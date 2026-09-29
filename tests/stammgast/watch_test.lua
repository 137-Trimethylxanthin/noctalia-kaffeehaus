-- Runs watch.luau against a fake Noctalia host: commands are recorded and
-- answered by the test, the clock is the test's, and the inhibitor streams
-- are fake. It checks the order of what the service does across the lid, the
-- agents, the battery, modes, failures and reloads, not systemd itself.

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

-- ── The fake host ────────────────────────────────────────────────────────────

local H -- the current host

local function newHost(opts)
  opts = opts or {}
  local h = {
    now = opts.now or 1000000,
    files = opts.files or {},
    state = opts.state or {},
    watchers = {},
    config = opts.config or {},
    calls = {},      -- every runAsync: { argv = ..., cb = ..., done = false }
    streams = {},    -- every runStream: { cmd = ..., cb = ..., tag = ... }
    logs = {},
    refuse = false,  -- runAsync refuses (command slots full)
  }
  local noctalia = {}
  noctalia.commandExists = function() return true end
  noctalia.pluginDataDir = function() return "/data" end
  noctalia.fileExists = function(p) return h.files[p] ~= nil end
  noctalia.readFile = function(p) return h.files[p] end
  noctalia.writeFile = function(p, t) h.files[p] = t end
  noctalia.removeFile = function(p) h.files[p] = nil end
  noctalia.nowMs = function() return h.now end
  noctalia.log = function(m) table.insert(h.logs, m) end
  noctalia.notifyError = function() end
  noctalia.tr = function(k) return k end
  noctalia.getConfig = function(k) return h.config[k] end
  noctalia.setUpdateInterval = function() end
  noctalia.string = { trim = function(s) return (string.gsub(string.gsub(s, "^%s+", ""), "%s+$", "")) end }
  noctalia.pluginDir = function() return nil end
  local json = require("json")
  local function encode(v)
    if type(v) ~= "table" then return tostring(v) end
    local keys = {}
    for k in pairs(v) do table.insert(keys, tostring(k)) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
      local val = v[k]; if val == nil then val = v[tonumber(k)] end
      table.insert(out, k .. "=" .. encode(val))
    end
    return "{" .. table.concat(out, ",") .. "}"
  end
  noctalia.json = { decode = json.decode, encode = encode }
  noctalia.state = {
    set = function(k, v)
      h.state[k] = v
      for _, fn in ipairs(h.watchers[k] or {}) do fn(v) end
    end,
    get = function(k) return h.state[k] end,
    watch = function(k, fn)
      h.watchers[k] = h.watchers[k] or {}
      table.insert(h.watchers[k], fn)
    end,
  }
  noctalia.runAsync = function(argv, cb)
    if h.refuse then return false end
    table.insert(h.calls, { argv = argv, cb = cb, done = false })
    return true
  end
  noctalia.runStream = function(cmd, cb)
    table.insert(h.streams, { cmd = cmd, cb = cb, tag = string.match(cmd, "(stammgast%-hold%-%d+%-%d+);"), alive = true })
    return true
  end
  h.noctalia = noctalia
  return h
end

local function load(h)
  H = h
  _G.noctalia = h.noctalia
  _G.update, _G.onIpc, _G.onExit, _G.onConfigChanged = nil, nil, nil, nil
  package.loaded["lib.stay"] = nil
  local chunk = assert(loadfile("lib/watch.lua"))
  chunk()
  h.update, h.onIpc, h.onExit, h.onConfigChanged = _G.update, _G.onIpc, _G.onExit, _G.onConfigChanged
  return h
end

-- Calls not yet answered whose argv matches.
local function pending(pred)
  local out = {}
  for _, c in ipairs(H.calls) do
    if not c.done and pred(c.argv) then table.insert(out, c) end
  end
  return out
end

local function isSnapshot(a) return a[1] == "sh" and string.find(a[3] or "", "echo ps", 1, true) ~= nil end
local function isPkill(a) return a[1] == "pkill" end
local function isLidAction(a) return a[1] == "sh" and string.find(a[3] or "", "HandleLidSwitch", 1, true) ~= nil end
local function isMsg(what) return function(a) return a[1] == "noctalia" and table.concat(a, " ", 3) == what end end

local function count(pred)
  local n = 0
  for _, c in ipairs(H.calls) do if pred(c.argv) then n = n + 1 end end
  return n
end

-- What the service's pkill -f patterns match: every hold, one instance's
-- holds, or one run.
local function matches(tag, pattern)
  if pattern == "stammgast-hold-[0-9]" then return true end
  local exact = string.match(pattern, "^(.*)%$$")
  if exact then return tag == exact end
  return string.sub(tag, 1, #pattern) == pattern
end

-- Answers every pkill: the streams it matches die, as pkill -f would do.
local function answerPkills()
  for _, c in ipairs(pending(isPkill)) do
    c.done = true
    for _, s in ipairs(H.streams) do
      if s.alive and s.tag and matches(s.tag, c.argv[4]) then
        s.alive = false
        s.cb("stammgast:ended")
      end
    end
    if c.cb then c.cb({ exitCode = 0, stdout = "", stderr = "" }) end
  end
end

local function snapshotText(t)
  local lines = {}
  if t.lid ~= nil then table.insert(lines, t.lid and "lid closed" or "lid open") end
  if t.docked ~= nil then table.insert(lines, t.docked and "docked 1" or "docked 0") end
  if t.ac ~= nil then table.insert(lines, "ac " .. (t.ac and "1" or "0")) end
  if t.bat then table.insert(lines, "bat " .. t.bat) end
  for _, raw in ipairs(t.extra or {}) do table.insert(lines, raw) end
  table.insert(lines, "ps")
  for i, args in ipairs(t.procs or {}) do table.insert(lines, " " .. (100 + i) .. " " .. args) end
  return table.concat(lines, "\n") .. "\n"
end

-- Answers the pending look with this world.
local function world(t)
  local looks = pending(isSnapshot)
  for _, c in ipairs(looks) do
    c.done = true
    c.cb({ exitCode = t.fail and 1 or 0, stdout = t.fail and "" or snapshotText(t), stderr = "" })
  end
  answerPkills()
  return #looks
end

-- The live inhibitor streams, and their --what.
local function alive()
  local out = {}
  for _, s in ipairs(H.streams) do if s.alive then table.insert(out, s) end end
  return out
end
local function what(s) return s and string.match(s.cmd, "%-%-what=(%S+)") end

-- The newest live stream says it holds.
local function confirm()
  local live = alive()
  if #live > 0 then live[#live].cb("held") end
end

local function tick(ms)
  H.now = H.now + (ms or 3000)
  H.update()
end

local AGENT = { "/home/me/.local/bin/claude" }
local NONE = {}

-- ── Scenarios ────────────────────────────────────────────────────────────────

print("== start ==")
load(newHost())
check("stale holds are cleared first", #pending(isPkill) == 1 and pending(isPkill)[1].argv[4] == "stammgast-hold-[0-9]")
check("no look before that", #pending(isSnapshot) == 0)
answerPkills()
check("then it looks", #pending(isSnapshot) == 1)
check("the look filters for agent names", string.find(pending(isSnapshot)[1].argv[5], "claude", 1, true) ~= nil)

print("== no agent ==")
world({ lid = false, ac = false, bat = 80, procs = { "/usr/bin/firefox" } })
check("nothing held", #alive() == 0)
check("tile dark", H.state.status.holding == false)

print("== agent, lid open ==")
tick(); world({ lid = false, ac = false, bat = 80, procs = AGENT })
check("one hold", #alive() == 1)
check("lid switch only", what(alive()[1]) == "handle-lid-switch", what(alive()[1]))
check("not lit before logind says so", H.state.status.holding == false)
confirm()
check("lit once held", H.state.status.holding == true and H.state.status.hold == "lid")
check("agents published", H.state.status.agents[1].name == "claude" and H.state.status.agents[1].kind == "claude")
check("no lock with the lid open", count(isMsg("session lock")) == 0)
local lidStream = alive()[1]

print("== lid closes ==")
tick(); world({ lid = true, ac = false, bat = 80, procs = AGENT })
check("deep hold started", what(alive()[#alive()]) == "handle-lid-switch:sleep:idle", what(alive()[#alive()]))
check("the lid hold stays until the deep one holds", lidStream.alive == true)
confirm(); answerPkills()
check("then the lid hold stops", lidStream.alive == false and #alive() == 1)
check("locked", count(isMsg("session lock")) == 1)
check("screen off", count(isMsg("dpms-off")) == 1)
confirm()
tick(); world({ lid = true, ac = false, bat = 80, procs = AGENT })
check("locked once per closing", count(isMsg("session lock")) == 1 and count(isMsg("dpms-off")) == 1)
check("no new hold on a quiet look", #H.streams == 2)

print("== a lid reading that fails keeps the last one ==")
tick(); world({ ac = false, bat = 80, procs = AGENT })
check("screen stays off", count(isMsg("dpms-on")) == 0)
check("still deep", what(alive()[1]) == "handle-lid-switch:sleep:idle")

print("== lid opens ==")
tick(); world({ lid = false, ac = false, bat = 80, procs = AGENT })
check("screen on", count(isMsg("dpms-on")) == 1)
confirm(); answerPkills()
check("back to lid only", #alive() == 1 and what(alive()[1]) == "handle-lid-switch")

print("== agent done with the lid closed ==")
tick(); world({ lid = true, ac = false, bat = 80, procs = AGENT })
confirm()
local locks = count(isMsg("session lock"))
tick(); world({ lid = true, ac = false, bat = 80, procs = NONE })
check("let go", #alive() == 0 and H.state.status.holding == false)
check("no lid action yet", count(isLidAction) == 0)
tick(3000); world({ lid = true, ac = false, bat = 80, procs = NONE })
check("still none at 3 s", count(isLidAction) == 0)
tick(3000); world({ lid = true, ac = false, bat = 80, procs = NONE })
check("lid action at 6 s", count(isLidAction) == 1)
check("... on battery", pending(isLidAction)[1] and pending(isLidAction)[1].argv[5] == "battery")
tick(6000); world({ lid = true, ac = false, bat = 80, procs = NONE })
check("only once", count(isLidAction) == 1)
check("no lock for a closing with nothing held", count(isMsg("session lock")) == locks)

print("== released, then the lid opens in time ==")
load(newHost()); answerPkills()
world({ lid = true, ac = true, bat = 80, procs = AGENT }); confirm()
tick(); world({ lid = true, ac = true, bat = 80, procs = NONE })
tick(3000); world({ lid = false, ac = true, bat = 80, procs = NONE })
tick(3000); world({ lid = false, ac = true, bat = 80, procs = NONE })
check("no lid action with the lid open", count(isLidAction) == 0)

print("== released, docked ==")
load(newHost()); answerPkills()
world({ lid = true, docked = true, ac = true, procs = AGENT }); confirm()
check("docked: no lock", count(isMsg("session lock")) == 0)
check("docked: no screen off", count(isMsg("dpms-off")) == 0)
tick(); world({ lid = true, docked = true, ac = true, procs = NONE })
tick(6000); world({ lid = true, docked = true, ac = true, procs = NONE })
check("docked: no lid action", count(isLidAction) == 0)

print("== released, then slept ==")
load(newHost()); answerPkills()
world({ lid = true, ac = true, procs = AGENT }); confirm()
tick(); world({ lid = true, ac = true, procs = NONE })
tick(3600 * 1000); world({ lid = true, ac = true, procs = NONE })
check("after a sleep, no lid action", count(isLidAction) == 0)

print("== battery floor ==")
load(newHost()); answerPkills()
world({ lid = true, ac = false, bat = 40, procs = AGENT }); confirm()
tick(); world({ lid = true, ac = false, bat = 15, procs = AGENT })
check("at 15 % it lets go", #alive() == 0 and H.state.status.low == true)
tick(); world({ lid = true, ac = false, bat = 18, procs = AGENT })
check("still let go at 18 %", #alive() == 0)
tick(); world({ lid = true, ac = true, bat = 18, procs = AGENT })
check("mains: holds again", #alive() == 1)
H.config.battery_floor = 0
tick(); world({ lid = true, ac = false, bat = 6, procs = AGENT })

check("floor 0: holds at 6 %", #alive() >= 1)
tick(); world({ lid = true, ac = false, bat = 5, procs = AGENT })
check("floor 0: still lets go at 5 %", #alive() == 0)

print("== modes ==")
local host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = NONE })
host.onIpc("always", nil); world({ lid = false, ac = true, procs = NONE })
check("always: holds without an agent", #alive() == 1)
check("mode saved", host.files["/data/mode"] == "always")
host.onIpc("off", nil); world({ lid = false, ac = true, procs = AGENT })
check("off: lets go even with an agent", #alive() == 0)
host.onIpc("toggle", nil); world({ lid = false, ac = true, procs = AGENT })
check("toggle from off is auto", H.state.status.mode == "auto" and #alive() == 1)
host.noctalia.state.set("request", { op = "toggle", n = 1 }); world({ lid = false, ac = true, procs = AGENT })
check("the tile's request works too", H.state.status.mode == "always")
host.onIpc("bogus", nil)
check("unknown events are ignored", H.state.status.mode == "always")
load(newHost({ files = { ["/data/mode"] = "off\n" } })); answerPkills()
world({ lid = false, ac = true, procs = AGENT })
check("a restart keeps the mode", H.state.status.mode == "off" and #alive() == 0)
load(newHost({ files = { ["/data/mode"] = "garbage" } }))
check("a broken mode file is auto", H.state.status.mode == "auto")

print("== settings ==")
host = load(newHost({ config = { apps = "", ignore = "" } })); answerPkills()
check("no agents listed: no names for the filter", pending(isSnapshot)[1].argv[5] == "")
world({ lid = false, ac = true, procs = AGENT })
check("... and nothing held", #alive() == 0)
host.config.apps = "claude"; host.onConfigChanged()
world({ lid = false, ac = true, procs = { "/home/me/.local/bin/claude --chrome-native-host" } })
check("an empty ignore list takes the bridge as an agent", #alive() == 1)

print("== the inhibitor ends by itself ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = AGENT }); confirm()
local s = alive()[1]; s.alive = false; s.cb("stammgast:ended")
check("tile goes dark", H.state.status.holding == false)
tick(); world({ lid = false, ac = true, procs = AGENT })
check("not started again at once", #alive() == 0)
tick(30000); world({ lid = false, ac = true, procs = AGENT })
check("started again after 30 s", #alive() == 1)
local ended = 0
for _ = 1, 5 do
  s = alive()[1]; if s then s.alive = false; s.cb("stammgast:ended") end
  tick(31000); world({ lid = false, ac = true, procs = AGENT })
end
for _, m in ipairs(H.logs) do if string.find(m, "ended by itself", 1, true) then ended = ended + 1 end end
check("a refused inhibitor is not logged every time", ended < 5, ended)

print("== failures ==")
host = load(newHost()); answerPkills()
world({ fail = true })
check("a failed look holds nothing", #alive() == 0)
tick(); check("and looks again", #pending(isSnapshot) == 1)
world({ lid = false, ac = true, procs = AGENT })
check("then holds", #alive() == 1)
host.refuse = true
tick(); host.refuse = false
tick(); check("a refused look is retried", #pending(isSnapshot) == 1)
world({ lid = false, ac = true, procs = AGENT })
tick() -- a look that never answers
tick(); check("no second look while one is out", #pending(isSnapshot) == 1)
tick(16000)
check("a look that never answers is given up on", #pending(isSnapshot) == 2)

print("== a refused lock is tried again ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = AGENT }); confirm()
tick()
local look = pending(isSnapshot)[1]
host.refuse = true
look.done = true
look.cb({ exitCode = 0, stdout = snapshotText({ lid = true, ac = true, procs = AGENT }), stderr = "" })
host.refuse = false
check("refused the first time", count(isMsg("session lock")) == 0)
tick(); world({ lid = true, ac = true, procs = AGENT })
check("locked on the next look", count(isMsg("session lock")) == 1)

print("== a new hold that never holds ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = AGENT }); confirm()
local first = alive()[1]
tick(); world({ lid = true, ac = true, procs = AGENT })
check("two while waiting", #alive() == 2)
tick(3000); world({ lid = true, ac = true, procs = AGENT })
check("the old one still holds at 6 s", first.alive == true)
tick(8000); answerPkills()
check("the old one stops after 10 s anyway", first.alive == false)

print("== a refused pkill is tried again ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = AGENT }); confirm()
first = alive()[1]
tick()
look = pending(isSnapshot)[1]
look.done = true
host.refuse = true
look.cb({ exitCode = 0, stdout = snapshotText({ lid = false, ac = true, procs = NONE }), stderr = "" })
host.refuse = false
answerPkills()
check("refused: the hold is still there", first.alive == true)
tick(); answerPkills()
check("stopped on the next tick", first.alive == false)

print("== docked ==")
host = load(newHost()); answerPkills()
world({ lid = true, ac = true, procs = AGENT }); confirm()
check("undocked, lid closed: deep, screen off", what(alive()[1]) == "handle-lid-switch:sleep:idle" and count(isMsg("dpms-off")) == 1)
tick(); world({ lid = true, docked = true, ac = true, procs = AGENT })
check("a screen plugged in: it comes on", count(isMsg("dpms-on")) == 1)
confirm(); answerPkills()
check("docked: the lid switch only, so idle and suspend are the user's", #alive() == 1 and what(alive()[1]) == "handle-lid-switch")

print("== a tile request is handled once ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = NONE })
host.noctalia.state.set("request", { op = "toggle", n = 7 })
check("handled", H.state.status.mode == "always")
check("and cleared", H.state.request == nil)

print("== disable ==")
host = load(newHost()); answerPkills()
world({ lid = true, ac = true, procs = AGENT }); confirm()
host.onExit(15, "disable")
answerPkills()
check("every hold of this instance stops", #alive() == 0)
check("the screen comes back on", count(isMsg("dpms-on")) == 1)

print("== reload ==")
host = load(newHost()); answerPkills()
world({ lid = true, ac = true, procs = AGENT }); confirm()
local oldStream = alive()[1]
host.onExit(nil, "reload")
answerPkills()
check("a reload keeps the hold until the next instance has one", oldStream.alive == true)
-- The next instance, same state and files, with the old stream still there.
local nextHost = newHost({ files = host.files, state = host.state, now = host.now + 50 })
nextHost.streams = { oldStream }
load(nextHost)
answerPkills()
check("the new instance does not stop the old hold before it holds", oldStream.alive == true)
world({ lid = true, ac = true, procs = AGENT })
check("the new instance holds", #alive() == 2)
confirm(); answerPkills()
check("then the old hold stops", oldStream.alive == false and #alive() == 1)
check("no second lock after a reload", count(isMsg("session lock")) == 0)

print("== reload with the lid closed, agent gone meanwhile ==")
host = load(newHost()); answerPkills()
world({ lid = true, ac = true, procs = AGENT }); confirm()
host.onExit(nil, "reload")
nextHost = newHost({ files = host.files, state = host.state, now = host.now + 50 })
nextHost.streams = { alive()[1] }
load(nextHost)
world({ lid = true, ac = true, procs = NONE })
check("the old hold is let go", #alive() == 0)
tick(3000); world({ lid = true, ac = true, procs = NONE })
tick(3500); world({ lid = true, ac = true, procs = NONE })
check("and the lid action still follows", count(isLidAction) == 1)

print("== two reloads before the first handover is done ==")
host = load(newHost()); answerPkills()
world({ lid = true, ac = true, procs = AGENT }); confirm()
local firstHold = alive()[1]
host.onExit(nil, "reload")
local second = load(newHost({ files = host.files, state = host.state, now = host.now + 50 }))
second.streams = { firstHold }
second.onExit(nil, "reload") -- before its first look
local third = load(newHost({ files = host.files, state = host.state, now = host.now + 100 }))
third.streams = { firstHold }
world({ lid = true, ac = true, procs = AGENT }); confirm(); answerPkills()
check("the first instance's hold is stopped too", firstHold.alive == false and #alive() == 1)

print("== docked, then undocked with the lid still closed ==")
host = load(newHost()); answerPkills()
world({ lid = true, ac = true, procs = AGENT }); confirm()
tick(); world({ lid = true, docked = true, ac = true, procs = AGENT }); confirm(); answerPkills()
local offs = count(isMsg("dpms-off"))
tick(); world({ lid = true, docked = false, ac = true, procs = AGENT }); confirm(); answerPkills()
check("dark again", count(isMsg("dpms-off")) == offs + 1)

print("== docked survives a failed reading ==")
host = load(newHost()); answerPkills()
world({ lid = true, docked = true, ac = true, procs = AGENT }); confirm()
tick(); world({ ac = true, procs = AGENT }) -- no lid, no docked line
check("still lid only, nothing locked", what(alive()[1]) == "handle-lid-switch" and count(isMsg("session lock")) == 0)

print("== a replacement that fails keeps the old hold ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = AGENT }); confirm()
first = alive()[1]
tick(); world({ lid = true, ac = true, procs = AGENT })
local deep = alive()[2]
deep.alive = false; deep.cb("stammgast:ended")
check("the tile still shows the lid hold", H.state.status.holding == true and H.state.status.hold == "lid")
tick(12000); world({ lid = true, ac = true, procs = AGENT }); answerPkills()
check("the old hold is kept past 10 s", first.alive == true)
tick(20000); world({ lid = true, ac = true, procs = AGENT }); confirm(); answerPkills()
check("replaced once a new try holds", first.alive == false and what(alive()[1]) == "handle-lid-switch:sleep:idle")

print("== replaced twice before holding ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = AGENT }); confirm()
first = alive()[1]
tick(); world({ lid = true, ac = true, procs = AGENT })
tick(); world({ lid = false, ac = true, procs = AGENT })
confirm(); answerPkills()
check("the older runs stop as soon as the newest holds", #alive() == 1 and first.alive == false)

print("== a run stopped before it started ==")
host = load(newHost()); answerPkills()
world({ lid = false, ac = true, procs = AGENT })
local early = alive()[1]
tick(); world({ lid = false, ac = true, procs = NONE })
-- pkill ran before systemd-inhibit existed: the fake stream is still alive
early.alive = true
early.cb("held"); answerPkills()
check("its heartbeat gets it stopped", early.alive == false)

print("== agent details for the widgets ==")
host = load(newHost()); answerPkills()
local claudeSession = 'cs {"pid":101,"sessionId":"s1","cwd":"/home/me/code/kaffeehaus","name":"kaffeehaus-88","status":"waiting","statusUpdatedAt":1000000}'
local statusLine = 'sl 1000 {"session_id":"s1","model":{"display_name":"Opus 5.5"},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":2000}}}'
world({ lid = false, ac = true, procs = { "/home/me/.local/bin/claude" }, extra = { claudeSession, statusLine } })
local a = H.state.status.agents[1]
check("state from Claude's session file", a and a.state == "waiting", a and a.state)
check("project and model", a.project == "kaffeehaus" and a.model == "Opus 5.5")
check("limits published", H.state.status.limits.claude and H.state.status.limits.claude.session.used == 0.3)
local published = 0
host.noctalia.state.watch("status", function() published = published + 1 end)
tick(); world({ lid = false, ac = true, procs = { "/home/me/.local/bin/claude" }, extra = { claudeSession, statusLine } })
check("nothing new: not published again", published == 0, published)
tick(); world({ lid = false, ac = true, procs = { "/home/me/.local/bin/claude" }, extra = { (string.gsub(claudeSession, "waiting", "busy")), statusLine } })
check("a state change is published", published == 1 and H.state.status.agents[1].state == "busy", published)

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
