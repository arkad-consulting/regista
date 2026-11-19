#!/bin/bash
# Builds the Base engines a downloaded Regista.app ships inside itself (#107): ffmpeg + ffprobe and whisper-cli from their
# pinned source tarballs (version and sha256 in scripts/engines.lock), and the pinned deep-filter release binary.
# Made for any Apple Silicon Mac on macOS 15 or later: nothing tuned to the CPU of the Mac that builds them (whisper.cpp
# without GGML_NATIVE, Apple clang's default arm64 target; Metal shaders embedded), static (no library outside macOS's
# own), and no Homebrew library is looked at (Homebrew's cmake is used as a build tool only).
#
# ffmpeg is configured with --disable-everything and then exactly what Regista asks of it (the inventory of every
# ffmpeg / ffprobe call in Sources/ and Tests/) plus the inputs a phone, a camera and a screen recording produce. No
# external library: the build is LGPL-2.1-or-later; H.264 is encoded with VideoToolbox, audio with ffmpeg's own AAC.
#
#   scripts/build-engines.sh [--force] [--quiet]
#
# Prints the folder that holds the result, keyed by the versions and the build flags:
#   ~/Library/Caches/Regista/engines-build/<key>/bin/{ffmpeg,ffprobe,whisper-cli,deep-filter}
#   …/licenses/<component>/…, BUILD-INFO.txt (versions, sha256 of each binary, build time), RECIPE.txt
# A second run with the same recipe builds nothing (--force rebuilds). REGISTA_ENGINES_BUILD moves the cache folder;
# REGISTA_BUILD_JOBS sets the compile jobs (default 4, always under `nice`: this may be someone's work machine).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
cd "$REPO"

FORCE=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --quiet) QUIET=1 ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option $a (see --help)" ;;
  esac
done
say() { [ "$QUIET" = 1 ] || printf '%s\n' "$*" >&2; }

JOBS="${REGISTA_BUILD_JOBS:-4}"
MIN_MACOS=15.0
FF_VERSION="$(lock_get ffmpeg-src 2)"; FF_SHA="$(lock_get ffmpeg-src 5)"
WH_SHA="$(lock_get whisper-src 5)"
DF_VERSION="$(lock_get deep-filter 2)"; DF_SHA="$(lock_get deep-filter 5)"

# What Regista uses (inventory 2026-11-19), and the common inputs from phones, cameras and screen recorders.
FF_FLAGS=(
  --cc=clang --arch=arm64 --target-os=darwin
  "--extra-cflags=-mmacosx-version-min=$MIN_MACOS" "--extra-ldflags=-mmacosx-version-min=$MIN_MACOS"
  --disable-autodetect --enable-videotoolbox --enable-audiotoolbox --enable-zlib
  --disable-everything --disable-doc --disable-debug --disable-network --disable-ffplay
  --enable-ffmpeg --enable-ffprobe --enable-static --disable-shared
  --enable-avdevice --enable-indev=lavfi --enable-swscale --enable-swresample
  --enable-protocol=file,pipe
  --enable-muxer=wav,null,rawvideo,pcm_f32le,pcm_s16le,image2,mp4,mov
  --enable-demuxer=mov,wav,image2,image_png_pipe,image_jpeg_pipe,image_webp_pipe,image_tiff_pipe,image_bmp_pipe,gif,mp3,flac,aac,aiff,caf,matroska,avi,mpegts,ogg,mpegps
  --enable-encoder=pcm_s16le,pcm_s24le,pcm_f32le,rawvideo,png,wrapped_avframe,aac,h264_videotoolbox
  --enable-decoder=wrapped_avframe,h264,hevc,prores,png,mjpeg,webp,tiff,bmp,gif,vp8,vp9,mpeg4,mpeg2video,mpeg1video,rawvideo,aac,aac_latm,alac,mp3float,mp3,flac,opus,vorbis,ac3,eac3,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f32be,pcm_u8,pcm_alaw,pcm_mulaw
  --enable-parser=h264,hevc,aac,aac_latm,mpegaudio,flac,png,mjpeg,webp,bmp,gif,vp8,vp9,opus,vorbis,ac3,mpeg4video,mpegvideo
  --enable-filter=buffer,buffersink,abuffer,abuffersink,null,anull,format,aformat,scale,aresample,trim,atrim,setpts,asetpts,transpose,hflip,vflip,rotate,crop,split,asplit,concat,pan,ebur128,afade,volume,adelay,apad,amultiply,amix,alimiter,anullsrc,highpass,equalizer,agate,acompressor,ssim,psnr,reverse,fps,lutyuv,color,testsrc2,sine,gradients
)
WH_FLAGS=(
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DCMAKE_OSX_ARCHITECTURES=arm64 "-DCMAKE_OSX_DEPLOYMENT_TARGET=$MIN_MACOS"
  -DGGML_NATIVE=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF -DGGML_CCACHE=OFF
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF
  "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
)
CC_VERSION="$(/usr/bin/clang --version | head -1)"
RECIPE="regista engines recipe 1
macOS >= $MIN_MACOS arm64, $CC_VERSION
ffmpeg $FF_VERSION $FF_SHA ${FF_FLAGS[*]}
whisper.cpp $WHISPER_VERSION $WH_SHA ${WH_FLAGS[*]}
deep-filter $DF_VERSION $DF_SHA"
KEY="$(printf '%s' "$RECIPE" | shasum -a 256 | cut -c1-16)"
ROOT="${REGISTA_ENGINES_BUILD:-$HOME/Library/Caches/Regista/engines-build}"
OUT="$ROOT/$KEY"
TOOLS="ffmpeg ffprobe whisper-cli deep-filter"

complete() { local t; [ -f "$1/RECIPE.txt" ] || return 1; for t in $TOOLS; do [ -x "$1/bin/$t" ] || return 1; done; }
if [ "$FORCE" = 0 ] && complete "$OUT"; then
  say "cached: nothing to build ($OUT)"
  echo "$OUT"; exit 0
fi

CMAKE="$(command -v cmake || true)"; [ -n "$CMAKE" ] || { [ -x /opt/homebrew/bin/cmake ] && CMAKE=/opt/homebrew/bin/cmake; } || true
[ -n "$CMAKE" ] || die "cmake is needed to build whisper.cpp on this Mac (brew install cmake): a build tool only, nothing of it ships"

WORK="$ROOT/work-$KEY"; PART="$OUT.part"
rm -rf "$WORK" "$PART"; mkdir -p "$WORK" "$PART/bin" "$PART/licenses"
trap 'rm -rf "$WORK"' EXIT
LOG="$WORK/logs"; mkdir -p "$LOG"
# A clean environment for the compilers: the system tools only, no Homebrew or pkg-config search path.
clean_env() { env -i HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" PATH=/usr/bin:/bin:/usr/sbin:/sbin LANG=C "$@"; }

say "==> sources (sha256-checked)"
FF_TAR="$CACHE/ffmpeg-src/ffmpeg-$FF_VERSION.tar.xz"; fetch ffmpeg-src "$FF_TAR"
WH_TAR="$CACHE/whisper-src/whisper.cpp-$WHISPER_VERSION.tar.gz"; fetch whisper-src "$WH_TAR"
DF_BIN="$CACHE/deep-filter/deep-filter-$DF_VERSION-aarch64-apple-darwin"; fetch deep-filter "$DF_BIN"

start=$(date +%s)
say "==> ffmpeg $FF_VERSION (nice, $JOBS jobs)"
tar -xJf "$FF_TAR" -C "$WORK"
FF_SRC="$WORK/ffmpeg-$FF_VERSION"
(cd "$FF_SRC" && clean_env nice -n 10 ./configure "${FF_FLAGS[@]}" >"$LOG/ffmpeg-configure.log" 2>&1) \
  || { tail -20 "$LOG/ffmpeg-configure.log" >&2; die "ffmpeg configure failed"; }
if grep -q "did not match anything" "$LOG/ffmpeg-configure.log"; then
  grep "did not match anything" "$LOG/ffmpeg-configure.log" >&2; die "ffmpeg configure: a component above does not exist in $FF_VERSION"
fi
grep -q '^License: LGPL version 2.1 or later' "$LOG/ffmpeg-configure.log" || die "ffmpeg configure: the build is not LGPL-2.1-or-later"
(cd "$FF_SRC" && clean_env nice -n 10 make -j "$JOBS" ffmpeg ffprobe >"$LOG/ffmpeg-make.log" 2>&1) \
  || { tail -30 "$LOG/ffmpeg-make.log" >&2; die "ffmpeg build failed"; }
cp "$FF_SRC/ffmpeg" "$FF_SRC/ffprobe" "$PART/bin/"
mkdir -p "$PART/licenses/ffmpeg"; cp "$FF_SRC/COPYING.LGPLv2.1" "$FF_SRC/LICENSE.md" "$PART/licenses/ffmpeg/"
cp "$LOG/ffmpeg-configure.log" "$PART/licenses/ffmpeg/configure-output.txt"   # what was enabled: the LGPL's "how it was built"
ff_end=$(date +%s)

say "==> whisper.cpp $WHISPER_VERSION (no GGML_NATIVE, Metal embedded; nice, $JOBS jobs)"
tar -xzf "$WH_TAR" -C "$WORK"
WH_SRC="$WORK/whisper.cpp-$WHISPER_VERSION"
(cd "$WH_SRC" && clean_env nice -n 10 "$CMAKE" -S . -B build "${WH_FLAGS[@]}" >"$LOG/whisper-cmake.log" 2>&1 \
   && clean_env nice -n 10 "$CMAKE" --build build --config Release --target whisper-cli -j "$JOBS" >"$LOG/whisper-build.log" 2>&1) \
  || { tail -30 "$LOG/whisper-build.log" "$LOG/whisper-cmake.log" >&2 2>/dev/null; die "whisper.cpp build failed"; }
cp "$WH_SRC/build/bin/whisper-cli" "$PART/bin/"
mkdir -p "$PART/licenses/whisper.cpp"; cp "$WH_SRC/LICENSE" "$PART/licenses/whisper.cpp/"
wh_end=$(date +%s)

say "==> deep-filter $DF_VERSION (pinned release binary)"
cp "$DF_BIN" "$PART/bin/deep-filter"; chmod 755 "$PART/bin/deep-filter"
mkdir -p "$PART/licenses/DeepFilterNet"; cp Resources/Licenses/DeepFilterNet/LICENSE-* "$PART/licenses/DeepFilterNet/"

say "==> checks"
for t in $TOOLS; do
  bad_libs="$(otool -L "$PART/bin/$t" | tail -n +2 | awk '{print $1}' | grep -vE '^(/usr/lib/|/System/Library/)' || true)"
  [ -z "$bad_libs" ] || die "$t links libraries outside macOS: $bad_libs"
  minos="$(otool -l "$PART/bin/$t" | awk '/LC_BUILD_VERSION/ {f=1} f && $1 == "minos" {print $2; exit}')"
  [ -z "$minos" ] || version_ge "$MIN_MACOS" "$minos" || die "$t needs macOS $minos (expected $MIN_MACOS or older)"
  [ "$(lipo -archs "$PART/bin/$t")" = arm64 ] || die "$t is not an arm64 binary"
done
"$PART/bin/ffmpeg" -hide_banner -version | head -1 >/dev/null
# Every component asked for is in the binary (configure drops a GPL-only one from an LGPL build without a word).
for kind in filter encoder decoder muxer demuxer; do
  case "$kind" in filter) list="filters"; col=2 ;; encoder) list="encoders"; col=2 ;; decoder) list="decoders"; col=2 ;;
    muxer) list="muxers"; col=2 ;; demuxer) list="demuxers"; col=2 ;; esac
  have="$("$PART/bin/ffmpeg" -hide_banner "-$list" 2>/dev/null | awk -v c="$col" '{print $c}' | tr ',' '\n' | sort -u)"
  for want in $(printf '%s\n' "${FF_FLAGS[@]}" | sed -n "s/^--enable-$kind=//p" | tr ',' ' '); do
    # The listing shows a format's own name: pcm_f32le is "f32le", image_png_pipe "png_pipe", mpegps "mpeg".
    shown="$want"; case "$kind" in muxer|demuxer) shown="${want#pcm_}"; shown="${shown#image_}"; [ "$want" = mpegps ] && shown=mpeg ;; esac
    printf '%s\n' "$have" | grep -qx "$shown" || die "ffmpeg: the $kind $want is not in the build (licence or name)"
  done
done
"$PART/bin/ffprobe" -hide_banner -version | head -1 >/dev/null
"$PART/bin/whisper-cli" --help >/dev/null 2>&1 || die "whisper-cli does not start"
"$PART/bin/deep-filter" --version >/dev/null 2>&1 || die "deep-filter does not start"
sha256 "$PART/bin/deep-filter" | grep -qx "$DF_SHA" || die "deep-filter differs from its pin"

printf '%s\n' "$RECIPE" >"$PART/RECIPE.txt"
{
  echo "Regista engines, built $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(sw_vers -productVersion), recipe $KEY"
  echo "ffmpeg $FF_VERSION (source sha256 $FF_SHA), LGPL-2.1-or-later, $((ff_end - start)) s"
  echo "whisper.cpp $WHISPER_VERSION (source sha256 $WH_SHA), MIT, $((wh_end - ff_end)) s"
  echo "deep-filter $DF_VERSION (release binary sha256 $DF_SHA), MIT OR Apache-2.0"
  for t in $TOOLS; do echo "  $t $(stat -f %z "$PART/bin/$t") bytes, sha256 $(sha256 "$PART/bin/$t")"; done
} >"$PART/BUILD-INFO.txt"
rm -rf "$OUT"; mv "$PART" "$OUT"
[ "$QUIET" = 1 ] || cat "$OUT/BUILD-INFO.txt" >&2
echo "$OUT"
