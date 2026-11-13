#!/bin/bash
# Builds whisper.cpp (the Base transcription engine) from its tagged source, pinned by SHA256 in
# scripts/engines.lock (id whisper-src), into <support>/engines/whisper.cpp-<version>/bin/whisper-cli
# (<support> = ~/Library/Application Support/Regista or $REGISTA_SUPPORT_DIR; the tarball is fetched through
# $REGISTA_CACHE_DIR, see scripts/lib.sh).
# Static build with Metal (shader library embedded): one self-contained binary, no Homebrew deps.
# Usage: scripts/build-whisper.sh [--force]
set -euo pipefail
. "$(dirname "$0")/lib.sh"

VERSION="$WHISPER_VERSION"    # tag v1.9.5, released 2026-10-06 (≥ 2 weeks before adoption)
COMMIT=d2a764c648779feb36d44363f212a29b00aad1af   # annotated tag object of v1.9.5
SHA256="$(lock_get whisper-src 5)"
URL="$(lock_get whisper-src 7)"

PREFIX="$ENGINES_DIR/whisper.cpp-$VERSION"
BIN="$WHISPER_BIN"

if [ -x "$BIN" ] && [ "${1:-}" != "--force" ]; then
  echo "already built: $BIN"; exit 0
fi
command -v cmake >/dev/null || { echo "cmake is required (brew install cmake)" >&2; exit 1; }

TARBALL="$ENGINES_DIR/src/whisper.cpp-$VERSION.tar.gz"
fetch whisper-src "$TARBALL"   # SHA256-checked (lib.sh)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xzf "$TARBALL" -C "$WORK"
cd "$WORK/whisper.cpp-$VERSION"
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF >/dev/null
cmake --build build --config Release --target whisper-cli -j "$(sysctl -n hw.ncpu)" >/dev/null
mkdir -p "$PREFIX/bin"
cp build/bin/whisper-cli "$BIN"
cat > "$PREFIX/BUILD-INFO.txt" <<EOF
whisper.cpp v$VERSION (tag object $COMMIT)
source $URL
source sha256 $SHA256
binary sha256 $(shasum -a 256 "$BIN" | cut -d' ' -f1)
built $(date -u +%Y-%m-%dT%H:%M:%SZ) static, Metal embedded
EOF
cat "$PREFIX/BUILD-INFO.txt"
