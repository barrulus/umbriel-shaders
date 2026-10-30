local A=require("lib/async.luau")
local sha=require("lib/sha256.luau")
local toml=require("lib/vendor/tinytoml.luau")
local checks=0
local function check(value,message) checks+=1; assert(value,message) end
check(sha("")=="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","empty SHA-256")
check(sha("abc")=="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad","abc SHA-256")
local finished=false
A.run(function() return sha(string.rep("a",1000000)) end,function(ok,result)
 check(ok and result=="cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0","million-byte SHA-256")
 finished=true
end)
while not finished do A.update() end
local value=toml.parse('[include]\nfiles = ["base.toml", "other.toml"]\n[effects.preset."name.with.dots"]\nkind="border"\nshader="a.glsl"\nlight={spread=12,intensity=0.5}\n[[rule]]\napp_id="test"\n',{load_from_string=true})
check(value.effects.preset['name.with.dots'].light.intensity==.5,"TOML nested/quoted/inline table")
check(value.include.files[2]=="other.toml" and value.rule[1].app_id=="test","TOML arrays and arrays of tables")
local ok=pcall(function() toml.parse('a=1\na=2\n',{load_from_string=true}) end)
check(not ok,"TOML duplicate key accepted")
print("PASS primitives: "..checks.." checks")
