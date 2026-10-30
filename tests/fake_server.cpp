// SPDX-License-Identifier: MIT
// Deliberately named umbriel by CMake, to exercise real SO_PEERCRED/executable checks.
// No renderer and no desktop access. The caller supplies a private socket and config.
#include "fake_peer.hpp"
#include <chrono>
#include <cstring>
#include <iostream>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>
int main(int argc, char **argv) {
    try {
        if (argc == 5 && std::string(argv[1]) == "config" && std::string(argv[2]) == "validate" &&
            std::string(argv[3]) == "-c") {
            parse_toml(argv[4]);
            return 0;
        }
        require(argc == 5 && std::string(argv[1]) == "-c" && std::string(argv[3]) == "--socket",
                "Invalid test server arguments");
        fs::path base = argv[2], socket = argv[4];
        FakePeer peer(base.parent_path());
        peer.config = base;
        for (const auto *kind : {"border", "window", "screen"}) {
            const std::string target = std::string(kind) == "screen" ? "HEADLESS-1" : "window-1";
            peer.targets[Json::array({kind, target}).dump()] = {kind, target, {}};
        }
        int listener = ::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        require(listener >= 0, "socket failed");
        sockaddr_un address{};
        address.sun_family = AF_UNIX;
        require(socket.string().size() < sizeof(address.sun_path), "socket path too long");
        std::strcpy(address.sun_path, socket.c_str());
        fs::remove(socket);
        if (bind(listener, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
            const int error = errno;
            std::cerr << "Cannot bind private test socket: " << std::strerror(error) << '\n';
            if (error == EPERM || error == EACCES)
                return 77;
            throw Error("bind failed");
        }
        require(listen(listener, 8) == 0, "listen failed");
        while (true) {
            int client = accept4(listener, nullptr, nullptr, SOCK_CLOEXEC);
            if (client < 0)
                continue;
            std::string input;
            char buffer[4096];
            Json reply;
            try {
                while (input.find('\n') == std::string::npos) {
                    auto count = recv(client, buffer, sizeof(buffer), 0);
                    require(count > 0, "disconnected");
                    input.append(buffer, size_t(count));
                    require(input.size() < document_limit, "request too large");
                }
                auto request = Json::parse(input.substr(0, input.find('\n')));
                auto command = request.at("cmd").get<std::string>();
                Json result = nullptr;
                if (command == "effects")
                    result = peer.effects();
                else if (command == "config-replace") {
                    peer.replace(request.at("args")[0].get<std::string>());
                    if (fs::exists(peer.root / "hold-switch")) {
                        atomic_write(peer.root / "switched", "yes");
                        while (fs::exists(peer.root / "hold-switch"))
                            std::this_thread::sleep_for(std::chrono::milliseconds(10));
                    }
                } else if (command == "action") {
                    const auto action = request.at("action").get<std::string>();
                    require(action.starts_with("effect-"), "Unexpected action");
                    const auto split = action.rfind('-');
                    const auto kind = action.substr(7, split - 7);
                    require(kind == "cursor" || kind == "border" || kind == "window" || kind == "screen",
                            "Invalid action kind");
                    const auto target =
                        kind == "cursor"
                            ? std::string{}
                            : request.at(kind == "screen" ? "output" : "window").get<std::string>();
                    peer.action(RuntimeSlot{kind, target, {}}, action.substr(split + 1),
                                request.value("effect", request.value("pool", "")));
                } else
                    throw Error("Unknown command");
                reply = {{"ok", result}};
            } catch (const std::exception &error) {
                reply = {{"err", error.what()}};
            }
            const auto output = reply.dump() + "\n";
            // Fragment replies intentionally to exercise stream framing.
            for (size_t offset = 0; offset < output.size();) {
                auto count = send(client, output.data() + offset,
                                  std::min<size_t>(17, output.size() - offset), MSG_NOSIGNAL);
                if (count <= 0)
                    break;
                offset += size_t(count);
            }
            close(client);
        }
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
