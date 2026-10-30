-- SPDX-License-Identifier: MIT
local M = {}
local order = {
  "animation.workspaces",
  "animation.windows_in",
  "animation.windows_out",
  "effects.border",
  "effects.window",
  "effects.cursor",
  "effects.screen",
  "animation.windows_move",
  "animation.overview",
  "animation.scratchpad",
  "animation.border",
  "animation.dim_unfocused",
  "animation.layers",
}
function M.index(catalogue)
  local model = { effects = {}, families = {}, members = {}, groups = {}, tags = {} }
  local tags = {}
  for _, effect in ipairs(catalogue.effects or {}) do
    model.effects[effect.id] = effect
    for _, tag in ipairs(effect.tags or {}) do
      tags[tag] = true
    end
  end
  for tag in pairs(tags) do
    table.insert(model.tags, tag)
  end
  table.sort(model.tags)
  for _, family in ipairs(catalogue.families or {}) do
    model.families[family.id] = family
    local members, groups, bySlot = {}, {}, {}
    for _, id in ipairs(family.members or {}) do
      local effect = model.effects[id]
      if effect then
        table.insert(members, effect)
        if effect.role ~= "companion" then
          for _, slot in ipairs(effect.uses or {}) do
            bySlot[slot] = bySlot[slot] or {}
            -- Keep manual-only uses visible with Keep current, without offering an invalid Apply.
            if effect.activation then
              table.insert(bySlot[slot], effect)
            end
          end
        end
      end
    end
    for _, slot in ipairs(order) do
      if bySlot[slot] then
        table.insert(groups, { slot = slot, members = bySlot[slot] })
      end
    end
    model.members[family.id], model.groups[family.id] = members, groups
  end
  return model
end
return M
