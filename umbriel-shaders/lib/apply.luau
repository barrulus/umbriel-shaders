-- SPDX-License-Identifier: MIT
-- Make a selection live: download its files, rewrite the generated include,
-- and keep the change only if Umbriel reports no new diagnostics.
local Config = require("./config.luau")
local Files = require("./files.luau")
local Selection = require("./selection.luau")

local M = {}

local function entriesOf(sel)
  local entries = {}
  for _, entry in pairs(sel.slots) do
    table.insert(entries, entry)
  end
  for _, rule in ipairs(sel.apps) do
    if rule.entry then
      table.insert(entries, rule.entry)
    end
  end
  return entries
end

function M.commit(env, nxt, cb)
  local paths = env.paths
  local jobs = Files.jobsFor(entriesOf(nxt), paths.shaders, noctalia.fileExists)
  Files.download(jobs, function(failed)
    if failed then
      cb(false, noctalia.tr("error.download", { file = failed }))
      return
    end
    Config.validate(paths.config, function(before, err)
      if not before then
        cb(false, err)
        return
      end
      local previous = noctalia.readFile(paths.generated)
      local ok, writeErr = noctalia.writeFile(paths.generated, Config.render(nxt))
      if not ok then
        cb(false, writeErr)
        return
      end
      Config.validate(paths.config, function(after, err2)
        local problems = after and Config.introduced(before, after) or { err2 }
        if #problems > 0 then
          local restored, restoreErr
          if previous then
            restored, restoreErr = noctalia.writeFile(paths.generated, previous)
          else
            restored, restoreErr = noctalia.removeFile(paths.generated)
          end
          local message = table.concat(problems, "\n")
          if not restored then
            message = message
              .. "\nrestoring "
              .. paths.generated
              .. " failed: "
              .. tostring(restoreErr)
          end
          cb(false, message)
          return
        end
        cb(Selection.save(env.selectionPath, nxt))
      end)
    end)
  end)
end

return M
