local F = fixture
local U = require("lib/util.luau")
local A = require("lib/async.luau")
for i = 1, 64 do
  F.effect("cursor", "unused-" .. i)
end
local choices = {}
for _, kind in ipairs({ "cursor", "border", "window", "screen", "animation" }) do
  F.effect(kind, "chosen-" .. kind)
  choices[kind == "animation" and "animation.windows_in" or "effects." .. kind] = kind
    .. "/chosen-"
    .. kind
end
F.write(
  "/assets/families.toml",
  [[
[families.coordinated]
name="Coordinated"
members=["cursor/chosen-cursor","border/chosen-border","window/chosen-window","screen/chosen-screen","animation/chosen-animation"]
[families.coordinated.defaults]
"effects.cursor"="cursor/chosen-cursor"
"effects.border"="border/chosen-border"
"effects.window"="window/chosen-window"
"effects.screen"="screen/chosen-screen"
"animation.windows_in"="animation/chosen-animation"
]]
)
F.call("catalogue")

-- Measure host round trips, independent of the runner's CPU speed. Budgeted CPU
-- and combined callbacks are covered separately in callback_budget.luau.
local realOs = os
os = table.clone(os)
os.clock = function()
  return 0
end
local nativeRead = noctalia.readFileAsync
local inFlight, peak, cacheReads, rejected = 0, 0, 0, 0
local capacity = 4
noctalia.readFileAsync = function(path, callback)
  if inFlight >= capacity then
    rejected += 1
    return false
  end
  if path:find("/catalogue-cache/", 1, true) then
    cacheReads += 1
  end
  inFlight += 1
  peak = math.max(peak, inFlight)
  return nativeRead(path, function(...)
    inFlight -= 1
    callback(...)
  end)
end
local function choose(action, request, ceiling)
  local start, command = F.time, #F.commands
  F.call(action, request)
  local elapsed = F.time - start
  local validations = 0
  for i = command + 1, #F.commands do
    if F.commands[i][2] == "config" then
      validations += 1
    end
  end
  F.check(validations == 1, "Direct selection validated the same config twice")
  F.check(elapsed <= ceiling, action .. " used too many serial I/O rounds: " .. elapsed)
  F.check(cacheReads == 0, "Activation decoded the unchanged catalogue again")
  F.check(inFlight == 0 and #F.events == 0, "Selection left background file work running")
  return elapsed
end
local single = choose("choose", { effect = "cursor/chosen-cursor", slot = "effects.cursor" }, 352)
local family = choose("choose-family", { family = "coordinated", choices = choices }, 624)
local retained = choose("choose", { effect = "cursor/unused-1", slot = "effects.cursor" }, 752)
F.check(peak == 4, "Independent file reads were not batched")

-- An explicit review still validates, and late generation edits still invalidate Apply.
local plan = F.call("prepare", { effect = "cursor/unused-2", slot = "effects.cursor" })
local config = "/state/generations/" .. plan.plan_token .. "/config.toml"
F.write(config, F.files[config] .. "\n# edited after review\n")
local active = F.active
F.call("apply", { token = plan.plan_token }, false)
F.check(F.active == active, "Batched verification accepted a changed generation")

-- A rejected host submission is retried; completion order must not reorder results.
capacity = 2
local mapped = F.run(function()
  return A.map({ 1, 2, 3, 4, 5, 6 }, function(i)
    U.read("/base.toml")
    return i * 2
  end)
end)
F.check(rejected > 0 and mapped[6] == 12 and mapped[1] == 2, "Batch lost work on queue saturation")

-- On error, drain launched reads before allowing rollback/another operation.
capacity = 4
local writes = 0
local ok = pcall(function()
  F.run(function()
    A.map({ 1, 2, 3, 4, 5, 6 }, function(i)
      U.read("/base.toml")
      if i == 2 then
        error("failed batch")
      end
      U.read("/base.toml")
      writes += 1
    end)
  end)
end)
F.check(not ok and writes > 0 and inFlight == 0, "Failed batch returned before its workers drained")
local completed = writes
F.pump()
F.check(writes == completed and #F.events == 0, "Failed batch continued after returning")
F.check(F.run(function()
  return #A.map({}, function()
    error("empty batch ran")
  end)
end) == 0, "Empty batch did not complete")
F.check(not pcall(function()
  F.run(function()
    A.map({ 1 }, function()
      error(nil)
    end)
  end)
end), "Batch swallowed a nil error")
os = realOs
print(
  "PASS activation performance: "
    .. F.checks
    .. " checks; modeled I/O ms: single="
    .. single
    .. ", family="
    .. family
    .. ", retained="
    .. retained
)
