local A = require("lib/async.luau")
local U = require("lib/util.luau")
local checks = 0
local function check(value, message)
  checks += 1
  assert(value, message)
end

-- Charge each host call deterministic CPU time. Ordinary fixture tests have no
-- host deadline; this catches an uninterrupted traversal even on a fast machine.
local realOs, encode, translate = os, noctalia.json.encode, noctalia.tr
local clock, callbackStart, maximum = 0, 0, 0
os = table.clone(os)
os.clock = function()
  return clock
end
local function charge()
  clock += 0.0001
  maximum = math.max(maximum, clock - callbackStart)
  assert(clock - callbackStart < 0.025, "Serialization exceeded the 25 ms callback budget")
end
noctalia.json.encode = function(value)
  charge()
  return encode(value)
end
noctalia.tr = function(key, args)
  charge()
  return translate(key, args)
end

local records, reverse = {}, {}
for i = 1, 1000 do
  local record =
    { name = "Shader " .. i, description = string.rep("colour ", 20), tags = { "glow", "border" } }
  records["effect-" .. i] = record
  reverse[1001 - i] = { name = record.name, tags = record.tags, description = record.description }
end
local reordered = {}
for i = 1, 1000 do
  reordered["effect-" .. (1001 - i)] = reverse[i]
end

local results, finished = {}, 0
for i, document in ipairs({ records, reordered, { records }, { reordered } }) do
  callbackStart = clock
  A.run(function()
    return U.json(document)
  end, function(ok, value)
    assert(ok, value)
    results[i] = value
    finished += 1
  end)
end
check(finished == 0, "Large serialization did not yield")
local updates = 0
while finished < 4 and updates < 10000 do
  updates += 1
  callbackStart = clock
  A.update()
end
check(finished == 4, "Concurrent serializations did not complete")
check(maximum < 0.025, "Combined update exceeded the host callback budget")
check(results[1] == results[2], "Yielding changed canonical object ordering")
check(
  results[3] == "[" .. results[1] .. "]" and results[3] == results[4],
  "Yielding changed array serialization"
)
noctalia.json.encode, noctalia.tr, os = encode, translate, realOs
print(
  "PASS JSON budget: "
    .. checks
    .. " checks; "
    .. updates
    .. " yielding updates for four concurrent catalogues"
)
