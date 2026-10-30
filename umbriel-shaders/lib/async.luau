-- SPDX-License-Identifier: MIT
-- Coroutines keep transactions sequential while every host operation remains asynchronous.
local M = {}
local queue = {}
local active = {}
local function resume(thread, ...)
  local job = active[thread]
  if not job then
    return
  end
  job.started = os.clock()
  local result = table.pack(coroutine.resume(thread, ...))
  if not result[1] or coroutine.status(thread) == "dead" then
    active[thread] = nil
    job.done(result[1], result[2])
  end
end
function M.run(fn, done)
  local thread = coroutine.create(fn)
  active[thread] = { done = done, started = os.clock() }
  resume(thread)
end
function M.await(start)
  local thread = coroutine.running()
  local deadline = noctalia.nowMs() + 30000
  repeat
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
  noctalia.setUpdateInterval(16)
  table.insert(queue, coroutine.running())
  coroutine.yield()
end
function M.checkpoint()
  local job = active[coroutine.running()]
  if job and os.clock() - job.started > 0.003 then
    M.pause()
  end
end
function M.update()
  local ready = queue
  queue = {}
  for _, thread in ipairs(ready) do
    resume(thread)
  end
  if #queue == 0 then
    noctalia.setUpdateInterval(1000)
  end
end
return M
