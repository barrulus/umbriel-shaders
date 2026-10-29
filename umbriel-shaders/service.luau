-- SPDX-License-Identifier: MIT
-- Operations belong to the service, so closing the panel does not cancel Apply.
local busy = false
local lastBase = nil
local configEpoch = 0
local dataDir, dataError = noctalia.pluginDataDir()
local helper = (noctalia.pluginDir() or "") .. "/helper/umbriel_shaders.py"
local recoveryHelper = dataDir and (dataDir .. "/recovery.py") or nil

local function publish(value)
  -- Keep the discovered path visible during operations and transport errors.
  -- All other fields, including review tokens, come only from this response.
  if value.base == nil then value.base = lastBase end
  lastBase = value.base
  value.busy = busy
  noctalia.state.set("status", value)
end

local function arguments(action, token, recovery, choice)
  local args = { "python3", recovery and recoveryHelper or helper, "--state-dir", dataDir }
  local base = noctalia.getConfig("base_config")
  if base ~= nil and base ~= "" then
    table.insert(args, "--base-config")
    table.insert(args, noctalia.expandPath(base))
  end
  if action == "prepare" or action == "choose" or action == "catalogue" or action == "choose-family" or action == "diagnostics" then
    table.insert(args, "--source-root")
    table.insert(args, noctalia.expandPath(noctalia.getConfig("source_root") or ""))
  end
  if (action == "prepare" or action == "choose") and choice then
    table.insert(args, "--effect")
    table.insert(args, choice.effect)
    table.insert(args, "--slot")
    table.insert(args, choice.slot)
  end
  if action == "choose-family" and choice then
    table.insert(args, "--family")
    table.insert(args, choice.family)
    table.insert(args, "--choices")
    table.insert(args, noctalia.json.encode(choice.choices))
  end
  if action == "apply-unverified" then
    action = "apply"
  end
  if token ~= nil then
    table.insert(args, "--plan-token")
    table.insert(args, token)
  end
  table.insert(args, action)
  return args
end

local function run(action, token, choice)
  if busy then return end
  if not dataDir then
    publish({ ok = false, message = dataError or "Persistent plugin storage is unavailable." })
    return
  end
  if not noctalia.commandExists("python3") then
    publish({ ok = false, message = "Python 3.11 or newer is required." })
    return
  end
  if not recoveryHelper then
    publish({ ok = false, message = "A persistent recovery helper is required before managing shaders." })
    return
  end
  local startedEpoch = configEpoch
  local previousStatus = noctalia.state.get("status") or {}
  busy = true
  publish({ message = noctalia.tr("operation.running") })
  local launched = noctalia.runAsync(arguments(action, token, false, choice), function(result)
    busy = false
    if configEpoch ~= startedEpoch then
      publish({ ok = false, message = "Settings changed during the operation. Refresh and review again." })
      return
    end
    local value = noctalia.json.decode(result.stdout or "")
    if type(value) ~= "table" or result.timedOut or result.stdoutTruncated then
      publish({ ok = false, message = result.stderr or "Operation interrupted; refresh to check recovery state." })
      return
    end
    if result.exitCode ~= 0 then value.ok = false end
    if value.catalogue then noctalia.state.set("catalogue", value.catalogue) end
    if value.diagnostics then
      noctalia.state.set("diagnostics", value.diagnostics)
      publish(previousStatus)
    else
      publish(value)
    end
  end)
  if not launched then
    busy = false
    publish({ ok = false, message = "Could not start the shader helper." })
  end
end

noctalia.state.watch("request", function(request)
  if type(request) ~= "table" then return end
  local allowed = { status = true, catalogue = true, diagnostics = true, prepare = true, choose = true, ["choose-family"] = true, apply = true, ["apply-unverified"] = true, undo = true, restore = true, recover = true }
  if (request.action == "prepare" or request.action == "choose") and (type(request.effect) ~= "string" or type(request.slot) ~= "string") then return end
  if request.action == "choose-family" and (type(request.family) ~= "string" or type(request.choices) ~= "table") then return end
  if allowed[request.action] then run(request.action, request.token, request) end
end)

function onConfigChanged()
  -- A changed base/source invalidates the panel's previous review.
  configEpoch += 1
  lastBase = nil
  noctalia.state.set("catalogue", {})
  if not busy then run("catalogue", nil) end
end

function onIpc(event, _payload)
  -- IPC is read-only here; changing effects starts from the panel Apply action.
  if event == "refresh" then run("catalogue", nil) end
end

function onExit(_signal, reason)
  if (reason == "disable" or reason == "uninstall") and recoveryHelper then
    -- The persistent helper survives removal of pluginDir. It serializes with
    -- any operation still running and restores only a wrapper it owns.
    noctalia.runAsync(arguments("restore", nil, true))
  end
end

-- Only trusted helper code is copied at startup, never shader content.
if dataDir then
  local source, err = noctalia.readFile(helper)
  if source then
    local saved, saveError = noctalia.writeFile(recoveryHelper .. ".next", source)
    if saved then
      saved, saveError = noctalia.renameFile(recoveryHelper .. ".next", recoveryHelper)
    end
    if not saved then
      recoveryHelper = nil
      publish({ ok = false, message = saveError or "Could not preserve the recovery helper." })
    else
      run("catalogue", nil)
    end
  else
    recoveryHelper = nil
    publish({ ok = false, message = err or "Shader helper is missing." })
  end
else
  publish({ ok = false, message = dataError or "Persistent plugin storage is unavailable." })
end
