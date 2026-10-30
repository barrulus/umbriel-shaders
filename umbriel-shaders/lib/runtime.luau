-- SPDX-License-Identifier: MIT
local U = require("./util.luau")
local M = {}
function M.selection(v)
  return {
    name = v.name or "",
    pool = v.pool or "",
    source = v.source or "default",
    suppressed = v.suppressed or false,
  }
end
function M.key(kind, target)
  return U.json({ kind, target })
end
function M.slots(report)
  local out, count = {}, 0
  local function add(kind, target, v)
    assert(
      type(target) == "string" and #target <= 512 and not target:find("%z"),
      noctalia.tr("runtime.invalid_runtime_target")
    )
    local key = M.key(kind, target)
    assert(not out[key], noctalia.tr("runtime.duplicate_runtime_target"))
    out[key] = { kind = kind, target = target, value = M.selection(v) }
    count += 1
  end
  add("cursor", "", report.cursor)
  for _, owner in ipairs(report.owners or {}) do
    local target = owner.type == "window" and owner.id or owner.name
    if target then
      for kind, v in pairs(owner.slots or {}) do
        if
          owner.type == "window" and (kind == "window" or kind == "border")
          or owner.type == "output" and kind == "screen"
        then
          add(kind, target, v)
        end
      end
    end
  end
  assert(count <= 2048, noctalia.tr("runtime.too_many_live_effect_targets"))
  return out
end
function M.markers(report)
  local out = {}
  for _, preset in ipairs(report.presets) do
    if
      preset.name:match("^umbriel%-shaders%-generation%-")
      or preset.name:match("^umbriel%-native%-generation%-")
    then
      table.insert(out, preset.name)
    end
  end
  table.sort(out)
  return out
end
function M.stamp(report)
  local runtime = M.slots(report)
  for key, r in pairs(runtime) do
    if r.kind ~= "cursor" and r.value.source ~= "runtime" and not r.value.suppressed then
      runtime[key] = nil
    end
  end
  local presets = {}
  for _, p in ipairs(report.presets) do
    presets[p.name] = p.kind
  end
  return { runtime = runtime, presets = presets }
end
function M.prune(records, live)
  for key in pairs(records) do
    if not live[key] then
      records[key] = nil
    end
  end
end
function M.restore(peer, desired, beforeAction)
  local report = peer:effects()
  local live = M.slots(report)
  local function action(record, operation, selector)
    if beforeAction then
      beforeAction()
    end
    peer:action(record, operation, selector)
  end
  for _, id in ipairs(U.keys(desired)) do
    local record = desired[id]
    assert(
      id == M.key(record.kind, record.target),
      noctalia.tr("runtime.invalid_saved_runtime_target")
    )
    if live[id] then
      local ok, err = pcall(function()
        local actual, value = live[id].value, record.value
        if value.source == "runtime" then
          if not U.equal(actual, value) then
            action(record, "set", value.pool ~= "" and value.pool or value.name)
            actual =
              { name = value.name, pool = value.pool, source = "runtime", suppressed = false }
            if value.pool ~= "" then
              local count = 0
              for _, pool in ipairs(report.pools or {}) do
                if pool.name == value.pool then
                  count = #pool.members
                end
              end
              assert(
                count > 0 and count <= 256,
                noctalia.tr("runtime.previous_effect_pool_is_unavailable")
              )
              for _ = 1, count do
                live = M.slots(peer:effects())
                if not live[id] or live[id].value.name == value.name then
                  break
                end
                action(record, "cycle", value.pool)
              end
              if not live[id] then
                return
              end
              actual = live[id].value
            end
          end
        elseif actual.source == "runtime" then
          action(record, "reset")
          actual = { source = "default", suppressed = false }
        end
        if actual.suppressed ~= value.suppressed then
          action(record, "toggle")
        end
      end)
      if not ok then
        live = M.slots(peer:effects())
        if live[id] then
          error(err)
        end
      end
    end
  end
  live = M.slots(peer:effects())
  for id, record in pairs(desired) do
    if live[id] then
      local a, b = live[id].value, record.value
      assert(
        b.source == "runtime" and U.equal(a, b)
          or b.source ~= "runtime" and a.source ~= "runtime" and a.suppressed == b.suppressed,
        noctalia.tr("runtime.runtime_restoration_could_not_be_verified")
      )
    end
  end
end
return M
