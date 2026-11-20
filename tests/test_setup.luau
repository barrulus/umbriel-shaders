-- SPDX-License-Identifier: MIT
local check = require("./check")
local Config = require("../lib/config")

local LINE = 'files = ["noctalia-shaders.toml"]'
check.eq(Config.includeState(nil), "manual", "missing config file")
check.eq(Config.includeState("[include.optional]\n" .. LINE .. "\n"), "present", "already present")
check.eq(Config.includeState("[general]\n"), "insert", "can insert")
check.eq(Config.includeState("[include]\noptional = { files = [] }\n"), "manual", "inline table")

check.eq(
  Config.addInclude("[general]\nx = 1\n"),
  "[general]\nx = 1\n\n[include.optional]\n" .. LINE .. "\n",
  "append a new table"
)
check.eq(
  Config.addInclude("[general]\nx = 1"),
  "[general]\nx = 1\n\n[include.optional]\n" .. LINE .. "\n",
  "append when the file lacks a trailing newline"
)
check.eq(
  Config.addInclude('[include.optional]\nfiles = [\n    "scratch.toml",\n]\n'),
  '[include.optional]\nfiles = ["noctalia-shaders.toml", \n    "scratch.toml",\n]\n',
  "insert into a multi-line array"
)
check.eq(
  Config.addInclude("[include.optional] # extras\nfiles = []\n[general]\n"),
  '[include.optional] # extras\nfiles = ["noctalia-shaders.toml", ]\n[general]\n',
  "insert into an empty array"
)
check.eq(
  Config.addInclude("[include.optional]\nnote = 1\n[general]\n"),
  "[include.optional]\n" .. LINE .. "\nnote = 1\n[general]\n",
  "add a files key to an existing table"
)
check.eq(
  Config.addInclude("[include.optional]\n[general]\nfiles = []\n"),
  "[include.optional]\n" .. LINE .. "\n[general]\nfiles = []\n",
  "files in a later table is not ours"
)
check.eq(Config.addInclude("[include]\noptional = { files = [] }\n"), nil, "inline table")
check.eq(Config.addInclude("include.optional.files = []\n"), nil, "dotted key")

local before = { diagnostics = { { file = "/c.toml", line = 4, message = "unknown key a" } } }
local after = {
  diagnostics = {
    { file = "/c.toml", line = 5, message = "unknown key a" },
    { file = "/g.toml", line = 2, message = "ignoring effects.screen" },
    { message = "include cycle or duplicate skipped: /x" },
  },
}
local new = Config.introduced(before, after)
check.eq(#new, 2, "a shifted line is not a new diagnostic")
check.eq(new[1], "/g.toml:2: ignoring effects.screen", "file and line prefix")
check.eq(new[2], "include cycle or duplicate skipped: /x", "diagnostic without a file")
check.done("setup")
