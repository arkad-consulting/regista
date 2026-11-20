#!/bin/bash
# Builds Regista with SwiftPM (no Xcode needed) and assembles build.noindex/Regista.app, plus the matching release
# regista-mcp / regista-engine (scripts/build-mcp.sh), all stamped with the same build id (scripts/build-stamp.sh).
# Both ship inside the app (Contents/MacOS, M3 #60): Claude Desktop and Claude Code run the app's own regista-mcp, so the
# server always matches the app and nothing points into a source folder.
# Usage: scripts/build-app.sh [--install] [--no-open] [--bundle-engines]
# REGISTA_RELEASE=1 (scripts/release.sh): the hardened runtime on the app and every helper, CFBundleVersion from
# REGISTA_BUNDLE_VERSION, RegistaRelease in Info.plist, and the source folder's path kept out of the binaries
# (-DREGISTA_RELEASE). REGISTA_SIGN_IDENTITY: sign with that identity (a Developer ID) and a secure timestamp instead of
# the local one; never ad hoc then.
# --bundle-engines ships ffmpeg, ffprobe, whisper-cli and deep-filter inside the app (Contents/Helpers, #107), from
# scripts/build-engines.sh (built once, then cached under ~/Library/Caches/Regista/engines-build), with their licence texts
# in Contents/Resources/Licenses; they are signed with the app. Without it (a developer's build) the app uses the tools
# installed on this Mac, as before.
# --install copies it to $REGISTA_APP_DIR (default /Applications; scripts/install.sh passes ~/Applications when
# /Applications is not writable) and, when that is /Applications or ~/Applications, moves any other Regista.app in those
# two folders to the Trash, so exactly one copy is left to launch. Any other destination (a test folder) touches nothing else.
# Signing (#45): every build signs with the local "Regista Local Build" identity, which scripts/signing-identity.sh
# creates (first build) or repairs in its own keychain under ~/Library/Application Support/Regista/signing/. The
# identity is selected by certificate SHA-1 with `codesign --keychain` on that file only. The designated requirement
# is the same on every build, so the camera / microphone / screen permissions survive a rebuild. Nothing asks
# anything and the login keychain is never touched. Ad-hoc only when the dedicated identity cannot be created or
# used, with one warning that says why (macOS then asks those permissions again after every build).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"
# The macOS SDK it can build SwiftUI with, without Xcode (#136); scripts/build-mcp.sh inherits it.
swift_sdk || die "$(t sdk_needs_xcode)"
[ -z "$SWIFT_SDK_NOTE" ] || echo "Building with the $SWIFT_SDK_NOTE (the newest SDK needs Xcode)"

INSTALL=0; OPEN=1; BUNDLE_ENGINES=0
for a in "$@"; do
  case "$a" in
    --install) INSTALL=1 ;;
    --no-open) OPEN=0 ;;
    --bundle-engines) BUNDLE_ENGINES=1 ;;
  esac
done
# The engines first (cached after the first build): a failure stops before anything is assembled.
if [ "$BUNDLE_ENGINES" = 1 ]; then ENGINES_OUT="$(scripts/build-engines.sh --quiet)" || die "scripts/build-engines.sh failed"; fi

read -r BUILD_ID BUILD_SHA BUILD_DIRTY _ < <(scripts/build-stamp.sh)
BUILD_DATE="$(date -u '+%Y-%m-%d %H:%M UTC')"
echo "Build $BUILD_ID ($BUILD_DATE)"
# A release keeps the source folder's path (the build Mac's user name) out of the binaries: REGISTA_RELEASE compiles out
# the #filePath fallbacks to the source folder, so only the bundle's own copies are used.
SWIFT_FLAGS=""
[ "${REGISTA_RELEASE:-}" = 1 ] && SWIFT_FLAGS="-Xswiftc -DREGISTA_RELEASE"
# REGISTA_BUILD_JOBS caps the compile jobs (as for scripts/build-engines.sh): a build on someone's work machine.
[ -z "${REGISTA_BUILD_JOBS:-}" ] || SWIFT_FLAGS="$SWIFT_FLAGS -j $REGISTA_BUILD_JOBS"
# shellcheck disable=SC2086
swift build -c release $SWIFT_FLAGS --product Regista
REGISTA_SWIFT_BUILD_FLAGS="$SWIFT_FLAGS" scripts/build-mcp.sh >/dev/null   # same stamp: the MCP server Claude launches matches this app
BIN="$(swift build -c release --show-bin-path)/Regista"

# build.noindex: Spotlight and Launchpad skip folders named *.noindex, so a build copy never shows up as a second
# Regista next to the installed one.
APP=build.noindex/Regista.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Regista"
# The MCP server Claude launches and the headless engine CLI, from the same build (scripts/build-mcp.sh above).
cp "$(dirname "$BIN")/regista-mcp" "$(dirname "$BIN")/regista-engine" "$APP/Contents/MacOS/"
cp Config/Info.plist "$APP/Contents/Info.plist"
# The build, shown in the About panel and readable with: defaults read <app>/Contents/Info RegistaBuildID
PB=/usr/libexec/PlistBuddy
"$PB" -c "Add :RegistaBuildID string $BUILD_ID" -c "Add :RegistaBuildSHA string $BUILD_SHA" \
      -c "Add :RegistaBuildDirty bool $([ "$BUILD_DIRTY" = 1 ] && echo true || echo false)" \
      -c "Add :RegistaBuildDate string $BUILD_DATE" "$APP/Contents/Info.plist"
[ -z "${REGISTA_BUNDLE_VERSION:-}" ] || "$PB" -c "Set :CFBundleVersion $REGISTA_BUNDLE_VERSION" "$APP/Contents/Info.plist"
[ "${REGISTA_RELEASE:-}" != 1 ] || "$PB" -c "Add :RegistaRelease bool true" "$APP/Contents/Info.plist"
cp -R Resources/Fonts Resources/Brand Resources/Blender Resources/SFX "$APP/Contents/Resources/"
# UI languages: English (also for every system language without its own) and Italian, the language of the source.
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"
# The guides for the Help menu (K1 #7), one folder per UI language: they open offline, in the app's language.
for lang in it en fr pt; do
  mkdir -p "$APP/Contents/Resources/Help/$lang"
  cp docs/$lang/*.md "$APP/Contents/Resources/Help/$lang/"
done
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
# The installer, for Impostazioni › Motori (scripts/install.sh --only <id>): the scripts it runs and the engine sources it
# copies (the files git tracks in engines/, never a .venv or a model). No Python helper: inside the app the installer asks
# Contents/MacOS/regista-engine (#106), so it runs on a Mac without the Command Line Tools.
INST="$APP/Contents/Resources/Installer"
mkdir -p "$INST/scripts"
cp scripts/install.sh scripts/lib.sh scripts/i18n.sh scripts/engines.lock scripts/engines.manifest.json \
   scripts/build-whisper.sh scripts/doctor.sh scripts/mcp_smoke.py "$INST/scripts/"
git ls-files engines | while IFS= read -r f; do mkdir -p "$INST/$(dirname "$f")"; cp "$f" "$INST/$f"; done
# The Claude Code skill (handoff/skill/regista): Settings › Claude and the installer install it from the app (#108).
mkdir -p "$APP/Contents/Resources/Skill/regista"; cp handoff/skill/regista/SKILL.md "$APP/Contents/Resources/Skill/regista/"
# The shipped engines (#107) and their licences.
if [ "$BUNDLE_ENGINES" = 1 ]; then
  mkdir -p "$APP/Contents/Helpers" "$APP/Contents/Resources/Licenses"
  cp "$ENGINES_OUT"/bin/* "$APP/Contents/Helpers/"
  cp -R "$ENGINES_OUT"/licenses/* "$APP/Contents/Resources/Licenses/"
  cp THIRD-PARTY-LICENSES.md "$ENGINES_OUT/BUILD-INFO.txt" "$APP/Contents/Resources/Licenses/"
  echo "Engines shipped in the app: $(cd "$APP/Contents/Helpers" && echo *) ($(du -sh "$APP/Contents/Helpers" | cut -f1), $ENGINES_OUT)"
fi

# Same entitlements and options as before (no hardened runtime); only the identity changes. The shipped engines in
# Contents/Helpers and the helpers in Contents/MacOS are signed first with the same identity (no entitlements: they need
# none), then the app.
sign() {
  local h
  for h in "$APP"/Contents/Helpers/* "$APP/Contents/MacOS/regista-mcp" "$APP/Contents/MacOS/regista-engine"; do
    [ -f "$h" ] || continue
    codesign --force "$@" "$h" || return 1
  done
  codesign --force "$@" --entitlements Config/Regista.entitlements "$APP"
}
RUNTIME=""; [ "${REGISTA_RELEASE:-}" = 1 ] && RUNTIME="--options runtime"
why=""
if [ -n "${REGISTA_SIGN_IDENTITY:-}" ]; then
  # A Developer ID from the keychain (scripts/release.sh): a failure stops the build, nothing is signed ad hoc.
  # shellcheck disable=SC2086
  with_timeout 120 sign $RUNTIME --timestamp --sign "$REGISTA_SIGN_IDENTITY" 2>build.noindex/codesign.log \
    || { cat build.noindex/codesign.log >&2; die "codesign with $REGISTA_SIGN_IDENTITY failed"; }
  echo "Signed with $REGISTA_SIGN_IDENTITY${RUNTIME:+ (hardened runtime)}"
elif ! scripts/signing-identity.sh --quiet 2>build.noindex/signing.log; then
  why="$(sed $'s/\033\\[[0-9;]*m//g' build.noindex/signing.log | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[^[:alnum:]]*//')"
elif ! HASH="$(sign_hash)"; then
  why="no certificate in $SIGN_KEYCHAIN"
else
  # shellcheck disable=SC2086
  rc=0; with_timeout 60 sign $RUNTIME --keychain "$SIGN_KEYCHAIN" --sign "$HASH" 2>build.noindex/codesign.log || rc=$?
  if [ "$rc" = 0 ]; then
    echo "Signed with the dedicated Regista identity $HASH (stable: privacy permissions survive rebuilds)${RUNTIME:+, hardened runtime}"
  elif [ "$rc" = 124 ]; then why="codesign did not finish in 60 s"
  else why="codesign: $(tail -1 build.noindex/codesign.log)"; fi
  find "$APP" -name '*.cstemp' -delete   # left behind by a codesign that was stopped
fi
if [ -n "$why" ]; then
  warn "ad-hoc signature, because the dedicated signing identity could not be used ($why): macOS will ask camera, microphone and screen permission again after this build"
  [ "${REGISTA_RELEASE:-}" != 1 ] || die "a release is never signed ad hoc ($why)"
  sign --sign -
fi

# Ask a running Regista (whichever copy) to quit, politely first; then stop it, as this script always did.
quit_running() {
  pgrep -x Regista >/dev/null || return 0
  with_timeout 10 osascript -e 'tell application id "com.arkad.regista" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x Regista >/dev/null || return 0; sleep 0.5; done
  warn "Regista did not quit: stopping it"
  pkill -x Regista 2>/dev/null || true
  sleep 0.5
}

if [ "$INSTALL" = 1 ]; then
  DEST="${REGISTA_APP_DIR:-/Applications}"
  mkdir -p "$DEST"
  if [ "$OPEN" = 1 ]; then quit_running; fi
  rm -rf "${DEST:?}/Regista.app"
  cp -R "$APP" "$DEST/"
  APP="$DEST/Regista.app"
  echo "Installed in $DEST"
  # Exactly one copy: any other Regista.app in the two Applications folders goes to the Trash (never deleted) — only when
  # this install went to one of them.
  standard=0
  for d in /Applications "$HOME/Applications"; do
    if [ -d "$d" ] && [ "$(cd "$d" && pwd -P)" = "$(cd "$DEST" && pwd -P)" ]; then standard=1; fi
  done
  [ "$standard" = 1 ] || echo "Installed outside the Applications folders: other copies left as they are"
  for d in /Applications "$HOME/Applications"; do
    [ "$standard" = 1 ] || break
    other="$d/Regista.app"
    [ -d "$other" ] && [ "$(cd "$d" && pwd -P)" != "$(cd "$DEST" && pwd -P)" ] || continue
    trash="$HOME/.Trash/Regista.app"; n=1
    while [ -e "$trash" ]; do trash="$HOME/.Trash/Regista $(date '+%Y-%m-%d %H.%M.%S') $n.app"; n=$((n + 1)); done
    if mv "$other" "$trash"; then echo "Moved the other copy $other to the Trash ($trash)"
    else warn "could not move $other to the Trash: remove it by hand, or the Dock may keep launching it"; fi
  done
fi

if [ "$OPEN" = 1 ]; then
  quit_running
  open "$APP"
fi
echo "Built $APP"
