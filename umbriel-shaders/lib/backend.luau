-- SPDX-License-Identifier: MIT
local A = require("./async.luau")
local U = require("./util.luau")
local S = require("./selection.luau")
local R = require("./runtime.luau")
local Peer = require("./peer.luau")
local Controller = require("./controller.luau")
local Source = require("./source.luau")
local M = {}
local function diagnostic(root, peer, liveError)
  local sections, issues = {}, {}
  local function section(title, text)
    table.insert(sections, { title = title, text = text:sub(1, 24000) })
  end
  local state
  local ok, err = pcall(function()
    if U.exists(root .. "/state.json") then
      state = U.load(root .. "/state.json")
    end
  end)
  if not ok then
    table.insert(issues, tostring(err))
  end
  local managed = false
  local live = liveError or "Umbriel is unavailable."
  if peer then
    ok, err = pcall(function()
      local report = peer:effects()
      managed = state
          and Peer.sameSession(state.session, peer.session)
          and state.current ~= nil
          and U.equal(R.markers(report), { U.marker .. state.current.token })
        or false
      local lines = { "Live selections (window IDs and app IDs omitted):" }
      local count = 0
      for _, record in pairs(R.slots(report)) do
        count += 1
        if count > 100 then
          table.insert(lines, "[Target list truncated]")
          break
        end
        local v = record.value
        table.insert(
          lines,
          record.kind
            .. ": "
            .. v.name
            .. " · "
            .. v.source
            .. (v.pool ~= "" and " · pool=" .. v.pool or "")
            .. (v.suppressed and " · suppressed" or "")
        )
      end
      table.insert(lines, "\nCompilation states:")
      for _, preset in ipairs(report.presets) do
        if not preset.name:match("^umbriel%-.*generation%-") then
          table.insert(lines, preset.name .. ": " .. preset.state)
        end
      end
      table.insert(
        lines,
        "\nAnimation settings are saved intent; the effects query does not expose them."
      )
      live = table.concat(lines, "\n")
    end)
    if not ok then
      live = tostring(err)
      table.insert(issues, live)
    end
  end
  section(
    "Overview",
    "Umbriel Shaders Luau diagnostic report\nData: "
      .. root
      .. "\nManaged selection: "
      .. tostring(managed)
      .. "\nIncludes local paths and shader names. Original configuration contents and environment values are excluded."
  )
  section("Original configuration", state and state.base or "No saved original configuration.")
  section(
    "Saved selections",
    state and state.current and U.json(state.current.bindings) or "No saved selections."
  )
  if state and state.current then
    ok, err = pcall(function()
      return U.read(state.current.config, 256 * 1024)
    end)
    section("Managed configuration", tostring(err))
  end
  section("Live state", live)
  ok, err = pcall(function()
    return U.exists(root .. "/operation.json") and U.json(U.load(root .. "/operation.json"))
      or "No recorded operation."
  end)
  section("Last operation", tostring(err))
  local text = {}
  for _, s in ipairs(sections) do
    table.insert(text, s.title .. "\n" .. s.text)
  end
  return {
    generated = tostring(noctalia.nowMs()),
    managed = managed,
    pending = U.exists(root .. "/pending.json"),
    issues = issues,
    sections = sections,
    report_text = table.concat(text, "\n\n"),
  }
end
function M.new(root)
  local cached, cacheKey
  local function open(refresh, recheck)
    local key = U.json({
      noctalia.getConfig("source_mode"),
      noctalia.getConfig("source_root"),
      noctalia.getConfig("catalogue_index"),
      noctalia.getConfig("assets_root"),
    })
    if cached and cacheKey == key and not refresh and not recheck then
      return cached
    end
    cached = Source.open(root, refresh)
    cacheKey = key
    return cached
  end
  local function previewsSource()
    local key = U.json({
      noctalia.getConfig("source_mode"),
      noctalia.getConfig("source_root"),
      noctalia.getConfig("catalogue_index"),
      noctalia.getConfig("assets_root"),
    })
    if cached and cacheKey == key then
      return cached
    end
    return open(false)
  end
  return {
    update = A.update,
    run = function(command, done)
      A.run(function()
        local action, request = command.action, command.request or {}
        local peer, controller, operation
        local function connect()
          local base = noctalia.getConfig("base_config") or ""
          peer = Peer.new(base)
          controller = Controller.new(root, peer, base ~= "")
          return controller
        end
        local function record(outcome, message)
          if operation then
            operation.outcome = outcome
            operation.message = message
            operation.finished = noctalia.nowMs()
            pcall(U.save, root .. "/operation.json", operation)
          end
        end
        local ok, result = pcall(function()
          if action == "previews" then
            return { previews = previewsSource():previews(request.ids) }
          end
          if action == "catalogue" or action == "refresh" then
            local catalogue = open(action == "refresh")
            if action == "refresh" then
              pcall(function()
                catalogue:collectCache()
              end)
            end
            local value = { catalogue = catalogue:browse(request.offset) }
            local live, status = pcall(function()
              return connect():status()
            end)
            if live then
              if action == "refresh" and catalogue.mode == "local" then
                operation = { action = action, started = noctalia.nowMs(), outcome = "running" }
                record("running", "")
                status = controller:refreshLocal(catalogue)
                record("passed", status.message)
              end
              for k, v in pairs(status) do
                value[k] = v
              end
            else
              value.live_error = tostring(status)
            end
            return value
          end
          if action == "diagnostics" then
            local live, err = pcall(connect)
            local report = diagnostic(root, live and peer or nil, not live and tostring(err) or nil)
            U.atomic(root .. "/diagnostics.txt", report.report_text)
            return { diagnostics = report }
          end
          connect()
          if action == "status" then
            return controller:status()
          end
          operation = { action = action, started = noctalia.nowMs(), outcome = "running" }
          record("running", "")
          local value
          if
            action == "prepare"
            or action == "choose"
            or action == "prepare-family"
            or action == "choose-family"
            or action == "remove"
          then
            local catalogue
            if action == "remove" then
              catalogue = setmetatable(
                { registry = { effects = {}, families = {}, feature_definitions = {} } },
                Source.Source
              )
            else
              -- Recheck authoring files before preparing a selection. Browsing
              -- and previews reuse this snapshot until Refresh or settings change.
              catalogue = open(false, true)
            end
            local requested, family
            if action == "prepare-family" or action == "choose-family" then
              family = request.family
              requested = S.familyChoices(catalogue.registry, family, request.choices)
            else
              requested = {
                [assert(request.slot, noctalia.tr("backend.choose_an_effect_destination"))] = action
                      == "remove"
                    and ""
                  or assert(request.effect, noctalia.tr("backend.choose_an_effect")),
              }
            end
            value = controller:prepare(catalogue, requested, family, request.compare)
            if action == "choose" or action == "choose-family" or action == "remove" then
              value = controller:apply(value.plan_token)
            end
          elseif action == "apply" then
            value = controller:apply(request.token)
          elseif action == "undo" then
            value = controller:undo()
          elseif action == "restore" then
            value = controller:restore()
          elseif action == "recover" then
            value = controller:recover()
          else
            error(noctalia.tr("backend.unsupported_action"))
          end
          record("passed", value.message)
          return value
        end)
        if not ok then
          local message = tostring(result)
          record("failed", message)
          local statusOk, status = pcall(function()
            return controller and controller:status() or {}
          end)
          result = statusOk and status or {}
          result.message = message
          result.pending = U.exists(root .. "/pending.json")
        end
        result.ok = ok
        result.protocol_version = 1
        return result
      end, function(ok, value)
        done(ok and value or {
          ok = false,
          protocol_version = 1,
          message = tostring(value),
          pending = U.exists(root .. "/pending.json"),
        })
      end)
      return true
    end,
  }
end
return M
