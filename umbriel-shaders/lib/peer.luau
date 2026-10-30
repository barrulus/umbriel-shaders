-- SPDX-License-Identifier: MIT
local A = require("./async.luau")
local U = require("./util.luau")
local M = {}
local Peer={}; Peer.__index=Peer
function M.sameSession(a,b)
  -- fileInfo converts filesystem-clock timestamps; ignore sub-millisecond conversion jitter.
  return a.socket==b.socket and a.boot==b.boot and math.floor(a.mtime*1000)==math.floor(b.mtime*1000)
end
function M.new(base)
  assert(noctalia.commandExists("umbriel"),"Umbriel is not on Noctalia's PATH")
  local socket=noctalia.getenv("UMBRIEL_SOCKET")
  if not socket or socket=="" then
    local runtime,display=noctalia.getenv("XDG_RUNTIME_DIR"),noctalia.getenv("WAYLAND_DISPLAY")
    assert(runtime and display and not display:find("/",1,true),"Cannot identify the Umbriel session")
    socket=runtime.."/umbriel-"..display..".sock"
  end
  local info=noctalia.fileInfo(socket)
  assert(info,"Umbriel socket is unavailable")
  local session={socket=socket,mtime=info.mtime,boot=U.read("/proc/sys/kernel/random/boot_id")}
  if not base or base=="" then
    local home=noctalia.getenv("HOME")
    local config=noctalia.getenv("XDG_CONFIG_HOME")
    base=(config and config~="" and config or home.."/.config").."/umbriel/config.toml"
  end
  return setmetatable({base=U.normalize(noctalia.expandPath(base)),session=session},Peer)
end
function Peer:command(args,timeout)
  local info=noctalia.fileInfo(self.session.socket)
  assert(info and math.floor(info.mtime*1000)==math.floor(self.session.mtime*1000),"Umbriel restarted; review again")
  local result=A.await(function(cb) return noctalia.runAsync(args,cb,timeout or 6000) end)
  assert(not result.timedOut and not result.stdoutTruncated,"Umbriel command timed out or exceeded its output limit")
  assert(result.exitCode==0,(result.stderr and result.stderr~="" and result.stderr) or "Umbriel rejected the command")
  return result.stdout or ""
end
function Peer:effects() return U.decode(self:command({"umbriel","effects","--json"})) end
function Peer:validate(path) self:command({"umbriel","config","validate","-c",path},20000) end
function Peer:replace(path) self:command({"umbriel","config-replace",path}) end
function Peer:action(record,operation,selector)
  assert(({set=true,reset=true,toggle=true,cycle=true})[operation],"Invalid effect operation")
  local kind,target=record.kind,record.target
  assert(({cursor=true,window=true,border=true,screen=true})[kind] and (kind=="cursor")== (target==""),"Explicit effect target required")
  local args={"umbriel","msg","effect-"..kind.."-"..operation}
  if selector and selector~="" then table.insert(args,selector) end
  if kind~="cursor" then
    if operation=="set" or operation=="cycle" then table.insert(args,kind=="screen" and "--output" or "--window") end
    table.insert(args,target)
  end
  self:command(args)
end
return M
