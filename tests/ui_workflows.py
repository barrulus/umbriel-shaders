#!/usr/bin/env python3
"""Run actual panel/service Luau with a small in-memory Noctalia API fixture."""
from pathlib import Path
import subprocess
import sys
import tempfile
from translations import translation_fixture

plugin = Path(__file__).resolve().parents[1] / 'umbriel-shaders'
host = r'''
local checks = 0
local function check(value, message)
  checks += 1
  assert(value, message)
end
local values, watchers, pending, config, tree
local function resetHost()
  values, watchers, pending, config = {}, {}, {}, { source_mode = "online" }
  noctalia = {
    tr = fixtureTranslate, trp = fixturePlural,
    state = {
      get = function(key) return values[key] end,
      set = function(key, value)
        values[key] = value
        if watchers[key] then watchers[key](value) end
      end,
      watch = function(key, callback) watchers[key] = callback end,
    },
    setUpdateInterval = function() end,
    pluginDataDir = function() return "/fixture/data" end,
    pluginDir = function() return "/fixture/plugin" end,
    getConfig = function(key) return config[key] end,
    expandPath = function(path) return path end,
    commandExists = function(_command) return true end,
    openSettings = function() end,
    copyToClipboard = function() return true end,
    json = {
      encode = function(value) return value end,
      decode = function(value) return type(value) == "table" and value or nil end,
    },
    runAsync = function(args, callback, timeout)
      table.insert(pending, { args = args, callback = callback, timeout = timeout })
      return true
    end,
  }
  ui = setmetatable({}, { __index = function(_table, kind)
    return function(props, children) return { kind = kind, props = props or {}, children = children or {} } end
  end })
  panel = { render = function(value) tree = value end, close = function() end }
end
local function nodes(predicate)
  local result = {}
  local function visit(node)
    if predicate(node) then table.insert(result, node) end
    for _, child in ipairs(node.children or {}) do visit(child) end
  end
  visit(tree)
  return result
end
local function node(key)
  return nodes(function(item) return item.props.key == key end)[1]
end
local function complete(index, value, timedOut)
  local item = table.remove(pending, index)
  item.callback(type(value) == "table" and value or { ok = false, protocol_version = 1, message = "Invalid response" })
end
resetHost()
local effects = {}
local kinds = { "cursor", "animation", "border", "window", "screen" }
for i = 1, 30 do
  local kind = kinds[i] or "cursor"
  local preset = i == 1 and "glow" or "effect-" .. tostring(i)
  local slot = kind == "animation" and "animation.windows_in" or "effects." .. kind
  local selector = kind == "animation" and slot .. ".effect" or slot
  table.insert(effects, { id = kind .. "/" .. preset, preset = preset, name = "Effect " .. tostring(i),
    kind = kind, role = "effect", author = "Test", license = "MIT", description = "Fixture shader",
    tags = { "glow" }, families = { "coordinated" }, uses = { slot }, activation = { settings = { [selector] = preset } } })
end
local family = { id = "coordinated", name = "Coordinated", description = "Fixture family", tags = {}, authors = { "Test" },
  members = { effects[1].id, effects[2].id, effects[3].id, effects[4].id, effects[5].id, effects[6].id },
  activation = { settings = { ["effects.cursor"] = "glow" } } }
values.catalogue = { mode = "online", effects = effects, families = { family } }
values.status = { ok = true, managed = true, selections = { ["effects.cursor"] = "cursor/withdrawn" }, can_undo = true, can_restore = true }
'''
panel_checks = r'''
onOpen()
check(node("slot-toggle-effects.border") ~= nil and node("slot-options-effects.border") == nil, "Opening did not show collapsed effect slots")
browseAll()
check(values.request.action == "status", "Opening the panel triggered a catalogue refresh")
check(#values.preview_request.ids == 24, "Visible preview request was not bounded to 24")
check(#nodes(function(item) return item.props.key and string.match(item.props.key, "^cursor/") ~= nil end) == 20,
  "Initial gallery did not paginate at 24 effects")
translationOverrides["panel.show_more"] = "Voir {visible} / {total}"
translationOverrides["panel.shader_count.other"] = "{count} effets"
onOpen()
check(node("show-more").props.text == "Voir 24 / 30", "Pagination did not use translated substitutions")
check(#nodes(function(item) return item.props.text == "30 effets" end) == 1, "Gallery did not use translated plurals")
translationOverrides = {}
showMore()
check(#values.preview_request.ids == 6, "Show more did not fetch only newly visible previews")
search("Effect 30")
check(node("cursor/effect-30") ~= nil and node("cursor/glow") == nil, "Search did not filter catalogue records")
clearFilters()
node("cursor/glow").props.onClick()
toggleDetails()
noctalia.state.set("status", { ok = true, managed = true, selections = { ["effects.cursor"] = "cursor/withdrawn" }, can_restore = true, plan_token = "review-token", effect_id = "cursor/glow", slot = "effects.cursor", changes = {} })
check(node("apply").props.onClick == "apply", "Reviewed shader was not connected to its Apply token")
browse()
toggleGallery()
node("family-coordinated").props.onClick()
local choice = node("family-choice-effects.cursor")
check(choice ~= nil, "Family choices were not rendered")
choice.props.onChange(1)
reviewFamily()
check(values.request.action == "prepare-family" and values.request.choices["effects.cursor"] == "", "Keep current was not passed to family review")
applyFamily()
check(values.request.action == "choose-family", "Family Apply did not reach the shared transaction request")
activeSelections()
local remove = nodes(function(item) return item.kind == "button" and item.props.text == "Remove" end)[1]
check(remove and remove.props.enabled, "Withdrawn active selection could not be removed")
remove.props.onClick()
check(values.request.action == "remove" and values.request.slot == "effects.cursor", "Remove did not target its explicit slot")
noctalia.state.set("status", { ok = false, pending = true, managed = true, selections = { ["effects.cursor"] = "cursor/withdrawn" } })
remove = nodes(function(item) return item.kind == "button" and item.props.text == "Remove" end)[1]
check(not remove.props.enabled, "Remove remained enabled during recovery")
check(#nodes(function(item) return item.props.text == "Recover" and item.props.visible end) == 1, "Recovery action was not shown")
supportBack()
browseAll()
noctalia.state.set("catalogue", {})
noctalia.state.set("status", { ok = true, busy = false })
noctalia.state.set("catalogue_status", { loading = true })
check(node("catalogue-message").props.text == "Loading shaders…", "A pending first download was not shown")
noctalia.state.set("catalogue_status", { loading = false, error = "Download timed out" })
check(string.find(node("catalogue-message").props.text, "Download timed out", 1, true) ~= nil,
  "Failed first catalogue load still showed a loading placeholder")
check(node("retry-catalogue").props.visible and node("retry-catalogue").props.enabled, "Catalogue failure did not expose Retry")
noctalia.state.set("status", { ok = true, managed = false })
onOpen()
check(string.find(node("catalogue-message").props.text, "Download timed out", 1, true) ~= nil,
  "Opening the panel or refreshing live status erased the catalogue error")
toggleGallery()
check(string.find(node("catalogue-message").props.text, "Download timed out", 1, true) ~= nil,
  "The family gallery hid a catalogue failure")
noctalia.state.set("catalogue", { effects = {}, families = {} })
noctalia.state.set("catalogue_status", { loading = false })
check(node("catalogue-message").props.text == "No families in this catalogue.", "A valid empty catalogue looked like it was still loading")
for _, effect in ipairs(effects) do effect.local_preview = { image = "/local/" .. effect.id .. ".png" } end
values.preview_request = nil
noctalia.state.set("catalogue", { mode = "local", effects = effects, families = { family } })
check(values.preview_request == nil, "Family gallery queued already-available local previews")
node("family-coordinated").props.onClick()
check(values.preview_request == nil, "Opening a local family queued preview work")
browse()
toggleGallery()
check(values.preview_request == nil, "Local shader gallery queued preview work")
check(node("refresh").props.tooltip == "Refresh catalogue and update active shaders", "Local Refresh did not explain active updates")
check(node("preview-cursor/glow:") ~= nil, "Local preview missing")
noctalia.state.set("catalogue", { mode = "local", fingerprint = "edited", effects = effects, families = { family } })
check(node("preview-cursor/glow:edited") ~= nil and node("preview-cursor/glow:") == nil, "Refreshed local preview reused its widget")
effectSlots()
noctalia.state.set("status", { ok = true, managed = true, can_undo = true,
  selections = { ["effects.border"] = "border/effect-3", ["application:effects.border:saved.app"] = "@off" },
  windows = {
    { id = "42", app_id = "org.example.App", slots = { border = { name = "external", source = "runtime", suppressed = true } } },
    { id = "43", app_id = "second.app", slots = { border = { name = "", source = "rule", suppressed = false } } },
  } })
node("slot-toggle-effects.border").props.onClick()
check(node("slot-description-effects.border") ~= nil, "Expanded slot has no description")
node("slot-documentation-effects.border").props.onClick()
check(pending[#pending].args[1] == "xdg-open" and pending[#pending].args[2] == "https://docs.noctalia.dev/umbriel/effects/#settings",
  "Persistent slot documentation opened the wrong destination")
check(node("slot-options-effects.border") ~= nil and node("slot-options-effects.cursor") == nil, "Opening a slot did not isolate its options")
check(node("rule-add-effects.border") == nil, "Nested window rules were expanded by default")
node("rules-toggle-effects.border").props.onClick()
check(node("rule-effects.border:saved.app") ~= nil, "Saved assignment disappeared when its application was closed")
node("rule-add-effects.border").props.onClick()
check(#node("rule-application-effects.border").props.options == 2, "Add did not list open applications")
node("rule-confirm-effects.border").props.onClick()
check(node("rule-effects.border:org.example.App") ~= nil, "Add did not create an assignment row")
check(string.find(node("effective-effects.border:org.example.App").props.text, "Runtime override", 1, true) ~= nil
  and string.find(node("effective-effects.border:org.example.App").props.text, "Suppressed", 1, true) ~= nil,
  "Nested rule hid effective source or suppression")
node("slot-off-effects.border:org.example.App").props.onClick()
check(values.request.effect == "@off" and values.request.slot == "application:effects.border:org.example.App", "Nested No effect lost its application target")
node("rule-add-effects.border").props.onClick()
check(#node("rule-application-effects.border").props.options == 1, "Add offered a duplicate assignment")
node("rule-confirm-effects.border").props.onClick()
check(node("rule-effects.border:second.app") ~= nil and node("rule-effects.border:org.example.App") ~= nil, "Adding a second application replaced the first")
node("rule-remove-effects.border:second.app").props.onClick()
check(node("rule-effects.border:second.app") == nil, "Removing a draft left an empty assignment behind")
node("slot-choose-effects.border:org.example.App").props.onClick()
check(node("border/effect-3") ~= nil and node("cursor/glow") == nil, "Slot browser offered incompatible shaders")
node("border/effect-3").props.onClick()
chooseShader()
check(values.request.slot == "application:effects.border:org.example.App", "Shader selection lost its nested application target")
local savedStatus = table.clone(values.status)
savedStatus.selections = table.clone(savedStatus.selections)
savedStatus.selections["application:effects.border:org.example.App"] = "border/effect-3"
noctalia.state.set("status", savedStatus)
check(node("rule-effects.border:org.example.App") ~= nil, "Saved rule disappeared after Apply")
node("rule-remove-effects.border:org.example.App").props.onClick()
check(values.request.action == "remove" and values.request.slot == "application:effects.border:org.example.App", "Remove did not target the saved rule")
local removedStatus = table.clone(savedStatus)
removedStatus.selections = table.clone(savedStatus.selections)
removedStatus.selections["application:effects.border:org.example.App"] = nil
noctalia.state.set("status", removedStatus)
check(node("rule-effects.border:org.example.App") == nil, "Removing a saved rule left a stale draft behind")
effectSlots()
node("refresh-windows").props.onClick()
check(values.request.action == "status", "Refresh lost its action after editing an application")
node("slot-toggle-animation.windows_in").props.onClick()
check(node("slot-options-effects.border") == nil and node("rule-add-effects.border") == nil, "Opening another slot failed to close the previous slot and its rules")
noctalia.state.set("status", { ok = true, managed = true,
  selections = { ["animation.windows_in"] = "animation/effect-2" },
  settings = { ["animation.windows_in.duration_ms"] = 450 } })
local durationKey = "duration-animation.windows_in-450"
check(node(durationKey).kind == "input" and node(durationKey).props.value == "450", "Timing input ignored saved duration")
node("curve-animation.windows_in").props.onChange(0)
node("save-duration-animation.windows_in").props.onClick()
check(values.request.duration_ms == 450 and values.request.curve == "linear", "Curve-only edit lost saved duration")
for _, text in ipairs({ "", "abc", "0", "-1", "10001", "250.5", "nan", "inf", "1e3" }) do
  node(durationKey).props.onChange(text)
  check(node(durationKey).props.value == text, "Invalid draft was discarded while typing")
  check(not node("save-duration-animation.windows_in").props.enabled, "Invalid duration enabled Apply: " .. text)
  local previous = values.request
  node("save-duration-animation.windows_in").props.onClick()
  check(values.request == previous, "Invalid duration submitted a timing request")
end
for _, text in ipairs({ "1", "10000", "250", " 300 " }) do
  node(durationKey).props.onChange(text)
  check(node("save-duration-animation.windows_in").props.enabled, "Valid duration disabled Apply: " .. text)
  node("save-duration-animation.windows_in").props.onClick()
  check(values.request.duration_ms == tonumber(text), "Typed duration was not saved exactly")
end
node(durationKey).props.onChange("680")
node("save-duration-animation.windows_in").props.onClick()
check(values.request.action == "timing" and values.request.duration_ms == 680 and values.request.curve == "easeoutcubic" and values.request.slot == "animation.windows_in", "Duration change did not reach its animation slot")
noctalia.state.set("status", { ok = true, managed = true,
  selections = { ["animation.windows_in"] = "animation/effect-2" },
  settings = { ["animation.windows_in.duration_ms"] = 300 } })
check(node("duration-animation.windows_in-300").props.value == "300" and node(durationKey) == nil,
  "Saved duration change did not reseed the input")
node("slot-toggle-animation.windows_in").props.onClick()
check(node("slot-options-animation.windows_in") == nil, "Expanded slot did not collapse on a second click")
for _,event in ipairs({"overview","scratchpad","border","dim_unfocused","layers"}) do
  local slot = "animation." .. event
  node("slot-toggle-" .. slot).props.onClick()
  check(node("slot-description-" .. slot) ~= nil and node("slot-documentation-" .. slot) ~= nil,
    "Animation slot lacks its description or documentation link")
  node("slot-documentation-" .. slot).props.onClick()
  check(pending[#pending].args[2] == "https://docs.noctalia.dev/umbriel/animation/#targets", "Animation target documentation opened the wrong page")
  check(node("slot-default-" .. slot) ~= nil and node("slot-example-" .. slot) ~= nil, "Animation slot lacks Default or example")
  node("slot-default-" .. slot).props.onClick()
  check(values.request.effect == "@default" and values.request.slot == slot, "Default targeted the wrong slot")
  check(not node("slot-example-" .. slot).props.enabled, "Missing community example remained selectable")
  local exampleIds = { overview="overview-glow", scratchpad="scratchpad-fade", border="focus-ring-pulse", dim_unfocused="focus-desaturation", layers="panel-glide" }
  local canonical = "animation/" .. exampleIds[event]
  local updated = table.clone(values.catalogue)
  updated.effects = table.clone(values.catalogue.effects)
  table.insert(updated.effects, { id=canonical, name="Community example", tags={}, uses={slot} })
  noctalia.state.set("catalogue", updated)
  check(node("slot-example-" .. slot).props.enabled, "Available community example was disabled")
  node("slot-example-" .. slot).props.onClick()
  check(values.request.effect == canonical and values.request.slot == slot,
    "Example targeted the wrong slot")
end
node("slot-toggle-effects.border").props.onClick()
noctalia.state.set("status", { ok = true, pending = true })
check(not node("slot-off-effects.border").props.enabled, "Slot assignment remained enabled during recovery")
onClose()
print("PASS panel search, pagination, visible previews, family choices, withdrawn removal and recovery controls")
resetHost()
'''
service_checks = r'''
check(#pending == 1 and pending[1].args.action == "catalogue", "Service startup performed a network refresh")
complete(1, { protocol_version = 1, ok = true, catalogue = { offset = 0, next_offset = 1, fingerprint = "same", effects = { { id = "a" } }, families = {} } })
check(#pending == 1 and pending[1].args.action == "catalogue", "Catalogue pagination was not continued")
complete(1, { protocol_version = 1, ok = true, catalogue = { offset = 1, fingerprint = "same", effects = { { id = "b" } }, families = {} } })
check(#values.catalogue.effects == 2 and not values.status.busy, "Catalogue pages were not combined")
noctalia.state.set("preview_request", { ids = { "p1", "p2", "p3", "p4", "p5", "p6" } })
check(#pending == 4, "Preview requests did not respect the four-download concurrency limit")
noctalia.state.set("request", { action = "status" })
check(#pending == 5 and pending[5].args.action == "status", "Four previews blocked a foreground status request")
complete(5, { protocol_version = 1, ok = true, managed = false })
complete(2, { protocol_version = 1, ok = true, previews = { p2 = { image = "/p2.png" } } })
check(values.previews.p2.image == "/p2.png" and values.previews.p1 == nil and #pending == 4,
  "A completed preview waited for the slow first image or did not refill its slot")
for _, id in ipairs({ "p3", "p4", "p5", "p6" }) do
  complete(2, { protocol_version = 1, ok = true, previews = { [id] = { image = "/" .. id .. ".png" } } })
end
check(values.previews.p6.image == "/p6.png" and #pending == 1,
  "A slow first preview blocked the rest of the visible gallery")
complete(1, { protocol_version = 1, ok = true, previews = { p1 = { image = "/p1.png" } } })
noctalia.state.set("preview_request", { ids = { "a", "a" } })
check(#pending == 1 and pending[1].args.action == "previews", "Visible previews were not requested")
noctalia.state.set("preview_request", { ids = { "a" } })
check(#pending == 1, "An already requested preview was downloaded repeatedly")
noctalia.state.set("request", { action = "status" })
check(#pending == 2, "Preview downloads blocked a status request")
onConfigChanged()
complete(1, { protocol_version = 1, ok = true, previews = { a = { image = "/stale.png" } } })
check(values.previews.a == nil, "A preview from an old source was published after settings changed")
complete(1, { protocol_version = 1, ok = true, managed = false })
check(#pending == 1 and pending[1].args.action == "catalogue", "Settings change did not queue a catalogue reload")
complete(1, "invalid JSON")
check(values.status.ok == false and not values.status.busy, "Malformed backend output was accepted")
check(values.catalogue_status.error ~= nil and not values.catalogue_status.loading, "Catalogue failures were not saved independently")
local catalogueError = values.catalogue_status.error
noctalia.state.set("request", { action = "status" })
complete(1, { protocol_version = 1, ok = true, managed = false })
check(values.catalogue_status.error == catalogueError, "Live status overwrote the failed catalogue result")
noctalia.state.set("request", { action = "prepare", effect = "cursor/glow" })
check(#pending == 0, "A selection without a target use reached the backend")
noctalia.state.set("request", { action = "refresh" })
check(#pending == 1 and pending[1].args.action == "refresh", "Explicit refresh did not reach the backend")
check(values.catalogue_status.loading and not values.catalogue_status.error, "Retry did not clear the previous catalogue error")
complete(1, { protocol_version = 1, ok = true, catalogue = { effects = {}, families = {}, fingerprint = "retry" } })
check(not values.catalogue_status.loading and not values.catalogue_status.error, "Successful retry left the gallery loading or failed")
noctalia.state.set("request", { action = "prepare", effect = "cursor/glow", slot = "effects.cursor", compare = true })
check(pending[1].args.request.compare == true, "Optional comparison did not reach the backend")
complete(1, { protocol_version = 1, ok = true })
check(onExit == nil, "Stopping the plugin must not launch restoration")
print("PASS service cached startup, catalogue pages, progressive previews, source-change races, persistent selections")
print(tostring(checks) .. " UI workflow assertions passed")
'''
source = translation_fixture() + host + '\nlocal catalogueModule = (function()\n' + (plugin / 'lib/catalogue.luau').read_text() + '\nend)()\n'
source += 'local allocationModule = (function()\n' + (plugin / 'lib/allocation.luau').read_text() + '\nend)()\n'
source += '''function require(path)
 if path == "./lib/catalogue.luau" then return catalogueModule end
 if path == "./lib/allocation.luau" then return allocationModule end
 return { new = function() return { update = function() end, run = noctalia.runAsync } end }
end\n'''
source += (plugin / 'panel.luau').read_text() + panel_checks
source += (plugin / 'service.luau').read_text() + service_checks
with tempfile.TemporaryDirectory(prefix='shaders-ui-') as directory:
    script = Path(directory) / 'workflows.luau'
    script.write_text(source)
    subprocess.run([sys.argv[1], script], check=True, timeout=20)
