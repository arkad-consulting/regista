#!/bin/bash
# Generates the reference in docs/reference/ from the code (K1, #7), in English, never edited by hand:
#   commands.md   every command of the registry the MCP server describes its tools from (Tests/RegistaAppTests/ReferenceDocsTests.swift)
#   shortcuts.md  every keyboard shortcut of the catalog the menus and Settings › Shortcuts use (same test)
#   settings.md   every engines.json key and every REGISTA_* environment variable the code reads (same test)
#   engines.md    every engine of scripts/engines.manifest.json (scripts/engines.py docs)
# Usage: scripts/reference-docs.sh [--check]
#   without --check: regenerates docs/reference/;
#   --check: regenerates into a temporary folder and fails on any difference with docs/reference/, naming the commands,
#   shortcuts, keys and engines that are missing from the docs (the pre-commit hook runs it).
set -euo pipefail
cd "$(dirname "$0")/.."
CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1
DOCS=docs/reference
tmp="$(mktemp -d -t regista-reference)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/out"

python3 -I scripts/engines.py docs --out "$tmp/out/engines.md" >/dev/null
# The Swift part: the test writes its files into REGISTA_REFERENCE_OUT (same build flags as scripts/test.sh).
if ! REGISTA_REFERENCE_OUT="$tmp/out" scripts/test.sh --filter ReferenceDocsSuite >"$tmp/test.log" 2>&1; then
  tail -40 "$tmp/test.log" >&2
  echo "reference-docs: the generator failed (log above)" >&2
  exit 1
fi
for f in commands.md shortcuts.md settings.md engines.md; do
  [ -s "$tmp/out/$f" ] || { echo "reference-docs: $f was not generated" >&2; exit 1; }
done

if [ "$CHECK" = 0 ]; then
  mkdir -p "$DOCS"
  cp "$tmp/out/"*.md "$DOCS/"
  ls_out=("$DOCS"/*.md)
  printf '%s\n' "${ls_out[@]}"
  exit 0
fi

if diff -ru "$DOCS" "$tmp/out" >"$tmp/diff" 2>&1; then
  echo "reference-docs: docs/reference is current"
  exit 0
fi
# Name what changed: the backticked ids of headings and table rows, in the docs vs in the code.
python3 -I - "$DOCS" "$tmp/out" <<'PY' >&2
import os, re, sys
docs, gen = sys.argv[1], sys.argv[2]
item = re.compile(r'^(?:### `([^`]+)`|\| `([^`]+)` \||\|.*\| `([A-Za-z0-9_.:-]+)` \|$|- \*\*[^*]+\*\* \(`([^`]+)`\))', re.M)
def ids(path):
    try:
        text = open(path, encoding='utf-8').read()
    except FileNotFoundError:
        return set()
    return {g for m in item.finditer(text) for g in m.groups() if g}
for name in sorted(set(os.listdir(gen)) | set(os.listdir(docs) if os.path.isdir(docs) else [])):
    a, b = ids(os.path.join(docs, name)), ids(os.path.join(gen, name))
    missing, gone = sorted(b - a), sorted(a - b)
    if missing:
        print(f"reference-docs: missing from docs/reference/{name}: {', '.join(missing)}")
    if gone:
        print(f"reference-docs: in docs/reference/{name} but no longer in the code: {', '.join(gone)}")
PY
head -60 "$tmp/diff" >&2
echo "reference-docs: docs/reference is stale: run scripts/reference-docs.sh and commit the result" >&2
exit 1
