// SPDX-License-Identifier: MIT
#include "core.hpp"

namespace shaders {
Json diagnostics(const fs::path &root, Peer *peer, const std::string &live_error) {
    Json issues = Json::array(), sections = Json::array();
    const auto section = [&](const std::string &title, std::string text) {
        if (text.size() > 24000)
            text = text.substr(0, 24000) + "\n[Truncated]";
        sections.push_back({{"title", title}, {"text", text}});
    };
    std::optional<State> state;
    try {
        if (fs::exists(root / "state.json"))
            state = decode_state(load(root / "state.json"));
    } catch (const std::exception &error) {
        issues.push_back(error.what());
    }
    const bool pending = fs::exists(root / "pending.json");
    bool managed = false;
    std::string live = live_error;
    if (peer) {
        try {
            const auto report = peer->effects();
            managed = state && state->session == peer->session() && state->current &&
                      markers(report) ==
                          std::vector<std::string>{std::string(marker_prefix) + state->current->token};
            live = "Live effect selections (window IDs and app IDs omitted):\n";
            size_t count = 0;
            for (const auto &[id, slot] : runtime_slots(report)) {
                (void)id;
                if (++count > 100) {
                    live += "[Target list truncated]\n";
                    break;
                }
                live += slot.kind + ": " + slot.value.name + " · " + slot.value.source +
                        (slot.value.pool.empty() ? "" : " · pool=" + slot.value.pool) +
                        (slot.value.suppressed ? " · suppressed" : "") + "\n";
            }
            live += "\nCompilation states:\n";
            for (const auto &preset : report.at("presets"))
                if (!preset.at("name").get<std::string>().starts_with(marker_prefix))
                    live += preset.at("name").get<std::string>() + ": " +
                            preset.at("state").get<std::string>() + "\n";
            live +=
                "\nAnimation event settings are saved intent; the live effects query does not expose them.\n";
        } catch (const std::exception &error) {
            live = error.what();
            issues.push_back(live);
        }
    }
    section("Overview", "Umbriel Shaders native diagnostic report\nData: " + root.string() +
                            "\nManaged selection: " + (managed ? "yes" : "no") +
                            "\nRecovery pending: " + (pending ? "yes" : "no") +
                            "\nIncludes local paths and selected shader names. Original configuration "
                            "contents and environment values are excluded.\n");
    section("Original configuration", state ? state->base : "No saved base configuration.");
    if (state && state->current) {
        try {
            section("Managed configuration", read(state->current->config, 256 * 1024));
        } catch (const std::exception &error) {
            issues.push_back(error.what());
            section("Managed configuration", error.what());
        }
        section("Saved selections", Json(state->current->bindings).dump(2));
    } else {
        section("Managed configuration", "No active saved generation.");
        section("Saved selections", "No saved selections.");
    }
    section("Live state", live.empty() ? "Umbriel is unavailable." : live);
    try {
        section("Last operation", fs::exists(root / "operation.json") ? load(root / "operation.json").dump(2)
                                                                      : "No recorded operation.");
    } catch (const std::exception &error) {
        issues.push_back(error.what());
        section("Last operation", error.what());
    }
    std::string text;
    for (const auto &item : sections)
        text += item.at("title").get<std::string>() + "\n" + item.at("text").get<std::string>() + "\n\n";
    return {{"generated", std::to_string(now())},
            {"managed", managed},
            {"pending", pending},
            {"issues", issues},
            {"sections", sections},
            {"report_text", text}};
}
} // namespace shaders
