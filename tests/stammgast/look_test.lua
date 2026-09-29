-- lib/look.luau with a fake ui (each constructor returns its props) and tr.
local fails = 0
local function check(name, cond, extra)
  if cond then print("  ok   " .. name)
  else fails = fails + 1; print("  FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "")) end
end

local strings = {
  ["state.busy"] = "Active", ["state.waiting"] = "Waiting for you", ["state.idle"] = "Idle",
  ["time.now"] = "just now", ["time.minutes"] = "{n} min", ["time.hours"] = "{n} h",
  ["time.hours_minutes"] = "{h} h {m} min", ["time.days"] = "{n} d", ["detail.context"] = "context {n} %",
}
_G.noctalia = {
  pluginDir = function() return "/plugin" end,
  tr = function(key, vars)
    local text = strings[key] or key
    for k, v in pairs(vars or {}) do text = string.gsub(text, "{" .. k .. "}", tostring(v)) end
    return text
  end,
}
_G.ui = setmetatable({}, { __index = function(_, kind) return function(props) props._kind = kind; return props end end })
local look = require("lib.look")

print("== icons ==")
local img = look.icon({ kind = "claude", state = "busy" }, 18)
check("claude is the mascot image", img._kind == "image" and img.path == "/plugin/icons/claude.svg")
check("sized by its aspect", img.height == 15 and img.width == 24, img.width .. "x" .. img.height)
check("full strength while busy", img.opacity == 1)
check("faded while idle", look.icon({ kind = "claude", state = "idle" }, 18).opacity == 0.6)
local codex = look.icon({ kind = "codex", state = "waiting" }, 18)
check("codex is the OpenAI glyph, coloured by state", codex._kind == "glyph" and codex.name == "brand-openai" and codex.color == "tertiary")
check("others get a sparkle", look.icon({ kind = "other", state = "busy" }, 18).name == "sparkles")
check("dot colour", look.dot("busy", 6).fill == "primary" and look.dot("gone", 6).fill == "outline")

print("== words ==")
check("just now", look.duration(45 * 1000) == "just now")
check("minutes", look.duration(3 * 60000) == "3 min")
check("hours", look.duration(2 * 3600000) == "2 h")
check("hours and minutes", look.duration(2 * 3600000 + 5 * 60000) == "2 h 5 min")
check("days", look.duration(3 * 86400000) == "3 d")
check("negative is empty", look.duration(-5) == "")
check("state line", look.stateLine({ state = "waiting", stateAt = 1000 }, 1000 + 60000) == "Waiting for you · 1 min")
check("state line without a time", look.stateLine({ state = "idle" }, 0) == "Idle")
check("a time in the future is left out", look.stateLine({ state = "busy", stateAt = 5000 }, 1000) == "Active")
check("where: project and session", look.where({ project = "kaffeehaus", session = "kaffeehaus-88" }) == "kaffeehaus · kaffeehaus-88")
check("where: a session named like its project once", look.where({ project = "x", session = "x" }) == "x")
check("where: nothing", look.where({}) == nil)
check("extras", look.extras({ model = "Opus 5.5", context = 0.424, cost = 1.2 }) == "Opus 5.5 · context 42 % · $1.20")
check("no extras", look.extras({}) == nil)

print(fails == 0 and "all ok" or (fails .. " failed"))
os.exit(fails == 0 and 0 or 1)
