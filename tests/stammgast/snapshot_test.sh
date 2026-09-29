#!/usr/bin/env bash
# Runs the SNAPSHOT and LID_ACTION scripts from watch.luau with fake busctl,
# ps and systemctl on the PATH, and checks what they print and do.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WATCH=$HERE/../../stammgast/watch.luau
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

extract() { awk -v name="$1" '$0 == "local " name " = [[" { f = 1; next } f && /^\]\]/ { exit } f' "$WATCH"; }
extract SNAPSHOT > "$OUT/snapshot.sh"
extract LID_ACTION > "$OUT/lid_action.sh"

mkdir "$OUT/bin"
cat > "$OUT/bin/busctl" <<'SH'
#!/bin/sh
eval "v=\${FAKE_$5:-}"
[ -n "$v" ] && echo "$v"
SH
cat > "$OUT/bin/ps" <<'SH'
#!/bin/sh
cat "$FAKE_PS"
SH
cat > "$OUT/bin/systemctl" <<'SH'
#!/bin/sh
echo "systemctl $*" >> "$FAKE_LOG"
SH
cat > "$OUT/bin/loginctl" <<'SH'
#!/bin/sh
echo "loginctl $*" >> "$FAKE_LOG"
SH
chmod +x "$OUT/bin/"*
export PATH="$OUT/bin:$PATH" FAKE_PS="$OUT/ps.txt" FAKE_LOG="$OUT/log.txt"

fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=$((fails + 1)); fi; }

long=$(printf 'x%.0s' $(seq 1 3000))
{
  echo "  101 1 /home/me/.local/bin/claude"
  echo "  102 1 /home/me/.local/bin/claude --chrome-native-host"
  echo "  103 1 node --no-warnings /usr/lib/node_modules/@openai/codex/bin/codex.js"
  echo "  104 1 /usr/lib/zen-browser/zen-bin -contentproc -isForBrowser -prefsLen 1 -prefMapSize 2 -jsInitLen 3 -parentBuildID 4 /tmp/claude-1000/profile $long"
  echo "  105 1 /usr/bin/zsh -c source /home/me/.claude/shell-snapshots/snap.sh"
  echo "  106 1 /usr/bin/CLAUDE"
  echo "  107 1 python3 -u /home/me/.local/bin/aider --model x $long"
  echo "  $$ 1 /usr/bin/claude --this-shell"
  for i in $(seq 1 100); do echo "  $((200 + i)) 1 /usr/bin/claude"; done
} > "$FAKE_PS"

names=$(printf 'claude\ncodex\naider')
export CLAUDE_CONFIG_DIR="$OUT/claude" XDG_RUNTIME_DIR="$OUT/run" CODEX_HOME="$OUT/codex"
mkdir -p "$CLAUDE_CONFIG_DIR/sessions" "$XDG_RUNTIME_DIR/stammgast/claude" "$CODEX_HOME/sessions/2026/09/29"
printf '{"pid":%s,\n"sessionId":"s1","status":"busy"}' $$ > "$CLAUDE_CONFIG_DIR/sessions/$$.json"
printf '{"pid":999999,"status":"busy"}' > "$CLAUDE_CONFIG_DIR/sessions/999999.json"
printf '{"session_id":"s1","rate_limits":{}}' > "$XDG_RUNTIME_DIR/stammgast/claude/s1.json"
printf '{"session_id":"old"}' > "$XDG_RUNTIME_DIR/stammgast/claude/old.json"; touch -d '2 days ago' "$XDG_RUNTIME_DIR/stammgast/claude/old.json"
{ echo '{"type":"session_meta"}'; echo '{"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":1}}}}'; echo '{"payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":2}}}}'; echo '{"payload":{"type":"token_count","rate_limits":null}}'; echo '{"type":"other"}'; } > "$CODEX_HOME/sessions/2026/09/29/rollout-x.jsonl"
FAKE_LidClosed="b true" FAKE_Docked="b false" sh "$OUT/snapshot.sh" "$names" > "$OUT/snap.txt"
body=$(sed -n '/^ps$/,$p' "$OUT/snap.txt" | tail -n +2)

echo "== snapshot =="
check "lid"                          'grep -qx "lid closed" "$OUT/snap.txt"'
check "not docked"                   'grep -qx "docked 0" "$OUT/snap.txt"'
check "a native binary"              'grep -q "^ *101 " <<<"$body"'
check "a helper too (lib/stay drops it)" 'grep -q "^ *102 " <<<"$body"'
check "an interpreter with flags"    'grep -q "^ *103 " <<<"$body"'
check "words past the ninth are not looked at" '! grep -q "^ *104 " <<<"$body"'
check "nor a shell sourcing a file"  '! grep -q "^ *105 " <<<"$body"'
check "names match in any case"      'grep -q "^ *106 " <<<"$body"'
check "pid, parent pid, ticks, command"  'grep -qE "^101 1 [0-9]+ /home/me/.local/bin/claude$" <<<"$body"'
check "real ticks from /proc"         'grep -qE "^$$ 1 [0-9]+ /usr/bin/claude --this-shell" <<<"$body"'
check "a live Claude session, on one line" "grep -qx 'cs {\"pid\":$$,\"sessionId\":\"s1\",\"status\":\"busy\"}' \"\$OUT/snap.txt\""
check "not a crashed one"             '! grep -q "999999" "$OUT/snap.txt"'
check "old status lines are cleared"  '[ ! -e "$XDG_RUNTIME_DIR/stammgast/claude/old.json" ]'
check "a saved status line with its mtime" 'grep -qE "^sl [0-9]+ \{\"session_id\":\"s1\"" "$OUT/snap.txt"'
check "the latest Codex limits, not a null" 'grep -qE "^cx [0-9]+ .*\"used_percent\":2" "$OUT/snap.txt"'
check "long lines are cut"           '[ "$(grep "^ *107 " <<<"$body" | wc -c)" -le 513 ]'
check "at most 64 processes"         '[ "$(wc -l <<<"$body")" -le 64 ]'
FAKE_LidClosed="b false" FAKE_Docked="b true" sh "$OUT/snapshot.sh" "" > "$OUT/snap2.txt"
check "no names: no processes"       '[ -z "$(sed -n "/^ps$/,\$p" "$OUT/snap2.txt" | tail -n +2)" ]'
check "docked"                       'grep -qx "docked 1" "$OUT/snap2.txt" && grep -qx "lid open" "$OUT/snap2.txt"'
FAKE_Docked="" sh "$OUT/snapshot.sh" "claude" > "$OUT/snap3.txt"
check "busctl failing: no lid line"  '! grep -q "^lid" "$OUT/snap3.txt"'
check "... and no docked line"       '! grep -q "^docked" "$OUT/snap3.txt"'
{ echo "  900 1 node --a --b --c --d --e --f /usr/bin/codex"; } > "$FAKE_PS"
check "an interpreter with six flags" '[ -n "$(sh "$OUT/snapshot.sh" codex | grep "^ *900 ")" ]'

echo "== lid action =="
act() { : > "$FAKE_LOG"; sh "$OUT/lid_action.sh" "$1"; cat "$FAKE_LOG"; }
export FAKE_HandleLidSwitch='s "suspend"' FAKE_HandleLidSwitchExternalPower='s ""' FAKE_HandleLidSwitchDocked='s "ignore"'
check "lid open: nothing"            '[ -z "$(FAKE_LidClosed="b false" act battery)" ]'
check "closed: suspend"              '[ "$(FAKE_LidClosed="b true" act battery)" = "systemctl suspend" ]'
check "on mains with no own action: suspend" '[ "$(FAKE_LidClosed="b true" act ac)" = "systemctl suspend" ]'
check "on mains with its own action" '[ "$(FAKE_LidClosed="b true" FAKE_HandleLidSwitchExternalPower="s \"lock\"" act ac)" = "loginctl lock-session" ]'
check "docked: ignore"               '[ -z "$(FAKE_LidClosed="b true" FAKE_Docked="b true" act battery)" ]'
check "hibernate"                    '[ "$(FAKE_LidClosed="b true" FAKE_HandleLidSwitch="s \"hibernate\"" act battery)" = "systemctl hibernate" ]'
check "ignore"                       '[ -z "$(FAKE_LidClosed="b true" FAKE_HandleLidSwitch="s \"ignore\"" act battery)" ]'
check "unknown action: nothing"      '[ -z "$(FAKE_LidClosed="b true" FAKE_HandleLidSwitch="s \"reboot; rm\"" act battery)" ]'

echo "== status line =="
SL=$HERE/../../stammgast/lib/claude-statusline.sh
doc='{"session_id":"abc-123","model":{"id":"x","display_name":"Opus 5.5"},
"context_window":{"used_percentage":42.7},"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1790700000}}}'
out=$(printf '%s' "$doc" | XDG_RUNTIME_DIR="$OUT/run2" sh "$SL")
check "its own line"                 '[ "$out" = "Opus 5.5 · context 42%" ]'
check "saved per session, on one line" '[ "$(wc -l < "$OUT/run2/stammgast/claude/abc-123.json")" -eq 0 ] && grep -q "five_hour" "$OUT/run2/stammgast/claude/abc-123.json"'
out=$(printf '%s' "$doc" | XDG_RUNTIME_DIR="$OUT/run2" sh "$SL" sh -c 'grep -c session_id')
check "hands the same JSON to a chained status line" '[ "$out" = "1" ]'
out=$(printf '{}' | XDG_RUNTIME_DIR="$OUT/run2" sh "$SL")
check "no model: a plain line"       '[ "$out" = "Claude" ] && [ -f "$OUT/run2/stammgast/claude/unknown.json" ]'
out=$(printf '{"session_id":"../../evil"}' | XDG_RUNTIME_DIR="$OUT/run2" sh "$SL")
check "a strange session id stays inside" '[ ! -e "$OUT/evil.json" ] && [ -f "$OUT/run2/stammgast/claude/unknown.json" ]'

out=$(printf '%s' "$doc" | env -u XDG_RUNTIME_DIR HOME="$OUT/home" TMPDIR="$OUT/tmp" sh "$SL")
check "no runtime dir: nothing saved, still a line" '[ "$out" = "Opus 5.5 · context 42%" ] && [ ! -e /tmp/stammgast/claude/abc-123.json ]'
check "saved files are private"      '[ "$(stat -c %a "$OUT/run2/stammgast/claude/abc-123.json")" = 600 ]'

[ "$fails" -eq 0 ] && echo "all ok" || { echo "$fails failed"; exit 1; }
