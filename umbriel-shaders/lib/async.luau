-- SPDX-License-Identifier: MIT
-- All jobs resumed by one host callback share its time slice, including completions.
local M = {}
local queue, active = {}, {}
local started
local slice = 0.003
local function intervalWakeup(pending)
  noctalia.setUpdateInterval(pending and 16 or 1000)
end
local wakeup = intervalWakeup
function M.setWakeup(callback)
  wakeup = callback or intervalWakeup
  wakeup(#queue > 0)
end
local function resume(thread, ...)
  if not active[thread] then
    return
  end
  local outer = started == nil
  if outer then
    started = os.clock()
  end
  local result = table.pack(coroutine.resume(thread, ...))
  if not result[1] or coroutine.status(thread) == "dead" then
    active[thread] = nil
  end
  if outer then
    started = nil
  end
  if not result[1] then
    error(result[2], 0)
  end
end
local function job(fn, done)
  local thread = coroutine.create(function()
    M.checkpoint()
    local ok, result = pcall(fn)
    M.checkpoint()
    done(ok, result)
  end)
  active[thread] = true
  return thread
end
function M.run(fn, done)
  resume(job(fn, done))
end
function M.defer(fn, done)
  table.insert(queue, job(fn, done))
  wakeup(true)
end
function M.await(start)
  local thread = coroutine.running()
  local deadline = noctalia.nowMs() + 30000
  repeat
    M.checkpoint()
    local synchronous, received = true, nil
    local accepted = start(function(...)
      if synchronous then
        received = table.pack(...)
      else
        resume(thread, ...)
      end
    end)
    synchronous = false
    if received then
      return table.unpack(received, 1, received.n)
    end
    if accepted ~= false then
      return coroutine.yield()
    end
    assert(noctalia.nowMs() < deadline, noctalia.tr("async.host_operation_queue_remained_full"))
    M.pause()
  until false
end
function M.pause()
  wakeup(true)
  table.insert(queue, coroutine.running())
  coroutine.yield()
end
function M.checkpoint()
  if active[coroutine.running()] and started and os.clock() - started >= slice then
    M.pause()
  end
end
function M.update()
  local ready = queue
  queue = {}
  started = os.clock()
  local ok, err = pcall(function()
    for index, thread in ipairs(ready) do
      if os.clock() - started >= slice then
        -- Older work stays ahead of jobs that yielded or were launched this tick.
        local pending = {}
        for i = index, #ready do
          table.insert(pending, ready[i])
        end
        for _, waiting in ipairs(queue) do
          table.insert(pending, waiting)
        end
        queue = pending
        break
      end
      resume(thread)
    end
  end)
  started = nil
  wakeup(#queue > 0)
  assert(ok, err)
end
return M
