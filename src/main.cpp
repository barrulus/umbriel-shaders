// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <cstdlib>
#include <iostream>

using namespace shaders;
namespace {
std::string env(const char *key) {
    const auto *value = std::getenv(key);
    return value ? value : "";
}
fs::path socket_path() {
    if (!env("UMBRIEL_SOCKET").empty())
        return env("UMBRIEL_SOCKET");
    auto runtime = env("XDG_RUNTIME_DIR"), display = env("WAYLAND_DISPLAY");
    require(!runtime.empty() && !display.empty() && display.find('/') == std::string::npos,
            "Cannot identify the Umbriel session; supply --socket");
    return fs::path(runtime) / ("umbriel-" + display + ".sock");
}
} // namespace
int main(int argc, char **argv) {
    fs::path root;
    std::unique_ptr<SocketPeer> peer;
    bool logging = false;
    Json operation;
    const auto record = [&](const std::string &outcome, const std::string &message) {
        if (!logging)
            return;
        try {
            operation["outcome"] = outcome;
            operation["message"] = message;
            if (outcome != "running")
                operation["finished"] = now();
            save(root / "operation.json", operation);
        } catch (const std::exception &) {
        }
    };
    try {
        std::map<std::string, std::string> options;
        std::string action;
        bool wait_lock = false, compare_local = false;
        for (int i = 1; i < argc; ++i) {
            const std::string value = argv[i];
            if (value == "--compare-local") {
                compare_local = true;
                continue;
            }
            if (value == "--wait-lock") {
                wait_lock = true;
                continue;
            }
            if (value == "--version") {
                std::cout << "umbriel-shaders-native 0.2.0 protocol=1 state=3\n";
                return 0;
            }
            if (value == "--help") {
                std::cout
                    << "Usage: umbriel-shaders-native --state-dir PATH [options] ACTION\n"
                       "  --source-mode online|local|snapshot  --source-root CHECKOUT\n"
                       "  --catalogue-index FILE --source-root SNAPSHOT_ASSETS\n"
                       "  --socket PATH --base-config PATH --wait-lock --compare-local\n"
                       "  --effect KIND/NAME --slot effects.KIND|animation.EVENT\n"
                       "  --family ID --choices JSON --effects JSON --plan-token TOKEN\n"
                       "Actions: status, catalogue, refresh, previews, diagnostics, prepare, choose,\n"
                       "         prepare-family, choose-family, remove, apply, undo, restore, recover\n";
                return 0;
            }
            if (value.starts_with("--")) {
                const std::set<std::string> allowed{
                    "--state-dir",       "--socket",  "--base-config", "--source-mode", "--source-root",
                    "--catalogue-index", "--offset",  "--effect",      "--slot",        "--family",
                    "--choices",         "--effects", "--plan-token"};
                require(allowed.contains(value), "Unknown option: " + value);
                require(i + 1 < argc && !options.contains(value), "Missing or duplicate option: " + value);
                options[value] = argv[++i];
            } else {
                require(action.empty(), "Only one action is accepted");
                action = value;
            }
        }
        require(options.contains("--state-dir") && !options.at("--state-dir").empty(),
                "--state-dir is required");
        root = fs::absolute(options.at("--state-dir"));
        const std::set<std::string> actions{
            "status",         "catalogue",     "refresh", "previews", "diagnostics", "prepare", "choose",
            "prepare-family", "choose-family", "remove",  "apply",    "undo",        "restore", "recover"};
        require(actions.contains(action), "Unsupported native action");
        if (options.contains("--slot"))
            require(valid_slot(options.at("--slot")), "Unsupported effect slot");
        auto open_catalogue = [&]() {
            const auto mode = options.contains("--source-mode")       ? options.at("--source-mode")
                              : options.contains("--catalogue-index") ? "snapshot"
                                                                      : "online";
            const auto cache = contained(root, "catalogue-cache");
            if (mode == "online")
                return Catalogue::online(cache / "online", action == "refresh");
            if (mode == "local")
                return Catalogue::local(options["--source-root"], cache / "local", action == "refresh");
            require(mode == "snapshot", "Invalid catalogue source mode");
            require(options.contains("--catalogue-index") && !options.at("--catalogue-index").empty(),
                    "Choose a saved catalogue JSON file");
            return Catalogue(fs::path(options.at("--catalogue-index")), options["--source-root"]);
        };
        auto connect = [&]() {
            peer = std::make_unique<SocketPeer>(
                options.contains("--socket") ? fs::path(options.at("--socket")) : socket_path());
        };
        Json result;
        if (action == "catalogue" || action == "refresh" || action == "previews") {
            const auto catalogue = open_catalogue();
            if (action == "previews")
                result = {
                    {"previews", catalogue.previews(
                                     parse_json(options.at("--effects")).get<std::vector<std::string>>())}};
            else {
                size_t offset = 0;
                if (options.contains("--offset")) {
                    const auto value = options.at("--offset");
                    require(!value.empty() && value.size() <= 4 &&
                                value.find_first_not_of("0123456789") == std::string::npos,
                            "Invalid catalogue offset");
                    offset = std::stoul(value);
                }
                result = {{"catalogue", catalogue.browse(offset)}, {"message", "Catalogue ready."}};
                try {
                    connect();
                    Controller controller(root, *peer, options["--base-config"]);
                    result.update(controller.status());
                } catch (const std::exception &error) {
                    result["live_error"] = error.what();
                }
            }
            if (action == "refresh") {
                try {
                    catalogue.collect_cache();
                } catch (const std::exception &) {
                }
            }
        } else if (action == "diagnostics") {
            std::string error;
            try {
                connect();
            } catch (const std::exception &value) {
                error = value.what();
            }
            result = {{"diagnostics", diagnostics(root, peer.get(), error)}};
        } else {
            Lock lock(root, wait_lock);
            connect();
            Controller controller(root, *peer, options["--base-config"]);
            logging = action != "status";
            operation = {{"action", action}, {"started", now()}};
            record("running", "Operation started");
            if (action == "status")
                result = controller.status();
            else if (action == "prepare" || action == "choose" || action == "prepare-family" ||
                     action == "choose-family" || action == "remove") {
                const auto executable = fs::canonical("/proc/self/exe"),
                           recovery = contained(root, "recovery");
                const auto binary = read(executable, 64 * document_limit);
                if (!fs::exists(recovery) || sha256(read(recovery, 64 * document_limit)) != sha256(binary))
                    atomic_write(recovery, binary, 0700);
                if (action == "remove") {
                    // Removing a withdrawn selection must work even when the catalogue is gone.
                    Json empty = {
                        {"schema_version", 1},
                        {"draft", false},
                        {"source",
                         {{"repository", "https://github.com/noctalia-dev/community-umbriel-shaders"},
                          {"revision", std::string(40, '0')}}},
                        {"effects", Json::array()},
                        {"families", Json::array()},
                        {"files", Json::object()},
                        {"feature_definitions", {{"preset-effects", "Named presets"}}}};
                    result = controller.prepare(Catalogue(empty), "", options.at("--slot"));
                } else {
                    const auto catalogue = open_catalogue();
                    if (action.ends_with("-family")) {
                        const auto family = options.at("--family");
                        result = controller.prepare(
                            catalogue, catalogue.family_choices(family, parse_json(options.at("--choices"))),
                            family);
                    } else
                        result = controller.prepare(catalogue, options.at("--effect"),
                                                    options.contains("--slot") ? options.at("--slot")
                                                                               : "effects.cursor",
                                                    compare_local);
                }
                if (action == "choose" || action == "choose-family" || action == "remove")
                    result = controller.apply(result.at("plan_token"));
            } else if (action == "apply")
                result = controller.apply(options.at("--plan-token"));
            else if (action == "undo")
                result = controller.undo();
            else if (action == "restore")
                result = controller.restore();
            else if (action == "recover")
                result = controller.recover();
            record("passed", result.value("message", "Operation completed"));
        }
        result["ok"] = true;
        result["protocol_version"] = 1;
        require(result.dump().size() < document_limit - 4096, "Response exceeds Noctalia transport budget");
        std::cout << result.dump() << '\n';
        return 0;
    } catch (const std::exception &error) {
        record("failed", error.what());
        Json result;
        if (peer && !root.empty()) {
            try {
                Controller controller(root, *peer);
                result = controller.status();
            } catch (const std::exception &) {
            }
        }
        result.update({{"ok", false},
                       {"protocol_version", 1},
                       {"message", error.what()},
                       {"pending", !root.empty() && fs::exists(root / "pending.json")}});
        std::cout << result.dump() << '\n';
        return 1;
    }
}
