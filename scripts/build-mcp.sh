#!/bin/bash
# Builds the release regista-mcp (and regista-engine) that .mcp.json and scripts/g0.sh launch:
# .build/release/regista-mcp. Claude Code does not rebuild it — run this after every pull or change,
# or the MCP session silently runs the old tools. Prints the binary path.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Build $(scripts/build-stamp.sh | cut -d' ' -f1)" >&2   # the id engines.status reports (BuildStamp.swift)
swift build -c release --product regista-mcp >&2
swift build -c release --product regista-engine >&2
BIN="$(swift build -c release --show-bin-path)"
echo "$BIN/regista-mcp"
