// SPDX-License-Identifier: MIT
// Optional complete-catalogue review against Umbriel's real config validator.
// Uses a synthetic peer: no sockets, config switching or GPU claims.
#include "fake_peer.hpp"
#include <fcntl.h>
#include <iostream>
#include <sys/wait.h>

int main(int argc, char **argv) {
    const auto root = fs::temp_directory_path() / ("native-catalogue-review-" + token());
    std::string current;
    try {
        require(argc == 4, "Usage: native-catalogue-review INDEX ASSETS UMBRIEL");
        fs::create_directories(root);
        Catalogue catalogue{fs::path(argv[1]), fs::path(argv[2])};
        atomic_write(root / "base.toml", "[general]\nautostart=[]\n");
        FakePeer peer(root);
        Controller controller(root / "state", peer);
        Lock lock(root / "state");
        size_t count = 0;
        auto validate = [&](const std::map<std::string, std::string> &requested, const std::string &family) {
            Json requirements = Json::object();
            for (const auto &[slot, id] : requested)
                requirements.update(catalogue.binding(id, slot, family).required);
            std::string base;
            for (const auto &[key, value] : requirements.items())
                base += key + "=" + value_toml(value) + "\n";
            atomic_write(root / "base.toml", base + "[general]\nautostart=[]\n");
            controller.prepare(catalogue, requested, family);
            const auto config =
                load(root / "state/plan.json").at("generation").at("config").get<std::string>();
            const pid_t child = fork();
            require(child >= 0, "Could not start validator");
            if (child == 0) {
                const int output =
                    open((root / "validation.log").c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
                dup2(output, STDOUT_FILENO);
                dup2(output, STDERR_FILENO);
                close(output);
                execl(argv[3], argv[3], "config", "validate", "-c", config.c_str(), nullptr);
                _exit(127);
            }
            int status = 0;
            const bool valid =
                waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0;
            if (!valid)
                throw Error("Umbriel validation failed: " + read(root / "validation.log"));
            ++count;
        };
        for (const auto &effect : catalogue.registry().at("effects")) {
            if (effect.at("role") != "effect" || effect.at("activation").is_null())
                continue;
            current = effect.at("id");
            for (const auto &slot : effect.at("uses"))
                validate({{slot, current}}, "");
        }
        for (const auto &family : catalogue.registry().at("families")) {
            if (family.at("activation").is_null())
                continue;
            current = family.at("id");
            std::map<std::string, std::string> requested;
            for (const auto &effect : catalogue.registry().at("effects")) {
                if (effect.at("role") != "effect" ||
                    std::find(family.at("members").begin(), family.at("members").end(), effect.at("id")) ==
                        family.at("members").end())
                    continue;
                for (const auto &use : effect.at("uses")) {
                    const auto slot = use.get<std::string>();
                    if (family.at("activation")
                            .at("settings")
                            .value(slot + (slot.starts_with("animation.") ? ".effect" : ""), "") ==
                        effect.at("preset").get<std::string>())
                        requested[slot] = effect.at("id");
                }
            }
            validate(requested, current);
        }
        std::cout << "PASS " << count
                  << " complete-catalogue effect/use and default-family reviews with real Umbriel config "
                     "validation; no compositor or GPU used\n";
        fs::remove_all(root);
        return 0;
    } catch (const std::exception &error) {
        std::cerr << current << ": " << error.what() << '\n';
        fs::remove_all(root);
        return 1;
    }
}
