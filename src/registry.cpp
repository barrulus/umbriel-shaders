// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <regex>

namespace shaders {
namespace {
void string(const Json &value, size_t limit = 2048) {
    require(value.is_string(), "Expected catalogue string");
    const auto &text = value.get_ref<const std::string &>();
    require(!text.empty() && text.size() <= limit && text.find('\0') == std::string::npos,
            "Invalid/oversized catalogue string");
}
void strings(const Json &values, size_t count = 64) {
    require(values.is_array() && values.size() <= count, "Invalid catalogue list");
    std::set<std::string> seen;
    for (const auto &value : values) {
        string(value, 256);
        require(seen.insert(value).second, "Duplicate catalogue list value");
    }
}
} // namespace
void validate_registry(const Json &registry, bool local) {
    require(registry.is_object() && registry.at("schema_version") == 1 && registry.at("draft").is_boolean() &&
                (local || registry.at("draft") == false),
            "A published schema-v1 catalogue is required");
    require(registry.at("source").at("repository") ==
                "https://github.com/noctalia-dev/community-umbriel-shaders",
            "Unexpected catalogue repository");
    require(local || (registry.at("source").at("revision").is_string() &&
                      hex_string(registry.at("source").at("revision").get<std::string>(), 40)),
            "Catalogue needs a pinned source revision");
    const auto &files = registry.at("files");
    require(files.is_object() && files.size() <= 10000, "Invalid catalogue files");
    uintmax_t total = 0;
    const std::set<std::string> media{".png", ".webp", ".gif", ".mp4", ".webm"};
    for (const auto &[name, record] : files.items()) {
        relative_path(name);
        const auto extension = fs::path(name).extension().string();
        require(media.contains(extension) || extension == ".glsl" || extension == ".toml" ||
                    extension == ".md" || extension == ".txt",
                "Invalid catalogue file type");
        require(record.is_object() && record.size() == 2 && record.at("bytes").is_number_unsigned() &&
                    record.at("bytes") <= (media.contains(extension) ? 32 * document_limit : 256 * 1024),
                "Invalid catalogue file size");
        require(record.at("sha256").is_string() && hex_string(record.at("sha256").get<std::string>(), 64),
                "Invalid catalogue file hash");
        total += record.at("bytes").get<size_t>();
    }
    require(total <= 512 * document_limit, "Catalogue exceeds total file size limit");
    const auto &features = registry.at("feature_definitions");
    require(features.is_object() && features.size() <= 64 && features.contains("preset-effects"),
            "Invalid feature definitions");
    for (const auto &[name, description] : features.items()) {
        string(name, 128);
        string(description);
    }
    const auto &effects = registry.at("effects");
    require(effects.is_array() && effects.size() <= 512, "Too many catalogue entries");
    std::map<std::string, const Json *> identifiers;
    std::set<std::string> presets;
    for (const auto &effect : effects) {
        const auto id = effect.at("id").get<std::string>();
        require(id.size() <= 128 &&
                    std::regex_match(
                        id, std::regex("(cursor|border|window|screen|animation)/[a-z0-9]+(-[a-z0-9]+)*")) &&
                    identifiers.emplace(id, &effect).second,
                "Invalid or duplicate effect ID");
        require(effect.at("path") == id && effect.at("kind") == id.substr(0, id.find('/')),
                "Mismatched effect path/kind");
        require(effect.at("role") == "effect" || effect.at("role") == "companion", "Invalid catalogue role");
        for (const auto *key : {"name", "description", "author", "license", "preset"})
            string(effect.at(key));
        const auto name = effect.at("preset").get<std::string>();
        require(name.size() <= 128 && name.find('/') == std::string::npos && presets.insert(name).second &&
                    name != "off" && !name.starts_with(marker_prefix) &&
                    !name.starts_with("umbriel-shaders-generation-"),
                "Invalid preset name");
        for (const auto *key : {"tags", "families", "uses", "dependencies", "notice_files", "install_files"})
            strings(effect.at(key));
        for (const auto &slot : effect.at("uses")) {
            const auto use = slot.get<std::string>();
            require(valid_slot(use) && (effect.at("kind") == "animation"
                                            ? use.starts_with("animation.")
                                            : use == "effects." + effect.at("kind").get<std::string>()),
                    "Invalid catalogue use");
        }
        require(effect.at("required_settings").is_object(), "Invalid required settings");
        for (const auto &[key, value] : effect.at("required_settings").items()) {
            validate_setting(key, value);
            require(!key.starts_with("effects.") && !key.ends_with(".effect"),
                    "Requirements cannot select effects");
        }
        if (effect.contains("requirements")) {
            strings(effect.at("requirements").at("features"));
            for (const auto &feature : effect.at("requirements").at("features"))
                require(features.contains(feature.get<std::string>()), "Unrecognised feature requirement");
        }
        std::set<std::string> install;
        size_t shaders = 0;
        for (const auto &path : effect.at("install_files")) {
            const auto file = path.get<std::string>();
            require(files.contains(file), "Missing install file record");
            if (fs::path(file).extension() == ".glsl") {
                ++shaders;
                require(file.starts_with(id + "/"), "Shader outside effect directory");
            }
            install.insert(file);
        }
        require(shaders == 1 && install.contains(id + "/effect.toml") && !effect.at("notice_files").empty(),
                "Invalid preset installation files");
        require(install.size() == effect.at("notice_files").size() + 2, "Unexpected installation files");
        for (const auto &path : effect.at("notice_files")) {
            const auto file = path.get<std::string>();
            require(install.contains(file) &&
                        (fs::path(file).extension() == ".md" || fs::path(file).extension() == ".txt"),
                    "Invalid attribution notice");
        }
        require(effect.at("preview").is_object(), "Invalid preview metadata");
        for (const auto &[key, value] : effect.at("preview").items()) {
            require(key == "image" || key == "animation", "Invalid preview field");
            if (value.is_null())
                continue;
            const auto file = value.get<std::string>(), suffix = fs::path(file).extension().string();
            require(files.contains(file) &&
                        (key == "image" ? suffix == ".png" || suffix == ".webp"
                                        : suffix == ".gif" || suffix == ".mp4" || suffix == ".webm"),
                    "Invalid preview path/type");
        }
        const auto &recipe = effect.at("activation");
        require(recipe.is_null() || (recipe.is_object() && recipe.at("settings").is_object()),
                "Invalid activation recipe");
        if (recipe.is_object())
            for (const auto &[key, value] : recipe.at("settings").items())
                validate_setting(key, value);
    }
    std::set<std::string> visited, visiting;
    std::function<void(const std::string &)> visit = [&](const std::string &id) {
        require(identifiers.contains(id), "Missing dependency: " + id);
        require(!visiting.contains(id) && visiting.size() < 64, "Cyclic or excessive dependency graph");
        if (visited.contains(id))
            return;
        visiting.insert(id);
        for (const auto &dependency : identifiers.at(id)->at("dependencies"))
            visit(dependency.get<std::string>());
        visiting.erase(id);
        visited.insert(id);
    };
    for (const auto &[id, ignored] : identifiers) {
        (void)ignored;
        visit(id);
    }
    require(registry.at("families").is_array() && registry.at("families").size() <= 64, "Too many families");
    std::set<std::string> families;
    for (const auto &family : registry.at("families")) {
        const auto id = family.at("id").get<std::string>();
        require(id.size() <= 128 && std::regex_match(id, std::regex("[a-z0-9]+(-[a-z0-9]+)*")) &&
                    families.insert(id).second,
                "Invalid family ID");
        string(family.at("name"));
        strings(family.at("members"));
        for (const auto *key : {"description", "license"})
            if (family.contains(key) && !family.at(key).is_null())
                string(family.at(key));
        for (const auto *key : {"tags", "authors"})
            if (family.contains(key))
                strings(family.at(key));
        for (const auto &member : family.at("members"))
            require(identifiers.contains(member.get<std::string>()), "Missing family member");
        const auto &recipe = family.at("activation");
        require(recipe.is_null() || (recipe.is_object() && recipe.at("settings").is_object()),
                "Invalid family recipe");
        if (recipe.is_object())
            for (const auto &[key, value] : recipe.at("settings").items())
                validate_setting(key, value);
    }
}
} // namespace shaders
