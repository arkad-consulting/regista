#!/bin/bash
# The bare-Mac check (#106, #8): what a person who downloaded Regista.app gets on a Mac without Apple's Command Line Tools
# and without Homebrew. Everything runs from the app's own files in a temporary home, with
#   - a `python3` first on the PATH that fails like the Command Line Tools stub (and writes down that it was called),
#   - no Homebrew folder on the PATH,
#   - every shell step of the installer traced (bash xtrace): a python3 call by absolute path is caught too.
# With an app that ships its engines, first the first open on that empty home (#112): no engines.json, no folder in
# Movies, no transcription model — what engines.status and a transcription attempt answer through regista-engine, then
# again once the model is installed (seeded from --seed, never downloaded by the check).
# Steps: Settings › Engines' path for one Base engine (`regista-engine install <id>`: the app's EngineInstaller running the
# installer inside the app, exactly as the Motori screen does), then Settings › Claude's Claude Desktop connection (the
# same code, `regista-engine claude-desktop set`) on a config that already has another server. With an app that ships
# its engines (scripts/build-app.sh --bundle-engines, #107), a first reel too, headless through regista-engine with the
# shipped helpers only: a synthetic take (macOS's `say` into a file, nothing plays; the picture and the file made by the
# shipped ffmpeg) imported, transcribed by the shipped whisper-cli, captioned, its voice cleaned by the shipped
# deep-filter, exported 9:16, and the export probed by the shipped ffprobe. Then the Medium tier's uv step (#109): the
# pinned uv and Python installed through Settings › Engines' path, `--check` of WhisperX and VoxCPM2, and with --uv-sync
# one real `uv sync` of the WhisperX environment (about 1 GB of packages, its own download cache in the temporary folder).
# Nothing outside the temporary folder is written; the owner's support folder, caches and Claude configs are not read.
#
#   scripts/bare-mac.sh --app <Regista.app> [--engine <id>] [--seed <lock id>=<file>]... [--uv-sync] [--keep]
#
#   --app     a built Regista.app (scripts/build-app.sh --no-open → build.noindex/Regista.app)
#   --engine  the Base engine to install (default: deepfilternet, a 28 MB pinned download; whisper-model with an app that
#             ships its engines: the one Base download left, give it with --seed ggml-large-v3-turbo=<file>)
#   --seed    an already downloaded file for the temporary download cache (still sha256-checked by the installer)
#   --uv-sync also build the WhisperX environment for real with the pinned uv (downloads its packages)
#   --keep    keep the temporary folder (printed)
# Exit 0 when every step passes.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

APP_SRC=""; ENGINE=""; SEEDS=(); KEEP=0; UV_SYNC=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP_SRC="${2:-}"; shift ;;
    --engine) ENGINE="${2:-}"; shift ;;
    --seed) SEEDS+=("${2:-}"); shift ;;
    --keep) KEEP=1 ;;
    --uv-sync) UV_SYNC=1 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[ -x "$APP_SRC/Contents/MacOS/regista-engine" ] || die "--app needs a Regista.app with Contents/MacOS/regista-engine (scripts/build-app.sh --no-open)"
APP="$(cd "$APP_SRC" && pwd)"
HELPER_BIN="$APP/Contents/MacOS/regista-engine"
SHIPPED=0; [ -x "$APP/Contents/Helpers/ffmpeg" ] && SHIPPED=1
if [ -z "$ENGINE" ]; then if [ "$SHIPPED" = 1 ]; then ENGINE=whisper-model; else ENGINE=deepfilternet; fi; fi

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
  # A seed that is not there would turn into a real download: a check never downloads a model.
  [ -f "$file" ] || die "--seed $id: no file at $file"
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
  hits="$(grep -E '^\++ (([^ =]*/)?(python3?|xcrun|xcode-select|brew|cmake|swift|clang)|/opt/homebrew/\S*|/usr/local/\S*)( |$)' "$1" || true)"
  if [ -n "$hits" ]; then bad "$2 ran developer tools:"; printf '%s\n' "$hits" | head -10 | sed 's/^/      /'; rc=1
  else ok "$2: $(grep -cE '^\++ ' "$1") traced shell steps, none runs python3, Homebrew or the Command Line Tools"; fi
}

M="$T/media"; mkdir -p "$M"
CONFIG_FILE="$H/Library/Application Support/Regista/engines.json"
# first_open <name> <expectations of the transcription step>: engines.status and a transcription of the synthetic take,
# headless through regista-engine on the temporary home (what the app's engine answers there).
first_open() {
  cat >"$T/$1.json" <<JSON
{"name": "$1", "description": "The first open of a downloaded app on an empty home (#112).", "steps": [
  {"command": "engines.status", "expect": {$2}, "show": ["result.configLoaded", "result.tier", "result.defaults.transcription"]},
  {"command": "project.new", "params": {"name": "$1", "directory": "\${WORK}"}},
  {"command": "media.import", "params": {"path": "$M/take.mov"}, "capture": {"raw": "result.asset.id"}},
  {"command": "media.extractAudio", "params": {"assetId": "\${raw}"}},
  {"command": "transcript.run", "params": {"assetId": "\${raw}", "language": "en"}, $3}
]}
JSON
  bare "$HELPER_BIN" run "$T/$1.json" --work "$T/work-$1" >"$T/logs/$1.log" 2>&1
}

if [ "$SHIPPED" = 1 ]; then
  step "0. First open on an empty home (log: $T/logs/first-open.log)"
  if [ ! -e "$CONFIG_FILE" ] && [ ! -e "$H/Movies/Regista" ] && [ -z "$(find "$H/Library/Application Support/Regista" -name 'ggml-*.bin' 2>/dev/null)" ]; then
    ok "the home is empty: no engines.json, no folder in Movies, no transcription model"
  else bad "the temporary home is not empty"; rc=1; fi
  # A voice in a file (say writes the file, nothing is played), a picture and the take made by the shipped ffmpeg.
  /usr/bin/say -o "$M/speech.aiff" "Hello. This is a short test of Regista on a new Mac. The captions come from the voice." \
    || die "say could not write the speech file"
  dur="$(bare "$APP/Contents/Helpers/ffprobe" -v error -show_entries format=duration -of csv=p=0 "$M/speech.aiff" 2>/dev/null | grep -E '^[0-9]' | head -1)"
  bare "$APP/Contents/Helpers/ffmpeg" -nostdin -hide_banner -loglevel error -y -f lavfi -i "testsrc2=s=1080x1920:r=30:d=${dur:-6}" \
    -i "$M/speech.aiff" -c:v h264_videotoolbox -b:v 4M -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$M/take.mov" >>"$T/logs/reel.log" 2>&1 \
    && ok "synthetic take made by the shipped ffmpeg (${dur:-?} s, H.264 VideoToolbox + AAC)" || { bad "the shipped ffmpeg could not make the take"; rc=1; }
  if first_open first-open '"result.configLoaded": false, "result.defaults.transcription": "whisper.cpp", "result.engines": {"includes": [{"id": "whisper-model", "state": "missing"}, {"id": "whisper.cpp", "shipped": true}]}' \
       '"expectError": "whisper model not found"'; then
    ok "engines.status: no engines.json, the model missing, whisper.cpp the engine to use; a transcription attempt fails with «whisper model not found at …» (no other engine named)"
  else bad "the first open answered otherwise:"; grep -vE '^\++ ' "$T/logs/first-open.log" | tail -12 | sed 's/^/      /'; rc=1; fi
  grep -E 'configLoaded|tier|transcription' "$T/logs/first-open.log" | head -3 | sed 's/^/  /'
fi

step "1. Settings › Engines: install $ENGINE (log: $T/logs/install.log)"
case "$(bare /usr/bin/printenv PATH)" in *homebrew*) die "Homebrew on the PATH of the check" ;; esac
irc=0; bare "$HELPER_BIN" install "$ENGINE" >"$T/logs/install.log" 2>&1 || irc=$?
grep -vE '^\++ ' "$T/logs/install.log" | sed 's/^/  /' | tail -12
if [ "$irc" = 0 ]; then ok "regista-engine install $ENGINE finished"; else bad "regista-engine install $ENGINE failed (exit $irc)"; rc=1; fi
trace_clean "$T/logs/install.log" "the installer"
if [ -f "$CONFIG_FILE" ]; then ok "engines.json written: $(tr -d '\n' <"$CONFIG_FILE" | sed 's/  */ /g' | cut -c1-160)"
else bad "no engines.json in the temporary home"; rc=1; fi

if [ "$SHIPPED" = 1 ] && [ "$ENGINE" = whisper-model ]; then
  step "1b. The same first open once the model is there (log: $T/logs/after-model.log)"
  if first_open after-model '"result.engines": {"includes": [{"id": "whisper-model", "state": "installed"}]}, "result.defaults.transcription": "whisper.cpp"' \
       '"expect": {"result.engine": "whisper.cpp", "result.words": {"min": 8}}, "show": ["result.engine", "result.note", "result.text"]'; then
    ok "engines.status: the model installed; the transcription without an engine named ran with whisper.cpp"
  else bad "after the model:"; grep -vE '^\++ ' "$T/logs/after-model.log" | tail -12 | sed 's/^/      /'; rc=1; fi
  grep -E 'result\.(engine|note|text)' "$T/logs/after-model.log" | head -3 | cut -c1-200 | sed 's/^/  /'
fi

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

if [ "$SHIPPED" = 1 ]; then
  step "3. A first reel with the shipped helpers only (log: $T/logs/reel.log)"
  cat >"$T/reel.json" <<JSON
{"name": "bare-mac-reel", "description": "A first reel on a bare Mac, shipped helpers only.", "steps": [
  {"command": "engines.status", "expect": {"result.engines.0.id": "ffmpeg", "result.engines.0.shipped": true, "result.engines.1.shipped": true, "result.engines.2.shipped": true, "result.engines.5.id": "deepfilternet", "result.engines.5.shipped": true}},
  {"command": "project.new", "params": {"name": "bare-mac-reel", "directory": "\${WORK}"}},
  {"command": "media.import", "params": {"path": "$M/take.mov"}, "capture": {"raw": "result.asset.id"}},
  {"command": "media.extractAudio", "params": {"assetId": "\${raw}"}},
  {"command": "transcript.run", "params": {"assetId": "\${raw}", "language": "en", "engine": "whisper.cpp"}, "expect": {"result.words": {"min": 8}}},
  {"command": "script.fromTranscript", "expect": {"result.set": true}},
  {"command": "takes.list"},
  {"command": "edit.autoCut"},
  {"command": "audio.clean", "expect": {"result.loudness.integrated": {"approx": -15, "tol": 1}}},
  {"command": "captions.generate", "params": {"keywords": ["REGISTA"]}, "expect": {"result.chunks": {"min": 2}}},
  {"command": "export.render", "params": {"path": "\${WORK}/bare-mac-reel.mp4", "preset": "9:16"}},
  {"command": "media.probe", "params": {"path": "\${WORK}/bare-mac-reel.mp4"}, "expect": {"result.video.width": 1080, "result.video.height": 1920}},
  {"command": "project.save"}
]}
JSON
  if bare "$HELPER_BIN" run "$T/reel.json" --work "$T/work" >>"$T/logs/reel.log" 2>&1; then
    ok "import → transcription → cut → clean voice → captions → export 9:16 ($(stat -f %z "$T/work/bare-mac-reel.mp4" 2>/dev/null || echo ?) bytes)"
  else bad "the first reel failed:"; grep -vE '^\++ ' "$T/logs/reel.log" | tail -15 | sed 's/^/      /'; rc=1; fi
  grep -E "transcript|words|chunks" "$T/logs/reel.log" | head -4 | sed 's/^/  /'
fi

step "4. The Medium tier's uv step (log: $T/logs/uv.log)"
urc=0; bare "$HELPER_BIN" install uv >"$T/logs/uv.log" 2>&1 || urc=$?
grep -vE '^\++ ' "$T/logs/uv.log" | grep -E '✓|✗' | sed 's/^/  /'
if [ "$urc" = 0 ]; then ok "regista-engine install uv finished"; else bad "regista-engine install uv failed (exit $urc)"; rc=1; fi
trace_clean "$T/logs/uv.log" "the uv step"
UVB="$(find "$H/Library/Application Support/Regista/engines/uv" -name uv -type f -perm +111 2>/dev/null | head -1)"
[ -n "$UVB" ] && ok "uv: $("$UVB" --version) ($(du -sh "$(dirname "$UVB")" | cut -f1)), Python: $(find "$H/Library/Application Support/Regista/engines/python" -maxdepth 1 -name 'cpython-*' -type d | sed 's#.*/##' | tr '\n' ' ')($(du -sh "$H/Library/Application Support/Regista/engines/python" | cut -f1))" \
  || { bad "no uv in the engines folder"; rc=1; }
[ ! -e "$H/.local/bin/python3.12" ] || { bad "a Python link was left in ~/.local/bin"; rc=1; }
for id in whisperx voxcpm; do
  out="$(bare /bin/bash "$APP/Contents/Resources/Installer/scripts/install.sh" --only "$id" --check --tier medium 2>&1)" \
    && ok "--only $id --check: $(printf '%s\n' "$out" | grep -vE '^\++ ' | tail -1)" || { bad "--only $id --check: $out"; rc=1; }
done
if [ "$UV_SYNC" = 1 ] && [ -n "$UVB" ]; then
  W="$T/wx"; mkdir -p "$W"
  cp "$APP/Contents/Resources/Installer/engines/whisperx/pyproject.toml" "$APP/Contents/Resources/Installer/engines/whisperx/uv.lock" "$W/"
  s0=$(date +%s)
  if bare env UV_PYTHON_INSTALL_DIR="$H/Library/Application Support/Regista/engines/python" UV_PYTHON_DOWNLOADS=never \
       UV_PYTHON="$(lock_get uv-python 2 | cut -d+ -f1)" UV_CACHE_DIR="$T/uv-cache" "$UVB" sync --frozen --quiet --project "$W" >>"$T/logs/uv.log" 2>&1; then
    ok "uv sync --frozen of WhisperX: $(( $(date +%s) - s0 )) s, $(du -sh "$T/uv-cache" | cut -f1) downloaded and cached, environment $(du -sh "$W/.venv" | cut -f1), $("$W/.venv/bin/python" -I -c 'import sys; print(sys.version.split()[0])')"
  else bad "uv sync of WhisperX failed (log: $T/logs/uv.log)"; rc=1; fi
fi

step "5. python3 calls"
if [ -s "$T/logs/python3-calls.log" ]; then bad "python3 was called:"; sed 's/^/      /' "$T/logs/python3-calls.log"; rc=1
else ok "python3 never called"; fi

echo
[ "$KEEP" = 1 ] && echo "temp folder kept: $T"
if [ "$rc" = 0 ]; then ok "bare-Mac check passed"; else bad "bare-Mac check failed (logs: $T/logs)"; fi
exit "$rc"
