#!/usr/bin/env bash
# Runs the pure-logic tests for Stehgeiger under Lua 5.4: lib/core.luau, which
# reads what `easyeffects -a` printed (the real EasyEffects 8.3.2 answers in
# fixtures/), turns the profiles setting and the preset files into the list
# the tile cycles through, and decides when it is safe and worth asking again.
# The module is converted with Fiaker's transpiler, run through uv (see
# tests/fiaker/run.sh for why). Talking to Easy Effects needs a running
# session and the Noctalia host, so that is not covered here.
set -euo pipefail
cd "$(dirname "$0")"
HERE=$PWD

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

(cd "$OUT" && uv run --quiet "$HERE/../fiaker/transpile.py" "$HERE"/../../stehgeiger/lib/core.luau >/dev/null)
for f in "$OUT"/lib/*.luau; do mv "$f" "${f%.luau}.lua"; done

cp core_test.lua "$OUT/"
cd "$OUT"
echo "--- core ---"; FIXTURES="$HERE/fixtures" lua5.4 core_test.lua
