// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <chrono>
#include <set>
#include <thread>

namespace shaders {
namespace {
Json optional_hash(const fs::path &path) {
    return fs::exists(path) ? Json(sha256(read(path))) : Json(nullptr);
}
} // namespace
Controller::Controller(fs::path root, Peer &peer, fs::path base)
    : root_(fs::absolute(root)), base_(base), explicit_base_(!base.empty()), peer_(peer) {
    require(!fs::is_symlink(root_), "State directory cannot be a symlink");
    if (base_.empty()) {
        if (fs::exists(root_ / "state.json"))
            base_ = decode_state(load(root_ / "state.json")).base;
        else
            base_ = peer_.base();
    }
    require(base_.is_absolute(), "Choose an absolute original configuration path");
}
void Controller::check_generation(const Generation &generation) const {
    require(valid_token(generation.token), "Invalid saved generation ID");
    auto directory = contained(root_, "generations/" + generation.token);
    require(generation.config == (directory / "config.toml").string(),
            "Saved generation path is outside managed storage");
    require(generation.files.contains(generation.config) &&
                generation.files.contains((directory / "marker.glsl").string()),
            "Generation fingerprints are incomplete");
    for (const auto &[name, hash] : generation.files) {
        (void)hash;
        auto relative = fs::path(name).lexically_relative(root_).generic_string();
        require(contained(root_, relative) == fs::path(name), "Generation references foreign files");
    }
}
State Controller::state() const {
    State value;
    if (fs::exists(root_ / "state.json"))
        value = decode_state(load(root_ / "state.json"));
    else {
        value.base = base_.string();
        value.session = peer_.session();
    }
    if (value.current)
        check_generation(*value.current);
    if (value.previous)
        check_generation(*value.previous);
    return value;
}
bool Controller::owned(const State &state, const Json &report) const {
    return state.session == peer_.session() && state.current &&
           markers(report) == std::vector<std::string>{std::string(marker_prefix) + state.current->token};
}
fs::path Controller::target(const State &state) const {
    return state.current ? fs::path(state.current->config) : fs::path(state.base);
}
Json Controller::status() {
    const auto saved = state();
    const auto report = peer_.effects();
    bool managed = owned(saved, report);
    Json selections = Json::object();
    if (saved.current)
        for (const auto &[slot, binding] : saved.current->bindings)
            selections[slot] = binding.id;
    return {{"managed", managed},
            {"pending", fs::exists(root_ / "pending.json")},
            {"can_undo", managed && saved.can_undo},
            {"can_restore", managed},
            {"base", base_.string()},
            {"selections", selections},
            {"cursor", cursor(report).name},
            {"message",
             managed ? "Native shader selections are active." : "Choose an effect to review and apply."}};
}
void Controller::cleanup(const State &state) {
    if (fs::exists(root_ / "pending.json"))
        return;
    std::set<std::string> keep;
    if (state.current)
        keep.insert(state.current->token);
    if (state.previous)
        keep.insert(state.previous->token);
    if (fs::exists(root_ / "plan.json")) {
        const auto plan = load(root_ / "plan.json");
        if (now() - plan.at("created").get<long>() < 900)
            keep.insert(plan.at("generation").at("token").get<std::string>());
        else
            durable_remove(root_ / "plan.json");
    }
    const auto generations = contained(root_, "generations");
    if (!fs::exists(generations))
        return;
    for (const auto &entry : fs::directory_iterator(generations)) {
        auto id = entry.path().filename().string();
        if (valid_token(id) && !keep.contains(id) && !entry.is_symlink())
            fs::remove_all(entry.path());
    }
}
Json Controller::prepare(const Catalogue &catalogue, const std::string &effect, const std::string &slot,
                         bool compare_local) {
    auto result = prepare(catalogue, std::map<std::string, std::string>{{slot, effect}}, "", compare_local);
    result["effect_id"] = effect;
    result["slot"] = slot;
    return result;
}
Json Controller::prepare(const Catalogue &catalogue, const std::map<std::string, std::string> &requested,
                         const std::string &family, bool compare_local) {
    require(!requested.empty(), "Choose at least one effect or slot to remove");
    require(!fs::exists(root_ / "pending.json"), "Recover the interrupted operation first");
    auto before = state();
    const auto report = peer_.effects();
    require(before.session.socket == peer_.session().socket, "State belongs to another compositor socket");
    const bool managed = owned(before, report);
    const bool adopted = before.current && before.session == peer_.session() && !managed;
    if (adopted) {
        require(explicit_base_ && markers(report).empty(),
                "Another configuration replaced the native wrapper; choose its original base path explicitly "
                "and review again");
        before = State{};
        before.base = base_.string();
        before.session = peer_.session();
    } else if (before.current && before.session == peer_.session())
        require(managed, "Another configuration replaced the native wrapper");
    else
        require(markers(report).empty(), "Another managed plugin generation is active; restore it first");
    require(!managed || before.base == base_.string(), "Restore before changing the base path");
    durable_remove(root_ / "plan.json");
    cleanup(before);
    auto graph = config_graph(base_, peer_.environment());
    auto bindings = before.current ? before.current->bindings : Bindings{};
    for (const auto &[slot, id] : requested) {
        require(valid_slot(slot), "Unsupported effect slot: " + slot);
        if (id.empty())
            bindings.erase(slot);
        else
            bindings[slot] = catalogue.binding(id, slot, family);
    }
    Json settings = Json::object(), requirements = Json::object();
    std::set<std::string> features;
    for (const auto &[slot, binding] : bindings) {
        (void)slot;
        for (const auto &[key, value] : binding.settings.items()) {
            require(!settings.contains(key) || settings.at(key) == value,
                    "Conflicting activation settings: " + key);
            settings[key] = value;
        }
        for (const auto &[key, value] : binding.required.items()) {
            require(!requirements.contains(key) || requirements.at(key) == value,
                    "Conflicting shader requirements: " + key);
            requirements[key] = value;
        }
        features.insert(binding.features.begin(), binding.features.end());
    }
    for (const auto &[key, value] : requirements.items()) {
        require(!settings.contains(key) || settings.at(key) == value,
                "Required setting conflicts with selection: " + key);
        if (key == "animation.enabled" || bindings.contains(setting_scope(key)))
            settings[key] = value;
        else
            require(graph.settings.contains(key) && graph.settings.at(key) == value,
                    "Required base setting must be resolved: " + key);
    }
    const auto selected = catalogue.resolve(bindings, graph, contained(root_, "library"), compare_local);
    const auto id = token();
    const auto directory = contained(root_, "generations/" + id);
    const auto config = directory / "config.toml", shader = directory / "marker.glsl";
    Generation generation;
    generation.token = id;
    generation.config = config.string();
    generation.files = selected.files;
    generation.bindings = bindings;
    generation.settings = settings;
    generation.presets.assign(selected.presets.begin(), selected.presets.end());
    try {
        atomic_write(shader, "vec4 cursor(vec2 uv) { return umbriel_sample(uv); }\n");
        std::string text = "# Managed by Umbriel Shaders. Edit the original configuration.\n";
        for (const auto &[key, value] : settings.items()) {
            std::string dotted;
            size_t start = 0;
            while (start < key.size()) {
                const auto end = key.find('.', start);
                if (!dotted.empty())
                    dotted += ".";
                dotted += quoted(key.substr(start, end == std::string::npos ? end : end - start));
                if (end == std::string::npos)
                    break;
                start = end + 1;
            }
            text += dotted + " = " + value_toml(value) + "\n";
        }
        text += "[include]\nfiles = [" + quoted(base_.string()) + "]\n";
        for (const auto &[name, definition] : selected.definitions) {
            text += "[effects.preset." + quoted(name) + "]\n";
            for (const auto &[key, value] : definition.items())
                text += quoted(key) + " = " + value_toml(value) + "\n";
        }
        text += "[effects.preset." + quoted(std::string(marker_prefix) + id) +
                "]\nkind = \"cursor\"\nshader = \"marker.glsl\"\nradius = 1\n";
        if (graph.drm)
            text += "[drm]\n";
        atomic_write(config, text);
        peer_.validate(config);
        verify(graph.files);
        verify(selected.files);
        generation.files[config.string()] = fingerprint(config);
        generation.files[shader.string()] = fingerprint(shader);
        save(root_ / "plan.json", {{"schema_version", 2},
                                   {"created", now()},
                                   {"base", base_.string()},
                                   {"session", peer_.session()},
                                   {"state_hash", optional_hash(root_ / "state.json")},
                                   {"generation", generation},
                                   {"base_files", graph.files},
                                   {"observed", selection_stamp(report)},
                                   {"requested", requested},
                                   {"adopted", adopted}});
    } catch (...) {
        std::error_code ignored;
        fs::remove_all(directory, ignored);
        throw;
    }
    auto previous = graph.settings;
    if (before.current)
        previous.update(before.current->settings);
    Json changes = Json::array();
    for (const auto &[key, value] : settings.items())
        changes.push_back({{"key", key}, {"before", previous.value(key, Json(nullptr))}, {"after", value}});
    for (const auto &[key, value] : previous.items()) {
        (void)value;
        if (before.current && before.current->settings.contains(key) && !settings.contains(key))
            changes.push_back({{"key", key},
                               {"before", previous.at(key)},
                               {"after", graph.settings.value(key, Json(nullptr))}});
    }
    Json unknown = Json::array();
    for (const auto &feature : features)
        if (feature != "preset-effects")
            unknown.push_back(feature);
    auto result = status();
    result.update({{"plan_token", id},
                   {"family_id", family},
                   {"changes", changes},
                   {"local_copies", selected.local_copies},
                   {"dependencies", generation.presets},
                   {"compatibility",
                    {{"status", unknown.empty() ? "compatible" : "unknown"},
                     {"unknown", unknown},
                     {"incompatible", Json::array()}}},
                   {"features", catalogue.registry().at("feature_definitions")},
                   {"message", "Shader selection validated and ready."}});
    return result;
}
void Controller::confirm(const State &state) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
    do {
        const auto report = peer_.effects();
        if (!state.current) {
            require(markers(report).empty(), "Original configuration still has a managed generation");
            return;
        }
        require(owned(state, report), "Active generation differs from requested configuration");
        std::map<std::string, std::string> presets;
        for (const auto &preset : report.at("presets"))
            presets[preset.at("name")] = preset.at("state");
        bool ready = true;
        for (const auto &name : state.current->presets) {
            require(presets.contains(name), "Selected shader preset is not loaded: " + name);
            require(presets.at(name) != "failed" && presets.at(name) != "error",
                    "Shader failed GPU compilation: " + name);
            ready = ready && presets.at(name) == "compiled";
        }
        if (ready)
            return;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    } while (std::chrono::steady_clock::now() < deadline);
    throw Error("Shader compilation could not be verified");
}
namespace {
void prune_state(State &state, const Runtime &live) {
    for (auto *records : {&state.original, &state.owned, &state.undo_runtime, &state.previous_original,
                          &state.previous_owned})
        prune(*records, live);
}
Runtime restored(const Runtime &live, const Runtime &owned, const Runtime &original) {
    auto desired = live;
    for (const auto &[id, record] : original)
        if (live.contains(id) && owned.contains(id) && live.at(id) == owned.at(id))
            desired[id] = record;
    return desired;
}
} // namespace
void Controller::rollback(const Json &journal) {
    auto before = decode_state(journal.at("before"));
    auto after = decode_state(journal.at("after"));
    require(before.session == peer_.session(), "Compositor restarted; explicit recovery is required");
    const auto report = peer_.effects();
    require(owned(before, report) || owned(after, report) ||
                ((!before.current || !after.current) && markers(report).empty()),
            "Recovery stopped because a foreign managed configuration is active");
    if (before.current) {
        check_generation(*before.current);
        verify(before.current->files);
    }
    peer_.validate(target(before));
    peer_.replace(target(before));
    auto desired = journal.value("runtime_before", Runtime{});
    if (journal.contains("cursor_before"))
        desired[Json::array({"cursor", ""}).dump()] = {"cursor", "",
                                                       journal.at("cursor_before").get<Selection>()};
    restore_runtime(peer_, desired);
    confirm(before);
    prune_state(before, runtime_slots(peer_.effects()));
    save(root_ / "state.json", encode(before));
    durable_remove(root_ / "pending.json");
}
void Controller::transact(State before, State after, const Runtime &desired, const Files &base_files,
                          const Json &expected) {
    if (after.current) {
        check_generation(*after.current);
        verify(after.current->files);
    }
    peer_.validate(target(after));
    verify(base_files);
    const auto report = peer_.effects();
    require(before.current ? owned(before, report) : markers(report).empty(),
            "Configuration changed during validation");
    require(selection_stamp(report) == expected, "Live selections changed during validation; review again");
    const auto live = runtime_slots(report);
    prune_state(before, live);
    prune_state(after, live);
    const Json journal = {{"schema_version", 2},
                          {"before", encode(before)},
                          {"after", encode(after)},
                          {"runtime_before", live}};
    save(root_ / "pending.json", journal);
    try {
        peer_.replace(target(after));
        restore_runtime(peer_, desired);
        confirm(after);
        verify(base_files);
        prune_state(after, runtime_slots(peer_.effects()));
        save(root_ / "state.json", encode(after));
    } catch (const std::exception &error) {
        const std::string message = error.what();
        try {
            rollback(journal);
        } catch (const std::exception &recovery) {
            throw Error(message + "; recovery is pending: " + recovery.what());
        }
        throw Error(message + "; previous configuration restored");
    }
    durable_remove(root_ / "pending.json");
    try {
        durable_remove(root_ / "plan.json");
        cleanup(after);
    } catch (const std::exception &) {
    }
}
Json Controller::apply(const std::string &id) {
    require(!fs::exists(root_ / "pending.json"), "Recover the interrupted operation first");
    require(valid_token(id), "Invalid review token");
    const auto plan = load(root_ / "plan.json");
    require(plan.at("schema_version") == 2 && plan.at("generation").at("token") == id,
            "Review is no longer current");
    require(plan.at("base") == base_.string() && plan.at("session").get<Session>() == peer_.session(),
            "Base or compositor changed after review");
    const auto age = now() - plan.at("created").get<long>();
    require(age >= 0 && age < 900, "Review expired");
    require(plan.at("state_hash") == optional_hash(root_ / "state.json"),
            "Saved selections changed after review");
    const auto report = peer_.effects();
    require(plan.at("observed") == selection_stamp(report), "Live selections changed after review");
    const auto base_files = plan.at("base_files").get<Files>();
    verify(base_files);
    auto before = state();
    if (before.session != peer_.session() || plan.value("adopted", false)) {
        before = State{};
        before.session = peer_.session();
        before.base = base_.string();
    }
    if (!before.current)
        before.base = base_.string();
    const auto live = runtime_slots(report);
    prune_state(before, live);
    auto after = before;
    after.current = plan.at("generation").get<Generation>();
    after.previous = before.current;
    after.can_undo = true;
    after.previous_original = before.original;
    after.previous_owned = before.owned;
    after.undo_runtime.clear();
    auto desired = live;
    for (const auto &[key, record] : live) {
        const auto slot = "effects." + record.kind;
        if (!plan.at("requested").contains(slot))
            continue;
        after.undo_runtime[key] = record;
        if (after.current->bindings.contains(slot)) {
            after.original.try_emplace(key, record);
            desired[key].value = {after.current->bindings.at(slot).name, "", "runtime", false};
            after.owned[key] = desired.at(key);
        } else {
            if (before.original.contains(key) && before.owned.contains(key) && record == before.owned.at(key))
                desired[key] = before.original.at(key);
            after.original.erase(key);
            after.owned.erase(key);
        }
    }
    transact(before, after, desired, base_files, selection_stamp(report));
    auto result = status();
    result["message"] = "Shader selections applied and GPU compilation verified.";
    return result;
}
Json Controller::undo() {
    require(!fs::exists(root_ / "pending.json"), "Recover the interrupted operation first");
    const auto before = state();
    const auto report = peer_.effects();
    require(owned(before, report) && before.can_undo, "No owned selection to undo");
    auto after = before;
    after.current = before.previous;
    after.previous.reset();
    after.can_undo = false;
    after.original = before.previous_original;
    after.owned = before.previous_owned;
    after.undo_runtime.clear();
    after.previous_original.clear();
    after.previous_owned.clear();
    const auto live = runtime_slots(report);
    auto desired = restored(live, before.owned, before.undo_runtime);
    // Removing a slot releases ownership. Undo may reapply it only if its restored value is unchanged.
    for (const auto &[id, original] : before.undo_runtime) {
        if (!before.owned.contains(id) && live.contains(id) && before.previous_original.contains(id)) {
            const auto &released = before.previous_original.at(id).value;
            const auto &actual = live.at(id).value;
            if (released.source == "runtime"
                    ? actual == released
                    : actual.source != "runtime" && actual.suppressed == released.suppressed)
                desired[id] = original;
        }
    }
    transact(before, after, desired, config_graph(before.base, peer_.environment()).files,
             selection_stamp(report));
    auto result = status();
    result["message"] = "Previous shader selections restored.";
    return result;
}
Json Controller::restore() {
    require(!fs::exists(root_ / "pending.json"), "Recover the interrupted operation first");
    const auto before = state();
    const auto report = peer_.effects();
    if (!owned(before, report))
        return status();
    State after;
    after.base = before.base;
    after.session = peer_.session();
    const auto desired = restored(runtime_slots(report), before.owned, before.original);
    transact(before, after, desired, config_graph(before.base, peer_.environment()).files,
             selection_stamp(report));
    auto result = status();
    result["message"] = "Original configuration restored.";
    return result;
}
Json Controller::recover() {
    require(fs::exists(root_ / "pending.json"), "No interrupted operation to recover");
    auto journal = load(root_ / "pending.json");
    require(journal.at("schema_version") == 1 || journal.at("schema_version") == 2,
            "Unsupported recovery journal");
    const auto before = decode_state(journal.at("before"));
    require(before.session.socket == peer_.session().socket, "Recovery belongs to another compositor socket");
    if (before.session != peer_.session()) {
        const auto report = peer_.effects();
        auto after = decode_state(journal.at("after"));
        auto prior = before;
        // A restarted compositor may have loaded the interrupted wrapper. Accept
        // only a generation recorded in this journal, and discard old window IDs.
        after.session = peer_.session();
        prior.session = peer_.session();
        require(markers(report).empty() || owned(prior, report) || owned(after, report),
                "Recovery stopped because a foreign managed configuration is active");
        State original;
        original.base = before.base;
        original.session = peer_.session();
        journal["before"] = encode(original);
        journal["after"] = encode(owned(prior, report) ? prior : owned(after, report) ? after : original);
        journal.erase("cursor_before");
        journal["runtime_before"] = Runtime{};
    }
    rollback(journal);
    try {
        durable_remove(root_ / "plan.json");
        cleanup(state());
    } catch (const std::exception &) {
    }
    auto result = status();
    result["message"] = "Interrupted native operation recovered.";
    return result;
}
} // namespace shaders
