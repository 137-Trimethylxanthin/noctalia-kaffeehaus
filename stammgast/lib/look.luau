--!nonstrict
-- How Stammgast's widgets draw an agent: its icon, its state's colour and
-- words, and short times. Shared by the bar icon and the desktop widget; only
-- ui.* and noctalia.tr, and all the data comes from the service's "status".

local M = {}

-- Colour roles per state. Waiting stands out: the agent needs you.
M.STATE_COLOR = {
  waiting = "tertiary",
  busy = "primary",
  idle = "on_surface_variant",
}

-- `aspect` is width over height, for images that are not square.
local KINDS = {
  claude = { image = "claude", aspect = 1.6 },
  codex = { glyph = "brand-openai" },
  copilot = { glyph = "brand-github-copilot" },
  gemini = { glyph = "brand-google" },
}

-- The icon for an agent: Claude Code's mascot, another agent's logo, or a
-- generic sparkle. Faded while idle.
function M.icon(agent, size)
  local kind = KINDS[agent and agent.kind or ""] or {}
  local opacity = (agent == nil or agent.state == "idle") and 0.6 or 1
  if kind.image then
    local dir = noctalia.pluginDir()
    if dir then
      -- A wide image as tall as a glyph would be looks small: a little taller.
      local height = math.floor(size * 0.85 + 0.5)
      local width = math.floor(height * (kind.aspect or 1) + 0.5)
      return ui.image({ path = dir .. "/icons/" .. kind.image .. ".svg", width = width, height = height, opacity = opacity })
    end
  end
  return ui.glyph({
    name = kind.glyph or "sparkles",
    size = size,
    color = M.STATE_COLOR[agent and agent.state or "idle"] or "on_surface",
    opacity = opacity,
  })
end

function M.dot(state, size, opacity)
  return ui.box({
    width = size,
    height = size,
    radius = size / 2,
    fill = M.STATE_COLOR[state] or "outline",
    opacity = opacity or 1,
  })
end

function M.stateText(state)
  return noctalia.tr("state." .. (state or "idle"))
end

-- 45 s -> "now", 3 min -> "3 min", 2 h 5 min -> "2 h 5 min", 3 days -> "3 d".
function M.duration(ms)
  if ms == nil or ms < 0 then
    return ""
  end
  local minutes = math.floor(ms / 60000)
  if minutes < 1 then
    return noctalia.tr("time.now")
  elseif minutes < 60 then
    return noctalia.tr("time.minutes", { n = minutes })
  end
  local hours = math.floor(minutes / 60)
  if hours < 24 then
    local rest = minutes % 60
    if rest == 0 then
      return noctalia.tr("time.hours", { n = hours })
    end
    return noctalia.tr("time.hours_minutes", { h = hours, m = rest })
  end
  return noctalia.tr("time.days", { n = math.floor(hours / 24) })
end

-- "Active for 3 min", "Waiting for you · 1 min".
function M.stateLine(agent, now)
  local text = M.stateText(agent.state)
  if agent.stateAt and now >= agent.stateAt then
    return text .. " · " .. M.duration(now - agent.stateAt)
  end
  return text
end

-- "kaffeehaus · kaffeehaus-88", or just the project, or nil.
function M.where(agent)
  local parts = {}
  if agent.project then
    table.insert(parts, agent.project)
  end
  if agent.session and agent.session ~= agent.project then
    table.insert(parts, agent.session)
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " · ")
end

-- "Opus 5.5 · context 42 % · $1.25", from what Claude's status line reports.
function M.extras(agent)
  local parts = {}
  if agent.model then
    table.insert(parts, agent.model)
  end
  if agent.context then
    table.insert(parts, noctalia.tr("detail.context", { n = math.floor(agent.context * 100 + 0.5) }))
  end
  if agent.cost then
    table.insert(parts, string.format("$%.2f", agent.cost))
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, " · ")
end

return M
