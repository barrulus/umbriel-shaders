-- SPDX-License-Identifier: MIT
-- Minimal assertions for the plugin's Luau unit tests.
local M = { count = 0 }

function M.eq(actual, expected, label)
  M.count += 1
  if actual ~= expected then
    error(
      string.format(
        "%s\n  expected: %s\n  actual:   %s",
        label,
        tostring(expected),
        tostring(actual)
      ),
      2
    )
  end
end

function M.truthy(value, label)
  M.count += 1
  if not value then
    error(label .. ": expected a truthy value", 2)
  end
end

function M.done(name)
  print(string.format("PASS %s (%d checks)", name, M.count))
end

return M
