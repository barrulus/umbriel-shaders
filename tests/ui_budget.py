#!/usr/bin/env python3
"""Exercise real service/panel/scheduler/transport with budgeted host boundaries."""
from pathlib import Path
import subprocess
import sys
import tempfile
from run import bundle

root = Path(__file__).resolve().parents[1]
entry = r'''
local A = require('lib/async.luau')
local U = require('lib/util.luau')
local Shared = require('lib/shared.luau')
local realRequire = require
local backendCalls = {}
require = function(name)
  if name == 'lib/backend.luau' then
    return { new = function() return {
      update = A.update,
      run = function(args, callback) table.insert(backendCalls, {args=args,callback=callback}); return true end,
    } end }
  end
  return realRequire(name)
end
local nativeEncodeImpl, nativeDecodeImpl = nativeEncode or noctalia.json.encode, nativeDecode or noctalia.json.decode
local clock, start, maximum, interval = 0, 0, 0, 1000
local tree, renders, maximumNodes, expectedOpen = nil, 0, 0, false
local needsFrames = false
local checks = 0
local function check(value, message) checks += 1; assert(value, message) end
os = table.clone(os); os.clock = function() return clock end
local function charge(cost)
  clock += cost
  maximum = math.max(maximum, clock - start)
  assert(clock - start < .025, 'UI/shared-state callback exceeded 25 ms')
end
noctalia.setUpdateInterval = function(value) interval = value end
noctalia.pluginDataDir = function() return '/state' end
noctalia.pluginDir = function() return '/plugin' end
noctalia.openSettings = function() end
noctalia.copyToClipboard = function() return true end
noctalia.json.encode = function(value)
  charge(.000005 + (type(value)=='string' and #value/4000000 or 0))
  return nativeEncodeImpl(value)
end
noctalia.json.decode = function(raw) charge(.000005 + #raw/4000000); return nativeDecodeImpl(raw) end
local wire, watchers, events = {}, {}, {}
noctalia.state = {
  get = function(key)
    local raw=wire[key]; charge(.000005 + (raw and #raw/4000000 or 0))
    return raw and nativeDecodeImpl(raw)
  end,
  set = function(key, value)
    local raw = assert(nativeEncodeImpl(value))
    check(#raw < 16000, 'An oversized shared-state payload bypassed transport')
    charge(.000005 + #raw/4000000); wire[key]=raw
    for _, callback in ipairs(watchers[key] or {}) do
      table.insert(events,function() callback(nativeDecodeImpl(raw)) end)
    end
  end,
  watch = function(key, callback) watchers[key]=watchers[key] or {};table.insert(watchers[key],callback) end,
}
ui = setmetatable({}, { __index = function(_, kind)
  return function(props, children) charge(.00001);return {kind=kind,props=props or {},children=children or {}} end
end })
panel = { setNeedsFrameTick = function(value) needsFrames=value;interval=value and 16 or 1000 end, close = function() end, render = function(value)
  check(expectedOpen, 'Closed panel published a deferred tree')
  local count=0
  local function visit(node)
    count+=1
    if node.props.options then check(#node.props.options<=66, 'Unbounded select options') end
    for _,child in ipairs(node.children) do visit(child) end
  end
  visit(value)
  maximumNodes=math.max(maximumNodes,count)
  charge(count*.00002) -- Native render is deliberately indivisible.
  tree=value;renders+=1
end }
local catalogue={mode='online',effects={},families={},offset=0,fingerprint='budget'}
for i=1,512 do
  local id='cursor/effect-'..i
  catalogue.effects[i]={id=id,preset='effect-'..i,name='Effect '..i,kind='cursor',role='effect',
    description='Shader',author='Test',license='MIT',tags={'glow','tag-'..i},families={},
    uses={'effects.cursor'},activation={settings={['effects.cursor']='effect-'..i}},preview={image=id..'/preview.png'}}
end
for i=1,64 do
  local members={};for j=1,64 do members[j]=catalogue.effects[j].id end
  catalogue.families[i]={id='family-'..i,name='Family '..i,description='Family',members=members,tags={},authors={'Test'}}
end
local status={ok=true,managed=true,selections={},windows={},settings={}}
local Allocation=require('lib/allocation.luau')
for i=1,256 do status.selections[Allocation.key('effects.border','app-'..i)]='@off' end
for i=1,1024 do status.windows[i]={id=tostring(i),app_id='app-'..i,slots={}} end
local function pump()
  local waiting=events;events={}
  for _,event in ipairs(waiting) do start=clock;event() end
  local calls=backendCalls;backendCalls={}
  for _,call in ipairs(calls) do
    local result
    if call.args.action=='catalogue' then result=table.clone(status);result.catalogue=catalogue
    elseif call.args.action=='previews' then
      result={ok=true,previews={}}
      for _,id in ipairs(call.args.request.ids) do result.previews[id]={image='/preview/'..id..'.png'} end
    else result=table.clone(status) end
    table.insert(events,function() call.callback(result) end)
  end
  start=clock
  if expectedOpen then
    if needsFrames then onFrameTick() end
  else A.update() end
end
local function settle()
  for _=1,30000 do
    pump()
    if interval==1000 and #events==0 and #backendCalls==0 then return end
  end
  error('UI work did not settle')
end
local function event(fn) start=clock;fn();settle() end
local function node(key)
  local function visit(value)
    if value.props.key==key then return value end
    for _,child in ipairs(value.children) do local found=visit(child);if found then return found end end
  end
  return tree and visit(tree)
end
require('service.luau')
require('panel.luau')
expectedOpen=true
event(function() onOpen();check(needsFrames,'Panel did not request frame ticks for deferred work') end)
check(node('slot-toggle-effects.border')~=nil,'Fresh panel did not reach slots')
event(browseAll)
check(node('cursor/effect-1') and not node('cursor/effect-25'),'Gallery did not bound the first page')
for i=1,21 do event(showMore) end
check(node('cursor/effect-512') and not node('cursor/effect-1'),'Next pages accumulated old cards or lost the last effect')
event(previousPage)
check(node('cursor/effect-481')~=nil,'Previous page lost earlier effects')
-- Cancel a partially constructed page with a new search while its coroutine yields.
start=clock;clearFilters();pump();start=clock;search('Effect 512');settle()
check(node('cursor/effect-512') and not node('cursor/effect-1'),'Stale render overwrote a newer search')
event(toggleGallery)
check(node('family-family-1')~=nil,'Family gallery did not render')
event(showMore)
check(node('family-family-25') and not node('family-family-1'),'Family pagination accumulated cards')
event(function() node('family-family-25').props.onClick() end)
check(node('family-choice-effects.cursor') ~= nil, 'Family options were lost')
event(effectSlots)
event(function() node('slot-toggle-effects.border').props.onClick() end)
event(function() node('rules-toggle-effects.border').props.onClick() end)
check(node('next-rules-effects.border') ~= nil, 'Application rules were not paginated')
event(function() node('next-rules-effects.border').props.onClick() end)
event(function() node('rule-add-effects.border').props.onClick() end)
check(node('next-applications-effects.border') ~= nil, 'Live application options were not paginated')
event(function() node('next-applications-effects.border').props.onClick() end)
'''
# Remaining budget cases use the stable public panel entry points.
entry += r'''
event(activeSelections)
check(node('next-active')~=nil,'Large saved selection list was not paginated')
event(function() node('next-active').props.onClick() end)
local publisher=Shared.new()
start=clock
publisher.set('diagnostics',{sections={{title='Large report',text=string.rep('line\n',5000)}},report_text='report'})
settle()
event(troubleshoot)
check(node('next-diagnostics-1')~=nil,'Diagnostic lines were not paginated')
-- An older preview snapshot must not be attached to a new catalogue when the
-- independent channels are delivered in a different order.
start=clock
local replacement=table.clone(catalogue);replacement.fingerprint='replacement'
publisher.set('catalogue',replacement)
publisher.set('previews',{__fingerprint='budget',['cursor/effect-1']={image='/stale.png'}})
settle()
event(browseAll)
check(node('preview-cursor/effect-1:replacement')==nil,'A stale preview crossed catalogue revisions')
event(toggleGallery)
check(node('family-family-1')~=nil,'Cold family gallery did not render')
local prior=renders
start=clock;browseAll();pump();start=clock;expectedOpen=false;onClose();settle()
check(renders==prior,'Closing failed to cancel a queued render')
check(not needsFrames,'Closed panel kept requesting animation frames')
expectedOpen=true
event(function() onOpen();check(needsFrames,'Reopening did not wake panel work') end)
check(not needsFrames,'Idle panel kept requesting animation frames')
check(maximum<.025 and maximumNodes<1000,'Rendered work exceeded its bounded callback')
print('PASS real UI budget: '..checks..' checks; '..maximumNodes..' maximum nodes; '..(maximum*1000)..' ms maximum modeled callback')
'''
with tempfile.TemporaryDirectory(prefix='shaders-ui-budget-') as directory:
    script = Path(directory) / 'budget.luau'
    script.write_text(bundle((root / 'tests/fixtures/host.luau').read_text() + '\n' + entry))
    subprocess.run([sys.argv[1], str(script)], check=True, timeout=120)
