if nativeEncode and nativeDecode then
  noctalia.json.encode, noctalia.json.decode = nativeEncode, nativeDecode
end
local A = require("lib/async.luau")
local U = require("lib/util.luau")
local checks = 0
local function check(value, message)
  checks += 1
  assert(value, message)
end
local records = {}
for i = 1, 1000 do
  records[i] = { id = "border/shader-" .. i, description = string.rep("colour ", 20),
    preview = { image = "border/shader-" .. i .. "/preview.png" }, tags = { "glow", "border" } }
end
local raw = noctalia.json.encode({ effects = records, files = records })
local realOs, decode = os, noctalia.json.decode
local clock, callbackStart, maximum, largest = 0, 0, 0, 0
os = table.clone(os)
os.clock = function() return clock end
noctalia.json.decode = function(text)
  -- Model native parse + table conversion as indivisible work. The previous
  -- depth scan yielded, then handed the entire catalogue to this one call.
  largest = math.max(largest, #text)
  clock += #text / 4000000
  maximum = math.max(maximum, clock - callbackStart)
  assert(clock - callbackStart < 0.025, "JSON decode exceeded the 25 ms callback budget")
  return decode(text)
end
local results, finished = {}, 0
for i = 1, 4 do
  callbackStart = clock
  A.run(function() return U.decode(raw) end, function(ok, result)
    assert(ok, result)
    results[i] = result
    finished += 1
  end)
end
check(finished == 0, "Large JSON decode did not yield")
local updates = 0
while finished < 4 and updates < 10000 do
  updates += 1
  callbackStart = clock
  A.update()
end
check(finished == 4, "Concurrent decodes did not complete")
check(maximum < 0.025, "Combined update exceeded the callback budget")
check(largest <= 4096, "Catalogue was passed to the native decoder in an unbounded piece")
for _, result in ipairs(results) do
  check(U.equal(result, { effects = records, files = records }), "Chunking changed decoded catalogue")
end
local long = string.rep('colour λ😀\\\"\n', 12000)
local encode = noctalia.json.encode
noctalia.json.encode = function(value)
  if type(value) == 'string' then
    check(#value <= 4096, 'Long string reached native encoding unbounded')
    clock += #value / 4000000
    assert(clock - callbackStart < .025, 'String encoding exceeded callback budget')
  end
  return encode(value)
end
callbackStart = clock
local roundTrip, stringDone
A.run(function() return U.decode(U.json({ text = long })) end,
  function(ok, value) assert(ok, value); roundTrip = value; stringDone = true end)
while not stringDone do callbackStart = clock; A.update() end
check(roundTrip.text == long, 'Long string chunking changed escapes or UTF-8')
check(not pcall(U.decode, '[' .. string.rep('1', 5000) .. ']'), 'Oversized numeric scalar reached native parsing')
noctalia.json.encode = encode
noctalia.json.decode, os = decode, realOs

-- Force the structural path, including whitespace, escaped delimiters, duplicate
-- keys, null array positions, and false (which must not be treated as an error).
local padding = string.rep(" ", 5000)
local parsed = U.decode('{"a":1,"a":null,"b":false,"array":[null,false,3],"s":"\\\" } ] \\\\ x"' .. padding .. '}')
check(parsed.a == nil and parsed.b == false, "Null/false or duplicate key semantics changed")
check(parsed.array[1] == nil and parsed.array[2] == false and parsed.array[3] == 3, "Null array positions changed")
check(parsed.s == '" } ] \\ x', "Escaped string boundaries changed")
check(U.decode('[' .. padding .. 'null,false,3]')[3] == 3, "Split arrays compressed null positions")
check(next(U.decode('{' .. padding .. '}')) == nil, "Large empty object failed")
check(U.decode('{"nested":' .. padding .. '{"x":2}}').nested.x == 2, "Nested whitespace failed")
for _, bad in ipairs({
  '{"a":1,}', '[1,]', '{"a" 1}', '{a:1}', '[1 2]', '{"a":}',
  '[}', '{]', '{"a":"unterminated}', '{} true', '[', '',
}) do
  check(not pcall(U.decode, padding .. bad), "Invalid JSON accepted: " .. bad)
  check(not pcall(U.decode, bad:sub(1, 1) .. padding .. bad:sub(2)), "Invalid split JSON accepted: " .. bad)
end
check(not pcall(U.decode, string.rep('[', 33) .. '0' .. string.rep(']', 33)), "Excessive nesting accepted")
check(not pcall(U.decode, string.rep(' ', 4 * U.limit + 1)), "Oversized document accepted")

if nativeDecode then
  for _, prefix in ipairs({4090,4091,4092,4093,4094,4095}) do
    local raw = '"' .. string.rep('a', prefix) .. '\\uD83D\\uDE00' .. string.rep('z',5000) .. '"'
    local value = fixture.run(function() return U.decode(raw) end)
    check(value == nativeDecode(raw), 'A split surrogate pair changed decoding')
  end
  for _, bad in ipairs({'\\uD800','\\uDE00','\\uD800x','\\uD800\\u0041','\\q'}) do
    check(not pcall(function() fixture.run(function() return U.decode('"' .. string.rep('a',5000) .. bad .. '"') end) end),
      'Invalid escape accepted in long string')
  end
end
print("PASS JSON decode budget: " .. checks .. " checks; " .. updates .. " yielding updates")
