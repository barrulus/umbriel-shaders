// SPDX-License-Identifier: MIT
#include "core.hpp"
#include <cmath>
#include <sstream>

namespace shaders {
namespace {
const std::set<std::string> events{"windows_in", "windows_out", "windows_move",  "workspaces", "overview",
                                   "scratchpad", "border",      "dim_unfocused", "layers"};
void number(const Json &value, double low, double high, bool integer = false) {
    require(value.is_number() && (!integer || value.is_number_integer()) &&
                std::isfinite(value.get<double>()) && value >= low && value <= high,
            "Invalid numeric effect setting");
}
void fields(const Json &value, const std::set<std::string> &allowed) {
    require(value.is_object(), "Expected an effect settings object");
    for (const auto &[key, ignored] : value.items()) {
        (void)ignored;
        require(allowed.contains(key), "Unexpected effect field: " + key);
    }
}
const Json &find(const Json &records, const std::string &id) {
    for (const auto &record : records)
        if (record.at("id") == id)
            return record;
    throw Error("Unknown catalogue entry: " + id);
}
} // namespace
Json json_table(const toml::table &table) {
    std::ostringstream stream;
    stream << toml::json_formatter(table);
    return parse_json(stream.str());
}
bool valid_slot(const std::string &slot) {
    return slot == "effects.cursor" || slot == "effects.border" || slot == "effects.window" ||
           slot == "effects.screen" || (slot.starts_with("animation.") && events.contains(slot.substr(10)));
}
std::string setting_scope(const std::string &key) {
    if (key == "animation.enabled")
        return "";
    if (key.starts_with("effects."))
        return key;
    const auto end = key.find('.', key.find('.') + 1);
    return key.substr(0, end);
}
void validate_setting(const std::string &key, const Json &value) {
    const auto selector = [&] {
        require(value.is_string() && !value.get_ref<const std::string &>().empty() &&
                    value.get_ref<const std::string &>().size() <= 128 &&
                    value.get_ref<const std::string &>().find('\0') == std::string::npos,
                "Invalid effect selector");
    };
    if (key.starts_with("effects.") && valid_slot(key)) {
        selector();
        return;
    }
    if (key == "animation.enabled") {
        require(value.is_boolean(), "Animation enabled must be boolean");
        return;
    }
    const auto slot = setting_scope(key);
    require(slot.starts_with("animation.") && valid_slot(slot) && key.size() > slot.size() + 1,
            "Unapproved activation setting: " + key);
    const auto field = key.substr(slot.size() + 1), event = slot.substr(10);
    if (field == "enabled")
        require(value.is_boolean(), "Animation enabled must be boolean");
    else if (field == "effect")
        selector();
    else if (field == "duration_ms")
        number(value, 1, 10000, true);
    else if (field == "scale" && (event == "windows_in" || event == "windows_out" || event == "scratchpad"))
        number(value, event == "scratchpad" ? 0 : .1, 1);
    else if (field == "style") {
        const std::map<std::string, std::set<std::string>> styles{
            {"windows_in", {"popin", "zoom", "slide", "fade", "none"}},
            {"windows_out", {"fade", "slide", "popin", "zoom"}},
            {"workspaces", {"slide", "reveal"}}};
        require(value.is_string() && styles.contains(event) &&
                    styles.at(event).contains(value.get<std::string>()),
                "Unsupported animation style");
    } else if (field == "curve") {
        static const auto curves = [] {
            std::set<std::string> values{
                "linear",    "ease",    "easein", "easeout",       "easeinout", "snappy", "default",
                "overshoot", "quad",    "cubic",  "quart",         "quint",     "expo",   "circ",
                "back",      "elastic", "bounce", "defaultspring", "bouncy",    "smooth", "stiff"};
            for (const auto *direction : {"in", "out", "inout"})
                for (const auto *shape :
                     {"sine", "quad", "cubic", "quart", "quint", "expo", "circ", "back", "elastic", "bounce"})
                    values.insert(std::string("ease") + direction + shape);
            return values;
        }();
        require(value.is_string() && curves.contains(value.get<std::string>()),
                "Unsupported animation curve");
    } else
        throw Error("Unapproved activation setting: " + key);
}
void validate_definition(const Json &definition, const std::string &kind) {
    require(kind == "cursor" || kind == "border" || kind == "window" || kind == "screen" ||
                kind == "animation",
            "Unknown preset kind");
    std::set<std::string> allowed{"kind", "shader", "palette"};
    if (kind == "cursor")
        allowed.insert("radius");
    if (kind == "border")
        allowed.insert({"padding", "speed", "animated", "overlay", "light"});
    fields(definition, allowed);
    require(definition.at("kind") == kind && definition.at("shader").is_string(),
            "Preset kind or shader mismatch");
    for (const auto *key : {"palette", "animated"})
        if (definition.contains(key))
            require(definition.at(key).is_boolean(), "Preset flag must be boolean");
    if (definition.contains("radius"))
        number(definition.at("radius"), 0, 4096, true);
    if (definition.contains("padding"))
        number(definition.at("padding"), 0, 1024, true);
    if (definition.contains("speed"))
        number(definition.at("speed"), 0, 10);
    if (definition.contains("overlay"))
        require(definition.at("overlay").is_string(), "Overlay must be a preset name");
    if (definition.contains("light")) {
        const auto &light = definition.at("light");
        fields(light, {"spread", "intensity", "threshold"});
        if (light.contains("spread"))
            number(light.at("spread"), 1, 256, true);
        if (light.contains("intensity"))
            number(light.at("intensity"), 0, 4);
        if (light.contains("threshold"))
            number(light.at("threshold"), 0, 1);
    }
}
std::string value_toml(const Json &value) {
    if (!value.is_object())
        return value.dump();
    std::string text = "{ ";
    for (const auto &[key, item] : value.items()) {
        if (text.size() > 2)
            text += ", ";
        text += quoted(key) + " = " + value_toml(item);
    }
    return text + " }";
}
Binding Catalogue::binding(const std::string &id, const std::string &slot, const std::string &family) const {
    require(valid_slot(slot), "Unsupported effect slot: " + slot);
    const auto &effect = find(registry_.at("effects"), id);
    require(effect.at("role") == "effect" && std::find(effect.at("uses").begin(), effect.at("uses").end(),
                                                       Json(slot)) != effect.at("uses").end(),
            "Effect does not support the selected use");
    auto recipe = effect.at("activation");
    const auto selector = slot.starts_with("animation.") ? slot + ".effect" : slot;
    if (!family.empty()) {
        const auto &record = find(registry_.at("families"), family);
        require(std::find(record.at("members").begin(), record.at("members").end(), Json(id)) !=
                    record.at("members").end(),
                "Effect is not a family member");
        if (record.at("activation").is_object() &&
            record.at("activation").at("settings").value(selector, "") ==
                effect.at("preset").get<std::string>())
            recipe = record.at("activation");
    }
    require(recipe.is_object() &&
                recipe.at("settings").value(selector, "") == effect.at("preset").get<std::string>(),
            "This effect requires manual configuration");
    Binding result;
    result.id = id;
    result.name = effect.at("preset");
    result.kind = effect.at("kind");
    for (const auto &[key, value] : recipe.at("settings").items()) {
        validate_setting(key, value);
        if (setting_scope(key) == slot || (key == "animation.enabled" && slot.starts_with("animation.")))
            result.settings[key] = value;
    }
    std::set<std::string> visiting, visited, features;
    std::function<void(const std::string &)> visit = [&](const std::string &selected) {
        require(!visiting.contains(selected) && visiting.size() < 64, "Cyclic or excessive dependency graph");
        if (visited.contains(selected))
            return;
        visiting.insert(selected);
        const auto &record = find(registry_.at("effects"), selected);
        for (const auto &dependency : record.at("dependencies"))
            visit(dependency);
        for (const auto &[key, value] : record.at("required_settings").items()) {
            validate_setting(key, value);
            require(!key.starts_with("effects.") && !key.ends_with(".effect"),
                    "Requirements cannot select effects");
            require(!result.required.contains(key) || result.required.at(key) == value,
                    "Conflicting shader requirements");
            result.required[key] = value;
        }
        for (const auto &feature :
             record.value("requirements", Json::object()).value("features", Json::array({"preset-effects"})))
            features.insert(feature.get<std::string>());
        visiting.erase(selected);
        visited.insert(selected);
    };
    visit(id);
    result.features.assign(features.begin(), features.end());
    return result;
}
std::map<std::string, std::string> Catalogue::family_choices(const std::string &id,
                                                             const Json &choices) const {
    const auto &family = find(registry_.at("families"), id);
    std::map<std::string, std::set<std::string>> groups;
    for (const auto &member : family.at("members")) {
        const auto member_id = member.get<std::string>();
        const auto &effect = find(registry_.at("effects"), member_id);
        if (effect.at("role") != "effect")
            continue;
        for (const auto &slot : effect.at("uses"))
            groups[slot].insert(member);
    }
    require(choices.is_object() && choices.size() == groups.size(),
            "Choose an effect or Keep current for every family use");
    std::map<std::string, std::string> requested;
    for (const auto &[slot, members] : groups) {
        require(choices.contains(slot) && choices.at(slot).is_string(), "Missing family choice");
        const auto selected = choices.at(slot).get<std::string>();
        if (selected.empty())
            continue;
        require(members.contains(selected), "Invalid family choice");
        requested[slot] = selected;
    }
    require(!requested.empty(), "Choose at least one family effect");
    return requested;
}
} // namespace shaders
