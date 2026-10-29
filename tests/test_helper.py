import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import tomllib
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "umbriel-shaders/helper"))
spec = importlib.util.spec_from_file_location("umbriel_shaders", ROOT / "umbriel-shaders/helper/umbriel_shaders.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


class FakePeer:
    def __init__(self, base):
        self.base = str(base)
        self.active = str(base)
        self.identity = {"pid": 10, "start": "123", "boot": "test", "socket": "/test/socket"}
        self.environ = {"HOME": str(base.parent)}
        self.cwd = str(base.parent)
        self.argv = ["umbriel", "-c", str(base)]
        self.executable = "/usr/bin/umbriel"
        self.switches = []
        self.reject = False
        self.compile_error = False
        self.runtime = False
        self.on_switch = None
        self.owners = []
        self.messages = []
        self.fail_action = None

    def capabilities(self):
        pass

    def validate(self, path):
        raw = Path(path).read_text()
        if "INVALID" in raw:
            raise h.Error("Invalid configuration")
        tomllib.loads(raw)

    def report(self):
        presets = {}
        cursor = ""
        defaults, pools = {}, {}

        def visit(path):
            nonlocal cursor
            data = tomllib.loads(Path(path).read_text())
            for included in data.get("include", {}).get("files", []):
                visit(h.expand(included, Path(path).parent, self.environ))
            for included in data.get("include", {}).get("optional", {}).get("files", []):
                resolved = h.expand(included, Path(path).parent, self.environ)
                if resolved.exists():
                    visit(resolved)
            effects = data.get("effects", {})
            presets.update(effects.get("preset", {}))
            defaults.update({k: v for k, v in effects.items() if isinstance(v, str)})
            pools.update(effects.get("pool", {}))
            cursor = effects.get("cursor", cursor)

        visit(self.active)
        def normalized(value, default):
            value = {"name": "", "pool": "", "source": "default", "suppressed": False, **value}
            if value["source"] == "default":
                value["name"] = default
            return value
        cursor_value = self.runtime if isinstance(self.runtime, dict) else ({"name": "other", "source": "runtime"} if self.runtime else {})
        return {"presets": [{"name": name, "kind": p["kind"],
                             "state": "failed" if name == "glow" and self.compile_error else "compiled"}
                            for name, p in presets.items()],
                "cursor": normalized(cursor_value, cursor),
                "pools": [{"name": name, "members": [{"name": member} for member in value.get("choose", [])]} for name, value in pools.items()],
                "owners": [{**owner, "slots": {kind: normalized(value, defaults.get(kind, "")) for kind, value in owner["slots"].items()}}
                           for owner in self.owners]}

    def request(self, command, argument=None):
        if command == "effects":
            return self.report()
        if command == "msg":
            self.messages.append(argument)
            if self.fail_action and self.fail_action(argument):
                raise h.Error("Injected runtime failure")
            action, _, arg = argument.partition(":")
            kind, operation = action.removeprefix("effect-").rsplit("-", 1)
            selector, target = (arg.split("/", 1) + [""])[:2] if operation in {"set", "cycle"} else (None, arg)
            report = self.report()
            if kind == "cursor":
                value = report["cursor"].copy()
                def store(value): self.runtime = value
            else:
                owner = next(o for o in self.owners if o.get("id", o.get("name")) == target)
                reported = next(o for o in report["owners"] if o.get("id", o.get("name")) == target)
                value = reported["slots"][kind].copy()
                def store(value): owner["slots"][kind] = value
            if operation == "reset":
                value = {"source": "default", "name": "", "pool": "", "suppressed": False}
            elif operation == "toggle":
                value["suppressed"] = not value["suppressed"]
            elif selector == "off":
                value["suppressed"] = True
            else:
                pool = next((p for p in report["pools"] if p["name"] == selector), None)
                name = selector
                if pool:
                    members = [m["name"] for m in pool["members"]]
                    index = (members.index(value["name"]) + 1) % len(members) if operation == "cycle" and value["name"] in members else 0
                    name = members[index]
                value = {"name": name, "pool": selector if pool else "", "source": "runtime", "suppressed": False}
            store(value)
            return None
        if command == "config-replace":
            if self.reject:
                self.reject = False
                raise h.Error("Rejected replacement")
            self.validate(argument)
            self.active = argument
            self.switches.append(argument)
            if self.on_switch:
                self.on_switch(argument)
            return None
        raise AssertionError(command)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="shaders test with spaces ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.base = self.root / "base.toml"
        self.base.write_text('[general]\nautostart = []\n[effects]\ncursor = ""\n'
                             '[[window_rule]]\nmatch.app_id = "^example$"\nopacity = 0.8\n')
        self.original = self.base.read_bytes()
        self.source = self.root / "source"
        for relative, content in {
            "cursor/glow/effect.toml": '[effects.preset.glow]\nkind = "cursor"\nshader = "shader.glsl"\npalette = true\nradius = 96\n',
            "cursor/glow/shader.glsl": 'vec4 cursor(vec2 uv) { return umbriel_sample(uv); }\n',
            "cursor/glow/README.md": 'Synthetic test fixture.\n',
            "LICENSES/Noctalia-MIT.txt": 'Synthetic test notice.\n',
        }.items():
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content)
        (self.source / "cursor/glow/metadata.toml").write_text('name = "Glow"\ndescription = "Test glow"\nauthor = "Test"\nlicense = "MIT"\nnotice_files = ["cursor/glow/README.md", "LICENSES/Noctalia-MIT.txt"]\n')
        (self.source / "cursor/glow/config.toml").write_text('[include]\nfiles = ["shaders/community/cursor/glow/effect.toml"]\n[effects]\ncursor = "glow"\n')
        self.peer = FakePeer(self.base)
        self.controller = h.Controller(self.root / "state", self.peer)

    def test_local_checkout_can_browse_unpublished_shaders(self):
        from catalogue_client import LocalCatalogue
        metadata = self.source / "cursor/glow/metadata.toml"
        metadata.write_text("publish = false\n" + metadata.read_text())
        catalogue = LocalCatalogue(self.source)
        self.assertEqual([e["id"] for e in catalogue.browse()["catalogue"]["effects"]], ["cursor/glow"])
        self.assertTrue(catalogue.registry["draft"])
        self.apply_glow()
        self.assertTrue(self.controller.status()["managed"])

    def run_cli(self, action, *extra):
        output = io.StringIO()
        with patch.object(h, "Peer", return_value=self.peer), contextlib.redirect_stdout(output):
            code = h.main(["--state-dir", str(self.controller.root), "--source-root", str(self.source), *extra, action])
        return code, json.loads(output.getvalue())

    def test_diagnostics_is_read_only_and_distinguishes_saved_from_runtime(self):
        self.apply_glow()
        self.peer.runtime = {"name": "external", "source": "runtime"}
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        switches = list(self.peer.switches)
        messages = list(self.peer.messages)
        report = h.diagnostic_report(self.controller.root, self.peer, source=str(self.source))
        self.assertTrue(report["managed"])
        self.assertIn("effects.cursor = ", report["report_text"])
        self.assertIn("cursor/glow", report["report_text"])
        self.assertIn("external", report["report_text"])
        self.assertIn("changed since plugin Apply", report["report_text"])
        self.assertEqual(switches, self.peer.switches)
        self.assertEqual(messages, self.peer.messages)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})
        self.assertNotIn("autostart", report["report_text"])
        self.assertNotIn("match.app_id", report["report_text"])

    def test_diagnostics_shows_original_includes_and_exact_managed_toml(self):
        included = self.root / "included.toml"
        included.write_text('[effects]\nmax_fps = 30\n')
        self.base.write_text(self.original.decode() + '\n[include]\nfiles = ' + json.dumps([str(included)]) + '\n')
        self.apply_glow()
        report = h.diagnostic_report(self.controller.root, self.peer)
        sections = {s["title"]: s["text"] for s in report["sections"]}
        self.assertIn(str(included), sections["Original configuration"])
        config = Path(self.controller.state()["current"]["config"])
        self.assertIn(config.read_text(), sections["Managed configuration"])
        self.assertIn("not implemented", sections["Saved selections"])

    def test_diagnostics_survives_missing_compositor_and_corrupt_saved_state(self):
        self.controller.state_path.write_text("broken json")
        self.controller.pending_path.write_text("broken journal")
        output = io.StringIO()
        with patch.object(h, "Peer", side_effect=OSError("No compositor socket")), contextlib.redirect_stdout(output):
            result = h.main(["--state-dir", str(self.controller.root), "diagnostics"])
        self.assertEqual(result, 0)
        report = json.loads(output.getvalue())["diagnostics"]
        self.assertTrue(report["pending"])
        self.assertFalse(report["managed"])
        self.assertIn("state.json", report["report_text"])
        self.assertIn("pending.json", report["report_text"])
        self.assertIn("No compositor socket", report["report_text"])
        self.assertEqual(self.controller.state_path.read_text(), "broken json")
        self.assertEqual(self.controller.pending_path.read_text(), "broken journal")

    def test_diagnostics_does_not_create_state_and_rejects_foreign_wrapper_path(self):
        missing = self.root / "not-created"
        report = h.diagnostic_report(missing, live_error="Offline")
        self.assertFalse(missing.exists())
        self.assertFalse(report["managed"])
        self.apply_glow()
        state = self.controller.state()
        secret = self.root / "private.txt"
        secret.write_text("secret that must not be exported")
        state["current"]["config"] = str(secret)
        h.save_json(self.controller.state_path, state)
        report = h.diagnostic_report(self.controller.root, self.peer)
        self.assertIn("outside the plugin generations", report["report_text"])
        self.assertNotIn(secret.read_text(), report["report_text"])

    def test_diagnostics_detects_external_configuration_and_restart(self):
        self.apply_glow()
        self.peer.active = str(self.base)
        report = h.diagnostic_report(self.controller.root, self.peer)
        self.assertFalse(report["managed"])
        self.assertIn("differs from the saved", report["report_text"])
        self.peer.identity = {**self.peer.identity, "start": "new-session"}
        report = h.diagnostic_report(self.controller.root, self.peer)
        self.assertIn("previous or different", report["report_text"])

    def test_cli_records_successful_validation_and_compilation_without_poll_overwrite(self):
        code, result = self.run_cli("choose")
        self.assertEqual(code, 0, result)
        operation = h.load_json(self.controller.root / "last-operation.json")
        self.assertEqual(operation["action"], "choose")
        self.assertEqual(operation["outcome"], "succeeded")
        phases = {(v["phase"], v["outcome"]) for v in operation["events"]}
        self.assertIn(("Configuration validation", "passed"), phases)
        self.assertIn(("GPU compilation", "passed"), phases)
        for action in ("status", "catalogue", "diagnostics"):
            self.assertEqual(self.run_cli(action)[0], 0)
            self.assertEqual(h.load_json(self.controller.root / "last-operation.json"), operation)

    def test_cli_records_compile_failure_and_successful_rollback(self):
        self.peer.compile_error = True
        code, result = self.run_cli("choose")
        self.assertEqual(code, 1)
        self.assertFalse(result["ok"])
        operation = h.load_json(self.controller.root / "last-operation.json")
        self.assertEqual(operation["outcome"], "failed")
        phases = {(v["phase"], v["outcome"]) for v in operation["events"]}
        self.assertIn(("GPU compilation", "failed"), phases)
        self.assertIn(("Rollback / recovery", "passed"), phases)
        self.assertEqual(self.peer.active, str(self.base))
        self.assertFalse(self.controller.pending_path.exists())

    def test_cli_records_validation_failure_before_switching(self):
        original_validate = self.peer.validate
        def reject_generated(path):
            if "generations" in str(path):
                raise h.Error("Invalid generated configuration")
            return original_validate(path)
        self.peer.validate = reject_generated
        code, _ = self.run_cli("choose")
        self.assertEqual(code, 1)
        operation = h.load_json(self.controller.root / "last-operation.json")
        self.assertEqual(operation["outcome"], "failed")
        self.assertIn("Invalid generated", operation["message"])
        self.assertEqual(self.peer.switches, [])

    def test_failed_rollback_remains_visible_as_pending_recovery(self):
        self.peer.compile_error = True
        def reject_rollback(path):
            if str(path) == str(self.base):
                raise h.Error("Rollback failed")
        self.peer.on_switch = reject_rollback
        code, _ = self.run_cli("choose")
        self.assertEqual(code, 1)
        report = h.diagnostic_report(self.controller.root, self.peer)
        self.assertTrue(report["pending"])
        self.assertIn("Rollback / recovery: failed", report["report_text"])
        self.assertIn("Recovery is still pending", report["report_text"])

    def test_changed_managed_file_is_not_presented_as_the_loaded_bytes(self):
        self.apply_glow()
        path = Path(self.controller.state()["current"]["config"])
        path.write_text(path.read_text() + "\n# edited externally\n")
        report = h.diagnostic_report(self.controller.root, self.peer)
        self.assertTrue(report["managed"])
        self.assertIn("may differ from what was loaded", report["report_text"])

    def test_operation_logging_failure_does_not_break_apply(self):
        real_save = h.save_json
        def save(path, value):
            if Path(path).name == "last-operation.json":
                raise OSError("Log storage unavailable")
            return real_save(path, value)
        with patch.object(h, "save_json", side_effect=save):
            code, result = self.run_cli("choose")
        self.assertEqual(code, 0, result)
        self.assertTrue(result["managed"])

    def test_diagnostics_reports_interrupted_operation_and_pending_recovery(self):
        def crash(_path):
            raise SystemExit("Process died after switching")
        self.peer.on_switch = crash
        with self.assertRaises(SystemExit):
            self.run_cli("choose")
        report = h.diagnostic_report(self.controller.root, self.peer)
        self.assertTrue(report["pending"])
        self.assertIn("did not record completion", report["report_text"])
        self.assertTrue(self.controller.pending_path.exists())

    def apply_glow(self):
        plan = self.controller.prepare(str(self.source))
        return self.controller.apply(plan["plan_token"])

    def crash_after_switch(self):
        plan = self.controller.prepare(str(self.source))
        save = h.save_json

        def crash(path, value):
            if Path(path) == self.controller.state_path:
                raise SystemExit("simulated power loss")
            save(path, value)

        with patch.object(h, "save_json", side_effect=crash), self.assertRaises(SystemExit):
            self.controller.apply(plan["plan_token"])

    def test_status_does_not_install_or_apply(self):
        result = self.controller.status()
        self.assertFalse(result["managed"])
        self.assertEqual(self.peer.switches, [])
        self.assertFalse((self.root / "state/library").exists())

    def test_review_installs_only_glow_and_notices_without_switching(self):
        plan = self.controller.prepare(str(self.source))
        self.assertEqual(self.peer.switches, [])
        self.assertEqual(plan["base"], str(self.base))
        installed = self.root / "state/library"
        self.assertEqual(sorted(p.relative_to(installed).as_posix() for p in installed.rglob("*") if p.is_file()),
                         sorted(h.GLOW_FILES))
        self.assertEqual(self.base.read_bytes(), self.original)

    def test_apply_and_undo_preserve_base_contents(self):
        self.base.chmod(0o444)
        result = self.apply_glow()
        self.assertTrue(result["managed"])
        self.assertEqual(self.peer.report()["cursor"]["name"], "glow")
        self.assertTrue(self.controller.status()["can_undo"])
        self.controller.undo()
        self.assertEqual(self.peer.active, str(self.base))
        self.assertFalse(self.controller.status()["managed"])
        self.assertEqual(self.base.read_bytes(), self.original)
        self.assertFalse(self.controller.pending_path.exists())

    def test_restore_uses_current_base_and_survives_new_helper_instance(self):
        self.apply_glow()
        self.base.write_text(self.base.read_text() + '\n[appearance]\nborder_width = 9\n')
        controller = h.Controller(self.root / "state", self.peer)
        controller.restore()
        self.assertEqual(self.peer.active, str(self.base))
        self.assertIn("border_width = 9", self.base.read_text())

    def test_invalid_base_after_apply_does_not_replace_active_config(self):
        self.apply_glow()
        before = self.peer.active
        self.base.write_text("INVALID")
        with self.assertRaises(ValueError):
            self.controller.restore()
        self.assertEqual(self.peer.active, before)

    def test_gpu_failure_rolls_back_and_clears_journal(self):
        plan = self.controller.prepare(str(self.source))
        self.peer.compile_error = True
        with self.assertRaisesRegex(h.Error, "failed GPU compilation.*previous configuration was restored"):
            self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.active, str(self.base))
        self.assertFalse(self.controller.pending_path.exists())

    def test_rejected_switch_restores_known_previous_config(self):
        plan = self.controller.prepare(str(self.source))
        self.peer.reject = True
        with self.assertRaisesRegex(h.Error, "Rejected replacement.*previous configuration was restored"):
            self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.active, str(self.base))
        self.assertFalse(self.controller.pending_path.exists())

    def test_interrupted_commit_requires_explicit_recovery(self):
        self.crash_after_switch()
        self.assertTrue(self.controller.pending_path.exists())
        self.assertNotEqual(self.peer.active, str(self.base))
        count = len(self.peer.switches)
        status = self.controller.status()
        self.assertTrue(status["pending"])
        self.assertEqual(len(self.peer.switches), count)
        with self.assertRaisesRegex(h.Error, "Recover"):
            self.controller.prepare(str(self.source))
        self.controller.recover()
        self.assertEqual(self.peer.active, str(self.base))
        self.assertFalse(self.controller.pending_path.exists())

    def test_interrupted_commit_then_compositor_restart_recovers_to_base(self):
        self.crash_after_switch()
        self.peer.identity = {**self.peer.identity, "start": "456"}
        self.peer.active = str(self.base)
        self.controller.recover()
        self.assertEqual(self.peer.active, str(self.base))
        self.assertFalse(self.controller.pending_path.exists())

    def test_failed_rollback_retains_recovery_record(self):
        plan = self.controller.prepare(str(self.source))
        self.peer.compile_error = True

        def sabotage(_path):
            self.base.write_text("INVALID")

        self.peer.on_switch = sabotage
        with self.assertRaisesRegex(h.Error, "Recovery is still pending"):
            self.controller.apply(plan["plan_token"])
        self.assertTrue(self.controller.pending_path.exists())

    def test_base_changes_including_optional_includes_invalidate_review(self):
        self.base.write_text(self.base.read_text() + '\n[include.optional]\nfiles = ["optional.toml"]\n')
        plan = self.controller.prepare(str(self.source))
        (self.root / "optional.toml").write_text('[appearance]\nborder_width = 8\n')
        with self.assertRaisesRegex(h.Error, "File changed"):
            self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.switches, [])

    def test_candidate_tampering_invalidates_review(self):
        plan = self.controller.prepare(str(self.source))
        state = h.load_json(self.root / "state/plans" / (plan["plan_token"] + ".json"))
        Path(state["current"]["config"]).write_text('[effects]\ncursor = ""\n')
        with self.assertRaisesRegex(h.Error, "File changed"):
            self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.switches, [])

    def test_runtime_override_is_switched_and_restored_by_undo(self):
        self.peer.runtime = True
        previous = self.peer.report()["cursor"]
        self.controller.choose(str(self.source), "cursor/glow", "effects.cursor")
        self.assertEqual(self.peer.report()["cursor"]["name"], "glow")
        self.controller.undo()
        self.assertEqual(self.peer.report()["cursor"], previous)

    def test_runtime_change_after_review_invalidates_apply(self):
        plan = self.controller.prepare(str(self.source))
        self.peer.runtime = True
        with self.assertRaisesRegex(h.Error, "Active selections changed"):
            self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.switches, [])

    def test_external_change_during_validation_is_not_overridden(self):
        self.apply_glow()
        validate = self.peer.validate

        def external_change(path):
            validate(path)
            self.peer.active = str(self.base)

        count = len(self.peer.switches)
        with patch.object(self.peer, "validate", side_effect=external_change):
            with self.assertRaisesRegex(h.Error, "changed during validation"):
                self.controller.restore()
        self.assertEqual(len(self.peer.switches), count)

    def test_external_config_replacement_is_not_overridden(self):
        self.apply_glow()
        external = self.root / "external.toml"
        external.write_text('[effects]\ncursor = ""\n')
        self.peer.active = str(external)
        switches = len(self.peer.switches)
        self.assertFalse(self.controller.status()["managed"])
        self.controller.restore()
        self.assertEqual(len(self.peer.switches), switches)
        with self.assertRaisesRegex(h.Error, "Another configuration"):
            self.controller.prepare(str(self.source))
        with self.assertRaisesRegex(h.Error, "no longer owns"):
            self.controller.undo()

    def test_explicit_base_review_can_adopt_an_external_replacement(self):
        self.apply_glow()
        external = self.root / "external.toml"
        external.write_bytes(self.original)
        self.peer.active = str(external)
        adopted = h.Controller(self.root / "state", self.peer, str(external))
        plan = adopted.prepare(str(self.source))
        self.assertEqual(self.peer.active, str(external))
        adopted.apply(plan["plan_token"])
        adopted.undo()
        self.assertEqual(self.peer.active, str(external))

    def test_restart_keeps_saved_selection_but_does_not_auto_apply(self):
        self.apply_glow()
        self.peer.active = str(self.base)
        self.peer.identity = {**self.peer.identity, "start": "456"}
        count = len(self.peer.switches)
        result = self.controller.status()
        self.assertIn("restarted", result["message"])
        self.assertEqual(len(self.peer.switches), count)
        self.apply_glow()
        self.controller.undo()
        self.assertEqual(self.peer.active, str(self.base))

    def test_restart_between_review_and_apply_is_rejected(self):
        plan = self.controller.prepare(str(self.source))
        self.peer.identity = {**self.peer.identity, "start": "456"}
        with self.assertRaisesRegex(h.Error, "restarted"):
            self.controller.apply(plan["plan_token"])

    def test_different_compositor_socket_cannot_reuse_saved_state(self):
        self.apply_glow()
        previous = self.controller.state_path.read_bytes()
        self.peer.identity = {**self.peer.identity, "socket": "/another/session"}
        self.peer.active = str(self.base)
        with self.assertRaisesRegex(h.Error, "another compositor socket"):
            self.controller.prepare(str(self.source))
        self.assertEqual(self.controller.state_path.read_bytes(), previous)

    def test_changed_config_setting_invalidates_review(self):
        plan = self.controller.prepare(str(self.source))
        changed = h.Controller(self.root / "state", self.peer, str(self.root / "another.toml"))
        with self.assertRaisesRegex(h.Error, "configured base path changed"):
            changed.apply(plan["plan_token"])
        self.assertEqual(self.peer.switches, [])

    def test_custom_base_and_declarative_symlink_remain_intact(self):
        target = self.root / "declarative.toml"
        target.write_bytes(self.original)
        self.base.unlink()
        self.base.symlink_to(target)
        self.apply_glow()
        self.controller.restore()
        self.assertTrue(self.base.is_symlink())
        self.assertEqual(target.read_bytes(), self.original)

    def test_changed_declarative_target_invalidates_review(self):
        first = self.root / "first.toml"
        second = self.root / "second.toml"
        first.write_bytes(self.original)
        second.write_bytes(self.original)
        self.base.unlink()
        self.base.symlink_to(first)
        plan = self.controller.prepare(str(self.source))
        self.base.unlink()
        self.base.symlink_to(second)
        with self.assertRaisesRegex(h.Error, "File changed"):
            self.controller.apply(plan["plan_token"])

    def test_root_drm_declaration_is_preserved(self):
        self.base.write_text(self.base.read_text() + '\n[include]\nfiles = ["gpu.toml"]\n[drm]\n')
        (self.root / "gpu.toml").write_text('[drm]\n')
        plan = self.controller.prepare(str(self.source))
        stored = h.load_json(self.root / "state/plans" / (plan["plan_token"] + ".json"))
        self.assertIn("drm", tomllib.loads(Path(stored["current"]["config"]).read_text()))

    def test_local_wrong_kind_is_reported_without_switching(self):
        self.base.write_text(self.base.read_text() + '\n[effects.preset.glow]\nkind = "border"\n')
        with self.assertRaisesRegex(h.Error, "must have kind cursor"):
            self.controller.prepare(str(self.source))
        self.assertEqual(self.peer.switches, [])

    def include_existing_glow(self):
        preset = self.source / "cursor/glow/effect.toml"
        self.base.write_text(self.base.read_text() + '\n[include]\nfiles = ' + json.dumps([str(preset)]) + '\n')
        return preset

    def test_existing_glow_is_reused_and_undo_preserves_it(self):
        self.include_existing_glow()
        original = self.base.read_bytes()
        plan = self.controller.prepare(str(self.source))
        self.assertIn("using your local copy", plan["message"])
        stored = h.load_json(self.root / "state/plans" / (plan["plan_token"] + ".json"))
        wrapper = tomllib.loads(Path(stored["current"]["config"]).read_text())
        self.assertEqual(wrapper["include"]["files"], [str(self.base)])
        self.controller.apply(plan["plan_token"])
        self.controller.undo()
        self.assertEqual(self.base.read_bytes(), original)
        self.assertIn("glow", {p["name"] for p in self.peer.report()["presets"]})

    def test_existing_glow_normalizes_omitted_defaults(self):
        imported = self.source / "cursor/glow/effect.toml"
        imported.write_text(imported.read_text().replace('palette = true\nradius = 96\n', ''))
        shader = self.source / "cursor/glow/shader.glsl"
        self.base.write_text(self.base.read_text() + '\n[effects.preset.glow]\nkind = "cursor"\nshader = '
                             + json.dumps(str(shader)) + '\npalette = false\nradius = 0\n')
        self.assertIn("using your local copy", self.controller.prepare(str(self.source))["message"])

    def test_custom_local_settings_and_shader_are_used_without_importing(self):
        imported = self.source / "cursor/glow/effect.toml"
        shader = self.root / "local.glsl"
        definition = imported.read_text().replace('"shader.glsl"', '"local.glsl"').replace('radius = 96', 'radius = 32')
        self.base.write_bytes(self.original + definition.encode())
        shader.write_bytes((imported.parent / "shader.glsl").read_bytes() + b'// custom colours\n')
        original_base, original_shader = self.base.read_bytes(), shader.read_bytes()
        plan = self.controller.prepare(str(self.source))
        self.assertIn("using your local copy", plan["message"])
        self.assertFalse(plan["local_copies"][0]["matches_catalogue"])
        self.assertFalse((self.root / "state/library").exists())
        self.controller.apply(plan["plan_token"])
        wrapper = Path(self.peer.active).read_text()
        self.assertNotIn('[effects.preset."glow"]', wrapper)
        self.assertEqual(self.peer.report()["cursor"]["name"], "glow")
        self.controller.restore()
        self.assertEqual(self.base.read_bytes(), original_base)
        self.assertEqual(shader.read_bytes(), original_shader)

    def test_existing_glow_shader_changes_invalidate_review(self):
        self.include_existing_glow()
        plan = self.controller.prepare(str(self.source))
        shader = self.source / "cursor/glow/shader.glsl"
        shader.write_bytes(shader.read_bytes() + b'// changed after review\n')
        with self.assertRaisesRegex(h.Error, "File changed"):
            self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.switches, [])

    def test_same_name_pool_is_not_reused(self):
        self.base.write_text(self.base.read_text() + '\n[effects.pool.glow]\nkind = "cursor"\n')
        with self.assertRaisesRegex(h.Error, "pool named glow"):
            self.controller.prepare(str(self.source))
        self.assertEqual(self.peer.switches, [])

    def test_failed_review_json_retains_discovered_base_without_plan(self):
        self.base.write_text(self.base.read_text() + '\n[effects.preset.glow]\nkind = "border"\n')
        output = io.StringIO()
        with patch.object(h, "Peer", return_value=self.peer), contextlib.redirect_stdout(output):
            result = h.main(["--state-dir", str(self.root / "state"), "--source-root", str(self.source), "prepare"])
        response = json.loads(output.getvalue())
        self.assertEqual(result, 1)
        self.assertFalse(response["ok"])
        self.assertEqual(response["base"], str(self.base))
        self.assertIn("must have kind cursor", response["message"])
        self.assertNotIn("plan_token", response)
        self.assertEqual(self.peer.switches, [])

    def test_failed_review_json_retains_pending_recovery(self):
        self.crash_after_switch()
        output = io.StringIO()
        with patch.object(h, "Peer", return_value=self.peer), contextlib.redirect_stdout(output):
            result = h.main(["--state-dir", str(self.root / "state"), "--source-root", str(self.source), "prepare"])
        response = json.loads(output.getvalue())
        self.assertEqual(result, 1)
        self.assertTrue(response["pending"])
        self.assertEqual(response["base"], str(self.base))
        self.assertIn("Recover", response["message"])
        self.assertNotIn("plan_token", response)

    def test_wrapper_cannot_become_its_own_base(self):
        self.base.write_text(h.MANAGED + "\n" + self.base.read_text())
        with self.assertRaisesRegex(h.Error, "cannot be used as the base"):
            self.controller.prepare(str(self.source))

    def test_import_rejects_commands_symlinks_and_shader_path_escape(self):
        preset = self.source / "cursor/glow/effect.toml"
        original = preset.read_text()
        for content in (original + '[general]\nautostart = ["nope"]\n',
                        original.replace('"shader.glsl"', '"../../../escape.glsl"')):
            with self.subTest(content=content):
                preset.write_text(content)
                with self.assertRaises(h.Error):
                    self.controller.prepare(str(self.source))
        preset.write_text(original)
        shader = self.source / "cursor/glow/shader.glsl"
        shader.rename(shader.with_suffix(".saved"))
        shader.symlink_to("shader.saved")
        with self.assertRaisesRegex(h.Error, "symlink"):
            self.controller.prepare(str(self.source))

    def test_installed_customisations_are_not_overwritten(self):
        self.controller.prepare(str(self.source))
        installed = self.root / "state/library/cursor/glow/shader.glsl"
        installed.write_text("my customised shader\n")
        with self.assertRaisesRegex(h.Error, "customised"):
            self.controller.prepare(str(self.source))
        self.assertEqual(installed.read_text(), "my customised shader\n")

    def test_discovery_honours_process_args_and_environment(self):
        self.assertEqual(h.discover_base(self.peer), str(self.base))
        self.peer.argv = ["umbriel"]
        self.peer.environ["XDG_CONFIG_HOME"] = str(self.root / "xdg")
        default = self.root / "xdg/umbriel/config.toml"
        default.parent.mkdir(parents=True)
        default.write_bytes(self.original)
        self.assertEqual(h.discover_base(self.peer), str(default))

    def add_effect(self, effect_id, uses=None, features=None, recipe=None, role="effect", dependencies=None):
        kind, name = effect_id.split("/")
        directory = self.source / effect_id
        directory.mkdir(parents=True, exist_ok=True)
        include = ('[include]\nfiles = ' + json.dumps(["../../" + dep + "/effect.toml" for dep in dependencies]) + '\n') if dependencies else ''
        overlay = '\noverlay = "test-overlay"\n' if dependencies else ''
        (directory / "effect.toml").write_text(include + f'[effects.preset."{name}"]\nkind = "{kind}"\nshader = "shader.glsl"\n' + overlay)
        (directory / "shader.glsl").write_text(f'vec4 {kind}(vec2 uv) {{ return umbriel_sample(uv); }}\n')
        (directory / "README.md").write_text('Synthetic test notice\n')
        metadata = f'name = "{name}"\ndescription = "Test effect"\nauthor = "Test"\nlicense = "MIT"\nnotice_files = ["{effect_id}/README.md"]\nrole = "{role}"\n'
        if uses is not None:
            metadata += "uses = " + json.dumps(uses) + "\n"
        if features:
            metadata += '[requirements]\nfeatures = ' + json.dumps(features) + '\n'
        (directory / "metadata.toml").write_text(metadata)
        if recipe is None and kind != "animation" and role != "companion":
            recipe = f'[effects]\n{kind} = "{name}"\n'
        if recipe:
            (directory / "config.toml").write_text('[include]\nfiles = ' + json.dumps(["shaders/community/" + effect_id + "/effect.toml"]) + '\n' + recipe)
        return directory

    def add_family(self, members, recipe=None):
        directory = self.source / "families/test"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "family.toml").write_text('name = "Test family"\ndescription = "Coordinated tests"\nmembers = ' + json.dumps(members) + '\n')
        if recipe:
            (directory / "config.toml").write_text(recipe)

    def test_family_apply_is_one_transaction_and_one_undo(self):
        self.add_effect("border/test-border")
        self.add_effect("window/test-window")
        self.controller.choose(str(self.source), "window/test-window", "effects.window")
        previous = self.controller.state()["current"]
        self.peer.runtime = True
        self.peer.owners = [{"type": "window", "id": "window-1", "slots": {"border": {"name": "", "source": "default", "suppressed": True}}}]
        cursor = self.peer.report()["cursor"].copy()
        self.add_family(["cursor/glow", "border/test-border"])
        count = len(self.peer.switches)
        result = self.controller.choose_family(str(self.source), "test", {"effects.cursor": "cursor/glow", "effects.border": "border/test-border"})
        self.assertTrue(result["managed"])
        self.assertEqual(len(self.peer.switches), count + 1)
        self.assertEqual(self.controller.state()["current"]["selections"], {"effects.window": "window/test-window", "effects.cursor": "cursor/glow", "effects.border": "border/test-border"})
        self.controller.undo()
        self.assertEqual(self.controller.state()["current"], previous)
        self.assertEqual(self.peer.report()["cursor"], cursor)
        self.assertTrue(self.peer.report()["owners"][0]["slots"]["border"]["suppressed"])

    def test_family_keep_current_preserves_external_cursor(self):
        self.add_effect("border/test-border")
        self.add_family(["cursor/glow", "border/test-border"])
        self.peer.runtime = True
        previous = self.peer.report()["cursor"].copy()
        self.controller.choose_family(str(self.source), "test", {"effects.cursor": "", "effects.border": "border/test-border"})
        self.assertNotIn("effects.cursor", self.controller.state()["current"]["settings"])
        self.assertEqual(self.peer.report()["cursor"], previous)
        self.controller.restore()
        self.assertEqual(self.peer.report()["cursor"], previous)

    def test_family_rejects_missing_ambiguous_foreign_and_empty_choices(self):
        self.add_effect("cursor/second")
        self.add_effect("cursor/outsider")
        self.add_family(["cursor/glow", "cursor/second"])
        for choices in ({}, {"effects.cursor": None}, {"effects.cursor": "cursor/outsider"}, {"effects.cursor": ""}, {"effects.border": "cursor/glow"}):
            with self.subTest(choices=choices), self.assertRaises(h.Error):
                self.controller.choose_family(str(self.source), "test", choices)
        self.assertEqual(self.peer.switches, [])
        self.assertFalse((self.root / "state/library").exists())

    def test_family_does_not_select_companion_as_global_window_effect(self):
        self.add_effect("window/test-overlay", uses=["effects.window"], role="companion", recipe='[effects]\nwindow = "test-overlay"\n')
        self.add_effect("border/test-border", dependencies=["window/test-overlay"])
        self.add_family(["border/test-border", "window/test-overlay"])
        self.controller.choose_family(str(self.source), "test", {"effects.border": "border/test-border"})
        self.assertNotIn("effects.window", self.controller.state()["current"]["settings"])
        self.assertIn("test-overlay", self.controller.state()["current"]["presets"])

    def test_family_recommendations_apply_only_to_chosen_slots(self):
        self.add_effect("animation/open", uses=["animation.windows_in"], recipe='[animation]\nenabled = true\n[animation.windows_in]\neffect = "open"\nenabled = true\nduration_ms = 600\ncurve = "linear"\n')
        recipe = '[include]\nfiles = ["shaders/community/animation/open/effect.toml"]\n[animation]\nenabled = true\n[animation.windows_in]\neffect = "open"\nenabled = true\nduration_ms = 1300\ncurve = "linear"\n'
        self.add_family(["animation/open"], recipe)
        self.controller.choose_family(str(self.source), "test", {"animation.windows_in": "animation/open"})
        settings = self.controller.state()["current"]["settings"]
        self.assertEqual(settings["animation.windows_in.duration_ms"], 1300)
        self.assertNotIn("animation.windows_out.effect", settings)
        self.add_effect("border/test-border")
        self.controller.choose(str(self.source), "border/test-border", "effects.border")
        self.assertEqual(self.controller.state()["current"]["settings"]["animation.windows_in.duration_ms"], 1300)

    def test_family_partial_runtime_failure_rolls_back_all_slots(self):
        self.add_effect("border/test-border")
        self.add_family(["cursor/glow", "border/test-border"])
        self.peer.runtime = True
        self.peer.owners = [{"type": "window", "id": "window-1", "slots": {"border": {"name": "", "source": "default", "suppressed": True}}}]
        cursor = self.peer.report()["cursor"].copy()
        self.peer.fail_action = lambda command: command.startswith("effect-border-set:test-border")
        with self.assertRaisesRegex(h.Error, "previous configuration was restored"):
            self.controller.choose_family(str(self.source), "test", {"effects.cursor": "cursor/glow", "effects.border": "border/test-border"})
        self.assertEqual(self.peer.report()["cursor"], cursor)
        self.assertFalse(self.controller.status()["managed"])
        self.assertFalse(self.controller.pending_path.exists())

    def test_catalogue_browses_metadata_without_installing(self):
        self.add_effect("border/test-border")
        result = self.controller.catalogue(str(self.source))
        self.assertEqual(len(result["catalogue"]["effects"]), 2)
        self.assertEqual(result["catalogue"]["mode"], "local")
        self.assertFalse((self.root / "state/library").exists())
        self.assertEqual(self.peer.switches, [])

    def test_browser_exposes_validated_preview_paths_and_missing_fallback(self):
        preview = self.source / "cursor/glow/preview.png"
        preview.write_bytes(b"test image bytes")
        effect = self.controller.catalogue(str(self.source))["catalogue"]["effects"][0]
        self.assertEqual(effect["local_preview"]["image"], str(preview))
        self.assertIsNone(effect["local_preview"]["animation"])
        self.assertFalse((self.root / "state/library").exists())

    def test_browser_rejects_preview_symlinks(self):
        outside = self.root / "outside.png"
        outside.write_bytes(b"outside")
        (self.source / "cursor/glow/preview.png").symlink_to(outside)
        with self.assertRaisesRegex(h.Error, "symlinks"):
            self.controller.catalogue(str(self.source))

    def test_border_preserves_cursor_and_undo_restores_previous_selection(self):
        self.add_effect("border/test-border")
        self.apply_glow()
        plan = self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.assertEqual({item["key"] for item in plan["changes"]}, {"effects.cursor", "effects.border"})
        self.controller.apply(plan["plan_token"])
        state = self.controller.state()
        self.assertEqual(state["current"]["settings"], {"effects.cursor": "glow", "effects.border": "test-border"})
        self.controller.undo()
        self.assertEqual(self.controller.state()["current"]["settings"], {"effects.cursor": "glow"})
        self.controller.restore()
        self.assertEqual(self.base.read_bytes(), self.original)

    def test_multiuse_recipe_only_applies_chosen_event(self):
        recipe = '[animation]\nenabled = true\n[animation.windows_in]\neffect = "test-animation"\nduration_ms = 350\n[animation.windows_out]\neffect = "test-animation"\nduration_ms = 800\n'
        self.add_effect("animation/test-animation", uses=["animation.windows_in", "animation.windows_out"], recipe=recipe)
        self.base.write_text(self.base.read_text() + '[animation.windows_out]\nduration_ms = 120\n')
        plan = self.controller.prepare(str(self.source), "animation/test-animation", "animation.windows_in")
        keys = {change["key"] for change in plan["changes"]}
        self.assertIn("animation.windows_in.effect", keys)
        self.assertFalse(any(key.startswith("animation.windows_out") for key in keys))
        self.controller.apply(plan["plan_token"])
        self.assertEqual(self.controller.state()["current"]["selections"], {"animation.windows_in": "animation/test-animation"})

    def test_dependency_is_installed_without_selecting_its_slot(self):
        self.add_effect("window/test-overlay", role="companion")
        self.add_effect("border/test-border", dependencies=["window/test-overlay"])
        plan = self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.assertIn("test-overlay", plan["dependencies"])
        self.assertEqual([change["key"] for change in plan["changes"]], ["effects.border"])
        self.controller.apply(plan["plan_token"])
        self.assertTrue((self.root / "state/library/window/test-overlay/shader.glsl").exists())
        self.assertEqual(set(self.controller.state()["current"]["presets"]), {"test-border", "test-overlay"})

    def test_companion_without_uses_cannot_be_selected(self):
        self.add_effect("window/test-overlay", role="companion")
        with self.assertRaisesRegex(h.Error, "unsupported selection"):
            self.controller.prepare(str(self.source), "window/test-overlay", "effects.window")
        self.assertFalse((self.root / "state/library").exists())

    def test_unknown_capability_does_not_gate_apply(self):
        self.add_effect("cursor/test-cursor", features=["cursor-pointer-history"])
        plan = self.controller.prepare(str(self.source), "cursor/test-cursor", "effects.cursor")
        self.assertEqual(plan["compatibility"]["status"], "unknown")
        self.assertEqual(self.peer.switches, [])
        self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.report()["cursor"]["name"], "test-cursor")

    def test_known_missing_setting_blocks_review(self):
        self.add_effect("border/test-border")
        with patch.object(self.peer, "capabilities", return_value={"effects.cursor"}):
            with self.assertRaisesRegex(h.Error, "incompatible.*effects.border"):
                self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.assertEqual(self.peer.switches, [])

    def test_restart_retains_all_saved_slots_for_explicit_review(self):
        self.add_effect("border/test-border")
        self.apply_glow()
        plan = self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.controller.apply(plan["plan_token"])
        self.peer.active = str(self.base)
        self.peer.identity = {**self.peer.identity, "start": "456"}
        plan = self.controller.prepare(str(self.source))
        self.assertEqual(self.peer.active, str(self.base))
        self.assertEqual({c["key"] for c in plan["changes"]}, {"effects.border", "effects.cursor"})
        self.controller.apply(plan["plan_token"])
        self.controller.undo()
        self.assertEqual(self.peer.active, str(self.base))

    def test_legacy_glow_state_migrates_when_adding_another_slot(self):
        self.apply_glow()
        state = self.controller.state()
        for key in ("settings", "selections", "presets", "catalogue"):
            state["current"].pop(key)
        h.save_json(self.controller.state_path, state)
        self.add_effect("border/test-border")
        plan = self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.controller.apply(plan["plan_token"])
        self.assertEqual(self.controller.state()["current"]["settings"], {"effects.cursor": "glow", "effects.border": "test-border"})
        self.controller.undo()
        self.assertTrue(self.controller.status()["managed"])
        self.assertEqual(self.peer.report()["cursor"]["name"], "glow")
        self.controller.restore()
        self.assertEqual(self.peer.active, str(self.base))

    def test_source_version_change_cannot_mix_installed_versions(self):
        self.apply_glow()
        shader = self.source / "cursor/glow/shader.glsl"
        shader.write_bytes(shader.read_bytes() + b'// updated\n')
        self.add_effect("border/test-border")
        with self.assertRaisesRegex(h.Error, "changes installed shader versions"):
            self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.assertFalse((self.root / "state/library/border").exists())
        self.assertTrue(self.controller.status()["managed"])

    def test_local_border_keeps_its_custom_overlay_and_skips_catalogue_dependencies(self):
        self.add_effect("window/test-overlay", role="companion")
        self.add_effect("border/test-border", dependencies=["window/test-overlay"])
        shader = self.root / "local-border.glsl"
        shader.write_text('vec4 border(vec2 uv) { return vec4(1.0); }\n')
        overlay = self.root / "local-overlay.glsl"
        overlay.write_text('vec4 window(vec2 uv) { return vec4(0.5); }\n')
        self.base.write_text(self.base.read_text() + '[effects.preset.test-border]\nkind = "border"\n'
                             'shader = "local-border.glsl"\noverlay = "my-overlay"\npadding = 7\n'
                             '[effects.preset.my-overlay]\nkind = "window"\nshader = "local-overlay.glsl"\n')
        before = self.base.read_bytes()
        plan = self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.assertFalse((self.root / "state/library").exists())
        self.controller.apply(plan["plan_token"])
        self.assertEqual(set(self.controller.state()["current"]["presets"]), {"test-border", "my-overlay"})
        self.controller.restore()
        self.assertEqual(self.base.read_bytes(), before)

    def test_local_copy_is_not_blocked_by_unused_customised_plugin_install(self):
        self.controller.prepare(str(self.source))
        (self.root / "state/library/cursor/glow/shader.glsl").write_text('unused customised installed bytes')
        self.include_existing_glow()
        plan = self.controller.prepare(str(self.source))
        self.controller.apply(plan["plan_token"])
        self.controller.restore()
        self.assertEqual((self.root / "state/library/cursor/glow/shader.glsl").read_text(), 'unused customised installed bytes')

    def test_matching_dependency_in_base_is_reused_once(self):
        overlay = self.add_effect("window/test-overlay", role="companion")
        self.add_effect("border/test-border", dependencies=["window/test-overlay"])
        self.base.write_text(self.base.read_text() + '[include]\nfiles = ' + json.dumps([str(overlay / "effect.toml")]) + '\n')
        plan = self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.controller.apply(plan["plan_token"])
        wrapper = Path(self.peer.active).read_text()
        self.assertNotIn('[effects.preset."test-overlay"]', wrapper)
        self.assertIn('[effects.preset."test-border"]', wrapper)

    def test_selected_file_tampering_blocks_apply(self):
        self.add_effect("cursor/test-cursor", features=["cursor-pointer-history"])
        plan = self.controller.prepare(str(self.source), "cursor/test-cursor", "effects.cursor")
        (self.root / "state/library/cursor/test-cursor/shader.glsl").write_text('tampered')
        with self.assertRaisesRegex(h.Error, "File changed"):
            self.controller.apply(plan["plan_token"])
        self.assertEqual(self.peer.switches, [])

    def test_missing_recipe_is_manual_only(self):
        self.add_effect("animation/test-animation", uses=["animation.windows_in"])
        with self.assertRaisesRegex(h.Error, "manual configuration required"):
            self.controller.prepare(str(self.source), "animation/test-animation", "animation.windows_in")

    def test_shared_required_setting_conflict_blocks_review(self):
        directory = self.add_effect("border/test-border")
        metadata = directory / "metadata.toml"
        metadata.write_text(metadata.read_text() + '[required_settings]\n"animation.workspaces.style" = "reveal"\n')
        with self.assertRaisesRegex(h.Error, "Required base setting"):
            self.controller.prepare(str(self.source), "border/test-border", "effects.border")
        self.assertEqual(self.peer.switches, [])

    def test_border_override_and_suppression_restore_on_undo(self):
        self.add_effect("border/test-border")
        self.peer.owners = [{"type": "window", "id": "window-1", "slots": {"border": {"name": "old-border", "source": "runtime", "suppressed": True}}}]
        previous = h.runtime_slots(self.peer.report())
        self.controller.choose(str(self.source), "border/test-border", "effects.border")
        slot = self.peer.report()["owners"][0]["slots"]["border"]
        self.assertEqual(slot["name"], "test-border")
        self.assertFalse(slot["suppressed"])
        self.controller.undo()
        self.assertEqual(h.runtime_slots(self.peer.report()), previous)

    def test_runtime_pool_member_and_suppression_survive_restore(self):
        self.base.write_text(self.base.read_text() + '[effects.pool.cursors]\nkind = "cursor"\nchoose = ["first", "second"]\n')
        self.peer.runtime = {"name": "second", "pool": "cursors", "source": "runtime", "suppressed": True}
        previous = self.peer.report()["cursor"].copy()
        self.controller.choose(str(self.source), "cursor/glow", "effects.cursor")
        self.controller.restore()
        self.assertEqual(self.peer.report()["cursor"], previous)

    def test_runtime_failure_restores_partial_changes(self):
        self.add_effect("border/test-border")
        self.peer.owners = [{"type": "window", "id": name, "slots": {"border": {"name": "old-border", "source": "runtime"}}} for name in ("one", "two")]
        original = h.runtime_slots(self.peer.report())
        self.peer.fail_action = lambda action: action == "effect-border-set:test-border/two"
        with self.assertRaisesRegex(h.Error, "previous configuration was restored"):
            self.controller.choose(str(self.source), "border/test-border", "effects.border")
        self.assertEqual(h.runtime_slots(self.peer.report()), original)
        self.assertFalse(self.controller.pending_path.exists())

    def test_runtime_crash_recovery_restores_previous_override(self):
        self.peer.runtime = True
        previous = self.peer.report()["cursor"].copy()
        self.crash_after_switch()
        self.assertEqual(self.peer.report()["cursor"]["name"], "glow")
        self.controller.recover()
        self.assertEqual(self.peer.report()["cursor"], previous)

    def test_external_runtime_change_after_apply_is_left_alone_on_restore(self):
        self.controller.choose(str(self.source), "cursor/glow", "effects.cursor")
        self.peer.runtime = True
        previous = self.peer.report()["cursor"].copy()
        self.controller.restore()
        self.assertEqual(self.peer.report()["cursor"], previous)

    def test_applying_border_does_not_reset_an_external_cursor_change(self):
        self.controller.choose(str(self.source), "cursor/glow", "effects.cursor")
        self.peer.runtime = True
        previous = self.peer.report()["cursor"].copy()
        self.add_effect("border/test-border")
        self.controller.choose(str(self.source), "border/test-border", "effects.border")
        self.assertEqual(self.peer.report()["cursor"], previous)
        self.controller.undo()
        self.assertEqual(self.peer.report()["cursor"], previous)
        self.controller.restore()
        self.assertEqual(self.peer.report()["cursor"], previous)

    def test_closed_window_is_skipped_during_restore(self):
        self.add_effect("border/test-border")
        self.peer.owners = [{"type": "window", "id": "closed", "slots": {"border": {"name": "old", "source": "runtime"}}}]
        self.controller.choose(str(self.source), "border/test-border", "effects.border")
        self.peer.owners = []
        count = len(self.peer.messages)
        self.controller.restore()
        self.assertEqual(len(self.peer.messages), count)

    def test_choose_unknown_applies_in_one_operation(self):
        self.add_effect("cursor/test-cursor", features=["cursor-pointer-history"])
        result = self.controller.choose(str(self.source), "cursor/test-cursor", "effects.cursor")
        self.assertTrue(result["managed"])
        self.assertNotIn("plan_token", result)
        self.assertEqual(self.peer.report()["cursor"]["name"], "test-cursor")

    def test_apply_twice_undo_then_restore_recovers_original_runtime(self):
        self.peer.runtime = True
        original = self.peer.report()["cursor"].copy()
        self.add_effect("cursor/second-cursor")
        self.controller.choose(str(self.source), "cursor/glow", "effects.cursor")
        self.controller.choose(str(self.source), "cursor/second-cursor", "effects.cursor")
        self.controller.undo()
        self.assertEqual(self.peer.report()["cursor"]["name"], "glow")
        self.controller.restore()
        self.assertEqual(self.peer.report()["cursor"], original)

    def test_review_token_cannot_escape_state_directory(self):
        with self.assertRaisesRegex(h.Error, "Review a shader"):
            self.controller.apply("../../file")


if __name__ == "__main__":
    unittest.main()
