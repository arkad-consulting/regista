#!/bin/bash
# Replays a scenario through the regista-mcp server over stdio (JSON-RPC, like Claude Code does).
# Usage: scripts/scenario.sh <scenario.json> [--work <dir>] [--engine app]
# --engine app replays on the running Regista app (MCP → socket → app); default: headless server.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -ge 1 ] || { echo "usage: scripts/scenario.sh <scenario.json> [--work <dir>] [--engine app]" >&2; exit 2; }

swift build --product regista-mcp >&2
swift build --product regista-engine >&2
BIN="$(swift build --show-bin-path)"
"$BIN/regista-engine" run "$@" --mcp "$BIN/regista-mcp"
