// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <array>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sstream>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

namespace shaders {
namespace {
class Fd {
  public:
    int value;
    explicit Fd(int fd) : value(fd) {
        require(fd >= 0, "Cannot allocate file descriptor");
    }
    ~Fd() {
        close(value);
    }
    Fd(const Fd &) = delete;
};
using Clock = std::chrono::steady_clock;
void wait_fd(int fd, short events, Clock::time_point deadline) {
    while (true) {
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - Clock::now()).count();
        require(left > 0, "Umbriel IPC timed out");
        pollfd item{fd, events, 0};
        const int result = poll(&item, 1, int(left));
        if (result < 0 && errno == EINTR)
            continue;
        require(result > 0 && !(item.revents & POLLNVAL), "Umbriel IPC timed out or failed");
        return;
    }
}
std::vector<std::string> split_null(const std::string &value) {
    std::vector<std::string> result;
    size_t start = 0;
    while (start < value.size()) {
        const auto end = value.find('\0', start);
        result.push_back(value.substr(start, end == std::string::npos ? end : end - start));
        if (end == std::string::npos)
            break;
        start = end + 1;
    }
    return result;
}
Session identity(int pid, const std::string &path) {
    const auto raw = read(fs::path("/proc") / std::to_string(pid) / "stat");
    const auto end = raw.rfind(')');
    require(end != std::string::npos, "Cannot identify compositor process");
    std::istringstream fields(raw.substr(end + 2));
    std::string field;
    for (int i = 0; i <= 19; ++i)
        require(bool(fields >> field), "Invalid process identity");
    return {pid, field, read("/proc/sys/kernel/random/boot_id"), path};
}
} // namespace
Json SocketPeer::request(Json payload) {
    const auto path = session_.socket;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    require(path.size() < sizeof(address.sun_path), "Umbriel socket path is too long");
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    Fd connection(::socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0));
    const auto deadline = Clock::now() + std::chrono::seconds(5);
    int connected = connect(connection.value, reinterpret_cast<sockaddr *>(&address), sizeof(address));
    if (connected != 0) {
        require(errno == EINPROGRESS || errno == EAGAIN, "Cannot connect to Umbriel socket");
        wait_fd(connection.value, POLLOUT, deadline);
        int error = 0;
        socklen_t size = sizeof(error);
        require(getsockopt(connection.value, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0,
                "Umbriel connection failed");
    }
    ucred credentials{};
    socklen_t size = sizeof(credentials);
    require(getsockopt(connection.value, SOL_SOCKET, SO_PEERCRED, &credentials, &size) == 0 &&
                credentials.uid == getuid(),
            "Socket must belong to this user");
    auto current = identity(credentials.pid, path);
    require(session_.pid == 0 || session_ == current, "Umbriel restarted or the session changed");
    session_ = current;
    const auto bytes = payload.dump() + '\n';
    size_t offset = 0;
    while (offset < bytes.size()) {
        wait_fd(connection.value, POLLOUT, deadline);
        auto n = send(connection.value, bytes.data() + offset, bytes.size() - offset, MSG_NOSIGNAL);
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
            continue;
        require(n > 0, "Cannot send Umbriel command");
        offset += size_t(n);
    }
    std::string response;
    std::array<char, 8192> buffer{};
    while (response.find('\n') == std::string::npos) {
        wait_fd(connection.value, POLLIN, deadline);
        auto n = recv(connection.value, buffer.data(), buffer.size(), 0);
        if (n < 0 && (errno == EAGAIN || errno == EINTR))
            continue;
        require(n > 0, "Umbriel disconnected before acknowledgement");
        response.append(buffer.data(), size_t(n));
        require(response.size() <= 2 * document_limit, "Umbriel response exceeds size limit");
    }
    auto result = parse_json(response.substr(0, response.find('\n')));
    require(result.is_object() && result.contains("ok"),
            "Umbriel rejected command: " + result.value("err", Json("invalid reply")).dump());
    return result.at("ok");
}
SocketPeer::SocketPeer(fs::path socket) {
    require(socket.is_absolute(), "An absolute Umbriel socket path is required");
    session_.socket = socket.string();
    effects();
    auto proc = fs::path("/proc") / std::to_string(session_.pid);
    executable_ = fs::canonical(proc / "exe");
    require(executable_.filename() == "umbriel" || executable_.filename() == ".umbriel-wrapped",
            "Socket peer is not Umbriel");
    cwd_ = fs::canonical(proc / "cwd");
    for (const auto &entry : split_null(read(proc / "environ"))) {
        auto split = entry.find('=');
        if (split != std::string::npos)
            environment_[entry.substr(0, split)] = entry.substr(split + 1);
    }
    auto arguments = split_null(read(proc / "cmdline"));
    for (size_t i = 1; i + 1 < arguments.size(); ++i)
        if (arguments[i] == "-c")
            base_ = fs::absolute(cwd_ / arguments[i + 1]);
    if (base_.empty()) {
        auto home = environment_.contains("HOME") ? environment_.at("HOME") : cwd_.string();
        auto config =
            environment_.contains("XDG_CONFIG_HOME") ? environment_.at("XDG_CONFIG_HOME") : home + "/.config";
        if (fs::exists(fs::path(config) / "umbriel/config.toml"))
            base_ = fs::path(config) / "umbriel/config.toml";
    }
}
Json SocketPeer::effects() {
    return request({{"cmd", "effects"}});
}
void SocketPeer::replace(const fs::path &path) {
    request({{"cmd", "config-replace"}, {"args", Json::array({path.string()})}});
}
void SocketPeer::action(const RuntimeSlot &slot, const std::string &operation, const std::string &selector) {
    require(operation == "set" || operation == "reset" || operation == "toggle" || operation == "cycle",
            "Invalid effect operation");
    require(slot.kind == "cursor" || slot.kind == "border" || slot.kind == "window" || slot.kind == "screen",
            "Invalid effect kind");
    require((slot.kind == "cursor") == slot.target.empty(), "Explicit effect target is required");
    Json message = {{"cmd", "action"}, {"action", "effect-" + slot.kind + "-" + operation}};
    if (slot.kind == "window" || slot.kind == "border")
        message["window"] = slot.target;
    if (slot.kind == "screen")
        message["output"] = slot.target;
    if (!selector.empty())
        message[operation == "cycle" ? "pool" : "effect"] = selector;
    request(message);
}
void SocketPeer::validate(const fs::path &path) {
    int pipefd[2];
    require(pipe2(pipefd, O_CLOEXEC | O_NONBLOCK) == 0, "Cannot create validator pipe");
    Fd input(pipefd[0]), output(pipefd[1]);
    const auto process = fork();
    require(process >= 0, "Cannot start validator");
    if (process == 0) {
        fcntl(output.value, F_SETFL, 0);
        dup2(output.value, STDOUT_FILENO);
        dup2(output.value, STDERR_FILENO);
        if (chdir(cwd_.c_str()) != 0)
            _exit(126);
        clearenv();
        for (const auto &[key, value] : environment_)
            setenv(key.c_str(), value.c_str(), 1);
        execl(executable_.c_str(), executable_.c_str(), "config", "validate", "-c", path.c_str(),
              static_cast<char *>(nullptr));
        _exit(127);
    }
    const auto deadline = Clock::now() + std::chrono::seconds(20);
    std::string message;
    int status = 0;
    try {
        while (true) {
            std::array<char, 4096> buffer{};
            auto count = ::read(input.value, buffer.data(), buffer.size());
            if (count > 0)
                message.append(buffer.data(), size_t(count));
            require(message.size() <= 256 * 1024, "Validator output exceeds limit");
            auto finished = waitpid(process, &status, WNOHANG);
            require(finished >= 0 || errno == EINTR, "Cannot wait for validator");
            if (finished == process)
                break;
            require(Clock::now() < deadline, "Configuration validation timed out");
            pollfd item{input.value, POLLIN, 0};
            poll(&item, 1, 10);
        }
    } catch (...) {
        kill(process, SIGKILL);
        while (waitpid(process, &status, 0) < 0 && errno == EINTR) {
        }
        throw;
    }
    require(WIFEXITED(status) && WEXITSTATUS(status) == 0, "Configuration validation failed: " + message);
}
} // namespace shaders
