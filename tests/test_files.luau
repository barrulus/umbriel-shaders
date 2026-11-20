-- SPDX-License-Identifier: MIT
local check = require("./check")
local Files = require("../lib/files")

check.eq(Files.slug("My Cool Shader!"), "my-cool-shader", "slug")
check.eq(Files.slug("  ---  "), "shader", "empty slug falls back")

local existing = { ["/s/r1/LICENSES/A.txt"] = true }
local jobs = Files.jobsFor(
  {
    { revision = "r1", files = { "LICENSES/A.txt", "border/glow/effect.toml" } },
    { revision = "r1", files = { "border/glow/effect.toml", "window/o/effect.toml" } },
    { files = {}, include = { "/s/imports/x/effect.toml" } },
  },
  "/s",
  function(path)
    return existing[path] == true
  end
)
check.eq(#jobs, 2, "existing and duplicate files are skipped")
check.eq(jobs[1].dest, "/s/r1/border/glow/effect.toml", "destination keeps the repository layout")
check.eq(jobs[1].url, Files.raw .. "r1/border/glow/effect.toml", "commit-pinned URL")
check.eq(jobs[2].dest, "/s/r1/window/o/effect.toml", "second file")
check.done("files")
