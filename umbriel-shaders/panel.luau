-- SPDX-License-Identifier: MIT
local opened = false
local status = noctalia.state.get("status") or {}
local catalogue = noctalia.state.get("catalogue") or {}
local catalogueStatus = noctalia.state.get("catalogue_status") or {}
local catalogueModel = require("./lib/catalogue.luau")
local model = catalogueModel.index(catalogue)
local previewWanted, previewAttempted = {}, {}
local chosen, chosenSlot = "cursor/glow", "effects.cursor"
local browsing, details, comparing = true, false, false
local query, tag = "", ""
local galleryMode, familyId = "shaders", nil
local familyChoices = {}
local searchRevision = 0
local visibleLimit = 24
local kindIndex = 1
local pendingAction, notice = nil, nil
local pendingLocalCopy = false
local kinds = { "all", "animation", "border", "cursor", "window", "screen" }
local kindLabels = {
  all = noctalia.tr("panel.all_types"),
  animation = noctalia.tr("panel.transitions"),
  border = noctalia.tr("panel.borders"),
  cursor = noctalia.tr("panel.cursor"),
  window = noctalia.tr("panel.windows"),
  screen = noctalia.tr("panel.screen"),
}
local labels = {
  ["effects.cursor"] = noctalia.tr("panel.cursor"),
  ["effects.border"] = noctalia.tr("panel.window_borders"),
  ["effects.window"] = noctalia.tr("panel.window_surfaces"),
  ["effects.screen"] = noctalia.tr("panel.screen"),
  ["animation.windows_in"] = noctalia.tr("panel.window_opening"),
  ["animation.windows_out"] = noctalia.tr("panel.window_closing"),
  ["animation.windows_move"] = noctalia.tr("panel.window_movement"),
  ["animation.workspaces"] = noctalia.tr("panel.workspace_transitions"),
  ["animation.overview"] = noctalia.tr("panel.overview"),
  ["animation.scratchpad"] = noctalia.tr("panel.scratchpad"),
  ["animation.border"] = noctalia.tr("panel.border_animation"),
  ["animation.dim_unfocused"] = noctalia.tr("panel.unfocused_dimming"),
  ["animation.layers"] = noctalia.tr("panel.layer_animations"),
}
local fields = {
  enabled = noctalia.tr("panel.enabled"),
  effect = noctalia.tr("panel.shader"),
  duration_ms = noctalia.tr("panel.duration_ms"),
  curve = noctalia.tr("panel.curve"),
  style = noctalia.tr("panel.style"),
  scale = noctalia.tr("panel.scale"),
}
local render
local supportView, supportNotice = nil, nil
local diagnosticReturn = nil
local diagnostics = noctalia.state.get("diagnostics") or {}
local diagnosticSection = 1

local function request(action, token, compare)
  pendingAction = action
  pendingLocalCopy = action == "apply" and #(status.local_copies or {}) > 0
  local serial = (noctalia.state.get("request_serial") or 0) + 1
  noctalia.state.set("request_serial", serial)
  noctalia.state.set("request", {
    serial = serial,
    action = action,
    token = token,
    compare = compare,
    effect = chosen,
    slot = chosenSlot,
    family = familyId,
    choices = familyChoices[familyId],
  })
end
local function selection()
  return model.effects[chosen]
end
local function contains(values, value)
  for _, item in ipairs(values or {}) do
    if item == value then
      return true
    end
  end
  return false
end
local function allTags()
  return model.tags
end
local function choose(effect, slot)
  if status.busy then
    return
  end
  chosen, chosenSlot = effect.id, slot or (effect.uses or {})[1]
  browsing, details, comparing = false, false, false
  status.plan_token = nil
  notice = nil
  render()
end
local function browseTag(value)
  if status.busy then
    return
  end
  galleryMode, familyId = "shaders", nil
  visibleLimit = 24
  tag, query, kindIndex = value, "", 1
  searchRevision += 1
  browsing, details = true, false
  render()
end
local function tagChips(effect, compact)
  local rows, row, used = {}, {}, 0
  local values = effect.tags or {}
  local limit = compact and math.min(2, #values) or #values
  for index = 1, limit do
    local value = values[index]
    -- Bound each chip and wrap rows so long contributor tags cannot widen the panel.
    local width = math.min(compact and 94 or 200, 40 + #value * 8)
    local budget = compact and 236 or 540
    if used + width > budget and #row > 0 then
      table.insert(rows, ui.row({ gap = 6 }, row))
      row, used = {}, 0
    end
    table.insert(
      row,
      ui.column({
        width = width,
        paddingH = 8,
        paddingV = 4,
        fill = "primary/0.12",
        radius = 12,
        onClick = function()
          browseTag(value)
        end,
        tooltip = noctalia.tr("panel.browse_tag", { tag = value }),
      }, {
        ui.label({ text = "#" .. value, fontSize = 12, maxLines = 1, color = "primary" }),
      })
    )
    used += width + 6
  end
  if compact and #values > limit then
    table.insert(row, ui.label({ text = "+" .. tostring(#values - limit), fontSize = 12 }))
  end
  if #row > 0 then
    table.insert(rows, ui.row({ gap = 6, align = "center" }, row))
  end
  return ui.column({ gap = 6 }, rows)
end
local function preview(effect, width, height)
  local localPreview = effect.local_preview or {}
  if
    model.effects[effect.id]
    and not (catalogue.mode == "local" and localPreview.image)
    and not previewAttempted[effect.id]
    and #previewWanted < 24
  then
    previewAttempted[effect.id] = true
    table.insert(previewWanted, effect.id)
  end
  local path = localPreview.image
  if type(path) == "string" and path ~= "" then
    return ui.image({
      key = "preview-" .. effect.id,
      path = path,
      width = width,
      height = height,
      fit = "contain",
      radius = 10,
    })
  end
  return ui.column({
    height = height,
    width = width,
    align = "center",
    justify = "center",
    fill = "primary/0.08",
    radius = 10,
  }, {
    ui.glyph({ name = "sparkles", size = 36, color = "primary" }),
    ui.label({
      text = localPreview.error and noctalia.tr("panel.preview_unavailable") or ((
        effect.preview or {}
      ).image and noctalia.tr("panel.loading_preview") or noctalia.tr(
        "panel.no_preview_available"
      )),
      tooltip = localPreview.error,
      fontSize = 12,
    }),
  })
end
local function matches(effect)
  if kinds[kindIndex] ~= "all" and effect.kind ~= kinds[kindIndex] then
    return false
  end
  if tag ~= "" and not contains(effect.tags, tag) then
    return false
  end
  local haystack = string.lower(
    effect.name
      .. " "
      .. effect.description
      .. " "
      .. effect.author
      .. " "
      .. table.concat(effect.tags or {}, " ")
      .. " "
      .. table.concat(effect.families or {}, " ")
  )
  return query == "" or string.find(haystack, string.lower(query), 1, true) ~= nil
end
local function isActive(effect)
  if not status.managed then
    return false
  end
  for _, id in pairs(status.selections or {}) do
    if id == effect.id then
      return true
    end
  end
  return false
end
local function emptyGallery(noun, records)
  local filtered = records and #records > 0
  local message
  local state = filtered and "filtered"
    or catalogueStatus.loading and "loading"
    or catalogueStatus.error and "failed"
    or records and "empty"
    or "unloaded"
  message =
    noctalia.tr("panel.gallery." .. noun .. "." .. state, { error = catalogueStatus.error or "" })
  return ui.column({ key = "empty-gallery", padding = 24, gap = 12, align = "center" }, {
    ui.glyph({ name = "search", size = 32 }),
    ui.label({ key = "catalogue-message", text = message, maxLines = 6 }),
    ui.button({
      text = noctalia.tr("panel.clear_filters"),
      onClick = "clearFilters",
      visible = filtered,
    }),
    ui.button({
      key = "retry-catalogue",
      text = catalogueStatus.error and noctalia.tr("panel.retry")
        or noctalia.tr("panel.load_catalogue"),
      onClick = "refresh",
      visible = not filtered and not catalogueStatus.loading,
      enabled = not status.busy,
    }),
  })
end
local function browserContent(records, ignoreFilters, slot)
  local children, row, count = {}, {}, 0
  for _, effect in ipairs(records or catalogue.effects or {}) do
    if ignoreFilters or matches(effect) then
      count += 1
      if count <= visibleLimit then
        local entry = effect
        table.insert(
          row,
          ui.column({
            key = entry.id,
            gap = 8,
            padding = 10,
            flexGrow = 1,
            fill = "surface_container/0.65",
            radius = 12,
            border = isActive(entry) and "primary" or "outline_variant/0.25",
            onClick = function()
              choose(entry, slot)
            end,
            tooltip = entry.description,
          }, {
            preview(entry, 240, 120),
            ui.label({
              text = entry.name,
              fontWeight = "bold",
              fontSize = 16,
              maxLines = 2,
              maxWidth = 240,
            }),
            tagChips(entry, true),
            ui.label({
              text = isActive(entry) and noctalia.tr(
                "panel.applied_kind",
                { kind = kindLabels[entry.kind] or entry.kind }
              ) or (kindLabels[entry.kind] or entry.kind),
              fontSize = 12,
              maxLines = 1,
            }),
          })
        )
        if #row == 2 then
          table.insert(children, ui.row({ gap = 12, align = "start" }, row))
          row = {}
        end
      end
    end
  end
  if #row > 0 then
    table.insert(row, ui.spacer({ flexGrow = 1 }))
    table.insert(children, ui.row({ gap = 12, align = "start" }, row))
  end
  if count > visibleLimit then
    table.insert(
      children,
      ui.button({
        key = "show-more",
        text = noctalia.tr("panel.show_more", { visible = visibleLimit, total = count }),
        onClick = "showMore",
      })
    )
  end
  if count == 0 then
    table.insert(children, emptyGallery("shaders", catalogue.effects))
  end
  return children, count
end
local function familySelection()
  return model.families[familyId]
end
local function openFamily(id)
  if status.busy then
    return
  end
  familyId, galleryMode, browsing, details = id, "families", true, false
  visibleLimit = 24
  notice = nil
  render()
end
local function familyMembers(family)
  return model.members[family.id] or {}
end
local function familyPreview(family)
  if (family.local_preview or {}).image then
    return preview(family, 240, 120)
  end
  local rows, row = {}, {}
  for index, effect in ipairs(familyMembers(family)) do
    if index > 4 then
      break
    end
    table.insert(row, preview(effect, 116, 58))
    if #row == 2 then
      table.insert(rows, ui.row({ gap = 4 }, row))
      row = {}
    end
  end
  if #row > 0 then
    table.insert(rows, ui.row({ gap = 4 }, row))
  end
  return ui.column({ height = 120, gap = 4 }, rows)
end
local function familyGallery()
  local children, row, count = {}, {}, 0
  for _, family in ipairs(catalogue.families or {}) do
    local kindMatch = kinds[kindIndex] == "all"
    for _, effect in ipairs(familyMembers(family)) do
      if effect.kind == kinds[kindIndex] then
        kindMatch = true
      end
    end
    local haystack = string.lower(
      family.name
        .. " "
        .. family.description
        .. " "
        .. table.concat(family.tags or {}, " ")
        .. " "
        .. table.concat(family.authors or {}, " ")
    )
    if
      kindMatch
      and (tag == "" or contains(family.tags, tag))
      and (query == "" or string.find(haystack, string.lower(query), 1, true))
    then
      count += 1
      if count <= visibleLimit then
        local entry = family
        table.insert(
          row,
          ui.column({
            key = "family-" .. entry.id,
            gap = 8,
            padding = 10,
            flexGrow = 1,
            fill = "surface_container/0.65",
            radius = 12,
            border = "outline_variant/0.25",
            tooltip = entry.description,
            onClick = function()
              openFamily(entry.id)
            end,
          }, {
            familyPreview(entry),
            ui.label({
              text = entry.name,
              fontWeight = "bold",
              fontSize = 16,
              maxLines = 2,
              maxWidth = 240,
            }),
            tagChips(entry, true),
            ui.label({
              text = noctalia.trp("panel.related_shaders", #entry.members),
              fontSize = 12,
            }),
          })
        )
        if #row == 2 then
          table.insert(children, ui.row({ gap = 12, align = "start" }, row))
          row = {}
        end
      end
    end
  end
  if #row > 0 then
    table.insert(row, ui.spacer({ flexGrow = 1 }))
    table.insert(children, ui.row({ gap = 12 }, row))
  end
  if count > visibleLimit then
    table.insert(
      children,
      ui.button({ text = noctalia.tr("panel.show_more_families"), onClick = "showMore" })
    )
  end
  if count == 0 then
    table.insert(children, emptyGallery("families", catalogue.families))
  end
  return children, count
end
local function familyGroups(family)
  return model.groups[family.id] or {}
end
local function initialiseFamilyChoices(family)
  if familyChoices[family.id] then
    return
  end
  local choices = {}
  for _, group in ipairs(familyGroups(family)) do
    local selector = string.sub(group.slot, 1, 10) == "animation." and group.slot .. ".effect"
      or group.slot
    local preferred = ((family.activation or {}).settings or {})[selector]
    if #group.members == 0 then
      choices[group.slot] = ""
    end
    for _, effect in ipairs(group.members) do
      if #group.members == 1 or effect.preset == preferred then
        choices[group.slot] = effect.id
      end
    end
  end
  familyChoices[family.id] = choices
end
local function familyReady(family)
  if not family then
    return false
  end
  initialiseFamilyChoices(family)
  local count = 0
  for _, group in ipairs(familyGroups(family)) do
    local id = familyChoices[family.id][group.slot]
    if id == nil then
      return false
    end
    if id ~= "" then
      local valid = false
      for _, effect in ipairs(group.members) do
        if effect.id == id then
          valid = true
        end
      end
      if not valid then
        return false
      end
      count += 1
    end
  end
  return count > 0
end
local function familyContent(family)
  initialiseFamilyChoices(family)
  local content = {
    ui.label({ text = family.name, fontSize = 22, fontWeight = "bold", maxLines = 2 }),
    ui.label({ text = family.description, maxLines = 3 }),
    tagChips(family, false),
    ui.label({
      text = noctalia.tr(
        "panel.apply_this_family_together_keep_current_skips_a_use_undo_restores_the_whole_change"
      ),
      fontSize = 13,
      maxLines = 2,
    }),
  }
  for _, group in ipairs(familyGroups(family)) do
    local options, selectedIndex =
      { noctalia.tr("panel.choose_a_shader"), noctalia.tr("panel.keep_current") }, 0
    local selected = familyChoices[family.id][group.slot]
    if selected == "" then
      selectedIndex = 1
    end
    for index, member in ipairs(group.members) do
      table.insert(options, member.name)
      if selected == member.id then
        selectedIndex = index + 1
      end
    end
    local use = group.slot
    local members = group.members
    table.insert(
      content,
      ui.label({ text = labels[use] or use, fontWeight = "bold", fontSize = 16 })
    )
    table.insert(
      content,
      ui.select({
        key = "family-choice-" .. use,
        options = options,
        selectedIndex = selectedIndex,
        enabled = not status.busy,
        onChange = function(index)
          local i = tonumber(index) or 0
          if i == 0 then
            familyChoices[family.id][use] = nil
          elseif i == 1 then
            familyChoices[family.id][use] = ""
          else
            familyChoices[family.id][use] = members[i - 1].id
          end
          notice = nil
          status.plan_token = nil
          render()
        end,
      })
    )
    local cards = browserContent(members, true, use)
    for _, card in ipairs(cards) do
      table.insert(content, card)
    end
  end
  local companions = {}
  for _, effect in ipairs(familyMembers(family)) do
    if effect.role == "companion" then
      table.insert(companions, effect)
    end
  end
  if #companions > 0 then
    table.insert(
      content,
      ui.label({
        text = noctalia.tr("panel.matching_overlays_are_included_with_their_borders"),
        fontSize = 13,
        maxLines = 2,
      })
    )
  end
  return content
end
local function show(value)
  if value == nil then
    return noctalia.tr("panel.base_default")
  end
  if value == "" then
    return noctalia.tr("panel.none")
  end
  return tostring(value)
end
local function changeLabel(key)
  if labels[key] then
    return labels[key]
  end
  local scope, field = string.match(key, "^(animation%.[^.]+)%.(.+)$")
  return (labels[scope] or noctalia.tr("panel.animations"))
    .. " · "
    .. (fields[field] or noctalia.tr("panel.enabled"))
end
local function technicalDetails(effect, hasPlan)
  local content = {
    ui.label({
      text = noctalia.tr("panel.effect_details", { name = effect.name }),
      fontSize = 21,
      fontWeight = "bold",
      maxLines = 2,
    }),
    ui.label({
      text = noctalia.tr(
        "panel.author_license",
        { author = effect.author, license = effect.license }
      ),
      maxLines = 2,
    }),
    tagChips(effect, false),
  }
  if #(effect.families or {}) > 0 then
    table.insert(
      content,
      ui.label({
        text = noctalia.tr("panel.collection", { names = table.concat(effect.families, ", ") }),
        maxLines = 3,
      })
    )
  end
  if hasPlan then
    table.insert(
      content,
      ui.label({ text = noctalia.tr("panel.what_will_change"), fontWeight = "bold" })
    )
    local changed = 0
    for _, change in ipairs(status.changes or {}) do
      if change.before ~= change.after then
        changed += 1
        table.insert(
          content,
          ui.label({
            text = changeLabel(change.key) .. ": " .. show(change.before) .. " → " .. show(
              change.after
            ),
            maxLines = 3,
          })
        )
      end
    end
    if changed == 0 then
      table.insert(
        content,
        ui.label({ text = noctalia.tr("panel.these_settings_already_match"), maxLines = 2 })
      )
    end
    if #(status.local_copies or {}) > 0 then
      table.insert(
        content,
        ui.button({
          text = comparing and noctalia.tr("panel.hide_local_comparison")
            or noctalia.tr("panel.compare_local_copy"),
          onClick = "compareLocal",
        })
      )
      if comparing then
        for _, copy in ipairs(status.local_copies) do
          local result = copy.comparison_error
              and (noctalia.tr("panel.comparison_error", { error = copy.comparison_error }))
            or noctalia.tr("panel.local_dependency_not_compared")
          if copy.matches_catalogue == true then
            result = noctalia.tr("panel.matches_the_catalogue")
          elseif copy.matches_catalogue == false then
            result = noctalia.tr("panel.customised_locally_your_changes_are_kept")
          end
          table.insert(
            content,
            ui.label({ text = copy.preset .. ": " .. result .. "\n" .. copy.config, maxLines = 5 })
          )
        end
      end
    end
    if #(status.dependencies or {}) > 0 then
      table.insert(
        content,
        ui.label({
          text = noctalia.tr("panel.included", { names = table.concat(status.dependencies, ", ") }),
          maxLines = 4,
        })
      )
    end
    table.insert(content, ui.label({ text = status.base_notice or "", maxLines = 4 }))
  end
  table.insert(
    content,
    ui.label({
      text = noctalia.tr(
        "panel.configuration",
        { path = status.base or noctalia.tr("panel.choose_configuration") }
      ),
      maxLines = 4,
    })
  )
  if not hasPlan and status.message then
    table.insert(content, ui.label({ text = status.message, maxLines = 8 }))
  end
  local recording = (effect.local_preview or {}).animation
  if type(recording) == "string" and noctalia.commandExists("xdg-open") then
    table.insert(
      content,
      ui.button({
        text = noctalia.tr("panel.open_recording_externally"),
        glyph = "external-link",
        onClick = "playRecording",
      })
    )
  end
  table.insert(
    content,
    ui.button({ text = noctalia.tr("panel.troubleshooting"), onClick = "troubleshoot" })
  )
  return content
end

local function supportHeader(title)
  return ui.row(
    { key = "support-header", height = 40, minHeight = 40, gap = 8, align = "center" },
    {
      ui.button({
        key = "support-back",
        glyph = "arrow-left",
        tooltip = noctalia.tr("panel.back"),
        onClick = "supportBack",
        variant = "ghost",
      }),
      ui.label({ text = title, fontSize = 22, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        key = "support-refresh",
        glyph = "refresh",
        tooltip = noctalia.tr("panel.refresh_diagnostics"),
        onClick = "refreshDiagnostics",
        visible = supportView == "diagnostics",
        enabled = not status.busy,
        variant = "ghost",
      }),
      ui.button({
        key = "support-close",
        glyph = "x",
        tooltip = noctalia.tr("panel.close"),
        onClick = "close",
        variant = "ghost",
      }),
    }
  )
end

local function renderSupport()
  if supportView == "active" then
    local content = {}
    for slot, id in pairs(status.selections or {}) do
      local effect = model.effects[id]
      local use = slot
      table.insert(
        content,
        ui.row({ gap = 8, align = "center" }, {
          ui.label({
            text = (labels[use] or use)
              .. "\n"
              .. (effect and effect.name or (noctalia.tr("panel.withdrawn", { id = id }))),
            maxLines = 3,
            flexGrow = 1,
          }),
          ui.button({
            text = noctalia.tr("panel.remove"),
            enabled = status.managed == true and not status.busy and not status.pending,
            tooltip = noctalia.tr(
              "panel.release_this_selection_and_return_this_use_to_the_original_configuration"
            ),
            onClick = function()
              local serial = (noctalia.state.get("request_serial") or 0) + 1
              noctalia.state.set("request_serial", serial)
              noctalia.state.set("request", { serial = serial, action = "remove", slot = use })
            end,
          }),
        })
      )
    end
    if #content == 0 then
      table.insert(
        content,
        ui.label({ text = noctalia.tr("panel.no_managed_shader_selections"), maxLines = 2 })
      )
    end
    panel.render(ui.column({ flexGrow = 1, padding = 14, gap = 12 }, {
      supportHeader(noctalia.tr("panel.active_selections")),
      ui.scroll({ flexGrow = 1, gap = 12 }, content),
      ui.label({
        text = status.message or "",
        maxLines = 4,
        color = status.ok == false and "error" or "on_surface",
      }),
      ui.row({ gap = 8 }, {
        ui.button({
          text = noctalia.tr("panel.undo"),
          onClick = "undo",
          enabled = status.can_undo == true and not status.busy and not status.pending,
        }),
        ui.button({
          text = noctalia.tr("panel.restore_original"),
          onClick = "restore",
          enabled = status.can_restore == true and not status.busy and not status.pending,
        }),
        ui.button({
          text = noctalia.tr("panel.recover"),
          onClick = "recover",
          visible = status.pending == true,
          enabled = not status.busy,
        }),
      }),
    }))
    return
  end
  if supportView == "settings" then
    panel.render(ui.column({ flexGrow = 1, padding = 14, gap = 16 }, {
      supportHeader(noctalia.tr("panel.settings")),
      ui.button({
        key = "plugin-settings",
        text = noctalia.tr("panel.plugin_settings"),
        glyph = "settings",
        onClick = "pluginSettings",
      }),
      ui.label({
        text = noctalia.tr("panel.choose_your_catalogue_source_and_original_configuration"),
        maxLines = 2,
      }),
      ui.button({
        key = "troubleshooting",
        text = noctalia.tr("panel.troubleshooting"),
        onClick = "troubleshoot",
      }),
      ui.label({
        text = noctalia.tr(
          "panel.inspect_saved_settings_the_generated_configuration_and_live_effects"
        ),
        maxLines = 3,
      }),
    }))
    return
  end
  local sections = diagnostics.sections or {}
  local options = {}
  for _, entry in ipairs(sections) do
    table.insert(options, entry.title)
  end
  diagnosticSection = math.max(1, math.min(diagnosticSection, #sections))
  local content = {}
  local selected = sections[diagnosticSection]
  if selected then
    for line in string.gmatch(selected.text .. "\n", "(.-)\n") do
      table.insert(
        content,
        ui.label({
          text = line == "" and " " or line,
          maxLines = 20,
          fontSize = 13,
          maxWidth = 560,
          fontFamily = diagnosticSection == 3 and "monospace" or nil,
        })
      )
    end
  else
    table.insert(
      content,
      ui.label({
        text = status.busy and noctalia.tr("panel.reading_diagnostics")
          or noctalia.tr("panel.no_report_available_use_refresh_to_try_again"),
        maxLines = 3,
      })
    )
  end
  local root = { supportHeader(noctalia.tr("panel.troubleshooting")) }
  if #options > 0 then
    table.insert(
      root,
      ui.select({
        key = "diagnostic-section",
        options = options,
        selectedIndex = diagnosticSection - 1,
        onChange = "chooseDiagnosticSection",
      })
    )
    table.insert(
      root,
      ui.label({
        text = status.busy
            and noctalia.tr("panel.refreshing_report", { time = diagnostics.generated or "" })
          or (diagnostics.generated or ""),
        fontSize = 12,
        maxLines = 2,
      })
    )
  end
  table.insert(
    root,
    ui.scroll({ key = "diagnostic-content-" .. tostring(diagnosticSection), flexGrow = 1 }, {
      ui.column({ gap = 5 }, content),
    })
  )
  if supportNotice or status.ok == false then
    table.insert(
      root,
      ui.label({
        text = supportNotice or status.message or noctalia.tr("panel.could_not_read_diagnostics"),
        fontSize = 13,
        maxLines = 3,
      })
    )
  end
  table.insert(
    root,
    ui.row({ key = "diagnostic-actions", gap = 8 }, {
      ui.button({
        key = "copy-report",
        text = noctalia.tr("panel.copy_report"),
        onClick = "copyDiagnosticReport",
        enabled = type(diagnostics.report_text) == "string" and not status.busy,
      }),
      ui.button({
        key = "open-data-folder",
        text = noctalia.tr("panel.open_data_folder"),
        onClick = "openDataFolder",
        enabled = noctalia.commandExists("xdg-open"),
        tooltip = noctalia.tr(
          "panel.open_the_plugin_s_persistent_configuration_and_shader_storage"
        ),
      }),
    })
  )
  panel.render(ui.column({ flexGrow = 1, padding = 14, gap = 12 }, root))
end

render = function()
  if not opened then
    return
  end
  previewWanted = {}
  if supportView then
    renderSupport()
    return
  end
  local effect = selection()
  local family = familySelection()
  if familyId and not family then
    familyId = nil
  end
  if not effect then
    browsing = true
  end
  local ready = not status.busy
  local hasPlan = not browsing
    and type(status.plan_token) == "string"
    and status.ok == true
    and status.effect_id == chosen
    and status.slot == chosenSlot
  local recipeReady, uses, useIndex = false, {}, 1
  if effect then
    for index, use in ipairs(effect.uses or {}) do
      table.insert(uses, labels[use] or use)
      if use == chosenSlot then
        useIndex = index
      end
    end
    chosenSlot = (effect.uses or {})[useIndex]
    if chosenSlot then
      local selector = string.sub(chosenSlot, 1, 10) == "animation." and chosenSlot .. ".effect"
        or chosenSlot
      recipeReady = type(effect.activation) == "table"
        and type(effect.activation.settings) == "table"
        and effect.activation.settings[selector] == effect.preset
    end
  end
  local root = {
    ui.row({ key = "header", height = 40, minHeight = 40, gap = 8, align = "center" }, {
      ui.button({
        key = "back",
        glyph = "arrow-left",
        tooltip = noctalia.tr("panel.back"),
        onClick = "browse",
        visible = not browsing or familyId ~= nil,
        enabled = ready,
        variant = "ghost",
      }),
      ui.label({
        key = "heading",
        text = galleryMode == "families" and noctalia.tr("panel.families")
          or noctalia.tr("panel.shaders"),
        fontSize = 24,
        fontWeight = "bold",
        flexGrow = 1,
      }),
      ui.button({
        key = "gallery-mode",
        text = galleryMode == "families" and noctalia.tr("panel.all_shaders")
          or noctalia.tr("panel.families"),
        onClick = "toggleGallery",
        visible = browsing and familyId == nil,
        enabled = ready,
        variant = "ghost",
      }),
      ui.button({
        key = "active",
        text = noctalia.tr("panel.active"),
        onClick = "activeSelections",
        enabled = ready,
        variant = "ghost",
      }),
      ui.button({
        key = "refresh",
        glyph = "refresh",
        tooltip = noctalia.tr("panel.refresh_catalogue"),
        onClick = "refresh",
        enabled = ready,
        variant = "ghost",
      }),
      ui.button({
        key = "settings",
        glyph = "settings",
        tooltip = noctalia.tr("panel.settings"),
        onClick = "settings",
        variant = "ghost",
      }),
      ui.button({
        key = "close",
        glyph = "x",
        tooltip = noctalia.tr("panel.close"),
        onClick = "close",
        variant = "ghost",
      }),
    }),
  }
  local mode = catalogue.mode or noctalia.getConfig("source_mode") or "online"
  local online = mode == "online"
  local sourceLabel = online and noctalia.tr("panel.community_catalogue")
    or (
      mode == "snapshot" and noctalia.tr("panel.saved_snapshot")
      or noctalia.tr("panel.local_development")
    )
  if online and catalogue.offline then
    sourceLabel = noctalia.tr("panel.offline_saved_community_catalogue")
  end
  table.insert(
    root,
    ui.row({ key = "catalogue-source", gap = 8, align = "center" }, {
      ui.label({ text = sourceLabel, fontSize = 12, color = "on_surface/0.7", flexGrow = 1 }),
      ui.button({
        text = noctalia.tr("panel.change_source"),
        variant = "ghost",
        onClick = "pluginSettings",
        enabled = ready,
      }),
    })
  )
  local content
  if browsing and family then
    content = familyContent(family)
  elseif browsing then
    table.insert(
      root,
      ui.input({
        key = "search-" .. tostring(searchRevision),
        value = query,
        placeholder = noctalia.tr("panel.search_shaders_tags_or_creators"),
        onChange = "search",
      })
    )
    local tags, tagIndex = { noctalia.tr("panel.all_tags") }, 0
    for index, value in ipairs(allTags()) do
      table.insert(tags, "#" .. value)
      if value == tag then
        tagIndex = index
      end
    end
    local count
    if galleryMode == "families" then
      content, count = familyGallery()
    else
      content, count = browserContent()
    end
    table.insert(
      root,
      ui.row({ key = "filters", gap = 8, align = "center" }, {
        ui.select({
          key = "kind",
          options = {
            noctalia.tr("panel.all_types"),
            noctalia.tr("panel.transitions"),
            noctalia.tr("panel.borders"),
            noctalia.tr("panel.cursor"),
            noctalia.tr("panel.windows"),
            noctalia.tr("panel.screen"),
          },
          selectedIndex = kindIndex - 1,
          width = 150,
          onChange = "filterKind",
        }),
        ui.select({
          key = "tag",
          options = tags,
          selectedIndex = tagIndex,
          width = 160,
          onChange = "filterTag",
        }),
        ui.label({
          text = noctalia.trp(
            galleryMode == "families" and "panel.family_count" or "panel.shader_count",
            count
          ),
          fontSize = 12,
          flexGrow = 1,
        }),
        ui.button({
          text = noctalia.tr("panel.clear"),
          onClick = "clearFilters",
          variant = "ghost",
          visible = tag ~= "" or query ~= "" or kindIndex ~= 1,
        }),
      })
    )
  elseif details then
    content = technicalDetails(effect, hasPlan)
  else
    content = {
      ui.label({ text = effect.name, fontSize = 22, fontWeight = "bold", maxLines = 2 }),
      tagChips(effect, false),
      ui.row({ justify = "center" }, { preview(effect, 480, 220) }),
      ui.label({ text = effect.description, maxLines = 3 }),
      ui.label({
        text = noctalia.tr("panel.author", { author = effect.author }),
        fontSize = 12,
        color = "on_surface/0.7",
        maxLines = 2,
      }),
    }
    for _, id in ipairs(effect.families or {}) do
      local familyName = id
      if model.families[id] then
        familyName = model.families[id].name
      end
      table.insert(
        content,
        ui.button({
          text = noctalia.tr("panel.explore_family", { name = familyName }),
          variant = "ghost",
          onClick = function()
            openFamily(id)
          end,
        })
      )
    end
    if not recipeReady then
      table.insert(
        content,
        ui.label({
          text = #uses == 0 and noctalia.tr("panel.included_with_another_shader")
            or noctalia.tr("panel.this_shader_needs_manual_setup"),
          maxLines = 2,
        })
      )
    end
  end
  table.insert(
    root,
    ui.scroll({
      key = browsing
          and ("gallery-" .. galleryMode .. "-" .. (familyId or "all") .. "-" .. tag .. "-" .. tostring(
            kindIndex
          ) .. "-" .. query)
        or (details and "details-" or "preview-") .. chosen,
      flexGrow = 1,
      gap = 12,
    }, content)
  )
  if status.busy then
    table.insert(root, ui.label({ text = noctalia.tr("panel.working"), fontSize = 13 }))
  elseif status.ok == false or status.pending then
    table.insert(
      root,
      ui.label({
        text = status.message
          or noctalia.tr("panel.could_not_complete_the_change_open_details_for_more_information"),
        color = "error",
        maxLines = 4,
      })
    )
  elseif not browsing or family then
    local message = notice
    if hasPlan and #(status.local_copies or {}) > 0 then
      message = noctalia.tr("panel.already_on_your_device_using_your_local_copy")
    end
    if message then
      table.insert(root, ui.label({ text = message, fontSize = 13, maxLines = 2 }))
    end
  end
  if status.pending then
    table.insert(
      root,
      ui.button({
        text = noctalia.tr("panel.recover_previous_look"),
        onClick = "recover",
        enabled = ready,
      })
    )
  end
  if browsing and family then
    local readyFamily = familyReady(family)
    table.insert(
      root,
      ui.row({ key = "family-apply", gap = 10, align = "center" }, {
        ui.label({
          text = readyFamily and noctalia.tr("panel.your_choices_apply_together")
            or noctalia.tr("panel.choose_a_shader_or_keep_current_for_each_use"),
          fontSize = 13,
          maxLines = 2,
          flexGrow = 1,
        }),
        ui.button({
          text = noctalia.tr("panel.review"),
          onClick = "reviewFamily",
          enabled = ready and readyFamily and not status.pending,
        }),
        ui.button({
          key = "apply-family",
          text = noctalia.tr("panel.apply_family"),
          variant = "primary",
          onClick = status.plan_token and status.family_id == familyId and "apply" or "applyFamily",
          enabled = ready and readyFamily and not status.pending,
        }),
      })
    )
  elseif not browsing then
    table.insert(
      root,
      ui.row({ key = "destination", gap = 10, align = "center" }, {
        ui.select({
          key = "use",
          options = uses,
          selectedIndex = useIndex - 1,
          flexGrow = 1,
          enabled = ready,
          onChange = "chooseUse",
          visible = #uses > 0,
        }),
        ui.button({
          key = "apply",
          text = noctalia.tr("panel.apply"),
          width = 100,
          variant = "primary",
          onClick = hasPlan and "apply" or "chooseShader",
          enabled = ready and recipeReady and not status.pending,
        }),
      })
    )
  end
  if not browsing or family or status.can_undo or status.can_restore then
    table.insert(
      root,
      ui.row({ key = "footer", gap = 8 }, {
        ui.button({
          key = "undo",
          text = noctalia.tr("panel.undo"),
          onClick = "undo",
          enabled = ready and status.can_undo == true and not status.pending,
          tooltip = noctalia.tr("panel.return_to_your_previous_selection"),
        }),
        ui.button({
          key = "restore",
          text = noctalia.tr("panel.restore_original"),
          onClick = "restore",
          enabled = ready and status.can_restore == true and not status.pending,
        }),
        ui.spacer({ flexGrow = 1 }),
        ui.button({
          key = "details",
          text = details and noctalia.tr("panel.preview") or noctalia.tr("panel.details"),
          onClick = "toggleDetails",
          visible = not browsing,
          enabled = ready,
          variant = "ghost",
        }),
      })
    )
  end
  panel.render(ui.column({ flexGrow = 1, padding = 14, gap = 12 }, root))
  if #previewWanted > 0 then
    noctalia.state.set("preview_request", { ids = previewWanted })
  end
end

noctalia.state.watch("status", function(value)
  if type(value) == "table" then
    status = value
    if not value.busy and pendingAction then
      if value.ok ~= false then
        if pendingAction == "choose-family" then
          notice = value.used_local_copy
              and noctalia.tr("panel.family_applied_using_your_local_copies")
            or noctalia.tr("panel.family_applied")
        elseif pendingAction == "apply" or pendingAction == "choose" then
          notice = (pendingLocalCopy or value.used_local_copy)
              and noctalia.tr("panel.applied_using_your_local_copy")
            or noctalia.tr("panel.applied")
        elseif pendingAction == "undo" then
          notice = noctalia.tr("panel.previous_look_restored")
        elseif pendingAction == "restore" or pendingAction == "recover" then
          notice = noctalia.tr("panel.original_look_restored")
        end
      end
      pendingAction = nil
    end
  end
  render()
end)
noctalia.state.watch("catalogue", function(value)
  catalogue = type(value) == "table" and value or {}
  model = catalogueModel.index(catalogue)
  previewAttempted = {}
  familyChoices = {}
  if tag ~= "" and not contains(allTags(), tag) then
    tag = ""
  end
  render()
end)
noctalia.state.watch("catalogue_status", function(value)
  catalogueStatus = type(value) == "table" and value or {}
  render()
end)
noctalia.state.watch("previews", function(value)
  for id, preview in pairs(type(value) == "table" and value or {}) do
    if model.effects[id] then
      model.effects[id].local_preview = preview
    end
  end
  render()
end)
noctalia.state.watch("diagnostics", function(value)
  diagnostics = type(value) == "table" and value or {}
  render()
end)
function onOpen(_context)
  opened = true
  status = noctalia.state.get("status") or status
  catalogue = noctalia.state.get("catalogue") or catalogue
  catalogueStatus = noctalia.state.get("catalogue_status") or catalogueStatus
  model = catalogueModel.index(catalogue)
  for id, preview in pairs(noctalia.state.get("previews") or {}) do
    if model.effects[id] then
      model.effects[id].local_preview = preview
    end
  end
  render()
  if not status.busy then
    request(supportView == "diagnostics" and "diagnostics" or "status", nil)
  end
end
function browse()
  if browsing and familyId then
    familyId = nil
  end
  browsing, details = true, false
  render()
end
function toggleGallery()
  galleryMode = galleryMode == "shaders" and "families" or "shaders"
  familyId, query, tag, kindIndex = nil, "", "", 1
  searchRevision += 1
  browsing, details = true, false
  render()
end
function showMore()
  visibleLimit += 24
  render()
end
function search(value)
  visibleLimit = 24
  query = value
  render()
end
function filterKind(index)
  visibleLimit = 24
  kindIndex = (tonumber(index) or 0) + 1
  render()
end
function filterTag(index)
  visibleLimit = 24
  tag = allTags()[tonumber(index) or 0] or ""
  render()
end
function clearFilters()
  visibleLimit = 24
  tag, query, kindIndex = "", "", 1
  searchRevision += 1
  browsing = true
  render()
end
function chooseUse(index)
  if status.busy then
    return
  end
  local effect = selection()
  if effect then
    chosenSlot = (effect.uses or {})[(tonumber(index) or 0) + 1]
  end
  status.plan_token, notice = nil, nil
  comparing = false
  render()
  if details then
    request("prepare", nil)
  end
end
function toggleDetails()
  notice = nil
  details = not details
  comparing = false
  render()
  local effect = selection()
  if details and effect and effect.activation and chosenSlot then
    request("prepare", nil)
  end
end
function playRecording()
  local effect = selection()
  local path = effect and (effect.local_preview or {}).animation
  if type(path) == "string" then
    noctalia.runAsync({ "xdg-open", path })
  end
end
function onClose()
  opened = false
end
function compareLocal()
  comparing = not comparing
  if comparing and not status.busy then
    request("prepare", nil, true)
  end
  render()
end
function applyFamily()
  request("choose-family", nil)
end
function apply()
  request("apply", status.plan_token)
end
function chooseShader()
  request("choose", nil)
end
function undo()
  request("undo", nil)
end
function restore()
  request("restore", nil)
end
function recover()
  request("recover", nil)
end
function refresh()
  request("refresh", nil)
end
function activeSelections()
  supportView = "active"
  render()
end
function reviewFamily()
  request("prepare-family", nil)
end
function settings()
  supportView = "settings"
  supportNotice = nil
  render()
end
function pluginSettings()
  noctalia.openSettings()
end
function troubleshoot()
  diagnosticReturn = supportView
  supportView, supportNotice = "diagnostics", nil
  diagnosticSection = 1
  render()
  if not status.busy then
    request("diagnostics", nil)
  end
end
function supportBack()
  supportView = supportView == "diagnostics" and diagnosticReturn or nil
  supportNotice = nil
  render()
end
function refreshDiagnostics()
  supportNotice = nil
  request("diagnostics", nil)
end
function chooseDiagnosticSection(index)
  diagnosticSection = (tonumber(index) or 0) + 1
  supportNotice = nil
  render()
end
function copyDiagnosticReport()
  if type(diagnostics.report_text) ~= "string" then
    return
  end
  supportNotice = noctalia.copyToClipboard(diagnostics.report_text, "text/plain")
      and noctalia.tr("panel.diagnostic_report_copied")
    or noctalia.tr("panel.could_not_copy_the_report")
  render()
end
function openDataFolder()
  local path, err = noctalia.pluginDataDir()
  if not path then
    supportNotice = err or noctalia.tr("panel.plugin_storage_is_unavailable")
    render()
    return
  end
  local launched = noctalia.runAsync({ "xdg-open", path }, function(result)
    supportNotice = result.exitCode == 0 and noctalia.tr("panel.opened_the_plugin_data_folder")
      or noctalia.tr("panel.could_not_open_the_folder_its_path_is_in_overview")
    render()
  end)
  if not launched then
    supportNotice = noctalia.tr("panel.could_not_start_the_file_manager")
    render()
  end
end
function close()
  panel.close()
end
