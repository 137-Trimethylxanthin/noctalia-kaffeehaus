#!/usr/bin/env bash
# Runs the tests for Stammgast under Lua 5.4: lib/stay.luau, which turns a
# snapshot of the lid, the battery and the process list into what to hold, and
# watch.luau itself against a fake Noctalia host (commands, clock and
# inhibitor streams are the test's). Both are converted with Fiaker's
# transpiler, run through uv (see tests/fiaker/run.sh for why). logind itself
# is not covered here.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

(cd "$OUT" && uv run --quiet "$HERE/../fiaker/transpile.py" "$HERE"/../../stammgast/lib/stay.luau "$HERE"/../../stammgast/lib/agents.luau "$HERE"/../../stammgast/lib/look.luau "$HERE"/../../stammgast/watch.luau >/dev/null)
for f in "$OUT"/lib/*.luau; do mv "$f" "${f%.luau}.lua"; done

cp stay_test.lua agents_test.lua look_test.lua watch_test.lua ../haeubchen/json.lua "$OUT/"
cd "$OUT"
echo "--- stay ---"; lua5.4 stay_test.lua
echo "--- agents ---"; lua5.4 agents_test.lua
echo "--- look ---"; lua5.4 look_test.lua
echo "--- watch ---"; lua5.4 watch_test.lua
echo "--- snapshot ---"; "$HERE/snapshot_test.sh"
