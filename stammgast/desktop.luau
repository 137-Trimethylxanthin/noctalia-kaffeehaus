--!nonstrict
-- [[desktop_widget]]: a card for the desktop or the lock screen. Every running
-- agent with its icon, what it is doing and for how long, its project and, for
-- Claude Code with the status line set up, model, context and cost; below,
-- the usage limits Claude and Codex report; on top, whether the lid is held.
-- Two widget settings trim it for the lock screen: projects and limits.

local look = require("./lib/look.luau")

local status = noctalia.state.get("status") or {}

local MAX_AGENTS = 4

local function setting(key)
  return noctalia.getConfig(key) ~= false
end

local function header()
  local chip
  if status.low then
    chip = noctalia.tr("desktop.battery_low")
  elseif status.holding then
    chip = noctalia.tr("desktop.lid_held")
  elseif status.mode == "off" then
    chip = noctalia.tr("mode.off")
  else
    chip = noctalia.tr("desktop.lid_free")
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.glyph({ name = if status.mode == "off" then "coffee-off" else "coffee", size = 18, color = "primary" }),
    ui.label({ text = noctalia.tr("title"), fontSize = 15, fontWeight = "bold" }),
    ui.spacer({ flexGrow = 1 }),
    ui.row({ paddingH = 8, paddingV = 3, radius = 10, fill = if status.holding then "primary/0.18" else "surface_variant" }, {
      ui.label({ text = chip, fontSize = 11, color = if status.holding then "primary" else "on_surface_variant" }),
    }),
  })
end

local function agentRow(agent, now, details)
  local text = { ui.label({ text = agent.label, fontSize = 14, fontWeight = "bold", maxLines = 1 }) }
  local where = details and look.where(agent) or nil
  if where then
    table.insert(text, ui.label({ text = where, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  local extras = details and look.extras(agent) or nil
  if extras then
    table.insert(text, ui.label({ text = extras, fontSize = 11, color = "on_surface_variant", maxLines = 1 }))
  end
  return ui.row({ gap = 10, align = "center" }, {
    look.icon(agent, 28),
    ui.column({ gap = 1, flexGrow = 1 }, text),
    ui.row({ gap = 5, align = "center" }, {
      look.dot(agent.state, 7),
      ui.label({ text = look.stateLine(agent, now), fontSize = 12, color = look.STATE_COLOR[agent.state] }),
    }),
  })
end

local function limitRow(label, window, now)
  local used = window.used or 0
  local text = math.floor(used * 100 + 0.5) .. " %"
  if window.reset then
    text = noctalia.tr("limits.reset")
  elseif window.resetsAt and window.resetsAt > now then
    text = text .. " · " .. noctalia.tr("limits.resets", { t = look.duration(window.resetsAt - now) })
  end
  return ui.row({ gap = 8, align = "center" }, {
    ui.row({ minWidth = 64 }, { ui.label({ text = label, fontSize = 11, color = "on_surface_variant" }) }),
    ui.progress({ progress = used, height = 6, radius = 3, flexGrow = 1,
      fill = if used >= 0.9 then "error" elseif used >= 0.7 then "tertiary" else "primary" }),
    ui.label({ text = text, fontSize = 11, color = "on_surface_variant" }),
  })
end

local function limitsBlock(now)
  local rows = {}
  for _, entry in ipairs({ { key = "claude", title = "Claude" }, { key = "codex", title = "Codex" } }) do
    local limits = (status.limits or {})[entry.key]
    if limits then
      table.insert(rows, ui.label({ text = noctalia.tr("limits.title", { agent = entry.title }), fontSize = 12, fontWeight = "bold" }))
      if limits.session then
        table.insert(rows, limitRow(noctalia.tr("limits.session"), limits.session, now))
      end
      if limits.week then
        table.insert(rows, limitRow(noctalia.tr("limits.week"), limits.week, now))
      end
    end
  end
  return rows
end

local function render()
  local now = noctalia.nowMs()
  local agents = status.agents or {}
  local details = setting("show_projects")
  local body = { header() }

  if #agents == 0 then
    table.insert(body, ui.label({ text = noctalia.tr("desktop.none"), fontSize = 13, color = "on_surface_variant" }))
  else
    for i, agent in ipairs(agents) do
      if i > MAX_AGENTS then
        table.insert(body, ui.label({ text = noctalia.tr("desktop.more", { n = #agents - MAX_AGENTS }), fontSize = 11, color = "on_surface_variant" }))
        break
      end
      table.insert(body, agentRow(agent, now, details))
    end
  end

  if setting("show_limits") then
    local limits = limitsBlock(now)
    if #limits > 0 then
      table.insert(body, ui.separator({ spacing = 2 }))
      for _, row in ipairs(limits) do
        table.insert(body, row)
      end
    end
  end

  desktopWidget.render(ui.column({ gap = 10, padding = 16, radius = 16, fill = "surface/0.85", minWidth = 320 }, body))
end

noctalia.state.watch("status", function(value)
  status = value or {}
  render()
end)

-- The times ("for 3 min", "resets in 2 h") move on without news.
noctalia.setUpdateInterval(30000)
function update()
  render()
end

render()
