#!/bin/bash
# The app gates (issue #2), on the running Regista app:
#  1. replays Tests/Scenarios/wesites-v1.json through regista-mcp → engine socket → the app's engine;
#  2. Tests/Scenarios/app-ui.json: the app's project.state is that edit, ui.screenshot of Pro and Quick
#     (1440×900, 1920×1080) shows it, preview.frame + frame.render at five times;
#  3. preview parity: SSIM (ffmpeg) of each preview frame against frame.render's, gate ≥ 0.98.
# Usage: scripts/app-check.sh <outdir> [--no-replay]     (start the app first: scripts/build-app.sh)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: scripts/app-check.sh <outdir> [--no-replay]}"
SOCK="${REGISTA_ENGINE_SOCKET:-$HOME/Library/Application Support/Regista/engine.sock}"
[ -S "$SOCK" ] || { echo "Regista is not running (no socket at $SOCK): open build/Regista.app" >&2; exit 1; }
FFMPEG="${REGISTA_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
mkdir -p "$OUT"

if [ "${2:-}" != "--no-replay" ]; then
  scripts/scenario.sh Tests/Scenarios/wesites-v1.json --work "$OUT/v1" --engine app
fi
scripts/scenario.sh Tests/Scenarios/app-ui.json --work "$OUT" --engine app

echo "preview parity (SSIM All, preview.frame vs frame.render):"
fail=0
for f in "$OUT"/parity/export/frame-*.png; do
  n="$(basename "$f")"
  s="$("$FFMPEG" -hide_banner -i "$OUT/parity/preview/$n" -i "$f" -lavfi ssim -f null - 2>&1 | sed -n 's/.*All:\([0-9.]*\).*/\1/p' | tail -1)"
  ok="$(awk -v s="$s" 'BEGIN { print (s >= 0.98) ? "ok" : "FAIL" }')"
  echo "  $n  $s  $ok"
  [ "$ok" = ok ] || fail=1
done
[ "$fail" = 0 ] && echo "✓ app gates passed" || { echo "✗ preview parity below 0.98" >&2; exit 1; }
