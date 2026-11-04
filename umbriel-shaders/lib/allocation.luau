-- SPDX-License-Identifier: MIT
local M = {
  durationCurves = {
    "linear",
    "ease",
    "easein",
    "easeout",
    "easeinout",
    "easeoutcubic",
    "easeinoutcubic",
  },
}
function M.example(slot)
  return ({
    ["animation.overview"] = "animation/overview-glow",
    ["animation.scratchpad"] = "animation/scratchpad-fade",
    ["animation.border"] = "animation/focus-ring-pulse",
    ["animation.dim_unfocused"] = "animation/focus-desaturation",
    ["animation.layers"] = "animation/panel-glide",
  })[slot]
end
function M.application(app)
  assert(
    type(app) == "string" and #app > 0 and #app <= 256 and not app:find("[%z\1-\31\127]"),
    noctalia.tr("allocation.invalid_application")
  )
  return app
end
function M.key(slot, app)
  if not app or app == "" then
    return slot
  end
  M.application(app)
  assert(
    slot == "effects.border" or slot == "effects.window",
    noctalia.tr("allocation.unsupported_application_slot")
  )
  return "application:" .. slot .. ":" .. app
end
function M.destination(key)
  assert(type(key) == "string", noctalia.tr("allocation.invalid_destination"))
  if key:sub(1, 12) ~= "application:" then
    return key, nil
  end
  local slot, app = key:match("^application:([^:]+):(.*)$")
  assert(slot and app and M.key(slot, app) == key, noctalia.tr("allocation.invalid_destination"))
  return slot, app
end
function M.pattern(app)
  M.application(app)
  return "^" .. app:gsub("([\\%.%^%$%|%?%*%+%(%)%[%]%{%}])", "\\%1") .. "$"
end
return M
