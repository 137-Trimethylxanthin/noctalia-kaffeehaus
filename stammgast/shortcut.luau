--!nonstrict
-- [[shortcut]]: a control-center tile for Stammgast. Lit while it is holding
-- the lid open for an agent (or for good, in "always"). Click steps through
-- auto -> always -> off; right-click opens the settings. Add it under
-- Settings -> Control Center shortcuts.

local function render(status)
  status = status or {}
  local mode = status.mode or "auto"
  shortcut.setLabel(noctalia.tr("mode." .. mode))
  shortcut.setIcon("coffee", "coffee-off")
  shortcut.setActive(status.holding == true)
  shortcut.setEnabled(status.available ~= false)
end

noctalia.state.watch("status", render)
render(noctalia.state.get("status"))

function onClick()
  noctalia.state.set("request", { op = "toggle", n = noctalia.nowMs() })
end

function onRightClick()
  noctalia.runAsync({ "noctalia", "msg", "settings-open-plugin", "137-trimethylxanthin/stammgast" })
end
