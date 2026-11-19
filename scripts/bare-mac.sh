#!/bin/bash
# The bare-Mac check (#106, #8): what a person who downloaded Regista.app gets on a Mac without Apple's Command Line Tools
# and without Homebrew. Everything runs from the app's own files in a temporary home, with
#   - a `python3` first on the PATH that fails like the Command Line Tools stub (and writes down that it was called),
#   - no Homebrew folder on the PATH,
#   - every shell step of the installer traced (bash xtrace): a python3 call by absolute path is caught too.
# Steps: Settings › Engines' path for one Base engine (`regista-engine install <id>`: the app's EngineInstaller running the
# installer inside the app, exactly as the Motori screen does), then Settings › Claude's Claude Desktop connection (the
# same code, `regista-engine claude-desktop set`) on a config that already has another server.
# Nothing outside the temporary folder is written; the owner's support folder, caches and Claude configs are not read.
#
#   scripts/bare-mac.sh --app <Regista.app> [--engine <id>] [--seed <lock id>=<file>]... [--keep]
#
#   --app     a built Regista.app (scripts/build-app.sh --no-open → build.noindex/Regista.app)
#   --engine  the Base engine to install (default deepfilternet: a 28 MB pinned download)
#   --seed    an already downloaded file for the temporary download cache (still sha256-checked by the installer)
#   --keep    keep the temporary folder (printed)
# Exit 0 when every step passes.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

APP_SRC=""; ENGINE=deepfilternet; SEEDS=(); KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP_SRC="${2:-}"; shift ;;
    --engine) ENGINE="${2:-}"; shift ;;
    --seed) SEEDS+=("${2:-}"); shift ;;
    --keep) KEEP=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[ -x "$APP_SRC/Contents/MacOS/regista-engine" ] || die "--app needs a Regista.app with Contents/MacOS/regista-engine (scripts/build-app.sh --no-open)"
APP="$(cd "$APP_SRC" && pwd)"
HELPER_BIN="$APP/Contents/MacOS/regista-engine"

T="$(mktemp -d "${TMPDIR:-/tmp}/regista-bare-mac.XXXXXX")"
[ "$KEEP" = 1 ] || trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H/Library/Application Support/Claude" "$T/stub" "$T/cache" "$T/tmp" "$T/logs"

# What /usr/bin/python3 does on a Mac without the Command Line Tools: it asks to install them and fails.
cat >"$T/stub/python3" <<SH
#!/bin/sh
echo "python3 \$*" >> "$T/logs/python3-calls.log"
echo "xcode-select: note: No developer tools were found, requesting install." >&2
echo "If developer tools are located at a non-default location on disk, use \\\`sudo xcode-select --switch path/to/Xcode.app\\\` to specify the Xcode that you wish to use for command line developer tools, and cancel the installation dialog." >&2
exit 1
SH
chmod +x "$T/stub/python3"
ln -s python3 "$T/stub/python"
"$T/stub/python3" -c 'print(1)' >/dev/null 2>&1 && die "the python3 stub did not fail"
: >"$T/logs/python3-calls.log"

for s in ${SEEDS[@]+"${SEEDS[@]}"}; do
  id="${s%%=*}"; file="${s#*=}"
  dest="$T/cache/${id%%:*}/$(lock_get "$id" 7 | sed 's#.*/##')"
  mkdir -p "$(dirname "$dest")"; [ -e "$dest" ] || ln -s "$file" "$dest"
done

# The environment of an app opened from the Finder on that Mac: launchd's short PATH, with the stub first.
bare() {
  env -i HOME="$H" CFFIXED_USER_HOME="$H" USER="${USER:-person}" LOGNAME="${USER:-person}" TMPDIR="$T/tmp" LANG=en_US.UTF-8 \
    PATH="$T/stub:/usr/bin:/bin:/usr/sbin:/sbin" REGISTA_CACHE_DIR="$T/cache" REGISTA_LANG=en \
    SHELLOPTS=xtrace PS4='+ ' "$@"
}

rc=0
# trace_clean <log> <what>: no python and no Homebrew in what the installer ran.
trace_clean() {
  local hits
  # A command in command position (assignments such as PY=… are not runs).
  hits="$(grep -E '^\++ (([^ =]*/)?(python3?|xcrun|xcode-select|brew|cmake|uv|swift|clang)|/opt/homebrew/\S*|/usr/local/\S*)( |$)' "$1" || true)"
  if [ -n "$hits" ]; then bad "$2 ran developer tools:"; printf '%s\n' "$hits" | head -10 | sed 's/^/      /'; rc=1
  else ok "$2: $(grep -cE '^\++ ' "$1") traced shell steps, none runs python3, Homebrew or the Command Line Tools"; fi
}

step "1. Settings › Engines: install $ENGINE (log: $T/logs/install.log)"
case "$(bare /usr/bin/printenv PATH)" in *homebrew*) die "Homebrew on the PATH of the check" ;; esac
irc=0; bare "$HELPER_BIN" install "$ENGINE" >"$T/logs/install.log" 2>&1 || irc=$?
grep -vE '^\++ ' "$T/logs/install.log" | sed 's/^/  /' | tail -12
if [ "$irc" = 0 ]; then ok "regista-engine install $ENGINE finished"; else bad "regista-engine install $ENGINE failed (exit $irc)"; rc=1; fi
trace_clean "$T/logs/install.log" "the installer"
CONFIG_FILE="$H/Library/Application Support/Regista/engines.json"
if [ -f "$CONFIG_FILE" ]; then ok "engines.json written: $(tr -d '\n' <"$CONFIG_FILE" | sed 's/  */ /g' | cut -c1-160)"
else bad "no engines.json in the temporary home"; rc=1; fi

step "2. Settings › Claude: connect Claude Desktop (the same code as the app's button)"
CFG="$H/Library/Application Support/Claude/claude_desktop_config.json"
printf '{"preferences": {"x": 1}, "mcpServers": {"other": {"command": "/bin/echo"}}}\n' >"$CFG"
MCP="$APP/Contents/MacOS/regista-mcp"
out="$(bare "$HELPER_BIN" claude-desktop set "$CFG" "$MCP" 2>&1)"; crc=$?
printf '%s\n' "$out" | sed 's/^/  /'
if [ "$crc" = 0 ] && bare "$HELPER_BIN" claude-desktop status "$CFG" "$MCP" >/dev/null 2>&1 \
   && grep -q '"other"' "$CFG" && grep -q '"preferences"' "$CFG" && [ -n "$(find "$(dirname "$CFG")" -name 'claude_desktop_config.json.regista-backup-*')" ]; then
  ok "Claude Desktop → $MCP (other server and preferences kept, backup made)"
else bad "Claude Desktop connection: $(cat "$CFG")"; rc=1; fi

step "3. python3 calls"
if [ -s "$T/logs/python3-calls.log" ]; then bad "python3 was called:"; sed 's/^/      /' "$T/logs/python3-calls.log"; rc=1
else ok "python3 never called"; fi

echo
[ "$KEEP" = 1 ] && echo "temp folder kept: $T"
if [ "$rc" = 0 ]; then ok "bare-Mac check passed"; else bad "bare-Mac check failed (logs: $T/logs)"; fi
exit "$rc"
