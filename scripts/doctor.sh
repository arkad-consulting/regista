#!/bin/bash
# Re-checks a Regista installation and prints the fix for every problem, in the macOS language (Italian, English, French or
# Portuguese; REGISTA_LANG forces one). Read-only: installs nothing, changes nothing. Exit 0 = all good, 1 = something to fix.
#   scripts/doctor.sh [--quick]     --quick skips hashing the large models
set -uo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
QUICK=0; [ "${1:-}" = "--quick" ] && QUICK=1

PROBLEMS=0
# problem "<what>" "<fix>"
problem() { PROBLEMS=$((PROBLEMS + 1)); bad "$1"; printf '      %s: %s\n' "$(t fix)" "$2"; }
REINSTALL="$(t fix_reinstall)"
# The helper scripts of an engine in the engines folder against the repository's (#61; lib.sh scripts_state).
check_scripts() {
  local st; st="$(scripts_state "$1")"
  case "$st" in
    current) ok "$2 helper scripts match the repo" ;;
    differ*) problem "$2 helper scripts differ from the repo:${st#differ}" "$(t fix_scripts "$1")" ;;
  esac
}
run_fix() { t fix_run "$1"; }

# The installed app, and whether it ships its engines (#107): then neither the Command Line Tools nor Homebrew is needed
# for the Base tier, and its own ffmpeg / ffprobe / whisper-cli / deep-filter are the ones checked.
APP=""
for d in "$APP_DIR" "$HOME/Applications" /Applications; do [ -d "$d/Regista.app" ] && { APP="$d/Regista.app"; break; }; done
HELPERS=""; [ -n "$APP" ] && [ -x "$APP/Contents/Helpers/ffmpeg" ] && HELPERS="$APP/Contents/Helpers"

step "System"
macos="$(sw_vers -productVersion)"
if [ "${macos%%.*}" -ge 15 ] && [ "$(uname -m)" = arm64 ]; then ok "macOS $macos, Apple Silicon"
else problem "macOS $macos on $(uname -m): Regista needs macOS 15+ on Apple Silicon" "$(t fix_update_macos)"; fi
if xcode-select -p >/dev/null 2>&1; then ok "Command Line Tools"
elif [ -n "$HELPERS" ]; then ok "Command Line Tools: not needed (the app ships its engines)"
else problem "Command Line Tools missing" "$(run_fix 'xcode-select --install')"; fi
BREW="$(command -v brew || { [ -x /opt/homebrew/bin/brew ] && echo /opt/homebrew/bin/brew; } || true)"
if [ -n "$BREW" ]; then BREW_BIN="$("$BREW" --prefix)/bin"; ok "Homebrew"
elif [ -n "$HELPERS" ]; then BREW_BIN=/opt/homebrew/bin; ok "Homebrew: not needed for the Base tier (the app ships its engines)"
else BREW_BIN=/opt/homebrew/bin; problem "Homebrew missing" "$(t fix_brew)"; fi
TIER="$(json_get "$CONFIG" tier)"; TIER="${TIER:-$(detect_tier)}"
ok "RAM $(ram_gb) GB → tier $TIER$( [ -n "$(json_get "$CONFIG" tier)" ] && echo ' (set in engines.json)')"
medium_up() { [ "$(tier_rank "$TIER")" -ge 1 ]; }

step "engines.lock (supply-chain rule: released ≥ 14 days before pinned)"
epoch() { date -j -f %Y-%m-%d "$1" +%s 2>/dev/null; }
lock_bad=0
while IFS= read -r id; do
  rel="$(lock_get "$id" 3)"; pin="$(lock_get "$id" 4)"
  [ "$rel" = - ] || [ "$pin" = - ] && continue
  days=$(( ($(epoch "$pin") - $(epoch "$rel")) / 86400 ))
  if [ "$days" -lt 14 ]; then lock_bad=1; problem "$id: released $rel, pinned $pin (only $days days)" "$(t fix_pin)"; fi
  url="$(lock_get "$id" 7)"
  if [ "${url#repo:}" != "$url" ] && [ -f "${url#repo:}" ] && ! sha_ok "${url#repo:}" "$(lock_get "$id" 5)"; then lock_bad=1
    problem "${url#repo:} differs from its pin in engines.lock" "$(t fix_restore)"; fi
done < <(lock_ids)
[ "$lock_bad" = 0 ] && ok "$(lock_ids | wc -l | tr -d ' ') pinned artifacts, all ≥ 14 days old at their pin date"

step "Configuration"
if [ ! -f "$CONFIG" ]; then
  problem "no $CONFIG" "$REINSTALL"
elif ! json_ok "$CONFIG"; then
  problem "$CONFIG is not valid JSON" "$(t fix_json)"
else ok "$CONFIG"; fi
# cfg <key> <default> — the engines.json value, else Regista's built-in default (EngineConfig.swift)
cfg() { local v; v="$(json_get "$CONFIG" "$1")"; v="${v:-$2}"; echo "${v/#\~/$HOME}"; }

step "Engines"
# tool <name> <path> <min version> <version flag> <word>
tool() {
  local have
  if [ ! -x "$2" ]; then problem "$1 not found at $2" "$(run_fix "brew install $1"), $REINSTALL"; return; fi
  have="$("$2" "$4" 2>/dev/null | head -1 | awk -v w="$5" '{print $w}' | sed 's/^n//; s/-.*//')"
  if version_ge "$have" "$3"; then ok "$1 $have ($2)"
  else problem "$1 $have is older than $3" "$(run_fix "brew upgrade $1")"; fi
}
# shipped <name> <file>: a helper the app ships answers.
shipped() {
  if "$HELPERS/$2" "$3" >/dev/null 2>&1; then ok "$1 (shipped in the app: $HELPERS/$2)"
  else problem "$1 shipped in the app does not run ($HELPERS/$2)" "$REINSTALL"; fi
}
if [ -n "$HELPERS" ]; then
  shipped ffmpeg ffmpeg -version; shipped ffprobe ffprobe -version
else
  tool ffmpeg "$(cfg ffmpeg "$BREW_BIN/ffmpeg")" "$(lock_get ffmpeg 2)" -version 3
  tool ffprobe "$(cfg ffprobe "$BREW_BIN/ffprobe")" "$(lock_get ffmpeg 2)" -version 3
fi

w="$(cfg whisperCpp "$WHISPER_BIN")"
info="$(dirname "$(dirname "$w")")/BUILD-INFO.txt"
if [ -n "$HELPERS" ]; then shipped whisper.cpp whisper-cli --help
elif [ ! -x "$w" ]; then problem "whisper.cpp not built ($w)" "$(run_fix scripts/build-whisper.sh)"
elif ! grep -q "source sha256 $(lock_get whisper-src 5)" "$info" 2>/dev/null; then
  problem "whisper.cpp at $w was not built from the pinned source" "$(run_fix 'scripts/build-whisper.sh --force')"
else ok "whisper.cpp $WHISPER_VERSION ($w, source sha256 ok)"; fi

# checked <label> <path> <lock id> <slow: 1 = skipped with --quick>
checked() {
  if [ ! -f "$2" ]; then problem "$1 missing ($2)" "$REINSTALL"
  elif [ "$4" = 1 ] && [ "$QUICK" = 1 ]; then ok "$1 ($2, hash skipped)"
  elif sha_ok "$2" "$(lock_get "$3" 5)"; then ok "$1 ($2, sha256 ok)"
  else problem "$1 checksum mismatch ($2)" "$(t fix_delete_reinstall)"; fi
}
checked "ggml large-v3-turbo" "$(cfg whisperModel "$GGML_MODEL")" ggml-large-v3-turbo 1
df="$(cfg deepFilter "$DEEP_FILTER")"
if [ -n "$HELPERS" ]; then shipped DeepFilterNet deep-filter --version
else
  checked "DeepFilterNet" "$df" deep-filter 0
  [ ! -f "$df" ] || [ -x "$df" ] || problem "DeepFilterNet is not executable ($df)" "$(run_fix "chmod +x \"$df\"")"
fi

CHECKED="ffmpeg,ffprobe,whisper.cpp,whisper-model,deepfilternet,blender"
if medium_up; then
  CHECKED="$CHECKED,uv,whisperx,faster-whisper-model,punkt-tab,aligner-en,aligner-pt,aligner-it,aligner-fr,voxcpm,voxcpm-weights,node,hyperframes"
  wx="$(cfg whisperXProject "$WX_DIR")"
  if [ ! -f "$wx/pyproject.toml" ]; then problem "WhisperX not installed (tier $TIER)" "$REINSTALL"
  else
    if [ -x "$(cfg uv "$UV_BIN")" ] && [ -x "$wx/.venv/bin/python" ]; then ok "WhisperX env ($wx/.venv)"
    else problem "WhisperX env missing in $wx" "$REINSTALL"; fi
    if [ "$wx" = "$WX_DIR" ]; then
      if cmp -s engines/whisperx/uv.lock "$wx/uv.lock"; then ok "WhisperX env matches the repo"
      else problem "WhisperX env is older than the repo" "$REINSTALL"; fi
      check_scripts whisperx WhisperX
      if [ -f "$WX_CT2/model.bin" ]; then
        if [ "$QUICK" = 1 ] || sha_ok "$WX_CT2/model.bin" "$(lock_get ct2-whisper-large-v3-turbo 5)"; then ok "faster-whisper model ($WX_CT2)"
        else warn "faster-whisper model.bin hash differs from engines.lock (converted locally; works, but not the reference build)"; fi
      else problem "faster-whisper model missing ($WX_CT2)" "$REINSTALL"; fi
      [ -d "$WX_PUNKT" ] && ok "NLTK punkt_tab" || problem "NLTK punkt_tab missing" "$REINSTALL"
      # The pinned aligners (wx_align.py never downloads one): English and Portuguese with WhisperX, Italian and French on
      # request only (CC BY-NC 4.0, #20) — absent is fine, a wrong file is not.
      checked "$(manifest name aligner-en)" "$WX_ALIGNER_EN" wav2vec2-base-960h-en 0
      pt_bad=""
      for id in $(lock_ids | grep '^ptalign:'); do
        f="$WX_ALIGNER_PT/${id#ptalign:}"
        if [ ! -f "$f" ]; then pt_bad="missing ($f)"; break; fi
        [ "$QUICK" = 1 ] && [ "${id#ptalign:}" = pytorch_model.bin ] && continue
        sha_ok "$f" "$(lock_get "$id" 5)" || { pt_bad="checksum mismatch ($f)"; break; }
      done
      if [ -z "$pt_bad" ]; then ok "$(manifest name aligner-pt) ($WX_ALIGNER_PT, sha256 ok)"
      else problem "$(manifest name aligner-pt) $pt_bad" "$REINSTALL"; fi
      for a in "aligner-it|$WX_ALIGNER|wav2vec2-voxpopuli-it" "aligner-fr|$WX_ALIGNER_FR|wav2vec2-voxpopuli-fr"; do
        IFS='|' read -r id f art <<<"$a"
        if [ -f "$f" ]; then checked "$(manifest name "$id") ($(manifest field "$id" licence), non-commercial)" "$f" "$art" 0
        else ok "$(manifest name "$id"): not installed — $(t fix_optin "$id")"; fi
      done
    fi
  fi
  # VoxCPM2: its environment (the repo's uv.lock) and the pinned base weights.
  vox="$(cfg voxcpmProject "$VOX_DIR")"; voxm="$(cfg voxcpmModel "$VOX_MODEL")"
  if [ ! -x "$vox/.venv/bin/python" ] || [ ! -f "$(cfg voxcpmScript "$VOX_DIR/vox_say.py")" ]; then problem "VoxCPM2 not installed ($vox)" "$REINSTALL"
  else
    if [ "$vox" != "$VOX_DIR" ] || cmp -s engines/voxcpm/uv.lock "$vox/uv.lock"; then ok "VoxCPM2 env ($vox/.venv)"
    else problem "VoxCPM2 env is older than the repo" "$REINSTALL"; fi
    [ "$vox" != "$VOX_DIR" ] || check_scripts voxcpm VoxCPM2
    vox_bad=""
    for id in $(lock_ids | grep '^vox:'); do
      f="$voxm/${id#vox:}"
      if [ ! -f "$f" ]; then vox_bad="missing ($f)"; break; fi
      [ "$QUICK" = 1 ] && [ "${id#vox:}" = model.safetensors ] && continue
      sha_ok "$f" "$(lock_get "$id" 5)" || { vox_bad="checksum mismatch ($f)"; break; }
    done
    if [ -z "$vox_bad" ]; then ok "VoxCPM2 weights ($voxm, revision $(lock_get vox:model.safetensors 2 | cut -c4-11)$([ "$QUICK" = 1 ] && echo ', large file hash skipped' || echo ', sha256 ok'))"
    else problem "VoxCPM2 weights $vox_bad" "$REINSTALL"; fi
  fi
  # Node.js and HyperFrames: the pinned build in the engines folder and the CLI from engines/hyperframes/package-lock.json.
  # (node_state / hyperframes_state in lib.sh: the rule the app's Motori screen shares, #11)
  node="$(node_path)"; ns="$(node_state)"
  case "$ns" in
    missing) problem "Node.js not installed ($node): HTML graphics (HyperFrames) cannot render" "$(run_fix 'scripts/install.sh --only node')" ;;
    installed*) ok "Node.js ${ns#installed } ($node)" ;;
    *) problem "Node.js ${ns#other } at $node is not the pinned $NODE_VERSION" "$(run_fix 'scripts/install.sh --only node')" ;;
  esac
  hf="$(hyperframes_path)"
  case "$(hyperframes_state)" in
    missing) problem "HyperFrames CLI not installed ($hf)" "$(run_fix 'scripts/install.sh --only hyperframes')" ;;
    other) problem "HyperFrames in $HF_DIR is not the version of engines/hyperframes/package-lock.json" "$(run_fix 'scripts/install.sh --only hyperframes')" ;;
    *) ok "HyperFrames $(lock_get hyperframes-env 2) ($hf)" ;;
  esac
fi
b="$(cfg blender "$HOME/Applications/Blender.app/Contents/MacOS/Blender")"
if [ -x "$b" ]; then ok "Blender ($b)"; elif medium_up; then warn "Blender not installed (optional, 3D titles): scripts/install.sh --with blender"; fi

step "App and MCP server"
COPIES=(); for d in /Applications "$HOME/Applications"; do [ -d "$d/Regista.app" ] && COPIES+=("$d/Regista.app"); done
if [ "${#COPIES[@]}" -gt 1 ]; then
  warn "${#COPIES[@]} copies of Regista.app (${COPIES[*]}): the Dock or Spotlight may open an old one. scripts/build-app.sh --install keeps one and moves the other to the Trash"
fi
MCP=""
if [ -z "$APP" ]; then problem "Regista.app not installed" "$REINSTALL"
else
  build="$(defaults read "$APP/Contents/Info" RegistaBuildID 2>/dev/null || echo "from before build ids")"
  # How it is signed (#45): the designated requirement's leaf certificate against the dedicated identity. Reads
  # certificates only: nothing is unlocked and the login keychain is not looked at.
  leaf="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/.*certificate leaf = H"\([0-9a-fA-F]*\)".*/\1/p' | tr 'A-F' 'a-f')"
  mine="$(sign_hash 2>/dev/null | tr 'A-F' 'a-f' || true)"
  if [ -n "$leaf" ] && [ "$leaf" = "$mine" ]; then signer="signed with the dedicated Regista identity (stable: permissions survive rebuilds)"
  elif [ -n "$leaf" ]; then signer="signed with another certificate ($leaf): the next scripts/build-app.sh --install uses the dedicated identity, permissions are asked once more"
  else signer="ad-hoc: privacy permissions are asked again after each build; the next scripts/build-app.sh --install signs with the dedicated identity"; fi
  if codesign -v "$APP" 2>/dev/null; then ok "Regista.app ($APP, build $build, signature ok, $signer)"
  else problem "Regista.app signature invalid" "$REINSTALL"; fi
  # A downloaded app carries the quarantine of its download: fine when Gatekeeper accepts it (a notarised release);
  # a problem only when it does not (a build signed on another Mac).
  if xattr -p com.apple.quarantine "$APP" >/dev/null 2>&1; then
    if spctl --assess --type execute "$APP" >/dev/null 2>&1; then ok "Regista.app was downloaded (quarantine) and Gatekeeper accepts it"
    else problem "Regista.app is quarantined and Gatekeeper does not accept it (not notarised: a build from another Mac?)" "$(run_fix "xattr -dr com.apple.quarantine \"$APP\"")"; fi
  fi
  # The app's own server (M3 #60): both Claude configs must run it, never a copy in a source folder.
  MCP="$(bundled_mcp "$APP")"
  if [ -x "$MCP" ]; then ok "regista-mcp inside the app ($MCP)"
  else problem "this Regista.app has no regista-mcp inside (built before M3)" "$REINSTALL"; MCP=""; fi
  # The installed app's helper reads Claude Desktop's config below (no python3, #106).
  [ -n "$HELPER" ] || [ ! -x "$APP/Contents/MacOS/regista-engine" ] || HELPER="$APP/Contents/MacOS/regista-engine"
  # An app built from an older commit than this folder: Claude would use old tools.
  # Only for an app built from a source folder: a release (RegistaRelease) is compared with nothing here.
  app_sha="$(defaults read "$APP/Contents/Info" RegistaBuildSHA 2>/dev/null || true)"
  [ "$(defaults read "$APP/Contents/Info" RegistaRelease 2>/dev/null || echo 0)" = 1 ] && app_sha=""
  head_sha="$(git -C "$REPO" rev-parse --short=7 HEAD 2>/dev/null || true)"
  if [ -n "$app_sha" ] && [ -n "$head_sha" ] && [ "${app_sha:0:7}" != "$head_sha" ]; then
    problem "Regista.app was built from commit ${app_sha:0:7}, this folder is at $head_sha (the app and Claude's tools are older)" "$REINSTALL"
  fi
  # The sound-effect bank ships inside the app (E3 #55): checked by its manifest entry, skipped when this version has none.
  if [ -n "$(manifest field sfx-bank name 2>/dev/null)" ]; then
    sfx="$APP/Contents/Resources/SFX"; n="$(find "$sfx" -name '*.m4a' 2>/dev/null | wc -l | tr -d ' ')"
    if sha_ok "$sfx/manifest.json" "$(lock_get sfx-bank 5)" && [ "$n" -gt 0 ]; then ok "$(manifest name sfx-bank) ($n sounds, $sfx)"
    else problem "$(manifest name sfx-bank) missing or not the pinned one in $sfx" "$REINSTALL"; fi
    CHECKED="$CHECKED,sfx-bank"
  else ok "sound-effect bank: not part of this version (skipped)"; fi
fi
if mine="$(sign_hash)"; then
  if sign_keychain_listed; then ok "Signing identity '$SIGN_CN' ($mine) in $SIGN_KEYCHAIN"
  else warn "Signing identity '$SIGN_CN' exists but its keychain is not in the keychain search list: the next scripts/build-app.sh adds it back"; fi
else warn "No dedicated signing identity yet: the next scripts/build-app.sh creates it ($SIGN_DIR)"; fi

# Claude Code and Claude Desktop: a path other than the app's own server is a problem (an old development build under
# .build/, a file that is gone); a client installed but not connected is a problem only when no client is connected.
CONNECTED=0; UNCONNECTED=()
if command -v claude >/dev/null 2>&1; then
  reg="$(cd "$HOME" && claude mcp get regista </dev/null 2>/dev/null | sed -n 's/^ *Command: //p' | head -1)"
  if [ -n "$MCP" ] && [ "$reg" = "$MCP" ]; then ok "Claude Code: regista → $MCP"; CONNECTED=1
  elif [ -n "$reg" ]; then problem "Claude Code's regista server points to $reg, not to the app's own (${MCP:-none in this app})" "$(t fix_repoint code)"
  else UNCONNECTED+=("Claude Code|claude mcp add --scope user regista -- ${MCP:-<Regista.app>/Contents/MacOS/regista-mcp}"); fi
else ok "Claude Code not installed (optional)"; fi
if desktop_installed; then
  MCP_ENV="$(mcp_env)"; rc=0; cur="$(desktop_config status "$DESKTOP_CONFIG" "${MCP:-/nonexistent}" ${MCP_ENV:+"$MCP_ENV"})" || rc=$?
  case $rc in
    0) ok "Claude Desktop: regista → $MCP"; CONNECTED=1 ;;
    2) problem "Claude Desktop's regista server points to $cur, not to the app's own (${MCP:-none in this app})" "$(t fix_repoint desktop)" ;;
    3) problem "$cur" "$(t fix_claude_edit)" ;;
    *) UNCONNECTED+=("Claude Desktop|scripts/install.sh --claude desktop") ;;
  esac
else ok "Claude Desktop not installed (optional)"; fi
for u in ${UNCONNECTED[@]+"${UNCONNECTED[@]}"}; do
  name="${u%%|*}"; fix="${u#*|}"
  if [ "$CONNECTED" = 1 ]; then warn "$name: regista not connected (fine if you use the other one; to connect it: $fix)"
  else problem "$name has no regista MCP server" "$REINSTALL · $fix"; fi
done
if ! command -v claude >/dev/null 2>&1 && ! desktop_installed; then
  problem "neither Claude Desktop nor Claude Code is installed" "$(t fix_install_claude)"
fi

"$PY" -I scripts/mcp_smoke.py socket "$SOCKET" >/dev/null 2>&1
case $? in
  0) ok "app running, live-attach socket answers ($SOCKET)" ;;
  2) ok "app not running (no socket): Claude works headless until you open Regista" ;;
  3) warn "stale socket $SOCKET (the app quit abruptly): reopening Regista replaces it" ;;
  *) problem "the socket $SOCKET does not answer correctly" "$(t fix_reopen)" ;;
esac
# The other engines of scripts/engines.manifest.json (engines.status in the app reports their state).
printf '  · not checked here: %s\n' "$(manifest others "$CHECKED")"

step "MCP smoke check"
if [ -n "$MCP" ]; then
  if out="$(REGISTA_ENGINES="$CONFIG" "$PY" -I scripts/mcp_smoke.py mcp "$MCP")"; then
    printf '%s\n' "$out" | sed 's/^/  /'
    printf '%s\n' "$out" | grep -q "CHECKSUM MISMATCH" && problem "engines.status reports a checksum mismatch" "$REINSTALL"
  else problem "regista-mcp does not answer: $out" "$REINSTALL"; fi
fi

echo
if [ "$PROBLEMS" = 0 ]; then
  printf '%s✓ %s%s\n' "$G" "$(t doctor_ok)" "$N"; exit 0
else
  printf '%s✗ %s%s\n' "$R" "$(t doctor_bad "$PROBLEMS")" "$N"; exit 1
fi
