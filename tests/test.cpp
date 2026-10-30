// SPDX-License-Identifier: MIT
#include "core.hpp"
#include "fake_peer.hpp"
#include <functional>
#include <iostream>
#include <sstream>
#include <sys/wait.h>
#include <unistd.h>
using namespace shaders;
namespace {
int assertions = 0;
void check(bool condition, const std::string &message) {
    ++assertions;
    require(condition, message);
}
void fails(const std::function<void()> &task, const std::string &expected) {
    try {
        task();
    } catch (const std::exception &error) {
        check(std::string(error.what()).find(expected) != std::string::npos,
              "Unexpected error: " + std::string(error.what()));
        return;
    }
    throw Error("Expected failure: " + expected);
}
struct Fixture {
    fs::path root = fs::temp_directory_path() / ("umbriel-native-test-" + token());
    fs::path state_root = root / "state", assets = root / "assets", index = root / "catalogue.json";
    Json registry;
    std::unique_ptr<FakePeer> peer;
    std::unique_ptr<Controller> controller;
    Fixture() {
        fs::create_directories(root);
        atomic_write(root / "base.toml", "[effects]\ncursor = \"\"\n[general]\nautostart=[]\n");
        registry = {{"schema_version", 1},
                    {"draft", false},
                    {"source",
                     {{"repository", "https://github.com/noctalia-dev/community-umbriel-shaders"},
                      {"revision", std::string(40, 'a')}}},
                    {"feature_definitions", {{"preset-effects", "Presets"}}},
                    {"effects", Json::array()},
                    {"families", Json::array()},
                    {"files", Json::object()}};
        add("glow");
        add("second");
        peer = std::make_unique<FakePeer>(root);
        controller = std::make_unique<Controller>(state_root, *peer);
    }
    ~Fixture() {
        std::error_code ignored;
        fs::remove_all(root, ignored);
    }
    void file(const std::string &name, const std::string &text) {
        atomic_write(assets / name, text);
        registry["files"][name] = {{"bytes", text.size()}, {"sha256", sha256(text)}};
    }
    void add(const std::string &name, const std::string &kind = "cursor", const std::string &extra = "") {
        const auto id = kind + "/" + name;
        file(id + "/effect.toml", "[effects.preset." + name + "]\nkind=" + quoted(kind) +
                                      "\nshader=\"shader.glsl\"\n" + (kind == "cursor" ? "radius=96\n" : "") +
                                      extra);
        file(id + "/shader.glsl", "vec4 " + kind + "(vec2 uv) { return umbriel_sample(uv); }\n");
        file(id + "/README.md", "MIT synthetic fixture\n");
        registry["effects"].push_back(
            {{"id", id},
             {"path", id},
             {"kind", kind},
             {"role", "effect"},
             {"preset", name},
             {"name", name},
             {"description", "Fixture"},
             {"author", "Test"},
             {"license", "MIT"},
             {"tags", Json::array()},
             {"families", Json::array()},
             {"uses", Json::array({kind == "animation" ? "animation.windows_in" : "effects." + kind})},
             {"dependencies", Json::array()},
             {"required_settings", Json::object()},
             {"notice_files", Json::array({id + "/README.md"})},
             {"install_files", Json::array({id + "/effect.toml", id + "/shader.glsl", id + "/README.md"})},
             {"preview", {{"image", nullptr}, {"animation", nullptr}}},
             {"activation",
              {{"settings",
                {{kind == "animation" ? "animation.windows_in.effect" : "effects." + kind, name}}}}}});
        save(index, registry);
    }
    std::string prepare(const std::string &name = "glow") {
        Catalogue cat(index, assets);
        return controller->prepare(cat, "cursor/" + name).at("plan_token");
    }
    void select(const std::string &id, const std::string &slot) {
        Catalogue cat(index, assets);
        controller->apply(controller->prepare(cat, id, slot).at("plan_token"));
    }
    void windows(int count, int batch = 0) {
        peer->targets.clear();
        for (int i = 0; i < count; ++i)
            for (const auto *kind : {"border", "window"}) {
                const auto target = "window-" + std::to_string(batch) + "-" + std::to_string(i);
                peer->targets[Json::array({kind, target}).dump()] = {kind, target, {}};
            }
        peer->targets[Json::array({"screen", "DP-1"}).dump()] = {"screen", "DP-1", {}};
    }
    void choose(const std::string &name = "glow") {
        controller->apply(prepare(name));
    }
};
void basics() {
    Fixture f;
    Lock lock(f.state_root);
    const auto original = read(f.root / "base.toml");
    const auto plan = f.prepare();
    check(f.peer->switches == 0, "Review switched configuration");
    f.controller->apply(plan);
    check(f.controller->status()["managed"], "Apply not owned");
    f.choose("second");
    f.controller->undo();
    check(cursor(f.peer->effects()).name == "glow", "Undo wrong cursor");
    f.controller->restore();
    check(!f.controller->status()["managed"], "Restore still owned");
    check(read(f.root / "base.toml") == original, "Original config was edited");
    check(!fs::exists(f.state_root / "pending.json"), "Successful transaction kept journal");
    f.choose();
    f.controller->undo();
    check(!f.controller->status()["managed"], "First selection undo failed");
}
void validation() {
    Fixture f;
    Lock lock(f.state_root);
    auto plan = f.prepare();
    atomic_write(f.root / "base.toml", read(f.root / "base.toml") + "\n# changed\n");
    fails([&] { f.controller->apply(plan); }, "File changed");
    check(f.peer->switches == 0, "Tampered base switched");
    plan = f.prepare();
    auto saved = load(f.state_root / "plan.json");
    auto config = saved["generation"]["config"].get<std::string>();
    atomic_write(config, read(config) + "\n# changed\n");
    fails([&] { f.controller->apply(plan); }, "File changed");
    plan = f.prepare();
    save(f.root / "runtime", Selection{"external", "", "runtime", false});
    fails([&] { f.controller->apply(plan); }, "Live selections changed");
    f.peer->identity.start = "restarted";
    fails([&] { f.controller->apply(plan); }, "Base or compositor changed");
    fails([&] { f.controller->apply("../escape"); }, "Invalid review token");
}
void failures() {
    Fixture f;
    Lock lock(f.state_root);
    auto plan = f.prepare();
    f.peer->reject = true;
    fails([&] { f.controller->apply(plan); }, "previous configuration restored");
    check(!fs::exists(f.state_root / "pending.json"), "Rejected switch kept recoverable journal");
    plan = f.prepare();
    f.peer->fail_compile = true;
    fails([&] { f.controller->apply(plan); }, "GPU compilation");
    check(read(f.root / "active") == f.peer->config.string(), "Compile failure did not roll back");
    plan = f.prepare();
    f.peer->fail_rollback = true;
    fails([&] { f.controller->apply(plan); }, "recovery is pending");
    check(fs::exists(f.state_root / "pending.json"), "Failed rollback lost journal");
    f.peer->fail_rollback = false;
    f.peer->fail_compile = false;
    f.controller->recover();
    check(!fs::exists(f.state_root / "pending.json"), "Recovery kept journal");
}
void crash_recovery() {
    Fixture f;
    {
        Lock lock(f.state_root);
        f.prepare();
    }
    const pid_t child = fork();
    require(child >= 0, "fork failed");
    if (child == 0) {
        Lock lock(f.state_root);
        f.peer->crash = true;
        f.controller->apply(load(f.state_root / "plan.json")["generation"]["token"]);
        _exit(99);
    }
    int status;
    waitpid(child, &status, 0);
    check(WIFEXITED(status) && WEXITSTATUS(status) == 71, "Did not crash after switch");
    check(fs::exists(f.state_root / "pending.json"), "Crash lost durable journal");
    Lock lock(f.state_root);
    FakePeer fresh(f.root);
    Controller recovery(f.state_root, fresh);
    recovery.recover();
    check(read(f.root / "active") == fresh.config.string(), "Recovery did not restore base");
    check(!recovery.status()["managed"], "Recovery retained owned configuration");
}
void reuse_and_catalogue() {
    Fixture f;
    Lock lock(f.state_root);
    f.choose();
    f.controller->restore();
    const auto shader = f.state_root / "library/cursor/glow/shader.glsl";
    atomic_write(shader, read(shader) + "// user customisation\n");
    fs::remove_all(f.assets);
    f.choose();
    check(read(shader).find("customisation") != std::string::npos, "Overwrote installed shader");
    // Replacing a withdrawn current cursor doesn't replan that old selection.
    f.registry["effects"].erase(f.registry["effects"].begin());
    save(f.index, f.registry);
    f.file("cursor/second/effect.toml",
           "[effects.preset.second]\nkind=\"cursor\"\nshader=\"shader.glsl\"\nradius=96\n");
    f.file("cursor/second/shader.glsl", "vec4 cursor(vec2 uv) { return umbriel_sample(uv); }\n");
    f.file("cursor/second/README.md", "MIT synthetic fixture\n");
    f.choose("second");
    f.controller->undo();
    check(cursor(f.peer->effects()).name == "glow", "Withdrawn installed preset cannot be restored");
    f.controller->restore();
}
void optional_local_comparison() {
    Fixture f;
    Lock lock(f.state_root);
    f.choose();
    f.controller->restore();
    Catalogue cat(f.index, f.assets);
    auto compare = [&] {
        return f.controller->prepare(cat, "cursor/glow", "effects.cursor", true).at("local_copies");
    };
    check(compare()[0]["matches_catalogue"] == true, "Unmodified installed copy did not match");
    const auto shader = f.state_root / "library/cursor/glow/shader.glsl";
    atomic_write(shader, read(shader) + "// customization\n");
    check(compare()[0]["matches_catalogue"] == false, "Customized shader was reported as matching");
    const auto bytes = read(shader);
    fs::remove_all(f.assets);
    check(compare()[0]["matches_catalogue"].is_null(), "Unavailable comparison reported a result");
    f.choose();
    check(read(shader) == bytes, "Comparison or Apply overwrote local edits");
    fails([&] { parse_json(std::string(100, '[') + "0" + std::string(100, ']')); }, "nesting exceeds");
}
void bounds_and_local() {
    Fixture f;
    Lock lock(f.state_root);
    for (int i = 0; i < 40; ++i)
        f.prepare();
    check(std::distance(fs::directory_iterator(f.state_root / "generations"), fs::directory_iterator{}) == 1,
          "Reviews accumulated generations");
    f.registry["effects"][0]["description"] = std::string(3000, 'x');
    save(f.index, f.registry);
    fails([&] { Catalogue cat(f.index, f.assets); }, "oversized");
    f.registry["effects"][0]["description"] = "Fixture";
    save(f.index, f.registry);
    atomic_write(f.root / "custom.glsl", "vec4 cursor(vec2 uv) {return umbriel_sample(uv);}\n");
    atomic_write(f.root / "base.toml",
                 read(f.root / "base.toml") +
                     "[effects.preset.glow]\nkind=\"cursor\"\nshader=\"custom.glsl\"\nradius=27\n");
    fs::remove_all(f.assets);
    f.choose();
    f.controller->restore();
    check(read(f.root / "base.toml").find("radius=27") != std::string::npos, "Local preset changed");
    fails([&] { Lock second(f.state_root); }, "Another operation");
    fails([&] { save(f.state_root / "oversized.json", std::string(document_limit, 'x')); }, "before writing");
    check(!fs::exists(f.state_root / "oversized.json"), "Oversized file was written");
}
void external_changes() {
    Fixture f;
    Lock lock(f.state_root);
    f.choose();
    auto external = Selection{"external", "", "runtime", true};
    save(f.root / "runtime", external);
    f.controller->restore();
    check(cursor(f.peer->effects()) == external, "Restore overwrote external cursor");
    f.choose();
    atomic_write(f.root / "active", f.peer->config.string());
    auto switches = f.peer->switches;
    f.controller->restore();
    check(f.peer->switches == switches, "Restore overwrote external config");
}
void adoption_and_restart_recovery() {
    {
        Fixture f;
        Lock lock(f.state_root);
        f.choose();
        const auto alternate = f.root / "alternate.toml";
        atomic_write(alternate, "[effects]\ncursor=\"\"\n");
        atomic_write(f.root / "active", alternate.string());
        fails([&] { f.prepare("second"); }, "choose its original base path explicitly");
        Controller adopted(f.state_root, *f.peer, alternate);
        Catalogue cat(f.index, f.assets);
        adopted.apply(adopted.prepare(cat, "cursor/second").at("plan_token"));
        check(adopted.status()["selections"].size() == 1, "Adoption retained abandoned selections");
        adopted.restore();
        check(read(f.root / "active") == alternate.string(), "Adopted configuration did not restore");
    }
    {
        Fixture f;
        Lock lock(f.state_root);
        f.windows(3);
        const auto plan = f.prepare();
        f.peer->fail_compile = true;
        f.peer->fail_rollback = true;
        fails([&] { f.controller->apply(plan); }, "recovery is pending");
        f.peer->fail_compile = false;
        f.peer->fail_rollback = false;
        f.peer->identity.start = "new-process";
        f.windows(2, 1);
        f.controller->recover();
        check(!f.controller->status()["managed"] && !fs::exists(f.state_root / "pending.json"),
              "Restart recovery failed");
        check(read(f.root / "active") == f.peer->config.string(),
              "Restart recovery retained interrupted wrapper");
        check(decode_state(load(f.state_root / "state.json")).original.empty(),
              "Restart recovery reused old window IDs");
    }
    {
        Fixture f;
        Lock lock(f.state_root);
        const auto plan = f.prepare();
        f.peer->fail_compile = true;
        f.peer->fail_rollback = true;
        fails([&] { f.controller->apply(plan); }, "recovery is pending");
        f.peer->fail_compile = false;
        f.peer->fail_rollback = false;
        f.peer->identity.start = "new-process";
        const auto foreign = f.root / "foreign.toml";
        atomic_write(foreign, "[effects.preset." + quoted(std::string(marker_prefix) + token()) +
                                  "]\nkind=\"cursor\"\nshader=\"foreign.glsl\"\n");
        atomic_write(f.root / "active", foreign.string());
        const auto switches = f.peer->switches;
        fails([&] { f.controller->recover(); }, "foreign managed configuration");
        check(f.peer->switches == switches && fs::exists(f.state_root / "pending.json"),
              "Recovery displaced a foreign wrapper");
    }
}
void integrity_and_races() {
    Fixture f;
    Lock lock(f.state_root);
    atomic_write(f.assets / "cursor/glow/shader.glsl", "corrupt");
    fails([&] { f.prepare(); }, "hash mismatch");
    check(!fs::exists(f.state_root / "library/cursor/glow"),
          "Failed verification partially installed a preset");
    f.file("cursor/glow/shader.glsl", "vec4 cursor(vec2 uv) { return umbriel_sample(uv); }\n");
    fs::remove(f.assets / "cursor/glow/shader.glsl");
    fs::create_symlink(f.root / "base.toml", f.assets / "cursor/glow/shader.glsl");
    fails([&] { f.prepare(); }, "Symlinks");
    fs::remove(f.assets / "cursor/glow/shader.glsl");
    f.file("cursor/glow/shader.glsl", "vec4 cursor(vec2 uv) { return umbriel_sample(uv); }\n");
    f.choose();
    const auto switches = f.peer->switches;
    f.peer->during_validation = [&] {
        save(f.root / "runtime", Selection{"external", "", "runtime", false});
    };
    fails([&] { f.controller->restore(); }, "Live selections changed during validation");
    check(f.peer->switches == switches, "Restore overwrote a change made during validation");
    f.peer->during_validation = {};
    f.controller->restore();
    const auto alternate = f.root / "alternate.toml";
    atomic_write(alternate, "[effects]\ncursor=\"\"\n");
    Controller other(f.state_root, *f.peer, alternate);
    Catalogue catalogue(f.index, f.assets);
    other.apply(other.prepare(catalogue, "cursor/glow").at("plan_token"));
    other.restore();
    check(read(f.root / "active") == alternate.string(), "New base after Restore was not retained");
}
void mixed_effects_and_withdrawal() {
    Fixture f;
    Lock lock(f.state_root);
    f.windows(3);
    f.add("frame", "border");
    f.add("surface", "window");
    f.add("display", "screen");
    f.add("fade", "animation");
    f.choose();
    f.select("border/frame", "effects.border");
    f.select("window/surface", "effects.window");
    f.select("screen/display", "effects.screen");
    f.select("animation/fade", "animation.windows_in");
    check(f.controller->status()["selections"].size() == 5, "Mixed selections were not preserved");
    // Withdrawal of an unchanged selection must not make an unrelated Apply depend on it.
    f.registry["effects"].erase(f.registry["effects"].begin());
    save(f.index, f.registry);
    f.select("animation/fade", "animation.windows_in");
    check(cursor(f.peer->effects()).name == "glow", "Withdrawn cursor was replaced");
    f.select("", "effects.border");
    for (const auto &[id, slot] : runtime_slots(f.peer->effects())) {
        (void)id;
        if (slot.kind == "border")
            check(slot.value.source == "default", "Removing border did not release runtime selection");
    }
    f.controller->undo();
    check(f.controller->status()["selections"].contains("effects.border"),
          "Undo did not restore removed slot");
    f.controller->restore();
    for (const auto &[id, slot] : runtime_slots(f.peer->effects())) {
        (void)id;
        check(slot.value.source != "runtime", "Restore retained a native runtime selection");
    }
}
void installed_border_base_overlay() {
    Fixture f;
    Lock lock(f.state_root);
    f.windows(2);
    f.add("overlay", "window");
    f.add("frame", "border", "overlay=\"overlay\"\nlight={spread=12,intensity=0.5}\n");
    auto &border = f.registry["effects"].back();
    border["dependencies"] = {"window/overlay"};
    f.file("border/frame/effect.toml",
           "[include]\nfiles=[\"../../window/overlay/"
           "effect.toml\"]\n[effects.preset.frame]\nkind=\"border\"\nshader=\"shader.glsl\"\noverlay="
           "\"overlay\"\nlight={spread=12,intensity=0.5}\n");
    save(f.index, f.registry);
    atomic_write(f.root / "custom.glsl", "vec4 window(vec2 uv) { return umbriel_sample(uv); }\n");
    atomic_write(f.root / "base.toml",
                 read(f.root / "base.toml") +
                     "[effects.preset.overlay]\nkind=\"window\"\nshader=\"custom.glsl\"\n");
    f.select("border/frame", "effects.border");
    check(!fs::exists(f.state_root / "library/window/overlay"), "Copied over a base-supplied overlay");
    f.choose();
    f.controller->undo();
    f.controller->restore();
    fs::remove_all(f.assets);
    f.select("border/frame", "effects.border");
    f.controller->restore();
    check(!fs::exists(f.state_root / "pending.json"), "Installed border reuse left recovery pending");
}
void windows_bounded_and_batched() {
    Fixture f;
    Lock lock(f.state_root);
    f.add("frame", "border");
    int small = 0, large = 0;
    for (const int count : {1, 100}) {
        f.windows(count);
        f.peer->queries = 0;
        f.select("border/frame", "effects.border");
        (count == 1 ? small : large) = f.peer->queries;
        f.controller->restore();
    }
    check(large == small && large < 16, "Effects reports grew with window count");
    size_t maximum = 0;
    for (int batch = 0; batch < 70; ++batch) {
        f.windows(20, batch);
        f.select("border/frame", "effects.border");
        maximum = std::max(maximum, fs::file_size(f.state_root / "state.json"));
        const auto state = decode_state(load(f.state_root / "state.json"));
        check(state.original.size() == 20 && state.owned.size() == 20, "Closed windows accumulated in state");
    }
    check(maximum < 50000, "Window churn expanded persistent state");
    f.controller->undo();
    f.controller->restore();
}
void families_and_external_targets() {
    Fixture f;
    Lock lock(f.state_root);
    f.add("frame", "border");
    f.add("fade", "animation");
    f.windows(2);
    f.registry["families"] = Json::array({{{"id", "test"},
                                           {"name", "Test"},
                                           {"members", {"cursor/glow", "border/frame", "animation/fade"}},
                                           {"activation",
                                            {{"settings",
                                              {{"effects.cursor", "glow"},
                                               {"effects.border", "frame"},
                                               {"animation.windows_in.effect", "fade"},
                                               {"animation.windows_in.duration_ms", 350}}}}}}});
    save(f.index, f.registry);
    Catalogue catalogue(f.index, f.assets);
    const auto requested = catalogue.family_choices("test", {{"effects.cursor", "cursor/glow"},
                                                             {"effects.border", "border/frame"},
                                                             {"animation.windows_in", "animation/fade"}});
    f.controller->apply(f.controller->prepare(catalogue, requested, "test").at("plan_token"));
    check(load(f.state_root / "state.json")["current"]["settings"]["animation.windows_in.duration_ms"] == 350,
          "Family animation recipe was lost");
    auto &external = f.peer->targets.begin()->second;
    external.value = {"external", "", "runtime", true};
    const auto external_id = f.peer->targets.begin()->first;
    f.controller->undo();
    check(runtime_slots(f.peer->effects()).at(external_id).value.name == "external",
          "Undo replaced an external window selection");
    check(!f.controller->status()["managed"], "Family Undo did not restore entire original selection");
}
void disappeared_targets_and_pool() {
    Fixture f;
    Lock lock(f.state_root);
    f.add("frame", "border");
    f.windows(3);
    bool removed = false;
    f.peer->during_action = [&](const RuntimeSlot &slot) {
        if (!removed && slot.kind == "border") {
            removed = true;
            f.peer->targets.erase(Json::array({slot.kind, slot.target}).dump());
        }
    };
    f.select("border/frame", "effects.border");
    check(removed && f.controller->status()["managed"], "A closing window broke Apply");
    f.peer->during_action = {};
    f.controller->restore();
    atomic_write(f.root / "base.toml",
                 read(f.root / "base.toml") +
                     "[effects.pool.pool]\nkind=\"cursor\"\nchoose=[\"old-a\",\"old-b\"]\n");
    save(f.root / "runtime", Selection{"old-b", "pool", "runtime", true});
    f.choose();
    f.controller->restore();
    check(cursor(f.peer->effects()) == Selection{"old-b", "pool", "runtime", true},
          "Pool member/suppression restoration failed");
}
void schema_two_upgrade() {
    Fixture f;
    Lock lock(f.state_root);
    f.choose();
    auto state = load(f.state_root / "state.json");
    auto generation = state["current"];
    generation.erase("bindings");
    generation.erase("settings");
    generation.erase("presets");
    generation["effect"] = "cursor/glow";
    generation["preset"] = "glow";
    Json old = {{"schema_version", 2},         {"base", state["base"]},
                {"session", state["session"]}, {"current", generation},
                {"previous", nullptr},         {"can_undo", true},
                {"original", Selection{}},     {"owned", Selection{"glow", "", "runtime", false}},
                {"undo_cursor", Selection{}},  {"previous_original", nullptr},
                {"previous_owned", nullptr}};
    save(f.state_root / "state.json", old);
    f.controller->undo();
    check(!f.controller->status()["managed"], "Selection prototype state could not Undo after upgrade");
    check(load(f.state_root / "state.json")["schema_version"] == 3, "Native state did not migrate");
}
void online_cache_and_preview_repair() {
    Fixture f;
    f.file("cursor/glow/preview.png", "synthetic preview bytes");
    f.registry["effects"][0]["preview"]["image"] = "cursor/glow/preview.png";
    save(f.index, f.registry);
    int downloads = 0;
    bool offline = false;
    auto fetch = [&](const std::string &url, size_t limit) {
        ++downloads;
        if (offline)
            throw Error("Offline fixture");
        if (url.ends_with("catalogue/catalogue.json"))
            return f.registry.dump();
        const auto prefix = "https://raw.githubusercontent.com/noctalia-dev/community-umbriel-shaders/" +
                            std::string(40, 'a') + "/";
        require(url.starts_with(prefix), "Unpinned asset URL");
        return read(f.assets / url.substr(prefix.size()), limit);
    };
    const auto cache = f.root / "cache";
    auto cat = Catalogue::online(cache, false, fetch);
    check(downloads == 1 && fs::exists(cache / "catalogue.json"),
          "First online browse did not download and save the index");
    check(!cat.browse()["effects"].empty(), "First online browse returned no effects");
    const auto modified = fs::last_write_time(cache / "catalogue.json");
    (void)cat.browse();
    check(downloads == 1, "Browse downloaded previews");
    auto preview = cat.previews({"cursor/glow"});
    const auto path = preview["cursor/glow"]["image"].get<std::string>();
    check(downloads == 2 && fs::exists(path), "Visible preview was not fetched");
    atomic_write(path, "bad");
    preview = cat.previews({"cursor/glow"});
    check(downloads == 3 && read(path) == "synthetic preview bytes", "Corrupt preview did not repair");
    atomic_write(path, std::string(100, 'x'));
    preview = cat.previews({"cursor/glow"});
    check(downloads == 4 && read(path) == "synthetic preview bytes", "Oversized preview did not repair");
    cat = Catalogue::online(cache, true, fetch);
    check(fs::last_write_time(cache / "catalogue.json") == modified, "Unchanged index was rewritten");
    const auto calls = downloads;
    (void)Catalogue::online(cache, false, fetch).browse();
    check(downloads == calls, "Cached browse requested network");
    offline = true;
    fails([&] { Catalogue::online(f.root / "empty-cache", false, fetch); }, "Offline fixture");
    check(!fs::exists(f.root / "empty-cache/catalogue.json"), "Failed first download left a cache file");
    check(Catalogue::online(cache, true, fetch).browse()["offline"], "Network failure lost saved catalogue");
    fs::remove(path);
    fs::create_symlink(f.root / "base.toml", path);
    preview = cat.previews({"cursor/glow"});
    check(preview["cursor/glow"].contains("error") && read(f.root / "base.toml").starts_with("[effects]"),
          "Preview repair followed a symlink");
    fails([&] { download("http://localhost/asset", 10); }, "origin");
}
void local_cache_and_catalogue_pages() {
    Fixture f;
    for (const auto *name : {"glow", "second"}) {
        const auto id = std::string("cursor/") + name;
        atomic_write(f.assets / id / "metadata.toml",
                     "name=" + quoted(name) +
                         "\ndescription=\"Fixture\"\nauthor=\"Test\"\nlicense=\"MIT\"\nnotice_files=[" +
                         quoted(id + "/README.md") + "]\n");
        atomic_write(f.assets / id / "config.toml", "[include]\nfiles=[" +
                                                        quoted("shaders/community/" + id + "/effect.toml") +
                                                        "]\n[effects]\ncursor=" + quoted(name) + "\n");
    }
    auto cat = Catalogue::local(f.assets, f.root / "local");
    check(cat.browse()["effects"].size() == 2, "Local catalogue did not discover authoring files");
    const auto cache =
        f.root / "local" / sha256(fs::absolute(f.assets).string()).substr(0, 16) / "catalogue.json";
    const auto modified = fs::last_write_time(cache);
    (void)Catalogue::local(f.assets, f.root / "local");
    check(fs::last_write_time(cache) == modified, "Warm local catalogue rewrote the index");
    atomic_write(f.assets / "cursor/glow/README.md", "Changed attribution");
    cat = Catalogue::local(f.assets, f.root / "local");
    check(cat.registry()["files"]["cursor/glow/README.md"]["sha256"] == sha256("Changed attribution"),
          "Local cache missed a file edit");
    Json large = f.registry;
    large["effects"] = Json::array();
    large["files"] = Json::object();
    for (int i = 0; i < 400; ++i) {
        const auto id = "cursor/entry-" + std::to_string(i);
        auto effect = f.registry["effects"][0];
        effect["id"] = id;
        effect["path"] = id;
        effect["preset"] = "entry-" + std::to_string(i);
        effect["description"] = std::string(2000, 'x');
        effect["activation"]["settings"]["effects.cursor"] = effect["preset"];
        effect["notice_files"] = {id + "/README.md"};
        effect["install_files"] = {id + "/README.md", id + "/effect.toml", id + "/shader.glsl"};
        for (const auto &path : effect["install_files"])
            large["files"][path.get<std::string>()] = {{"bytes", size_t(1)}, {"sha256", sha256("x")}};
        large["effects"].push_back(effect);
    }
    Catalogue paged(large);
    size_t offset = 0, seen = 0, pages = 0;
    do {
        const auto page = paged.browse(offset);
        ++pages;
        seen += page["effects"].size();
        check(page.dump().size() < 768 * 1024, "Catalogue page exceeds transport budget");
        if (page["next_offset"].is_null())
            break;
        check(page["next_offset"].get<size_t>() > offset, "Catalogue pagination did not progress");
        offset = page["next_offset"];
    } while (pages < 20);
    check(seen == 400 && pages > 1, "Catalogue pagination lost effects");
}

} // namespace
int main() {
    try {
        for (const auto &[name, test] : std::vector<std::pair<std::string, std::function<void()>>>{
                 {"apply/undo/restore", basics},
                 {"review validation", validation},
                 {"failure rollback", failures},
                 {"process crash recovery", crash_recovery},
                 {"installed reuse", reuse_and_catalogue},
                 {"optional local comparison and JSON depth", optional_local_comparison},
                 {"bounds and base reuse", bounds_and_local},
                 {"external changes", external_changes},
                 {"explicit base adoption and restarted recovery", adoption_and_restart_recovery},
                 {"integrity and concurrent changes", integrity_and_races},
                 {"mixed effects and withdrawal", mixed_effects_and_withdrawal},
                 {"installed border with base overlay", installed_border_base_overlay},
                 {"bounded window state and batched IPC", windows_bounded_and_batched},
                 {"family recipes and external selections", families_and_external_targets},
                 {"disappeared targets and pools", disappeared_targets_and_pool},
                 {"cursor state migration", schema_two_upgrade},
                 {"online cache and preview repair", online_cache_and_preview_repair},
                 {"local invalidation and catalogue pagination", local_cache_and_catalogue_pages}}) {
            test();
            std::cout << "PASS " << name << std::endl;
        }
        std::cout << assertions << " assertions passed\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
