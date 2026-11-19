#!/bin/bash
# Builds the release regista-mcp (and regista-engine) that .mcp.json and scripts/g0.sh launch:
# .build/release/regista-mcp. Claude Code does not rebuild it — run this after every pull or change,
# or the MCP session silently runs the old tools. Prints the binary path.
set -euo pipefail
cd "$(dirname "$0")/.."
echo "Build $(scripts/build-stamp.sh | cut -d' ' -f1)" >&2   # the id engines.status reports (BuildStamp.swift)
# REGISTA_SWIFT_BUILD_FLAGS: the release build's extra flags (scripts/build-app.sh), the same for both products.
# shellcheck disable=SC2086
swift build -c release ${REGISTA_SWIFT_BUILD_FLAGS:-} --product regista-mcp >&2
# shellcheck disable=SC2086
swift build -c release ${REGISTA_SWIFT_BUILD_FLAGS:-} --product regista-engine >&2
BIN="$(swift build -c release --show-bin-path)"
echo "$BIN/regista-mcp"
