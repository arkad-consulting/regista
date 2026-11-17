#!/bin/bash
# Regista installer for the team (issue #12). Run it from a clone of the repo; run it again to update
# (git pull + rebuild): anything already installed and verified is kept.
#
#   scripts/install.sh [--yes] [--tier base|medium|pro] [--with blender,shotcut,comfyui,aligner-it,aligner-fr] [--no-pull]
#                      [--claude desktop|code|both|none] [--app-bundle <Regista.app>]
#   scripts/install.sh --only <engine id> [--check]
#
#   --yes        no questions: the defaults (no optional apps unless --with names them; the Italian and French aligners,
#                non-commercial, never without --with)
#   --tier       force a tier instead of detecting it from the RAM; it is kept in engines.json for the app
#                and later runs (--tier auto goes back to detecting)
#   --with       optional apps and engines to install without asking (aligner-it / aligner-fr: you accept their CC BY-NC 4.0
#                licence, non-commercial use only)
#   --app-bundle install this already built Regista.app instead of building one (a prebuilt app, or the fresh-user test:
#                nothing is signed and no other copy is touched)
#   --no-pull    don't git pull first
#   --claude     where to connect Regista's MCP server: Claude Desktop, Claude Code, both, or none (prints
#                how instead). Default: whichever of the two is installed. --no-claude = --claude none
#   --only       install one engine of scripts/engines.manifest.json by id, with the same step the full install runs
#                for it (no git pull, no app build, no Claude setup; engines.json gets only that engine's keys). What the
#                Motori screen of the app runs. Refuses ids the installer cannot install (system, manual, first-use,
#                cloud, planned) and engines above this Mac's tier. --check prints what it would do and changes nothing
#
# Engine downloads are pinned in scripts/engines.lock and SHA256-checked; the Homebrew bootstrap is pinned below.
# Locations and the download cache
# can be moved with REGISTA_SUPPORT_DIR / REGISTA_CACHE_DIR / REGISTA_ENGINES / REGISTA_APP_DIR (scripts/lib.sh).
# Messages follow the macOS language (Italian, English, French, Portuguese; REGISTA_LANG=it|en|fr|pt forces one).
# Regista never runs sudo itself; the official Homebrew bootstrap may ask for an administrator password.
# Check an installation later with scripts/doctor.sh.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"

ARGS=("$@")
YES=0; TIER=""; WITH=","; PULL=1; CLAUDE_TARGET=auto; ONLY=""; CHECK=0; APP_BUNDLE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y) YES=1 ;;
    --tier) TIER="${2:-}"; shift ;;
    --tier=*) TIER="${1#--tier=}" ;;
    --with) WITH=",${2:-},"; shift ;;
    --with=*) WITH=",${1#--with=},";;
    --no-pull) PULL=0 ;;
    --claude) CLAUDE_TARGET="${2:-}"; shift ;;
    --claude=*) CLAUDE_TARGET="${1#--claude=}" ;;
    --no-claude) CLAUDE_TARGET=none ;;
    --only) ONLY="${2:-}"; [ -n "$ONLY" ] || die "--only needs an engine id"; shift ;;
    --only=*) ONLY="${1#--only=}" ;;
    --check) CHECK=1 ;;
    --app-bundle) APP_BUNDLE="${2:-}"; [ -d "$APP_BUNDLE/Contents/MacOS" ] || die "--app-bundle needs a Regista.app"; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
  shift
done
[ -z "$TIER" ] || [ "$TIER" = auto ] || [ "$(tier_rank "$TIER")" -ge 0 ] || die "--tier must be base, medium, pro or auto"
case "$CLAUDE_TARGET" in auto|desktop|code|both|none) ;; *) die "--claude must be desktop, code, both or none" ;; esac
[ "$CHECK" = 0 ] || [ -n "$ONLY" ] || die "--check goes with --only <id>"

# ask "<question>" <default y|n> — the default with --yes or without a terminal.
ask() {
  local a
  if [ "$YES" = 1 ] || [ ! -t 0 ]; then [ "$2" = y ]; return; fi
  if [ "$2" = y ]; then printf '  %s [Y/n] ' "$1"; else printf '  %s [y/N] ' "$1"; fi
  read -r a || a=""
  case "$a" in [yY]*) return 0 ;; [nN]*) return 1 ;; *) [ "$2" = y ] ;; esac
}
wants() { case "$WITH" in *",$1,"*) return 0 ;; esac; return 1; }

FOUND=""; MISSING=""; OPTIONAL=""
found()    { FOUND="$FOUND, $1"; ok "$1${2:+ — $2}"; }
missing()  { MISSING="$MISSING, $1"; warn "$1 — $2"; }
optional() { OPTIONAL="$OPTIONAL, $1"; ok "$1: not installed — $2"; }

# ---------------------------------------------------------------- update
if [ -z "$ONLY" ] && [ "$PULL" = 1 ] && [ -z "${REGISTA_INSTALL_PULLED:-}" ] && git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
  step "$(t step_update)"
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    warn "local changes in the repo: not pulling (commit or stash them to update)"
  else
    before="$(git rev-parse HEAD)"
    if ! GIT_TERMINAL_PROMPT=0 git pull --ff-only --quiet; then
      warn "$(t git_pull_failed)"
    elif [ "$(git rev-parse HEAD)" != "$before" ]; then
      ok "updated to $(git log -1 --format='%h %s')"
      REGISTA_INSTALL_PULLED=1 exec "$REPO/scripts/install.sh" ${ARGS[@]+"${ARGS[@]}"}   # the installer itself may have changed
    else
      ok "already up to date ($(git log -1 --format=%h))"
    fi
  fi
fi

# ---------------------------------------------------------------- preflight (functions: --only runs only what it needs)
preflight_platform() {
  [ "$(uname -s)" = Darwin ] || die "$(t need_macos)"
  if [ "$(uname -m)" != arm64 ] || [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    die "$(t need_arm)"
  fi
  macos="$(sw_vers -productVersion)"
  [ "${macos%%.*}" -ge 15 ] || die "$(t need_macos15 "$macos")"
  ok "macOS $macos, Apple Silicon"
}

preflight_clt() {
  if ! xcode-select -p >/dev/null 2>&1 || ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    xcode-select --install 2>/dev/null || true
    die "$(t clt_missing)"
  fi
  swiftv="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\..*/\1/p' | head -1)"
  [ "${swiftv:-0}" -ge 6 ] || die "$(t swift_old "${swiftv:-none}")"
  ok "Command Line Tools ($(xcode-select -p)), Swift $swiftv"
}

# Official Homebrew bootstrap (not an engine): commit dated 2026-10-01, pinned 2026-11-13 (#87).
# Keep its URL and SHA256 together; never execute a moving HEAD download.
BREW_INSTALL_URL=https://raw.githubusercontent.com/Homebrew/install/09c62fc577ec170172b0a184060f141a2c622dc1/install.sh
BREW_INSTALL_SHA=5f333bbe53bc490e51e7ccb1df8779b3dd6ee73a1a7379efda216edb08ccb148
find_brew() {
  BREW="$(command -v brew || true)"
  if [ -z "$BREW" ] && [ -x /opt/homebrew/bin/brew ]; then BREW=/opt/homebrew/bin/brew; fi
}
preflight_brew() {
  local bootstrap
  [ -z "${BREW_BIN:-}" ] || return 0
  find_brew
  if [ -z "$BREW" ]; then
    # --yes accepts the Regista question, but cannot supply Homebrew's password/confirmation.
    [ -t 0 ] || die "$(t brew_terminal)"
    warn "$(t brew_bootstrap)"
    ask "$(t ask_brew)" y || die "$(t brew_terminal)"
    bootstrap="$(mktemp -t regista-homebrew)" || die "$(t brew_failed)"
    if ! curl -fL --retry 3 -sS -o "$bootstrap" "$BREW_INSTALL_URL"; then
      rm -f "$bootstrap"; die "$(t brew_failed)"
    fi
    if ! sha_ok "$bootstrap" "$BREW_INSTALL_SHA"; then
      rm -f "$bootstrap"; die "Homebrew installer SHA256 mismatch: nothing executed"
    fi
    if ! /bin/bash "$bootstrap"; then
      rm -f "$bootstrap"; die "$(t brew_failed)"
    fi
    rm -f "$bootstrap"
    find_brew
    [ -n "$BREW" ] || die "$(t brew_failed)"
  fi
  BREW_BIN="$("$BREW" --prefix)/bin"
  export PATH="$BREW_BIN:$PATH"   # cmake for build-whisper.sh, even when brew's shellenv is not in the profile
  ok "Homebrew ($BREW)"
}

resolve_tier() {
  DETECTED="$(detect_tier)"
  [ -n "$TIER" ] || TIER="$(json_get "$CONFIG" tier)"   # an earlier --tier, kept in engines.json
  [ "$TIER" = auto ] && TIER=""
  TIER_FORCED="$TIER"; TIER="${TIER:-$DETECTED}"
  ok "RAM $(ram_gb) GB → tier ${B}$TIER${N}${TIER_FORCED:+ (forced; detected: $DETECTED)}"
}
medium_up() { [ "$(tier_rank "$TIER")" -ge 1 ]; }

LOGS="$SUPPORT/logs"
# Keys install steps add to engines.json (written at the end: the full install adds the tier, --only writes only these).
KV=()

# ---------------------------------------------------------------- Homebrew tools
# brew_tool <formula> <binary> <version flag> <word of the first output line that is the version>
brew_tool() {
  local f="$1" bin="$BREW_BIN/$2" min have
  min="$(lock_get "$f" 2)"
  if [ ! -x "$bin" ]; then
    printf '  … brew install %s\n' "$f"
    "$BREW" install "$f" >/dev/null || die "brew install $f failed"
  fi
  have="$("$bin" "$3" 2>/dev/null | head -1 | awk -v w="$4" '{print $w}' | sed 's/^n//; s/-.*//')"
  if version_ge "$have" "$min"; then ok "$f $have"
  else warn "$f $have is older than the tested minimum $min — run: brew upgrade $f"; fi
}
install_ffmpeg() {
  brew_tool ffmpeg ffmpeg -version 3
  [ -x "$BREW_BIN/ffprobe" ] || die "ffprobe missing next to ffmpeg — run: brew reinstall ffmpeg"
  KV+=(ffmpeg "$BREW_BIN/ffmpeg" ffprobe "$BREW_BIN/ffprobe")
}
install_cmake() { brew_tool cmake cmake --version 3; }
install_uv() { brew_tool uv uv --version 2; KV+=(uv "$BREW_BIN/uv"); }

# ---------------------------------------------------------------- engines, Base tier
install_whisper_cpp() {
  scripts/build-whisper.sh 2>"$LOGS/build-whisper.log" | sed 's/^/  /' \
    || { tail -30 "$LOGS/build-whisper.log"; die "whisper.cpp build failed (log: $LOGS/build-whisper.log)"; }
  found "whisper.cpp $WHISPER_VERSION" "$WHISPER_BIN"
  KV+=(whisperCpp "$WHISPER_BIN")
}

# Model: already installed, or an existing verified copy referenced in place (the one engines.json names), or the
# download cache (put a copy in $REGISTA_CACHE_DIR to skip the download), or a download.
install_model() {
  local c
  MODEL_SHA="$(lock_get ggml-large-v3-turbo 5)"
  MODEL="$GGML_MODEL"
  if ! sha_ok "$MODEL" "$MODEL_SHA"; then
    c="$(json_get "$CONFIG" whisperModel)"; c="${c/#\~/$HOME}"
    if [ -n "$c" ] && [ "$c" != "$MODEL" ] && sha_ok "$c" "$MODEL_SHA"; then MODEL="$c"; fi
  fi
  if sha_ok "$MODEL" "$MODEL_SHA"; then
    found "ggml large-v3-turbo" "$MODEL (sha256 ok)"
  elif [ ! -f "$CACHE/ggml-large-v3-turbo/ggml-large-v3-turbo.bin" ] && [ "$TIER" = base ] && [ "$FREE" -lt 10 ] \
       && ! ask "$(t ask_model "$(human "$(lock_get ggml-large-v3-turbo 6)")" "$FREE")" y; then
    missing "ggml large-v3-turbo" "$(t skipped_rerun)"
    MODEL=""
  else
    fetch ggml-large-v3-turbo "$MODEL"
    found "ggml large-v3-turbo" "$MODEL (sha256 ok)"
  fi
  KV+=(whisperModelSha256 "$MODEL_SHA")
  [ -z "$MODEL" ] || KV+=(whisperModel "$MODEL")
}

install_deepfilter() {
  local c
  DF_SHA="$(lock_get deep-filter 5)"
  DF="$DEEP_FILTER"
  if ! sha_ok "$DF" "$DF_SHA"; then
    c="$(json_get "$CONFIG" deepFilter)"; c="${c/#\~/$HOME}"
    if [ -n "$c" ] && sha_ok "$c" "$DF_SHA"; then DF="$c"; fi
    sha_ok "$DF" "$DF_SHA" || fetch deep-filter "$DF"
  fi
  chmod +x "$DF"
  found "DeepFilterNet $(lock_get deep-filter 2)" "$DF (sha256 ok)"
  KV+=(deepFilter "$DF" deepFilterSha256 "$DF_SHA")
}

# The sound-effect bank (E3 #55) ships in the repository and inside Regista.app (Resources/SFX, copied by the app build
# below): this step only checks it against its pin. The copy of this script inside the app (Contents/Resources/Installer,
# what Impostazioni › Motori runs) has no Resources/SFX of its own: it checks the app's bank, Contents/Resources/SFX (#12).
install_sfx_bank() {
  local dir="$REPO/Resources/SFX"
  if [ ! -d "$dir" ] && [ "$(basename "$REPO")" = Installer ] && [ -d "$REPO/../SFX" ]; then dir="$(cd "$REPO/../SFX" && pwd)"; fi
  sha_ok "$dir/manifest.json" "$(lock_get sfx-bank 5)" || die "$dir differs from its pin in engines.lock: restore it (git checkout in a clone, a new build of the app)"
  found "Sound-effect bank ($(lock_get sfx-bank 2))" "$(find "$dir" -name '*.m4a' | wc -l | tr -d ' ') sounds, installed with the app"
}

# ---------------------------------------------------------------- engines, Medium tier
install_whisperx() {
  local lock_sha zip c src
  lock_sha="$(lock_get whisperx-env 5)"
  sha_ok engines/whisperx/uv.lock "$lock_sha" || die "engines/whisperx/uv.lock does not match engines.lock (edited without re-pinning?)"
  mkdir -p "$WX_DIR"
  for f in pyproject.toml uv.lock wx_align.py textnorm.py; do cp "engines/whisperx/$f" "$WX_DIR/$f"; done
  printf '  … uv sync --frozen (first run installs %s of Python packages)\n' "$(human "$(manifest size whisperx)")"
  "$BREW_BIN/uv" sync --frozen --quiet --project "$WX_DIR" || die "uv sync failed in $WX_DIR"
  ok "uv environment $WX_DIR/.venv (engines/whisperx/uv.lock)"

  if [ ! -f "$WX_PUNKT/.sha256" ] || [ "$(cat "$WX_PUNKT/.sha256")" != "$(lock_get punkt_tab 5)" ]; then
    zip="$CACHE/punkt_tab/punkt_tab.zip"
    fetch punkt_tab "$zip"
    rm -rf "$WX_PUNKT"; mkdir -p "$(dirname "$WX_PUNKT")"
    unzip -q -o "$zip" -d "$(dirname "$WX_PUNKT")"
    lock_get punkt_tab 5 > "$WX_PUNKT/.sha256"
  fi
  ok "NLTK punkt_tab (pinned, no download at run time)"

  install_aligner_en
  install_aligner_pt

  CT2_SHA="$(lock_get ct2-whisper-large-v3-turbo 5)"
  if ! sha_ok "$WX_CT2/model.bin" "$CT2_SHA"; then
    # An already converted copy (download cache, or $REGISTA_CT2_MODEL), else convert from OpenAI's repo.
    for c in "$CACHE/ct2-whisper-large-v3-turbo" "${REGISTA_CT2_MODEL:-}"; do
      [ -n "$c" ] || continue
      if sha_ok "$c/model.bin" "$CT2_SHA"; then
        mkdir -p "$WX_CT2"; for f in "$c"/*; do clone "$f" "$WX_CT2/${f##*/}"; done; break
      fi
    done
  fi
  if ! sha_ok "$WX_CT2/model.bin" "$CT2_SHA"; then
    printf '  … converting openai/whisper-large-v3-turbo to CTranslate2 (downloads 1.6 GB once)\n'
    src="$CACHE/oai"
    for id in $(lock_ids | grep '^oai:'); do fetch "$id" "$src/${id#oai:}"; done
    rm -rf "$WX_CT2.tmp"
    "$BREW_BIN/uv" run --frozen --quiet --project "$WX_DIR" python -I -m ctranslate2.converters.transformers \
      --model "$src" --output_dir "$WX_CT2.tmp" --quantization float16 \
      --copy_files tokenizer.json preprocessor_config.json >"$LOGS/convert-ct2.log" 2>&1 \
      || { tail -20 "$LOGS/convert-ct2.log"; die "CTranslate2 conversion failed (log: $LOGS/convert-ct2.log)"; }
    rm -rf "$WX_CT2"; mv "$WX_CT2.tmp" "$WX_CT2"
    rm -f "$src/model.safetensors"   # 1.6 GB, only needed for the conversion
    sha_ok "$WX_CT2/model.bin" "$CT2_SHA" \
      || warn "converted model.bin differs from engines.lock ($(sha256 "$WX_CT2/model.bin")): source files verified, converter output changed"
  fi
  ok "faster-whisper large-v3-turbo $WX_CT2"
  WX_OK=1
  found "WhisperX $(lock_get whisperx-env 2)" "$WX_DIR"
  KV+=(whisperXProject "$WX_DIR" whisperXScript "$WX_DIR/wx_align.py")
}

# The pinned aligners WhisperX uses (wx_align.py never downloads one). English and Portuguese come with WhisperX; Italian
# and French are CC BY-NC 4.0 (issue #20): installed only when asked for, after the licence is shown.
install_aligner_en() { fetch wav2vec2-base-960h-en "$WX_ALIGNER_EN"; ok "$(manifest name aligner-en) (sha256 ok)"; }
install_aligner_pt() {
  local id; for id in $(lock_ids | grep '^ptalign:'); do fetch "$id" "$WX_ALIGNER_PT/${id#ptalign:}"; done
  ok "$(manifest name aligner-pt) (revision $(lock_get ptalign:pytorch_model.bin 2 | cut -c4-11), sha256 ok)"
}
# licence_ok <id> — shows the licence of a non-commercial entry; true when it may be installed: named in --with, or the
# person says yes at the terminal, or --only <id> without a terminal (the app's Motori screen asked first).
licence_ok() {
  local id="$1" lic url
  lic="$(manifest field "$id" licence)"; url="$(manifest field "$id" licenceUrl)"
  warn "$(t licence_notice "$(manifest name "$id")" "$lic" "$url")"
  wants "$id" && return 0
  if [ -n "$ONLY" ] && [ ! -t 0 ]; then return 0; fi
  [ "$YES" = 1 ] && return 1
  ask "$(t ask_licence)" n
}
# install_aligner_optin <id> <lock id> <file> [ask] — kept when already installed and verified; else, with "ask" (the full
# install), only after licence_ok.
install_aligner_optin() {
  local id="$1" art="$2" file="$3"
  if sha_ok "$file" "$(lock_get "$art" 5)"; then found "$(manifest name "$id")" "$file (sha256 ok, $(manifest field "$id" licence))"; return 0; fi
  if [ "${4:-}" = ask ] && ! licence_ok "$id"; then optional "$(manifest name "$id")" "$(t optin_skipped "$id")"; return 0; fi
  fetch "$art" "$file"; found "$(manifest name "$id")" "$file (sha256 ok, $(manifest field "$id" licence))"
}

# ---------------------------------------------------------------- engines, Medium tier: Node.js + HyperFrames
# The official Node.js build (sha256-checked) extracted into the engines folder, then the HyperFrames CLI from
# engines/hyperframes/package-lock.json with npm ci --ignore-scripts: exact versions, integrity-checked, no install
# scripts, nothing global (no Homebrew, no npm -g, no PATH change; npm's cache in Regista's download cache).
install_node() {
  local tgz part
  if [ ! -x "$NODE_HOME/bin/node" ] || [ "$("$NODE_HOME/bin/node" --version 2>/dev/null)" != "v$NODE_VERSION" ]; then
    tgz="$CACHE/node/$(lock_get node 7 | sed 's#.*/##')"
    fetch node "$tgz"
    part="$ENGINES_DIR/node/.part"; rm -rf "$part"; mkdir -p "$part"
    tar -xzf "$tgz" -C "$part" || { rm -rf "$part"; die "cannot extract $tgz"; }
    rm -rf "$NODE_HOME"; mv "$part/${NODE_HOME##*/}" "$NODE_HOME"; rm -rf "$part"
  fi
  found "Node.js $NODE_VERSION" "$NODE_HOME (sha256 ok)"
  sha_ok engines/hyperframes/package-lock.json "$(lock_get hyperframes-env 5)" \
    || die "engines/hyperframes/package-lock.json does not match engines.lock (edited without re-pinning?)"
  mkdir -p "$HF_DIR" "$LOGS"
  if ! cmp -s engines/hyperframes/package-lock.json "$HF_DIR/package-lock.json" || [ ! -f "$HF_CLI" ]; then
    for f in package.json package-lock.json .npmrc; do cp "engines/hyperframes/$f" "$HF_DIR/$f"; done
    printf '  … npm ci --ignore-scripts (hyperframes %s)\n' "$(lock_get hyperframes-env 2)"
    (cd "$HF_DIR" && PATH="$NODE_HOME/bin:/usr/bin:/bin" npm_config_cache="$CACHE/npm" npm_config_ignore_scripts=true \
       npm_config_update_notifier=false "$NODE_HOME/bin/npm" ci --ignore-scripts --no-audit --no-fund >"$LOGS/hyperframes-npm.log" 2>&1) \
      || { tail -20 "$LOGS/hyperframes-npm.log"; die "npm ci failed in $HF_DIR (log: $LOGS/hyperframes-npm.log)"; }
  fi
  [ -f "$HF_CLI" ] || die "the HyperFrames CLI is missing after npm ci ($HF_CLI)"
  found "HyperFrames $(lock_get hyperframes-env 2)" "$HF_DIR (package-lock.json, scripts off)"
  KV+=(node "$NODE_HOME/bin/node" hyperframes "$HF_CLI")
}

# ---------------------------------------------------------------- engines, Medium tier: VoxCPM2
# Voice-over in the user's OWN cloned voice (issues #38/#41). Only the engine and the base model are installed: no
# voice ships with Regista — each person creates their profile and records their own voice (Settings → Profile and voice).
# vox_weights_ok <dir> — every pinned VoxCPM2 file is there with its sha256
vox_weights_ok() { local id; for id in $(lock_ids | grep '^vox:'); do sha_ok "$1/${id#vox:}" "$(lock_get "$id" 5)" || return 1; done; }
install_voxcpm() {
  local c
  VOX_MODEL_DIR="$VOX_MODEL"
  sha_ok engines/voxcpm/uv.lock "$(lock_get voxcpm-env 5)" || die "engines/voxcpm/uv.lock does not match engines.lock (edited without re-pinning?)"
  mkdir -p "$VOX_DIR/scripts"
  for f in pyproject.toml uv.lock vox_say.py train_voxcpm_finetune.py; do cp "engines/voxcpm/$f" "$VOX_DIR/$f"; done
  cp engines/voxcpm/scripts/*.md "$VOX_DIR/scripts/"
  printf '  … uv sync --frozen (first run installs %s of Python packages: PyTorch)\n' "$(human "$(manifest size voxcpm)")"
  "$BREW_BIN/uv" sync --frozen --quiet --project "$VOX_DIR" >"$LOGS/voxcpm-sync.log" 2>&1 \
    || { tail -20 "$LOGS/voxcpm-sync.log"; die "uv sync failed in $VOX_DIR (log: $LOGS/voxcpm-sync.log)"; }
  ok "uv environment $VOX_DIR/.venv (engines/voxcpm/uv.lock)"
  # Weights: installed and verified, or an existing verified copy referenced in place, or a download.
  if ! vox_weights_ok "$VOX_MODEL"; then
    c="$(json_get "$CONFIG" voxcpmModel)"; c="${c/#\~/$HOME}"
    if [ -n "$c" ] && [ "$c" != "$VOX_MODEL" ] && vox_weights_ok "$c"; then
      VOX_MODEL_DIR="$c"
    elif [ "$FREE" -lt 12 ] && ! ask "$(t ask_vox "$(human "$(manifest size voxcpm-weights)")" "$FREE")" y; then
      VOX_MODEL_DIR=""
    else
      for id in $(lock_ids | grep '^vox:'); do fetch "$id" "$VOX_MODEL/${id#vox:}"; done
    fi
  fi
  if [ -n "$VOX_MODEL_DIR" ]; then
    VOX_OK=1
    found "VoxCPM2 (voice model, revision $(lock_get vox:model.safetensors 2 | cut -c4-11))" "$VOX_MODEL_DIR (sha256 ok)"
    KV+=(voxcpmProject "$VOX_DIR" voxcpmScript "$VOX_DIR/vox_say.py" voxcpmModel "$VOX_MODEL_DIR")
  else
    missing "VoxCPM2" "$(t skipped_rerun)"
  fi
}

# ---------------------------------------------------------------- optional apps
# app_version <.app> — CFBundleShortVersionString, empty if missing
app_version() { [ -d "$1" ] && /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true; }
# find_app <Name.app> <version> — an installed copy with that exact version
find_app() {
  local d
  for d in "$APP_DIR" "$HOME/Applications" /Applications; do
    [ "$(app_version "$d/$1")" = "$2" ] && { echo "$d/$1"; return 0; }
  done
  return 1
}
# install_dmg <lock id> <Name.app> — copied next to the old copy first, then swapped: a failure keeps the old one.
install_dmg() {
  local dmg mnt
  dmg="$CACHE/$1/$(lock_get "$1" 7 | sed 's#.*/##')"
  fetch "$1" "$dmg"
  mnt="$(mktemp -d)"
  echo Y | hdiutil attach -nobrowse -readonly -noautoopen -quiet -mountpoint "$mnt" "$dmg" >/dev/null || die "cannot open $dmg"
  mkdir -p "$APP_DIR"; rm -rf "${APP_DIR:?}/.$2.part"
  cp -R "$mnt/$2" "$APP_DIR/.$2.part" || { rm -rf "${APP_DIR:?}/.$2.part"; hdiutil detach -quiet "$mnt"; die "copy of $2 failed"; }
  hdiutil detach -quiet "$mnt"; rmdir "$mnt" 2>/dev/null || true
  rm -rf "${APP_DIR:?}/$2"; mv "$APP_DIR/.$2.part" "$APP_DIR/$2"
}
# install_blender [ask] — found, or installed; with "ask" (the full install) it asks first or says how to add it
install_blender() {
  local BV; BV="$(lock_get blender 2)"
  BLENDER=""
  if BLENDER_APP="$(find_app Blender.app "$BV")"; then
    BLENDER="$BLENDER_APP/Contents/MacOS/Blender"; found "Blender $BV" "$BLENDER_APP"
  elif [ "${1:-}" != ask ] || wants blender || { medium_up && ask "$(t ask_blender "$BV" "$(human "$(lock_get blender 6)")")" n; }; then
    install_dmg blender Blender.app
    BLENDER="$APP_DIR/Blender.app/Contents/MacOS/Blender"; found "Blender $BV" "$APP_DIR/Blender.app (sha256 ok)"
  elif medium_up; then
    optional "Blender $BV" "3D titles; add it with scripts/install.sh --with blender"
  else
    ok "Blender: not used on the base tier"
  fi
  [ -z "$BLENDER" ] || KV+=(blender "$BLENDER")
}
install_shotcut() {
  local SV; SV="$(lock_get shotcut 2)"
  if SHOTCUT_APP="$(find_app Shotcut.app "$SV")"; then
    found "Shotcut $SV" "$SHOTCUT_APP"
  elif [ "${1:-}" != ask ] || wants shotcut || ask "$(t ask_shotcut "$SV" "$(human "$(lock_get shotcut 6)")")" n; then
    install_dmg shotcut Shotcut.app; found "Shotcut $SV" "$APP_DIR/Shotcut.app (sha256 ok)"
  else
    optional "Shotcut $SV" "opens the export.mlt projects; add it with scripts/install.sh --with shotcut"
  fi
}

# ---------------------------------------------------------------- engines.json
# write_config <key> <value> … — managed keys only; an empty value removes the key; anything else the user set is kept.
write_config() {
  mkdir -p "$(dirname "$CONFIG")"
  "$PY" -I - "$CONFIG" "$@" <<'EOF'
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
EOF
  ok "$CONFIG"
}

# ---------------------------------------------------------------- one engine (--only <id>, the app's Motori screen)
if [ -n "$ONLY" ]; then
  info="$(manifest install-info "$ONLY" 2>/dev/null)" || die "unknown engine id '$ONLY' (scripts/engines.py ids lists them)"
  IFS='|' read -r method istep formula arts files etier estatus <<EOF
$info
EOF
  [ "$estatus" = available ] || die "$ONLY is planned, not built yet: nothing to install"
  # What runs: the step the full install runs for this engine (a whole step is idempotent: what is there is kept).
  plan=""; needs=""
  case "$method" in
    homebrew) plan="brew install $formula (Homebrew)"; needs="brew"
              case "$formula" in ffmpeg) run=install_ffmpeg ;; cmake) run=install_cmake ;; uv) run=install_uv ;;
                *) die "$ONLY: no Homebrew step for formula $formula" ;; esac ;;
    installer)
      case "$ONLY" in
        whisper.cpp) plan="build whisper.cpp $WHISPER_VERSION from its pinned source"; needs="clt brew cmake"; run=install_whisper_cpp ;;
        whisper-model) plan="download the transcription model (sha256-checked)"; run=install_model ;;
        deepfilternet) plan="download DeepFilterNet (sha256-checked)"; run=install_deepfilter ;;
        sfx-bank) plan="the sound-effect bank in Resources/SFX (sha256-checked), copied into Regista.app by the app build"; run=install_sfx_bank ;;
        whisperx|faster-whisper-model|punkt-tab) plan="the WhisperX step: Python environment, sentence splitter, aligners, speech model"
                                                 needs="brew uv"; run=install_whisperx ;;
        voxcpm|voxcpm-weights|voice-training) plan="the VoxCPM2 step: Python environment and voice model"; needs="brew uv"; run=install_voxcpm ;;
        node|hyperframes) plan="Node.js $NODE_VERSION (sha256-checked) and HyperFrames $(lock_get hyperframes-env 2) from its lockfile (npm ci --ignore-scripts)"; run=install_node ;;
        aligner-pt) plan="download the Portuguese aligner (pinned revision, sha256-checked)"; run=install_aligner_pt ;;
        aligner-it|aligner-fr)
          plan="download the $(manifest name "$ONLY") ($(manifest field "$ONLY" licence), non-commercial: licence shown first, sha256-checked)"
          run=install_optin_only ;;
        blender) plan="Blender $(lock_get blender 2) into $APP_DIR (sha256-checked dmg)"; run=install_blender ;;
        shotcut) plan="Shotcut $(lock_get shotcut 2) into $APP_DIR (sha256-checked dmg)"; run=install_shotcut ;;
        *)
          # A single pinned download to its one file in the engines folder (the aligners, …).
          case "$arts$files" in *,*|'') die "$ONLY: the installer has no step for it" ;; esac
          [ -n "$arts" ] && [ -n "$files" ] || die "$ONLY: the installer has no step for it"
          plan="download $arts to engines/$files (sha256-checked)"; run=install_one_file ;;
      esac ;;
    *) die "$ONLY is not installed by the installer (install method: $method): see its steps in Settings › Motori" ;;
  esac
  [ -n "$TIER" ] || TIER="$(json_get "$CONFIG" tier)"   # --tier, else the tier kept in engines.json, else the RAM
  [ -n "$TIER" ] && [ "$TIER" != auto ] || TIER="$(detect_tier)"
  if [ -n "$etier" ] && [ "$(tier_rank "$etier")" -gt "$(tier_rank "$TIER")" ]; then
    die "$ONLY needs the $etier tier; this Mac runs the $TIER tier (force a higher tier in Settings › Motori, at your own risk)"
  fi
  if [ "$CHECK" = 1 ]; then echo "$ONLY: $plan"; exit 0; fi

  step "Install $ONLY: $plan"
  preflight_platform
  case " $needs " in *" clt "*) preflight_clt ;; esac
  case " $needs " in *" brew "*) preflight_brew ;; esac
  case " $needs " in *" cmake "*) install_cmake ;; esac
  case " $needs " in *" uv "*) install_uv ;; esac
  FREE="$(free_gb "$SUPPORT")"
  NEED="$(manifest need-gb "$ONLY")"
  [ "$FREE" -ge "$NEED" ] || die "$(t disk_short_one "$FREE" "$ONLY" "$NEED")"
  mkdir -p "$ENGINES_DIR" "$CACHE" "$LOGS"
  install_one_file() { fetch "$arts" "$ENGINES_DIR/$files"; found "$ONLY" "$ENGINES_DIR/$files (sha256 ok)"; }
  install_optin_only() { licence_ok "$ONLY" || die "$(t optin_skipped "$ONLY")"; install_aligner_optin "$ONLY" "$arts" "$ENGINES_DIR/$files"; }
  "$run"
  [ ${#KV[@]} -eq 0 ] || write_config "${KV[@]}"
  ok "$ONLY installed"
  exit 0
fi

# ---------------------------------------------------------------- the full install
step "$(t step_preflight)"
preflight_platform
preflight_clt
preflight_brew
resolve_tier

FREE="$(free_gb "$SUPPORT")"
# What this tier installs + a margin, from scripts/engines.manifest.json (scripts/engines.py disk <tier> itemises it).
# What this tier installs + a margin, from scripts/engines.manifest.json: "<need> <installs> <margin>" (whole GB, GB, GB).
DETAIL="$(manifest need-gb "$TIER" --detail)" || die "scripts/engines.manifest.json is unreadable (scripts/engines.py validate says why)"
read -r NEED INSTALLS MARGIN <<<"$DETAIL"
[ "$FREE" -ge "$NEED" ] || die "$(t disk_short "$TIER" "$FREE" "$NEED" "$INSTALLS" "$MARGIN")"
ok "$(t disk_ok "$FREE" "$TIER" "$NEED")"
[ "$TIER" != pro ] || ok "$(t disk_comfy "$(human "$(manifest comfy-bytes)")")"
mkdir -p "$ENGINES_DIR" "$CACHE" "$LOGS" "$HOME/Movies/Regista"   # the folder Claude reads videos from

step "$(t step_brew)"
install_ffmpeg
install_cmake
if medium_up; then install_uv; fi

step "$(t step_base)"
install_whisper_cpp
install_model
install_deepfilter
install_sfx_bank

WX_OK=0
if medium_up; then
  step "$(t step_wx)"
  install_whisperx
  install_aligner_optin aligner-it wav2vec2-voxpopuli-it "$WX_ALIGNER" ask
  install_aligner_optin aligner-fr wav2vec2-voxpopuli-fr "$WX_ALIGNER_FR" ask
fi

VOX_OK=0
if medium_up; then
  step "$(t step_vox)"
  install_voxcpm
  step "$(t step_node)"
  install_node
fi

step "$(t step_optional)"
install_blender ask
install_shotcut ask

COMFY_GEN=""
if [ "$TIER" = pro ]; then
  comfy_bytes="$(manifest comfy-bytes)"
  if wants comfyui || ask "$(t ask_comfy "$(human "$comfy_bytes")")" n; then
    echo "  $(t comfy_steps "$(human "$comfy_bytes")")"
    manifest steps comfyui | awk '{ printf "    %d. %s\n", NR, $0 }'
  fi
  COMFY_GEN="$(json_get "$CONFIG" comfyGen)"; COMFY_GEN="${COMFY_GEN:-~/.local/bin/comfy-gen}"; COMFY_GEN="${COMFY_GEN/#\~/$HOME}"
  if [ -x "$COMFY_GEN" ]; then found "ComfyUI (comfy-gen)" "$COMFY_GEN"; else COMFY_GEN=""; optional "ComfyUI" "$(t comfy_missing)"; fi
fi

# ---------------------------------------------------------------- build the app and the MCP server
step "$(t step_app)"
if [ -n "$APP_BUNDLE" ]; then
  # A prebuilt app: copied as it is (its signature and its own regista-mcp included), nothing else touched.
  mkdir -p "$APP_DIR"; rm -rf "${APP_DIR:?}/.Regista.app.part"
  cp -R "$APP_BUNDLE" "$APP_DIR/.Regista.app.part" && rm -rf "${APP_DIR:?}/Regista.app" && mv "$APP_DIR/.Regista.app.part" "$APP_DIR/Regista.app" \
    || die "cannot copy $APP_BUNDLE to $APP_DIR"
  ok "Regista.app → $APP_DIR/Regista.app (from $APP_BUNDLE)"
  : >"$LOGS/build-app.log"
else
  REGISTA_APP_DIR="$APP_DIR" scripts/build-app.sh --install --no-open >"$LOGS/build-app.log" 2>&1 \
    || { tail -30 "$LOGS/build-app.log"; die "app build failed"; }
  ok "Regista.app → $APP_DIR/Regista.app (built here: Gatekeeper does not quarantine it)"
fi
# The MCP server Claude runs is the app's own (Contents/MacOS): it always matches the app, and no Claude config points
# into this folder (M3 #60).
MCP="$(bundled_mcp "$APP_DIR/Regista.app")"
[ -x "$MCP" ] || die "regista-mcp not found inside the app ($MCP)"
ok "regista-mcp $MCP"
# One installed copy (others moved to the Trash) and how it was signed (#45).
grep -E '^(Moved the other copy|Signed with)' "$LOGS/build-app.log" | while IFS= read -r l; do ok "$l"; done || true
# The first build creates the signing identity in its own keychain; the summary says so, or why it is ad-hoc.
grep -E '^ *✓ .*(Regista signing keychain|Regista Local Build)' "$LOGS/build-app.log" | sed 's/^ *✓ *//' | while IFS= read -r l; do ok "$l"; done || true
grep -E '^ *! .*(ad-hoc signature|signing keychain)' "$LOGS/build-app.log" | sed 's/^ *! *//' | while IFS= read -r l; do warn "$l"; done || true
if pgrep -x Regista >/dev/null 2>&1; then warn "$(t app_running)"; fi

# ---------------------------------------------------------------- engines.json
step "engines.json"
write_config ${KV[@]+"${KV[@]}"} tier "$TIER_FORCED"   # empty tier = detect from the RAM (key removed)

# ---------------------------------------------------------------- Claude (Code and Desktop)
HAS_CODE=0; command -v claude >/dev/null 2>&1 && HAS_CODE=1
HAS_DESKTOP=0; desktop_installed && HAS_DESKTOP=1
case "$CLAUDE_TARGET" in
  auto) DO_CODE=$HAS_CODE; DO_DESKTOP=$HAS_DESKTOP ;;
  both) DO_CODE=1; DO_DESKTOP=1 ;;
  code) DO_CODE=1; DO_DESKTOP=0 ;;
  desktop) DO_CODE=0; DO_DESKTOP=1 ;;
  none) DO_CODE=0; DO_DESKTOP=0 ;;
esac

step "Claude Code"
ADD=(claude mcp add --scope user regista)
MCP_ENV="$(mcp_env)"
[ -z "$MCP_ENV" ] || ADD+=(-e "$MCP_ENV")
ADD+=(-- "$MCP")
CODE_STATE="missing"
if [ "$DO_CODE" = 1 ] && [ "$HAS_CODE" = 1 ]; then
  echo "  Registering Regista's MCP server for every Claude Code session (user scope):"
  # From $HOME: inside the repo, `get` would also see the project-scope .mcp.json entry.
  if (cd "$HOME" && claude mcp get regista </dev/null 2>/dev/null | grep -q 'Scope: User'); then
    old="$(cd "$HOME" && claude mcp get regista </dev/null 2>/dev/null | sed -n 's/^ *Command: //p' | head -1)"
    [ -z "$old" ] || [ "$old" = "$MCP" ] || ok "$(t repoint "$old")"
    echo "    claude mcp remove regista --scope user   # replaces the previous entry"
    (cd "$HOME" && claude mcp remove regista --scope user </dev/null >/dev/null 2>&1) || true
  fi
  printf '    %s\n' "${ADD[*]}"
  (cd "$HOME" && "${ADD[@]}" </dev/null >/dev/null) || die "claude mcp add failed"
  ok "claude mcp: regista → $MCP"
  CODE_STATE="added"
  # The regista skill (handoff/skill/regista): when to reach for the tools and the rules that always hold.
  SKILL_SRC="$REPO/handoff/skill/regista/SKILL.md"; SKILL_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/regista"
  if [ -f "$SKILL_SRC" ]; then
    mkdir -p "$SKILL_DIR" && cp "$SKILL_SRC" "$SKILL_DIR/SKILL.md" && ok "Claude Code skill: $SKILL_DIR/SKILL.md"
  fi
elif [ "$HAS_CODE" = 1 ]; then
  ok "not connected (--claude $CLAUDE_TARGET). To do it: ${ADD[*]}"; CODE_STATE="skipped"
elif [ "$DO_CODE" = 1 ]; then
  missing "Claude Code" "install it from https://claude.com/claude-code, log in, then run: ${ADD[*]}"
else
  ok "Claude Code not installed (optional: Claude Desktop is enough)"; CODE_STATE="none"
fi

step "Claude Desktop"
DESKTOP_STATE="none"
desktop_snippet() {
  printf '      add this server to "mcpServers" in %s:\n        "regista": {"command": "%s", "args": []}\n' "$DESKTOP_CONFIG" "$MCP"
}
if [ "$DO_DESKTOP" = 1 ]; then
  [ "$HAS_DESKTOP" = 1 ] || warn "Claude Desktop does not seem installed (https://claude.ai/download): connecting it anyway"
  rc=0; cur="$("$PY" -I scripts/claude_desktop.py status "$DESKTOP_CONFIG" "$MCP" ${MCP_ENV:+"$MCP_ENV"})" || rc=$?
  case $rc in
    0) ok "already connected: regista → $MCP ($DESKTOP_CONFIG)"; DESKTOP_STATE="ok" ;;
    3) missing "Claude Desktop" "$cur — not touched. Fix it in Claude → Settings → Developer → Edit Config, then re-run scripts/install.sh"
       desktop_snippet ;;
    *) [ $rc = 2 ] && echo "  The current regista entry runs: $cur"
       if ask "$(t ask_desktop) ($DESKTOP_CONFIG)" y; then
         out="$("$PY" -I scripts/claude_desktop.py set "$DESKTOP_CONFIG" "$MCP" ${MCP_ENV:+"$MCP_ENV"})" \
           || die "could not update $DESKTOP_CONFIG: $out"
         printf '%s\n' "$out" | sed -n 's/^backup /  backup: /p'
         ok "Claude Desktop: regista → $MCP"
         DESKTOP_STATE="added"
       else
         ok "not connected (you said no)"; desktop_snippet; DESKTOP_STATE="skipped"
       fi ;;
  esac
elif [ "$HAS_DESKTOP" = 1 ]; then
  ok "not connected (--claude $CLAUDE_TARGET). To do it: scripts/install.sh --claude desktop"; DESKTOP_STATE="skipped"
else
  ok "Claude Desktop not installed (optional)"
fi
[ "$CODE_STATE" = added ] || [ "$DESKTOP_STATE" = added ] || [ "$DESKTOP_STATE" = ok ] \
  || [ "$CLAUDE_TARGET" = none ] || missing "Claude" "$(t no_claude)"

step "$(t step_smoke)"
REGISTA_ENGINES="$CONFIG" "$PY" -I scripts/mcp_smoke.py mcp "$MCP" | sed 's/^/  /' \
  || die "the MCP smoke check failed — run scripts/doctor.sh"
if [ -n "$COMFY_GEN" ]; then
  # The Pro tier proof (#36): every ComfyUI model's node packs and model files (ComfyUI must be running to check them all).
  echo "  generate.check:"
  REGISTA_ENGINES="$CONFIG" REGISTA_ENGINE=local "$APP_DIR/Regista.app/Contents/MacOS/regista-engine" exec generate.check '{}' 2>&1 \
    | "$PY" -I -c 'import json,sys
try: print(json.load(sys.stdin)["summary"])
except Exception as e: print("generate.check did not answer (%s)" % e)' | sed 's/^/    /'
fi

# ---------------------------------------------------------------- summary
list() { if [ -n "$1" ]; then echo "${1#, }"; else echo "—"; fi; }
cat <<EOF

${B}━━ $(t done_title) ━━${N}
  $(t done_tier): $TIER$( [ -n "$TIER_FORCED" ] && echo " (--tier; RAM → $DETECTED)" )
  $(t done_found): $(list "$FOUND")
  $(t done_missing): $(list "$MISSING")
  $(t done_optional): $(list "$OPTIONAL")

  $(t done_next "$APP_DIR")
EOF
case "$CODE_STATE" in
  added) echo "  $(t done_code)";;
  missing) echo "  Claude Code: ${ADD[*]}";;
esac
case "$DESKTOP_STATE" in
  added|ok) echo "  ${B}$(t done_desktop)${N}";;
esac
