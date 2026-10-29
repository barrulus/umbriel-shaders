#!/usr/bin/env python3
"""Exercise real Apply/Undo in a disposable headless compositor, never the desktop.

Requires a local community shader checkout and Umbriel with a usable GLES device.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "umbriel-shaders/helper"))
spec = importlib.util.spec_from_file_location("helper", ROOT / "umbriel-shaders/helper/umbriel_shaders.py")
h = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--umbriel", default=shutil.which("umbriel"))
    parser.add_argument("--keep", action="store_true", help="retain temporary logs and configs for inspection")
    parser.add_argument("--host-smoke", action="store_true", help="also load the plugin in a private Noctalia and open its panel")
    parser.add_argument("--pointer-client", type=Path, help="optional Umbriel harness pointer-client for real panel clicks")
    parser.add_argument("--host-only", action="store_true", help="run just the panel/lifecycle checks")
    parser.add_argument("--size", choices=("1280x1024", "640x480"), default="1280x1024")
    args = parser.parse_args()
    args.source_root = args.source_root.resolve()
    root = Path(tempfile.mkdtemp(prefix="us-test-", dir="/tmp"))
    process = None
    log = None
    try:
        root.chmod(0o700)
        env = os.environ.copy()
        for key in ("DISPLAY", "WAYLAND_DISPLAY", "WAYLAND_SOCKET", "UMBRIEL_SOCKET", "NOCTALIA_SOCKET",
                    "DBUS_SESSION_BUS_ADDRESS", "WLR_DRM_DEVICES", "WLR_BACKENDS", "WLR_HEADLESS_OUTPUTS"):
            env.pop(key, None)
        env.update(XDG_RUNTIME_DIR=str(root), WAYLAND_DISPLAY="wayland-0",
                   UMBRIEL_SOCKET=str(root / "umbriel-wayland-0.sock"),
                   XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"),
                   XDG_CACHE_HOME=str(root / "cache"), WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1",
                   WLR_LIBINPUT_NO_DEVICES="1", WLR_RENDERER="gles2", LIBGL_ALWAYS_SOFTWARE="1")
        base = root / "base.toml"
        base.write_text('[general]\nautostart = []\nxwayland = false\nshow_cheatsheet = false\n'
                        '[effects]\ncursor = ""\nin_capture = true\n[animation]\nenabled = false\n'
                        f'[output.HEADLESS-1]\nmode = "{args.size}@60"\nworkspaces = 2\n')
        original = base.read_bytes()
        log = (root / "umbriel.log").open("w")

        def start():
            child = subprocess.Popen([args.umbriel, "-c", str(base)], env=env, stdin=subprocess.DEVNULL,
                                     stdout=log, stderr=log, start_new_session=True)
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                if child.poll() is not None:
                    raise RuntimeError("Headless Umbriel exited: " + (root / "umbriel.log").read_text()[-5000:])
                if Path(env["UMBRIEL_SOCKET"]).is_socket():
                    try:
                        peer = h.Peer(env["UMBRIEL_SOCKET"])
                        if peer.identity["pid"] == child.pid:
                            return child, peer
                    except (h.Error, OSError):
                        pass
                time.sleep(0.05)
            child.terminate()
            child.wait(timeout=5)
            raise RuntimeError("Headless compositor startup timed out.")

        process, peer = start()
        if args.host_only:
            results = host_smoke(root, env, base, peer, args.source_root, args.pointer_client, args.size)
            print(json.dumps({"passed": results, "directory": str(root), "retained": args.keep}, indent=2))
            return 0
        controller = h.Controller(root / "plugin", peer)
        results = []
        assert not controller.status()["managed"]
        plan = controller.prepare(str(args.source_root))
        assert not controller.status()["managed"]
        results.append("review leaves the base active")
        applied = controller.apply(plan["plan_token"])
        assert applied["managed"]
        results.append("apply switches the wrapper and verifies Glow GPU compilation")
        controller.undo()
        assert not controller.status()["managed"]
        results.append("undo restores the base")

        # A pre-existing copy must be reused, not included twice in the wrapper.
        existing_preset = args.source_root / "cursor/glow/effect.toml"
        base.write_text(base.read_text() + '\n[include]\nfiles = ' + json.dumps([str(existing_preset)]) + '\n')
        peer.validate(base)
        peer.request("config-replace", str(base))
        plan = controller.prepare(str(args.source_root))
        assert "using your local copy" in plan["message"]
        controller.apply(plan["plan_token"])
        active = h.load_json(controller.state_path)["current"]["config"]
        assert str(existing_preset) not in Path(active).read_text()
        controller.undo()
        assert any(p["name"] == "glow" for p in peer.request("effects")["presets"])
        results.append("matching existing Glow is reused, compiles, and survives undo without duplicate definitions")
        base.write_bytes(original)
        peer.request("config-replace", str(base))

        invalid_source = root / "invalid-source"
        for name in h.GLOW_FILES:
            destination = invalid_source / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.source_root / name, destination)
        shutil.copyfile(args.source_root / "docs/catalogue-examples/cursor/glow/metadata.toml", invalid_source / "cursor/glow/metadata.toml")
        shutil.copyfile(args.source_root / "cursor/glow/config.toml", invalid_source / "cursor/glow/config.toml")
        (invalid_source / "cursor/glow/shader.glsl").write_text("vec4 cursor(vec2 uv) { this_is_invalid; }\n")
        invalid_controller = h.Controller(root / "invalid-plugin", peer)
        invalid_plan = invalid_controller.prepare(str(invalid_source))
        try:
            invalid_controller.apply(invalid_plan["plan_token"])
        except h.Error as error:
            assert "previous configuration was restored" in str(error), str(error)
        else:
            raise AssertionError("Invalid GLSL was reported as a successful apply")
        assert not invalid_controller.status()["managed"] and not invalid_controller.pending_path.exists()
        results.append("real GLSL compilation failure restores the previous configuration")

        plan = controller.prepare(str(args.source_root))
        controller.apply(plan["plan_token"])
        base.write_text(base.read_text() + '\n[appearance]\nborder_width = 7\n')
        controller.restore()
        assert not controller.status()["managed"]
        assert "border_width = 7" in base.read_text()
        results.append("restore preserves edits to the base")
        base.write_bytes(original)

        # Simulate process loss after IPC acceptance and before local commit.
        plan = controller.prepare(str(args.source_root))
        save_json = h.save_json

        def crash(path, value):
            if Path(path) == controller.state_path:
                raise SystemExit("simulated helper termination")
            save_json(path, value)

        with patch.object(h, "save_json", side_effect=crash):
            try:
                controller.apply(plan["plan_token"])
            except SystemExit:
                pass
        assert controller.status()["pending"]
        h.Controller(root / "plugin", peer).recover()
        assert not controller.status()["pending"] and not controller.status()["managed"]
        results.append("interrupted commit recovers explicitly")

        plan = controller.prepare(str(args.source_root))
        controller.apply(plan["plan_token"])
        old_identity = peer.identity.copy()
        process.terminate()
        process.wait(timeout=10)
        process, peer = start()
        assert peer.identity != old_identity
        controller = h.Controller(root / "plugin", peer)
        assert not controller.status()["managed"]
        assert "restarted" in controller.status()["message"]
        plan = controller.prepare(str(args.source_root))
        controller.apply(plan["plan_token"])
        controller.restore()
        results.append("compositor restart leaves saved selection inactive until explicit reapply")
        assert base.read_bytes() == original
        results.append("original base bytes remain unchanged")
        catalogue = controller.catalogue(str(args.source_root))["catalogue"]
        assert len(catalogue["effects"]) >= 9
        for effect in catalogue["effects"]:
            for slot in effect["uses"]:
                print("Apply " + effect["id"] + " to " + slot, file=sys.stderr, flush=True)
                controller.choose(str(args.source_root), effect["id"], slot)
                assert controller.status()["managed"]
                controller.restore()
                assert not controller.status()["managed"]
        results.append("all catalogue effects apply, compile and restore through single-step Apply, including reveal")
        # Each family is one config transaction. Ambiguous slots are explicitly
        # selected here; the panel requires a choice instead of picking silently.
        from catalogue_client import LocalCatalogue
        family_catalogue = LocalCatalogue(str(args.source_root))
        for family in family_catalogue.registry["families"]:
            choices = {}
            for member in family["members"]:
                effect = family_catalogue.effects[member]
                if effect["role"] == "companion" or not effect["activation"]:
                    continue
                for slot in effect["uses"]:
                    choices.setdefault(slot, member)
            result = controller.choose_family(str(args.source_root), family["id"], choices)
            assert result["managed"], family["id"]
            assert controller.state()["current"]["selections"] == choices, family["id"]
            controller.undo()
            assert not controller.status()["managed"], family["id"]
        results.append("all ten families apply chosen uses atomically and Undo restores the base")

        # Every catalogue preset already exists with locally changed bytes/settings.
        # Reuse all of them without installing a second copy or adding definitions.
        from catalogue_client import LocalCatalogue, preset_lines
        local_catalogue = LocalCatalogue(str(args.source_root))
        local_root = root / "custom-local-shaders"
        local_files = {}
        local_config = original.decode()
        for effect in catalogue["effects"]:
            definition = local_catalogue.definition(effect["id"], local_root)
            shader_path = Path(definition["shader"])
            relative = shader_path.relative_to(local_root).as_posix()
            shader_path.parent.mkdir(parents=True, exist_ok=True)
            shader_path.write_bytes(local_catalogue.bytes(relative) + b'\n// User customisation retained.\n')
            local_files[str(shader_path)] = shader_path.read_bytes()
            if effect["kind"] == "border":
                definition["padding"] = definition.get("padding", 0) + 1
            elif effect["kind"] == "cursor":
                definition["radius"] = definition.get("radius", 0) + 1
            local_config += "\n" + "\n".join(preset_lines(effect["preset"], definition)) + "\n"
        base.write_text(local_config)
        peer.validate(base)
        peer.request("config-replace", str(base))
        local_controller = h.Controller(root / "local-reuse", peer)
        for effect in catalogue["effects"]:
            for slot in effect["uses"]:
                plan = local_controller.prepare(str(args.source_root), effect["id"], slot)
                assert "using your local copy" in plan["message"]
                entry = next(item for item in plan["local_copies"] if item["preset"] == effect["preset"])
                assert entry["matches_catalogue"] is False
                assert not (root / "local-reuse/library").exists()
                local_controller.apply(plan["plan_token"])
                active = Path(local_controller.state()["current"]["config"]).read_text()
                assert '[effects.preset.' + json.dumps(effect["preset"]) + ']' not in active
                local_controller.restore()
                assert base.read_text() == local_config
        assert all(Path(path).read_bytes() == raw for path, raw in local_files.items())
        results.append("all customised local presets are reused without importing replacements; local config and shader bytes stay unchanged")
        # Real mapped window with an existing, suppressed runtime border override.
        base.write_text(local_config + '\n[effects.pool.test-cursors]\nkind = "cursor"\nchoose = ["glow", "vampire-wake"]\n')
        peer.request("config-replace", str(base))
        window = subprocess.Popen(["foot", "--app-id=umbriel-shaders-test", "sleep", "120"], env=env,
                                  stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 10
            while True:
                windows = peer.request("windows")
                target = next((w["id"] for w in windows if w["app_id"] == "umbriel-shaders-test"), None)
                if target:
                    break
                assert time.monotonic() < deadline, "Test window did not map"
                time.sleep(0.05)
            peer.request("action", action="effect-border-set", effect="heartbeat", window=target)
            peer.request("action", action="effect-border-set", effect="off", window=target)
            original_border = next(o["slots"]["border"] for o in peer.request("effects")["owners"] if o.get("id") == target)
            runtime_controller = h.Controller(root / "runtime-plugin", peer)
            runtime_controller.choose(str(args.source_root), "border/flowering-vine", "effects.border")
            applied_border = next(o["slots"]["border"] for o in peer.request("effects")["owners"] if o.get("id") == target)
            assert applied_border["name"] == "flowering-vine" and not applied_border["suppressed"]
            runtime_controller.choose(str(args.source_root), "border/heartbeat", "effects.border")
            runtime_controller.undo()
            assert next(o["slots"]["border"] for o in peer.request("effects")["owners"] if o.get("id") == target)["name"] == "flowering-vine"
            runtime_controller.restore()
            assert next(o["slots"]["border"] for o in peer.request("effects")["owners"] if o.get("id") == target) == original_border
            peer.request("action", action="effect-cursor-set", effect="test-cursors")
            peer.request("action", action="effect-cursor-cycle", pool="test-cursors")
            peer.request("action", action="effect-cursor-set", effect="off")
            original_cursor = peer.request("effects")["cursor"]
            runtime_controller.choose(str(args.source_root), "cursor/glow", "effects.cursor")
            runtime_controller.restore()
            assert peer.request("effects")["cursor"] == original_cursor
            peer.request("action", action="effect-cursor-reset")
            for kind, target_field, target_value, before_id, chosen_id in (
                ("window", "window", target, "window/crt", "window/parchment"),
                ("screen", "output", "HEADLESS-1", "screen/vignette", "screen/midnight-fog"),
            ):
                catalogue_effects = local_catalogue.effects
                fields = {target_field: target_value}
                peer.request("action", action=f"effect-{kind}-set", effect=catalogue_effects[before_id]["preset"], **fields)
                peer.request("action", action=f"effect-{kind}-set", effect="off", **fields)
                def current_slot():
                    return next(record["value"] for record in h.runtime_slots(peer.request("effects")).values()
                                if record["kind"] == kind and record["target"] == target_value)
                previous = current_slot()
                runtime_controller.choose(str(args.source_root), chosen_id, f"effects.{kind}")
                assert current_slot()["name"] == catalogue_effects[chosen_id]["preset"]
                assert not current_slot()["suppressed"]
                runtime_controller.undo()
                assert current_slot() == previous
                peer.request("action", action=f"effect-{kind}-reset", **fields)
            results.append("typed window/output actions replace runtime overrides and Undo restores selection and suppression")
            results.append("one-step Apply replaces a real window runtime override; Undo/Restore recover its previous border and suppression, plus cursor pool/member state")
        finally:
            window.terminate()
            window.wait(timeout=5)
        base.write_bytes(original)
        peer.request("config-replace", str(base))

        cursor_plan = controller.prepare(str(args.source_root), "cursor/glow", "effects.cursor")
        controller.apply(cursor_plan["plan_token"])
        border_plan = controller.prepare(str(args.source_root), "border/flowering-vine", "effects.border")
        controller.apply(border_plan["plan_token"])
        assert controller.state()["current"]["settings"] == {"effects.cursor": "glow", "effects.border": "flowering-vine"}
        assert "flowering-vine-overlay" in controller.state()["current"]["presets"]
        controller.undo()
        assert controller.state()["current"]["settings"] == {"effects.cursor": "glow"}
        controller.restore()
        results.append("border and overlay dependencies preserve the cursor; Undo restores the prior selection")
        if args.host_smoke:
            results.extend(host_smoke(root, env, base, peer, args.source_root, args.pointer_client, args.size))
        print(json.dumps({"passed": results, "directory": str(root), "retained": args.keep}, indent=2))
        return 0
    finally:
        if process and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        if log:
            log.close()
        if not args.keep:
            shutil.rmtree(root)


def host_smoke(root, compositor_env, base, peer, source, pointer_client=None, size="1280x1024"):
    env = compositor_env.copy()
    env.update(HOME=str(root / "home"), XDG_DATA_HOME=str(root / "data"),
               NOCTALIA_CONFIG_HOME=str(root / "config"), NOCTALIA_STATE_HOME=str(root / "state"),
               NOCTALIA_DATA_HOME=str(root / "data"),
               DBUS_SYSTEM_BUS_ADDRESS="unix:path=" + str(root / "absent-system-bus"))
    Path(env["HOME"]).mkdir(exist_ok=True)
    # Keep the Open data folder test inside this private session.
    bin_dir = root / "test-bin"
    bin_dir.mkdir(exist_ok=True)
    opener = bin_dir / "xdg-open"
    opener.write_text("#!/usr/bin/env python3\nimport json, pathlib, sys\npathlib.Path(" + repr(str(root / "opened-folder.json")) + ").write_text(json.dumps(sys.argv[1:]))\n")
    opener.chmod(0o700)
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    config_dir = root / "config/noctalia"
    config_dir.mkdir(parents=True, exist_ok=True)
    key_file = root / "test-storage-key"
    key_file.write_text(os.urandom(32).hex() + "\n")
    key_file.chmod(0o600)
    (config_dir / "config.toml").write_text(
        '[storage]\nkey_source = "file"\nkey_file = ' + json.dumps(str(key_file)) + '\n'
        '[shell]\noffline_mode = true\ntelemetry_enabled = false\nsetup_wizard_enabled = false\n'
        'clipboard_enabled = false\n[plugins]\nenabled = ["barrulus/umbriel-shaders"]\nauto_update = "none"\n'
        '[[plugins.source]]\nname = "prototype"\nkind = "path"\nenabled = true\nlocation = '
        + json.dumps(str(ROOT)) + '\n[plugin_settings."barrulus/umbriel-shaders"]\nsource_root = '
        + json.dumps(str(source)) + '\nbase_config = ' + json.dumps(str(base)) + '\n')
    log_path = root / "noctalia.log"
    data = root / "state/noctalia/plugins/data/barrulus/umbriel-shaders"
    with log_path.open("w") as log:
        child = subprocess.Popen(["dbus-run-session", "--", "noctalia"], env=env,
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 20
            while not (data / "recovery.py").is_file():
                if child.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Private plugin host failed: " + log_path.read_text()[-6000:])
                time.sleep(0.1)

            def msg(*args):
                result = subprocess.run(["noctalia", "msg", *args], env=env, capture_output=True, text=True, timeout=5)
                if result.returncode:
                    raise RuntimeError(result.stderr + result.stdout)
                return result.stdout

            msg("panel-toggle", "barrulus/umbriel-shaders:shaders")
            time.sleep(0.5)
            msg("plugin", "barrulus/umbriel-shaders:manager", "all", "refresh")
            time.sleep(0.5)
            assert not (data / "library").exists(), "Opening the plugin unexpectedly installed shaders"
            subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel.png")], env=env, check=True, timeout=10)
            host_controller = h.Controller(data, peer, str(base))
            if pointer_client:
                def pointer(*commands):
                    subprocess.run([str(pointer_client), *size.split("x"), *map(str, commands)], env=env, check=True, timeout=10)
                def wait_for_operation(action):
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        path = data / "last-operation.json"
                        operation = h.load_json(path) if path.exists() else {}
                        if operation.get("action") == action and operation.get("outcome") != "running":
                            assert operation.get("outcome") == "succeeded", operation
                            # Helper completion precedes the async service callback
                            # and the next rendered frame containing enabled buttons.
                            pointer("pause", 200)
                            return
                        time.sleep(0.05)
                    raise AssertionError("Operation did not finish: " + action)
                large = size == "1280x1024"
                search_x, search_y = (500, 144) if large else (180, 110)
                card_x, card_y = (480, 250) if large else (180, 220)
                review_x, action_y = (890, 735) if large else (560, 425)
                apply_x = 880 if large else 560
                apply_y = 689 if large else 379
                restore_x, restore_y = (480, 735) if large else (160, 425)
                # The catalogue stays bounded on first open. Expand one page and
                # retain access to search across the entire catalogue.
                pointer("move", card_x, card_y, *sum((["notch", 1] for _ in range(100)), []), "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-more-before.png")], env=env, check=True, timeout=10)
                pointer("move", 620 if large else 300, 735 if large else 425, "click", 272, "pause", 300)
                pointer("move", card_x, card_y, *sum((["notch", 1] for _ in range(100)), []), "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-more-after.png")], env=env, check=True, timeout=10)
                # Filter the visual grid to the exact workspace effect that exposed
                # the overflowing review, then select its thumbnail.
                pointer("move", search_x, search_y, "click", 272,
                        "tap", 17, "tap", 30, "tap", 31, "tap", 35, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-filtered.png")], env=env, check=True, timeout=10)
                pointer("move", card_x, card_y, "click", 272, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-detail.png")], env=env, check=True, timeout=10)
                # Reveal must apply directly from the detail card, with no Review
                # or compatibility confirmation between the click and activation.
                pointer("move", apply_x, apply_y, "click", 272, "pause", 500)
                wait_for_operation("choose")
                deadline = time.monotonic() + 5
                while not host_controller.status()["managed"]:
                    if time.monotonic() > deadline:
                        raise RuntimeError("Single-click reveal Apply failed; inspect panel-detail.png")
                    time.sleep(0.05)
                assert host_controller.state()["current"]["selections"] == {"animation.workspaces": "animation/vampire-blood-wash"}
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-reveal-applied.png")], env=env, check=True, timeout=10)
                # Read diagnostics through the actual settings menu. Copy/export
                # and opening its data folder must not alter the applied state.
                before_diagnostics = host_controller.state_path.read_bytes()
                pointer("move", 876 if large else 556, 85 if large else 55, "click", 272, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-settings.png")], env=env, check=True, timeout=10)
                pointer("move", 600 if large else 280, 216 if large else 186, "click", 272, "pause", 700)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-diagnostics.png")], env=env, check=True, timeout=10)
                pointer("move", 600 if large else 280, 142 if large else 108, "click", 272, "pause", 200)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-diagnostic-sections.png")], env=env, check=True, timeout=10)
                pointer("move", 600 if large else 280, 254 if large else 220, "click", 272, "pause", 200)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-diagnostic-config.png")], env=env, check=True, timeout=10)
                pointer("move", 400 if large else 80, restore_y, "click", 272, "pause", 200)
                copied = subprocess.run(["wl-paste", "--no-newline"], env=env, capture_output=True, text=True, timeout=5)
                assert copied.returncode == 0 and "Umbriel Shaders diagnostic report" in copied.stdout, "Copy diagnostics button failed"
                assert "animation/vampire-blood-wash" in copied.stdout
                assert "GPU compilation: passed" in copied.stdout
                (root / "copied-diagnostics.txt").write_text(copied.stdout)
                pointer("move", 550 if large else 230, restore_y, "click", 272, "pause", 300)
                assert json.loads((root / "opened-folder.json").read_text()) == [str(data)]
                assert host_controller.state_path.read_bytes() == before_diagnostics
                pointer("move", 370 if large else 50, 85 if large else 55, "click", 272, "pause", 200)
                pointer("move", 370 if large else 50, 85 if large else 55, "click", 272, "pause", 200)
                pointer("move", restore_x, restore_y, "click", 272, "pause", 500)
                wait_for_operation("restore")
                deadline = time.monotonic() + 5
                while host_controller.status()["managed"]:
                    if time.monotonic() > deadline:
                        raise RuntimeError("Panel Restore original click failed")
                    time.sleep(0.05)
                # Review remains optional and does not switch the configuration.
                pointer("move", review_x, action_y, "click", 272, "pause", 500)
                assert not host_controller.status()["managed"]
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-review.png")], env=env, check=True, timeout=10)
                pointer("move", apply_x, apply_y, "click", 272, "pause", 500)
                wait_for_operation("apply")
                assert host_controller.status()["managed"]
                pointer("move", restore_x, restore_y, "click", 272, "pause", 500)
                wait_for_operation("restore")
                assert not host_controller.status()["managed"]
                pointer("move", 370 if large else 50, 85 if large else 55, "click", 272, "pause", 200)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-back.png")], env=env, check=True, timeout=10)
                pointer("move", search_x, search_y, "click", 272, "mod", "control", "tap", 30, "mod", "none",
                        "tap", 47, "tap", 23, "tap", 49, "tap", 18, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-vine-filter.png")], env=env, check=True, timeout=10)
                pointer("move", card_x, card_y, "click", 272, "pause", 200)
                pointer("move", apply_x, apply_y, "click", 272, "pause", 500)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-direct-apply.png")], env=env, check=True, timeout=10)
                wait_for_operation("choose")
                deadline = time.monotonic() + 5
                while not host_controller.status()["managed"]:
                    assert time.monotonic() < deadline, "Single-click Flowering Vine Apply failed"
                    time.sleep(0.05)
                assert host_controller.state()["current"]["settings"]["effects.border"] == "flowering-vine"
                pointer("move", restore_x, restore_y, "click", 272, "pause", 500)
                wait_for_operation("restore")
                assert not host_controller.status()["managed"]
                # Families are a browsing view, never a request to apply every member.
                pointer("move", 370 if large else 50, 85 if large else 55, "click", 272, "pause", 200)
                pointer("move", 760 if large else 445, 85 if large else 55, "click", 272, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-families.png")], env=env, check=True, timeout=10)
                pointer("move", search_x, search_y, "click", 272,
                        "tap", 47, "tap", 30, "tap", 50, "tap", 25, "tap", 23, "tap", 19, "tap", 18, "pause", 300)
                pointer("move", card_x, card_y, "click", 272, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-family-vampire.png")], env=env, check=True, timeout=10)
                assert not host_controller.status()["managed"]
                pointer("move", 880 if large else 550, apply_y, "click", 272, "pause", 900)
                wait_for_operation("choose-family")
                deadline = time.monotonic() + 5
                while not host_controller.status()["managed"]:
                    assert time.monotonic() < deadline, "Apply family failed"
                    time.sleep(0.05)
                expected = {"animation.workspaces": "animation/vampire-blood-wash", "animation.windows_in": "animation/blood-in", "animation.windows_out": "animation/blood-out", "effects.border": "border/heartbeat", "effects.cursor": "cursor/vampire-wake"}
                assert host_controller.state()["current"]["selections"] == expected
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-family-applied.png")], env=env, check=True, timeout=10)
                # One Undo restores the entire family, not just its final member.
                pointer("move", 380 if large else 65, restore_y, "click", 272, "pause", 500)
                wait_for_operation("undo")
                assert not host_controller.status()["managed"]
                pointer("move", 880 if large else 550, apply_y, "click", 272, "pause", 900)
                wait_for_operation("choose-family")
                assert host_controller.status()["managed"]
                pointer("move", restore_x, restore_y, "click", 272, "pause", 500)
                wait_for_operation("restore")
                assert not host_controller.status()["managed"]
                pointer("move", 370 if large else 50, 85 if large else 55, "click", 272, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-family-return.png")], env=env, check=True, timeout=10)
                # Ghostly Tear has three alternative cursor effects.
                # Its family page must expose choices instead of silently picking.
                pointer("move", search_x, search_y, "click", 272, "mod", "control", "tap", 30, "mod", "none",
                        "tap", 34, "tap", 35, "tap", 24, "tap", 31, "tap", 20, "pause", 300)
                pointer("move", card_x, card_y, "click", 272, "pause", 300)
                subprocess.run(["grim", "-o", "HEADLESS-1", str(root / "panel-family-alternatives.png")], env=env, check=True, timeout=10)
                pointer("move", 880 if large else 550, apply_y, "click", 272, "pause", 300)
                assert not host_controller.status()["managed"], "Ambiguous family applied without choices"

            review = host_controller.prepare(str(source))
            host_controller.apply(review["plan_token"])
            msg("plugins", "disable", "barrulus/umbriel-shaders")
            deadline = time.monotonic() + 10
            while host_controller.status()["managed"]:
                if time.monotonic() > deadline:
                    raise RuntimeError("Plugin disable did not restore the base: " + log_path.read_text()[-6000:])
                time.sleep(0.1)
            return ([f"Expanded shader browsing, search, one-click reveal and border Apply, Details, family browsing, Apply family, whole-family Undo and Restore, diagnostics copy and data-folder actions passed at {size}"] if pointer_client else []) + ["Noctalia loaded the service and panel without installing shaders on open",
                    "plugin disable restored its active wrapper through the persistent recovery helper"]
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()


if __name__ == "__main__":
    sys.exit(main())
