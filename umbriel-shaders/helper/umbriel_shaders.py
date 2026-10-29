#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Barrulus
"""Local catalogue Apply/Undo client. No networking or automatic startup apply.

Python 3.11+, Linux, and Umbriel. JSON stdout is the service interface.
The original configuration is never written. Every switch has a durable journal.
"""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid


MARKER = "umbriel-shaders-generation-"
MANAGED = "# Managed by Umbriel Shaders; edit the original base configuration."
LIMIT = 2 * 1024 * 1024
GLOW_FILES = ("cursor/glow/effect.toml", "cursor/glow/shader.glsl",
              "cursor/glow/README.md", "LICENSES/Noctalia-MIT.txt")


class Error(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Error(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path, limit=LIMIT):
    path = Path(path)
    require(path.is_file(), f"Not a regular file: {path}")
    require(path.stat().st_size <= limit, f"File exceeds {limit} bytes: {path}")
    with path.open("rb") as stream:
        raw = stream.read(limit + 1)
    require(len(raw) <= limit, f"File exceeds {limit} bytes: {path}")
    return raw


def atomic(path, raw):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(raw)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        temporary = None
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def save_json(path, value):
    atomic(path, (json.dumps(value, sort_keys=True, indent=2) + "\n").encode())


def load_json(path):
    return json.loads(read(path))


def fingerprint(path):
    path = Path(path)
    if not path.exists():
        return None
    return {"resolved": str(path.resolve()), "sha256": digest(read(path))}


def verify(records):
    for path, expected in records.items():
        require(fingerprint(path) == expected, f"File changed; review again: {path}")


def peer_identity(pid, socket_path):
    proc = Path("/proc") / str(pid)
    fields = (proc / "stat").read_text().rsplit(")", 1)[1].split()
    return {"socket": str(socket_path), "pid": pid, "start": fields[19],
            "boot": Path("/proc/sys/kernel/random/boot_id").read_text().strip()}


class Peer:
    """Bind every IPC request to one authenticated, same-user compositor process."""

    def __init__(self, path=None):
        if path is None:
            path = os.environ.get("UMBRIEL_SOCKET")
            if not path:
                runtime = os.environ.get("XDG_RUNTIME_DIR")
                display = os.environ.get("WAYLAND_DISPLAY")
                require(runtime and display and "/" not in display, "Cannot identify this Umbriel session; set UMBRIEL_SOCKET.")
                path = str(Path(runtime) / f"umbriel-{display}.sock")
        self.path = Path(path)
        require(self.path.is_absolute(), "The Umbriel socket path must be absolute.")
        self.identity = None
        self.request("effects")
        proc = Path("/proc") / str(self.identity["pid"])
        self.executable = str((proc / "exe").resolve())
        require(Path(self.executable).name in {"umbriel", ".umbriel-wrapped"},
                "The socket peer is not an Umbriel executable.")
        self.argv = (proc / "cmdline").read_bytes().decode().rstrip("\0").split("\0")
        self.cwd = str((proc / "cwd").resolve())
        self.environ = dict(item.split("=", 1) for item in (proc / "environ").read_bytes().decode().split("\0") if "=" in item)

    def request(self, command, *arguments, **fields):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(str(self.path))
            pid, uid, _ = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
            require(uid == os.getuid(), "The Umbriel socket belongs to another user.")
            identity = peer_identity(pid, self.path)
            require(self.identity is None or identity == self.identity, "Umbriel restarted or the session changed; review again.")
            self.identity = identity
            payload = {"cmd": command, **fields}
            if arguments:
                payload["args"] = list(arguments)
            connection.sendall((json.dumps(payload) + "\n").encode())
            response = b""
            while b"\n" not in response:
                chunk = connection.recv(65536)
                require(bool(chunk), "Umbriel disconnected before acknowledging the command.")
                response += chunk
                require(len(response) <= LIMIT, "Umbriel response exceeds the size limit.")
            value = json.loads(response.split(b"\n", 1)[0])
            require(isinstance(value, dict), "Invalid Umbriel reply.")
            require("ok" in value, str(value.get("err", "Invalid Umbriel reply")))
            return value["ok"]

    def run(self, *args):
        result = subprocess.run([self.executable, *args], env=self.environ, cwd=self.cwd,
                                capture_output=True, text=True, timeout=20)
        require(result.returncode == 0, (result.stderr or result.stdout).strip() or "Umbriel validation failed.")
        return result.stdout

    def validate(self, path):
        self.run("config", "validate", "-c", str(path))

    def capabilities(self):
        schema = json.loads(self.run("config", "schema", "--json"))
        keys = {entry["path"] for entry in schema["options"]}
        require({"effects.cursor", "effects.preset.<name>.kind", "effects.preset.<name>.radius"} <= keys,
                "This Umbriel build lacks the required cursor preset interface.")
        help_text = self.run("config-replace", "--help")
        require("config-replace" in help_text, "This Umbriel build does not expose config-replace.")
        return keys


def expand(value, base, environ):
    require(isinstance(value, str) and "\0" not in value, "Invalid include path.")
    def substitute(match):
        return environ.get(match.group(1) or match.group(2), "")
    value = re.sub(r"\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*)", substitute, value)
    if value == "~" or value.startswith("~/"):
        value = environ.get("HOME", "~") + value[1:]
    return Path(os.path.abspath(Path(base) / value))


def discover_base(peer):
    explicit = None
    for index, argument in enumerate(peer.argv[:-1]):
        if argument == "-c":
            explicit = peer.argv[index + 1]
    if explicit:
        return str(expand(explicit, peer.cwd, peer.environ))
    env = peer.environ
    home = env.get("XDG_CONFIG_HOME") or str(Path(env.get("HOME", peer.cwd)) / ".config")
    candidates = [Path(home) / "umbriel/config.toml"]
    candidates += [Path(p) / "umbriel/config.toml" for p in env.get("XDG_CONFIG_DIRS", "/etc/xdg").split(":") if p]
    candidates.append(Path(peer.executable).parent.parent / "share/umbriel/config.toml")
    for path in candidates:
        if path.exists():
            return str(path.absolute())
    raise Error("Base configuration could not be discovered; choose its absolute path in plugin settings.")


def config_graph(base, environ):
    """Inspect includes without rewriting user TOML; retain symlink paths and missing optional files."""
    records, presets, pools, visited, settings = {}, {}, set(), set(), {}
    has_drm = False

    def visit(path, optional=False, depth=0):
        nonlocal has_drm
        require(depth < 32 and len(records) < 256, "Configuration include graph exceeds prototype limits.")
        path = Path(path).absolute()
        records[str(path)] = fingerprint(path)
        if records[str(path)] is None and optional:
            return
        require(records[str(path)] is not None, f"Missing configuration include: {path}")
        resolved = path.resolve()
        require(resolved not in visited, f"Duplicate or cyclic config include requires review: {path}")
        visited.add(resolved)
        raw = read(path).decode()
        require(not raw.startswith(MANAGED), "A plugin wrapper cannot be used as the base configuration.")
        data = tomllib.loads(raw)
        has_drm = has_drm or "drm" in data
        includes = data.get("include", {})
        require(isinstance(includes, dict), f"Invalid include table: {path}")
        for optional_flag, group in ((False, includes), (True, includes.get("optional", {}))):
            require(isinstance(group, dict) and isinstance(group.get("files", []), list), f"Invalid include list: {path}")
            for name in group.get("files", []):
                visit(expand(name, path.parent, environ), optional_flag, depth + 1)
        def flatten(value, prefix):
            for key, item in value.items():
                full = prefix + "." + key
                if isinstance(item, dict):
                    flatten(item, full)
                else:
                    settings[full] = item
        for section in ("effects", "animation"):
            flatten(data.get(section, {}), section)
        effects = data.get("effects", {})
        for name, preset in effects.get("preset", {}).items():
            require(name not in presets and not name.startswith(MARKER), f"Conflicting or managed preset in base: {name}")
            presets[name] = {"definition": preset, "config": str(path), "shader": None}
            if isinstance(preset, dict) and isinstance(preset.get("shader"), str):
                shader = expand(preset["shader"], path.parent, environ)
                records[str(shader)] = fingerprint(shader)
                presets[name]["shader"] = str(shader)
        pools.update(effects.get("pool", {}))

    visit(base)
    return {"files": records, "presets": presets, "pools": sorted(pools), "settings": settings, "drm": has_drm}


def runtime_slots(report):
    slots = {}

    def add(owner, target, kind, value):
        if not isinstance(value, dict):
            return
        key = json.dumps([owner, target, kind])
        slots[key] = {"owner": owner, "target": target, "kind": kind,
                      "value": {"name": value.get("name", ""), "pool": value.get("pool", ""),
                                "source": value.get("source", "default"), "suppressed": value.get("suppressed", False)}}

    add("cursor", "", "cursor", report.get("cursor"))
    for owner in report.get("owners", []):
        target = owner.get("id") if owner.get("type") == "window" else owner.get("name")
        if not target:
            continue  # Never fall back to whichever window happens to be focused.
        for kind, value in owner.get("slots", {}).items():
            add(owner["type"], target, kind, value)
    return slots


def selection_report(report):
    """Stable selections, including suppression and pool identity; omit compile state."""
    return {"cursor": report.get("cursor"),
            "runtime": {key: slot for key, slot in runtime_slots(report).items()
                        if slot["value"]["source"] == "runtime" or slot["value"]["suppressed"]},
            "presets": sorted((p["name"], p["kind"]) for p in report.get("presets", []))}


def markers(report):
    return {p["name"] for p in report.get("presets", []) if p["name"].startswith(MARKER)}


def empty_state(base=None, session=None):
    return {"schema_version": 1, "base": base, "session": session, "current": None, "undo": []}


def diagnostic_report(directory, peer=None, *, base=None, source=None, live_error=None):
    """Read saved and live evidence without validating, installing or switching configs."""
    root = Path(directory).absolute()
    issues = []
    sections = []

    def text(value, limit=2000):
        value = str(value)
        return value if len(value) <= limit else value[:limit] + "… [truncated]"

    def section(title, lines):
        sections.append({"title": title, "text": text("\n".join(lines), 24000)})

    def document(name):
        path = root / name
        if not path.exists():
            return {}
        try:
            value = load_json(path)
            require(isinstance(value, dict), f"{name}: expected an object")
            return value
        except (Error, OSError, ValueError) as error:
            issues.append(f"{name}: {text(error)}")
            return {}

    state = document("state.json")
    current = state.get("current") or {}
    if not isinstance(current, dict):
        issues.append("state.json: invalid current selection")
        current = {}
    if state and state.get("schema_version") != 1:
        issues.append("state.json: unsupported schema version")
    pending = document("pending.json")
    pending_exists = (root / "pending.json").exists()
    operation = document("last-operation.json")
    live = None
    if peer is not None:
        try:
            live = peer.request("effects")
            require(isinstance(live, dict), "Invalid live effects response")
        except (Error, OSError, ValueError) as error:
            live_error = text(error)
            live = None
    if live_error:
        issues.append("Live Umbriel state unavailable: " + text(live_error))
    managed = bool(live is not None and isinstance(current.get("marker"), str) and current["marker"]
                   and state.get("session") == peer.identity
                   and markers(live) == {current["marker"]})
    if live is None:
        ownership = "Live state unavailable; active configuration cannot be confirmed."
    elif managed:
        ownership = "The saved managed configuration is active (generation marker matches)."
    elif current and state.get("session") != peer.identity:
        ownership = "Saved selection belongs to a previous or different Umbriel session; ownership cannot be confirmed here."
    elif current:
        ownership = "The active configuration differs from the saved plugin generation."
    else:
        ownership = "No saved plugin selection. Umbriel does not expose its active configuration path."
    original = base or state.get("base")
    if not original and peer is not None:
        try:
            original = discover_base(peer)
        except (Error, OSError, ValueError) as error:
            issues.append(text(error))
    if original is not None and not isinstance(original, str):
        issues.append("Invalid original configuration path in saved state")
        original = None
    original_lines = ["Original configuration: " + (original or "Not configured or discoverable.")]
    if base and state.get("base") and base != state["base"]:
        original_lines.append("Saved selection used a different base: " + text(state["base"]))
    if original:
        try:
            graph = config_graph(original, peer.environ if peer is not None else os.environ)
            original_lines += ["", "Original configuration and referenced files (current disk contents):"]
            for path, entry in list(graph["files"].items())[:100]:
                original_lines.append(text(path) + (" — missing optional/reference file" if entry is None else ""))
                if entry and entry["resolved"] != path:
                    original_lines.append("  Resolves to: " + text(entry["resolved"]))
            if len(graph["files"]) > 100:
                original_lines.append("[File list truncated to 100 entries]")
        except (Error, OSError, ValueError, TypeError, KeyError, AttributeError) as error:
            issues.append("Original configuration inspection failed: " + text(error))
            original_lines.append(text(error))
    original_lines += ["", "Base contents and environment variables are not included in the copied report.",
                       "The plugin does not edit these files. Startup discovery cannot detect an earlier external config-replace."]

    wrapper_lines = ["Managed configuration: " + text(current.get("config", "None saved.")), ownership]
    if current.get("config"):
        try:
            path = Path(current["config"])
            require(path.is_absolute() and path.resolve().is_relative_to((root / "generations").resolve()),
                    "Saved managed configuration is outside the plugin generations directory")
            raw = read(path, 256 * 1024).decode("utf-8")
            wrapper_lines += ["", "Generated TOML (read-only):", raw]
            expected = (current.get("files") or {}).get(str(path))
            if expected and fingerprint(path) != expected:
                issues.append("The managed configuration on disk has changed since Apply; displayed TOML may differ from what was loaded.")
        except (Error, OSError, ValueError, TypeError, AttributeError) as error:
            issues.append("Managed configuration unavailable: " + text(error))
            wrapper_lines.append(text(error))
    selections = current.get("selections", {})
    settings = current.get("settings", {})
    saved_lines = ["Saved selections (intent, not a live-state query):"]
    for label, values in (("Catalogue selections", selections), ("Managed settings", settings)):
        saved_lines += ["", label + ":"]
        if isinstance(values, dict):
            saved_lines += [text(key, 200) + " = " + text(json.dumps(value, ensure_ascii=False), 600)
                            for key, value in sorted(values.items())[:100]] or ["None saved."]
            if len(values) > 100:
                saved_lines.append("[List truncated to 100 entries]")
        else:
            saved_lines.append("Invalid saved data.")
            issues.append("Invalid " + label.lower() + " in state.json")
    saved_lines += ["", "Automatic restoration across sessions is not implemented yet."]

    live_lines = [ownership]
    if live is not None:
        live_lines += ["", "Live effects by target:"]
        slots = runtime_slots(live)
        tracked = state.get("runtime_current") or {}
        for key, slot in list(slots.items())[:100]:
            value = slot["value"]
            line = (f"{slot['owner']} {slot['target']} · {slot['kind']}: "
                    f"{value['name'] or '(none)'} · source={value['source']}"
                    + (f" · pool={value['pool']}" if value['pool'] else "")
                    + (" · suppressed" if value['suppressed'] else ""))
            if managed and isinstance(tracked, dict) and key in tracked and slot != tracked[key]:
                line += " · changed since plugin Apply"
            live_lines.append(text(line))
        if len(slots) > 100:
            live_lines.append("[Target list truncated to 100 entries]")
        live_lines += ["", "Loaded shader compilation states:"]
        presets = [p for p in live.get("presets", []) if not p.get("name", "").startswith(MARKER)]
        for preset in presets[:200]:
            live_lines.append(text(f"{preset.get('name')} ({preset.get('kind')}): {preset.get('state', 'unknown')}", 500))
        if len(presets) > 200:
            live_lines.append("[Preset list truncated to 200 entries]")
        live_lines += ["", "Animation defaults are shown under Saved selections; Umbriel does not expose them in the live effects query.",
                       "Compilation states are runtime observations, not a visual-quality check."]
    else:
        live_lines.append(text(live_error or "Umbriel is unavailable."))

    operation_lines = []
    if operation:
        for key in ("action", "started", "finished", "outcome", "message"):
            if key in operation:
                operation_lines.append(key.capitalize() + ": " + text(operation[key]))
        latest_phases = {}
        for event in operation.get("events", [])[:24] if isinstance(operation.get("events", []), list) else []:
            if isinstance(event, dict):
                latest_phases[str(event.get("phase"))] = event
        for event in latest_phases.values():
            operation_lines.append(text(f"{event.get('phase')}: {event.get('outcome')}" +
                                        (" — " + str(event['detail']) if event.get('detail') else "")))
        if operation.get("outcome") == "running":
            operation_lines.append("This operation did not record completion; it may still be running or have been interrupted.")
    else:
        operation_lines.append("No operation recorded yet. New Apply, Review, Undo, Restore and Recover operations will appear here.")
    operation_lines += ["", "Recovery journal: " + ("Present — recovery may be required." if pending_exists else "None.")]
    if pending:
        operation_lines.append("Journal session: " + text(pending.get("session", "Unknown")))

    generated = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())
    overview = ["Umbriel Shaders diagnostic report", "Captured: " + generated, ownership,
                "Plugin data: " + str(root), "Catalogue checkout: " + text(source or "Not supplied"),
                "Umbriel executable: " + text(getattr(peer, "executable", "Unavailable")),
                "", "Automatic cross-session restore: not implemented.",
                "Recovery journal: " + ("present" if pending_exists else "none"),
                "", "Inspection issues:", *(issues or ["None detected."]),
                "", "This report includes local file paths, generated TOML and shader selections. It excludes original config contents, environment values and window app IDs."]
    section("Overview", overview)
    section("Original configuration", original_lines)
    section("Managed configuration", wrapper_lines)
    section("Saved selections", saved_lines)
    section("Live state", live_lines)
    section("Last operation", operation_lines)
    report_text = "\n\n".join(s["title"] + "\n" + s["text"] for s in sections)
    return {"generated": generated, "managed": managed, "pending": pending_exists,
            "issues": issues, "sections": sections, "report_text": report_text}


class Controller:
    def __init__(self, directory, peer, base=None):
        self.root = Path(directory).absolute()
        require(not self.root.is_symlink(), "The plugin data directory cannot be a symlink.")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        require(self.root.stat().st_uid == os.getuid(), "Plugin data must belong to the current user.")
        self.root.chmod(0o700)
        self.peer = peer
        self.base_override = base
        self.state_path = self.root / "state.json"
        self.pending_path = self.root / "pending.json"
        self.operation = None

    def save_operation(self):
        if self.operation is not None:
            try:
                save_json(self.root / "last-operation.json", self.operation)
            except OSError:
                # Diagnostic logging must never turn a successful switch into
                # a failure or interfere with the durable recovery journal.
                pass

    def phase(self, name, outcome, detail=None):
        if self.operation is not None:
            self.operation["events"].append({"phase": name, "outcome": outcome,
                                             "detail": str(detail)[:2000] if detail else None})
            self.operation["events"] = self.operation["events"][-24:]
            self.save_operation()

    def fail_phase(self, error):
        if self.operation and self.operation["events"]:
            last = self.operation["events"][-1]
            if last["outcome"] == "running":
                self.phase(last["phase"], "failed", error)

    def perform(self, action, task):
        if action not in {"prepare", "choose", "choose-family", "apply", "undo", "restore", "recover"}:
            return task()
        self.operation = {"action": action, "started": time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()),
                          "outcome": "running", "events": []}
        self.save_operation()
        try:
            result = task()
        except Exception as error:
            self.fail_phase(error)
            self.operation.update(outcome="failed", message=str(error)[:4000],
                                  finished=time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()))
            self.save_operation()
            self.operation = None
            raise
        self.operation.update(outcome="succeeded", message=result.get("message", "Completed."),
                              finished=time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()))
        self.save_operation()
        self.operation = None
        return result

    @contextlib.contextmanager
    def locked(self):
        with (self.root / "operation.lock").open("a") as lock:
            deadline = time.monotonic() + 12
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    require(time.monotonic() < deadline, "Another shader operation is still running; try again.")
                    time.sleep(0.05)
            try:
                yield
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)

    def state(self):
        value = load_json(self.state_path) if self.state_path.exists() else empty_state()
        require(value.get("schema_version") == 1, "Unsupported local state; keep the files for recovery.")
        return value

    def owned(self, state, report):
        return (state["session"] == self.peer.identity and state["current"] is not None
                and markers(report) == {state["current"]["marker"]})

    def status(self):
        state = self.state()
        report = self.peer.request("effects")
        owned = self.owned(state, report)
        pending = self.pending_path.exists()
        other_session = state["session"] and state["session"]["socket"] != self.peer.identity["socket"]
        if other_session:
            message = "This prototype's saved state belongs to another compositor socket; it has been left unchanged."
        elif pending:
            message = "An operation was interrupted. Recover before applying another selection."
        elif owned:
            message = "Your shader selections are managed by Umbriel Shaders."
        elif state["current"] and state["session"] != self.peer.identity:
            message = "Umbriel restarted. Review and apply to restore your saved selections."
        elif state["current"]:
            message = "The active configuration changed outside the plugin. It has been left alone."
        else:
            message = "Choose a shader and review its changes. Browsing does not apply effects."
        try:
            base = self.base_override or state["base"] or discover_base(self.peer)
        except Error:
            base = None
        return {"message": message, "managed": owned, "pending": pending, "base": base,
                "cursor": report.get("cursor", {}).get("name", ""), "can_undo": owned and bool(state["undo"]),
                "can_restore": owned, "session": self.peer.identity,
                "selections": (state["current"].get("selections", {"effects.cursor": "cursor/glow"})
                               if state["current"] else {})}

    def catalogue(self, source):
        from catalogue_client import LocalCatalogue
        try:
            return {**self.status(), **LocalCatalogue(source).browse()}
        except ValueError as error:
            raise Error(str(error)) from error

    def install_selection(self, catalogue, selected):
        manifest_path = self.root / "library.json"
        installed = load_json(manifest_path) if manifest_path.exists() else {}
        for name, expected in installed.items():
            require(digest(read(self.root / "library" / name)) == expected,
                    "Installed shader files were customised; they will not be overwritten.")
            require(name in catalogue.registry["files"] and catalogue.registry["files"][name]["sha256"] == expected,
                    "The local catalogue changes installed shader versions. Library updates are not implemented yet.")
        for name in selected:
            raw = catalogue.bytes(name)
            destination = self.root / "library" / name
            require(not destination.exists() or read(destination) == raw, "Unrecorded local shader files need review.")
            if name not in installed:
                atomic(destination, raw)
            installed[name] = digest(raw)
        save_json(manifest_path, installed)
        return {str(self.root / "library" / name): fingerprint(self.root / "library" / name) for name in selected}

    def prepare(self, source, effect_id="cursor/glow", slot="effects.cursor", *, family_id=None, choices=None):
        from catalogue_client import LocalCatalogue, equivalent, setting_lines, preset_lines
        require(not self.pending_path.exists(), "Recover the interrupted operation first.")
        keys = self.peer.capabilities()
        disk_state = self.state()
        require(not disk_state["session"] or disk_state["session"]["socket"] == self.peer.identity["socket"],
                "Saved state belongs to another compositor socket; use separate state directories for multiple sessions.")
        report = self.peer.request("effects")

        adopted = False
        if disk_state["current"] and disk_state["session"] == self.peer.identity:
            if not self.owned(disk_state, report):
                require(self.base_override and not markers(report),
                        "Another configuration replaced the plugin wrapper; choose its base path explicitly in settings, then review again.")
                adopted = True
        else:
            require(not markers(report), "An unrecorded plugin generation is active; use recovery instructions.")
        base = self.base_override or disk_state["base"] or discover_base(self.peer)
        require(Path(base).is_absolute(), "The base configuration path must be absolute.")
        require(not disk_state["current"] or not self.owned(disk_state, report) or disk_state["base"] == base,
                "Restore the original configuration before changing the base path.")
        graph = config_graph(base, self.peer.environ)
        before = disk_state if disk_state["session"] == self.peer.identity and not adopted else empty_state(base, self.peer.identity)
        before = {**before, "base": str(base), "session": self.peer.identity}
        saved = None if adopted else disk_state["current"]
        selections = dict(saved.get("selections", {"effects.cursor": "cursor/glow"})) if saved else {}
        requested = {slot: effect_id}
        family = None
        try:
            catalogue = LocalCatalogue(source)
            if family_id is not None:
                family, requested, selections, selected = catalogue.family_selection(
                    family_id, choices, selections, {"preset-effects": "supported"})
            else:
                selections.update(requested)
                selected = catalogue.selection(selections, {"preset-effects": "supported"})
            catalogue.preserve_unchanged_settings(selected, selections, requested, saved.get("settings", {}) if saved else {})
        except ValueError as error:
            raise Error(str(error)) from error
        settings = selected["settings"]
        if keys is not None:
            missing = set(settings) - keys
            require(not missing, "This Umbriel build is incompatible: missing settings " + ", ".join(sorted(missing)))
        for key, expected in selected["prerequisites"].items():
            require(graph["settings"].get(key) == expected,
                    f"Required base setting {key} = {expected!r} must be resolved before applying.")
        definitions, local_copies, resolved, checked_presets = {}, {}, set(), set()
        imported_ids = set()

        def use_local(name, kind):
            existing = graph["presets"].get(name)
            require(existing is not None, f"The local preset references a missing {kind} preset: {name}")
            definition = existing["definition"]
            require(isinstance(definition, dict) and definition.get("kind") == kind,
                    f"The local preset {name} must have kind {kind} for this selection.")
            checked_presets.add(name)
            # Follow the local border's actual overlay, not the catalogue's default.
            if kind == "border" and definition.get("overlay"):
                use_local(definition["overlay"], "window")
            local_copies.setdefault(name, {"preset": name, "config": existing["config"], "matches_catalogue": None})
            return existing

        def resolve(selected_id):
            if selected_id in resolved:
                return
            resolved.add(selected_id)
            effect = catalogue.effects[selected_id]
            name = effect["preset"]
            require(not name.startswith(MARKER), "Catalogue presets cannot use the plugin ownership marker prefix.")
            require(name not in graph["pools"], f"The base {base} defines a pool named {name}, not an individual shader preset.")
            definition = catalogue.definition(selected_id, self.root / "library")
            if name in graph["presets"]:
                existing = use_local(name, effect["kind"])
                relative_shader = Path(definition["shader"]).relative_to(self.root / "library").as_posix()
                local_copies[name]["matches_catalogue"] = equivalent(
                    existing, definition, graph["files"], catalogue.registry["files"][relative_shader]["sha256"])
                return
            for dependency in effect["dependencies"]:
                resolve(dependency)
            imported_ids.add(selected_id)
            definitions[name] = definition
            checked_presets.add(name)

        for selected_id in sorted(set(selections.values())):
            resolve(selected_id)
        import_files = sorted({path for selected_id in imported_ids for path in catalogue.effects[selected_id]["install_files"]})
        installed = self.install_selection(catalogue, import_files) if import_files else {}
        token = uuid.uuid4().hex
        directory = self.root / "generations" / token
        shader = directory / "marker.glsl"
        atomic(shader, b"vec4 cursor(vec2 uv) { return umbriel_sample(uv); }\n")
        config = directory / "config.toml"
        marker = MARKER + token
        lines = [MANAGED, *setting_lines(settings), '[include]', 'files = ' + json.dumps([str(base)])]
        for name, definition in sorted(definitions.items()):
            lines += preset_lines(name, definition)
        lines += preset_lines(marker, {"kind": "cursor", "shader": "marker.glsl", "radius": 1})
        if graph["drm"]:
            lines += ["[drm]"]
        atomic(config, ("\n".join(lines) + "\n").encode())
        self.phase("Configuration validation", "running")
        self.peer.validate(config)
        self.phase("Configuration validation", "passed")
        verify(graph["files"])
        own_files = {**installed, str(config): fingerprint(config), str(shader): fingerprint(shader)}
        current = {"token": token, "marker": marker, "config": str(config), "files": own_files,
                   "selections": selections, "settings": settings,
                   "presets": sorted(checked_presets),
                   "catalogue": catalogue.fingerprint}
        plan = {"token": token, "created": time.time(), "disk_state": disk_state, "before": before,
                "before_report": selection_report(report), "current": current, "compatibility": selected["compatibility"],
                "base_files": graph["files"], "session": self.peer.identity, "slot": slot, "slots": sorted(requested)}
        save_json(self.root / "plans" / f"{token}.json", plan)
        prior_settings = {**graph["settings"], **(before["current"].get("settings", {}) if before["current"] else {})}
        effect = family or catalogue.effects[effect_id]
        message = "Ready to apply " + effect["name"] + "."
        if local_copies:
            message += " Already exists locally — using your local copy: " + ", ".join(sorted(local_copies)) + "."
        return {**self.status(), "plan_token": token, "message": message, "base": str(base),
                "effect_id": effect_id if family is None else None, "slot": slot if family is None else None, "effect_name": effect["name"], "family_id": family_id,
                "compatibility": selected["compatibility"], "features": catalogue.registry["feature_definitions"],
                "changes": [{"key": key, "before": prior_settings.get(key), "after": value} for key, value in settings.items()],
                "dependencies": sorted(checked_presets - {catalogue.effects[item]["preset"] for item in requested.values()}),
                "local_copies": list(local_copies.values()),
                "runtime_changes": sum(1 for item in runtime_slots(report).values()
                                       if "effects." + item["kind"] in requested),
                "base_notice": "Review the base path: startup discovery cannot detect an earlier external config-replace."}

    def target_path(self, state):
        return state["current"]["config"] if state["current"] else state["base"]

    def verify_target(self, state, compiled=True):
        deadline = time.monotonic() + 4
        while True:
            report = self.peer.request("effects")
            if state["current"] is None:
                require(not markers(report), "The base configuration still contains a managed generation.")
                return
            require(self.owned(state, report), "The active generation does not match the requested configuration.")
            current = state["current"]
            expected = current.get("presets", ["glow"])
            presets = {p["name"]: p for p in report.get("presets", [])}
            require(all(name in presets for name in expected), "A reviewed shader preset was not loaded.")
            failed = [name for name in expected if presets[name].get("state") in {"failed", "error"}]
            require(not failed, "Shader failed GPU compilation: " + ", ".join(failed))
            waiting = [name for name in expected if presets[name].get("state") != "compiled"]
            if not compiled or not waiting:
                return
            require(time.monotonic() < deadline, "Shader compilation could not be verified: " + ", ".join(waiting))
            time.sleep(0.05)

    def effect_action(self, record, operation, selector=None):
        target, kind = record["target"], record["kind"]
        require(kind in {"border", "window", "screen", "cursor"}, "Invalid effect kind in recovery state.")
        require(kind == "cursor" or bool(target), "An explicit effect target is required.")
        require(operation in {"set", "cycle", "reset", "toggle"}, "Invalid effect operation in recovery state.")
        fields = {"action": f"effect-{kind}-{operation}"}
        if operation == "set":
            require(bool(selector), "An effect selector is required.")
            fields["effect"] = selector
        elif operation == "cycle" and selector:
            fields["pool"] = selector
        if kind in {"border", "window"}:
            fields["window"] = target
        elif kind == "screen":
            fields["output"] = target
        self.peer.request("action", **fields)

    def restore_runtime(self, records):
        for key, desired in records.items():
            report = self.peer.request("effects")
            current = runtime_slots(report).get(key)
            if current is None:
                continue  # The window closed/output disappeared; never target a replacement.
            value = desired["value"]
            try:
                if value["source"] == "runtime":
                    selector = value["pool"] or value["name"]
                    require(bool(selector), "Cannot restore an empty runtime selector.")
                    self.effect_action(desired, "set", selector)
                    if value["pool"]:
                        pool = next((p for p in report.get("pools", []) if p["name"] == value["pool"]), None)
                        require(pool is not None, "The previous effect pool is no longer available.")
                        for _ in range(len(pool["members"])):
                            actual = runtime_slots(self.peer.request("effects")).get(key)
                            if actual is None or actual["value"]["name"] == value["name"]:
                                break
                            self.effect_action(desired, "cycle", value["pool"])
                elif current["value"]["source"] == "runtime":
                    self.effect_action(desired, "reset")
                actual = runtime_slots(self.peer.request("effects")).get(key)
                if actual is None:
                    continue
                if actual["value"]["suppressed"] != value["suppressed"]:
                    self.effect_action(desired, "toggle")
                actual = runtime_slots(self.peer.request("effects")).get(key)
                if actual is None:
                    continue
                require(actual["value"]["suppressed"] == value["suppressed"], "Could not restore effect suppression.")
                if value["source"] == "runtime":
                    require(actual["value"] == value, "Could not restore the previous runtime shader selection.")
                else:
                    require(actual["value"]["source"] != "runtime", "Could not restore the configured shader selection.")
            except Error:
                if key not in runtime_slots(self.peer.request("effects")):
                    continue
                raise

    def transaction(self, before, target, expected_base=None, expected_report=None, runtime_action="apply", runtime_slot=None):
        config = self.target_path(target)
        graph = config_graph(target["base"], self.peer.environ)
        if expected_base is not None:
            require(graph["files"] == expected_base, "Base configuration changed; review again.")
        if target["current"]:
            verify(target["current"]["files"])
        self.phase("Configuration validation", "running")
        self.peer.validate(config)
        self.phase("Configuration validation", "passed")
        verify(graph["files"])
        observed = self.peer.request("effects")
        if before["current"]:
            require(self.owned(before, observed), "The active configuration changed during validation; it was left unchanged.")
        if expected_report is not None:
            require(json.dumps(selection_report(observed), sort_keys=True) == json.dumps(expected_report, sort_keys=True),
                    "Active selections changed during validation; review again.")
        live = runtime_slots(observed)
        runtime_after = {}
        if runtime_action == "apply":
            settings = target["current"].get("settings", {"effects.cursor": "glow"})
            original = dict(before.get("runtime_original", {}))
            for key, record in live.items():
                selector = settings.get("effects." + record["kind"])
                if selector is not None and (runtime_slot is None or "effects." + record["kind"] in (runtime_slot if isinstance(runtime_slot, list) else [runtime_slot])):
                    original.setdefault(key, record)
                    runtime_after[key] = {**record, "value": {"name": selector, "pool": "", "source": "runtime", "suppressed": False}}
            target["runtime_original"] = original
            target["runtime_current"] = {**before.get("runtime_current", {}), **runtime_after}
            target["undo_runtime"] = {key: live[key] for key in runtime_after}
            target["undo_original"] = before.get("runtime_original", {})
            target["undo_owned"] = before.get("runtime_current", {})
        else:
            desired = before.get("undo_runtime" if runtime_action == "undo" else "runtime_original", {})
            # An external change after Apply belongs to the user; leave it in place.
            for key, record in desired.items():
                if key in live and live[key] == before.get("runtime_current", {}).get(key):
                    runtime_after[key] = record
            target["runtime_original"] = before.get("undo_original", {}) if runtime_action == "undo" else {}
            target["runtime_current"] = before.get("undo_owned", {}) if runtime_action == "undo" else {}
            for field in ("undo_runtime", "undo_original", "undo_owned"):
                target.pop(field, None)
        runtime_before = {key: live[key] for key in runtime_after if key in live}
        journal = {"before": before, "target": target, "session": self.peer.identity, "runtime_before": runtime_before}
        save_json(self.pending_path, journal)
        try:
            self.phase("Configuration switch", "running")
            self.peer.request("config-replace", config)
            self.phase("Configuration switch", "passed")
            self.phase("Runtime selections", "running")
            self.restore_runtime(runtime_after)
            self.phase("Runtime selections", "passed")
            self.phase("GPU compilation" if target["current"] else "Original configuration check", "running")
            self.verify_target(target)
            self.phase("GPU compilation" if target["current"] else "Original configuration check", "passed")
            verify(graph["files"])
            save_json(self.state_path, target)
        except Exception as error:
            self.fail_phase(error)
            try:
                self.rollback(journal)
            except Exception as recovery:
                raise Error(f"{error} Recovery is still pending: {recovery}") from error
            raise Error(f"{error} The previous configuration was restored.") from error
        self.pending_path.unlink()
        self.cleanup(target)

    def rollback(self, pending):
        self.phase("Rollback / recovery", "running")
        require(pending["session"] == self.peer.identity, "The compositor restarted; recover to the original base explicitly.")
        before = pending["before"]
        if before["current"]:
            verify(before["current"]["files"])
        self.peer.validate(self.target_path(before))
        self.peer.request("config-replace", self.target_path(before))
        self.restore_runtime(pending.get("runtime_before", {}))
        self.verify_target(before)
        save_json(self.state_path, before)
        self.pending_path.unlink(missing_ok=True)
        self.phase("Rollback / recovery", "passed")

    def choose_family(self, source, family_id, choices):
        plan = self.prepare(source, family_id=family_id, choices=choices)
        result = self.apply(plan["plan_token"])
        result["message"] = "Family applied. Undo restores the whole previous selection."
        if plan["local_copies"]:
            result["message"] += " Using your existing local copies."
        return result

    def choose(self, source, effect_id, slot):
        plan = self.prepare(source, effect_id, slot)
        result = self.apply(plan["plan_token"])
        if plan["local_copies"]:
            result["message"] += " Using your existing local copy."
        return result

    def apply(self, token):
        require(not self.pending_path.exists(), "Recover the interrupted operation first.")
        require(isinstance(token, str) and bool(re.fullmatch(r"[0-9a-f]{32}", token)), "Review a shader before applying.")
        plan = load_json(self.root / "plans" / f"{token}.json")
        compatibility = plan.get("compatibility", {"status": "compatible", "unknown": []})
        require(compatibility["status"] != "incompatible", "The reviewed selection is incompatible.")
        require(not self.base_override or self.base_override == plan["before"]["base"],
                "The configured base path changed; review again.")
        require(plan["session"] == self.peer.identity and time.time() - plan["created"] < 900,
                "The review expired or Umbriel restarted; review again.")
        require(self.state() == plan["disk_state"], "Selections changed after review; review again.")
        # JSON turns tuples into lists; compare their canonical encodings.
        require(json.dumps(selection_report(self.peer.request("effects")), sort_keys=True)
                == json.dumps(plan["before_report"], sort_keys=True), "Active selections changed after review; review again.")
        verify(plan["base_files"])
        verify(plan["current"]["files"])
        target = {**plan["before"], "current": plan["current"], "undo": [plan["before"]["current"]]}
        self.transaction(plan["before"], target, plan["base_files"], plan["before_report"], runtime_slot=plan.get("slots", plan.get("slot")))
        return {**self.status(), "message": "Shader selections applied and GPU compilation verified."}

    def undo(self):
        require(not self.pending_path.exists(), "Recover the interrupted operation first.")
        state = self.state()
        require(self.owned(state, self.peer.request("effects")), "The plugin no longer owns the active configuration.")
        require(bool(state["undo"]), "There is no previous selection to restore.")
        target = {**state, "current": state["undo"][-1], "undo": []}
        self.transaction(state, target, runtime_action="undo")
        return {**self.status(), "message": "Previous plugin selection restored."}

    def restore(self):
        require(not self.pending_path.exists(), "Recover the interrupted operation first.")
        state = self.state()
        if not self.owned(state, self.peer.request("effects")):
            return {**self.status(), "message": "No owned configuration to restore; the active session was left unchanged."}
        target = empty_state(state["base"], self.peer.identity)
        self.transaction(state, target, runtime_action="restore")
        return {**self.status(), "message": "Original configuration restored from its current contents."}

    def recover(self):
        require(self.pending_path.exists(), "There is no interrupted operation to recover.")
        pending = load_json(self.pending_path)
        if pending["session"] != self.peer.identity:
            require(pending["session"]["socket"] == self.peer.identity["socket"], "Recovery belongs to another compositor socket.")
            base = pending["before"]["base"]
            # Explicit recovery after restart restores the chosen base, never a
            # stale wrapper inferred from files left by the old process.
            before = empty_state(base, self.peer.identity)
            pending = {"before": before, "session": self.peer.identity}
        self.rollback(pending)
        return {**self.status(), "message": "Interrupted operation recovered to the previous configuration."}

    def cleanup(self, state):
        keep = {x["token"] for x in [state["current"], *state["undo"]] if x}
        for directory in (self.root / "generations").glob("*"):
            if re.fullmatch(r"[0-9a-f]{32}", directory.name) and directory.name not in keep and not directory.is_symlink():
                shutil.rmtree(directory)
        for path in (self.root / "plans").glob("*.json"):
            path.unlink()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state-dir", required=True, type=Path)
    parser.add_argument("--socket", help="explicit Umbriel socket; defaults to this session's environment")
    parser.add_argument("--base-config", help="explicit base path, including custom/declarative configurations")
    parser.add_argument("--source-root", help="community shader checkout, used only by prepare")
    parser.add_argument("--plan-token")
    parser.add_argument("--family")
    parser.add_argument("--choices", help="JSON mapping of family uses to selected member IDs; empty values keep current")
    parser.add_argument("--effect", default="cursor/glow")
    parser.add_argument("--slot", default="effects.cursor")
    # Accept the old flag during service hot reload; it no longer changes behaviour.
    parser.add_argument("--allow-unverified", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("action", choices=("status", "catalogue", "diagnostics", "prepare", "choose", "choose-family", "apply", "undo", "restore", "recover"))
    args = parser.parse_args(argv)
    controller = None
    try:
        if args.action == "diagnostics":
            peer, live_error = None, None
            try:
                peer = Peer(args.socket)
            except (Error, OSError, ValueError, subprocess.TimeoutExpired) as error:
                live_error = str(error)
            result = diagnostic_report(args.state_dir, peer, base=args.base_config,
                                       source=args.source_root, live_error=live_error)
            print(json.dumps({"ok": True, "diagnostics": result}))
            return 0
        controller = Controller(args.state_dir, None, args.base_config or None)
        with controller.locked():
            def dispatch():
                controller.peer = Peer(args.socket)
                if args.action == "choose-family":
                    return controller.choose_family(args.source_root, args.family, json.loads(args.choices or "null"))
                if args.action == "choose":
                    return controller.choose(args.source_root, args.effect, args.slot)
                if args.action == "prepare":
                    return controller.prepare(args.source_root, args.effect, args.slot)
                if args.action == "catalogue":
                    return controller.catalogue(args.source_root)
                if args.action == "apply":
                    return controller.apply(args.plan_token)
                return getattr(controller, args.action)()
            result = controller.perform(args.action, dispatch)
        print(json.dumps({"ok": True, **result}))
        return 0
    except (Error, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        context = {}
        if controller is not None and controller.peer is not None:
            try:
                with controller.locked():
                    context = controller.status()
            except (Error, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
                pass
        print(json.dumps({**context, "ok": False, "message": str(error)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
