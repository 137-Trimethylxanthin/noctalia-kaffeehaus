--!nonstrict
-- Pure agent details for Stammgast's bar icon and desktop widget: which agents
-- run, what each is doing, and the usage limits they report. No noctalia.*,
-- so the tests can run it under plain Lua; JSON decoding is passed in.
--
-- States, most urgent first:
--   waiting  the agent needs you (a permission prompt, a question)
--   busy     it is working
--   idle     it is open, at its prompt
-- Claude Code says which in its session file (~/.claude/sessions/<pid>.json);
-- for every other agent, CPU use decides between busy and idle.

local M = {}

-- How each agent is shown. `image` is a file in icons/, `glyph` a Tabler icon.
M.KINDS = {
  claude = { label = "Claude Code", image = "claude" },
  codex = { label = "Codex", glyph = "brand-openai" },
  copilot = { label = "Copilot", glyph = "brand-github-copilot" },
  gemini = { label = "Gemini", glyph = "brand-google" },
}
M.GENERIC_GLYPH = "sparkles"

local RANK = { waiting = 3, busy = 2, idle = 1 }

-- Claude Code's session statuses; "blocked" is a prompt it cannot pass alone.
local CLAUDE_STATES = { busy = "busy", waiting = "waiting", blocked = "waiting", idle = "idle" }

-- CPU share (of one core) above which an agent without a session file counts
-- as working. Tool runs are the agent's children, so this is its own thinking,
-- streaming and rendering, which idles near zero at a prompt.
M.BUSY_SHARE = 0.03

function M.kindOf(name)
  if M.KINDS[name] then
    return name
  end
  return "other"
end

function M.label(name)
  local kind = M.KINDS[name]
  if kind then
    return kind.label
  end
  return (string.gsub(name or "", "^%l", string.upper))
end

local function basename(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return string.match(path, "([^/]+)/*$") or path
end

local function ms(value)
  value = tonumber(value)
  if value == nil then
    return nil
  end
  -- Seconds and milliseconds both show up; anything before 2001 in ms is s.
  if value < 1e12 then
    return value * 1000
  end
  return value
end

local function percent(value)
  value = tonumber(value)
  if value == nil then
    return nil
  end
  return math.max(0, math.min(1, value / 100))
end

-- Claude session files by pid, and saved status lines by session id.
function M.claudeIndex(rawSessions, rawLines, decode)
  local sessions, lines = {}, {}
  for _, raw in ipairs(rawSessions or {}) do
    local ok, value = pcall(decode, raw)
    if ok and type(value) == "table" and tonumber(value.pid) then
      sessions[tonumber(value.pid)] = value
    end
  end
  local newest = nil
  for _, entry in ipairs(rawLines or {}) do
    local ok, value = pcall(decode, entry.json)
    if ok and type(value) == "table" then
      value._mtime = entry.mtime
      if type(value.session_id) == "string" then
        lines[value.session_id] = value
      end
      if value.rate_limits ~= nil and (newest == nil or (entry.mtime or 0) > (newest._mtime or 0)) then
        newest = value
      end
    end
  end
  return sessions, lines, newest
end

-- procs: { pid, ppid, ticks, name } for agent processes only.
-- prev:  { [pid] = { ticks, at } } from the last look; returned updated.
-- since: { [key] = { state, at } } state-change times; returned updated.
-- Returns the agents, most urgent first, and the new prev and since.
function M.build(input)
  local now = input.now
  local procs = input.procs or {}
  local sessions = input.sessions or {}
  local lines = input.lines or {}
  local prev = input.prev or {}
  local since = input.since or {}

  -- A wrapper and the program it starts (node codex.js and the codex binary)
  -- are one agent: children of an agent of the same name fold into it.
  local byPid = {}
  for _, proc in ipairs(procs) do
    byPid[proc.pid] = proc
  end
  local function root(proc)
    local seen = 0
    while proc.ppid and byPid[proc.ppid] and byPid[proc.ppid].name == proc.name and seen < 8 do
      proc = byPid[proc.ppid]
      seen += 1
    end
    return proc
  end
  local groups, order = {}, {}
  for _, proc in ipairs(procs) do
    local top = root(proc)
    local group = groups[top.pid]
    if group == nil then
      group = { proc = top, ticks = 0, pids = {} }
      groups[top.pid] = group
      table.insert(order, top.pid)
    end
    group.ticks += (proc.ticks or 0)
    table.insert(group.pids, proc.pid)
  end

  local nextPrev, nextSince, out = {}, {}, {}
  for _, pid in ipairs(order) do
    local group = groups[pid]
    local proc = group.proc
    local kind = M.kindOf(proc.name)
    local agent = {
      key = proc.name .. ":" .. pid,
      pid = pid,
      name = proc.name,
      kind = kind,
      label = M.label(proc.name),
    }

    local before = prev[pid]
    nextPrev[pid] = { ticks = group.ticks, at = now }
    local cpuBusy = nil
    if before ~= nil and now > before.at then
      local seconds = (now - before.at) / 1000
      -- Ticks are 1/100 s.
      cpuBusy = (group.ticks - before.ticks) / 100 / seconds >= M.BUSY_SHARE
    end

    -- The session file names the process that runs Claude, which may be a
    -- child of the one that matched first (a shell script starting node).
    local session = nil
    if kind == "claude" then
      for _, member in ipairs(group.pids) do
        session = session or sessions[member]
      end
    end
    if session ~= nil then
      agent.state = CLAUDE_STATES[session.status] or "idle"
      agent.project = basename(session.cwd)
      agent.session = type(session.name) == "string" and session.name or nil
      agent.startedAt = ms(session.startedAt)
      agent.stateAt = ms(session.statusUpdatedAt)
      local line = type(session.sessionId) == "string" and lines[session.sessionId] or nil
      if line ~= nil then
        if type(line.model) == "table" and type(line.model.display_name) == "string" then
          agent.model = line.model.display_name
        end
        if type(line.context_window) == "table" then
          agent.context = percent(line.context_window.used_percentage)
        end
        if type(line.cost) == "table" then
          agent.cost = tonumber(line.cost.total_cost_usd)
        end
      end
    elseif cpuBusy == true then
      agent.state = "busy"
    else
      agent.state = "idle"
    end

    -- When the state last changed, if the agent does not say itself.
    local was = since[agent.key]
    if was ~= nil and was.state == agent.state then
      nextSince[agent.key] = was
    else
      nextSince[agent.key] = { state = agent.state, at = (was == nil and agent.stateAt) or now }
    end
    agent.stateAt = agent.stateAt or nextSince[agent.key].at
    table.insert(out, agent)
  end

  table.sort(out, function(a, b)
    if RANK[a.state] ~= RANK[b.state] then
      return RANK[a.state] > RANK[b.state]
    end
    if (a.stateAt or 0) ~= (b.stateAt or 0) then
      return (a.stateAt or 0) > (b.stateAt or 0)
    end
    return a.pid < b.pid
  end)
  return out, nextPrev, nextSince
end

-- Limits older than this are not shown at all.
M.LIMITS_MAX_AGE = 7 * 24 * 3600 * 1000

local function window(entry, usedKey, now)
  if type(entry) ~= "table" then
    return nil
  end
  local used = percent(entry[usedKey])
  if used == nil then
    return nil
  end
  local resetsAt = ms(entry.resets_at)
  if resetsAt == nil and tonumber(entry.resets_in_seconds) and entry._at then
    resetsAt = entry._at + tonumber(entry.resets_in_seconds) * 1000
  end
  -- Read before the window reset: whatever it said is used up and gone.
  if resetsAt ~= nil and resetsAt <= now then
    return { used = 0, reset = true }
  end
  return { used = used, resetsAt = resetsAt }
end

-- Usage limits: Claude's from the newest saved status line, Codex's from its
-- latest rate-limits event. Each is { session = {used, resetsAt}, week = ... }
-- (used 0..1, resetsAt in ms), or nil when unknown.
function M.limits(claudeLine, rawCodex, decode, now)
  local out = {}
  if type(claudeLine) == "table" and type(claudeLine.rate_limits) == "table" then
    local limits = claudeLine.rate_limits
    local claude = {
      session = window(limits.five_hour, "used_percentage", now),
      week = window(limits.seven_day, "used_percentage", now),
      at = claudeLine._mtime and claudeLine._mtime * 1000 or nil,
    }
    local fresh = claude.at == nil or now - claude.at <= M.LIMITS_MAX_AGE
    if fresh and (claude.session or claude.week) then
      out.claude = claude
    end
  end
  if type(rawCodex) == "table" and type(rawCodex.json) == "string" then
    local ok, value = pcall(decode, rawCodex.json)
    if ok and type(value) == "table" then
      local payload = type(value.payload) == "table" and value.payload or value
      local limits = payload.rate_limits
      if type(limits) == "table" then
        -- resets_in_seconds counts from when Codex wrote the line.
        local at = rawCodex.mtime and rawCodex.mtime * 1000 or now
        for _, key in ipairs({ "primary", "secondary" }) do
          if type(limits[key]) == "table" then
            limits[key]._at = at
          end
        end
        -- Which window is which goes by its length: primary is usually the
        -- 5-hour one and secondary the week, but a plan may report only one.
        local codex = { at = at }
        for _, key in ipairs({ "primary", "secondary" }) do
          local entry = limits[key]
          local minutes = type(entry) == "table" and tonumber(entry.window_minutes) or nil
          local slot = nil
          if minutes ~= nil then
            slot = minutes >= 24 * 60 and "week" or "session"
          else
            slot = key == "primary" and "session" or "week"
          end
          if codex[slot] == nil then
            codex[slot] = window(entry, "used_percent", now)
          end
        end
        if now - at <= M.LIMITS_MAX_AGE and (codex.session or codex.week) then
          out.codex = codex
        end
      end
    end
  end
  return out
end

-- The agent the bar shows: the most urgent (build() sorted them).
function M.primary(agents)
  return agents and agents[1] or nil
end

return M
