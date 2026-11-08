local A = require('lib/async.luau')
local U = require('lib/util.luau')
local Source = require('lib/source.luau')
local Registry = require('lib/registry.luau')
local checks = 0
local function check(value, message) checks += 1; assert(value, message) end
for i = 1, 64 do fixture.effect('cursor', 'shader-' .. i) end
local registry = fixture.run(function() return Source.open('/budget', false).registry end)
local members = {}
for _, effect in ipairs(registry.effects) do table.insert(members, effect.id) end
registry.families = {}
for i = 1, 64 do registry.families[i] = { id = 'family-' .. i, name = 'Family ' .. i, members = members } end
local realOs, translate = os, noctalia.tr
local clock, start, maximum = 0, 0, 0
os = table.clone(os); os.clock = function() return clock end
local function charge(seconds)
  clock += seconds
  maximum = math.max(maximum, clock - start)
  assert(clock - start < .025, 'Combined callback exceeded 25 ms')
end
local function tick()
  start = clock
  A.update()
end
local finished, completions = 0, 0
for _ = 1, 5 do
  start = clock
  A.run(function()
    A.pause()
    charge(.006) -- Indivisible work can overshoot a coroutine's 3 ms checkpoint.
    A.checkpoint()
  end, function(ok, err)
    assert(ok, err)
    for _ = 1, 20 do charge(.001); A.checkpoint() end
    completions += 1
    A.run(function()
      for _ = 1, 10 do charge(.001); A.checkpoint() end
    end, function(nestedOk, nestedErr) assert(nestedOk, nestedErr); finished += 1 end)
  end)
end
for _ = 1, 1000 do if finished == 5 then break end; tick() end
check(finished == 5 and completions == 5, 'Queued jobs or yielding completions were lost')
check(maximum < .025, 'Five jobs exceeded a shared update budget')
local done = false
start = clock
A.run(function()
  for i = 1, 200 do
    local value = A.await(function(cb) charge(.0002); cb(i, 'sync'); return true end)
    check(value == i, 'Synchronous await changed its result')
  end
end, function(ok, err) assert(ok, err); done = true end)
while not done do tick() end
noctalia.tr = function(key, args) charge(.00001); return translate(key, args) end
start = clock; done = false
A.run(function() return Registry.validate(registry, true) end,
  function(ok, result) assert(ok, result); done = true end)
while not done do tick() end
check(maximum < .025, 'Maximum-size family validation exceeded the callback budget')
-- Charge traversal checkpoints so copy/equality/key collection must yield too.
local checkpoint = A.checkpoint
A.checkpoint = function() charge(.00001); checkpoint() end
start = clock; done = false
A.run(function()
  local copy = U.copy(registry)
  check(U.equal(copy, registry), 'Yielding copy changed the registry')
  check(#U.keys(copy.files) == #U.keys(registry.files), 'Yielding key traversal lost files')
end, function(ok, result) assert(ok, result); done = true end)
while not done do tick() end
A.checkpoint, noctalia.tr, os = checkpoint, translate, realOs
print('PASS callback budget: ' .. checks .. ' checks (shared slices, completions, nesting, synchronous await, validation, traversal)')
