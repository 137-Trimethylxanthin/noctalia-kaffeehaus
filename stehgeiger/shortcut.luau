--!nonstrict
-- [[shortcut]]: a control-center tile that steps to the next output profile,
-- say from headphones to speakers. It shows what the control service last
-- read, so it follows switches made anywhere, the Easy Effects window
-- included. Add it under Settings -> Control Center shortcuts.
--
-- There is no right-click, and no bypass anywhere: a profile's equalizer
-- carries the cut that keeps it from being louder than the others, and
-- bypassing it would take that cut away (see the README on hearing safety).

local function render(status)
  local running = status ~= nil and status.state == "running"
  local label = noctalia.tr("title")
  if running and status.output ~= nil then
    local found = nil
    for _, profile in ipairs(status.outputs or {}) do
      if profile.preset == status.output then
        found = profile
      end
    end
    label = if found then found.label else status.output
  end
  shortcut.setLabel(label)
  shortcut.setIcon("adjustments-horizontal")
  shortcut.setActive(running and status.output ~= nil)
  shortcut.setEnabled(running and #(status.outputs or {}) > 0)
end

noctalia.state.watch("status", render)
render(noctalia.state.get("status"))

function onClick()
  noctalia.state.set("request", { op = "cycle-output", n = noctalia.nowMs() })
end
