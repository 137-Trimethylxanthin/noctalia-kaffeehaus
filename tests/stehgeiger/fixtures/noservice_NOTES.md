EasyEffects 8.3.2, no service running (captured 2026-11-08):
`-a output`, `-p` and `-b 3` print their answer and then do NOT exit: the CLI
process becomes a full EasyEffects instance (it creates
$XDG_RUNTIME_DIR/EasyEffectsServer and PipeWire nodes, and opens a window) and
keeps running. `timeout 8` killed each one (exit 124). This is why the plugin never
spawns easyeffects unless the socket exists AND `pgrep -x easyeffects` finds it.

Stale socket (service killed with `kill -9`): the socket file stays behind, and
`-a output` behaves exactly like the no-service case: it prints "None", becomes
an instance and hangs (`timeout 6` killed it, exit 124). So the socket check
alone is not enough; the `pgrep -x easyeffects` check is what stops the spawn.

Service running (`easyeffects --service-mode`): `-a output` and `-a input` print
an empty line (no preset loaded yet); `-p` prints "No output presets." /
"No input presets."; `-b 3` prints "2" (bypass off); every exit code is 0,
and no extra process is started.
