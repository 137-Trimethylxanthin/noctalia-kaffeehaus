local stay = require("lib.stay")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

local function list(t)
  return table.concat(t, ",")
end

local apps = stay.parseApps(stay.DEFAULT_APPS)
local ignore = stay.parseIgnore(stay.DEFAULT_IGNORE)
local function agent(args) return stay.agentName(args, apps, ignore) end

print("== settings ==")
local parsed = stay.parseApps("Claude, codex  gemini,,")
check("lowercased, commas and spaces", parsed.claude and parsed.codex and parsed.gemini)
check("ignore keeps inner spaces", list(stay.parseIgnore(" MCP serve , --x,,")) == "mcp serve,--x")
check("empty ignore", #stay.parseIgnore("") == 0)

print("== names ==")
check("native binary by path", agent("/home/me/.local/bin/claude") == "claude")
check("bare name with arguments", agent("claude --resume") == "claude")
check("the Chrome bridge is a helper", agent("/home/me/.local/bin/claude --chrome-native-host") == nil)
check("npm codex through node", agent("node /usr/lib/node_modules/@openai/codex/bin/codex.js") == "codex")
check("npm gemini: package, -cli dropped", agent("node /usr/lib/node_modules/@google/gemini-cli/dist/index.js") == "gemini")
check("node flags skipped", agent("node --no-warnings /usr/bin/opencode") == "opencode")
check("unscoped package", agent("bun /x/node_modules/opencode/bin/run.js") == "opencode")
check("python agent", agent("python3.12 /home/me/.local/bin/aider --model x") == "aider")
check("uv run", agent("uv run aider") == "aider")
check("uvx", agent("uvx aider") == "aider")
check("bun x with a scoped package", agent("bun x @openai/codex") == "codex")
check("npm claude without a shebang", agent("node /usr/lib/node_modules/@anthropic-ai/claude-code/cli.js") == "claude")
check("npx itself is not the agent (its child is)", agent("node /usr/bin/npx codex") == nil)
check("node of something else", agent("node /usr/lib/node_modules/typescript/bin/tsc") == nil)
check("a mcp server is not claude", agent("node /home/me/.claude/plugins/cache/omc/bridge/mcp-server.cjs") == nil)
check("unrelated", agent("/usr/bin/firefox") == nil)
check("a name inside a path is not enough", agent("/usr/bin/vim /home/me/claude/notes.md") == nil)
check("empty", agent("") == nil)

print("== snapshot ==")
local snap = stay.parseSnapshot(table.concat({
  "lid closed", "ac 0", "bat 57", "bat 80", "ps",
  "  132295 /home/me/.local/bin/claude --chrome-native-host",
  "  178744 claude",
  "  200000 node /usr/lib/node_modules/@openai/codex/bin/codex.js",
  "  200001 codex",
  "  1 /sbin/init",
}, "\n"))
check("lid", snap.lid == true)
check("ac", snap.ac == false)
check("lowest battery", snap.battery == 57, snap.battery)
check("processes", #snap.procs == 5, #snap.procs)
check("pid and args", snap.procs[2].pid == 178744 and snap.procs[2].args == "claude")
check("agents sorted, once each", list(stay.findAgents(snap.procs, apps, ignore)) == "claude,codex")
local bare = stay.parseSnapshot("ps\n 1 /sbin/init\n")
check("no lid, no battery", bare.lid == nil and bare.battery == nil and bare.ac == nil)
check("lid open", stay.parseSnapshot("lid open\nps\n").lid == false)
check("docked", stay.parseSnapshot("docked 1\nps\n").docked == true)
check("not docked", stay.parseSnapshot("docked 0\nps\n").docked == false)
check("docked unknown", bare.docked == nil)
check("any mains counts", stay.parseSnapshot("ac 0\nac 1\nps\n").ac == true)
check("a ps line that says lid is a process", stay.parseSnapshot("ps\n 9 lid closed\n").lid == nil)

print("== battery ==")
check("above the floor", stay.batteryLow(40, false, 15, false) == false)
check("at the floor", stay.batteryLow(15, false, 15, false) == true)
check("stays low until 5 above", stay.batteryLow(18, false, 15, true) == true)
check("... then clears", stay.batteryLow(20, false, 15, true) == false)
check("mains clears it", stay.batteryLow(5, true, 15, true) == false)
check("floor 0 still lets go at 5 %", stay.batteryLow(5, false, 0, false) == true)
check("floor 0 holds at 6 %", stay.batteryLow(6, false, 0, false) == false)
check("unknown battery", stay.batteryLow(nil, false, 15, true) == false)

print("== decide ==")
check("no agents", stay.decide({ mode = "auto", agents = {}, lid = false }) == "none")
check("agent, lid open", stay.decide({ mode = "auto", agents = { "claude" }, lid = false }) == "lid")
check("agent, lid closed", stay.decide({ mode = "auto", agents = { "claude" }, lid = true }) == "deep")
check("agent, no lid known", stay.decide({ mode = "auto", agents = { "claude" } }) == "lid")
check("always without agents", stay.decide({ mode = "always", agents = {}, lid = true }) == "deep")
check("docked, lid closed: lid only", stay.decide({ mode = "auto", agents = { "claude" }, lid = true, docked = true }) == "lid")
check("off wins", stay.decide({ mode = "off", agents = { "claude" }, lid = true }) == "none")
check("low battery wins", stay.decide({ mode = "always", agents = { "claude" }, lid = true, low = true }) == "none")
check("what: lid", stay.inhibitWhat("lid") == "handle-lid-switch")
check("what: deep", stay.inhibitWhat("deep") == "handle-lid-switch:sleep:idle")
check("what: none", stay.inhibitWhat("none") == nil)

print("== modes ==")
check("auto -> always", stay.nextMode("auto") == "always")
check("always -> off", stay.nextMode("always") == "off")
check("off -> auto", stay.nextMode("off") == "auto")
check("junk -> auto", stay.nextMode("x") == "auto")
check("valid", stay.validMode("off") and not stay.validMode("on"))

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
