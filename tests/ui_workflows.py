#!/usr/bin/env python3
"""Run actual panel/service Luau with a small in-memory Noctalia API fixture."""
from pathlib import Path
import subprocess
import sys
import tempfile

plugin = Path(__file__).resolve().parents[1] / 'umbriel-shaders-native'
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
    state = {
      get = function(key) return values[key] end,
      set = function(key, value)
        values[key] = value
        if watchers[key] then watchers[key](value) end
      end,
      watch = function(key, callback) watchers[key] = callback end,
    },
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
  item.callback({ stdout = value, exitCode = 0, timedOut = timedOut or false, stdoutTruncated = false })
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
check(values.request.action == "status", "Opening the panel triggered a catalogue refresh")
check(#values.preview_request.ids == 24, "Visible preview request was not bounded to 24")
check(#nodes(function(item) return item.props.key and string.match(item.props.key, "^cursor/") ~= nil end) == 20,
  "Initial gallery did not paginate at 24 effects")
showMore()
check(#values.preview_request.ids == 6, "Show more did not fetch only newly visible previews")
search("Effect 30")
check(node("cursor/effect-30") ~= nil and node("cursor/glow") == nil, "Search did not filter catalogue records")
clearFilters()
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
browse()
toggleGallery()
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
onClose()
print("PASS panel search, pagination, visible previews, family choices, withdrawn removal and recovery controls")
resetHost()
'''
service_checks = r'''
check(#pending == 1 and pending[1].args[#pending[1].args] == "catalogue", "Service startup performed a network refresh")
complete(1, { protocol_version = 1, ok = true, catalogue = { offset = 0, next_offset = 1, fingerprint = "same", effects = { { id = "a" } }, families = {} } })
check(#pending == 1 and pending[1].args[#pending[1].args] == "catalogue", "Catalogue pagination was not continued")
complete(1, { protocol_version = 1, ok = true, catalogue = { offset = 1, fingerprint = "same", effects = { { id = "b" } }, families = {} } })
check(#values.catalogue.effects == 2 and not values.status.busy, "Catalogue pages were not combined")
noctalia.state.set("preview_request", { ids = { "p1", "p2", "p3", "p4", "p5", "p6" } })
check(#pending == 4, "Preview requests did not respect the four-download concurrency limit")
noctalia.state.set("request", { action = "status" })
check(#pending == 5 and pending[5].args[#pending[5].args] == "status", "Four previews blocked a foreground status request")
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
check(#pending == 1 and pending[1].args[#pending[1].args] == "previews", "Visible previews were not requested")
noctalia.state.set("preview_request", { ids = { "a" } })
check(#pending == 1, "An already requested preview was downloaded repeatedly")
noctalia.state.set("request", { action = "status" })
check(#pending == 2, "Preview downloads blocked a status request")
onConfigChanged()
complete(1, { protocol_version = 1, ok = true, previews = { a = { image = "/stale.png" } } })
check(values.previews.a == nil, "A preview from an old source was published after settings changed")
complete(1, { protocol_version = 1, ok = true, managed = false })
check(#pending == 1 and pending[1].args[#pending[1].args] == "catalogue", "Settings change did not queue a catalogue reload")
complete(1, "invalid JSON")
check(values.status.ok == false and not values.status.busy, "Malformed helper output was accepted")
check(values.catalogue_status.error ~= nil and not values.catalogue_status.loading, "Catalogue failures were not saved independently")
local catalogueError = values.catalogue_status.error
noctalia.state.set("request", { action = "status" })
complete(1, { protocol_version = 1, ok = true, managed = false })
check(values.catalogue_status.error == catalogueError, "Live status overwrote the failed catalogue result")
noctalia.state.set("request", { action = "prepare", effect = "cursor/glow" })
check(#pending == 0, "A selection without a target use reached the helper")
noctalia.state.set("request", { action = "refresh" })
check(#pending == 1 and pending[1].args[#pending[1].args] == "refresh", "Explicit refresh did not reach the helper")
check(values.catalogue_status.loading and not values.catalogue_status.error, "Retry did not clear the previous catalogue error")
complete(1, { protocol_version = 1, ok = true, catalogue = { effects = {}, families = {}, fingerprint = "retry" } })
check(not values.catalogue_status.loading and not values.catalogue_status.error, "Successful retry left the gallery loading or failed")
noctalia.state.set("request", { action = "prepare", effect = "cursor/glow", slot = "effects.cursor", compare = true })
check(table.find(pending[1].args, "--compare-local") ~= nil, "Optional comparison did not reach the native helper")
complete(1, { protocol_version = 1, ok = true })
onExit(0, "reload")
check(#pending == 0, "Script reload restored the desktop unexpectedly")
onExit(0, "disable")
check(#pending == 1 and pending[1].args[1] == "/fixture/data/native-v1/recovery" and pending[1].args[4] == "--wait-lock",
  "Disable did not use the persistent recovery helper and operation lock")
print("PASS service cached startup, catalogue pages, preview deduplication, source-change races and disable recovery")
print(tostring(checks) .. " UI workflow assertions passed")
'''
source = host + '\nlocal catalogueModule = (function()\n' + (plugin / 'lib/catalogue.luau').read_text() + '\nend)()\n'
source += 'function require(_path) return catalogueModule end\n'
source += (plugin / 'panel.luau').read_text() + panel_checks
source += (plugin / 'service.luau').read_text() + service_checks
with tempfile.TemporaryDirectory(prefix='native-ui-') as directory:
    script = Path(directory) / 'workflows.luau'
    script.write_text(source)
    subprocess.run([sys.argv[1], script], check=True, timeout=20)
