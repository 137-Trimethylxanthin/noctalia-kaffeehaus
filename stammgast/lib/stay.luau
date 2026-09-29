--!nonstrict
-- Pure decisions for Stammgast: no systemd-inhibit, no noctalia.*, so the
-- tests can run it under plain Lua.
--
-- The service reads one snapshot per look, printed by a small shell script:
--
--   lid closed            (or `lid open`; missing when there is no lid)
--   docked 1              (logind: an external screen or a dock; 0 if not,
--                          missing when busctl failed)
--   ac 0                  (1 when on mains power)
--   bat 57                (percent, one line per battery)
--   cs {...}              (a Claude Code session file, one per session)
--   sl 1790680000 {...}   (a saved Claude status line: its mtime, its JSON)
--   cx 1790680000 {...}   (Codex's latest rate-limits event: file mtime, JSON)
--   ps                    (every line after this: pid, parent pid, CPU ticks,
--   1234 1200 5301 /home/me/.local/bin/claude          command line)
--   5678 1200 88 node /usr/lib/node_modules/@openai/codex/bin/codex.js
--
-- and turns it into what to hold: nothing, the lid switch alone, or, while the
-- lid is closed, sleep and idle as well.

local M = {}

M.DEFAULT_APPS = "claude, codex, gemini, opencode, aider, crush, goose, cursor-agent, qwen, amp, copilot"

-- Parts of a command line that mean the process is a helper, not an agent at
-- work: Claude Code's Chrome bridge runs for as long as the browser does.
M.DEFAULT_IGNORE = "--chrome-native-host"

-- Programs that run an agent's script rather than being the agent; for these
-- the script's name, or the npm package it lives in, is what counts.
local INTERPRETERS = {
  node = true, nodejs = true, bun = true, bunx = true, deno = true, npx = true, pnpx = true,
  python = true, python3 = true, uv = true, uvx = true,
}

-- Words between an interpreter and the script: `uv run aider`, `bun x codex`.
local SUBCOMMANDS = { run = true, x = true, exec = true, tool = true }

-- Modes the tile and IPC switch between, in the order a click steps through.
M.MODES = { "auto", "always", "off" }

function M.nextMode(mode)
  for i, name in ipairs(M.MODES) do
    if name == mode then
      return M.MODES[(i % #M.MODES) + 1]
    end
  end
  return "auto"
end

function M.validMode(mode)
  for _, name in ipairs(M.MODES) do
    if name == mode then
      return true
    end
  end
  return false
end

local function trim(text)
  return (string.gsub(string.gsub(text, "^%s+", ""), "%s+$", ""))
end

local function words(text)
  local out = {}
  for word in string.gmatch(text or "", "[^%s,]+") do
    table.insert(out, word)
  end
  return out
end

-- "Claude, codex  gemini,," -> { claude = true, codex = true, gemini = true }
function M.parseApps(text)
  local out = {}
  for _, word in ipairs(words(text)) do
    out[string.lower(word)] = true
  end
  return out
end

-- Comma-separated, and kept as typed apart from case: an ignore entry may
-- hold spaces ("mcp serve").
function M.parseIgnore(text)
  local out = {}
  for part in string.gmatch(text or "", "[^,]+") do
    part = string.lower(trim(part))
    if part ~= "" then
      table.insert(out, part)
    end
  end
  return out
end

local function basename(path)
  return string.match(path, "([^/]+)$") or path
end

local function stripExt(name)
  return (string.gsub(string.gsub(name, "%.[cm]?[jt]s$", ""), "%.py$", ""))
end

-- The names a command line goes by: the program itself, and for an
-- interpreter also its script and the npm package the script belongs to,
-- with any "-cli" or "-code" at the end dropped (@google/gemini-cli ->
-- gemini, @anthropic-ai/claude-code -> claude).
function M.names(args)
  local argv = words(string.gsub(args or "", ",", " "))
  local out = {}
  if #argv == 0 then
    return out
  end
  local first = string.lower(basename(argv[1]))
  table.insert(out, first)
  local interpreter = INTERPRETERS[first] or string.match(first, "^python3%.%d+$") ~= nil
  if not interpreter then
    return out
  end
  for i = 2, #argv do
    local arg = argv[i]
    if string.sub(arg, 1, 1) ~= "-" and not SUBCOMMANDS[string.lower(arg)] then
      local script = string.lower(arg)
      table.insert(out, stripExt(basename(script)))
      local package = string.match(script, "node_modules/@[^/]+/([^/]+)") or string.match(script, "node_modules/([^/@][^/]*)")
      if package then
        table.insert(out, package)
        local short = string.match(package, "^(.-)%-cli$") or string.match(package, "^(.-)%-code$")
        if short and short ~= "" then
          table.insert(out, short)
        end
      end
      break
    end
  end
  return out
end

-- The agent a command line is, or nil.
function M.agentName(args, apps, ignore)
  local lowered = string.lower(args or "")
  for _, part in ipairs(ignore or {}) do
    if string.find(lowered, part, 1, true) then
      return nil
    end
  end
  for _, name in ipairs(M.names(args)) do
    if apps[name] then
      return name
    end
  end
  return nil
end

function M.parseSnapshot(text)
  local snap = { lid = nil, docked = nil, ac = nil, battery = nil, procs = {},
    claudeSessions = {}, statusLines = {}, codex = nil }
  local inPs = false
  for line in string.gmatch(text or "", "[^\n]+") do
    if inPs then
      local pid, ppid, ticks, args = string.match(line, "^%s*(%d+)%s+(%d+)%s+(%d+)%s+(.-)%s*$")
      if pid then
        table.insert(snap.procs, { pid = tonumber(pid), ppid = tonumber(ppid), ticks = tonumber(ticks), args = args })
      else
        local bare, rest = string.match(line, "^%s*(%d+)%s+(.-)%s*$")
        if bare then
          table.insert(snap.procs, { pid = tonumber(bare), args = rest })
        end
      end
    elseif line == "ps" then
      inPs = true
    elseif string.sub(line, 1, 3) == "cs " then
      table.insert(snap.claudeSessions, string.sub(line, 4))
    elseif string.sub(line, 1, 3) == "sl " then
      local mtime, json = string.match(line, "^sl (%d+) (.*)$")
      if mtime then
        table.insert(snap.statusLines, { mtime = tonumber(mtime), json = json })
      end
    elseif string.sub(line, 1, 3) == "cx " then
      local mtime, json = string.match(line, "^cx (%d+) (.*)$")
      if mtime then
        snap.codex = { mtime = tonumber(mtime), json = json }
      end
    else
      local key, value = string.match(line, "^(%a+)%s+(%S+)")
      if key == "lid" then
        if value == "closed" then
          snap.lid = true
        elseif value == "open" then
          snap.lid = false
        end
      elseif key == "docked" then
        if value == "1" then
          snap.docked = true
        elseif value == "0" then
          snap.docked = false
        end
      elseif key == "ac" then
        snap.ac = snap.ac == true or value == "1"
      elseif key == "bat" then
        -- With two batteries, the lower one decides.
        local percent = tonumber(value)
        if percent and (snap.battery == nil or percent < snap.battery) then
          snap.battery = percent
        end
      end
    end
  end
  return snap
end

-- The running agents, by name, sorted, each once.
function M.findAgents(procs, apps, ignore)
  local seen, out = {}, {}
  for _, proc in ipairs(procs or {}) do
    local name = M.agentName(proc.args, apps, ignore)
    if name and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

-- Below this it always lets go, whatever the setting: a held sleep lock
-- would also block UPower's own action at a critical battery.
M.MIN_FLOOR = 5

-- Whether the battery is too low to go on, with 5 points of slack before
-- holding again, so a battery hovering at the floor does not flip it back and
-- forth. `low` is the previous answer. Mains power always clears it.
function M.batteryLow(battery, ac, floor, low)
  if ac == true or battery == nil then
    return false
  end
  floor = math.max(M.MIN_FLOOR, floor or M.MIN_FLOOR)
  if low then
    return battery < floor + 5
  end
  return battery <= floor
end

-- { mode, agents, lid, docked, low } -> "none" | "lid" | "deep"
--   lid   the lid switch is blocked: closing it does nothing
--   deep  the lid is closed, so sleep and idle are blocked too, or the idle
--         timer would suspend the laptop in the bag. Not when docked: then
--         someone is at the external screen, and idle and suspend are theirs
function M.decide(input)
  local mode = input.mode or "auto"
  if mode == "off" or input.low then
    return "none"
  end
  if mode ~= "always" and #(input.agents or {}) == 0 then
    return "none"
  end
  if input.lid == true and not input.docked then
    return "deep"
  end
  return "lid"
end

function M.inhibitWhat(hold)
  if hold == "deep" then
    return "handle-lid-switch:sleep:idle"
  elseif hold == "lid" then
    return "handle-lid-switch"
  end
  return nil
end

return M
