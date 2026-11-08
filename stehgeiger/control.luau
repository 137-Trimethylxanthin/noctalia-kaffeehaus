--!nonstrict
-- [[service]]: the only entry that talks to Easy Effects. It asks which
-- output preset is loaded every ten seconds and right after every switch,
-- publishes that with the profiles on offer on noctalia.state ("status") for
-- the launcher and the tile, and is the only one that switches: the launcher
-- and the tile ask through noctalia.state ("request"), a keybind through IPC.
--
--   noctalia msg plugin 137-trimethylxanthin/stehgeiger:control all set-output <preset>
--   noctalia msg plugin 137-trimethylxanthin/stehgeiger:control all set-input <preset>
--   noctalia msg plugin 137-trimethylxanthin/stehgeiger:control all cycle-output
--
-- It never starts Easy Effects, and never calls `easyeffects` unless the
-- service is really there: without it, `easyeffects -a output` does not
-- answer and exit but turns into a full Easy Effects instance that keeps
-- running, and a socket left behind by a crash does not prove it is there
-- (see lib/core.luau, M.GATE, and tests/stehgeiger/fixtures). Every call
-- goes through the gate first. It never touches bypass or the effects
-- themselves either: see the README on hearing safety.

local core = require("./lib/core.luau")

local available = noctalia.commandExists("easyeffects")

-- ── Presets ──────────────────────────────────────────────────────────────────
--
-- Read from Easy Effects' preset directories, not from `easyeffects -p`: a
-- directory listing costs no process and works while Easy Effects is down.

local function presetDir(kind)
  local data = noctalia.getenv("XDG_DATA_HOME")
  if data == nil or data == "" then
    data = noctalia.expandPath("~/.local/share")
  end
  return data .. "/easyeffects/" .. kind
end

local function presetsOf(kind)
  return core.presetNames(noctalia.listDir(presetDir(kind)))
end

local function profiles(kind)
  return core.profiles(noctalia.getConfig(kind .. "_profiles") or "", presetsOf(kind))
end

-- ── State ────────────────────────────────────────────────────────────────────

-- "missing" | "stopped" | "running" | "failed", and nil until the first look.
local state = nil
local active = { output = nil, input = nil }
local nextAt = nil

local function publish()
  local outputs, inputs = profiles("output"), profiles("input")
  noctalia.state.set("status", {
    state = state,
    output = active.output,
    input = active.input,
    outputs = outputs,
    inputs = inputs,
    -- Presets left out of the profiles: the launcher lists them after the
    -- profiles, the tile never cycles to them.
    outputOthers = core.others(outputs, presetsOf("output")),
    inputOthers = core.others(inputs, presetsOf("input")),
  })
end

-- ── Talking to Easy Effects ──────────────────────────────────────────────────

local busy = false
local queued = {}

-- Runs the gate, then `easyeffects <args>` only if it opened. done(outcome,
-- stdout): "ok", "stopped" (gate shut, nothing spawned) or "failed".
local function call(args, done)
  local accepted = noctalia.runAsync(core.GATE, function(gate)
    if not core.gateOpen(gate.exitCode) then
      return done("stopped")
    end
    local argv = { "easyeffects" }
    for _, arg in ipairs(args) do
      table.insert(argv, arg)
    end
    local ran = noctalia.runAsync(argv, function(result)
      if result.exitCode ~= 0 then
        noctalia.log("stehgeiger: easyeffects " .. table.concat(args, " ") .. " failed (" .. tostring(result.exitCode) .. ")")
        return done("failed")
      end
      done("ok", result.stdout)
    end, core.CALL_TIMEOUT_MS)
    if not ran then
      done("failed")
    end
  end, core.CALL_TIMEOUT_MS)
  if not accepted then
    done("failed")
  end
end

-- One job at a time, so a poll and a switch never cross; jobs that come in
-- meanwhile wait their turn.
local function run(job)
  table.insert(queued, job)
  if busy then
    return
  end
  local function nextJob()
    local current = table.remove(queued, 1)
    if current == nil then
      busy = false
      return
    end
    busy = true
    current(nextJob)
  end
  nextJob()
end

-- Settles the state after an outcome and plans the next look.
local function settle(outcome)
  if outcome == "ok" then
    state = "running"
  elseif outcome == "stopped" then
    state = "stopped"
    active.output, active.input = nil, nil
  else
    state = "failed"
  end
  nextAt = noctalia.nowMs() + core.nextDelay(outcome)
end

-- Asks what is loaded: the output always, the input only when `withInput`
-- (the launcher is open, or it was asked for).
local function read(withInput, done)
  if not available then
    state = "missing"
    publish()
    if done then
      done()
    end
    return
  end
  run(function(finish)
    call({ "-a", "output" }, function(outcome, stdout)
      if outcome == "ok" then
        active.output = core.parseActive(stdout)
      end
      local function finished(final)
        -- Free the queue first: if publishing threw, a busy flag left set
        -- would stop every later look and switch.
        finish()
        settle(final)
        publish()
        if done then
          done()
        end
      end
      if outcome ~= "ok" or not withInput then
        return finished(outcome)
      end
      call({ "-a", "input" }, function(inputOutcome, inputStdout)
        if inputOutcome == "ok" then
          active.input = core.parseActive(inputStdout)
        end
        finished(inputOutcome)
      end)
    end)
  end)
end

-- ── Switching ────────────────────────────────────────────────────────────────

local function announce(reason, label)
  if reason == "ok" then
    noctalia.notify(noctalia.tr("title"), noctalia.tr("switched", { label = label }))
  elseif reason == "missing" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("missing.subtitle"))
  elseif reason == "stopped" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("stopped.subtitle"))
  elseif reason == "unknown" then
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("unknown", { preset = label }))
  else
    noctalia.notifyError(noctalia.tr("title"), noctalia.tr("failed"))
  end
end

-- Loads `preset` from `kind` ("output" | "input"). Only a preset that has a
-- file in that directory is passed on, so a typo in a keybind cannot reach
-- the command line as anything else.
local function switch(kind, preset)
  if not available then
    return announce("missing")
  end
  local presets = presetsOf(kind)
  -- Every preset can be loaded by name, also one left out of the profiles
  -- setting; the setting only decides what the tile cycles and the
  -- launcher lists.
  local all = core.profiles("", presets)
  if core.find(all, preset) == nil then
    return announce("unknown", tostring(preset))
  end
  local profile = core.find(core.profiles(noctalia.getConfig(kind .. "_profiles") or "", presets), preset)
  local label = profile and profile.label or preset
  run(function(finish)
    call({ "-l", preset }, function(outcome)
      if outcome ~= "ok" then
        finish()
        settle(outcome)
        publish()
        return announce(outcome)
      end
      finish()
      announce("ok", label)
      read(kind == "input")
    end)
  end)
end

local function cycleOutput()
  read(false, function()
    if state ~= "running" then
      return announce(state)
    end
    local nextProfile = core.nextProfile(profiles("output"), active.output)
    if nextProfile == nil then
      return noctalia.notifyError(noctalia.tr("title"), noctalia.tr("no-profiles"))
    end
    switch("output", nextProfile.preset)
  end)
end

local function handle(request)
  if type(request) ~= "table" then
    return
  end
  if request.op == "cycle-output" then
    cycleOutput()
  elseif (request.op == "set-output" or request.op == "set-input") and type(request.preset) == "string" then
    switch(if request.op == "set-output" then "output" else "input", request.preset)
  elseif request.op == "refresh" then
    -- The launcher asks on every keystroke; a look already under way will
    -- publish soon enough.
    if not busy then
      read(request.input == true)
    end
  end
end

noctalia.state.watch("request", handle)

function onIpc(event, payload)
  if event == "cycle-output" then
    cycleOutput()
  elseif (event == "set-output" or event == "set-input") and type(payload) == "string" and payload ~= "" then
    switch(if event == "set-output" then "output" else "input", noctalia.string.trim(payload))
  else
    noctalia.log("stehgeiger: unknown event '" .. tostring(event) .. "'")
  end
end

-- A profile list edited in Settings shows up at once.
function onConfigChanged()
  publish()
end

-- A preset switched in the Easy Effects window, or Easy Effects started or
-- stopped: a slow look keeps the tile right. After a failed call it waits a
-- minute instead (core.nextDelay), so a broken Easy Effects is not hammered.
-- The tick is short and cheap; nextAt decides when a look is really due.
noctalia.setUpdateInterval(2000)
function update()
  if available and not busy and core.due(noctalia.nowMs(), nextAt) then
    read(false)
  end
end

if not available then
  noctalia.log("stehgeiger: easyeffects is not installed; staying idle")
end
read(false)
