-- SPDX-License-Identifier: MIT
local Apply = require("./lib/apply.luau")
local Catalogue = require("./lib/catalogue.luau")
local Config = require("./lib/config.luau")
local Files = require("./lib/files.luau")
local Selection = require("./lib/selection.luau")
local Slots = require("./lib/slots.luau")

local PAGE_SIZE = 8
local tr = noctalia.tr

local dataDir = assert(noctalia.pluginDataDir())
local env = { paths = Config.paths(), selectionPath = dataDir .. "/selection.json" }
local hasUmbriel = noctalia.commandExists("umbriel")

local sel = Selection.load(env.selectionPath)
local cat = Catalogue.readCache(dataDir)
local catState = cat and "ok" or "loading" -- ok | loading | offline | error
local fetching = false
local setupState = "present" -- present | insert | manual
local busy = false
local message, messageIsError = nil, false
local tab = "slots" -- slots | browse | families
local query, slotFilter, page = "", nil, 1
local picking = nil -- { slot = string, app_id = string? } while choosing a shader
local previews = {} -- destination path -> "pending" | "ok" | "failed"

local render

-- Child list without holes: nil/false arguments are skipped.
local function nodes(...)
  local out = {}
  for i = 1, select("#", ...) do
    local node = select(i, ...)
    if node then
      table.insert(out, node)
    end
  end
  return out
end

local function slotLabel(slot)
  return tr("slot." .. Slots.key(slot))
end

local function say(text, isError)
  message, messageIsError = text, isError == true
end

local function canApply()
  return hasUmbriel and setupState == "present" and not busy
end

local function commitSelection(nxt, okText, onOk)
  if busy then
    return
  end
  busy = true
  say(tr("status.working"))
  render()
  Apply.commit(env, nxt, function(ok, err)
    busy = false
    if ok then
      sel = nxt
      say(okText or tr("status.applied"))
      if onOk then
        onOk()
      end
    else
      say(tr("status.failed", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function commit(change, okText, onOk)
  commitSelection(Selection.change(sel, change), okText, onOk)
end

local function refreshSetup()
  setupState = Config.includeState(noctalia.readFile(env.paths.config))
end

local function runSetup()
  if busy then
    return
  end
  busy = true
  say(tr("status.working"))
  render()
  Config.setup(env.paths, function(ok, err)
    busy = false
    refreshSetup()
    if ok then
      say(tr("setup.done"))
    else
      say(tr("setup.failed", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function fetchCatalogue()
  if fetching then
    return
  end
  fetching = true
  if not cat then
    catState = "loading"
  end
  Catalogue.fetch(dataDir, function(fresh, err)
    fetching = false
    if fresh then
      cat, catState = fresh, "ok"
    elseif cat then
      catState = "offline"
    else
      catState = "error"
      say(tr("banner.catalogue_error", { error = tostring(err) }), true)
    end
    render()
  end)
end

local function previewFor(effect)
  local image = cat and not effect.imported and effect.preview and effect.preview.image
  if not image then
    return nil
  end
  local dest = dataDir .. "/previews/" .. cat.revision .. "/" .. image
  if previews[dest] == nil then
    if noctalia.fileExists(dest) then
      previews[dest] = "ok"
    else
      previews[dest] = "pending"
      local synchronous = true
      local job = { url = Files.raw .. cat.revision .. "/" .. image, dest = dest }
      Files.download({ job }, function(failed)
        previews[dest] = failed and "failed" or "ok"
        if not synchronous then
          render()
        end
      end)
      synchronous = false
    end
  end
  return previews[dest] == "ok" and dest or nil
end

local function pick(slot, appId)
  picking = { slot = slot, app_id = appId }
  tab, query, page = "browse", "", 1
  render()
end

local function applyEffect(effect, slot)
  local target = picking
  if target then
    picking, tab, query = nil, "slots", ""
  end
  local entry = Catalogue.resolve(cat, effect, slot, env.paths.shaders)
  if target and target.app_id then
    commit(function(n)
      Selection.setApp(n, target.app_id, slot, entry)
    end)
  else
    commit(function(n)
      n.slots[slot] = entry
    end)
  end
end

local function removeImport(effect)
  commit(
    function(n)
      Selection.removeImport(n, effect.id)
    end,
    tr("status.import_removed"),
    function()
      Files.removeImport(effect)
    end
  )
end

local function applyFamily(family)
  local entries = {}
  for slot, effect in pairs(Catalogue.familySlots(cat, family)) do
    entries[slot] = Catalogue.resolve(cat, effect, slot, env.paths.shaders)
  end
  commit(function(n)
    for slot, entry in pairs(entries) do
      n.slots[slot] = entry
    end
  end, tr("status.family_applied", { name = family.name }))
end

local function card(key, children)
  return ui.column(
    { key = key, gap = 6, padding = 10, radius = 8, fill = "surface_variant/0.5" },
    children
  )
end

local function hint(text)
  return ui.label({ text = text, fontSize = 11, color = "on_surface_variant" })
end

local function slotsTab()
  local out = {}
  for _, slot in ipairs(Slots.list) do
    local entry = sel.slots[slot]
    table.insert(
      out,
      card(slot, {
        ui.row(
          { gap = 8, align = "center" },
          nodes(
            ui.column({ gap = 2, flexGrow = 1 }, {
              ui.label({ text = slotLabel(slot), fontWeight = "bold" }),
              ui.label({
                text = entry and entry.name or tr("slots.none"),
                color = entry and "primary" or "on_surface_variant",
                fontSize = 12,
              }),
            }),
            ui.button({
              text = tr("slots.change"),
              controlSize = "sm",
              enabled = canApply(),
              onClick = function()
                pick(slot, nil)
              end,
            }),
            entry
              and ui.button({
                text = tr("slots.clear"),
                controlSize = "sm",
                variant = "ghost",
                enabled = canApply(),
                onClick = function()
                  commit(function(n)
                    n.slots[slot] = nil
                    n.timing[slot] = nil
                  end)
                end,
              })
          )
        ),
      })
    )
  end
  return out
end

local function allEffects()
  local list = table.clone(sel.imports)
  for _, effect in ipairs(cat and cat.effects or {}) do
    table.insert(list, effect)
  end
  return list
end

local function effectCard(effect)
  local buttons = {}
  for _, slot in ipairs(picking and { picking.slot } or effect.uses) do
    table.insert(
      buttons,
      ui.button({
        key = effect.id .. ":" .. slot,
        text = picking and tr("browse.apply") or slotLabel(slot),
        controlSize = "sm",
        variant = "secondary",
        enabled = canApply(),
        onClick = function()
          applyEffect(effect, slot)
        end,
      })
    )
  end
  if effect.imported and not picking then
    table.insert(
      buttons,
      ui.button({
        key = effect.id .. ":remove",
        text = tr("import.remove"),
        controlSize = "sm",
        variant = "ghost",
        enabled = canApply(),
        onClick = function()
          removeImport(effect)
        end,
      })
    )
  end
  local image = previewFor(effect)
  return ui.row(
    { key = effect.id, gap = 12, padding = 10, radius = 8, fill = "surface_variant/0.5" },
    {
      image and ui.image({ path = image, width = 144, height = 81, radius = 6, fit = "cover" })
        or ui.box({ width = 144, height = 81, radius = 6, fill = "surface_variant" }),
      ui.column({ gap = 4, flexGrow = 1 }, {
        ui.label({ text = effect.name, fontWeight = "bold" }),
        ui.label({
          text = effect.imported and tr("browse.imported")
            or tr("browse.by", { author = effect.author or "" }),
          fontSize = 12,
          color = "on_surface_variant",
        }),
        ui.label({ text = effect.description or "", fontSize = 12, maxLines = 2 }),
        ui.row({ gap = 6 }, buttons),
      }),
    }
  )
end

-- Extra nodes at the end of Browse (Task 9 adds the import form here).
local function browseFooter()
  return {}
end

local function browseTab()
  local out = {}
  if picking then
    local target = picking
    local text = target.app_id
        and tr("browse.picking_app", { app = target.app_id, slot = slotLabel(target.slot) })
      or tr("browse.picking", { slot = slotLabel(target.slot) })
    table.insert(
      out,
      ui.row(
        { gap = 8, align = "center" },
        nodes(
          ui.label({ text = text, flexGrow = 1 }),
          target.app_id
            and ui.button({
              text = tr("apps.off"),
              controlSize = "sm",
              enabled = canApply(),
              onClick = function()
                picking, tab, query = nil, "slots", ""
                commit(function(n)
                  Selection.setApp(n, target.app_id, target.slot, nil)
                end)
              end,
            }),
          ui.button({
            text = tr("browse.cancel"),
            controlSize = "sm",
            variant = "ghost",
            onClick = function()
              picking, tab, query = nil, "slots", ""
              render()
            end,
          })
        )
      )
    )
  end
  local options = { tr("browse.all_slots") }
  for _, slot in ipairs(Slots.list) do
    table.insert(options, slotLabel(slot))
  end
  table.insert(
    out,
    ui.row(
      { gap = 8 },
      nodes(
        ui.input({
          key = "search:" .. (picking and (picking.slot .. (picking.app_id or "")) or "all"),
          value = query,
          placeholder = tr("browse.search"),
          controlSize = "sm",
          flexGrow = 1,
          onChange = function(value)
            query, page = value, 1
            render()
          end,
        }),
        not picking
          and ui.select({
            key = "slot-filter",
            options = options,
            selectedIndex = slotFilter and table.find(Slots.list, slotFilter) or 0,
            controlSize = "sm",
            width = 200,
            onChange = function(value)
              local index = tonumber(value) or 0
              slotFilter, page = index > 0 and Slots.list[index] or nil, 1
              render()
            end,
          })
      )
    )
  )
  local effects = allEffects()
  if #effects == 0 then
    local key = catState == "error" and "banner.catalogue_failed" or "banner.loading"
    table.insert(out, ui.label({ text = tr(key), color = "on_surface_variant" }))
  else
    local results = Catalogue.search(effects, query, picking and picking.slot or slotFilter)
    local pages = math.max(1, math.ceil(#results / PAGE_SIZE))
    page = math.clamp(page, 1, pages)
    if #results == 0 then
      table.insert(out, ui.label({ text = tr("browse.empty"), color = "on_surface_variant" }))
    end
    for i = (page - 1) * PAGE_SIZE + 1, math.min(page * PAGE_SIZE, #results) do
      table.insert(out, effectCard(results[i]))
    end
    if pages > 1 then
      table.insert(
        out,
        ui.row({ gap = 8, align = "center", justify = "center" }, {
          ui.button({
            text = tr("browse.previous"),
            controlSize = "sm",
            enabled = page > 1,
            onClick = function()
              page -= 1
              render()
            end,
          }),
          ui.label({ text = tr("browse.page", { page = tostring(page), pages = tostring(pages) }) }),
          ui.button({
            text = tr("browse.next"),
            controlSize = "sm",
            enabled = page < pages,
            onClick = function()
              page += 1
              render()
            end,
          }),
        })
      )
    end
  end
  for _, node in ipairs(browseFooter()) do
    table.insert(out, node)
  end
  return out
end

local function familiesTab()
  if not cat then
    return { ui.label({ text = tr("banner.loading"), color = "on_surface_variant" }) }
  end
  if #cat.families == 0 then
    return { ui.label({ text = tr("families.empty"), color = "on_surface_variant" }) }
  end
  local out = {}
  for _, family in ipairs(cat.families) do
    local members = {}
    for slot, effect in pairs(Catalogue.familySlots(cat, family)) do
      table.insert(members, slotLabel(slot) .. ": " .. effect.name)
    end
    table.sort(members)
    table.insert(
      out,
      card(family.id, {
        ui.label({ text = family.name, fontWeight = "bold" }),
        ui.label({ text = family.description or "", fontSize = 12, maxLines = 3 }),
        hint(table.concat(members, " · ")),
        ui.row({ justify = "end" }, {
          ui.button({
            text = tr("families.apply"),
            variant = "primary",
            controlSize = "sm",
            enabled = canApply(),
            onClick = function()
              applyFamily(family)
            end,
          }),
        }),
      })
    )
  end
  return out
end

local function banner(text, actions)
  return ui.column({ gap = 8, padding = 10, radius = 8, border = "primary", borderWidth = 1 }, {
    ui.label({ text = text }),
    ui.row({ gap = 6, justify = "end" }, actions),
  })
end

local function banners()
  local out = {}
  if not hasUmbriel then
    table.insert(out, banner(tr("banner.no_umbriel"), {}))
  end
  if setupState ~= "present" then
    local actions = {}
    if setupState == "insert" then
      table.insert(
        actions,
        ui.button({
          text = tr("setup.add"),
          variant = "primary",
          controlSize = "sm",
          enabled = not busy,
          onClick = runSetup,
        })
      )
    end
    table.insert(
      actions,
      ui.button({
        text = tr("setup.copy"),
        controlSize = "sm",
        onClick = function()
          noctalia.copyToClipboard(Config.snippet)
          say(tr("setup.copied"))
          render()
        end,
      })
    )
    table.insert(
      actions,
      ui.button({
        text = tr("setup.check"),
        controlSize = "sm",
        variant = "ghost",
        onClick = function()
          refreshSetup()
          render()
        end,
      })
    )
    table.insert(
      out,
      banner(tr("setup.text", { path = env.paths.config }) .. "\n\n" .. Config.snippet, actions)
    )
  end
  if catState == "offline" then
    table.insert(out, banner(tr("banner.offline"), {}))
  end
  return out
end

local function header()
  return ui.row({ gap = 6, align = "center" }, {
    ui.label({
      text = tr("title"),
      fontSize = 16,
      fontWeight = "bold",
      color = "primary",
      flexGrow = 1,
    }),
    ui.button({
      text = tr("header.undo"),
      controlSize = "sm",
      variant = "ghost",
      enabled = canApply() and sel.previous ~= nil,
      onClick = function()
        local nxt = Selection.undo(sel)
        if nxt then
          commitSelection(nxt, tr("status.undone"))
        end
      end,
    }),
    ui.button({
      text = tr("header.clear_all"),
      controlSize = "sm",
      variant = "ghost",
      enabled = canApply(),
      onClick = function()
        commit(Selection.clearAll, tr("status.cleared"))
      end,
    }),
    ui.button({
      glyph = "refresh",
      tooltip = tr("header.refresh"),
      controlSize = "sm",
      variant = "ghost",
      enabled = not fetching,
      onClick = function()
        fetchCatalogue()
        render()
      end,
    }),
    ui.button({
      glyph = "x",
      tooltip = tr("header.close"),
      controlSize = "sm",
      variant = "ghost",
      onClick = function()
        panel.close()
      end,
    }),
  })
end

local function tabs()
  local function tabButton(id)
    return ui.button({
      text = tr("tabs." .. id),
      controlSize = "sm",
      variant = tab == id and "primary" or "ghost",
      onClick = function()
        tab, picking, query = id, nil, ""
        render()
      end,
    })
  end
  return ui.row({ gap = 6 }, { tabButton("slots"), tabButton("browse"), tabButton("families") })
end

render = function()
  local body
  if tab == "browse" then
    body = browseTab()
  elseif tab == "families" then
    body = familiesTab()
  else
    body = slotsTab()
  end
  local children = { header(), tabs() }
  for _, node in ipairs(banners()) do
    table.insert(children, node)
  end
  if message then
    table.insert(
      children,
      ui.label({
        text = message,
        color = messageIsError and "error" or "on_surface_variant",
        fontSize = 12,
        maxLines = 4,
      })
    )
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 8 }, body))
  panel.render(ui.column({ gap = 10, padding = 16 }, children))
end

function onOpen()
  sel = Selection.load(env.selectionPath)
  refreshSetup()
  if not cat or Catalogue.isStale(dataDir) then
    fetchCatalogue()
  end
  render()
end
