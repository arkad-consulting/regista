#!/bin/bash
# A release build of Regista (#108): the app with its engines inside (scripts/build-app.sh --bundle-engines), the hardened
# runtime on the app and every helper, packed as dist/Regista-<version>.dmg with the Applications shortcut, and its
# sha256 in dist/Regista-<version>.dmg.sha256.
#
#   scripts/release.sh
#
# The version is CFBundleShortVersionString in Config/Info.plist (bump it in a commit); CFBundleVersion is set at build
# to the number of commits. A release is made from a commit: a tree with changes is refused.
#
# Signing and notarisation run when their settings are present (never written in the repository):
#   REGISTA_SIGN_IDENTITY   a "Developer ID Application: …" identity in the keychain (name or SHA-1): signs the helpers,
#                           the app and the image with it, with a secure timestamp
#   REGISTA_NOTARY_PROFILE  a `xcrun notarytool store-credentials` keychain profile: submits the app, then the image,
#                           waits for Apple's answer and staples both (needs REGISTA_SIGN_IDENTITY)
# Without them the image is signed with this Mac's local identity: good for this Mac only (Gatekeeper refuses it on
# another Mac). No tag, no GitHub release and no upload: publishing is the reviewer's step.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"

[ -z "$(git status --porcelain)" ] || die "the working tree has changes (git status): a release is made from a commit"
IDENTITY="${REGISTA_SIGN_IDENTITY:-}"; PROFILE="${REGISTA_NOTARY_PROFILE:-}"
[ -z "$PROFILE" ] || [ -n "$IDENTITY" ] || die "REGISTA_NOTARY_PROFILE needs REGISTA_SIGN_IDENTITY (Apple notarises Developer ID signatures only)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Config/Info.plist)"
NUMBER="$(git rev-list --count HEAD)"
echo "Regista $VERSION ($NUMBER), commit $(git rev-parse --short HEAD)"

start=$(date +%s)
REGISTA_RELEASE=1 REGISTA_BUNDLE_VERSION="$NUMBER" scripts/build-app.sh --no-open --bundle-engines
APP=build.noindex/Regista.app
built=$(date +%s)

step "Checks"
codesign --verify --strict --deep "$APP" || die "the app's signature does not verify"
for b in "$APP"/Contents/Helpers/* "$APP"/Contents/MacOS/*; do
  flags="$(codesign -dv "$b" 2>&1 | sed -n 's/.*flags=\(0x[0-9a-f]*\)(\([^)]*\)).*/\1 \2/p')"
  case "$flags" in *runtime*) ok "${b#"$APP"/Contents/}: $flags" ;; *) die "${b#"$APP"/Contents/} has no hardened runtime ($flags)" ;; esac
done
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" = "$NUMBER" ] || die "CFBundleVersion is not $NUMBER"

# notarise <file> — submit, wait, fail with Apple's log when it is not accepted.
notarise() {
  local out id
  out="$(xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1)" || true
  printf '%s\n' "$out" | sed 's/^/  /'
  printf '%s\n' "$out" | grep -q 'status: Accepted' && return 0
  id="$(printf '%s\n' "$out" | sed -n 's/^ *id: //p' | head -1)"
  [ -z "$id" ] || xcrun notarytool log "$id" --keychain-profile "$PROFILE" 2>&1 | sed 's/^/    /'
  die "notarisation of $(basename "$1") was not accepted"
}
if [ -n "$PROFILE" ]; then
  step "Notarisation of the app"
  mkdir -p build.noindex/notary; rm -f build.noindex/notary/Regista.zip
  ditto -c -k --keepParent "$APP" build.noindex/notary/Regista.zip
  notarise build.noindex/notary/Regista.zip
  xcrun stapler staple "$APP"
fi

step "Disk image"
mkdir -p dist
DMG="dist/Regista-$VERSION.dmg"
STAGE="build.noindex/dmg"; rm -rf "$STAGE" "$DMG"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Regista.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Regista $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$STAGE"
if [ -n "$IDENTITY" ]; then codesign --force --timestamp --sign "$IDENTITY" "$DMG"; fi
if [ -n "$PROFILE" ]; then
  step "Notarisation of the image"
  notarise "$DMG"
  xcrun stapler staple "$DMG"
fi
(cd dist && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
ok "$DMG ($(du -h "$DMG" | cut -f1), app $(du -sh "$APP" | cut -f1)), sha256 $(cut -d' ' -f1 "$DMG.sha256")"
ok "built in $((built - start)) s, packed in $(( $(date +%s) - built )) s"
if [ -z "$IDENTITY" ]; then
  warn "signed with this Mac's local identity: the image opens on this Mac only; on another Mac Gatekeeper refuses it (set REGISTA_SIGN_IDENTITY and REGISTA_NOTARY_PROFILE for a public release)"
elif [ -z "$PROFILE" ]; then
  warn "signed with $IDENTITY but not notarised: Gatekeeper refuses it on another Mac until it is (set REGISTA_NOTARY_PROFILE)"
else
  ok "signed with $IDENTITY, notarised and stapled: ready to publish (no tag, no release and no upload were made)"
fi
