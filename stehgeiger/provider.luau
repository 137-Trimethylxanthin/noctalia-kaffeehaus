--!nonstrict
-- [[launcher_provider]]: type /eq to pick an Easy Effects profile, output and
-- input alike. The control service talks to Easy Effects and does the
-- switching; this only shows what it published and asks it.

local lastQuery = ""

local function matches(profile, filter)
  if filter == "" then
    return true
  end
  -- The label and the preset name, so "studio" finds "Studio=studio-flat"
  -- either way.
  return string.find(string.lower(profile.label), filter, 1, true) ~= nil
    or string.find(string.lower(profile.preset), filter, 1, true) ~= nil
end

local function rows(kind, list, current, filter, out)
  local glyph = if kind == "output" then "headphones" else "microphone"
  for _, profile in ipairs(list or {}) do
    if matches(profile, filter) then
      local subtitle = noctalia.tr(kind)
      if profile.label ~= profile.preset then
        subtitle = subtitle .. "  ·  " .. profile.preset
      end
      if profile.preset == current then
        subtitle = noctalia.tr("active") .. "  ·  " .. subtitle
      end
      table.insert(out, {
        id = kind .. ":" .. profile.preset,
        title = profile.label,
        subtitle = subtitle,
        glyph = glyph,
      })
    end
  end
end

local function notice(key, glyph)
  return { { id = "", title = noctalia.tr(key .. ".title"), subtitle = noctalia.tr(key .. ".subtitle"), glyph = glyph } }
end

local function build(filter)
  local status = noctalia.state.get("status")
  if status == nil or status.state == nil then
    return {}
  end
  if status.state == "missing" then
    return notice("missing", "plug-off")
  elseif status.state == "stopped" then
    return notice("stopped", "plug-off")
  elseif status.state == "failed" then
    return notice("unanswered", "alert-triangle")
  end
  local out = {}
  rows("output", status.outputs, status.output, filter, out)
  rows("output", status.outputOthers, status.output, filter, out)
  rows("input", status.inputs, status.input, filter, out)
  rows("input", status.inputOthers, status.input, filter, out)
  if #out == 0 and filter == "" then
    return notice("empty", "folder-off")
  end
  return out
end

local function render()
  launcher.setResults(lastQuery, build(string.lower(noctalia.string.trim(lastQuery))))
end

-- Every new reading redraws the latest query, so the Active marker follows
-- what is really loaded.
noctalia.state.watch("status", function()
  render()
end)

function onQuery(query)
  lastQuery = query
  render()
  -- The input preset is only asked for here, while someone is looking.
  noctalia.state.set("request", { op = "refresh", input = true, n = noctalia.nowMs() })
end

function onActivate(id)
  local kind, preset = string.match(id, "^(%a+):(.+)$")
  if kind ~= "output" and kind ~= "input" then
    return
  end
  noctalia.state.set("request", { op = "set-" .. kind, preset = preset, n = noctalia.nowMs() })
end
