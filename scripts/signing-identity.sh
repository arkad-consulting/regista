#!/bin/bash
# Creates, when missing, the self-signed code-signing identity Regista is signed with, in a keychain of its own
# (idempotent; scripts/build-app.sh runs it before every signature). Same certificate on every build, so the app's
# designated requirement (bundle id + this certificate) never changes and macOS keeps camera, microphone and screen
# permissions across rebuilds. Nobody approves anything: no dialog, no login password.
#   scripts/signing-identity.sh            create or repair, print the identity
#   scripts/signing-identity.sh --quiet    the same, printing only what it changed (build-app.sh)
#   scripts/signing-identity.sh --remove   undo: out of the search list, keychain and password file deleted
# What it touches, and nothing else:
#   ~/Library/Application Support/Regista/signing/ (0700): regista-signing.keychain-db, keychain-password (0600,
#   random, generated at creation). The keychain is unlocked here, never auto-locks, and lets /usr/bin/codesign use
#   the key (import -T, set-key-partition-list -k), so codesign never asks.
#   The user keychain search list: the dedicated keychain is appended at the end, every other entry kept in its
#   order (codesign finds an identity only in a listed keychain, even with --keychain; owner's decision, #45).
#   The login keychain and the default keychain are never read, written or changed.
# Security trade-off: the key is protected by a password stored on the same disk, so any process running as this
# user could sign a binary macOS treats as Regista, and it would inherit Regista's privacy permissions. Acceptable
# for a build made on the user's own Mac; a distributed build needs a Developer ID (#70). The password is passed on
# the command line of `security` for the instant of each call.
# After --remove (or deleting the directory) the next build creates a new certificate: macOS asks camera,
# microphone and screen permission once more.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

MODE=ensure
for a in "$@"; do
  case "$a" in
    --quiet) MODE=quiet ;;
    --remove) MODE=remove ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $a (see --help)" ;;
  esac
done
say() { [ "$MODE" = quiet ] || ok "$*"; }

# Only ever the dedicated file: refuse anything else (the login keychain above all).
KC="$SIGN_KEYCHAIN"
case "$KC" in
  "$HOME/Library/Application Support/Regista/signing/"*.keychain-db) ;;
  *) die "refusing to operate on $KC: only the dedicated Regista signing keychain is allowed" ;;
esac
case "$KC" in */login.keychain*|*/Library/Keychains/*) die "refusing to operate on $KC" ;; esac

# The search list as it is, rewritten with every entry kept in its order; only the dedicated keychain is added or
# removed. Never `default-keychain -s`.
read_list() { LIST=(); local k; while IFS= read -r k; do [ -n "$k" ] && LIST+=("$k"); done < <(user_keychains); }
write_list() {
  local rc=0; with_timeout 15 security list-keychains -d user -s "$@" || rc=$?
  [ "$rc" = 0 ] || die "could not update the keychain search list ($([ "$rc" = 124 ] && echo "no answer in 15 s" || echo "rc $rc"))"
}
list_add() {
  read_list
  [ "${#LIST[@]}" -gt 0 ] || die "the keychain search list is empty: not touching it"
  local k; for k in "${LIST[@]}"; do [ "$k" = "$KC" ] && return 0; done
  write_list "${LIST[@]}" "$KC"
  sign_keychain_listed || die "the signing keychain is still not in the search list after adding it"
  ok "Added the Regista signing keychain to the end of the keychain search list ($KC)"
}
list_remove() {
  read_list
  local keep=() k found=0
  for k in "${LIST[@]+"${LIST[@]}"}"; do if [ "$k" = "$KC" ]; then found=1; else keep+=("$k"); fi; done
  [ "$found" = 1 ] || return 0
  [ "${#keep[@]}" -gt 0 ] || die "the signing keychain is the only entry of the search list: not touching it"
  write_list "${keep[@]}"
  ok "Removed the Regista signing keychain from the keychain search list"
}

if [ "$MODE" = remove ]; then
  list_remove
  rm -f "$KC" "$SIGN_PASSFILE"
  rm -f "$SIGN_DIR"/.fl* 2>/dev/null || true   # lock files `security` leaves beside a keychain
  rmdir "$SIGN_DIR" 2>/dev/null || true
  ok "Regista signing identity removed. The next build creates a new one: macOS will ask camera, microphone and screen permission once more."
  exit 0
fi

sec() {   # sec <seconds> <what> <security args…>: a security call that can never wait forever
  local secs="$1" what="$2" rc=0; shift 2
  with_timeout "$secs" security "$@" || rc=$?
  case $rc in
    0) ;;
    124) die "$what: no answer from the keychain in $secs s" ;;
    *) die "$what failed (security rc $rc)" ;;
  esac
}
new_keychain() {
  (umask 077; /usr/bin/openssl rand -hex 32 > "$SIGN_PASSFILE") || die "could not write $SIGN_PASSFILE"
  chmod 600 "$SIGN_PASSFILE"
  sec 20 "creating the signing keychain" create-keychain -p "$(cat "$SIGN_PASSFILE")" "$KC"
  chmod 600 "$KC"
  ok "Created the Regista signing keychain ($KC)"
}

mkdir -p "$SIGN_DIR"; chmod 700 "$SIGN_DIR"
if [ -f "$KC" ] && [ ! -s "$SIGN_PASSFILE" ]; then
  warn "the signing keychain has no password file: creating a new one (permissions will be asked once more)"
  rm -f "$KC"
fi
[ -f "$KC" ] || new_keychain
rc=0; with_timeout 20 security unlock-keychain -p "$(cat "$SIGN_PASSFILE")" "$KC" || rc=$?
if [ "$rc" = 124 ]; then die "unlocking the signing keychain: no answer in 20 s"
elif [ "$rc" != 0 ]; then
  # Wrong password (the file was edited or replaced): the keychain is unusable, so start over.
  warn "the signing keychain does not open with its password file: creating a new one (permissions will be asked once more)"
  rm -f "$KC"; new_keychain
  sec 20 "unlocking the signing keychain" unlock-keychain -p "$(cat "$SIGN_PASSFILE")" "$KC"
fi
sec 20 "disabling the signing keychain's auto-lock" set-keychain-settings "$KC"   # no timeout, no lock on sleep

if ! sign_hash >/dev/null; then
  tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_CN
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  # LibreSSL (/usr/bin/openssl): its PKCS#12 defaults are what `security import` reads (OpenSSL 3 would need -legacy).
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null || die "could not create the certificate (openssl)"
  p12pass="$(/usr/bin/openssl rand -hex 16)"   # protects the temporary .p12 only
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$SIGN_CN" \
    -out "$tmp/id.p12" -passout "pass:$p12pass" || die "could not package the identity (openssl pkcs12)"
  sec 30 "importing the identity" import "$tmp/id.p12" -k "$KC" -f pkcs12 -P "$p12pass" -T /usr/bin/codesign >/dev/null
  sec 30 "giving codesign access to the key" \
    set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(cat "$SIGN_PASSFILE")" "$KC" >/dev/null
  sign_hash >/dev/null || die "the identity was imported but its certificate is not found in $KC"
  ok "Created the '$SIGN_CN' identity (self-signed, code signing, valid 10 years): macOS asks camera, microphone and screen permission once more after this build"
fi

list_add
say "Regista signing identity $(sign_hash) in $KC"
