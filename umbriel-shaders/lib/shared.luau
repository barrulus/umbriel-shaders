-- SPDX-License-Identifier: MIT
-- Large values cross runtime boundaries as bounded strings. A small manifest
-- commits an entire snapshot; readers never expose partially written chunks.
local A = require("./async.luau")
local U = require("./util.luau")
local J = require("./json.luau")
local M = {}
function M.new()
  local cache, requested, writing = {}, {}, {}
  local store = {}
  local function key(name)
    return "shaders-v2:" .. name
  end
  local function chunk(name, slot, index)
    return key(name) .. ":" .. slot .. ":" .. index
  end
  local function finish(ok, err)
    assert(ok, err)
  end
  function store.get(name)
    return cache[name]
  end
  function store.set(name, value)
    cache[name] = value
    requested[name] = (requested[name] or 0) + 1
    if writing[name] then
      return
    end
    writing[name] = true
    A.defer(function()
      local committed = noctalia.state.get(key(name))
      local revision = type(committed) == "table" and committed.revision or 0
      while true do
        local request = requested[name]
        local raw = U.json(cache[name])
        assert(#raw <= 4 * U.limit, noctalia.tr("util.document_exceeds_limit"))
        if requested[name] == request then
          local slot, count, first = (revision + 1) % 2, 0, 1
          while first <= #raw and requested[name] == request do
            A.checkpoint()
            local last = J.chunkEnd(raw, first)
            count += 1
            noctalia.state.set(chunk(name, slot, count), raw:sub(first, last))
            first = last + 1
          end
          if requested[name] == request then
            A.checkpoint()
            if requested[name] == request then
              revision += 1
              noctalia.state.set(key(name), { revision = revision, slot = slot, count = count })
              break
            end
          end
        end
      end
      writing[name] = nil
    end, function(ok, err)
      if not ok then
        writing[name] = nil
      end
      finish(ok, err)
    end)
  end
  function store.watch(name, callback)
    local request, reading = 0, false
    local function changed()
      request += 1
      if reading then
        return
      end
      reading = true
      A.defer(function()
        while true do
          local serial = request
          local manifest = noctalia.state.get(key(name))
          if type(manifest) ~= "table" then
            break
          end
          assert(type(manifest.count) == "number" and manifest.count <= 2048)
          local parts, complete = {}, true
          for i = 1, manifest.count do
            A.checkpoint()
            if request ~= serial then
              complete = false
              break
            end
            local part = noctalia.state.get(chunk(name, manifest.slot, i))
            if type(part) ~= "string" or #part > 4096 then
              complete = false
              break
            end
            parts[i] = part
          end
          local current = noctalia.state.get(key(name))
          if
            complete
            and current
            and current.revision == manifest.revision
            and request == serial
          then
            local value = U.decode(table.concat(parts))
            current = noctalia.state.get(key(name))
            if current and current.revision == manifest.revision and request == serial then
              cache[name] = value
              callback(value)
            end
          end
          if serial == request then
            -- A publication can arrive while we're decoding, before its watch
            -- event is delivered. Read the new committed revision immediately.
            if not current or current.revision == manifest.revision then
              break
            end
          end
        end
        reading = false
      end, function(ok, err)
        if not ok then
          reading = false
        end
        finish(ok, err)
      end)
    end
    noctalia.state.watch(key(name), changed)
    changed()
  end
  return store
end
return M
