# Shared helpers for install.sh, doctor.sh and build-whisper.sh (bash 3.2). Source it, don't run it.
#
# Locations (environment overrides, used by the fresh-user test and for unusual setups):
#   REGISTA_SUPPORT_DIR  engines, engines.json, socket      default ~/Library/Application Support/Regista
#   REGISTA_CACHE_DIR    verified downloads, reused by name   default ~/Library/Caches/Regista/downloads
#                        layout <cache>/<lock id before ":">/<last url component>, e.g.
#                        ggml-large-v3-turbo/ggml-large-v3-turbo.bin: put (or symlink) a file there to skip
#                        its download; it is SHA256-checked like a download
#   REGISTA_ENGINES      the engines.json the app and regista-mcp read   default $REGISTA_SUPPORT_DIR/engines.json
#   REGISTA_APP_DIR      where Regista.app (and Blender/Shotcut) go       default /Applications if writable, else ~/Applications

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="${REGISTA_LOCK:-$REPO/scripts/engines.lock}"   # download facts; everything else about an engine: scripts/engines.manifest.json
# (REGISTA_LOCK / REGISTA_MANIFEST point both scripts at other copies: the installer tests' fake engine)
SUPPORT="${REGISTA_SUPPORT_DIR:-$HOME/Library/Application Support/Regista}"
ENGINES_DIR="$SUPPORT/engines"
CACHE="${REGISTA_CACHE_DIR:-$HOME/Library/Caches/Regista/downloads}"
CONFIG="${REGISTA_ENGINES:-$SUPPORT/engines.json}"
if [ -n "${REGISTA_APP_DIR:-}" ]; then APP_DIR="$REGISTA_APP_DIR"
elif [ -w /Applications ]; then APP_DIR=/Applications
else APP_DIR="$HOME/Applications"; fi
SOCKET="${REGISTA_ENGINE_SOCKET:-$SUPPORT/engine.sock}"
# Claude Desktop's MCP config (install.sh adds a "regista" server there, doctor.sh checks it).
DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
# The env Regista's MCP server needs in a Claude config: REGISTA_ENGINES only when engines.json is not at its default place.
mcp_env() { [ "$CONFIG" = "$HOME/Library/Application Support/Regista/engines.json" ] || echo "REGISTA_ENGINES=$CONFIG"; }
desktop_installed() { [ -d /Applications/Claude.app ] || [ -d "$HOME/Applications/Claude.app" ] || [ -f "$DESKTOP_CONFIG" ]; }
PY=/usr/bin/python3   # ships with the Command Line Tools: only a developer's clone uses it (below), always with -I
# The app's own helper (#106): on a Mac without the Command Line Tools /usr/bin/python3 is a stub that only asks to install
# them, so the installer copy inside Regista.app (what Settings › Engines runs) asks regista-engine instead: the manifest
# queries, engines.json and Claude Desktop's config. $REGISTA_HELPER names it (the app passes its own); the copy in
# Contents/Resources/Installer finds Contents/MacOS/regista-engine by itself; install.sh --app-bundle uses that app's. A
# clone without a built app falls back to scripts/engines.py and Python (developer tools are there anyway).
if [ -n "${REGISTA_HELPER:-}" ]; then HELPER="$REGISTA_HELPER"
elif [ -x "$REPO/../../MacOS/regista-engine" ]; then HELPER="$(cd "$REPO/../../MacOS" && pwd)/regista-engine"
else HELPER=""; fi
. "$REPO/scripts/i18n.sh"   # t <key>: messages in it / en / fr / pt, from the macOS language

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=; G=; Y=; R=; N=; fi
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$N"; }
ok()   { printf '  %s✓%s %s\n' "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n' "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n' "$R" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$R" "$*" "$N" >&2; exit 1; }

# lock_get <id> <column>  — columns: 1 id, 2 version, 3 released, 4 pinned, 5 sha256, 6 size, 7 url
lock_get() {
  awk -F' [|] ' -v id="$1" -v col="$2" '$0 !~ /^#/ && $1 == id { print $col; found=1; exit } END { exit !found }' "$LOCK" \
    || die "engines.lock has no entry '$1'"
}
lock_ids() { awk -F' [|] ' '$0 !~ /^#/ && NF >= 7 { print $1 }' "$LOCK"; }

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
# sha_ok <file> <expected>
sha_ok() { [ -f "$1" ] && [ "$(sha256 "$1")" = "$2" ]; }

# with_timeout <seconds> <command…>: runs it, kills it after <seconds> (exit 124). For keychain and codesign calls
# that could wait forever on a dialog nobody answers.
with_timeout() {
  local secs="$1" pid i=0; shift
  "$@" & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $((secs * 10)) ]; then   # the children too (a shell function runs in a subshell)
      pkill -TERM -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124
    fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid"
}

# The local code-signing identity (#45): scripts/signing-identity.sh creates it in a keychain of its own, never in
# the login keychain; scripts/build-app.sh signs with it by certificate SHA-1 and `codesign --keychain`. Fixed under
# the real home (not REGISTA_SUPPORT_DIR): one identity per user, so the designated requirement never changes.
SIGN_DIR="$HOME/Library/Application Support/Regista/signing"
SIGN_KEYCHAIN="$SIGN_DIR/regista-signing.keychain-db"
SIGN_PASSFILE="$SIGN_DIR/keychain-password"
# Not "Regista Local Signing": an identity with that name exists in some login keychains (2026-11-12) and a codesign
# name lookup ignores --keychain and lands there. The identity is always selected by SHA-1 anyway.
SIGN_CN="Regista Local Build"
# SHA-1 of the certificate in the dedicated keychain (reads the certificate only, never the key; no unlock needed).
sign_hash() {
  [ -f "$SIGN_KEYCHAIN" ] || return 1
  with_timeout 15 security find-certificate -c "$SIGN_CN" -Z "$SIGN_KEYCHAIN" 2>/dev/null \
    | awk '/^SHA-1 hash:/ { print $3; f = 1; exit } END { exit !f }'
}
# The user keychain search list, one path per line (quotes and indentation removed). Read only.
user_keychains() { with_timeout 15 security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'; }
sign_keychain_listed() { user_keychains | grep -qxF "$SIGN_KEYCHAIN"; }

# Copy-on-write clone on APFS (instant, no extra space), plain copy elsewhere.
clone() { mkdir -p "$(dirname "$2")"; rm -rf "$2"; cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2"; }

# fetch <lock id> <destination>: the destination when it already verifies, else the cached copy, else a
# download into the cache; every path is SHA256-checked against engines.lock before it is used.
fetch() {
  local id="$1" dest="$2" sha url name cached size bar
  sha="$(lock_get "$id" 5)"; url="$(lock_get "$id" 7)"; name="${url##*/}"; cached="$CACHE/${id%%:*}/$name"
  if sha_ok "$dest" "$sha"; then return 0; fi
  if ! sha_ok "$cached" "$sha"; then
    mkdir -p "$(dirname "$cached")"
    size="$(lock_get "$id" 6)"
    printf '  ↓ %s (%s)\n' "$name" "$(human "$size")"
    bar=--progress-bar; case "$size" in -|'') ;; *) [ "$size" -ge 10000000 ] || bar=-sS ;; esac
    curl -fL --retry 3 "$bar" -o "$cached.part" "$url" || { rm -f "$cached.part"; die "download failed: $url"; }
    if ! sha_ok "$cached.part" "$sha"; then
      rm -f "$cached.part"; die "SHA256 mismatch for $url (expected $sha) — file deleted, nothing installed"
    fi
    mv "$cached.part" "$cached"
  fi
  [ "$cached" = "$dest" ] || clone "$cached" "$dest"
}

human() {
  case "$1" in ''|-) echo "?";; *) awk -v b="$1" 'BEGIN { if (b >= 1e9) printf "%.1f GB", b/1e9; else if (b >= 1e6) printf "%.0f MB", b/1e6; else printf "%.0f kB", b/1e3 }';; esac
}

# version_ge <have> <min>  (dotted numbers)
version_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$2" ]; }

# Free space in GB on the volume holding $1 (or its nearest existing parent).
free_gb() { local p="$1"; while [ ! -e "$p" ]; do p="$(dirname "$p")"; done; df -k "$p" | awk 'NR==2 { printf "%d", $4/1048576 }'; }

ram_gb() { echo $(( $(sysctl -n hw.memsize) / 1073741824 )); }
# What the installer found, is missing, or left out (the summary lists them); optional lines are translated (#124).
FOUND=""; MISSING=""; OPTIONAL=""
found()    { FOUND="$FOUND, $1"; ok "$1${2:+ — $2}"; }
missing()  { MISSING="$MISSING, $1"; warn "$1 — $2"; }
optional() { OPTIONAL="$OPTIONAL, $1"; ok "$(t not_installed "$1" "$2")"; }

# comfy_where — where Regista's ComfyUI is, as the app sees it (ComfyServer.locate, #6): "server <address>" when a server
# answers at comfyServer, "start <setting>" when engines.json sets comfyStart, "found <folder>" for the first usual place
# (the manifest's comfyPlaces, the list Regista reads: #124) that holds a ComfyUI folder with its own Python environment,
# else nothing.
comfy_where() {
  local server start p dir py
  server="$(json_get "$CONFIG" comfyServer)"; server="${server:-http://127.0.0.1:8188}"
  if curl -fsS -m 2 "${server%/}/system_stats" >/dev/null 2>&1; then echo "server $server"; return 0; fi
  start="$(json_get "$CONFIG" comfyStart)"
  if [ -n "$start" ]; then echo "start $start"; return 0; fi
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    case "$p" in "~/"*) dir="$HOME/${p#\~/}" ;; *) dir="$p" ;; esac
    [ -e "$dir/main.py" ] && [ -d "$dir/comfy" ] || continue
    for py in .venv/bin/python venv/bin/python .venv/bin/python3 venv/bin/python3; do
      if [ -x "$dir/$py" ] && [ ! -d "$dir/$py" ]; then echo "found $(cd "$dir" && pwd -P)"; return 0; fi
    done
  done < <(manifest comfy-places)
}

# comfy_line — the installer's ComfyUI line; sets COMFY (an address or a folder generate.check can reach, empty: none).
comfy_line() {
  local w; w="$(comfy_where)"
  case "$w" in
    "server "*|"start "*) COMFY="${w#* }"; found "ComfyUI" "$COMFY" ;;
    "found "*) COMFY="${w#found }"; found "ComfyUI" "$(t comfy_found "$COMFY")" ;;
    *) COMFY=""; optional "ComfyUI" "$(t comfy_missing)" ;;
  esac
}

# manifest <command> … — the queries of scripts/engines.py on scripts/engines.manifest.json: regista-engine when there is
# one ($HELPER), else engines.py itself (a clone: python3 of the Command Line Tools).
manifest() { if [ -n "$HELPER" ]; then "$HELPER" manifest "$@"; else "$PY" -I "$REPO/scripts/engines.py" "$@"; fi; }
# The manifest's tier thresholds, the same ones MachineTier.detect reads (RegistaCore EngineManifest).
detect_tier() { manifest tier-for-ram "$(ram_gb)"; }
tier_rank() { case "$1" in base) echo 0;; medium) echo 1;; pro) echo 2;; *) echo -1;; esac; }

# json_get <file> <key>   — prints the value (empty if missing)
json_get() {
  [ -f "$1" ] || return 0
  if [ -n "$HELPER" ]; then "$HELPER" config get "$1" "$2" 2>/dev/null || true; return 0; fi
  "$PY" -I -c 'import json,sys
d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print("" if v is None else v)' "$1" "$2" 2>/dev/null || true
}
# json_set <file> <key> <value> … — managed keys only; an empty value removes the key; anything else is kept.
json_set() {
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  if [ -n "$HELPER" ]; then "$HELPER" config set "$f" "$@"; return; fi
  "$PY" -I - "$f" "$@" <<'PYEOF'
import json, os, sys
path, kv = sys.argv[1], sys.argv[2:]
try:
    with open(path) as f: cfg = json.load(f)
except FileNotFoundError:
    cfg = {}
for k, v in zip(kv[::2], kv[1::2]):
    if v: cfg[k] = v
    else: cfg.pop(k, None)
tmp = path + ".tmp"
with open(tmp, "w") as f: json.dump(cfg, f, indent=2, sort_keys=True); f.write("\n")
os.replace(tmp, path)
PYEOF
}
# json_ok <file> — the file holds valid JSON.
json_ok() {
  if [ -n "$HELPER" ]; then "$HELPER" config check "$1" >/dev/null 2>&1; return; fi
  "$PY" -I -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
}
# desktop_config status|set <config> <regista-mcp> [KEY=VALUE …] — Claude Desktop's regista entry (regista-engine
# claude-desktop: exit 0 connected here, 1 absent, 2 something else, 3 not valid JSON, also printed when there is no
# helper yet). The installer and the doctor use the installed app's helper.
desktop_config() {
  [ -n "$HELPER" ] || { echo "no regista-engine to read Claude Desktop's config with (build or install the app first)"; return 3; }
  "$HELPER" claude-desktop "$@"
}

# Paths Regista expects for the managed engines.
WHISPER_VERSION="$(lock_get whisper-src 2)"
WHISPER_BIN="$ENGINES_DIR/whisper.cpp-$WHISPER_VERSION/bin/whisper-cli"
GGML_MODEL="$ENGINES_DIR/models/ggml-large-v3-turbo.bin"
DEEP_FILTER="$ENGINES_DIR/deepfilternet/deep-filter-$(lock_get deep-filter 2)-aarch64-apple-darwin"
WX_DIR="$ENGINES_DIR/whisperx"
WX_CT2="$WX_DIR/models/ct2-whisper-large-v3-turbo"
VOX_DIR="$ENGINES_DIR/voxcpm"
VOX_MODEL="$VOX_DIR/VoxCPM2"
WX_ALIGNER="$WX_DIR/models/torchaudio/wav2vec2_voxpopuli_base_10k_asr_it.pt"
WX_ALIGNER_FR="$WX_DIR/models/torchaudio/wav2vec2_voxpopuli_base_10k_asr_fr.pt"
WX_ALIGNER_EN="$WX_DIR/models/torchaudio/wav2vec2_fairseq_base_ls960_asr_ls960.pth"
WX_ALIGNER_PT="$WX_DIR/models/wav2vec2-large-xlsr-53-portuguese"   # a folder: the ptalign: rows of engines.lock
# uv and the Python of the Medium tier's environments (#109): the pinned builds, in the engines folder (no Homebrew).
UV_VERSION="$(lock_get uv-bin 2)"
UV_BIN="$ENGINES_DIR/uv/uv-$UV_VERSION/uv"
PY_BUILD="$(lock_get uv-python 2)"   # 3.12.16+20261026
PY_PIN="${PY_BUILD%%+*}"
UV_PY_DIR="$ENGINES_DIR/python"
# uv_env <command…>: uv with the pinned Python only, from the engines folder (never a download of another one).
uv_env() { UV_PYTHON_INSTALL_DIR="$UV_PY_DIR" UV_PYTHON_DOWNLOADS=never UV_PYTHON="$PY_PIN" "$@"; }
# Node.js (official build, extracted) and the HyperFrames CLI from engines/hyperframes/package-lock.json (Medium tier).
NODE_VERSION="$(lock_get node 2)"
NODE_HOME="$ENGINES_DIR/node/node-v$NODE_VERSION-darwin-arm64"
HF_DIR="$ENGINES_DIR/hyperframes"
HF_CLI="$HF_DIR/node_modules/hyperframes/bin/hyperframes.mjs"
# Installed (#11) = the pinned copy in the engines folder, or the path engines.json names: the rule the app's Motori screen
# applies too (GraphicsEngines.nodeInstalled / hyperframesInstalled; InstallTests runs both on the same fake folder). A node
# or npx found elsewhere on this Mac is not installed.
node_path() { local v; v="$(json_get "$CONFIG" node)"; v="${v:-$NODE_HOME/bin/node}"; echo "${v/#\~/$HOME}"; }
hyperframes_path() { local v; v="$(json_get "$CONFIG" hyperframes)"; v="${v:-$HF_CLI}"; echo "${v/#\~/$HOME}"; }
# node_state: "installed <version>", "missing", or "other <version>" (the pinned path holds another version)
node_state() {
  local n v; n="$(node_path)"
  [ -x "$n" ] || { echo missing; return; }
  v="$("$n" --version 2>/dev/null)"
  if [ "$n" != "$NODE_HOME/bin/node" ] || [ "$v" = "v$NODE_VERSION" ]; then echo "installed $v"; else echo "other $v"; fi
}
# hyperframes_state: "installed", "missing", or "other" (the engines folder's copy is not engines/hyperframes/package-lock.json)
hyperframes_state() {
  local h; h="$(hyperframes_path)"
  [ -f "$h" ] || { echo missing; return; }
  if [ "$h" = "$HF_CLI" ] && ! cmp -s "$REPO/engines/hyperframes/package-lock.json" "$HF_DIR/package-lock.json"; then echo other; else echo installed; fi
}
# scripts_state <id>: "current", "differ <script> …" (the engines folder's helper scripts are not the repository's), or
# "none" (no scripts, or the engine is not installed there): the rule of the app's EngineScripts and Motori (#61).
# Installed = every file of the entry that is not a script (nor a folder holding scripts) is in the engines folder.
scripts_state() {
  local scripts files f s rest=0 differ=""
  scripts="$(manifest scripts "$1")"; [ -n "$scripts" ] || { echo none; return; }
  files="$(manifest install-info "$1" | cut -d'|' -f5 | tr ',' '\n')"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$scripts" | grep -qxF -e "$f" && continue
    printf '%s\n' "$scripts" | grep -qF -e "$f/" && continue
    rest=1
    [ -e "$ENGINES_DIR/$f" ] || { echo none; return; }
  done <<<"$files"
  [ "$rest" = 1 ] || { echo none; return; }
  while IFS= read -r s; do cmp -s "$REPO/engines/$s" "$ENGINES_DIR/$s" || differ="$differ $s"; done <<<"$scripts"
  if [ -z "$differ" ]; then echo current; else echo "differ$differ"; fi
}
# The regista-mcp an installed app ships (scripts/build-app.sh): what both Claude configs run.
bundled_mcp() { echo "$1/Contents/MacOS/regista-mcp"; }
WX_PUNKT="$WX_DIR/.venv/nltk_data/tokenizers/punkt_tab"
