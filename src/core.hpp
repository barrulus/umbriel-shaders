// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <chrono>
#include <filesystem>
#include <functional>
#include <map>
#include <nlohmann/json.hpp>
#include <optional>
#include <set>
#include <stdexcept>
#include <string>
#include <toml++/toml.hpp>
#include <vector>

namespace shaders {
namespace fs = std::filesystem;
using Json = nlohmann::json;
using Files = std::map<std::string, std::string>;
constexpr size_t document_limit = 1024 * 1024;
constexpr auto marker_prefix = "umbriel-native-generation-";
struct Error : std::runtime_error {
    using std::runtime_error::runtime_error;
};
void require(bool condition, const std::string &message);
std::string read(const fs::path &, size_t limit = document_limit);
std::string sha256(std::string_view);
std::string fingerprint(const fs::path &);
bool hex_string(std::string_view, size_t length);
fs::path relative_path(const std::string &);
std::string token();
void atomic_write(const fs::path &, std::string_view, unsigned mode = 0600);
void durable_remove(const fs::path &);
Json parse_json(std::string_view);
Json load(const fs::path &);
void save(const fs::path &, const Json &);
void verify(const Files &);
fs::path contained(const fs::path &root, const std::string &relative);
bool valid_token(const std::string &);
std::string quoted(const std::string &);
long now();
class Lock {
    int fd_ = -1;

  public:
    explicit Lock(const fs::path &root, bool wait = false);
    ~Lock();
    Lock(const Lock &) = delete;
    Lock &operator=(const Lock &) = delete;
};

struct Session {
    int pid = 0;
    std::string start, boot, socket;
    bool operator==(const Session &) const = default;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Session, pid, start, boot, socket)
struct Selection {
    std::string name, pool, source = "default";
    bool suppressed = false;
    bool operator==(const Selection &) const = default;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Selection, name, pool, source, suppressed)
Selection cursor(const Json &report);
std::vector<std::string> markers(const Json &report);
Json selection_stamp(const Json &report);
struct RuntimeSlot {
    std::string kind, target;
    Selection value;
    bool operator==(const RuntimeSlot &) const = default;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(RuntimeSlot, kind, target, value)
using Runtime = std::map<std::string, RuntimeSlot>;
Runtime runtime_slots(const Json &);
void prune(Runtime &, const Runtime &live);
void restore_runtime(class Peer &, const Runtime &);

// A selection keeps its activation recipe independently of the discovery catalogue.
// An unrelated Apply must not rewrite or invalidate an already installed selection.
struct Binding {
    std::string id, name, kind;
    Json settings = Json::object(), required = Json::object();
    std::vector<std::string> features;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Binding, id, name, kind, settings, required, features)
using Bindings = std::map<std::string, Binding>;

struct Generation {
    std::string token, config;
    Files files;
    Bindings bindings;
    Json settings = Json::object();
    std::vector<std::string> presets;
};
void to_json(Json &, const Generation &);
void from_json(const Json &, Generation &);
struct State {
    std::string base;
    Session session;
    std::optional<Generation> current, previous;
    bool can_undo = false;
    Runtime original, owned, undo_runtime, previous_original, previous_owned;
};
Json encode(const State &);
State decode_state(const Json &);

class Peer {
  public:
    virtual ~Peer() = default;
    virtual Session session() const = 0;
    virtual Json effects() = 0;
    virtual void replace(const fs::path &) = 0;
    virtual void action(const RuntimeSlot &, const std::string &operation,
                        const std::string &selector = "") = 0;
    virtual void validate(const fs::path &) = 0;
    virtual fs::path base() const = 0;
    virtual std::map<std::string, std::string> environment() const = 0;
};
class SocketPeer final : public Peer {
    Session session_;
    fs::path executable_, cwd_, base_;
    std::map<std::string, std::string> environment_;
    Json request(Json);

  public:
    explicit SocketPeer(fs::path socket);
    Session session() const override {
        return session_;
    }
    Json effects() override;
    void replace(const fs::path &) override;
    void action(const RuntimeSlot &, const std::string &, const std::string & = "") override;
    void validate(const fs::path &) override;
    fs::path base() const override {
        return base_;
    }
    std::map<std::string, std::string> environment() const override {
        return environment_;
    }
};
struct Graph {
    bool drm = false;
    Files files;
    std::map<std::string, Json> presets;
    Json settings = Json::object();
};
Graph config_graph(const fs::path &, const std::map<std::string, std::string> &);
struct Resolved {
    std::map<std::string, Json> definitions;
    Files files;
    std::set<std::string> presets;
    Json local_copies = Json::array();
};
using Fetch = std::function<std::string(const std::string &, size_t)>;
std::string download(const std::string &, size_t);
Json local_registry(const fs::path &root, const fs::path &cache, bool refresh = false);
void validate_registry(const Json &, bool local = false);
std::string setting_scope(const std::string &);
bool valid_slot(const std::string &);
void validate_setting(const std::string &, const Json &);
void validate_definition(const Json &, const std::string &kind);
std::string value_toml(const Json &);
Json json_table(const toml::table &);
class Catalogue {
    Json registry_;
    fs::path assets_;
    fs::path cache_;
    Fetch fetch_;
    std::string mode_ = "snapshot";
    bool offline_ = false;
    std::chrono::steady_clock::time_point deadline_ =
        std::chrono::steady_clock::now() + std::chrono::seconds(35);
    std::string bytes(const std::string &) const;
    fs::path object_path(const std::string &) const;
    std::string url(const std::string &) const;

  public:
    Catalogue(const fs::path &index, fs::path assets = {});
    explicit Catalogue(Json registry, fs::path assets = {}, bool local = false);
    static Catalogue online(const fs::path &cache, bool refresh = false, Fetch fetch = download);
    static Catalogue local(const fs::path &root, const fs::path &cache, bool refresh = false);
    Json previews(const std::vector<std::string> &) const;
    void collect_cache() const;
    Json browse(size_t offset = 0) const;
    Binding binding(const std::string &id, const std::string &slot, const std::string &family = "") const;
    std::map<std::string, std::string> family_choices(const std::string &, const Json &) const;
    Resolved resolve(const Bindings &, const Graph &, const fs::path &library,
                     bool compare_local = false) const;
    const Json &registry() const {
        return registry_;
    }
};
class Controller {
    fs::path root_, base_;
    bool explicit_base_ = false;
    Peer &peer_;
    State state() const;
    void check_generation(const Generation &) const;
    bool owned(const State &, const Json &) const;
    fs::path target(const State &) const;
    void confirm(const State &);
    void rollback(const Json &);
    void transact(State before, State after, const Runtime &desired, const Files &base_files,
                  const Json &expected);
    void cleanup(const State &);

  public:
    Controller(fs::path root, Peer &peer, fs::path base = {});
    Json status();
    Json prepare(const Catalogue &, const std::string &effect, const std::string &slot = "effects.cursor",
                 bool compare_local = false);
    Json prepare(const Catalogue &, const std::map<std::string, std::string> &requested,
                 const std::string &family = "", bool compare_local = false);
    Json apply(const std::string &plan);
    Json undo();
    Json restore();
    Json recover();
};
Json diagnostics(const fs::path &, Peer *, const std::string &live_error = "");
} // namespace shaders
