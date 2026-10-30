-- SPDX-License-Identifier: MIT
local directory, storageError = noctalia.pluginDataDir()
local root = directory and (directory .. "/native-v1") or nil
local pluginDirectory = noctalia.pluginDir()
local bundledHelper = pluginDirectory and (pluginDirectory .. "/bin/umbriel-shaders-native") or nil
local helper = bundledHelper and noctalia.commandExists(bundledHelper) and bundledHelper or "umbriel-shaders-native"
local busy, refreshQueued = false, false
local previewsInFlight = 0
local previewConcurrency = 4
local epoch = 0
local previewQueue, previewDone = {}, {}
local previewResults = {}
local run, pumpPreviews
local catalogueActions = { catalogue = true, refresh = true, previews = true, prepare = true, choose = true,
  ["prepare-family"] = true, ["choose-family"] = true }
local function publish(value)
  value.busy = busy
  noctalia.state.set("status", value)
end
local function publishCatalogue(loading, message)
  noctalia.state.set("catalogue_status", { loading = loading, error = message })
end
local function arguments(action, request)
  local result = { helper, "--state-dir", root }
  local function option(key, value)
    if value ~= nil then table.insert(result, key); table.insert(result, value) end
  end
  local base = noctalia.getConfig("base_config") or ""
  if base ~= "" then option("--base-config", noctalia.expandPath(base)) end
  if catalogueActions[action] then
    local mode = noctalia.getConfig("source_mode") or "online"
    option("--source-mode", mode)
    if mode == "snapshot" then
      option("--catalogue-index", noctalia.expandPath(noctalia.getConfig("catalogue_index") or ""))
      option("--source-root", noctalia.expandPath(noctalia.getConfig("assets_root") or ""))
    elseif mode == "local" then
      option("--source-root", noctalia.expandPath(noctalia.getConfig("source_root") or ""))
    end
  end
  if request then
    if request.compare == true and action == "prepare" then table.insert(result, "--compare-local") end
    if request.offset then option("--offset", tostring(request.offset)) end
    option("--effect", request.effect)
    option("--slot", request.slot)
    option("--plan-token", request.token)
    if action == "prepare-family" or action == "choose-family" then
      option("--family", request.family)
      option("--choices", noctalia.json.encode(request.choices))
    end
    if action == "previews" then option("--effects", noctalia.json.encode(request.ids)) end
  end
  table.insert(result, action)
  return result
end
local function decode(result)
  local value
  if not result.timedOut and not result.stdoutTruncated then value = noctalia.json.decode(result.stdout or "") end
  if type(value) ~= "table" or value.protocol_version ~= 1 then
    return { ok = false, message = "Helper interrupted or returned an invalid response. Refresh status to check recovery." }
  end
  if result.exitCode ~= 0 then value.ok = false end
  return value
end
local function resetPreviews()
  previewQueue, previewDone, previewResults = {}, {}, {}
  noctalia.state.set("previews", {})
end
pumpPreviews = function()
  if busy or not root then return end
  -- Publish each completed image immediately. One slow request must not hold
  -- back the other cards, and four slots leave room for foreground operations.
  while previewsInFlight < previewConcurrency and #previewQueue > 0 do
    local id = table.remove(previewQueue, 1)
    local startedEpoch = epoch
    previewsInFlight += 1
    local launched = noctalia.runAsync(arguments("previews", { ids = { id } }), function(result)
      previewsInFlight -= 1
      if startedEpoch == epoch then
        local value = decode(result)
        previewResults[id] = (value.previews or {})[id] or { error = value.message or "Preview unavailable." }
        noctalia.state.set("previews", previewResults)
      end
      pumpPreviews()
    end, 30000)
    if not launched then
      previewsInFlight -= 1
      table.insert(previewQueue, 1, id)
      return
    end
  end
end
run = function(action, request)
  if busy then return end
  local loadingCatalogue = action == "catalogue" or action == "refresh"
  local function fail(message)
    if loadingCatalogue then publishCatalogue(false, message) end
    publish({ ok = false, message = message })
  end
  if not root then fail(storageError or "Plugin storage is unavailable."); return end
  if not noctalia.commandExists(helper) then
    fail("Install the native helper package before using this plugin."); return
  end
  if action == "refresh" then epoch += 1; resetPreviews() end
  local startedEpoch = epoch
  local previousStatus = noctalia.state.get("status") or {}
  busy = true
  if loadingCatalogue then publishCatalogue(true, nil) end
  local running = table.clone(previousStatus)
  running.message = "Working…"
  publish(running)
  local launched = noctalia.runAsync(arguments(action, request), function(result)
    busy = false
    local value = decode(result)
    if startedEpoch ~= epoch then value.plan_token = nil; refreshQueued = true end
    if value.catalogue and startedEpoch == epoch then
      if (value.catalogue.offset or 0) == 0 then resetPreviews()
      else
        local previous = noctalia.state.get("catalogue") or {}
        if previous.fingerprint ~= value.catalogue.fingerprint then
          refreshQueued = true
        else
          local effects, families = previous.effects or {}, previous.families or {}
          for _, effect in ipairs(value.catalogue.effects or {}) do table.insert(effects, effect) end
          for _, family in ipairs(value.catalogue.families or {}) do table.insert(families, family) end
          value.catalogue.effects, value.catalogue.families = effects, families
        end
      end
      if not refreshQueued then noctalia.state.set("catalogue", value.catalogue) end
    end
    if loadingCatalogue and startedEpoch == epoch then
      local continuing = refreshQueued or (value.catalogue and value.catalogue.next_offset ~= nil) or false
      publishCatalogue(continuing, value.ok == false and value.message or nil)
    end
    if value.diagnostics then
      noctalia.state.set("diagnostics", value.diagnostics)
      publish(previousStatus)
    else publish(value) end
    if refreshQueued then refreshQueued = false; run("catalogue")
    elseif value.catalogue and value.catalogue.next_offset then run("catalogue", { offset = value.catalogue.next_offset })
    else pumpPreviews() end
  end, 60000)
  if not launched then busy = false; fail("Could not launch the native helper.") end
end
noctalia.state.watch("request", function(request)
  if type(request) ~= "table" then return end
  local allowed = { catalogue = true, refresh = true, status = true, diagnostics = true, prepare = true, choose = true,
    ["prepare-family"] = true, ["choose-family"] = true, remove = true, apply = true, undo = true, restore = true, recover = true }
  if not allowed[request.action] then return end
  if (request.action == "prepare" or request.action == "choose") and
      (type(request.effect) ~= "string" or type(request.slot) ~= "string") then return end
  if request.action == "remove" and type(request.slot) ~= "string" then return end
  if (request.action == "prepare-family" or request.action == "choose-family") and
      (type(request.family) ~= "string" or type(request.choices) ~= "table") then return end
  run(request.action, request)
end)
noctalia.state.watch("preview_request", function(request)
  if type(request) ~= "table" or type(request.ids) ~= "table" or #request.ids > 24 then return end
  for _, id in ipairs(request.ids) do
    if type(id) == "string" and not previewDone[id] then
      previewDone[id] = true
      table.insert(previewQueue, id)
    end
  end
  pumpPreviews()
end)
function onConfigChanged()
  epoch += 1
  resetPreviews()
  publishCatalogue(true, nil)
  noctalia.state.set("catalogue", {})
  if busy then refreshQueued = true else run("catalogue") end
end
function onIpc(event, _payload)
  if event == "refresh" then run("refresh") elseif event == "status" then run("status") end
end
function onExit(_signal, reason)
  if root and (reason == "disable" or reason == "uninstall") then
    noctalia.runAsync({ root .. "/recovery", "--state-dir", root, "--wait-lock", "restore" })
  end
end
run("catalogue")
