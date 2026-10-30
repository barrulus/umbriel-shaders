// SPDX-License-Identifier: MIT
#pragma once
#include "core.hpp"
#include <functional>
#include <sstream>
#include <unistd.h>
using namespace shaders;
Json parse_toml(const fs::path &path) {
    std::ostringstream stream;
    stream << toml::json_formatter(toml::parse(read(path)));
    return Json::parse(stream.str());
}
struct FakePeer final : Peer {
    fs::path root, config;
    Session identity;
    bool fail_compile = false, reject = false, fail_rollback = false, crash = false;
    int switches = 0, queries = 0, actions = 0;
    Runtime targets;
    std::function<void(const RuntimeSlot &)> during_action;
    std::function<void()> during_validation;
    explicit FakePeer(fs::path directory)
        : root(directory), config(root / "base.toml"), identity{10, "start", "boot", "/fake/socket"} {
        if (!fs::exists(root / "active"))
            atomic_write(root / "active", config.string());
        if (!fs::exists(root / "runtime"))
            save(root / "runtime", Selection{});
    }
    Session session() const override {
        return identity;
    }
    std::map<std::string, std::string> environment() const override {
        return {{"HOME", root.string()}};
    }
    fs::path base() const override {
        return config;
    }
    Json effects() override {
        ++queries;
        return snapshot();
    }
    Json snapshot() {
        Json presets = Json::object(), pools = Json::object();
        Json defaults = Json::object();
        std::function<void(fs::path)> visit = [&](const fs::path &path) {
            auto data = parse_toml(path);
            for (const auto &included : data.value("include", Json::object()).value("files", Json::array()))
                visit(path.parent_path() / included.get<std::string>());
            const auto effects = data.value("effects", Json::object());
            presets.update(effects.value("preset", Json::object()));
            pools.update(effects.value("pool", Json::object()));
            for (const auto *kind : {"cursor", "border", "window", "screen"})
                if (effects.contains(kind))
                    defaults[kind] = effects.at(kind);
        };
        visit(read(root / "active"));
        auto runtime = load(root / "runtime").get<Selection>();
        if (runtime.source != "runtime")
            runtime.name = defaults.value("cursor", "");
        Json list = Json::array(), pool_list = Json::array();
        for (const auto &[name, def] : presets.items())
            list.push_back({{"name", name},
                            {"kind", def.at("kind")},
                            {"state", fail_compile && name == "glow" ? "failed" : "compiled"}});
        for (const auto &[name, def] : pools.items()) {
            Json members = Json::array();
            for (const auto &member : def.at("choose"))
                members.push_back({{"name", member}});
            pool_list.push_back({{"name", name}, {"members", members}});
        }
        Json owners = Json::array();
        std::map<std::string, Json> grouped;
        for (const auto &[key, record] : targets) {
            (void)key;
            auto &owner = grouped[record.target];
            const auto type = record.kind == "screen" ? "output" : "window";
            owner["type"] = type;
            owner[record.kind == "screen" ? "name" : "id"] = record.target;
            auto value = record.value;
            if (value.source != "runtime")
                value.name = defaults.value(record.kind, "");
            owner["slots"][record.kind] = value;
        }
        for (const auto &[key, owner] : grouped) {
            (void)key;
            owners.push_back(owner);
        }
        return {{"presets", list}, {"cursor", runtime}, {"owners", owners}, {"pools", pool_list}};
    }
    void validate(const fs::path &path) override {
        parse_toml(path);
        if (during_validation)
            during_validation();
    }
    void replace(const fs::path &path) override {
        if (reject) {
            reject = false;
            throw Error("Rejected replacement");
        }
        if (fail_rollback && path == config)
            throw Error("Rollback failed");
        atomic_write(root / "active", path.string());
        ++switches;
        if (crash)
            _exit(71);
    }
    void action(const RuntimeSlot &slot, const std::string &operation,
                const std::string &selector = "") override {
        ++actions;
        if (during_action)
            during_action(slot);
        const auto id = Json::array({slot.kind, slot.target}).dump();
        auto live = runtime_slots(snapshot());
        require(live.contains(id), "Target disappeared");
        auto runtime = live.at(id).value;
        if (operation == "set") {
            runtime = {selector, "", "runtime", false};
            const auto report = snapshot();
            for (const auto &pool : report.at("pools"))
                if (pool.at("name").get<std::string>() == selector) {
                    runtime.pool = selector;
                    runtime.name = pool.at("members")[0].at("name");
                }
        } else if (operation == "reset")
            runtime = Selection{};
        else if (operation == "toggle")
            runtime.suppressed = !runtime.suppressed;
        else if (operation == "cycle") {
            const auto report = snapshot();
            for (const auto &pool : report.at("pools"))
                if (pool.at("name").get<std::string>() == selector) {
                    const auto &members = pool.at("members");
                    for (size_t i = 0; i < members.size(); ++i)
                        if (members[i].at("name").get<std::string>() == runtime.name) {
                            runtime.name = members[(i + 1) % members.size()].at("name");
                            break;
                        }
                }
        }
        if (slot.kind == "cursor")
            save(root / "runtime", runtime);
        else
            targets.at(id).value = runtime;
    }
};
