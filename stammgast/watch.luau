--!nonstrict
-- [[service]]: keeps the laptop working with the lid closed while an AI agent
-- is running.
--
-- logind suspends on a closed lid unless someone holds a `handle-lid-switch`
-- inhibitor, which any user in the active session may take. So while an agent
-- such as Claude Code or Codex runs, this holds one through
-- `systemd-inhibit`. Once the lid is closed it also blocks sleep and idle, or
-- the idle timer would still suspend the laptop in the bag, and it locks the
-- screen and turns it off. With the lid open, idle and a manual suspend work
-- as before.
--
-- When the last agent exits, or the battery reaches its floor, it lets go. If
-- the lid is still closed then, logind carries out its lid action (normally
-- suspend); if it has not after a few seconds, this does it, so a laptop never
-- stays awake in a bag with nothing to do.
--
-- lib/stay decides; this file only looks and acts.
--
--   noctalia msg plugin 137-trimethylxanthin/stammgast:watch all toggle   # auto -> always -> off
--   noctalia msg plugin 137-trimethylxanthin/stammgast:watch all auto
--   noctalia msg plugin 137-trimethylxanthin/stammgast:watch all always
--   noctalia msg plugin 137-trimethylxanthin/stammgast:watch all off

local stay = require("./lib/stay.luau")
local agentInfo = require("./lib/agents.luau")

local TOOLS = { "systemd-inhibit", "busctl", "ps", "awk", "pkill", "noctalia" }

local missing = {}
for _, tool in ipairs(TOOLS) do
  if not noctalia.commandExists(tool) then
    table.insert(missing, tool)
  end
end

-- ── Mode ─────────────────────────────────────────────────────────────────────
--
-- auto (hold while an agent runs), always, or off. On disk, so a restart keeps
-- what was picked.

local function modePath()
  local dir = noctalia.pluginDataDir()
  return dir and (dir .. "/mode") or nil
end

local function loadMode()
  local path = modePath()
  local raw = path and noctalia.fileExists(path) and noctalia.readFile(path)
  local mode = raw and noctalia.string.trim(raw)
  return stay.validMode(mode) and mode or "auto"
end

local mode = loadMode()

local function saveMode()
  local path = modePath()
  if path then
    noctalia.writeFile(path, mode)
  end
end

-- ── What was last seen ───────────────────────────────────────────────────────

local agents = {}
-- What the bar icon and the desktop widget show: each running agent with its
-- state (lib/agents), and the usage limits the agents report.
local details = {}
local limits = {}
local cpuPrev, stateSince = {}, {}
local lid = nil -- true closed, false open, nil unknown
local docked = false
local battery = nil
local ac = nil
local low = false

-- The hold that should be in place, and the one confirmed by the helper.
local want = "none"
local held = "none"

local function publish()
  noctalia.state.set("status", {
    mode = mode,
    holding = held ~= "none",
    hold = held,
    agents = details,
    limits = limits,
    lid = lid,
    battery = battery,
    low = low,
    available = #missing == 0,
  })
end

-- ── The inhibitor ────────────────────────────────────────────────────────────
--
-- One `systemd-inhibit` at a time, running a shell that prints a line every
-- five seconds. When Noctalia lets go of the pipe (a crash, a disable), the
-- next print fails, the shell dies of SIGPIPE, and logind drops the lock: a
-- hold can never outlive the service by more than a few seconds.
--
-- Each run ends in a tag, `stammgast-hold-<instance>-<gen>`, the last word of
-- both the systemd-inhibit and the shell command line, so pkill can stop one
-- run, or every run a service instance started, or every leftover.

local INSTANCE = tostring(noctalia.nowMs())
local startedAt = noctalia.nowMs()
local gen = 0
local runs = {} -- [gen] = hold
local confirmed = {} -- [gen] = true once it printed "held"

-- On a reload the old instance keeps its hold and says so here; this one stops
-- it once its own is in place, so a closed lid is never left unheld between
-- the two. { instances = { ... }, closedHandled, screenOff }; more than one
-- instance when a second reload comes before the first handover is done.
local handover = noctalia.state.get("handover")
noctalia.state.set("handover", nil)
if type(handover) ~= "table" or type(handover.instances) ~= "table" then
  handover = nil
end

local function tag(n)
  return "stammgast-hold-" .. INSTANCE .. "-" .. n
end

-- pkill patterns Noctalia refused to run (its command slots were full), tried
-- again on every tick: a hold nobody stops would last as long as the service.
local killQueue = {}

local function stop(pattern)
  if not noctalia.runAsync({ "pkill", "-f", "--", pattern }) then
    killQueue[pattern] = true
  end
end

local function flushKills()
  local patterns = {}
  for pattern in pairs(killQueue) do
    table.insert(patterns, pattern)
  end
  killQueue = {}
  for _, pattern in ipairs(patterns) do
    stop(pattern)
  end
end

local function stopRun(n)
  runs[n] = nil
  confirmed[n] = nil
  stop(tag(n) .. "$")
end

local function releaseHandover()
  if handover ~= nil then
    for _, instance in ipairs(handover.instances) do
      stop("stammgast-hold-" .. instance .. "-")
    end
    handover = nil
  end
end

-- A run that ends by itself (refused by logind, killed by someone else) is
-- started again by a later look, at most every 30 seconds.
local endedAt = nil
local endedCount = 0

-- Older runs waiting for the newest to hold: [gen] = when it was replaced.
-- systemd-inhibit takes a moment to get its lock, and a closed lid with no
-- lock held for that moment is a suspend, so the old one stops only once the
-- new one prints "held" (its child starts only after the lock is taken), or
-- after ten seconds if it never does.
local replacing = {}

local function stopOlder()
  for m in pairs(runs) do
    if m ~= gen then
      stopRun(m)
    end
  end
  replacing = {}
end

-- The kind of the newest older run that holds, or "none".
local function olderHeld()
  local best = nil
  for m in pairs(runs) do
    if m ~= gen and confirmed[m] and (best == nil or m > best) then
      best = m
    end
  end
  return best and runs[best] or "none"
end

local function onHoldLine(line, n)
  if runs[n] == nil then
    -- A run stopped before systemd-inhibit had even started escapes that
    -- pkill; its heartbeat gives it away, and it is stopped again.
    if line == "held" then
      stop(tag(n) .. "$")
    end
    return
  end
  if line == "held" then
    confirmed[n] = true
    if n == gen then
      if held ~= runs[n] then
        held = runs[n]
        endedCount = 0
        publish()
      end
      stopOlder()
      releaseHandover()
    end
  elseif line == "stammgast:ended" then
    runs[n] = nil
    confirmed[n] = nil
    endedAt = noctalia.nowMs()
    endedCount += 1
    -- logind refusing (a session that is not active, a polkit rule) ends
    -- every try the same way: said on the first and every tenth.
    if endedCount % 10 == 1 then
      noctalia.log("stammgast: the inhibitor ended by itself (" .. endedCount .. "x); trying again every 30 seconds")
    end
    if n == gen then
      -- An older run may still hold while this one, its replacement, failed.
      held = olderHeld()
      publish()
    end
  end
end

local function startRun(hold)
  gen += 1
  local n = gen
  local what = stay.inhibitWhat(hold)
  -- Every word here is fixed or digits, so the string is safe for the shell.
  local cmd = "systemd-inhibit --what=" .. what
    .. " --who=Stammgast --why='An AI agent is working' --mode=block"
    .. " sh -c 'while echo held; do sleep 5; done' " .. tag(n)
    .. "; echo stammgast:ended"
  runs[n] = hold
  local ok = noctalia.runStream(cmd, function(line)
    onHoldLine(noctalia.string.trim(line or ""), n)
  end)
  if not ok then
    runs[n] = nil
    noctalia.log("stammgast: could not start systemd-inhibit right now; the next look tries again")
    return false
  end
  return true
end

-- The newest run, if it is still going.
local function current()
  return runs[gen] and gen or nil
end

-- Brings the inhibitor in line with `want`. Letting go stops every run at
-- once; a new hold replaces the old one only once it holds (see `replacing`).
local function apply()
  local n = current()
  local running = n and runs[n] or "none"
  if running == want then
    return
  end
  if want == "none" then
    held = "none"
    for m in pairs(runs) do
      stopRun(m)
    end
    replacing = {}
    publish()
    return
  end
  if endedAt ~= nil and noctalia.nowMs() - endedAt < 30000 then
    return
  end
  if startRun(want) and n then
    replacing[n] = noctalia.nowMs()
  end
end

-- ── The lid ──────────────────────────────────────────────────────────────────
--
-- Closing the lid while holding locks the screen and turns it off, once per
-- closing. Opening it turns the screen back on; the lock stays. Docked, the
-- external screen is the one in use, so neither happens.

local closedHandled = handover ~= nil and handover.closedHandled == true
local screenOff = handover ~= nil and handover.screenOff == true
local lockedThisClosing = closedHandled

-- False when Noctalia's command slots are full; the next look tries again.
local function run(argv)
  return noctalia.runAsync(argv)
end

local function onLid(closed, holding)
  if closed and holding and not docked and not closedHandled then
    local done = true
    if noctalia.getConfig("lock_on_close") ~= false and not lockedThisClosing then
      lockedThisClosing = run({ "noctalia", "msg", "session", "lock" })
      done = done and lockedThisClosing
    end
    if noctalia.getConfig("screen_off_on_close") ~= false and not screenOff then
      screenOff = run({ "noctalia", "msg", "dpms-off" })
      done = done and screenOff
    end
    closedHandled = done
  elseif closed and docked and screenOff then
    -- Plugged into a screen after the lid closed: that screen is in use now.
    if run({ "noctalia", "msg", "dpms-on" }) then
      screenOff = false
      closedHandled = false -- undocked again with the lid still closed: dark again
    end
  elseif not closed then
    lockedThisClosing = false
    closedHandled = false
    if screenOff then
      screenOff = false
      run({ "noctalia", "msg", "dpms-on" })
    end
  end
end

-- After letting go with the lid still closed, logind should suspend on its
-- own. If six seconds later nothing has happened, this asks for logind's lid
-- action itself. The clock is compared against the time of release: once the
-- laptop has slept, far more time has passed and nothing is done.
local LID_ACTION = [[
bus() { busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager "$1" 2>/dev/null; }
[ "$(bus LidClosed)" = "b true" ] || exit 0
action=$(bus HandleLidSwitch | sed 's/^s "\(.*\)"$/\1/')
if [ "$(bus Docked)" = "b true" ]; then
  action=$(bus HandleLidSwitchDocked | sed 's/^s "\(.*\)"$/\1/')
elif [ "$1" = ac ]; then
  external=$(bus HandleLidSwitchExternalPower | sed 's/^s "\(.*\)"$/\1/')
  [ -n "$external" ] && action=$external
fi
case $action in
  suspend|hibernate|hybrid-sleep|suspend-then-hibernate|sleep|poweroff|halt|reboot|kexec) exec systemctl "$action" ;;
  lock) exec loginctl lock-session ;;
esac
]]

local releasedAt = nil

local function checkAfterRelease(now)
  if releasedAt == nil or now - releasedAt < 6000 then
    return
  end
  local since = now - releasedAt
  releasedAt = nil
  if since > 30000 or want ~= "none" or lid ~= true or docked then
    return
  end
  noctalia.log("stammgast: lid still closed after letting go; carrying out the lid action")
  run({ "sh", "-c", LID_ACTION, "sh", ac == true and "ac" or "battery" })
end

-- ── Looking ──────────────────────────────────────────────────────────────────

local SNAPSHOT = [[
case $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager LidClosed 2>/dev/null) in
  "b true") echo "lid closed" ;;
  "b false") echo "lid open" ;;
esac
case $(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager Docked 2>/dev/null) in
  "b true") echo "docked 1" ;;
  "b false") echo "docked 0" ;;
esac
for d in /sys/class/power_supply/*; do
  [ -r "$d/type" ] || continue
  case $(cat "$d/type") in
    Mains|USB) echo "ac $(cat "$d/online" 2>/dev/null)" ;;
    Battery) [ "$(cat "$d/scope" 2>/dev/null)" = Device ] || echo "bat $(cat "$d/capacity" 2>/dev/null)" ;;
  esac
done
# Claude Code's session files, one small JSON document per running session
# with its state (busy, idle, waiting), folder and name. Only sessions whose
# process still runs, and at most 16: a crash leaves its file behind.
claude="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
lines="${XDG_RUNTIME_DIR:-}/stammgast/claude"
live=0
for f in "$claude"/sessions/*.json; do
  [ -f "$f" ] || continue
  pid=${f##*/}; pid=${pid%.json}
  [ -d "/proc/$pid" ] || continue
  printf 'cs '; head -c 8192 "$f" | tr -d '\n'; echo
  # Its saved status line (lib/claude-statusline.sh), if the user set that up:
  # model, context and cost.
  id=$(head -c 8192 "$f" | grep -o '"sessionId" *: *"[A-Za-z0-9_-]*"' | head -n 1 | sed 's/.*"\([A-Za-z0-9_-]*\)"$/\1/')
  if [ -n "$id" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -f "$lines/$id.json" ]; then
    printf 'sl %s ' "$(stat -c %Y "$lines/$id.json")"; head -c 16384 "$lines/$id.json"; echo
  fi
  live=$((live + 1)); [ "$live" -ge 16 ] && break
done
if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$lines" ]; then
  # The usage limits are the account's: the newest status line has them, even
  # from a session that has ended. Lines older than a day go.
  newest=$(ls -t "$lines"/*.json 2>/dev/null | head -n 1)
  [ -n "$newest" ] && { printf 'sl %s ' "$(stat -c %Y "$newest")"; head -c 16384 "$newest"; echo; }
  find "$lines" -name '*.json' -mmin +1440 -exec rm -f {} + 2>/dev/null
fi
# Codex's latest rate-limits event, from its newest session log of the week.
latest=$(ls -t "${CODEX_HOME:-$HOME/.codex}"/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -n 1)
if [ -n "$latest" ] && [ -n "$(find "$latest" -mmin -10080 2>/dev/null)" ]; then
  event=$(tail -n 400 "$latest" | grep -E '"rate_limits": ?\{' | tail -n 1 | head -c 16384)
  [ -n "$event" ] && printf 'cx %s %s\n' "$(stat -c %Y "$latest")" "$event"
fi
echo ps
# Only processes with an agent's name in their first few words (the program,
# an interpreter's flags and script), cut short and capped: Luau parsing every
# process, or a browser's kilobyte-long command lines that merely mention a
# path with "claude" in it, runs past Noctalia's CPU budget for one callback.
# lib/stay then matches exactly. Each line: pid, parent pid, CPU ticks so far
# (utime + stime from /proc), command line.
ps -eo pid=,ppid=,args= | awk -v list="$1" '
BEGIN { n = split(tolower(list), names, "\n") }
{
  for (f = 3; f <= 10 && f <= NF; f++) {
    parts = split(tolower($f), part, "/")
    for (p = 1; p <= parts; p++)
      for (i = 1; i <= n; i++)
        if (names[i] != "" && index(part[p], names[i]) == 1) {
          ticks = 0; stat = ""; file = "/proc/" $1 "/stat"
          if ((getline stat < file) > 0) { sub(/^.*\) /, "", stat); split(stat, s, " "); ticks = s[12] + s[13] }
          close(file)
          args = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", args)
          print $1, $2, ticks, substr(args, 1, 480)
          if (++shown == 64) exit
          next
        }
  }
}'
]]

local looking = false
local lookStartedAt = 0
local snapFailures = 0

local function settings()
  local floor = tonumber(noctalia.getConfig("battery_floor"))
  return {
    apps = stay.parseApps(noctalia.getConfig("apps") or stay.DEFAULT_APPS),
    ignore = stay.parseIgnore(noctalia.getConfig("ignore") or stay.DEFAULT_IGNORE),
    floor = math.max(0, math.min(100, floor or 15)),
  }
end

local function sameList(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

-- A fixed-order text for a table, to tell whether anything changed: a JSON
-- encoder may walk keys in any order.
local function canonical(value)
  if type(value) ~= "table" then
    return tostring(value)
  end
  local keys = {}
  for key in pairs(value) do
    table.insert(keys, tostring(key))
  end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    local item = value[key]
    if item == nil then
      item = value[tonumber(key)]
    end
    table.insert(parts, key .. "=" .. canonical(item))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Works out what each agent is doing and the usage limits, for the widgets.
-- True when that changed, so they are only redrawn when there is news.
local lastDescribed = nil

local function describe(snap, config)
  local procs = {}
  for _, proc in ipairs(snap.procs) do
    local name = stay.agentName(proc.args, config.apps, config.ignore)
    if name then
      table.insert(procs, { pid = proc.pid, ppid = proc.ppid, ticks = proc.ticks, name = name })
    end
  end
  local decode = noctalia.json.decode
  local sessions, lines, newest = agentInfo.claudeIndex(snap.claudeSessions, snap.statusLines, decode)
  local now = noctalia.nowMs()
  details, cpuPrev, stateSince = agentInfo.build({
    procs = procs, sessions = sessions, lines = lines, prev = cpuPrev, since = stateSince, now = now,
  })
  limits = agentInfo.limits(newest, snap.codex, decode, now)
  local text = canonical({ details, limits })
  local changed = text ~= lastDescribed
  lastDescribed = text
  return changed
end

local function look()
  if #missing > 0 or looking then
    return
  end
  looking = true
  lookStartedAt = noctalia.nowMs()
  local config = settings()
  local names = {}
  for name in pairs(config.apps) do
    table.insert(names, name)
  end
  local patterns = table.concat(names, "\n")
  local accepted = noctalia.runAsync({ "sh", "-c", SNAPSHOT, "sh", patterns }, function(result)
    looking = false
    if result.exitCode ~= 0 then
      snapFailures += 1
      if snapFailures == 5 then
        noctalia.log("stammgast: cannot read the lid and process list: "
          .. noctalia.string.trim((result.stderr or "") .. (result.stdout or "")))
      end
      return
    end
    snapFailures = 0
    local snap = stay.parseSnapshot(result.stdout or "")
    local found = stay.findAgents(snap.procs, config.apps, config.ignore)
    local detailsChanged = describe(snap, config)
    -- No lid line means busctl failed this time (a laptop without a lid
    -- still says "open"), so the last reading stands.
    local newLid = snap.lid
    if newLid == nil then
      newLid = lid
    end
    local newDocked = snap.docked
    if newDocked == nil then
      newDocked = docked
    end
    local changed = not sameList(found, agents) or newLid ~= lid or snap.battery ~= battery or snap.ac ~= ac
    agents, lid, docked, battery, ac = found, newLid, newDocked, snap.battery, snap.ac
    local wasLow = low
    low = stay.batteryLow(battery, ac, config.floor, low)
    if low and not wasLow then
      noctalia.log("stammgast: battery at " .. tostring(battery) .. "%; letting go")
    end
    local before = want
    want = stay.decide({ mode = mode, agents = agents, lid = lid, docked = docked, low = low })
    if (before ~= "none" or handover ~= nil) and want == "none" and lid == true then
      releasedAt = noctalia.nowMs()
    end
    apply()
    if want == "none" then
      releaseHandover()
    end
    onLid(lid == true, want ~= "none")
    if changed or low ~= wasLow or detailsChanged then
      publish()
    end
  end, 10000)
  if not accepted then
    looking = false
  end
end

-- ── Requests ─────────────────────────────────────────────────────────────────

local function setMode(next)
  if not stay.validMode(next) or next == mode then
    return
  end
  mode = next
  saveMode()
  publish()
  look()
end

local function handle(request)
  if type(request) ~= "table" then
    return
  end
  -- Handled once: a request still in the shared state must not switch the
  -- mode again after a reload.
  noctalia.state.set("request", nil)
  if request.op == "toggle" then
    setMode(stay.nextMode(mode))
  else
    setMode(request.op)
  end
end

noctalia.state.watch("request", handle)

function onIpc(event, _payload)
  handle({ op = event })
end

function onConfigChanged()
  look()
end

-- Three seconds: the lid inhibitor is taken as soon as an agent starts, well
-- before anyone closes the lid, so only locking the screen waits for a look.
noctalia.setUpdateInterval(3000)
function update()
  if #missing > 0 then
    return
  end
  local now = noctalia.nowMs()
  flushKills()
  -- A replacement slow to hold (the newest run, still going) lets the old one
  -- go after ten seconds; a replacement that failed keeps it until the next.
  for m, since in pairs(replacing) do
    if now - since > 10000 and runs[gen] ~= nil then
      replacing[m] = nil
      if runs[m] then
        stopRun(m)
      end
    end
  end
  if looking and now - lookStartedAt > 15000 then
    noctalia.log("stammgast: a look never finished; starting over")
    looking = false
  end
  -- The new hold never came (refused, slots full): the old one goes anyway.
  if handover ~= nil and now - startedAt > 15000 then
    releaseHandover()
  end
  checkAfterRelease(now)
  look()
end

-- Let go on the way out. On a reload the hold stays until the next instance
-- has its own (see `handover`), along with what was done for this closing.
-- Fire-and-forget, as the service is gone before it runs; the pipe closing
-- ends the hold anyway.
function onExit(_signal, reason)
  if reason == "reload" then
    local instances = { INSTANCE }
    for _, instance in ipairs(handover and handover.instances or {}) do
      table.insert(instances, instance)
    end
    noctalia.state.set("handover", { instances = instances, closedHandled = closedHandled, screenOff = screenOff })
    return
  end
  stop("stammgast-hold-" .. INSTANCE .. "-")
  if screenOff then
    run({ "noctalia", "msg", "dpms-on" })
  end
end

-- The optional Claude Code status line (see lib/claude-statusline.sh), kept
-- at a path that does not depend on where the plugin was installed from.
local function installStatusLine()
  local dir, data = noctalia.pluginDir(), noctalia.pluginDataDir()
  if dir == nil or data == nil then
    return
  end
  local source = noctalia.readFile(dir .. "/lib/claude-statusline.sh")
  local target = data .. "/claude-statusline.sh"
  if source and (not noctalia.fileExists(target) or noctalia.readFile(target) ~= source) then
    noctalia.writeFile(target, source)
  end
end

installStatusLine()

if #missing > 0 then
  noctalia.log("stammgast: needs " .. table.concat(missing, ", ") .. "; staying idle")
  noctalia.notifyError(noctalia.tr("title"), noctalia.tr("missing", { tools = table.concat(missing, ", ") }))
elseif handover ~= nil then
  look()
else
  -- Holds a crashed instance left behind; the first look starts only after.
  looking = true
  lookStartedAt = noctalia.nowMs()
  local function first()
    looking = false
    look()
  end
  if not noctalia.runAsync({ "pkill", "-f", "--", "stammgast-hold-[0-9]" }, first) then
    first()
  end
end

publish()
