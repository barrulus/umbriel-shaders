// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <array>
#include <cerrno>
#include <chrono>
#include <fcntl.h>
#include <fstream>
#include <openssl/evp.h>
#include <sys/file.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>

namespace shaders {
void require(bool condition, const std::string &message) {
    if (!condition)
        throw Error(message);
}
std::string read(const fs::path &path, size_t limit) {
    std::ifstream stream(path, std::ios::binary);
    require(bool(stream) && fs::is_regular_file(path), "Cannot read regular file: " + path.string());
    require(fs::file_size(path) <= limit, "File exceeds size limit: " + path.string());
    std::string value;
    std::array<char, 8192> buffer{};
    while (stream.read(buffer.data(), buffer.size()) || stream.gcount()) {
        value.append(buffer.data(), size_t(stream.gcount()));
        require(value.size() <= limit, "File grew beyond size limit: " + path.string());
    }
    require(stream.eof(), "Failed reading: " + path.string());
    return value;
}
std::string sha256(std::string_view value) {
    std::array<unsigned char, EVP_MAX_MD_SIZE> hash{};
    unsigned length = 0;
    require(EVP_Digest(value.data(), value.size(), hash.data(), &length, EVP_sha256(), nullptr) == 1,
            "SHA-256 failed");
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    for (unsigned i = 0; i < length; ++i) {
        result += hex[hash[i] >> 4];
        result += hex[hash[i] & 15];
    }
    return result;
}
std::string token() {
    std::array<unsigned char, 16> value{};
    size_t offset = 0;
    while (offset < value.size()) {
        const auto n = getrandom(value.data() + offset, value.size() - offset, 0);
        if (n < 0 && errno == EINTR)
            continue;
        require(n > 0, "Cannot obtain random generation ID");
        offset += size_t(n);
    }
    constexpr char hex[] = "0123456789abcdef";
    std::string result;
    for (auto byte : value) {
        result += hex[byte >> 4];
        result += hex[byte & 15];
    }
    return result;
}
namespace {
void sync_directory(const fs::path &path) {
    const int fd = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    require(fd >= 0, "Cannot open directory for sync");
    const int result = fsync(fd);
    close(fd);
    require(result == 0, "Cannot sync directory: " + path.string());
}
} // namespace
void atomic_write(const fs::path &path, std::string_view value, unsigned mode) {
    fs::create_directories(path.parent_path());
    const fs::path temporary = path.parent_path() / (".next-" + token());
    const int fd = open(temporary.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(mode));
    require(fd >= 0, "Cannot create temporary file: " + path.string());
    bool closed = false;
    try {
        size_t offset = 0;
        while (offset < value.size()) {
            const auto n = write(fd, value.data() + offset, value.size() - offset);
            if (n < 0 && errno == EINTR)
                continue;
            require(n > 0, "Cannot write: " + path.string());
            offset += size_t(n);
        }
        require(fsync(fd) == 0, "Cannot sync: " + path.string());
        close(fd);
        closed = true;
        fs::rename(temporary, path);
        sync_directory(path.parent_path());
    } catch (...) {
        if (!closed)
            close(fd);
        std::error_code ignored;
        fs::remove(temporary, ignored);
        throw;
    }
}
void durable_remove(const fs::path &path) {
    if (fs::remove(path))
        sync_directory(path.parent_path());
}
Json parse_json(std::string_view bytes) {
    require(bytes.size() <= 4 * document_limit, "JSON input exceeds size limit");
    return Json::parse(bytes, [](int depth, Json::parse_event_t, Json &) {
        require(depth <= 64, "JSON nesting exceeds limit");
        return true;
    });
}
Json load(const fs::path &path) {
    return parse_json(read(path));
}
void save(const fs::path &path, const Json &value) {
    auto bytes = value.dump();
    require(bytes.size() <= document_limit, "Persistent document exceeds size limit before writing");
    atomic_write(path, bytes);
}
void verify(const Files &files) {
    for (const auto &[path, hash] : files) {
        if (hash == "missing")
            require(!fs::exists(path), "Optional file appeared: " + path);
        else
            require(fingerprint(path) == hash, "File changed: " + path);
    }
}
fs::path relative_path(const std::string &relative) {
    require(!relative.empty() && fs::path(relative).is_relative(), "Invalid relative path");
    for (const auto &part : fs::path(relative)) {
        require(part != "." && part != ".." && !part.empty(), "Unsafe path component");
        for (auto c : part.string()) {
            require(static_cast<unsigned char>(c) >= 32 && c != '\\' && c != '$' && c != '~' && c != ':',
                    "Unsafe path character");
        }
    }
    return fs::path(relative);
}
fs::path contained(const fs::path &root, const std::string &relative) {
    const auto validated = relative_path(relative);
    fs::path result = fs::absolute(root);
    require(!fs::is_symlink(result), "Root cannot be a symlink");
    for (const auto &part : validated) {
        result /= part;
        require(!fs::is_symlink(result), "Symlinks are not permitted: " + result.string());
    }
    return result;
}
bool hex_string(std::string_view value, size_t length) {
    return value.size() == length && std::all_of(value.begin(), value.end(), [](char c) {
               return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
           });
}
bool valid_token(const std::string &value) {
    return hex_string(value, 32);
}
std::string fingerprint(const fs::path &path) {
    return sha256(fs::canonical(path).string() + '\n' + read(path));
}
std::string quoted(const std::string &value) {
    return Json(value).dump();
}
long now() {
    return std::chrono::system_clock::to_time_t(std::chrono::system_clock::now());
}
Lock::Lock(const fs::path &root, bool wait) {
    require(!fs::is_symlink(root), "State directory cannot be a symlink");
    fs::create_directories(root);
    struct stat info{};
    require(stat(root.c_str(), &info) == 0 && info.st_uid == getuid(),
            "State directory must belong to this user");
    require(chmod(root.c_str(), 0700) == 0, "Cannot protect state directory");
    fd_ = open((root / "operation.lock").c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    require(fd_ >= 0, "Cannot open operation lock");
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(wait ? 65 : 0);
    while (flock(fd_, LOCK_EX | LOCK_NB) != 0) {
        if (errno != EWOULDBLOCK || std::chrono::steady_clock::now() >= deadline) {
            close(fd_);
            fd_ = -1;
            throw Error("Another operation is running; try again");
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
}
Lock::~Lock() {
    if (fd_ >= 0)
        close(fd_);
}
Selection cursor(const Json &report) {
    const auto &item = report.at("cursor");
    return {item.value("name", ""), item.value("pool", ""), item.value("source", "default"),
            item.value("suppressed", false)};
}
std::vector<std::string> markers(const Json &report) {
    std::vector<std::string> result;
    for (const auto &preset : report.at("presets")) {
        auto name = preset.at("name").get<std::string>();
        if (name.starts_with(marker_prefix) || name.starts_with("umbriel-shaders-generation-"))
            result.push_back(name);
    }
    std::sort(result.begin(), result.end());
    return result;
}
Json selection_stamp(const Json &report) {
    std::vector<std::pair<std::string, std::string>> presets;
    for (const auto &item : report.at("presets"))
        presets.emplace_back(item.at("name"), item.at("kind"));
    std::sort(presets.begin(), presets.end());
    auto runtime = runtime_slots(report);
    std::erase_if(runtime, [](const auto &entry) {
        return entry.second.kind != "cursor" && entry.second.value.source != "runtime" &&
               !entry.second.value.suppressed;
    });
    return {{"runtime", runtime}, {"presets", presets}};
}
void to_json(Json &json, const Generation &value) {
    json = {{"token", value.token},       {"config", value.config},     {"files", value.files},
            {"bindings", value.bindings}, {"settings", value.settings}, {"presets", value.presets}};
}
void from_json(const Json &json, Generation &value) {
    value.token = json.at("token");
    value.config = json.at("config");
    value.files = json.at("files").get<Files>();
    if (json.contains("bindings")) {
        value.bindings = json.at("bindings").get<Bindings>();
        value.settings = json.at("settings");
        value.presets = json.at("presets").get<std::vector<std::string>>();
    } else {
        // Read cursor-prototype generations without rewriting their config files.
        Binding binding;
        binding.id = json.at("effect");
        binding.name = json.at("preset");
        binding.kind = "cursor";
        binding.settings = {{"effects.cursor", binding.name}};
        binding.features = {"preset-effects"};
        value.bindings = {{"effects.cursor", binding}};
        value.settings = binding.settings;
        value.presets = {binding.name};
    }
    require(value.bindings.size() <= 13 && value.presets.size() <= 512, "Oversized saved selection");
    for (const auto &[slot, binding] : value.bindings) {
        require(valid_slot(slot), "Invalid saved selection slot");
        relative_path(binding.id);
        for (const auto &[key, item] : binding.settings.items())
            validate_setting(key, item);
        for (const auto &[key, item] : binding.required.items())
            validate_setting(key, item);
    }
}
Json encode(const State &state) {
    return {{"schema_version", 3},
            {"base", state.base},
            {"session", state.session},
            {"can_undo", state.can_undo},
            {"current", state.current ? Json(*state.current) : Json(nullptr)},
            {"previous", state.previous ? Json(*state.previous) : Json(nullptr)},
            {"original", state.original},
            {"owned", state.owned},
            {"undo_runtime", state.undo_runtime},
            {"previous_original", state.previous_original},
            {"previous_owned", state.previous_owned}};
}
State decode_state(const Json &json) {
    const auto version = json.at("schema_version").get<int>();
    require(version == 2 || version == 3, "Unsupported native state format");
    State state;
    state.base = json.at("base");
    state.session = json.at("session").get<Session>();
    state.can_undo = json.at("can_undo");
    if (!json.at("current").is_null())
        state.current = json.at("current").get<Generation>();
    if (!json.at("previous").is_null())
        state.previous = json.at("previous").get<Generation>();
    auto runtime = [&](const char *key, const char *legacy = nullptr) {
        if (version == 3)
            return json.at(key).get<Runtime>();
        Runtime result;
        const auto &value = json.at(legacy ? legacy : key);
        if (!value.is_null())
            result[Json::array({"cursor", ""}).dump()] = {"cursor", "", value.get<Selection>()};
        return result;
    };
    state.original = runtime("original");
    state.owned = runtime("owned");
    state.undo_runtime = runtime("undo_runtime", "undo_cursor");
    state.previous_original = runtime("previous_original");
    state.previous_owned = runtime("previous_owned");
    require(fs::path(state.base).is_absolute(), "Saved base path must be absolute");
    return state;
}
} // namespace shaders
