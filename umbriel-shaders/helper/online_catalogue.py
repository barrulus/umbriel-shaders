# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Barrulus
"""Published catalogue reader: pinned GitHub files, bounded reads and verified bytes."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

import catalogue_contract as c
from catalogue_client import LocalCatalogue

INDEX_LIMIT = 4 * 1024 * 1024
REPOSITORY = re.compile(r"https://github\.com/([A-Za-z0-9_-]+/[A-Za-z0-9_.-]+)\Z")
SHA = re.compile(r"[0-9a-f]{40}\Z")
HASH = re.compile(r"[0-9a-f]{64}\Z")


def repository_name(url):
    match = REPOSITORY.fullmatch(url)
    c.require(match is not None and not any(part in {'.', '..'} for part in match[1].split('/')),
              "Choose a GitHub repository URL, such as https://github.com/noctalia-dev/community-umbriel-shaders.")
    return match[1]


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        raise c.CatalogueError("Catalogue downloads must not redirect to another URL.")


def download(url, limit):
    c.require(url.startswith('https://raw.githubusercontent.com/'), 'Invalid download origin.')
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'Umbriel-Shaders/0.4', 'Accept-Encoding': 'identity'})
        with urllib.request.build_opener(NoRedirect()).open(request, timeout=8) as response:
            data = response.read(limit + 1)
        c.require(len(data) <= limit, 'Download exceeds the advertised size limit.')
        return data
    except (urllib.error.URLError, TimeoutError, OSError) as error:
        raise ConnectionError('Could not fetch the community catalogue files: ' + str(error)) from error


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def validate_registry(registry, repository):
    c.allow_keys(registry, {'schema_version', 'draft', 'source', 'feature_definitions', 'effects', 'families', 'files'}, 'catalogue')
    c.require(type(registry.get('schema_version')) is int and registry['schema_version'] == 1, 'Unsupported catalogue schema.')
    c.require(registry.get('draft') is False, 'Online catalogues must be published snapshots, not drafts.')
    source = registry.get('source')
    c.allow_keys(source, {'repository', 'revision'}, 'source')
    c.require(source.get('repository') == repository, 'Catalogue repository does not match the configured source.')
    c.require(isinstance(source.get('revision'), str) and SHA.fullmatch(source['revision']), 'Catalogue needs a full source commit SHA.')
    definitions = c.table(registry.get('feature_definitions'), 'feature_definitions')
    c.require('preset-effects' in definitions and len(definitions) <= 64, 'Invalid feature definitions.')
    for key, value in definitions.items():
        c.string(key, 'feature label'); c.string(value, 'feature description')
    files = c.table(registry.get('files'), 'files')
    c.require(len(files) <= c.MAX_FILES, 'Too many catalogue files.')
    total = 0
    for path, record in files.items():
        c.relative_path(path)
        suffix = Path(path).suffix
        c.require(suffix in c.DOWNLOAD_SUFFIXES, f'{path}: unsupported file type')
        c.allow_keys(record, {'bytes', 'sha256'}, path)
        limit = c.FILE_LIMIT if suffix in {'.png', '.gif', '.webp', '.mp4', '.webm'} else c.TEXT_LIMIT
        c.require(type(record.get('bytes')) is int and 0 <= record['bytes'] <= limit, f'{path}: invalid file size')
        c.require(isinstance(record.get('sha256'), str) and HASH.fullmatch(record['sha256']), f'{path}: invalid hash')
        total += record['bytes']
    c.require(total <= c.MAX_TOTAL_BYTES, 'Catalogue exceeds total file size limit.')

    def listed(path):
        c.relative_path(path)
        c.require(path in files, f'{path}: missing file record')

    def effect_id(value):
        c.string(value, 'effect ID')
        parts = value.split('/')
        c.require(len(parts) == 2 and parts[0] in c.KINDS and c.SLUG.fullmatch(parts[1]), 'Invalid effect ID: ' + value)

    def tags(record):
        values = c.strings(record.get('tags'), 'tags')
        c.require(len(values) <= 64 and all(c.SLUG.fullmatch(tag) for tag in values), 'Invalid tags.')

    effects = {}
    presets = {}
    c.require(isinstance(registry.get('effects'), list) and len(registry['effects']) <= c.MAX_FILES, 'Invalid effects list.')
    for effect in registry['effects']:
        c.allow_keys(effect, {'id', 'path', 'name', 'description', 'author', 'license', 'notice_files', 'tags', 'role',
                             'kind', 'preset', 'uses', 'dependencies', 'families', 'requirements', 'required_settings',
                             'tested_on', 'install_files', 'preview', 'readme', 'config_example', 'activation'}, 'effect')
        identifier = effect.get('id'); effect_id(identifier)
        c.require(identifier not in effects and effect.get('path') == identifier, 'Duplicate or mismatched effect ID.')
        kind = identifier.split('/')[0]
        c.require(effect.get('kind') == kind and effect.get('role') in {'effect', 'companion'}, 'Invalid kind or role.')
        for key in ('name', 'description', 'author', 'license', 'preset'):
            c.string(effect.get(key), identifier + ': ' + key)
        c.require(effect['preset'] not in presets and effect['preset'] != 'off', 'Duplicate or reserved preset name.')
        presets[effect['preset']] = identifier
        uses = c.strings(effect.get('uses'), identifier + ': uses', nonempty=effect['role'] == 'effect')
        allowed = {u for u in c.USES if u.startswith('animation.')} if kind == 'animation' else {'effects.' + kind}
        c.require(set(uses) <= allowed, identifier + ': uses do not match kind')
        for key in ('dependencies', 'families', 'tested_on'):
            c.strings(effect.get(key), identifier + ': ' + key)
        tags(effect)
        c.allow_keys(effect.get('requirements'), {'features'}, identifier + ': requirements')
        features = c.strings(effect['requirements'].get('features'), 'features')
        c.require('preset-effects' in features and set(features) <= definitions.keys(), 'Unrecognised requirements.')
        for key, value in c.table(effect.get('required_settings'), 'required_settings').items():
            c.validate_setting(key, value)
            c.require(not key.startswith('effects.') and not key.endswith('.effect'), 'Requirements cannot select other shaders.')
        notices = c.strings(effect.get('notice_files'), 'notices', nonempty=True)
        for path in notices:
            listed(path)
            c.require(Path(path).suffix in {'.txt', '.md'}, 'Notices must be text.')
        install = c.strings(effect.get('install_files'), 'install_files', nonempty=True)
        for path in install: listed(path)
        shaders = [p for p in install if p.endswith('.glsl')]
        c.require(len(shaders) == 1 and shaders[0].startswith(identifier + '/'), 'Invalid shader installation path.')
        c.require(set(install) == set(notices + [identifier + '/effect.toml', shaders[0]]), 'Unexpected installation files.')
        c.allow_keys(effect.get('preview'), {'image', 'animation'}, 'preview')
        for key, suffixes in [('image', {'.png', '.webp'}), ('animation', {'.gif', '.mp4', '.webm'})]:
            path = effect['preview'].get(key)
            if path is not None:
                listed(path); c.require(Path(path).suffix in suffixes, 'Invalid preview type.')
        for key in ('readme', 'config_example'):
            if effect.get(key) is not None:
                listed(effect[key])
                c.require(effect[key] == identifier + ('/README.md' if key == 'readme' else '/config.toml'), 'Invalid documentation path.')
        effects[identifier] = effect
    for identifier, effect in effects.items():
        c.closure(effects, [identifier])
        c.requirements_for(effects, [identifier])

    def recipe(value, members):
        if value is None: return
        c.allow_keys(value, {'include', 'settings'}, 'activation')
        includes = c.strings(value.get('include'), 'activation.include')
        settings = c.table(value.get('settings'), 'activation.settings')
        selections = {}
        for key, item in settings.items():
            c.validate_setting(key, item)
            if key.startswith('effects.') or key.endswith('.effect'):
                member = presets.get(item)
                slot = c.setting_scope(key)
                c.require(member in members and slot in effects[member]['uses'], 'Activation selects an invalid family member or use.')
                selections[slot] = member
        c.require(bool(selections), 'Empty activation recipe.')
        c.require(includes == c.include_roots(effects, selections.values()), 'Activation includes unrelated presets.')
        for key in settings:
            c.require(c.setting_scope(key) is None or c.setting_scope(key) in selections, 'Activation changes an unselected slot.')
        for slot in selections:
            c.require(not (settings.get(slot + '.curve') in c.SPRINGS and slot + '.duration_ms' in settings), 'Spring duration cannot be overridden.')
        _, required = c.requirements_for(effects, selections.values())
        for key, item in required.items():
            c.require(key not in settings or (type(settings[key]) is type(item) and settings[key] == item), 'Activation conflicts with requirements.')

    for identifier, effect in effects.items(): recipe(effect.get('activation'), [identifier])
    c.require(isinstance(registry.get('families'), list) and len(registry['families']) <= c.MAX_FILES, 'Invalid families list.')
    backlinks = {identifier: set() for identifier in effects}
    families = set()
    for family in registry['families']:
        c.allow_keys(family, {'id', 'name', 'description', 'members', 'tags', 'authors', 'preview', 'readme', 'config_example', 'activation'}, 'family')
        identifier = c.string(family.get('id'), 'family ID')
        c.require(c.SLUG.fullmatch(identifier) and identifier not in families, 'Invalid or duplicate family ID.')
        families.add(identifier)
        for key in ('name', 'description'): c.string(family.get(key), key)
        members = c.strings(family.get('members'), 'members', nonempty=True)
        c.closure(effects, members)
        for member in members: backlinks[member].add(identifier)
        tags(family)
        c.require(family.get('authors') == sorted({effects[m]['author'] for m in c.closure(effects, members)}), 'Incorrect family credits.')
        c.require(family.get('preview') == {'image': None, 'animation': None} and family.get('readme') is None
                  and family.get('config_example') is None, 'Families must reference members, not copied assets.')
        recipe(family.get('activation'), members)
    for identifier, effect in effects.items():
        c.require(set(effect['families']) == backlinks[identifier], 'Inconsistent family membership.')
    return registry


class RemoteSource:
    def __init__(self, registry, cache, fetch=None):
        self.registry, self.root, self.fetch = registry, Path(cache), fetch or download
        self.memory = {}
        self.deadline = time.monotonic() + 45
        self.revision = registry['source']['revision']
        self.repository = repository_name(registry['source']['repository'])

    def url(self, path):
        c.relative_path(path)
        c.require(path in self.registry['files'], 'File is absent from the catalogue.')
        return 'https://raw.githubusercontent.com/' + self.repository + '/' + self.revision + '/' + urllib.parse.quote(path, safe='/')

    def cached_path(self, path):
        item = self.registry['files'][path]
        return self.root / 'objects' / (item['sha256'] + Path(path).suffix)

    def exists(self, path):
        return path in self.registry['files']

    def read(self, path, limit=c.FILE_LIMIT):
        c.relative_path(path)
        c.require(path in self.registry['files'], 'Missing catalogue file: ' + path)
        expected = self.registry['files'][path]
        c.require(expected['bytes'] <= limit, path + ': exceeds read limit')
        if path in self.memory:
            return self.memory[path]
        cacheable = Path(path).suffix in {'.png', '.webp', '.gif'}
        cached = self.cached_path(path)
        c.require(not cached.is_symlink(), 'Cached files cannot be symlinks.')
        if cacheable and cached.exists():
            c.require(cached.stat().st_size <= expected['bytes'], path + ': cached file size changed')
            raw = cached.read_bytes()
        else:
            if time.monotonic() > self.deadline:
                raise ConnectionError("Download took too long; try again.")
            raw = self.fetch(self.url(path), expected['bytes'])
        c.require(len(raw) == expected['bytes'] and hashlib.sha256(raw).hexdigest() == expected['sha256'], path + ': download hash mismatch')
        if cacheable and not cached.exists(): atomic(cached, raw)
        self.memory[path] = raw
        return raw

    def toml(self, path):
        try:
            return tomllib.loads(self.read(path, c.TEXT_LIMIT).decode('utf-8'))
        except (UnicodeError, tomllib.TOMLDecodeError) as error:
            raise c.CatalogueError(path + ': invalid TOML') from error


class OnlineCatalogue(LocalCatalogue):
    def __init__(self, repository, cache, *, refresh=False, fetch=None):
        fetch = fetch or download
        self.online = True
        name = repository_name(repository)
        cache = Path(cache) / hashlib.sha256(repository.encode()).hexdigest()[:16]
        index = cache / 'catalogue.json'
        self.offline = False
        raw = None
        if refresh or not index.exists():
            try:
                raw = fetch('https://raw.githubusercontent.com/' + name + '/catalogue/catalogue.json', INDEX_LIMIT)
            except ConnectionError:
                if not index.exists(): raise
                self.offline = True
        if raw is None:
            c.require(not index.is_symlink() and index.stat().st_size <= INDEX_LIMIT, 'Invalid cached catalogue.')
            raw = index.read_bytes()
        c.require(len(raw) <= INDEX_LIMIT, 'Catalogue exceeds size limit.')
        try:
            self.registry = validate_registry(json.loads(raw), repository)
        except (ValueError, KeyError, TypeError, RecursionError) as error:
            raise c.CatalogueError('Invalid published catalogue: ' + str(error)) from error
        atomic(index, raw)
        self.source = RemoteSource(self.registry, cache, fetch)
        self.effects = {effect['id']: effect for effect in self.registry['effects']}
        self.definitions = {}
        self.fingerprint = hashlib.sha256(c.encode(self.registry).encode()).hexdigest()

    def browse(self):
        # Only static previews are cached for browsing. Shader files are fetched
        # when selected; recordings open at their immutable source URL.
        deadline = time.monotonic() + 25
        def preview(effect):
            path = effect['preview']['image']
            if not path or time.monotonic() > deadline: return None
            try:
                self.source.read(path)
                return str(self.source.cached_path(path))
            except (c.CatalogueError, ConnectionError, OSError):
                return None
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            images = list(pool.map(preview, self.registry['effects']))
        effects = [{**effect, 'local_preview': {'image': image,
                    'animation': self.source.url(effect['preview']['animation']) if effect['preview']['animation'] else None}}
                   for effect, image in zip(self.registry['effects'], images)]
        return {'catalogue': {'mode': 'online', 'repository': self.registry['source']['repository'],
                'revision': self.source.revision, 'offline': self.offline, 'fingerprint': self.fingerprint,
                'effects': effects, 'families': self.registry['families'], 'features': self.registry['feature_definitions']},
                **({'message': 'Offline — showing the saved catalogue. Previously downloaded shaders remain available.'} if self.offline else {})}

    def definition(self, effect_id, library):
        if effect_id not in self.definitions:
            validator = c.Generator(self.source)
            name, shader, dependencies = validator.read_preset(effect_id)
            record = self.effects[effect_id]
            c.require(name == record['preset'] and dependencies == record['dependencies'] and shader in record['install_files'],
                      'Downloaded preset does not match its catalogue record.')
            definition = validator.definitions[effect_id]
            overlay = definition.get('overlay')
            if overlay:
                c.require(any(self.effects[d]['preset'] == overlay and self.effects[d]['kind'] == 'window'
                              for d in c.closure(self.effects, dependencies)), 'Invalid companion overlay.')
            self.definitions[effect_id] = definition
        return super().definition(effect_id, library)
