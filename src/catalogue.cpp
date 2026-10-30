// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <functional>
#include <regex>
#include <set>
#include <sstream>

namespace shaders {
namespace {
fs::path expand(std::string value, const fs::path &parent, const std::map<std::string, std::string> &env) {
    require(value.find('\0') == std::string::npos, "NUL in configuration path");
    if (value == "~" || value.starts_with("~/")) {
        require(env.contains("HOME"), "HOME is required for tilde expansion");
        value = env.at("HOME") + value.substr(1);
    }
    static const std::regex variable(R"(\$\{([^}]+)\}|\$([A-Za-z_][A-Za-z0-9_]*))");
    std::smatch match;
    std::string expanded;
    while (std::regex_search(value, match, variable)) {
        expanded += match.prefix().str();
        const auto key = match[1].matched ? match[1].str() : match[2].str();
        if (env.contains(key))
            expanded += env.at(key);
        value = match.suffix();
    }
    return fs::absolute(parent / (expanded + value)).lexically_normal();
}
} // namespace
Graph config_graph(const fs::path &base, const std::map<std::string, std::string> &env) {
    Graph result;
    std::set<fs::path> visited;
    std::function<void(fs::path, bool, unsigned)> visit = [&](fs::path path, bool optional, unsigned depth) {
        require(depth < 32 && result.files.size() < 256, "Configuration graph exceeds limits");
        path = fs::absolute(path).lexically_normal();
        if (optional && !fs::exists(path)) {
            result.files[path.string()] = "missing";
            return;
        }
        require(visited.insert(fs::canonical(path)).second, "Duplicate or cyclic configuration include");
        result.files[path.string()] = fingerprint(path);
        auto data = json_table(toml::parse(read(path)));
        const auto includes = data.value("include", Json::object());
        require(includes.is_object(), "Invalid include table");
        auto group = [&](const Json &value, bool opt) {
            const auto files = value.value("files", Json::array());
            require(files.is_array(), "Invalid include files array");
            for (const auto &name : files)
                visit(expand(name.get<std::string>(), path.parent_path(), env), opt, depth + 1);
        };
        group(includes, false);
        group(includes.value("optional", Json::object()), true);
        result.drm = result.drm || data.contains("drm");
        const auto effects = data.value("effects", Json::object());
        for (const auto *kind : {"cursor", "border", "window", "screen"})
            if (effects.contains(kind))
                result.settings[std::string("effects.") + kind] = effects.at(kind);
        std::function<void(const Json &, const std::string &)> flatten = [&](const Json &value,
                                                                             const std::string &prefix) {
            for (const auto &[key, item] : value.items()) {
                if (item.is_object())
                    flatten(item, prefix + "." + key);
                else
                    result.settings[prefix + "." + key] = item;
            }
        };
        if (data.contains("animation"))
            flatten(data.at("animation"), "animation");
        const auto presets = effects.value("preset", Json::object());
        for (const auto &[name, preset] : presets.items()) {
            require(!result.presets.contains(name) && !name.starts_with(marker_prefix) &&
                        !name.starts_with("umbriel-shaders-generation-"),
                    "Conflicting or managed preset in base");
            Json definition = preset;
            if (preset.contains("shader")) {
                auto shader = expand(preset.at("shader").get<std::string>(), path.parent_path(), env);
                definition["shader"] = shader.string();
                result.files[shader.string()] = fingerprint(shader);
            }
            result.presets.emplace(name, std::move(definition));
        }
        const auto pools = effects.value("pool", Json::object());
        for (const auto &[name, pool] : pools.items()) {
            (void)pool;
            require(!result.presets.contains(name), "Pool and preset have the same name");
            result.presets[name] = {{"kind", "pool"}};
        }
    };
    visit(base, false, 0);
    return result;
}
Catalogue::Catalogue(const fs::path &index, fs::path assets)
    : Catalogue(parse_json(read(index, 4 * document_limit)), std::move(assets)) {}
Catalogue::Catalogue(Json registry, fs::path assets, bool local)
    : registry_(std::move(registry)), assets_(std::move(assets)) {
    validate_registry(registry_, local);
}
Json Catalogue::browse(size_t offset) const {
    Json effects = Json::array(), families = Json::array();
    size_t index = 0, used = 0;
    const auto total = registry_.at("effects").size() + registry_.at("families").size();
    require(offset <= total, "Invalid catalogue offset");
    for (auto effect : registry_.at("effects")) {
        if (index < offset) {
            ++index;
            continue;
        }
        effect["local_preview"] = {{"image", nullptr}, {"animation", nullptr}};
        if (!assets_.empty() && effect.at("preview").contains("image") &&
            effect["preview"]["image"].is_string()) {
            auto path = contained(assets_, effect["preview"]["image"].get<std::string>());
            if (fs::is_regular_file(path))
                effect["local_preview"]["image"] = path.string();
        }
        if (mode_ == "online") {
            for (const auto *kind : {"image", "animation"}) {
                const auto name = effect.at("preview").value(kind, Json(nullptr));
                if (!name.is_string())
                    continue;
                if (std::string(kind) == "animation")
                    effect["local_preview"][kind] = url(name);
                else {
                    const auto path = object_path(name);
                    if (fs::is_regular_file(path) &&
                        fs::file_size(path) == registry_.at("files").at(name.get<std::string>()).at("bytes"))
                        effect["local_preview"][kind] = path.string();
                }
            }
        } else if (!assets_.empty() && effect.at("preview").value("animation", Json(nullptr)).is_string()) {
            const auto path = contained(assets_, effect.at("preview").at("animation").get<std::string>());
            if (fs::is_regular_file(path))
                effect["local_preview"]["animation"] = path.string();
        }
        for (const auto *key : {"install_files", "notice_files", "tested_on", "path"})
            effect.erase(key);
        Json projection = Json::object();
        for (const auto *key :
             {"id", "name", "description", "author", "license", "preset", "kind", "role", "tags", "families",
              "uses", "requirements", "required_settings", "preview", "local_preview"})
            if (effect.contains(key))
                projection[key] = effect.at(key);
        projection["activation"] = effect.at("activation").is_object()
                                       ? Json{{"settings", effect.at("activation").at("settings")}}
                                       : Json(nullptr);
        const auto size = projection.dump().size();
        require(size < 128 * 1024, "Catalogue display record is too large");
        if (used + size > 512 * 1024)
            break;
        used += size;
        ++index;
        effects.push_back(std::move(projection));
    }
    if (index == registry_.at("effects").size()) {
        for (const auto &family : registry_.at("families")) {
            if (index < offset) {
                ++index;
                continue;
            }
            Json projection = Json::object();
            for (const auto *key : {"id", "name", "description", "members", "tags", "authors", "activation"})
                if (family.contains(key))
                    projection[key] = family.at(key);
            projection["activation"] = family.at("activation").is_object()
                                           ? Json{{"settings", family.at("activation").at("settings")}}
                                           : Json(nullptr);
            const auto size = projection.dump().size();
            require(size < 128 * 1024, "Family display record is too large");
            if (used + size > 512 * 1024)
                break;
            used += size;
            ++index;
            families.push_back(std::move(projection));
        }
    }
    Json result = {{"mode", mode_},
                   {"native", true},
                   {"offline", offline_},
                   {"effects", effects},
                   {"families", families},
                   {"offset", offset},
                   {"next_offset", index < total ? Json(index) : Json(nullptr)},
                   {"total_effects", registry_.at("effects").size()},
                   {"total_families", registry_.at("families").size()},
                   {"fingerprint", sha256(registry_.dump())},
                   {"features", registry_.at("feature_definitions")},
                   {"revision", registry_.at("source").at("revision")}};
    require(result.dump().size() < 768 * 1024, "Browser projection exceeds host transport budget");
    return result;
}
Resolved Catalogue::resolve(const Bindings &bindings, const Graph &base, const fs::path &library,
                            bool compare_local) const {
    Resolved result;
    std::map<std::string, Json> effects;
    std::map<std::string, std::string> names;
    for (const auto &effect : registry_.at("effects")) {
        effects[effect.at("id")] = effect;
        names[effect.at("preset")] = effect.at("id");
    }
    auto local_copy = [&](const std::string &id, const std::string &name, Json definition,
                          const fs::path &shader, const std::string &config) {
        Json copy = {{"preset", name}, {"config", config}, {"matches_catalogue", nullptr}};
        if (compare_local && effects.contains(id)) {
            try {
                auto published =
                    json_table(toml::parse(bytes(id + "/effect.toml"))).at("effects").at("preset").at(name);
                validate_definition(published, definition.at("kind"));
                const auto path = (fs::path(id) / published.at("shader").get<std::string>())
                                      .lexically_normal()
                                      .generic_string();
                relative_path(path);
                require(path.starts_with(id + "/"), "Comparison shader is outside effect directory");
                definition.erase("shader");
                published.erase("shader");
                copy["matches_catalogue"] =
                    definition == published &&
                    sha256(read(shader)) == registry_.at("files").at(path).at("sha256").get<std::string>();
            } catch (const std::exception &error) {
                copy["comparison_error"] = error.what();
            }
        }
        result.local_copies.push_back(std::move(copy));
    };
    // Installed names remain discoverable when the remote entry is withdrawn.
    for (const auto *kind : {"cursor", "border", "window", "screen", "animation"}) {
        const auto directory = contained(library, kind);
        if (!fs::exists(directory))
            continue;
        size_t count = 0;
        for (const auto &entry : fs::directory_iterator(directory)) {
            require(++count <= 512, "Too many installed effect records");
            const auto id = std::string(kind) + "/" + entry.path().filename().string();
            const auto record_path = contained(library, id + "/preset.json");
            if (!fs::is_regular_file(record_path))
                continue;
            const auto record = load(record_path);
            require(record.at("id") == id, "Installed preset identity mismatch");
            names[record.at("name")] = id;
        }
    }
    std::set<std::string> visiting;
    std::function<void(std::string, std::string, std::string)> visit;
    auto overlay = [&](const Json &definition) {
        const auto name = definition.value("overlay", "");
        if (name.empty())
            return;
        require(base.presets.contains(name) || names.contains(name), "Missing companion overlay: " + name);
        visit(names.contains(name) ? names.at(name) : "", name, "window");
    };
    visit = [&](const std::string &id, const std::string &name, const std::string &kind) {
        require(!visiting.contains(name) && visiting.size() < 64, "Cyclic installed overlay reference");
        if (result.presets.contains(name))
            return;
        visiting.insert(name);
        if (base.presets.contains(name)) {
            const auto definition = base.presets.at(name);
            validate_definition(definition, kind);
            overlay(definition);
            local_copy(id, name, definition, definition.at("shader").get<std::string>(),
                       "Original configuration");
        } else {
            require(!id.empty(), "Missing effect identity for " + name);
            const auto directory = contained(library, id);
            const auto record_path = contained(directory, "preset.json");
            Json definition;
            std::vector<std::string> notice_paths;
            if (fs::exists(record_path)) {
                const auto record = load(record_path);
                require(record.at("id") == id && record.at("name") == name,
                        "Installed preset identity changed");
                definition = record.at("definition");
                validate_definition(definition, kind);
                require(definition.at("shader") == "shader.glsl", "Installed shader path changed");
                notice_paths = record.value("notices", std::vector<std::string>{});
                overlay(definition);
                local_copy(id, name, definition, contained(directory, "shader.glsl"), record_path.string());
            } else {
                require(effects.contains(id), "Withdrawn preset is not installed: " + id);
                const auto &effect = effects.at(id);
                require(effect.at("preset") == name && effect.at("kind") == kind,
                        "Catalogue preset identity changed");
                const auto preset_path = id + "/effect.toml";
                const auto data = json_table(toml::parse(bytes(preset_path)));
                require(data.is_object() && data.size() <= 2 && data.contains("effects") &&
                            (data.size() == 1 || data.contains("include")) && data.at("effects").size() == 1,
                        "Unexpected preset configuration sections");
                const auto definitions = data.at("effects").at("preset");
                require(definitions.size() == 1 && definitions.contains(name),
                        "Downloaded preset identity mismatch");
                definition = definitions.at(name);
                validate_definition(definition, kind);
                const auto shader_path = (fs::path(id) / definition.at("shader").get<std::string>())
                                             .lexically_normal()
                                             .generic_string();
                relative_path(shader_path);
                require(shader_path.starts_with(id + "/") && fs::path(shader_path).extension() == ".glsl",
                        "Invalid shader path");
                const auto includes = data.value("include", Json::object());
                require(includes.empty() || (includes.size() == 1 && includes.contains("files")),
                        "Unexpected preset include fields");
                std::set<std::string> dependencies;
                for (const auto &ref : includes.value("files", Json::array())) {
                    const auto path =
                        (fs::path(id) / ref.get<std::string>()).lexically_normal().generic_string();
                    relative_path(path);
                    require(path.ends_with("/effect.toml"), "Invalid dependency include");
                    dependencies.insert(path.substr(0, path.size() - 12));
                }
                require(dependencies == effect.at("dependencies").get<std::set<std::string>>(),
                        "Preset dependencies differ from catalogue");
                std::map<std::string, std::string> notices;
                std::set<std::string> expected{preset_path, shader_path};
                const auto shader_bytes = bytes(shader_path);
                require(!effect.at("notice_files").empty(), "Preset is missing attribution notices");
                for (const auto &value : effect.at("notice_files")) {
                    const auto notice = value.get<std::string>();
                    require(fs::path(notice).extension() == ".md" || fs::path(notice).extension() == ".txt",
                            "Invalid notice type");
                    notices[notice] = bytes(notice);
                    expected.insert(notice);
                    notice_paths.push_back(notice);
                }
                require(expected == effect.at("install_files").get<std::set<std::string>>(),
                        "Unexpected installation files");
                const auto companion = definition.value("overlay", "");
                if (!companion.empty()) {
                    require(base.presets.contains(companion) ||
                                std::ranges::any_of(dependencies,
                                                    [&](const auto &dep) {
                                                        return effects.at(dep).at("preset") == companion;
                                                    }),
                            "Overlay is not a declared dependency");
                    overlay(definition);
                }
                const auto shader = contained(directory, "shader.glsl");
                require(!fs::exists(shader) || read(shader) == shader_bytes,
                        "Unrecorded customised shader needs review");
                atomic_write(shader, shader_bytes);
                for (const auto &[notice, value] : notices) {
                    const auto path = contained(library / "notices", notice);
                    if (!fs::exists(path))
                        atomic_write(path, value);
                }
                definition["shader"] = "shader.glsl";
                save(record_path,
                     {{"id", id}, {"name", name}, {"definition", definition}, {"notices", notice_paths}});
            }
            const auto shader = contained(directory, "shader.glsl");
            definition["shader"] = shader.string();
            result.definitions[name] = definition;
            result.files[record_path.string()] = fingerprint(record_path);
            result.files[shader.string()] = fingerprint(shader);
            for (const auto &notice : notice_paths) {
                const auto path = contained(library / "notices", notice);
                result.files[path.string()] = fingerprint(path);
            }
        }
        visiting.erase(name);
        result.presets.insert(name);
    };
    for (const auto &[slot, binding] : bindings) {
        (void)slot;
        visit(binding.id, binding.name, binding.kind);
    }
    return result;
}
} // namespace shaders
