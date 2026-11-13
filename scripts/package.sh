#!/bin/bash
# Builds the hand-off zip for a partner's Mac (issue #14): dist/regista-<date>-<shortsha>.zip with
#   regista-<date>-<shortsha>/
#     INSTALLA.command   double-click: copies regista/ to the install folder handoff/INSTALLA.command names, runs scripts/install.sh
#     LISEZMOI.md        guide in French      LEIAME.md  guide in Portuguese
#     START-PROMPT.md    instructions to paste into a Claude Desktop Project
#     regista/           source snapshot of HEAD (git archive: tracked files only, no .git, builds or footage)
#                        + SNAPSHOT (commit, date), which INSTALLA.command uses to recognise an older snapshot
# Only committed files are packaged: commit first. Prints the zip path.
#   scripts/package.sh [--out <dir>]     (default dist/)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=dist
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out needs a directory}"; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option $1 (see --help)" >&2; exit 1 ;;
  esac
  shift
done

SHA="$(git rev-parse --short HEAD)"
NAME="regista-$(date +%Y-%m-%d)-$SHA"
if [ -n "$(git status --porcelain --untracked-files=all)" ]; then
  echo "package refused: uncommitted or untracked files would be missing from the source snapshot. Commit the reviewed changes first, or package from a clean worktree." >&2
  exit 1
fi

scripts/check-voice-data.sh || { echo "package refused: voice data in the repository" >&2; exit 1; }
# The signing keychain lives outside the repository (~/Library/Application Support/Regista/signing, #45); refuse it
# anyway if a copy was ever committed: whoever has it can sign a binary macOS treats as this Mac's Regista.
if git ls-files | grep -Eiq '\.keychain(-db)?$|\.p12$|(^|/)keychain-password$|(^|/)signing/'; then
  echo "package refused: signing keychain or key material in the repository" >&2; exit 1
fi

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/$NAME/regista"
git archive --format=tar HEAD | tar -x -C "$STAGE/$NAME/regista"
printf '%s\ncommit %s · %s\n' "$NAME" "$(git rev-parse HEAD)" "$(git log -1 --format='%cI %s')" > "$STAGE/$NAME/regista/SNAPSHOT"
for f in INSTALLA.command LISEZMOI.md LEIAME.md START-PROMPT.md; do
  cp "$STAGE/$NAME/regista/handoff/$f" "$STAGE/$NAME/$f"   # from the snapshot, so the zip matches HEAD
done
chmod +x "$STAGE/$NAME/INSTALLA.command"

mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
rm -f "$OUT/$NAME.zip"
(cd "$STAGE" && zip -qr -X "$OUT/$NAME.zip" "$NAME")
echo "$OUT/$NAME.zip"
