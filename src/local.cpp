// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <regex>
#include <sys/stat.h>

namespace shaders {
namespace {
constexpr auto repository = "https://github.com/noctalia-dev/community-umbriel-shaders";
std::string reference(const std::string &parent, const std::string &value) {
    require(!fs::path(value).is_absolute(), "Preset reference must be relative");
    const auto path = (fs::path(parent) / value).lexically_normal().generic_string();
    relative_path(path);
    return path;
}
Json flatten(const Json &value, const std::string &prefix) {
    require(value.is_object(), "Expected configuration table");
    Json result = Json::object();
    for (const auto &[key, item] : value.items()) {
        require(key.find('.') == std::string::npos, "Quoted dotted activation key is not a nested table");
        if (item.is_object())
            result.update(flatten(item, prefix + "." + key));
        else
            result[prefix + "." + key] = item;
    }
    return result;
}
struct Builder {
    fs::path root;
    std::string metadata_prefix;
    Json files = Json::object(), effects = Json::object();
    std::map<std::string, Json> definitions;
    size_t total = 0;
    explicit Builder(fs::path path) : root(std::move(path)) {}
    Json toml(const std::string &name) {
        return json_table(toml::parse(read(contained(root, name), 256 * 1024)));
    }
    std::string file(const std::string &name) {
        if (files.contains(name))
            return name;
        const auto suffix = fs::path(name).extension().string();
        const bool media = suffix == ".png" || suffix == ".webp" || suffix == ".gif" || suffix == ".mp4" ||
                           suffix == ".webm";
        const auto data = read(contained(root, name), media ? 32 * document_limit : 256 * 1024);
        total += data.size();
        require(files.size() < 10000 && total <= 512 * document_limit, "Local catalogue exceeds limits");
        files[name] = {{"bytes", data.size()}, {"sha256", sha256(data)}};
        return name;
    }
    Json optional(const std::string &name) {
        return fs::exists(contained(root, name)) ? Json(file(name)) : Json(nullptr);
    }
    std::set<std::string> closure(const std::set<std::string> &ids) const {
        std::set<std::string> found, visiting;
        std::function<void(const std::string &)> visit = [&](const std::string &id) {
            require(effects.contains(id), "Missing local dependency: " + id);
            require(!visiting.contains(id) && visiting.size() < 64, "Cyclic local dependency");
            if (found.contains(id))
                return;
            visiting.insert(id);
            for (const auto &dependency : effects.at(id).at("dependencies"))
                visit(dependency);
            visiting.erase(id);
            found.insert(id);
        };
        for (const auto &id : ids)
            visit(id);
        return found;
    }
    std::vector<std::string> roots(const std::set<std::string> &ids) const {
        auto direct = ids;
        for (const auto &id : ids)
            for (const auto &dependency :
                 closure(effects.at(id).at("dependencies").get<std::set<std::string>>()))
                direct.erase(dependency);
        std::vector<std::string> result;
        for (const auto &id : direct)
            result.push_back(id + "/effect.toml");
        return result;
    }
    void effect(const std::string &id, const std::string &metadata) {
        const auto kind = id.substr(0, id.find('/'));
        const auto meta = toml(metadata), data = toml(id + "/effect.toml");
        require(data.contains("effects") && data.at("effects").size() == 1 &&
                    (data.size() == 1 || (data.size() == 2 && data.contains("include"))),
                "Unexpected local preset sections");
        const auto &presets = data.at("effects").at("preset");
        require(presets.is_object() && presets.size() == 1, "Each local effect must define one preset");
        const auto name = presets.begin().key();
        const auto definition = presets.begin().value();
        validate_definition(definition, kind);
        definitions[id] = definition;
        const auto shader = reference(id, definition.at("shader"));
        require(shader.starts_with(id + "/") && fs::path(shader).extension() == ".glsl",
                "Invalid local shader path");
        std::set<std::string> dependencies;
        const auto includes = data.value("include", Json::object());
        require(includes.empty() || (includes.size() == 1 && includes.contains("files")),
                "Invalid local include table");
        for (const auto &value : includes.value("files", Json::array())) {
            const auto path = reference(id, value);
            require(path.ends_with("/effect.toml"), "Local include must reference effect.toml");
            dependencies.insert(path.substr(0, path.size() - 12));
        }
        auto feature_list = meta.value("requirements", Json::object()).value("features", Json::array());
        auto features = feature_list.get<std::vector<std::string>>();
        if (std::find(features.begin(), features.end(), "preset-effects") == features.end())
            features.insert(features.begin(), "preset-effects");
        const auto role = meta.value("role", "effect");
        const auto uses =
            meta.value("uses", role == "companion" || kind == "animation" ? Json::array()
                                                                          : Json::array({"effects." + kind}));
        const auto notices = meta.at("notice_files");
        std::set<std::string> install = notices.get<std::set<std::string>>();
        install.insert({id + "/effect.toml", shader});
        for (const auto &path : install)
            file(path);
        Json animation = nullptr;
        for (const auto *suffix : {".webm", ".mp4", ".gif"}) {
            animation = optional(id + "/preview" + suffix);
            if (!animation.is_null())
                break;
        }
        effects[id] = {{"id", id},
                       {"path", id},
                       {"kind", kind},
                       {"role", role},
                       {"preset", name},
                       {"name", meta.at("name")},
                       {"description", meta.at("description")},
                       {"author", meta.at("author")},
                       {"license", meta.at("license")},
                       {"notice_files", notices},
                       {"tags", meta.value("tags", Json::array())},
                       {"uses", uses},
                       {"dependencies", dependencies},
                       {"families", Json::array()},
                       {"requirements", {{"features", features}}},
                       {"required_settings", meta.value("required_settings", Json::object())},
                       {"tested_on", meta.value("tested_on", Json::array())},
                       {"install_files", install},
                       {"preview", {{"image", optional(id + "/preview.png")}, {"animation", animation}}},
                       {"readme", optional(id + "/README.md")},
                       {"config_example", optional(id + "/config.toml")},
                       {"activation", nullptr}};
    }
    Json recipe(const std::string &id) {
        if (effects.at(id).at("config_example").is_null() || effects.at(id).at("uses").empty())
            return nullptr;
        const auto data = toml(effects.at(id).at("config_example"));
        for (const auto &[key, ignored] : data.items()) {
            (void)ignored;
            require(key == "include" || key == "effects" || key == "animation",
                    "Unexpected activation section");
        }
        std::set<std::string> included;
        for (const auto &value : data.value("include", Json::object()).value("files", Json::array())) {
            auto path = value.get<std::string>();
            require(path.starts_with("shaders/community/") && path.ends_with("/effect.toml"),
                    "Invalid example include");
            path = path.substr(18, path.size() - 18 - 12);
            relative_path(path);
            included.insert(path);
        }
        const auto allowed = closure({id}), available = closure(included);
        for (const auto &member : included)
            require(allowed.contains(member), "Example includes an unrelated effect");
        Json settings = Json::object();
        bool manual = false;
        for (const auto *section : {"effects", "animation"})
            if (data.contains(section))
                settings.update(flatten(data.at(section), section));
        std::set<std::string> slots;
        for (const auto &[key, value] : settings.items()) {
            if (key == "effects.max_fps" || key == "effects.in_capture") {
                manual = true;
                continue;
            }
            validate_setting(key, value);
            if (key.starts_with("effects.") || key.ends_with(".effect")) {
                require(value == effects.at(id).at("preset") && available.contains(id),
                        "Example selects an unrelated effect");
                const auto slot = setting_scope(key);
                const auto uses = effects.at(id).at("uses").get<std::set<std::string>>();
                require(uses.contains(slot), "Example selects an unsupported use");
                slots.insert(slot);
            }
        }
        require(!slots.empty(), "Example has no effect selection");
        for (const auto &[key, ignored] : settings.items()) {
            (void)ignored;
            if (key == "effects.max_fps" || key == "effects.in_capture")
                continue;
            require(setting_scope(key).empty() || slots.contains(setting_scope(key)),
                    "Example changes an unselected event");
        }
        const std::set<std::string> springs{"defaultspring", "bouncy", "smooth", "stiff"};
        for (const auto &slot : slots)
            require(!springs.contains(settings.value(slot + ".curve", "")) ||
                        !settings.contains(slot + ".duration_ms"),
                    "Spring duration cannot be overridden");
        for (const auto &member : allowed)
            for (const auto &[key, value] : effects.at(member).at("required_settings").items())
                require(!settings.contains(key) || settings.at(key) == value,
                        "Example conflicts with requirements");
        return manual ? Json(nullptr) : Json{{"include", roots(included)}, {"settings", settings}};
    }
    Json registry() const {
        Json list = Json::array();
        for (const auto &[id, effect] : effects.items()) {
            (void)id;
            list.push_back(effect);
        }
        return {{"schema_version", 1},
                {"draft", true},
                {"source", {{"repository", repository}, {"revision", nullptr}}},
                {"feature_definitions",
                 {{"preset-effects", "Umbriel named effect presets and selectors; the original preset API "
                                     "was introduced at 512e2fb3."},
                  {"workspace-reveal-full-scene",
                   "Full-scene workspace reveal: outgoing and incoming scene sampling, including "
                   "umbriel_sample_incoming, with reveal mode. Older root-mask and scene-v1 interfaces are "
                   "incompatible."},
                  {"cursor-pointer-history",
                   "Selection pointer history via umbriel_pointer_count and umbriel_pointer_path[64]."}}},
                {"effects", list},
                {"families", Json::array()},
                {"files", files}};
    }
    Json finish() {
        require(!effects.empty(), "No local effect metadata found");
        for (auto &[id, effect] : effects.items()) {
            const auto dependencies = closure({id});
            const auto overlay = definitions.at(id).value("overlay", "");
            if (!overlay.empty())
                require(std::ranges::any_of(dependencies,
                                            [&](const auto &member) {
                                                return effects.at(member).at("kind") == "window" &&
                                                       effects.at(member).at("preset") == overlay;
                                            }),
                        "Border overlay is not an included window dependency");
            effect["activation"] = recipe(id);
        }
        Json families = Json::array();
        const auto family_file = metadata_prefix + "families.toml";
        const auto all_families = fs::exists(contained(root, family_file))
                                      ? toml(family_file).value("families", Json::object())
                                      : Json::object();
        Catalogue catalogue(registry(), root, true);
        for (const auto &[id, family] : all_families.items()) {
            const auto members = family.at("members").get<std::set<std::string>>();
            const auto dependencies = closure(members);
            std::set<std::string> authors;
            for (const auto &member : dependencies)
                authors.insert(effects.at(member).at("author"));
            Json activation = nullptr, settings = Json::object(), required = Json::object();
            std::set<std::string> selected;
            const auto defaults = family.value("defaults", Json::object());
            for (const auto &[slot, member] : defaults.items()) {
                require(members.contains(member.get<std::string>()), "Family default is not a member");
                const auto binding = catalogue.binding(member, slot);
                for (const auto &[key, value] : binding.settings.items()) {
                    require(!settings.contains(key) || settings.at(key) == value,
                            "Conflicting family settings");
                    settings[key] = value;
                }
                for (const auto &[key, value] : binding.required.items()) {
                    require(!required.contains(key) || required.at(key) == value,
                            "Conflicting family requirements");
                    required[key] = value;
                }
                selected.insert(member.get<std::string>());
            }
            for (const auto &[key, value] : required.items()) {
                require(!settings.contains(key) || settings.at(key) == value,
                        "Family defaults conflict with requirements");
                if (key == "animation.enabled" || defaults.contains(setting_scope(key)))
                    settings[key] = value;
            }
            if (!selected.empty())
                activation = {{"include", roots(selected)}, {"settings", settings}};
            for (const auto &member : members)
                effects[member]["families"].push_back(id);
            families.push_back({{"id", id},
                                {"name", family.at("name")},
                                {"description", family.at("description")},
                                {"members", family.at("members")},
                                {"tags", family.value("tags", Json::array())},
                                {"authors", authors},
                                {"preview", {{"image", nullptr}, {"animation", nullptr}}},
                                {"readme", nullptr},
                                {"config_example", nullptr},
                                {"activation", activation}});
        }
        auto result = registry();
        result["families"] = families;
        validate_registry(result, true);
        return result;
    }
};
} // namespace
Json local_registry(const fs::path &input, const fs::path &cache, bool refresh) {
    require(!input.empty() && fs::is_directory(input), "Choose the community shader checkout");
    const auto root = fs::absolute(input);
    Json stamps = Json::object();
    std::vector<std::string> metadata, fallback;
    for (fs::recursive_directory_iterator it(root), end; it != end; ++it) {
        const auto path = it->path().lexically_relative(root).generic_string();
        if (it->is_directory() && it->path().filename().string().starts_with('.')) {
            it.disable_recursion_pending();
            continue;
        }
        if (it->is_symlink()) {
            stamps[path] = "symlink";
            continue;
        }
        if (!it->is_regular_file())
            continue;
        struct stat info{};
        require(::stat(it->path().c_str(), &info) == 0, "Cannot inspect local shader file");
        stamps[path] = Json::array({info.st_size, info.st_mtim.tv_sec, info.st_mtim.tv_nsec,
                                    info.st_ctim.tv_sec, info.st_ctim.tv_nsec});
        require(stamps.size() <= 10000, "Too many files in local shader checkout");
        if (std::regex_match(path,
                             std::regex("(cursor|border|window|screen|animation)/[^/]+/metadata\\.toml")))
            metadata.push_back(path);
        else if (std::regex_match(
                     path, std::regex("docs/catalogue-examples/(cursor|border|window|screen|animation)/[^/]+/"
                                      "metadata\\.toml")))
            fallback.push_back(path);
    }
    const auto signature = sha256("native-local-v1:" + stamps.dump());
    const auto directory = contained(cache, sha256(root.string()).substr(0, 16));
    const auto saved = contained(directory, "catalogue.json"), stamp = contained(directory, "signature");
    if (!refresh && fs::exists(saved) && fs::exists(stamp) && read(stamp) == signature) {
        auto registry = parse_json(read(saved, 4 * document_limit));
        validate_registry(registry, true);
        return registry;
    }
    Builder builder(root);
    if (metadata.empty()) {
        metadata = std::move(fallback);
        builder.metadata_prefix = "docs/catalogue-examples/";
    }
    std::sort(metadata.begin(), metadata.end());
    for (const auto &path : metadata) {
        const auto relative = path.substr(builder.metadata_prefix.size());
        builder.effect(relative.substr(0, relative.size() - 14), path);
    }
    const auto registry = builder.finish();
    const auto bytes = registry.dump();
    require(bytes.size() <= 4 * document_limit, "Local catalogue index is too large");
    atomic_write(saved, bytes);
    atomic_write(stamp, signature);
    return registry;
}
} // namespace shaders
