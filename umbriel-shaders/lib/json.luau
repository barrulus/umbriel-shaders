-- SPDX-License-Identifier: MIT
local A = require("./async.luau")
local M = {}
local chunkSize = 4096

-- Keep every native string operation bounded without splitting a UTF-8 sequence.
function M.chunkEnd(raw, first, size)
  local last = math.min(#raw, first + (size or chunkSize) - 1)
  while last < #raw do
    local byte = raw:byte(last + 1)
    if byte < 128 or byte >= 192 then
      break
    end
    last -= 1
    if last < first then
      error(noctalia.tr("util.invalid_json_document"))
    end
  end
  return last
end
function M.encodeString(raw)
  local parts, first = {}, 1
  while first <= #raw do
    A.checkpoint()
    local last = M.chunkEnd(raw, first)
    local encoded = assert(noctalia.json.encode(raw:sub(first, last)))
    table.insert(parts, encoded:sub(2, -2))
    first = last + 1
  end
  return '"' .. table.concat(parts) .. '"'
end

function M.decode(raw)
  local function invalid()
    error(noctalia.tr("util.invalid_json_document"))
  end
  -- Record complete value boundaries while checking depth. The host decoder
  -- cannot yield: only small subtrees or bounded scalar pieces go to it.
  local ends, stack = {}, {}
  local quoted, escaped, start = false, false, 0
  for i = 1, #raw do
    local c = raw:sub(i, i)
    if quoted then
      if escaped then
        escaped = false
      elseif c == "\\" then
        escaped = true
      elseif c == '"' then
        quoted = false
        ends[start] = i
      end
    elseif c == '"' then
      quoted, start = true, i
    elseif c == "{" or c == "[" then
      table.insert(stack, i)
      if #stack > 32 then
        error(noctalia.tr("util.document_nesting_exceeds_limit"))
      end
    elseif c == "}" or c == "]" then
      local opening = table.remove(stack)
      if not opening or raw:sub(opening, opening) ~= (c == "}" and "{" or "[") then
        invalid()
      end
      ends[opening] = i
    end
    if i % 1024 == 0 then
      A.checkpoint()
    end
  end
  if quoted or #stack > 0 then
    invalid()
  end

  local position = 1
  local function space()
    while raw:sub(position, position):match("[ \t\r\n]") do
      position += 1
      if position % 1024 == 0 then
        A.checkpoint()
      end
    end
  end
  local value
  value = function()
    A.checkpoint()
    space()
    local first = position
    local c, last = raw:sub(first, first), ends[first]
    if (c == "{" or c == "[") and last - first + 1 > chunkSize then
      position += 1
      local result, index = {}, 1
      space()
      while position < last do
        local key
        if c == "{" then
          if raw:sub(position, position) ~= '"' then
            invalid()
          end
          key = value()
          space()
          if raw:sub(position, position) ~= ":" then
            invalid()
          end
          position += 1
        else
          key, index = index, index + 1
        end
        result[key] = value()
        space()
        if position == last then
          break
        end
        if raw:sub(position, position) ~= "," then
          invalid()
        end
        position += 1
        space()
        if position >= last then
          invalid()
        end
      end
      if position ~= last then
        invalid()
      end
      position += 1
      return result
    end
    if not last then
      while position <= #raw and not raw:sub(position, position):match("[ \t\r\n,%]%}]") do
        position += 1
        if position % 1024 == 0 then
          A.checkpoint()
        end
      end
      last = position - 1
    end
    position = last + 1
    if c == '"' and last - first + 1 > chunkSize then
      local parts, cursor = {}, first + 1
      while cursor < last do
        A.checkpoint()
        local begin = cursor
        while cursor < last do
          local byte, width = raw:byte(cursor), 1
          if byte == 92 then
            width = 2
            if raw:sub(cursor + 1, cursor + 1) == "u" then
              width = 6
              local code = tonumber(raw:sub(cursor + 2, cursor + 5), 16)
              -- A surrogate pair must reach the native validator together.
              if code and code >= 0xD800 and code <= 0xDBFF then
                width = 12
              end
            end
          elseif byte >= 240 then
            width = 4
          elseif byte >= 224 then
            width = 3
          elseif byte >= 192 then
            width = 2
          end
          if cursor + width - begin > chunkSize - 2 then
            break
          end
          if cursor + width > last then
            invalid()
          end
          cursor += width
        end
        local decoded = noctalia.json.decode('"' .. raw:sub(begin, cursor - 1) .. '"')
        if type(decoded) ~= "string" then
          invalid()
        end
        table.insert(parts, decoded)
      end
      return table.concat(parts)
    end
    -- No plugin field needs a multi-kilobyte numeric literal. Reject it before
    -- entering the native parser, rather than spending a callback on conversion.
    if last - first + 1 > chunkSize then
      invalid()
    end
    local token = raw:sub(first, last)
    local decoded = noctalia.json.decode(token)
    if decoded == nil and token ~= "null" then
      invalid()
    end
    return decoded
  end
  local result = value()
  space()
  if position <= #raw then
    invalid()
  end
  return result
end
return M
