# Third-party software shipped inside Regista.app

A release build (`scripts/release.sh`, or `scripts/build-app.sh --bundle-engines`) puts these programs in
`Regista.app/Contents/Helpers/`, built or fetched by `scripts/build-engines.sh` from the versions pinned (with their
SHA-256) in `scripts/engines.lock`. Their licence texts are in `Regista.app/Contents/Resources/Licenses/<component>/`.
A developer build without `--bundle-engines` ships none of them: it uses the tools installed on that Mac.

| Program | Version | Licence | Source | How it is made |
|---|---|---|---|---|
| `ffmpeg`, `ffprobe` (FFmpeg) | 9.0.2 | LGPL-2.1-or-later | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz | Built from that source tarball, static, with only the components Regista uses enabled and no external library (no GPL or non-free component). The configure output that lists every enabled component ships next to the licence (`Licenses/ffmpeg/configure-output.txt`). |
| `whisper-cli` (whisper.cpp, with ggml) | 1.9.5 | MIT | https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz | Built from that source tarball, static, Metal shaders embedded, for any Apple Silicon Mac (no CPU-specific tuning). |
| `deep-filter` (DeepFilterNet) | 0.5.6 | MIT OR Apache-2.0 | https://github.com/Rikorose/DeepFilterNet/releases/tag/v0.5.6 | The project's own release binary for Apple Silicon (model embedded), unchanged apart from Regista's code signature. Licence texts: `Resources/Licenses/DeepFilterNet/` in this repository, from the v0.5.6 tag. |

FFmpeg is linked statically under the LGPL: the exact source is the tarball above (SHA-256 in `scripts/engines.lock`),
and `scripts/build-engines.sh` rebuilds the same binaries from it, so anyone can rebuild or replace them (the helpers
are separate programs in `Contents/Helpers/`, run as processes).

The sound-effect bank (`Resources/SFX`, MIT) and the fonts (`Resources/Fonts`, each with its licence) are listed with
their own files.
