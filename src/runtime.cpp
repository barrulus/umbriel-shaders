// SPDX-License-Identifier: MIT
#include "core.hpp"

namespace shaders {
namespace {
std::string key(const std::string &kind, const std::string &target) {
    return Json::array({kind, target}).dump();
}
void validate(const RuntimeSlot &slot) {
    require(slot.kind == "cursor" || slot.kind == "border" || slot.kind == "window" || slot.kind == "screen",
            "Invalid runtime effect kind");
    require((slot.kind == "cursor") == slot.target.empty(), "An explicit effect target is required");
    require(slot.target.size() <= 512 && slot.target.find('\0') == std::string::npos,
            "Invalid runtime target");
    require(slot.value.source == "runtime" || slot.value.source == "default" || slot.value.source == "rule",
            "Invalid runtime selection source");
}
} // namespace
Runtime runtime_slots(const Json &report) {
    Runtime result;
    auto add = [&](const std::string &kind, const std::string &target, const Json &item) {
        RuntimeSlot slot{kind,
                         target,
                         {item.value("name", ""), item.value("pool", ""), item.value("source", "default"),
                          item.value("suppressed", false)}};
        validate(slot);
        require(result.emplace(key(kind, target), slot).second, "Duplicate live effect target");
    };
    if (report.contains("cursor"))
        add("cursor", "", report.at("cursor"));
    for (const auto &owner : report.value("owners", Json::array())) {
        const auto type = owner.value("type", "");
        if (type != "window" && type != "output")
            continue;
        const auto target = owner.value(type == "window" ? "id" : "name", "");
        if (target.empty())
            continue;
        const auto slots = owner.value("slots", Json::object());
        for (const auto &[kind, value] : slots.items()) {
            if ((type == "window" && (kind == "border" || kind == "window")) ||
                (type == "output" && kind == "screen"))
                add(kind, target, value);
        }
    }
    require(result.size() <= 2048, "Too many live effect targets");
    return result;
}
void prune(Runtime &records, const Runtime &live) {
    std::erase_if(records, [&](const auto &item) { return !live.contains(item.first); });
}
void restore_runtime(Peer &peer, const Runtime &desired) {
    // One shared report before a batch and one afterwards. Only pool cycling and
    // target-disappearance races need additional full reports.
    auto report = peer.effects();
    auto live = runtime_slots(report);
    for (const auto &[id, record] : desired) {
        validate(record);
        require(id == key(record.kind, record.target), "Saved runtime target identity mismatch");
        if (!live.contains(id))
            continue;
        try {
            auto actual = live.at(id).value;
            const auto &value = record.value;
            if (value.source == "runtime") {
                require(!value.name.empty() || !value.pool.empty(), "Empty runtime effect selector");
                if (actual.name != value.name || actual.pool != value.pool || actual.source != "runtime") {
                    peer.action(record, "set", value.pool.empty() ? value.name : value.pool);
                    actual = {value.name, value.pool, "runtime", false};
                    if (!value.pool.empty()) {
                        size_t count = 0;
                        for (const auto &pool : report.at("pools"))
                            if (pool.at("name") == value.pool)
                                count = pool.at("members").size();
                        require(count > 0 && count <= 256,
                                "Previous effect pool is unavailable or too large");
                        for (size_t n = 0; n < count; ++n) {
                            live = runtime_slots(peer.effects());
                            if (!live.contains(id) || live.at(id).value.name == value.name)
                                break;
                            peer.action(record, "cycle", value.pool);
                        }
                        if (!live.contains(id))
                            continue;
                        actual = live.at(id).value;
                    }
                }
            } else if (actual.source == "runtime") {
                peer.action(record, "reset");
                actual = Selection{};
            }
            if (actual.suppressed != value.suppressed)
                peer.action(record, "toggle");
        } catch (const std::exception &) {
            live = runtime_slots(peer.effects());
            if (live.contains(id))
                throw;
        }
    }
    live = runtime_slots(peer.effects());
    for (const auto &[id, record] : desired) {
        if (!live.contains(id))
            continue;
        const auto &actual = live.at(id).value;
        require(actual.suppressed == record.value.suppressed &&
                    (record.value.source == "runtime" ? actual == record.value : actual.source != "runtime"),
                "Effect restoration could not be verified for " + record.kind + " " + record.target);
    }
}
} // namespace shaders
