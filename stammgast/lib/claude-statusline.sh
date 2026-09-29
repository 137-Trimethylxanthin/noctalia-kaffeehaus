#!/bin/sh
# Claude Code status line for Stammgast. Claude Code hands its status line a
# JSON document with the model, the context used, the session's cost and the
# account's usage limits; this keeps a copy for Stammgast's widgets, then
# prints a status line.
#
# Stammgast copies this file to its data directory on start. In
# ~/.claude/settings.json:
#
#   "statusLine": {
#     "type": "command",
#     "command": "sh ~/.local/state/noctalia/plugins/data/137-trimethylxanthin/stammgast/claude-statusline.sh"
#   }
#
# To keep a status line you already have, put its command after this one; it
# gets the same JSON and prints the line instead:
#
#   "command": "sh ~/.local/state/noctalia/plugins/data/137-trimethylxanthin/stammgast/claude-statusline.sh node ~/.claude/hud/omc-hud.mjs"

input=$(cat)

# Only in the user's own runtime directory: the JSON names folders and costs.
if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
  umask 077
  dir="$XDG_RUNTIME_DIR/stammgast/claude"
  if mkdir -p "$dir" 2>/dev/null; then
    id=$(printf '%s' "$input" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[A-Za-z0-9_-]*"' | head -n 1 | sed 's/.*"\([A-Za-z0-9_-]*\)"$/\1/')
    file="$dir/${id:-unknown}.json"
    # One line, so Stammgast can read every session in a single pass; written
    # aside and moved, so it is never read half-done.
    printf '%s' "$input" | tr -d '\n' > "$file.$$" && mv -f "$file.$$" "$file"
  fi
fi

if [ "$#" -gt 0 ]; then
  printf '%s' "$input" | "$@"
  exit
fi

# No other status line: a short one of its own.
field() { printf '%s' "$input" | sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\).*/\1/p" | head -n 1; }
model=$(field display_name)
context=$(printf '%s' "$input" | sed -n 's/.*"context_window"[^}]*"used_percentage"[[:space:]]*:[[:space:]]*\([0-9.]*\).*/\1/p' | head -n 1)
line=${model:-Claude}
[ -n "$context" ] && line="$line · context ${context%.*}%"
printf '%s\n' "$line"
