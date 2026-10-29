# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Barrulus
"""Trusted local catalogue adapter. Never imports code from the shader checkout.

The bundled contract generator validates authoring files and produces the same
schema-v1 records used by the eventual published API. Draft JSON is not accepted
as a remote/installable catalogue: this explicit local mode reads source files.
"""
import hashlib
import json
from pathlib import Path

import catalogue_contract as contract


class LocalCatalogue:
    def __init__(self, root):
        contract.require(bool(root), "Choose the community shader checkout in plugin settings.")
        self.source = contract.Source(Path(root).expanduser().absolute(), None)
        # Real metadata takes precedence over the review-only example overlay.
        overlay = "." if self.source.discover(".", "metadata.toml") else "docs/catalogue-examples"
        # A configured checkout is explicit authoring mode. Publication gating
        # applies to generated online catalogues, not local experiments.
        generator = contract.Generator(self.source, overlay, include_unpublished=True)
        self.registry = generator.build()
        self.definitions = generator.definitions
        self.effects = {e["id"]: e for e in self.registry["effects"]}
        self.fingerprint = hashlib.sha256(contract.encode(self.registry).encode()).hexdigest()

    def browse(self):
        return {"catalogue": {"mode": "local", "fingerprint": self.fingerprint,
                "effects": [{**effect, "local_preview": {kind: str(self.source.root / path) if path else None
                             for kind, path in effect["preview"].items()}} for effect in self.registry["effects"]],
                "families": [{**family, "local_preview": {kind: str(self.source.root / path) if path else None
                              for kind, path in family["preview"].items()}} for family in self.registry["families"]],
                "features": self.registry["feature_definitions"]}}

    def selection(self, selections, evidence):
        # Latest-Umbriel catalogue policy; capability evidence remains diagnostic.
        return contract.activation_for(self.registry, selections, evidence=evidence)

    def family_selection(self, family_id, choices, selections, evidence):
        family = next((f for f in self.registry["families"] if f["id"] == family_id), None)
        contract.require(family is not None, "Unknown shader family.")
        groups = {}
        for effect_id in family["members"]:
            effect = self.effects[effect_id]
            if effect["role"] == "companion":
                continue  # Borders resolve their own overlays; don't also enable them globally.
            for slot in effect["uses"]:
                if effect["activation"] is not None:
                    groups.setdefault(slot, []).append(effect_id)
        contract.require(isinstance(choices, dict) and set(choices) == set(groups),
                         "Choose a shader or Keep current for every family use.")
        requested = {}
        for slot, effect_id in choices.items():
            contract.require(isinstance(effect_id, str), "Choose between the family's alternatives before applying.")
            if not effect_id:
                continue
            contract.require(effect_id in groups[slot], "The chosen shader is not a family member for this use.")
            requested[slot] = effect_id
        contract.require(bool(requested), "Choose at least one family shader to apply.")
        combined = {**selections, **requested}
        selected = self.selection(combined, evidence)
        recommended = contract.activation_for(self.registry, requested, family=family_id, evidence=evidence)
        selected["settings"].update(recommended["settings"])
        _, requirements = contract.requirements_for(self.effects, combined.values())
        for key, value in requirements.items():
            contract.require(key not in selected["settings"] or
                             (type(selected["settings"][key]) is type(value) and selected["settings"][key] == value),
                             "Family settings conflict with another selected shader: " + key)
        return family, requested, combined, selected

    def preserve_unchanged_settings(self, selected, selections, requested, previous):
        for key, value in previous.items():
            scope = contract.setting_scope(key)
            if scope in selections and scope not in requested:
                selected["settings"][key] = value
        _, requirements = contract.requirements_for(self.effects, selections.values())
        for key, value in requirements.items():
            contract.require(key not in selected["settings"] or
                             (type(selected["settings"][key]) is type(value) and selected["settings"][key] == value),
                             "Saved settings conflict with a shader requirement: " + key)

    def bytes(self, name):
        raw = self.source.read(name)
        expected = self.registry["files"][name]
        contract.require(len(raw) == expected["bytes"] and hashlib.sha256(raw).hexdigest() == expected["sha256"],
                         f"Catalogue file changed: {name}")
        return raw

    def definition(self, effect_id, library):
        definition = dict(self.definitions[effect_id])
        relative = contract.runtime_path(effect_id, definition["shader"])
        definition["shader"] = str(library / relative)
        return definition


def value_toml(value):
    if isinstance(value, dict):
        return "{ " + ", ".join(json.dumps(k) + " = " + value_toml(v) for k, v in sorted(value.items())) + " }"
    return json.dumps(value, ensure_ascii=False, allow_nan=False)


def setting_lines(settings):
    # Quoted segments prevent preset names or strings from introducing TOML syntax.
    return [".".join(json.dumps(part) for part in key.split(".")) + " = " + value_toml(value)
            for key, value in sorted(settings.items())]


def preset_lines(name, definition):
    return ["[effects.preset." + json.dumps(name) + "]"] + [json.dumps(key) + " = " + value_toml(value)
                                                            for key, value in sorted(definition.items())]


def equivalent(existing, imported, graph_files, imported_hash):
    definition = existing["definition"]
    if not isinstance(definition, dict):
        return False
    defaults = {"palette": False}
    if imported["kind"] == "cursor":
        defaults["radius"] = 0
    elif imported["kind"] == "border":
        defaults.update(padding=0, speed=1.0, animated=True, overlay="")
    left = {**defaults, **definition}
    right = {**defaults, **imported}
    left.pop("shader", None)
    right.pop("shader", None)
    # Config validation supplies the strict type checks; booleans must not compare as numbers.
    for key in ("palette", "animated"):
        if key in left and type(left[key]) is not bool:
            return False
    shader = graph_files.get(existing["shader"])
    return left == right and shader is not None and shader["sha256"] == imported_hash
