"""Online catalogue and Apply regression checks with no shader checkout at runtime."""
import copy
import hashlib
import json
from pathlib import Path
import shutil
import unittest
from unittest.mock import patch
import urllib.parse

import test_helper as fixtures
h = fixtures.h
from catalogue_client import LocalCatalogue, ONLINE_REPOSITORY
import catalogue_contract as c
import online_catalogue as online


class OnlineTests(unittest.TestCase):
    add_effect = fixtures.ControllerTests.add_effect
    add_family = fixtures.ControllerTests.add_family

    def setUp(self):
        fixtures.ControllerTests.setUp(self)
        self.add_effect('window/test-overlay', role='companion')
        self.add_effect('border/test-border', dependencies=['window/test-overlay'])
        self.add_effect('animation/test-reveal', uses=['animation.workspaces'], features=['workspace-reveal-full-scene'],
                        recipe='[animation]\nenabled = true\n[animation.workspaces]\neffect = "test-reveal"\nstyle = "reveal"\nenabled = true\nduration_ms = 1000\ncurve = "linear"\n')
        self.add_family(['cursor/glow', 'border/test-border'], {'effects.cursor':'cursor/glow','effects.border':'border/test-border'})
        (self.source/'cursor/glow/preview.png').write_bytes(b'synthetic preview')
        self.registry = LocalCatalogue(self.source).registry
        self.registry['draft'] = False
        self.registry['source']['revision'] = 'a'*40
        self.payloads = {path:(self.source/path).read_bytes() for path in self.registry['files']}
        # The consumer can only reach the fake HTTP transport, not authoring files.
        shutil.rmtree(self.source)
        self.requests = []
        self.offline = False
        mock = patch.object(online, 'download', side_effect=self.fetch)
        mock.start(); self.addCleanup(mock.stop)

    def fetch(self, url, limit):
        self.requests.append(url)
        if self.offline: raise ConnectionError('Offline')
        if url.endswith('/catalogue/catalogue.json'):
            return json.dumps(self.registry).encode()
        prefix = 'https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/' + self.registry['source']['revision'] + '/'
        self.assertTrue(url.startswith(prefix), url)
        path = urllib.parse.unquote(url[len(prefix):])
        return self.payloads[path]

    def browse(self):
        return self.controller.catalogue(ONLINE_REPOSITORY)['catalogue']

    def choose(self, effect='cursor/glow', slot='effects.cursor'):
        return self.controller.choose(ONLINE_REPOSITORY, effect, slot)

    def test_browse_fetches_only_index_and_previews_without_install_or_apply(self):
        result = self.browse()
        self.assertEqual(result['mode'], 'online')
        self.assertEqual(len(result['effects']),4)
        self.assertTrue(all(url.endswith(('/catalogue.json','.png')) for url in self.requests))
        self.assertFalse((self.controller.root/'library').exists())
        self.assertEqual(self.peer.switches, [])
        self.assertFalse(self.source.exists())

    def test_choose_downloads_only_selection_and_notices_then_undo_restores(self):
        self.browse(); self.requests.clear()
        self.assertTrue(self.choose()['managed'])
        paths={Path(url).name for url in self.requests}
        self.assertEqual(paths, {'effect.toml','shader.glsl','README.md','Noctalia-MIT.txt'})
        self.assertFalse((self.controller.root/'library/border').exists())
        self.assertEqual(len(self.peer.switches),1)
        self.controller.undo()
        self.assertFalse(self.controller.status()['managed'])
        self.assertEqual(self.base.read_bytes(), self.original)
        # No second persistent copy of downloaded shader code in the HTTP cache.
        self.assertFalse(list((self.controller.root/'catalogue-cache').rglob('*.glsl')))

    def test_family_downloads_dependencies_and_undo_is_one_transaction(self):
        self.browse()
        self.controller.choose_family(ONLINE_REPOSITORY,'test',{'effects.cursor':'cursor/glow','effects.border':'border/test-border'})
        self.assertTrue((self.controller.root/'library/window/test-overlay/shader.glsl').is_file())
        self.assertNotIn('effects.window', self.controller.state()['current']['selections'])
        self.assertEqual(len(self.peer.switches),1)
        self.controller.undo();self.assertFalse(self.controller.status()['managed'])

    def test_reveal_applies_in_one_operation_and_restores(self):
        self.browse()
        self.choose('animation/test-reveal','animation.workspaces')
        self.assertEqual(len(self.peer.switches),1)
        self.assertEqual(self.controller.state()['current']['settings']['animation.workspaces.style'],'reveal')
        self.controller.restore(); self.assertEqual(self.base.read_bytes(),self.original)

    def test_failed_download_leaves_config_and_library_untouched(self):
        self.browse()
        self.payloads['cursor/glow/README.md'] += b'wrong bytes'
        with self.assertRaisesRegex(ValueError,'hash mismatch'):
            self.choose()
        self.assertEqual(self.peer.switches,[])
        self.assertFalse((self.controller.root/'library').exists())

    def test_offline_saved_catalogue_and_installed_shader_work_after_restart(self):
        self.browse();self.choose();self.controller.restore()
        self.offline=True
        self.controller=h.Controller(self.controller.root,self.peer)
        self.assertTrue(self.browse()['offline'])
        self.requests.clear()
        self.assertTrue(self.choose()['managed'])
        self.assertEqual(self.requests,[])
        self.controller.restore()
        with self.assertRaises(ConnectionError):
            self.choose('border/test-border','effects.border')
        self.assertFalse(self.controller.status()['managed'])

    def test_custom_installed_shader_is_reused_when_catalogue_changes(self):
        self.browse();self.choose();self.controller.restore()
        local=self.controller.root/'library/cursor/glow/shader.glsl'
        custom=local.read_bytes()+b'// custom colours\n';local.write_bytes(custom)
        self.registry['source']['revision']='b'*40
        self.payloads['cursor/glow/shader.glsl']+=b'// online change\n'
        raw=self.payloads['cursor/glow/shader.glsl']
        self.registry['files']['cursor/glow/shader.glsl']={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
        self.browse();self.requests.clear()
        self.choose()
        self.assertEqual(self.requests,[])
        self.assertEqual(local.read_bytes(),custom)
        self.choose('border/test-border','effects.border')
        self.assertEqual(local.read_bytes(),custom)
        self.controller.undo();self.assertTrue(self.controller.status()['managed'])
        self.controller.restore();self.assertEqual(local.read_bytes(),custom)

    def test_local_base_preset_needs_no_network_on_apply(self):
        shader=self.root/'custom.glsl';shader.write_bytes(self.payloads['cursor/glow/shader.glsl']+b'// custom\n')
        self.base.write_text(self.base.read_text()+'\n[effects.preset.glow]\nkind = "cursor"\nshader = "custom.glsl"\nradius = 42\n')
        original=self.base.read_bytes()
        self.browse();self.offline=True;self.requests.clear()
        self.choose()
        self.assertEqual(self.requests,[])
        self.assertFalse((self.controller.root/'library').exists())
        self.controller.restore();self.assertEqual(self.base.read_bytes(),original)

    def test_invalid_refresh_preserves_last_good_cached_index(self):
        self.browse()
        index=next((self.controller.root/'catalogue-cache').rglob('catalogue.json'))
        good=index.read_bytes()
        self.registry['draft']=True
        with self.assertRaisesRegex(h.Error,'draft'):
            self.browse()
        self.assertEqual(index.read_bytes(),good)
        self.offline=True
        self.assertTrue(self.browse()['offline'])

    def test_downloaded_preset_must_match_advertised_kind_and_name(self):
        self.payloads['cursor/glow/effect.toml']=self.payloads['cursor/glow/effect.toml'].replace(b'preset.glow',b'preset.wrong')
        raw=self.payloads['cursor/glow/effect.toml']
        self.registry['files']['cursor/glow/effect.toml']={'bytes':len(raw),'sha256':hashlib.sha256(raw).hexdigest()}
        self.browse()
        with self.assertRaisesRegex(ValueError,'does not match'):
            self.choose()
        self.assertEqual(self.peer.switches,[])

    def test_untrusted_records_reject_drafts_hosts_paths_hooks_and_wrong_scopes(self):
        cases=[]
        for key,value in [('draft',True),('schema_version',2)]:
            bad=copy.deepcopy(self.registry);bad[key]=value;cases.append(bad)
        bad=copy.deepcopy(self.registry);bad['source']['repository']='https://evil.invalid/a';cases.append(bad)
        bad=copy.deepcopy(self.registry);bad['source']['revision']='main';cases.append(bad)
        bad=copy.deepcopy(self.registry);bad['files']['../escape.glsl']={'bytes':1,'sha256':'0'*64};cases.append(bad)
        bad=copy.deepcopy(self.registry);bad['effects'][0]['activation']['settings']['general.autostart']=['command'];cases.append(bad)
        bad=copy.deepcopy(self.registry);bad['families'][0]['path']='copied-family';cases.append(bad)
        bad=copy.deepcopy(self.registry);bad['effects'][0]['families']=['missing-family'];cases.append(bad)
        for number,bad in enumerate(cases):
            with self.subTest(number=number),self.assertRaises(ValueError):
                online.validate_registry(bad,ONLINE_REPOSITORY)

    def test_new_descriptive_tags_and_capability_labels_do_not_block_browsing(self):
        self.registry['feature_definitions']['future-api'] = 'A new upstream capability label.'
        glow = next(e for e in self.registry['effects'] if e['id'] == 'cursor/glow')
        glow['tags'] = ['new-community-tag']
        glow['requirements']['features'].append('future-api')
        result = self.browse()
        self.assertIn('future-api', result['features'])
        self.assertTrue(self.choose()['managed'])

    def test_preview_symlink_is_not_read_as_cached_content(self):
        self.browse()
        image=next((self.controller.root/'catalogue-cache').rglob('*.png'))
        original=self.base.read_bytes()
        image.unlink();image.symlink_to(self.base)
        self.requests.clear()
        result=self.browse()
        glow=next(e for e in result['effects'] if e['id']=='cursor/glow')
        self.assertIsNone(glow['local_preview']['image'])
        self.assertEqual(self.base.read_bytes(),original)


if __name__=='__main__': unittest.main()
