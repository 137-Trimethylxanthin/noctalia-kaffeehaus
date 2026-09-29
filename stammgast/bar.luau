--!nonstrict
-- [[widget]]: Stammgast in the bar. Shows the agent that matters most right
-- now (one waiting for you, else one at work, else one at its prompt) with a
-- dot for its state, pulsing while it works, and how many run if more than
-- one. With no agent, a coffee cup: Stammgast is there and watching. The
-- tooltip lists every agent and whether the lid is held. Click steps through
-- auto -> always -> off, like the tile.

local look = require("./lib/look.luau")

local ICON = 18
local status = noctalia.state.get("status") or {}
local pulse = false

local function tooltip(agents, now)
  local rows = {}
  for _, agent in ipairs(agents) do
    local value = look.stateLine(agent, now)
    local where = look.where(agent)
    if where then
      value = value .. " · " .. where
    end
    table.insert(rows, { key = agent.label, value = value })
  end
  if #agents == 0 then
    table.insert(rows, { key = noctalia.tr("title"), value = noctalia.tr("bar.none") })
  end
  local lid = if status.holding then noctalia.tr("bar.lid_held") else noctalia.tr("bar.lid_free")
  table.insert(rows, { key = noctalia.tr("bar.lid"), value = lid })
  table.insert(rows, { key = noctalia.tr("bar.mode"), value = noctalia.tr("mode." .. (status.mode or "auto")) })
  if status.low then
    table.insert(rows, { key = noctalia.tr("bar.battery"), value = noctalia.tr("bar.battery_low") })
  end
  return rows
end

local function render()
  local agents = status.agents or {}
  local top = agents[1]
  local now = noctalia.nowMs()
  local children
  if top == nil then
    local name = if status.mode == "off" then "coffee-off" else "coffee"
    local color = if status.holding then "primary" else "on_surface_variant"
    children = { ui.glyph({ name = name, size = ICON, color = color }) }
  else
    local dotOpacity = if top.state == "busy" and pulse then 0.35 else 1
    children = { look.icon(top, ICON), look.dot(top.state, 6, dotOpacity) }
    if #agents > 1 then
      table.insert(children, ui.label({ text = tostring(#agents), fontSize = 11, fontWeight = "bold" }))
    end
  end
  if barWidget.isVertical() then
    barWidget.render(ui.column({ gap = 3, align = "center" }, children))
  else
    barWidget.render(ui.row({ gap = 4, align = "center" }, children))
  end
  barWidget.setTooltip(tooltip(agents, now))
end

-- Pulse only while an agent works; otherwise redraw now and then, for the
-- times in the tooltip.
local function pace()
  local top = (status.agents or {})[1]
  noctalia.setUpdateInterval(if top ~= nil and top.state == "busy" then 700 else 15000)
end

noctalia.state.watch("status", function(value)
  status = value or {}
  pace()
  render()
end)

function update()
  pulse = not pulse
  render()
end

function onClick()
  noctalia.state.set("request", { op = "toggle", n = noctalia.nowMs() })
end

function onRightClick()
  noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", "137-trimethylxanthin/stammgast" })
end

pace()
render()
