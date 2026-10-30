-- SPDX-License-Identifier: MIT
local directory, storageError = noctalia.pluginDataDir()
local root = directory and (directory .. "/luau-v1") or nil
local backend = require("./lib/backend.luau").new(root)
local busy, refreshQueued = false, false
local previewsInFlight = 0
local previewConcurrency = 4
local epoch = 0
local previewQueue, previewDone = {}, {}
local previewResults = {}
local run, pumpPreviews
local function publish(value)
  value.busy = busy
  noctalia.state.set("status", value)
end
local function publishCatalogue(loading, message)
  noctalia.state.set("catalogue_status", { loading = loading, error = message })
end
local function arguments(action, request)
  return { action = action, request = request }
end
local function resetPreviews()
  previewQueue, previewDone, previewResults = {}, {}, {}
  noctalia.state.set("previews", {})
end
pumpPreviews = function()
  if busy or not root then
    return
  end
  -- Publish each completed image immediately. One slow request must not hold
  -- back the other cards, and four slots leave room for foreground operations.
  while previewsInFlight < previewConcurrency and #previewQueue > 0 do
    local id = table.remove(previewQueue, 1)
    local startedEpoch = epoch
    previewsInFlight += 1
    local launched = backend.run(arguments("previews", { ids = { id } }), function(result)
      previewsInFlight -= 1
      if startedEpoch == epoch then
        local value = result
        previewResults[id] = (value.previews or {})[id]
          or { error = value.message or noctalia.tr("service.preview_unavailable") }
        noctalia.state.set("previews", previewResults)
      end
      pumpPreviews()
    end)
    if not launched then
      previewsInFlight -= 1
      table.insert(previewQueue, 1, id)
      return
    end
  end
end
run = function(action, request)
  if busy then
    return
  end
  local loadingCatalogue = action == "catalogue" or action == "refresh"
  local function fail(message)
    if loadingCatalogue then
      publishCatalogue(false, message)
    end
    publish({ ok = false, message = message })
  end
  if not root then
    fail(storageError or noctalia.tr("service.plugin_storage_is_unavailable"))
    return
  end
  if action == "refresh" then
    epoch += 1
    resetPreviews()
  end
  local startedEpoch = epoch
  local previousStatus = noctalia.state.get("status") or {}
  busy = true
  if loadingCatalogue then
    publishCatalogue(true, nil)
  end
  local running = table.clone(previousStatus)
  running.message = noctalia.tr("service.working")
  publish(running)
  local launched = backend.run(arguments(action, request), function(result)
    busy = false
    local value = result
    if startedEpoch ~= epoch then
      value.plan_token = nil
      refreshQueued = true
    end
    if value.catalogue and startedEpoch == epoch then
      if (value.catalogue.offset or 0) == 0 then
        resetPreviews()
      else
        local previous = noctalia.state.get("catalogue") or {}
        if previous.fingerprint ~= value.catalogue.fingerprint then
          refreshQueued = true
        else
          local effects, families = previous.effects or {}, previous.families or {}
          for _, effect in ipairs(value.catalogue.effects or {}) do
            table.insert(effects, effect)
          end
          for _, family in ipairs(value.catalogue.families or {}) do
            table.insert(families, family)
          end
          value.catalogue.effects, value.catalogue.families = effects, families
        end
      end
      if not refreshQueued then
        noctalia.state.set("catalogue", value.catalogue)
      end
    end
    if loadingCatalogue and startedEpoch == epoch then
      local continuing = refreshQueued
        or (value.catalogue and value.catalogue.next_offset ~= nil)
        or false
      publishCatalogue(continuing, value.ok == false and value.message or nil)
    end
    if value.diagnostics then
      noctalia.state.set("diagnostics", value.diagnostics)
      publish(previousStatus)
    else
      publish(value)
    end
    if refreshQueued then
      refreshQueued = false
      run("catalogue")
    elseif value.catalogue and value.catalogue.next_offset then
      run("catalogue", { offset = value.catalogue.next_offset })
    else
      pumpPreviews()
    end
  end)
  if not launched then
    busy = false
    fail(noctalia.tr("service.could_not_start_the_operation"))
  end
end
noctalia.state.watch("request", function(request)
  if type(request) ~= "table" then
    return
  end
  local allowed = {
    catalogue = true,
    refresh = true,
    status = true,
    diagnostics = true,
    prepare = true,
    choose = true,
    ["prepare-family"] = true,
    ["choose-family"] = true,
    remove = true,
    apply = true,
    undo = true,
    restore = true,
    recover = true,
  }
  if not allowed[request.action] then
    return
  end
  if
    (request.action == "prepare" or request.action == "choose")
    and (type(request.effect) ~= "string" or type(request.slot) ~= "string")
  then
    return
  end
  if request.action == "remove" and type(request.slot) ~= "string" then
    return
  end
  if
    (request.action == "prepare-family" or request.action == "choose-family")
    and (type(request.family) ~= "string" or type(request.choices) ~= "table")
  then
    return
  end
  run(request.action, request)
end)
noctalia.state.watch("preview_request", function(request)
  if type(request) ~= "table" or type(request.ids) ~= "table" or #request.ids > 24 then
    return
  end
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
  if busy then
    refreshQueued = true
  else
    run("catalogue")
  end
end
function onIpc(event, payload)
  if event == "refresh" then
    run("refresh")
  elseif event == "status" then
    run("status")
  elseif event == "request" then
    local request = noctalia.json.decode(payload or "")
    if type(request) == "table" then
      noctalia.state.set("request", request)
    end
  end
end
-- Installed selections persist when this service stops. Restore is an explicit action.
function update()
  backend.update()
end
noctalia.setUpdateInterval(1000)
run("catalogue")
