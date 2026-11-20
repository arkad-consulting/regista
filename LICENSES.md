# Licences — dependencies, engines, models and assets

Regista's own code is licensed under the **GNU General Public License v3.0 or later** (`GPL-3.0-or-later`, see
`LICENSE`), Copyright © 2026 Arkad Consulting. The name "Regista" and the Arkad name and logos are not covered by the
GPL: see `TRADEMARKS.md`. This file lists the third-party parts Regista ships or uses and their licences; all of
them are compatible with distributing Regista under the GPL (nothing GPL-incompatible is linked or bundled, and the
GPL engines run as separate programs).

**Rule of the project:** the repository ships source code, scripts, two OFL fonts, the app icon and a bank of sound
effects made in code (MIT, rendered from earshot). Every engine,
model and app is downloaded on the user's Mac by `scripts/install.sh` from its official source (pinned version +
SHA256 in `scripts/engines.lock`), or installed by the user (Homebrew), and runs as a separate process. Nothing
below is redistributed by Regista unless the "In the repo" column says so. Each engine's licence, and whether it is
non-commercial, is also recorded in `scripts/engines.manifest.json` (summary in `docs/engines.md`); the tests check
that every entry has one.

## In the repository

| Item | Licence | Redistributable | Notes |
|---|---|---|---|
| Regista source (Swift, scripts, `engines/whisperx/*.py`, `Resources/Blender/*.py`) | GPL-3.0-or-later (`LICENSE`) | yes | Own work, © 2026 Arkad Consulting. No third-party code copied in except the file listed below. |
| Swift packages | — | — | None: `Package.swift` has no dependencies (Apple frameworks only). |
| `Resources/Fonts/Fraunces.ttf` | SIL OFL 1.1 (`OFL-Fraunces.txt`) | yes, with the licence file | App UI font. |
| `Resources/Fonts/Geist.ttf`, `GeistMono.ttf` | SIL OFL 1.1 (`OFL-Geist.txt`) | yes, with the licence file | App UI fonts (Vercel). |
| `Resources/AppIcon.icns` | own work | yes | |
| `Resources/Brand/arkad-*.svg`, `arkad-*.png` | Arkad Consulting trademarks, **not** under the GPL | only unmodified, inside Regista | The built-in Arkad brand kit. Forks must remove them or use their own logo (`TRADEMARKS.md`). |
| `Resources/Brand/cafe-atelier-placeholder-*.svg` | GPL-3.0-or-later | yes | Placeholder wordmark of the fictional Café Atelier starter kit. |
| `engines/whisperx/uv.lock` | — | yes | A lock file (names, versions, hashes), not the packages. |
| `engines/hyperframes/package.json`, `package-lock.json`, `.npmrc` | — | yes | The HyperFrames CLI's exact version and its 125 dependencies with their sha512 integrity (a lock file, not the packages); `npm ci --ignore-scripts` installs them on the user's Mac. |
| `Tests/Fixtures/hyperframes-kicker/index.html` | own work | yes | Loads GSAP 3.14.2 from jsDelivr at render time (GSAP "Standard no-charge" licence, not redistributed). |
| `engines/voxcpm/train_voxcpm_finetune.py` | Apache-2.0 (OpenBMB/VoxCPM 2.0.3) | yes, with attribution | Copied unmodified (header names the source); run by `voice.enroll.train`. |
| `Resources/SFX/` (185 sound effects, 4.2 MB) | MIT (earshot 0.3.0, © 2026 Leon Lin; `Resources/SFX/LICENSE.txt`); 15 fitted sounds from CC0 1.0 recordings | yes, with the licence file | Sound effects made in code by [earshot](https://github.com/Leonxlnx/earshot) (commit 0121eb6, released 2026-10-18), rendered once by `scripts/sfx-bank.py` (no recording inside; the fitted ones are recipes measured from CC0 Freesound recordings, each credited in `manifest.json`). Listed by `sfx.library` on every install; pinned by sha256 in `scripts/engines.lock` (`sfx-bank`). |
| `engines/voxcpm/uv.lock`, `vox_say.py`, `scripts/*.md` | — / own work | yes | Lock file; own script; recording scripts written for Regista. |
| `handoff/*` | GPL-3.0-or-later | yes | Install guides (French, Portuguese), the start prompt for Claude Desktop, the Claude Code skill, the zip launcher. |

## Downloaded by the installer or installed by the user (never bundled)

| Engine | Version (engines.lock) | Licence | How it runs | Notes |
|---|---|---|---|---|
| ffmpeg / ffprobe | Homebrew `ffmpeg` ≥ 7.0 | LGPL-2.1+ / GPL (Homebrew build enables GPL parts) | separate process | Installed by the user with Homebrew (or a first-run download), never bundled: Regista links nothing from it. A release must not ship an ffmpeg binary inside the app. |
| CMake, uv | Homebrew, minimum versions in engines.lock | BSD-3-Clause (CMake); Apache-2.0 OR MIT (uv) | build / environment tools | Installed with Homebrew by the installer: CMake builds whisper.cpp, uv makes the Medium-tier Python environments. |
| whisper.cpp | 1.9.5 (source tarball, built locally) | MIT | separate process | |
| ggml large-v3-turbo | ggerganov/whisper.cpp @5359861 | MIT (OpenAI Whisper weights, MIT) | model file | |
| DeepFilterNet | 0.5.6 release binary | MIT OR Apache-2.0 | separate process | Model embedded in the binary (same licence). |
| WhisperX environment | whisperx 3.8.6 + 123 locked wheels | BSD-2-Clause (whisperx); torch BSD-3; faster-whisper / CTranslate2 MIT; pyannote.audio MIT; transformers Apache-2.0; NLTK Apache-2.0 | separate process (uv) | Medium tier and up. Full per-package list: `uv pip list` + each package's metadata in `~/Library/Application Support/Regista/engines/whisperx/.venv`. |
| faster-whisper model | converted locally from openai/whisper-large-v3-turbo @41f01f3 | MIT | model files | |
| wav2vec2 English / Portuguese aligners | torchaudio `WAV2VEC2_ASR_BASE_960H` (PyTorch download) / `jonatasgrosman/wav2vec2-large-xlsr-53-portuguese` @634ac65 | MIT / Apache-2.0 | model files | Pinned with sha256 (#60), installed with WhisperX (Medium tier); `wx_align.py` loads them from the engines folder and never downloads one. |
| wav2vec2 VoxPopuli IT / FR aligners | torchaudio `VOXPOPULI_ASR_BASE_10K_IT` / `_FR` | **CC BY-NC 4.0** (VoxPopuli) | model files | **Non-commercial, opt-in** (#20, #60): the installer and Settings › Motori show the licence and install them only when asked (`--with aligner-it,aligner-fr`); without them Regista transcribes Italian / French with whisper.cpp. A commercial product must not rely on them. Not redistributable in a commercial bundle. |
| NLTK punkt_tab | nltk_data @4f15a3d | Apache-2.0 | data file | |
| VoxCPM2 environment | voxcpm 2.0.3 + 170 locked packages (`engines/voxcpm/uv.lock`) | Apache-2.0 (voxcpm); torch BSD-3; transformers Apache-2.0 | separate process (uv) | Medium tier and up. Full per-package list: `uv pip list` + each package's metadata in `~/Library/Application Support/Regista/engines/voxcpm/.venv`. |
| VoxCPM2 weights | openbmb/VoxCPM2 @32279ef (2026-08-18) | Apache-2.0 | model files | The base voice model (4.6 GB + its audio VAE and tokenizer, each sha256-pinned in `engines.lock` as `vox:*`). No voice ships with Regista: each user records their own (profiles stay on their Mac); voice-over and LoRA training run in the separate VoxCPM2 environment. |
| Blender | 5.2.2 (optional) | GPL-2.0+ | **separate process only** (headless script) | Never linked or bundled; the user installs it (installer downloads the official dmg). The title script Regista writes is its own code. |
| Shotcut | 26.9.28 (optional) | GPL-3.0-or-later | separate app | Opens the `.mlt` exports; nothing shared at runtime. |
| ComfyUI, with the ComfyUI-GGUF node pack | manual setup (Pro tier) | GPL-3.0 (ComfyUI); Apache-2.0 (ComfyUI-GGUF) | **separate process, over HTTP** | Never linked or bundled. Regista sends its shipped workflows to ComfyUI's HTTP API itself; when Settings › Engines names a ComfyUI folder, it starts ComfyUI there for a generation and stops it afterwards. The node pack loads the Wan 2.2 GGUF files. Models (the `comfyui-*` entries of `scripts/engines.manifest.json`, every file pinned by size and sha256, downloaded by the user from its row or from the publisher's page): **Z-Image Turbo** (Z-Image Turbo bf16, Qwen3 4B text encoder, FLUX VAE: Apache-2.0); **Wan 2.2 image-to-video** (Wan 2.2 I2V A14B Q6_K GGUF high and low noise, lightx2v 4-step lightning LoRAs, umt5-xxl text encoder, Wan 2.1 VAE: Apache-2.0; RIFE 4.26: MIT); **ACE-Step 1.5** (turbo model, Qwen 0.6B and 1.7B text encoders, VAE: Apache-2.0); **Real-ESRGAN + RIFE** (RealESRGAN x4plus: BSD-3-Clause; RIFE 4.26: MIT). Re-check each model card at setup time, the lightning LoRAs' first (the manifest notes that their licence is to be read on their model card). |
| HyperFrames CLI | 0.8.150 from `engines/hyperframes/package-lock.json` (`npm ci --ignore-scripts`, resolved with `--before` 14 days back) | Apache-2.0 (dependencies: MIT / ISC / Apache-2.0 / BSD, see `node_modules/*/package.json`) | separate process | Installed in the engines folder (Medium tier); headless Chrome is downloaded by HyperFrames at the first render (`~/.cache/hyperframes`). GSAP is loaded by the compositions (Standard no-charge licence). |
| Node.js | 24.22.1 official darwin-arm64 build (sha256 from nodejs.org SHASUMS256.txt) | MIT (and the licences in its `LICENSE` file) | separate process | Extracted into the engines folder by the installer (#60): nothing global, no Homebrew, no `npm -g`. |
| Higgsfield | paid web service (optional) | terms of service | HTTPS | Not part of Regista; the user's own account and budget. |
| Apple Vision, AVFoundation, Speech, Core Image, Core Text | macOS | Apple SDK licence | system frameworks | |
| Claude Desktop / Claude Code | — | Anthropic terms | separate apps (MCP client) | |

## Referenced, not bundled — cannot be redistributed

| Asset | Where Regista looks for it | Licence | Why it stays outside |
|---|---|---|---|
| Impact (caption font of `talking-head-v1`) | macOS system font, by name | Microsoft / Monotype, proprietary | Ships with macOS; may not be copied into a release. A public release could default to an OFL condensed sans (e.g. Anton, Bebas Neue) and keep Impact as an option. |
| WeSites brand fonts (Young Serif, Instrument Sans, Fragment Mono) | the WeSites brand kit's folder (`~/Library/Application Support/Regista/brandkits`) | SIL OFL 1.1 | Redistributable in principle, but they belong to the WeSites brand kit's own assets: kept out of the repo. |
| `wesites-mark.svg` and your own logos | the brand-kit folder | the brand owner's trademarks | Brand assets stay in the user's brand-kit folder, never in the repository. |
| Your own sound effects (`sfx.library`, extra source) | `sfxLibrary` in engines.json (default `~/Library/Application Support/Regista/sfx`) | the user's (e.g. Pixabay Content License) | Pixabay's licence forbids redistributing the files as a standalone collection: users add their own library next to the shipped bank. |
| Test footage (`IMG_*.MOV`, the 2026-10-26 take) | `REGISTA_TEST_MEDIA`, `REGISTA_GOLDEN_MEDIA` | private recordings (people's faces and voices) | Never committed; scenarios skip without them. |

## Evaluated and not used

| Item | Licence | Why not | Checked |
|---|---|---|---|
| MiniMax H3 (video model behind openjutsu's swaps) | MiniMax H3 Community License | Granted "worldwide, excluding the European Union, the United Kingdom, the Republic of Korea and the United States": not licensed in France, where Arkad is based. Also needs an NVIDIA GPU. | 2026-11-03 |
| InsightFace `buffalo_l` | non-commercial research only | Face identity for openjutsu's face fix: not for client work. | 2026-11-03 |
| Ultralytics YOLO weights (Bingsu/adetailer) | AGPL-3.0 | Same face fix; AGPL terms not wanted in the toolchain. | 2026-11-03 |

Planned and compatible: **SAM 3.1** (Meta, SAM License 2025-11-19 — worldwide, royalty-free, commercial use allowed;
redistribution must carry the licence; no ITAR, military, nuclear, espionage or weapons end uses) for objects
tracked by name (#37). Downloaded by the user like every other model, never bundled.

## Open points

1. A commercially licensed Italian / French aligner would bring precise timings back to commercial work without the
   non-commercial VoxPopuli models (#20).
2. Consider an OFL default caption font instead of Impact.
3. Re-run this audit against `engines/whisperx/uv.lock` and `engines/voxcpm/uv.lock` (per-package licences) and the
   ComfyUI model cards when they change.
