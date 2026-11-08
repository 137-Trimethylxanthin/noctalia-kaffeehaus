--!nonstrict
-- Stehgeiger's decisions, with no Easy Effects in them: what `easyeffects -a`
-- said, which presets there are, which of them the user wants in what order,
-- which one comes next, and when it is safe and worth asking again. Pure, so
-- the tests run it under plain Lua.
--
-- A profile is one preset the plugin offers:
--   { label = "Studio", preset = "studio-flat" }
-- The label is what the tile and the launcher show; the preset is the file
-- name in ~/.local/share/easyeffects/<output|input>/ without ".json".

local M = {}

-- How often the service asks Easy Effects what is loaded, and how long it
-- waits after an `easyeffects` call that failed.
M.POLL_MS = 10000
M.BACKOFF_MS = 60000
-- An `easyeffects` call (or the gate) that takes longer than this is cut
-- off. It should never be reached: the gate below is what keeps a call from
-- hanging, and the cut-off keeps a stuck one from holding up every look after.
M.CALL_TIMEOUT_MS = 5000

-- The liveness gate, run as one process before every `easyeffects` call.
-- With no Easy Effects service running, `easyeffects -a output` (or `-l`,
-- `-p`, `-b`) does not answer and exit: it becomes a full Easy Effects
-- instance, window and all, and keeps running. After a crash or `kill -9`
-- the socket is left behind, and the same happens, so the socket alone
-- proves nothing; the process has to be there too. Exit 0 means both are.
M.GATE = {
  "sh", "-c",
  'test -S "$XDG_RUNTIME_DIR/EasyEffectsServer" && pgrep -x easyeffects >/dev/null',
}

local function trim(s)
  s = string.gsub(s, "^%s+", "")
  s = string.gsub(s, "%s+$", "")
  return s
end

-- Whether the gate's exit code lets an `easyeffects` call through.
function M.gateOpen(exitCode)
  return exitCode == 0
end

-- How long to wait before the next look, after one that ended as `outcome`:
--   "ok"       Easy Effects answered
--   "stopped"  the gate was shut: nothing to ask, but cheap to look again
--   "failed"   an `easyeffects` call failed or timed out: back off
function M.nextDelay(outcome)
  if outcome == "failed" then
    return M.BACKOFF_MS
  end
  return M.POLL_MS
end

-- Whether a look is due at `now`, given when the next one was planned.
function M.due(now, nextAt)
  return nextAt == nil or now >= nextAt
end

-- The preset `easyeffects -a output|input` reports, or nil for none. A
-- running service prints an empty line when nothing is loaded; an instance
-- started without one prints "None".
function M.parseActive(stdout)
  if type(stdout) ~= "string" then
    return nil
  end
  local line = trim(string.match(stdout, "^[^\n]*") or "")
  if line == "" or line == "None" then
    return nil
  end
  return line
end

-- A preset name that is safe to hand to `easyeffects -l` as one argument:
-- not empty, no path in it, and not something that reads as an option.
function M.validPreset(name)
  return type(name) == "string"
    and name ~= ""
    and string.sub(name, 1, 1) ~= "-"
    and string.sub(name, 1, 1) ~= "."
    and string.find(name, "/", 1, true) == nil
    and string.find(name, "\n", 1, true) == nil
end

-- Preset names from a preset directory listing (noctalia.listDir entries,
-- plain names or { name = ... }): every "*.json" without the extension,
-- sorted, each once.
function M.presetNames(entries)
  local out, seen = {}, {}
  if type(entries) ~= "table" then
    return out
  end
  for _, entry in ipairs(entries) do
    local file = entry
    if type(entry) == "table" then
      file = entry.name
    end
    local name = type(file) == "string" and string.match(file, "^(.+)%.json$") or nil
    if M.validPreset(name) and not seen[name] then
      seen[name] = true
      table.insert(out, name)
    end
  end
  table.sort(out)
  return out
end

-- The profiles setting: "Label=preset, Label2=preset2". A bare "preset" is
-- its own label. Entries with an empty side, or with a preset name that
-- could not be a file, are skipped, and so is a preset listed twice.
function M.parseProfiles(text)
  local out, seen = {}, {}
  if type(text) ~= "string" then
    return out
  end
  for item in string.gmatch(text, "[^,]+") do
    item = trim(item)
    local label, preset
    local eq = string.find(item, "=", 1, true)
    if eq then
      label, preset = trim(string.sub(item, 1, eq - 1)), trim(string.sub(item, eq + 1))
    else
      label, preset = item, item
    end
    if label ~= "" and M.validPreset(preset) and not seen[preset] then
      seen[preset] = true
      table.insert(out, { label = label, preset = preset })
    end
  end
  return out
end

-- The profiles to offer: the configured ones, in their order, that have a
-- preset file; or, when nothing usable is configured, every preset found,
-- alphabetically, each labelled with its own name.
function M.profiles(text, presets)
  local exists = {}
  for _, name in ipairs(presets or {}) do
    exists[name] = true
  end
  local configured = M.parseProfiles(text)
  local out = {}
  if #configured == 0 then
    for _, name in ipairs(presets or {}) do
      table.insert(out, { label = name, preset = name })
    end
    return out
  end
  for _, profile in ipairs(configured) do
    if exists[profile.preset] then
      table.insert(out, profile)
    end
  end
  return out
end

-- The presets that are not among `profiles`, alphabetically, each labelled
-- with its own name: the launcher lists them after the profiles, so a preset
-- kept out of the tile's cycle (an A/B variant, say) is still one search away.
function M.others(profiles, presets)
  local taken = {}
  for _, profile in ipairs(profiles or {}) do
    taken[profile.preset] = true
  end
  local out = {}
  for _, name in ipairs(presets or {}) do
    if not taken[name] then
      table.insert(out, { label = name, preset = name })
    end
  end
  return out
end

-- The profile for `preset`, or nil when it is not one of them.
function M.find(profiles, preset)
  for i, profile in ipairs(profiles or {}) do
    if profile.preset == preset then
      return profile, i
    end
  end
  return nil
end

-- The profile after `current` (a preset name), wrapping round; the first
-- one when `current` is none or not in the list; nil for an empty list.
function M.nextProfile(profiles, current)
  if type(profiles) ~= "table" or #profiles == 0 then
    return nil
  end
  local _, i = M.find(profiles, current)
  if i == nil then
    return profiles[1]
  end
  return profiles[i % #profiles + 1]
end

return M
