local A = require('lib/async.luau')
local U = require('lib/util.luau')
local Shared = require('lib/shared.luau')
local encode, decode = nativeEncode or noctalia.json.encode, nativeDecode or noctalia.json.decode
local realOs, previousState = os, noctalia.state
local clock, start, maximum, largest = 0, 0, 0, 0
local wire, watchers, events = {}, {}, {}
local checks = 0
local function check(value, message) checks += 1; assert(value, message) end
os = table.clone(os); os.clock = function() return clock end
local function charge(size)
  clock += .00002 + size / 4000000
  maximum = math.max(maximum, clock - start)
  assert(clock - start < .025, 'Shared-state callback exceeded 25 ms')
end
noctalia.state = {
  set = function(key, value)
    if type(value) == 'string' then largest = math.max(largest, #value); assert(#value <= 4096) end
    local raw = assert(encode(value)); charge(#raw); wire[key] = raw
    for _, callback in ipairs(watchers[key] or {}) do
      table.insert(events, function() callback(decode(raw)) end)
    end
  end,
  get = function(key) local raw = wire[key]; charge(raw and #raw or 0); return raw and decode(raw) end,
  watch = function(key, callback) watchers[key] = watchers[key] or {}; table.insert(watchers[key], callback) end,
}
local function pump(deliver)
  if deliver ~= false then
    local pending = events; events = {}
    for _, event in ipairs(pending) do start = clock; event() end
  end
  start = clock; A.update()
end
local function document(revision)
  local result = { revision = revision, records = {} }
  for i = 1, 600 do
    result.records[i] = { id = i, text = string.rep('λ😀"\\\n', 12), revision = revision }
  end
  return result
end
local writer, reader = Shared.new(), Shared.new()
local seen = {}
reader.watch('catalogue', function(value)
  for i, record in ipairs(value.records) do
    check(record.id == i and record.revision == value.revision, 'Reader exposed mixed revisions')
  end
  check(#value.records == 600, 'Reader exposed a partial snapshot')
  seen[value.revision] = true
end)
writer.set('catalogue', document(1))
for _ = 1, 10000 do if seen[1] then break end; pump() end
check(seen[1], 'Initial snapshot did not arrive')
-- Supersede serialization and chunk writes; only complete revisions may escape.
writer.set('catalogue', document(2)); pump()
writer.set('catalogue', document(3))
for _ = 1, 10000 do if seen[3] then break end; pump() end
check(seen[3], 'Superseding snapshot did not arrive')
local reopened, reopenedValue = Shared.new(), nil
reopened.watch('catalogue', function(value) reopenedValue = value end)
for _ = 1, 10000 do if reopenedValue then break end; pump() end
check(reopenedValue and reopenedValue.revision == 3, 'New runtime could not reopen the committed snapshot')
-- Delay watcher delivery across both storage slots being reused.
writer.set('catalogue', document(4))
for _ = 1, 500 do pump(false) end
writer.set('catalogue', document(5))
for _ = 1, 500 do pump(false) end
for _ = 1, 10000 do if seen[5] then break end; pump() end
check(seen[5] and reader.get('catalogue').revision == 5, 'Delayed notification restored an obsolete snapshot')
check(largest <= 4096 and maximum < .025, 'State transfer was not bounded')
noctalia.state, os = previousState, realOs
print('PASS shared state budget: ' .. checks .. ' checks (UTF-8, coalescing, atomic revisions, reopening, delayed notifications)')
