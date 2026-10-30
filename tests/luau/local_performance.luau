local F = fixture
local U = require("lib/util.luau")
local Source = require("lib/source.luau")
local Registry = require("lib/registry.luau")
F.effect("cursor", "first")
F.effect("cursor", "second")
F.write("/assets/cursor/first/preview.png", string.rep("image", 1000))
F.write("/assets/cursor/first/preview.gif", string.rep("animation", 10000))

local reads, scans, jitter = 0, 0, 0
local read, fileInfo = U.read, noctalia.fileInfo
U.read = function(path, limit)
  if path:sub(1, 8) == "/assets/" then
    reads += 1
    assert(not path:match("preview%."), "Browsing read local preview media")
  end
  return read(path, limit)
end
noctalia.fileInfo = function(path)
  local info = fileInfo(path)
  if info and path:sub(1, 8) == "/assets/" then
    scans += 1
    info.mtime = 1.0009999 + jitter
  end
  return info
end

local cold = F.run(function()
  return Source.open("/local-cache", false)
end)
F.check(#cold.registry.effects == 2 and reads > 0, "Cold metadata indexing failed")
F.check(cold.registry.files["cursor/first/preview.gif"].sha256 == false, "Local media was hashed")
F.check(
  U.hex(cold.registry.files["cursor/first/shader.glsl"].sha256, 64),
  "Installed shader lost its checksum"
)
local page = F.run(function()
  return cold:browse()
end)
F.check(
  page.effects[1].local_preview.image == "/assets/cursor/first/preview.png",
  "Local preview path was not exposed directly"
)
local fingerprint = page.fingerprint
reads = 0
jitter = 0.0000002
local warm = F.run(function()
  return Source.open("/local-cache", false)
end)
F.check(reads == 0, "Timestamp jitter caused a metadata rebuild")
F.check(F.run(function()
  return warm:browse().fingerprint
end) == fingerprint, "Unchanged catalogue changed pagination identity")
local previews = F.run(function()
  return warm:previews({ "cursor/first" })
end)
F.check(
  reads == 0 and previews["cursor/first"].image == page.effects[1].local_preview.image,
  "Local preview request read media"
)

local published = U.copy(cold.registry)
published.draft = false
published.source.revision = string.rep("a", 40)
F.check(
  not pcall(Registry.validate, published, false),
  "Published media without hashes was accepted"
)
local invalid = U.copy(cold.registry)
invalid.files["cursor/first/shader.glsl"].sha256 = false
F.check(not pcall(Registry.validate, invalid, true), "Local shader without a checksum was accepted")

-- Same-size edits still cannot bypass checksum verification of selected assets.
local shader = F.files["/assets/cursor/first/shader.glsl"]
F.write("/assets/cursor/first/shader.glsl", shader:gsub("vec4", "vec3"))
F.check(not pcall(function()
  F.run(function()
    warm:bytes("cursor/first/shader.glsl")
  end)
end), "Changed local shader bypassed verification")
reads = 0
local refreshed = F.run(function()
  return Source.open("/local-cache", true)
end)
F.check(reads > 0 and refreshed.fingerprint ~= fingerprint, "Refresh did not force reindexing")
F.check(F.run(function()
  return refreshed:bytes("cursor/first/shader.glsl")
end) == F.files["/assets/cursor/first/shader.glsl"], "Refreshed shader was not verified")

F.write(
  "/assets/cursor/first/metadata.toml",
  F.files["/assets/cursor/first/metadata.toml"] .. "\n# author edit\n"
)
reads = 0
local edited = F.run(function()
  return Source.open("/local-cache", false)
end)
F.check(
  reads > 0 and edited.fingerprint ~= refreshed.fingerprint,
  "Authoring edit did not invalidate cache"
)
F.files["/assets/cursor/second/metadata.toml"] = nil
local removed = F.run(function()
  return Source.open("/local-cache", false)
end)
F.check(#removed.registry.effects == 1, "Removed effect was retained in cache")

F.call("catalogue")
reads, scans = 0, 0
F.call("catalogue")
F.check(
  reads == 0 and scans == 0,
  "Browsing reopened the local source instead of reusing its snapshot"
)
F.call("prepare", { effect = "cursor/first", slot = "effects.cursor" })
F.check(scans > 0, "Preparing a selection skipped local-file revalidation")
print(
  "PASS local performance: "
    .. F.checks
    .. " checks (media-free indexing, cache jitter, refresh, navigation, asset verification)"
)
