#!/bin/bash
# New-user simulation (M3 #60): runs scripts/install.sh and scripts/doctor.sh as if on a Mac account that has never seen
# Regista — a temp home (HOME and CFFIXED_USER_HOME, which Foundation reads instead of $HOME), its own support folder,
# download cache, Applications folder, Claude Code config (a stand-in `claude` that only writes the temp home) and Claude
# Desktop config — then asks the app's own regista-mcp for engines.status. Nothing outside the temp folder is written:
# no keychain, no signing, no real Claude config, no other Regista.app moved.
#
#   scripts/fresh-user.sh --app <Regista.app> [--tier base|medium] [--full] [--seed <lock id>=<file>]... [--keep] [--reuse <dir>]
#
#   --app    a built Regista.app (scripts/build-app.sh --no-open → build/Regista.app), installed with --app-bundle
#   --tier   base (default): the full installer on the Base tier. medium: the same, then Node.js + HyperFrames and the
#            English aligner for real, and the heavy Medium engines (WhisperX, VoxCPM2: several GB) with --only <id> --check
#   --full   with --tier medium: the full installer on the Medium tier instead (downloads about 12 GB)
#   --seed   put an already downloaded, verified file in the temp download cache (symlink, read only; still sha256-checked
#            by the installer), e.g. --seed ggml-large-v3-turbo=<path to ggml-large-v3-turbo.bin>
#   --keep   keep the temp folder (printed) instead of deleting it
#   --reuse  run again in a folder a previous --keep run left (its downloads and engines are reused, nothing re-downloaded)
# Exit 0 when the install and the doctor both pass. What only a real new account can prove is listed at the end.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"

APP_SRC=""; FU_TIER=base; KEEP=0; SEEDS=(); FULL=0; REUSE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP_SRC="${2:-}"; shift ;;
    --tier) FU_TIER="${2:-}"; shift ;;
    --seed) SEEDS+=("${2:-}"); shift ;;
    --keep) KEEP=1 ;;
    --full) FULL=1 ;;
    --reuse) REUSE="${2:-}"; [ -d "$REUSE/home" ] || die "--reuse needs a folder left by --keep"; KEEP=1; shift ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[ -x "$APP_SRC/Contents/MacOS/regista-mcp" ] || die "--app needs a Regista.app with Contents/MacOS/regista-mcp (scripts/build-app.sh --no-open)"
case "$FU_TIER" in base|medium) ;; *) die "--tier base or medium" ;; esac

if [ -n "$REUSE" ]; then T="$(cd "$REUSE" && pwd)"; else T="$(mktemp -d "${TMPDIR:-/tmp}/regista-fresh-user.XXXXXX")"; fi
[ "$KEEP" = 1 ] || trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H/Applications" "$T/cache" "$T/bin" "$T/logs" "$H/Library/Application Support/Claude"

# A stand-in for Claude Code's CLI: `mcp add/get/remove --scope user` on $HOME/.claude.json, the file the real one writes.
cat >"$T/bin/claude" <<'SH'
#!/bin/bash
cfg="$HOME/.claude.json"
case "$1 $2" in
  "mcp add") shift 2; while [ "$1" != "--" ]; do shift; done; shift
     /usr/bin/python3 -I -c 'import json,os,sys
p=sys.argv[1]; d=json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("mcpServers",{})["regista"]={"type":"stdio","command":sys.argv[2],"args":sys.argv[3:],"env":{}}
json.dump(d,open(p,"w"),indent=2)' "$cfg" "$@" ;;
  "mcp get") /usr/bin/python3 -I -c 'import json,sys
r=json.load(open(sys.argv[1])).get("mcpServers",{}).get("regista")
if not r: sys.exit(1)
print("regista:\n  Scope: User config\n  Type: stdio\n  Command: "+r["command"])' "$cfg" 2>/dev/null ;;
  "mcp remove") /usr/bin/python3 -I -c 'import json,sys
p=sys.argv[1]; d=json.load(open(p)); d.get("mcpServers",{}).pop("regista",None); json.dump(d,open(p,"w"),indent=2)' "$cfg" ;;
  *) echo "fake claude: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$T/bin/claude"
# What a user who tried Regista from a source folder before would have: Claude Desktop with another server and a regista
# entry pointing into a clone, which the installer must repoint to the app and keep the rest.
[ -f "$H/Library/Application Support/Claude/claude_desktop_config.json" ] || \
printf '{"preferences": {"x": 1}, "mcpServers": {"other": {"command": "/bin/echo"}, "regista": {"command": "%s/old-clone/.build/release/regista-mcp", "args": []}}}\n' \
  "$H" >"$H/Library/Application Support/Claude/claude_desktop_config.json"

for s in ${SEEDS[@]+"${SEEDS[@]}"}; do
  id="${s%%=*}"; file="${s#*=}"
  dest="$T/cache/${id%%:*}/$(lock_get "$id" 7 | sed 's#.*/##')"
  mkdir -p "$(dirname "$dest")"; [ -e "$dest" ] || ln -s "$file" "$dest"
done

export HOME="$H" CFFIXED_USER_HOME="$H" CLAUDE_CONFIG_DIR="$H/.claude" REGISTA_CACHE_DIR="$T/cache" REGISTA_APP_DIR="$H/Applications"
export PATH="$T/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
unset REGISTA_SUPPORT_DIR REGISTA_ENGINES REGISTA_ENGINE_SOCKET REGISTA_TIER
# Re-read the locations from the new HOME (lib.sh derives them from it).
. "$REPO/scripts/lib.sh"

rc=0
INSTALL_TIER=base; [ "$FU_TIER" = medium ] && [ "$FULL" = 1 ] && INSTALL_TIER=medium
step "1. scripts/install.sh --yes --tier $INSTALL_TIER --app-bundle (log: $T/logs/install.log)"
bash scripts/install.sh --yes --no-pull --tier "$INSTALL_TIER" --app-bundle "$APP_SRC" --claude both </dev/null >"$T/logs/install.log" 2>&1 || rc=1
tail -25 "$T/logs/install.log"
[ "$rc" = 0 ] && ok "installer finished" || bad "installer failed"

if [ "$FU_TIER" = medium ] && [ "$FULL" = 0 ] && [ "$rc" = 0 ]; then
  step "1b. Medium engines: the heavy ones planned only (--check), the light ones for real"
  for id in whisperx faster-whisper-model aligner-pt voxcpm voxcpm-weights; do bash scripts/install.sh --only "$id" --check --tier medium </dev/null | sed 's/^/  /'; done
  for id in node aligner-en; do
    bash scripts/install.sh --only "$id" --tier medium </dev/null >"$T/logs/only-$id.log" 2>&1 && ok "--only $id" || { bad "--only $id (log: $T/logs/only-$id.log)"; rc=1; }
  done
fi

step "2. scripts/doctor.sh (log: $T/logs/doctor.log)"
drc=0; bash scripts/doctor.sh --quick </dev/null >"$T/logs/doctor.log" 2>&1 || drc=1
cat "$T/logs/doctor.log"
[ "$drc" = 0 ] || rc=1

step "3. The Claude configs point to the app's own server"
MCP="$(bundled_mcp "$APP_DIR/Regista.app")"
"$PY" -I scripts/claude_desktop.py status "$DESKTOP_CONFIG" "$MCP" >/dev/null && ok "Claude Desktop → $MCP (other server kept: $("$PY" -I -c 'import json,sys; print(",".join(sorted(json.load(open(sys.argv[1]))["mcpServers"])))' "$DESKTOP_CONFIG"))" \
  || { bad "Claude Desktop: $(cat "$DESKTOP_CONFIG")"; rc=1; }
[ "$(claude mcp get regista | sed -n 's/^ *Command: //p')" = "$MCP" ] && ok "Claude Code → $MCP" || { bad "Claude Code: $(cat "$H/.claude.json" 2>/dev/null)"; rc=1; }
grep -rl "$REPO" "$DESKTOP_CONFIG" "$H/.claude.json" "$SUPPORT/engines.json" 2>/dev/null | sed 's/^/  ! points into the source folder: /' && rc=1

step "4. What only a real new macOS account can confirm"
cat <<'EOF'
  - Gatekeeper and TCC: the first launch from Finder, the camera / microphone / screen prompts, and that macOS keeps
    them across rebuilds with that account's own signing identity (created at its first build, in its own keychain).
  - Homebrew from zero (here the Mac's own Homebrew and its ffmpeg / cmake / uv are reused), and the Command Line Tools
    prompt on a Mac without them.
  - Downloading every model for real on that account's network (here the big ones come from --seed or are --check only).
  - Claude Desktop (a real install, signed in) reading the new config after ⌘Q, asking per tool, and driving the
    running app; the real `claude` CLI writing that account's ~/.claude.json.
  - The app's socket and windows: launching Regista.app as that user and Claude attaching to it live.
EOF
echo
[ "$KEEP" = 1 ] && echo "temp folder kept: $T"
if [ "$rc" = 0 ]; then ok "fresh-user simulation passed ($FU_TIER tier)"; else bad "fresh-user simulation failed (logs: $T/logs)"; fi
exit "$rc"
