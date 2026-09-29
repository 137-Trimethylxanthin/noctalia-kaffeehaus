local agents = require("lib.agents")
local json = require("json")
local decode = json.decode

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

local NOW = 1790690000000

print("== kinds ==")
check("claude has the mascot", agents.KINDS.claude.image == "claude")
check("codex has the OpenAI mark", agents.KINDS.codex.glyph == "brand-openai")
check("unknown is other", agents.kindOf("aider") == "other")
check("labels", agents.label("claude") == "Claude Code" and agents.label("aider") == "Aider")

print("== claude sessions ==")
local sessions, lines, newest = agents.claudeIndex({
  '{"pid":101,"sessionId":"s1","cwd":"/home/me/code/kaffeehaus","name":"kaffeehaus-88","status":"busy","startedAt":1790680000000,"statusUpdatedAt":1790689990000}',
  '{"pid":102,"sessionId":"s2","cwd":"/home/me/School/pos","name":"pos-2f","status":"waiting","statusUpdatedAt":1790689000000}',
  '{"pid":103,"status":"blocked"}',
  'not json',
}, {
  { mtime = 1790689900, json = '{"session_id":"s1","model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":42},"cost":{"total_cost_usd":1.25},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1790700000},"seven_day":{"used_percentage":12.5,"resets_at":1791000000}}}' },
  { mtime = 1790680000, json = '{"session_id":"old","rate_limits":{"five_hour":{"used_percentage":99}}}' },
  { mtime = 1, json = 'broken' },
}, decode)
check("sessions by pid", sessions[101] and sessions[102] and sessions[103])
check("lines by session id", lines.s1 and lines.old)
check("newest line with limits", newest and newest.session_id == "s1")

local procs = {
  { pid = 101, ppid = 1, ticks = 1000, name = "claude" },
  { pid = 102, ppid = 1, ticks = 50, name = "claude" },
  { pid = 103, ppid = 1, ticks = 50, name = "claude" },
  { pid = 200, ppid = 1, ticks = 500, name = "codex" },
  { pid = 201, ppid = 200, ticks = 300, name = "codex" }, -- the binary its node wrapper started
  { pid = 300, ppid = 1, ticks = 10, name = "aider" },
}
local list, prev, since = agents.build({ procs = procs, sessions = sessions, lines = lines, now = NOW })
local byKey = {}
for _, a in ipairs(list) do byKey[a.key] = a end
check("one agent per process group", #list == 5, #list)
check("the wrapper and its child are one", byKey["codex:200"] ~= nil and byKey["codex:201"] == nil)
local c = byKey["claude:101"]
check("state from the session file", c.state == "busy")
check("project is the folder name", c.project == "kaffeehaus")
check("session name", c.session == "kaffeehaus-88")
check("since from the session file", c.stateAt == 1790689990000)
check("model, context and cost from its status line", c.model == "Opus 5.5" and math.abs(c.context - 0.42) < 1e-9 and c.cost == 1.25)
check("waiting", byKey["claude:102"].state == "waiting")
check("blocked counts as waiting", byKey["claude:103"].state == "waiting")
check("no CPU history yet: idle", byKey["codex:200"].state == "idle" and byKey["aider:300"].state == "idle")
check("most urgent first", list[1].state == "waiting" and list[#list].state == "idle")
check("primary is the first", agents.primary(list) == list[1])
check("both waiting sessions come first", list[1].state == "waiting" and list[2].state == "waiting" and list[3].key == "claude:101")

print("== CPU ==")
local procs2 = {
  { pid = 200, ppid = 1, ticks = 500 + 20, name = "codex" },
  { pid = 201, ppid = 200, ticks = 300 + 0, name = "codex" },  -- 20 ticks in 3 s: 6.7 %
  { pid = 300, ppid = 1, ticks = 10 + 5, name = "aider" },     -- 5 ticks in 3 s: 1.7 %
}
local list2, prev2, since2 = agents.build({ procs = procs2, prev = prev, since = since, now = NOW + 3000 })
local k2 = {}
for _, a in ipairs(list2) do k2[a.key] = a end
check("a working agent is busy", k2["codex:200"].state == "busy")
check("the child's ticks count for the group", prev2[200].ticks == 820)
check("a quiet one stays idle", k2["aider:300"].state == "idle")
check("state change time is kept", k2["codex:200"].stateAt == NOW + 3000)
check("an unchanged state keeps its time", k2["aider:300"].stateAt == since["aider:300"].at)
local list3 = agents.build({ procs = procs2, prev = prev2, since = since2, now = NOW + 6000 })
check("no new ticks: idle again", list3[1].state == "idle" and list3[2].state == "idle")
check("gone agents are dropped", #list3 == 2)
check("no agents", #agents.build({ procs = {}, now = NOW }) == 0 and agents.primary({}) == nil)

print("== limits ==")
local limits = agents.limits(newest, nil, decode, NOW)
check("claude session limit", limits.claude and math.abs(limits.claude.session.used - 0.30) < 1e-9)
check("resets_at in seconds becomes ms", limits.claude.session.resetsAt == 1790700000000)
check("weekly", math.abs(limits.claude.week.used - 0.125) < 1e-9)
check("when it was read", limits.claude.at == 1790689900000)
check("no codex without a line", limits.codex == nil)
local codex = agents.limits(nil, { mtime = 1790689900, json = '{"timestamp":"x","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":55.0,"window_minutes":300,"resets_in_seconds":600},"secondary":{"used_percent":20.0,"window_minutes":10080,"resets_at":1791000000}}}}' }, decode, NOW)
check("codex session", codex.codex and math.abs(codex.codex.session.used - 0.55) < 1e-9)
check("resets_in_seconds counts from the file time", codex.codex.session.resetsAt == 1790689900000 + 600000)
check("codex weekly resets_at", codex.codex.week.resetsAt == 1791000000000)
check("broken codex line", agents.limits(nil, { mtime = 1, json = "{" }, decode, NOW).codex == nil)
check("a status line without limits", agents.limits({ model = {} }, nil, decode, NOW).claude == nil)
check("percent is clamped", agents.limits({ rate_limits = { five_hour = { used_percentage = 140 } } }, nil, decode, NOW).claude.session.used == 1)

print("== stale and odd limits ==")
local stale = agents.limits({ _mtime = 1790680000, rate_limits = { five_hour = { used_percentage = 99, resets_at = 1790685000 }, seven_day = { used_percentage = 40, resets_at = 1791000000 } } }, nil, decode, NOW)
check("a window that has reset since shows 0 %", stale.claude.session.used == 0 and stale.claude.session.reset == true)
check("the week still counts", math.abs(stale.claude.week.used - 0.40) < 1e-9)
check("limits older than a week are dropped", agents.limits({ _mtime = 1790000000, rate_limits = { seven_day = { used_percentage = 5 } } }, nil, decode, NOW).claude == nil)
local weekly = agents.limits(nil, { mtime = 1790689900, json = '{"payload":{"rate_limits":{"primary":{"used_percent":10,"window_minutes":10080,"resets_at":1791000000}}}}' }, decode, NOW)
check("a weekly primary is the week", weekly.codex and weekly.codex.week and weekly.codex.session == nil)
check("codex older than a week is dropped", agents.limits(nil, { mtime = 1790000000, json = '{"rate_limits":{"primary":{"used_percent":1}}}' }, decode, NOW).codex == nil)

print("== a Claude started through a wrapper ==")
local wrapped = agents.build({
  procs = { { pid = 500, ppid = 1, ticks = 0, name = "claude" }, { pid = 501, ppid = 500, ticks = 0, name = "claude" } },
  sessions = { [501] = { pid = 501, status = "waiting", cwd = "/x/proj" } },
  now = NOW,
})
check("the session of the child counts for the group", #wrapped == 1 and wrapped[1].state == "waiting" and wrapped[1].project == "proj")

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
