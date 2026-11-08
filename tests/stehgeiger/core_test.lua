-- Stehgeiger's decisions. The `easyeffects` answers are the real ones from
-- EasyEffects 8.3.2, captured in fixtures/ (see fixtures/noservice_NOTES.md).
local core = require("lib.core")

local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra ~= nil and ("  -> " .. tostring(extra)) or "")) end
end

local FIXTURES = os.getenv("FIXTURES") or "fixtures"
local function fixture(name)
  local f = assert(io.open(FIXTURES .. "/" .. name, "rb"))
  local text = f:read("a")
  f:close()
  return text
end

local function labels(list)
  local out = {}
  for _, p in ipairs(list) do out[#out + 1] = p.label .. "=" .. p.preset end
  return table.concat(out, ",")
end

print("== -a output / -a input ==")
check("service, nothing loaded: an empty line is none", core.parseActive(fixture("service_aoutput.stdout")) == nil)
check("service, input: none either", core.parseActive(fixture("service_ainput.stdout")) == nil)
check("no service: \"None\" is none", core.parseActive(fixture("noservice_aoutput.stdout")) == nil)
check("stale socket: \"None\" is none", core.parseActive(fixture("stale_aoutput.stdout")) == nil)
check("the service answered with exit 0", tonumber(fixture("service_aoutput.exit")) == 0)
check("without the service it hung until killed", tonumber(fixture("noservice_aoutput.exit")) == 124
  and tonumber(fixture("stale_aoutput.exit")) == 124)
check("a loaded preset", core.parseActive("speakers-flat\n") == "speakers-flat")
check("surrounding blanks go", core.parseActive("  studio \n") == "studio")
check("only the first line counts", core.parseActive("studio\nsomething else\n") == "studio")
check("a name with spaces", core.parseActive("Late Night\n") == "Late Night")
check("no answer", core.parseActive(nil) == nil and core.parseActive("") == nil)

print("== the gate ==")
check("one process", core.GATE[1] == "sh" and core.GATE[2] == "-c" and #core.GATE == 3)
check("checks the socket", string.find(core.GATE[3], 'test -S "$XDG_RUNTIME_DIR/EasyEffectsServer"', 1, true) ~= nil)
check("and the process, exactly", string.find(core.GATE[3], "&& pgrep -x easyeffects", 1, true) ~= nil)
check("exit 0 opens it", core.gateOpen(0))
check("anything else keeps it shut", not core.gateOpen(1) and not core.gateOpen(124) and not core.gateOpen(nil))
-- Run it for real (it only looks, it starts nothing): the shell has to take
-- it, so the answer is 0 or 1, never a syntax error.
local _, how, code = os.execute(core.GATE[3] .. " 2>/dev/null")
check("the shell takes it", how == "exit" and (code == 0 or code == 1), tostring(how) .. " " .. tostring(code))

print("== when to look again ==")
check("answered: ten seconds", core.nextDelay("ok") == 10000)
check("not running: ten seconds, the gate is cheap", core.nextDelay("stopped") == 10000)
check("a failed call: a minute", core.nextDelay("failed") == 60000)
check("nothing planned: due", core.due(5, nil))
check("not yet", not core.due(1000, 2000))
check("now", core.due(2000, 2000) and core.due(2500, 2000))
check("a call is cut off well before the next look", core.CALL_TIMEOUT_MS < core.POLL_MS)

print("== preset names ==")
local listing = { "speakers-flat.json", "headphones-eq.json", "notes.txt", ".hidden.json", "-x.json", "studio.json", "studio.json" }
local presets = core.presetNames(listing)
check("json only, sorted, once", table.concat(presets, ",") == "headphones-eq,speakers-flat,studio", table.concat(presets, ","))
check("listDir entries as tables", table.concat(core.presetNames({ { name = "b.json" }, { name = "a.json" } }), ",") == "a,b")
check("no listing", #core.presetNames(nil) == 0)
check("an option is no preset", not core.validPreset("-l"))
check("a path is no preset", not core.validPreset("../x") and not core.validPreset("a/b"))
check("a plain name is", core.validPreset("Late Night") and core.validPreset("flat-safe"))

print("== the profiles setting ==")
local parsed = core.parseProfiles(" Headphones = headphones-eq ,Speakers=speakers-flat, , =nolabel, nopreset=, studio, Again=headphones-eq")
check("labels and presets, trimmed, in order", labels(parsed) == "Headphones=headphones-eq,Speakers=speakers-flat,studio=studio", labels(parsed))
check("a label may hold spaces", labels(core.parseProfiles("Late night=quiet")) == "Late night=quiet")
check("only the first = splits", labels(core.parseProfiles("A=b=c")) == "A=b=c")
check("an option as preset is dropped", #core.parseProfiles("Bad=-b") == 0)
check("empty", #core.parseProfiles("") == 0 and #core.parseProfiles(nil) == 0)

print("== profiles on offer ==")
check("empty setting: every preset, by name", labels(core.profiles("", presets))
  == "headphones-eq=headphones-eq,speakers-flat=speakers-flat,studio=studio")
check("nothing usable configured: every preset", labels(core.profiles(" , =x", presets)) == labels(core.profiles("", presets)))
check("configured order kept", labels(core.profiles("Speakers=speakers-flat, Headphones=headphones-eq", presets))
  == "Speakers=speakers-flat,Headphones=headphones-eq")
check("a configured preset with no file is dropped", labels(core.profiles("Gone=missing, Studio=studio", presets)) == "Studio=studio")
check("configured but none there: none", #core.profiles("Gone=missing", presets) == 0)
check("no presets at all", #core.profiles("", {}) == 0)

print("== the next profile ==")
local list = core.profiles("A=headphones-eq, B=speakers-flat, C=studio", presets)
check("steps on", core.nextProfile(list, "headphones-eq").preset == "speakers-flat")
check("wraps round", core.nextProfile(list, "studio").preset == "headphones-eq")
check("nothing loaded: the first", core.nextProfile(list, nil).preset == "headphones-eq")
check("a preset not in the list: the first", core.nextProfile(list, "something-else").preset == "headphones-eq")
check("one profile stays itself", core.nextProfile({ list[2] }, "speakers-flat").preset == "speakers-flat")
check("no profiles: nothing", core.nextProfile({}, "studio") == nil and core.nextProfile(nil, nil) == nil)
print("== presets left out of the profiles ==")
check("others: the rest, by name", labels(core.others(core.profiles("Studio=studio", presets), presets))
  == "headphones-eq=headphones-eq,speakers-flat=speakers-flat")
check("others: none when every preset is a profile", #core.others(core.profiles("", presets), presets) == 0)
check("others: all when there are no profiles", #core.others({}, presets) == #presets)
local found, i = core.find(list, "speakers-flat")
check("find by preset", found.label == "B" and i == 2)
check("find nothing", core.find(list, "nope") == nil)

print()
if fails > 0 then print(fails .. " failed"); os.exit(1) end
print("all passed")
