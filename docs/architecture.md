# Regista architecture

How Regista is built, for developers and for anyone driving it from an agent. Using the app: [user-guide.md](user-guide.md);
installing it: the [README](../README.md); engines by tier: [engines.md](engines.md).

## Development

The Apple **Command Line Tools** are enough to work on the code (`xcode-select --install`); Xcode is not needed.

```bash
scripts/build-app.sh            # build and open build.noindex/Regista.app (and the matching release regista-mcp)
scripts/build-app.sh --install  # and copy it to /Applications; another copy in ~/Applications goes to the Trash
scripts/signing-identity.sh --remove  # undo the local signing identity (permissions are asked once more after)
scripts/test.sh                 # tests
```

**One app, stable signature, visible build** (#45). `--install` leaves exactly one `Regista.app` across
`/Applications` and `~/Applications`. Every build signs with a self-signed "Regista Local Build" identity kept in a
keychain of its own, `~/Library/Application Support/Regista/signing/regista-signing.keychain-db` (folder 0700),
with a random password beside it (`keychain-password`, 0600). `scripts/signing-identity.sh` creates it on the first
build and repairs it afterwards, without any dialog: the scripts unlock that keychain themselves, codesign may use
its key, and it is selected by certificate SHA-1 with `codesign --keychain`. The same designated requirement on
every build means macOS asks camera, microphone and screen permission once and keeps it. The login keychain is never
read or changed; the only system setting touched is the user keychain search list, where the dedicated keychain is
appended at the end (codesign does not find an identity in an unlisted keychain, even with `--keychain`), every other
entry kept as it was. Trade-off: the password sits on the same disk, so any process running as you could sign a
binary macOS treats as Regista, with its permissions — fine for a build made on your own Mac; a distributed build
needs a Developer ID (#70). `scripts/signing-identity.sh --remove` takes the keychain out of the search list and
deletes it with its password file; deleting the folder does the same except for the search list entry. Either way
the next build creates a new certificate, so macOS asks the permissions once more. If the identity cannot be created
or used, the build signs ad-hoc with one warning that says why. The build id (git short sha, `-dirty.<hash>` for uncommitted
changes) and date are in the About panel; `engines.status` reports `build`, and through `regista-mcp` attached to the
app also `appBuild`, `mcpBuild` and a `buildWarning` saying which one to rebuild when they differ.

With Xcode installed, opening `Package.swift` is enough. Installer details: "Installer" below. Enable the pre-commit
gate once per clone with `git config core.hooksPath .githooks` ("Pre-commit hook" below).

**Settings (⌘,)** has five tabs (M2 #59): **General** (interface language, spoken language transcription starts from,
the Regista folder, the format of new projects, automatic saving — off by default), **Engines** (this Mac's RAM, tier
and free disk, every engine of `scripts/engines.manifest.json` by tier with its state, size and licence; **Install**
runs `scripts/install.sh --only <id>` as a job with progress and Cancel, **Remove** deletes only the engine's `files`
in the engines folder after saying what stops working, manual engines show their steps; **Force tier** writes `tier`
in engines.json), **Profile and voice**, **Claude** (connection and build, whether Claude Desktop and Claude Code are
connected, the start prompt) and **Shortcuts** (the catalog the menus use, searchable). No API key is needed: the old
paid pipeline (OpenAI / Anthropic / ElevenLabs keys) was removed; keys stored earlier stay in the Keychain untouched.

**UI languages.** The interface is written with Italian literals; `Resources/Localization/en.lproj`, `fr.lproj` and
`pt.lproj` hold the English, French and Portuguese (Brazilian) text (Italian keys) and `it.lproj` maps each key to
itself (the engine manifest's phrases are keyed by their English text). The app follows the macOS language, English
otherwise; a language not translated yet is declared pending in one place in `scripts/l10n.py`. `python3 -I scripts/l10n.py` (also in the pre-commit hook) fails when a
string is missing from a table (run it after adding UI text; `--todo <lang>` prints the keys a table lacks). The terms used in
every language are in `Resources/Localization/glossary.md`.

## Code structure

```
Sources/Regista/
  App/          launch, menus, settings, Keychain
  Editor/       EditorStore (the app's engine + socket), preview, media cache, meter, ui.screenshot
  UI/           the views: Shell (top bar), Pro, Simple (guided steps), Export, timeline, Agent panel, theme
  Recording/    camera+microphone and screen recording (tutorials), teleprompter
  Pipeline/ Edit/   the old paid automatic edit (no longer reachable, kept for reference)
```

## Claude at the edit (MCP)

Regista is driven from **Claude Code** or **Claude Desktop**: every editing action is a command, and Claude uses them
through a small local MCP server. **With the app open, Claude works in the app**: the server connects to the editor by
itself (top right `Claude ● connected`), every command shows in the Agent panel and the timeline updates while it
works. With the app closed it works on its own, without a window, and saves the project (open it later with ⌘O).

```bash
scripts/build-mcp.sh   # once, and after EVERY update (git pull, changes): Claude Code does not rebuild it
```

`scripts/install.sh` registers it for every Claude Code session (`claude mcp add --scope user regista`) and rebuilds it
on every update. In the repository folder the `.mcp.json` file works too (Claude Code asks to approve it on first
launch). The videos and scripts Claude can see are in **Movies/Regista** (or the folders passed with `--media-root`).

## Architecture (developers)

```
RegistaCore     pure Swift, no AppKit — project model, time, commands, Engine, scenarios, captions, render plan, MLT
RegistaMCP      MCP over JSON-RPC 2.0: MCPServer, stdio transport, EngineHost seam, test client
regista-engine  headless CLI: `exec` one command, `run` a scenario (directly or via MCP)
regista-mcp     stdio MCP server used by Claude Code (.mcp.json)
RegistaEngines  engine adapters that need Apple frameworks (Vision faces, Core Image compositor, Core Text captions, AVFoundation export)
Regista         the SwiftUI app (recording, teleprompter, current auto-edit pipeline)
```

- **Model** (`Project.swift`): OpenTimelineIO-inspired, Codable value types — assets (path, duration,
  video size/fps/rotation, audio), tracks bottom-to-top (`video`, `audio`, `caption`, `overlay`; name,
  locked, muted, hidden), clips (asset, source in/out, timeline start, transform), markers. Ids are short
  per-project serials (`a1`, `t2`, `c5`). Saved as `<name>.regista/project.json`.
- **Time** (`Time.swift`): `MediaTime` is an `Int64` count of ticks at 1/705 600 000 s, so 23.976–120 fps
  and 44.1/48/96 kHz are all whole numbers of ticks — no Double drift. Seconds exist only in JSON params and
  summaries. Timeline times snap to the project frame grid, source times to the asset's frames.
- **Commands** (`Command.swift`, `Commands/`): a `Command` has an id (`timeline.cut`), a summary, a
  parameter description, a kind (`query`, `edit`, `session`, `history`) and a `run` on a copy of the engine
  state — a failing command changes nothing. The parameter description drives validation (missing, unknown,
  mistyped params get explicit errors) and the MCP JSON schema; `CommandParams` refuses to read undeclared
  params, so code and schema can't drift.
- **Undo**: every `edit` stores the project before and after (snapshots of a small value type). Undo/redo
  swap snapshots; opening or creating a project clears the history.
- **Engine** (`Engine.swift`): holds the project, runs commands, keeps the command log and the history.
  One owner, not thread-safe.

Commands (144; each one an MCP tool except the human-only `generate.approve`): `project.new`, `project.format`, `project.open`, `project.save`, `project.close`, `project.state`, `recipe.get`,
`media.list`, `text.read` (below, "MCP server"), `media.import` (ffprobe,
isolated behind `MediaProber`; set `REGISTA_FFPROBE` to override the path), `track.add`, `track.set`, `timeline.place`,
`timeline.cut`, `timeline.trim`, `timeline.move`, `timeline.delete` (ripple), `timeline.link`, `clip.set`, `history.undo`,
`history.redo`; analysis (below): `engines.status`, `media.extractAudio`, `media.measureLoudness`, `transcript.run`,
`transcript.get`, `transcript.evaluate`, `audio.clean`, `faces.track`, `script.set`, `takes.list`, `takes.select`,
`takes.compare`, `edit.autoCut`; editing: `edit.punchIns`, `transcript.timeline`, `transcript.deleteWords`, `transcript.editText`; captions:
`captions.generate`, `captions.get`, `captions.setKeywords`, `captions.setStyle`, `captions.place`; placing by hand
(below, "Moving things by hand"): `clip.place`, `frame.elements`, `media.checkPlacement`; output: `export.render`, `frame.render`,
`frame.contactSheet`, `export.srt`, `export.mlt`; checks: `media.probe`, `media.compare`, `captions.checkTiming`, `media.checkSync`.
App only (they need the running editor; headless they say so): `ui.screenshot`, `preview.frame` (see "The app").
Graphics (below, "Graphics layer"): `overlay.add`, `clip.keyframe`, `title.add`, `effect.add`, `effect.remove`,
`transition.add`, `brandkit.list`, `brandkit.apply`, `brandkit.create`, `brandkit.update`, `brandkit.setLogo`,
`brandkit.setFont`, `brandkit.import`, `brandkit.export`, `brandkit.delete`, `brandkit.preview`, `brandkit.check`, `logo.add`
(below, "Brand kits"), `graphics.blenderTitle`, `graphics.hyperframes`, `audio.addMusic`,
`audio.duck`, `sfx.library`, `sfx.add`, `timeline.mapTimes`; graphics checks: `graphics.checkLayout`, `media.checkOverlay`,
`audio.checkDucking`, `sfx.checkOnsets`; behind the person (below, "Text behind the person"): `matte.track`,
`graphics.checkBehindSubject`. Looks (below, "Looks"): `layout.speaker`, `hands.track`, `clip.follow`, `status.add`, `meters.add`. Screen recordings (below, "Screen recording"): `recording.import`, `layout.presets`,
`layout.apply`, `edit.autoZoom`, `cursor.style`, `keys.overlay`, `recording.synthesize`, `recording.check`. Generation (below, "Generated media"): `generate.providers`, `generate.estimate`,
`generate.approve` (human only), `generate.run`, `generate.upscale`, `generate.status`, `generate.list`. Effects and
motion templates (below, "Effects for users", "Motion templates"): `look.list`, `look.apply`, `adjust.set`, `clip.speed`,
`sticker.add`, `callout.add`, `progress.add`, `logo.animate`, `effects.catalog`, `effects.preview`, `style.apply`,
`edit.beatSync`, `effects.check`, `motion.add`, `media.synthesize`.
`regista-engine list` prints them with their parameters.

**Human-only commands** (`Command.humanOnly`, today only `generate.approve`): the MCP server neither lists nor runs them
(`tools/call` returns an error that tells the agent to ask the person), and the app's engine socket refuses them from
every client (socket clients are agents). They run from the app's own UI (`EditorStore.run`) or from the owner's
terminal with `regista-engine exec` — that is the human path by definition: an agent session started by `scripts/g0.sh`
or Claude Code over MCP has no way to reach it.

**Linked clips.** `edit.autoCut` links the picture and the sound of each range (`link` id on both clips; `timeline.place
linkTo`, `timeline.link`). `timeline.cut/move/trim/delete` then act on both — a ripple delete closes the gap on every
affected track — unless called with `linked: false`. `audio.clean` swaps the sound and keeps the links and fades.

**Clip properties** (`clip.set`, on clips or a whole track): crop in source pixels `[w, h, x, y]` (stored as fractions of
the source's display frame), `scale`/`x`/`y`/`rotation`/`opacity`, `keyframes` (clip-relative, linear, they override the
static transform), grade with ffmpeg `eq` semantics (`brightness`/`contrast`/`saturation`) and audio edge fades
(`fadeIn`/`fadeOut`; `edit.autoCut` sets 15 ms on every sound clip).

**Punch-ins** (`edit.punchIns`): two framings (`base`, `punch`) alternating at every clip or at every script line
(`by: "line"`, from the takes). `mode: "face"` keeps the crop sizes and centres each crop on the tracked face (the
`faces.track` sidecar, One-Euro smoothed, averaged over 0.5 s, raised by 25% of the face height for hair, clamped to the
frame), as keyframes every 5 frames — or a static crop when the face barely moves. Ordinary `clip.set` commands, one undo step.

**Text-based editing.** `transcript.timeline` lists the words as the timeline plays them (each clip's transcript, or the
transcript of the file a derived asset came from, mapped through the clip; a word belongs to the clip holding its middle).
`transcript.deleteWords {from, to}` removes words: cut points at the first word's start and the next word's start (or the
clip edges when the range starts/ends a clip), frame-snapped; `timeline.cut` on every track, then a ripple
`timeline.delete`; captions are regenerated in the same undo step. `expect` guards against stale indices.
`transcript.editText {from, to, text, expect}` corrects the words only (a misheard name): the new words share the old
span by length in the source transcript, nothing is cut, captions follow. In the app: the pencil on each transcript
paragraph. `track.delete {trackId, force}` removes a track (force when it still holds clips); in the app: the bin on
hover of a track header, or right click → Elimina pista.

### Headless engine

```bash
swift build --product regista-engine
B=$(swift build --show-bin-path)
$B/regista-engine exec project.new '{"name":"demo","directory":"/tmp"}'
$B/regista-engine exec media.import '{"path":"~/Movies/take.mov"}' --project /tmp/demo.regista
$B/regista-engine run Tests/Scenarios/basic.json            # in-process engine
scripts/scenario.sh Tests/Scenarios/basic.json               # same scenario through regista-mcp (stdio)
```

Scenarios (`Tests/Scenarios/*.json`) are lists of `{command, params, expect, expectError, capture}` steps.
`expect` maps a path in `result` or `state` (project.state after the step) to a value or a matcher
(`equals`, `approx`+`tol`, `min`/`max`, `count`, `exists`, `contains`); a top-level `"requires": ["engines"]`
marks scenarios that need the engines (`--skip-requiring engines` skips them) and `"requires": ["footage"]` with a
`"footage": [paths]` list marks those that need the test take: they skip themselves when a file is missing (a clone
without the test footage); `capture` saves values for `${name.path}`
substitution. `${WORK}` is a fresh scratch folder (or `--work <dir>`), `${HOME}` and other environment
variables are available. See `Sources/RegistaCore/Scenario.swift`.

### MCP server

`scripts/build-mcp.sh` builds the release `regista-mcp` (and `regista-engine`) and prints its path; `.mcp.json` (repo root)
registers it for Claude Code as `regista` at `${HOME}/code/regista/.build/release/regista-mcp` (adjust if the repo lives
elsewhere, or `claude mcp add regista -- <path>/regista-mcp`). **Release-build gotcha:** Claude Code launches whatever
binary is there and never rebuilds it, while the pre-commit hook and `scripts/scenario.sh` build *debug* — after every
pull or change run `scripts/build-mcp.sh`, or the session silently serves the old tools (`scripts/g0.sh` always does).

Protocol: newline-delimited JSON-RPC 2.0 on stdio, `initialize` (2025-11-25, also accepts 2025-06-18 / 2025-03-26 /
2024-11-05), `ping`, `tools/list`, `tools/call`, `prompts/list`, `prompts/get`. Each command is a tool named with `_`
instead of `.` (`timeline_cut`); its description says when to use it and what it returns; command errors come back as
`isError` results so the model can correct itself. Logs go to stderr.

Built for an agent that has **no shell and no file tools** (golden test G0):
- **Images.** A command result may list `images: [{path, mimeType, width, height}]`; the server sends each file as MCP
  image content (`{"type": "image", "data": <base64>, "mimeType"}`, at most 8) after the JSON text. `frame.render`
  returns up to 6 previews 540 px wide (JPEG, `inline: false` to skip); `frame.contactSheet` renders N frames (default 12,
  evenly spaced over the timeline or `from`/`to`, or `times`) through the export compositor and tiles them, each labelled
  with its time, in one JPEG of at most 1600×1600 (`<project>.regista/previews/contact-<n>.jpg`). Drawing is
  `ImageToolkit` (RegistaCore protocol) → `CGImageToolkit` (Core Graphics + Core Text, RegistaEngines).
- **Media roots.** `media.list` lists video/audio/image/text/project/Shotcut files under the roots (depth 3, hidden files
  skipped, `.regista` folders listed as projects) and reports `outputDirectory`; `text.read` reads `.md/.txt/.srt/.json`
  (≤ 256 KB). Roots: `~/Movies/Regista`, every `--media-root <dir>` and `REGISTA_MEDIA_ROOT` (colon-separated), and the
  output directory (`--output-dir <dir>` / `REGISTA_OUTPUT_DIR`, which is created and becomes the server's working
  directory). Paths are standardized (`..` resolved) before the check and anything outside the roots is refused; a link
  the operator put inside a root is followed. Other commands (`media.import`, exports) still take any path.
- **Recipe.** The `talking-head-reel` prompt (arguments `footage`, `script`, `brand`) is the step-by-step recipe with the
  house rules copied from the reel templates of the earlier Python prototype (`_common.md`, `talking-head.md`: approved style, pacing, −15 LUFS,
  safe zones, glossary); `recipe.get` returns the same text as a tool (headless clients do not show prompts to the
  model) and the `initialize` `instructions` carry a short version. The `reel-graphics` prompt (arguments `brand`,
  `brief`; its step 14 points there) dresses a finished edit: which layer when (title / card / insert / nothing), the
  layout bands (top band 110–640 with small cards on the wall at y ≈ 170–230, face clear, caption band 1230–1460
  always clean, Instagram chrome), SFX sparse and on beats at 0.2–0.3, music only when asked and always ducked, kit
  fonts/colours by role, the house taste (abstract fine touches, no literal decoration, no gimmicks, real motion), and the
  checks. Source: `Sources/RegistaCore/Recipes.swift` — keep it in sync with the templates.

```bash
regista-mcp [--media-root <dir>]… [--output-dir <dir>]
```

Quick check: `printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}' '{"jsonrpc":"2.0","id":2,"method":"prompts/list"}' | .build/release/regista-mcp`

**Live attach.** The server talks to an `EngineHost` (`descriptors()`, `execute()`). `regista-mcp` uses
`AutoEngineHost`: on the first tool call it connects to the app's Unix socket
(`~/Library/Application Support/Regista/engine.sock`, owner-only, `$REGISTA_ENGINE_SOCKET` overrides) and forwards
every call there (`SocketEngineHost`); if nothing listens it runs a headless engine in-process (`InProcessEngineHost`),
and the choice sticks for the session. `REGISTA_ENGINE=app` requires the app, `REGISTA_ENGINE=local` never attaches.
Framing: one JSON object per line, `{"op": "hello", "client"}` then `{"op": "execute", "command", "params"}` →
`{"ok", "result" | "error"}` (`RegistaMCP/EngineSocket.swift`). Test replays stay headless: `regista-engine run --mcp`
starts the server with `REGISTA_ENGINE=local` unless `--engine app` (`scripts/scenario.sh … --engine app`). Media roots
and the output directory of an attached session are the app's (`~/Movies/Regista`, `REGISTA_MEDIA_ROOT`), not the
server's `--media-root` flags.

### Installer (issue #12)

`scripts/install.sh` (bash 3.2, never sudo) is what users run; `scripts/install.sh --only <id> [--check]` installs one
engine of the manifest with the same step (what Settings › Engines runs, from the copy of the installer inside the app
bundle; it refuses unknown ids, engines the installer cannot install and engines above the tier); `scripts/doctor.sh` re-checks an installation
read-only and prints the fix for each problem (exit 1 if anything is wrong; `--quick` skips hashing the big models). Both
source `scripts/lib.sh`, and both speak the macOS language — Italian, English, French or Portuguese, English otherwise;
`REGISTA_LANG=it|en|fr|pt` forces one (messages in `scripts/i18n.sh`, a test checks every key exists in all four).

- **Pins.** `scripts/engines.lock` is the single manifest: `id | version | released | pinned | sha256 | size | url`
  for every download (whisper.cpp source, ggml model at a Hugging Face revision, DeepFilterNet, the WhisperX aligners,
  NLTK `punkt_tab`, the OpenAI files the faster-whisper model is converted from, Node.js, Blender, Shotcut), `repo:`
  entries for files shipped here (`engines/whisperx/uv.lock`, `engines/hyperframes/package-lock.json`) and `brew:`
  minimum versions. `doctor.sh` enforces the
  supply-chain rule on every line (released ≥ 14 days before pinned). `build-whisper.sh` reads its pin from the lock.
- **ffmpeg** comes from Homebrew (installed if missing, version ≥ the lock's minimum, warned otherwise): FFmpeg ships no
  official macOS binaries, the static arm64 builds it links to are single-maintainer third-party builds, while
  Homebrew bottles are built in Homebrew's CI from the checksummed official source. Same for `cmake` (whisper.cpp
  build) and `uv` (Medium tier). Bottles are not pinnable: the gap is a minimum version, not a hash.
- **Medium tier.** `engines/whisperx/` (pyproject + `uv.lock` ported from the Python prototype without mediapipe: same 123
  package versions, `exclude-newer = 2026-10-18`, all wheels, no litellm, plus `wx_align.py`/`textnorm.py`) is copied to
  `<support>/engines/whisperx/` and installed with `uv sync --frozen`. `punkt_tab` is unpacked into the env's own
  `nltk_data` so WhisperX never downloads it unpinned at run time. The faster-whisper model is converted locally
  (ctranslate2 4.8.3, float16) from OpenAI's repo at a pinned revision, every source file SHA256-checked; the result
  is compared with the lock's reference hash (a mismatch is reported, not fatal). Aligners: English (torchaudio) and
  Portuguese (Hugging Face, pinned revision) are installed with WhisperX; Italian and French are CC BY-NC 4.0, so the
  installer prints the licence and installs them only on request (`--with aligner-it,aligner-fr`, or yes at the prompt;
  never with `--yes` alone). Without the aligner of a language, `transcript.run` falls back to whisper.cpp and says why.
  Node.js 24 (official build, sha256) is extracted into the engines folder and the HyperFrames CLI installed from
  `engines/hyperframes/package-lock.json` with `npm ci --ignore-scripts` (npm's cache in Regista's download cache):
  nothing global.
- **ComfyUI (Pro, by hand).** `generate.check` compares each model's workflow with the running server's
  `/object_info` and lists missing node packs, model files (with their ComfyUI folder) and renamed values; it never
  starts ComfyUI (off = "not checked"). `generate.run` runs it first and fails at once when something is missing.
- **The app's own MCP server.** `scripts/build-app.sh` puts `regista-mcp` and `regista-engine` in
  `Regista.app/Contents/MacOS`; the installer connects Claude Desktop and Claude Code to that copy, never to a source
  folder, and doctor flags a config that runs another one (Settings › Claude offers to repoint it).
- **Layout.** Engines in `~/Library/Application Support/Regista/engines/`, config `engines.json` there (the installer
  only sets the keys it manages and keeps the rest), build logs in `logs/`, downloads in
  `~/Library/Caches/Regista/downloads/<id>/<file>` (reused when they verify), the app in `/Applications` when writable,
  else `~/Applications` (a copy left in the other folder is moved to the Trash). Existing verified copies are referenced in place (the paths `engines.json` already names), and the download cache is reused.
- **Overrides** (for tests and unusual setups): `REGISTA_SUPPORT_DIR`, `REGISTA_CACHE_DIR`, `REGISTA_ENGINES`,
  `REGISTA_APP_DIR`. `scripts/fresh-user.sh` runs the whole new-user simulation (installer + doctor in a temp home with
  a prebuilt app, see its header). Foundation ignores `$HOME`, so a fresh-user simulation also sets `CFFIXED_USER_HOME`:

  ```bash
  T=$(mktemp -d); git clone ~/code/regista $T/home/code/regista   # cache: symlink already-downloaded files into $T/cache/<id>/
  HOME=$T/home CFFIXED_USER_HOME=$T/home CLAUDE_CONFIG_DIR=$T/home/.claude REGISTA_CACHE_DIR=$T/cache \
    REGISTA_APP_DIR=$T/home/Applications $T/home/code/regista/scripts/install.sh --yes --tier base
  ```
  With `HOME` and `CLAUDE_CONFIG_DIR` in the temp folder, `claude mcp add --scope user` writes the temp config, not yours,
  and the Claude Desktop entry goes to `$HOME/Library/Application Support/Claude/` in the temp folder too (put a fake
  config there first to test the merge). The package is tested the same way: unzip it in a temp folder and run
  `bash <dir>/INSTALLA.command </dev/null` with the same environment.
- **Claude connections.** `--claude desktop|code|both|none` (default: whichever is installed — `claude` in PATH for
  Claude Code; `Claude.app` in /Applications or ~/Applications, or an existing config, for Claude Desktop; `--no-claude`
  = `none`). Claude Code: `claude mcp add --scope user regista` (replaces a previous user-scope entry). Claude Desktop:
  `scripts/claude_desktop.py set` adds or replaces `mcpServers.regista = {"command": <abs>/regista-mcp, "args": []}`
  (+ `env.REGISTA_ENGINES` when engines.json is not at its default place) in
  `~/Library/Application Support/Claude/claude_desktop_config.json`, keeping every other key (Desktop keeps its own
  `preferences` there) and server; asks first unless `--yes`, copies the file to
  `claude_desktop_config.json.regista-backup-<timestamp>`, writes a temp file, reads it back and checks it before
  moving it into place, and never touches a file that is not valid JSON (it prints the entry to add by hand).
  `doctor.sh` checks both: a regista entry pointing to another or missing binary is a problem; a client installed but
  not connected is a problem only when no client at all is connected (a warning otherwise).
- **Claude Desktop limits** (Claude Desktop 4.4212, 2026-11-02): it reads the config only at launch — quit it with ⌘Q
  and reopen after installing (doctor cannot see whether it reloaded). It starts `regista-mcp` with a minimal
  environment: every engine path comes from engines.json, npx is also searched in fnm/Homebrew, so nothing depends on the
  shell's PATH. The MCP SDK bundled in the app defaults to a **60 s request timeout** (`timeout ?? 6e4` in its
  `Protocol.request`; which value the chat passes for local tool calls could not be confirmed), and `regista-mcp`
  sends no progress notifications: a long call (`transcript_run` on a long take, `export_render`, a waited-for
  generation) can come back as "Request timed out" while the server keeps working — the server handles requests one at
  a time, so the next call simply waits, and transcription and generations are cached. The hand-off guide and
  `handoff/START-PROMPT.md` tell the user/agent to wait and check `project_state` instead of starting over. Desktop
  asks permission per tool ("Always allow" once). MCP prompts are not in the model's context there: the agent must call
  `recipe_get` (START-PROMPT.md says so).
- **Hand-off package** (issue #14). `scripts/package.sh` → `dist/regista-<date>-<shortsha>.zip`: `regista/` = `git
  archive HEAD` (tracked files only: no .git, builds or footage; ~3 MB) + a `SNAPSHOT` file, and from `handoff/`:
  `INSTALLA.command` (double-click: copies the snapshot to `~/code/regista` — or uses a git clone already there, which
  install.sh pulls, or rsyncs over an older snapshot keeping `.build` — strips the download quarantine and runs
  `scripts/install.sh`), `LISEZMOI.md` (FR) and `LEIAME.md` (PT) for a non-developer user, `START-PROMPT.md` (Claude
  Desktop Project instructions). Built from HEAD: commit first. A snapshot install has no git, so it updates by
  running a newer package's `INSTALLA.command`.
- **Smoke check.** `scripts/mcp_smoke.py mcp <regista-mcp>` (stdlib, `/usr/bin/python3 -I`): `initialize`,
  `tools/list`, `engines_status` over stdio, headless (`REGISTA_ENGINE=local`); `mcp_smoke.py socket <path>` says
  whether the app is listening.

### Pre-commit hook

`.githooks/pre-commit` first runs two repository guards: `scripts/check-voice-data.sh` (no voice data) and
`scripts/check-public.sh` (no internal names, personal home paths or real e-mail addresses in staged files; the
deny-list of names is read from outside the repository, `${REGISTA_PRIVATE_WORDS:-~/.config/regista/private-words}`,
one case-insensitive regex per line; `--all` checks the whole tree, `--self-test` checks the checker). Then it runs `scripts/test.sh` (RegistaCore, RegistaMCP and RegistaEngines tests — the latter push a
synthetic clip through the real compositor and writer) and every scenario that does not need the engines, directly and
through `regista-mcp` (~20 s). Scenarios that need the WeSites test footage (`"requires": ["footage"]`) skip themselves
with a note on a clone without it, so the hook passes on any clone. After changing a public struct of RegistaCore, `touch Sources/RegistaEngines/*.swift`:
SwiftPM's incremental debug build once left RegistaEngines compiled against the old layout (a crash in the tests). Enable it once per clone:

```bash
git config core.hooksPath .githooks
```

## Teleprompter (P2-T1, issue #1)

```
PromptScript (RegistaCore)      numbered sentences = takes, continuation lines, " / " breath marks, *keywords*
   ├─ Script.parse              same rules → the project's script lines always match the teleprompter's sentences
   └─ PromptScript.prepare      script.prepare: ≤ 32-char lines, breath marks after , ; : –, keywords (kept for captions)
TakeTracker (RegistaCore, pure) hypotheses in → cursor, restarts, live take markers, voice commands, pace
   └─ ScriptAligner             fuzzy windowed word alignment, off-script stop / resume, re-anchoring; digits spelled out
LiveSpeechSession (Engines)     DictationTranscriber (macOS 26, a hypothesis per word) > SpeechTranscriber > SFSpeechRecognizer
ScriptFollower (app)            mic buffers (SpeechAudioSink ← Recorder.speechSink) → session → tracker
TeleprompterController (app)    the window: sharingType .none, per-display frame, karaoke canvas, keys, sidecar on stop
```

- **Restart detection**: when the newest heard words are the first words of the sentence being read (≥ 2 words and
  ≥ 7 letters, or ≥ 3 words; up to 8 when hypotheses arrive in bursts), or of the sentence just finished, the cursor
  jumps back to that sentence and a new take starts. Not a restart: the speaker has not got past those words yet, the
  script itself continues with them, or they also start the next sentence. Split recognitions are glued back
  ("P hp" → PHP, "9 , 2" → nove virgola due).
- **Live take markers** `{sentence, take, start, end, complete, fromStart, discarded}` in recording seconds: dated by the
  recognizer's own word times once a result is final (words are found again by text after a revision), by arrival
  time minus 0.35 s until then. Saved as `<movie>.takes.json` (or `takes.json` in a screen session folder);
  `media.import` attaches them to the asset (`analysis.liveTakes`), `takes.live` does it by hand, `takes.list`
  prefers them (`source: auto|live|transcript`; ignored if they were logged against another script) and scores each
  reading with the transcript words inside it; `edit.autoCut` then cuts the chosen take as before.
- **Voice commands**: a phrase fires when it is the newest thing heard and not the script's own words around the
  cursor. Defaults: it `rifaccio`, `la rifaccio` / `stop`; fr `je recommence`, `je la refais` / `stop`.
- **Highlight lead** (`CursorLead`): between two recognizer updates the highlight advances at the speaker's pace, at
  most 2 words, never past a breath mark, punctuation or the sentence end, and not once the cursor stalls for 0.9 s.
- **Recorder seam** (with #6): the recorder hands every mic buffer to `Recorder.speechSink` (a `SpeechAudioSink`) while
  the capture session runs; markers are measured from the moment `isRecording` turns true; `onFinished` /
  `onSessionFinished` wait for `TeleprompterController.saveTakes(for:)` before importing.
- **Capture exclusion**: `TeleprompterController.makePanel` sets `sharingType = .none` (asserted; the only exception is the
  developer flag `--prompter-demo`), checked by `RegistaAppTests.teleprompterWindowIsExcludedFromScreenCapture`.
- **Screenshots**: `ui.screenshot {"workspace": "teleprompter" | "teleprompter-mirror"}` renders the window offscreen
  with the project's script; `REGISTA_TELEPROMPTER_SNAPSHOTS=<dir> [REGISTA_TELEPROMPTER_SCRIPT=<file>] scripts/test.sh
  --filter teleprompter` writes the same PNGs from the tests.

### Without a speaker: `teleprompter.simulate`

```bash
D=$REGISTA_GOLDEN_MEDIA   # the test take's folder (see "Test media")
regista-engine exec teleprompter.simulate '{"audio": "'$D'/raw/take.mov",
  "script": "'$D'/script.md", "reference": "'$D'/work/segments.json",
  "output": "/tmp/tp.json"}'                 # real time; "speed": 4 is faster but lags more
regista-engine exec teleprompter.simulate '{"replay": "/tmp/tp.json", "script": "…"}'   # offline, deterministic
```

The file is fed to the live recognizer in 100 ms buffers at speed× real time (a buffer is sent once its last sample
would have been spoken, plus 1 s of silence at the end), every hypothesis drives the take tracker, and the log keeps
the recognizer updates (replayable without Speech), the cursor trail, the final words and the markers (`takes.live`
reads it). Cursor lag = time from a word's end (its final timing) to the confirmed cursor / the drawn highlight
reaching it, for every word an ideal follower fed the final words would read in order. No speech-recognition
permission is needed for the SpeechAnalyzer engines, so it runs headless from the CLI; SFSpeechRecognizer needs it
and only an app bundle can ask, so the command reports that instead of crashing.


Scenario `Tests/Scenarios/wesites-teleprompter.json` (engines + footage, skipped by the hook) runs the simulation and
then the live markers through `takes.list` / `edit.autoCut` / `takes.compare` against the hand edit.

## Screen recording, face layouts, auto-zoom (P2-T2, issue #6)

```
RegistaCore/Recording/Session    session.json model (RecordingSession), SessionSync (sources on the common clock), RecordingLink
RegistaCore/Recording/Layouts    LayoutSpec presets → placement / crop around the face / mask per layer (pure geometry)
RegistaCore/Recording/AutoZoom   click groups, zoom keys, crop per clip aspect, cursor follow (safe zone), free band beside the face
RegistaCore/Recording/DragHold   drags from the session (mouse-up log, button state, else the cursor) → zoom held through them
RegistaCore/Render/CameraBlur    motion blur of camera moves: the crop's motion over the shutter as two scale+shift maps
RegistaCore/Recording/Synthesis  the synthetic session's screen description (ScreenSynthesizer protocol, cursor path)
RegistaCore/Recording/Cursor     drawn cursor: CursorStyle, spring-smoothed CursorPath, idle fade, ripples → CursorOverlay
RegistaCore/Recording/Drags      presses (click → mouseUp) and drags (≥ 160 ms, > 1.5% of the diagonal)
Commands/CursorCommands          cursor.style
RegistaEngines/CursorRasterizer  macOS cursor sprites (NSCursor per kind) and ripple rings drawn on the screen frame
RegistaCore/Recording/ScreenFrame styled frame (ScreenFrame: padding, radius, shadow) and its Backdrop (colour, gradients, image, presets)
RegistaCore/Recording/KeyOverlay logged keys → macOS notation (⇧⌘K), shortcut detection, repeats and typing runs collapsed
Commands/RecordingCommands       recording.import, layout.presets, layout.apply, edit.autoZoom
Commands/KeysCommands            keys.overlay
RegistaEngines/BackdropRasterizer the frame backdrop: per-pixel dithered gradients, aspect-filled image, cached per size
Commands/RecordingSynthCommands  recording.synthesize        Commands/RecordingCheckCommands  recording.check
RegistaEngines/ScreenSynthesizer the animated desktop (Core Graphics → AVAssetWriter H.264)
RegistaEngines/LayerShapes       CG masks (circle, rounded), border rings, shadows, cut-out matte steepening and soft sides
Regista/Recording/ScreenSession  the real capture: SCStream + camera/mic writers, events, pause, session.json
Regista/Recording/Recorder       Registra workspace: devices, screen target, area picker, layout picker, live layout preview
```

- **Session format.** A folder with `screen.mov` (ScreenCaptureKit, native pixels, 60 fps, with or without the system
  cursor — `cursorInVideo`, absent = with —, H.264 or HEVC above 4096 px), `camera.mov` (H.264), `mic.wav`, optional `system.wav`, and `session.json`: `sources[]` (`id`, `file`,
  `offset` = session time of the file's first sample on the **host clock**, device, size/fps/rate, screen `region` in
  global points + `scale`), `events[]` (`click`/`rightClick`/`mouseUp` with screen.mov pixels, `key` with `cmd+s`-style
  names), `cursor[]` at 30 Hz (position, `kind` when not the arrow, `down` while the left button is held), `pauses[]` (informative: the files are continuous, pauses are cut out of every source alike),
  `layout` + `layoutChanges[]` (switches made while recording), `syncMarks[]` (synthetic slates). Times are recorded
  seconds (pauses removed).
- **Sync.** Every source starts at timeline 0: the window is [latest start, earliest end) on whole frames, and each clip
  reads from `sourceIn = origin − offset` — exact ticks, never snapped, so a camera that started 7.5 frames after the
  screen stays 7.5 frames after it (`SessionSync`, unit-tested). Clips of one session share a link (cuts move together).
  `SessionSync.timelineTime` maps a session instant through the clips, so clicks still land right after edits.
- **Layouts are clip properties.** `Placement.box` (the crop fills a `width`×`height` box of the frame, at `x`/`y`) and
  `Clip.mask` (`LayerMask`: rect / rounded / circle, `cutout` = the asset's Vision person matte as alpha, border, shadow),
  plus `settings.background` (the split's dark backdrop). The compositor draws a box as crop → Lanczos → mask → border →
  shadow → native placement, so transform keyframes still move and scale it. Presets (`Layouts.geometry`): bubble
  (0.22/0.30/0.40 of the shorter side, 4.5% margin, white 3 px ring, soft shadow, square crop of 2.7 face heights),
  split (screen contained in 2/3, face card of the same height in 1/3, centred as a pair, 3.5% gaps, rounded 3.5%),
  stack (two halves), face (full frame), cutout (4:5 crop of the upper body standing on the bottom edge, matte steepened
  0.35→0.65, sides feathered over 6%), screen. The face box comes from `faces.track` on the camera (median over the
  range; `recording.import faces: true` runs it); without it a centred upper framing is assumed.
- **layout.apply** cuts the session's clips at the range edges (`Clip.split`, which rebases keyframes — `timeline.cut`
  now uses it too) and writes placement/crop/mask; the camera clip entering a range glides from the previous position
  when the shape is the same (another corner) or pops in (0.3 s, 0.9→1, expo) when it changes; zoom keyframes on the
  screen keep their crop. The layouts applied are listed in `project.state.recordings`.
- **edit.autoZoom** groups clicks closer than easeIn + hold + easeOut + 0.6 s, zooms in onto the first click (ending on
  it), pans to the next ones, holds, zooms out — crop keyframes per screen clip at the clip's own aspect (box or frame),
  inside the clip's resting crop; a move cut by a clip edge is sampled every 1/15 s. `follow: true` makes the resting
  framing a zero-lag smoothed cursor (dense keyframes). When the face covers a large part of the screen (cut-out over a
  9:16 slice) clicks are anchored in the free band beside it and the zoom rises (≤ 2.5×) until a click near the screen
  edge gets out from behind the person.
- **Drawn cursor** (issue #42). Registra records the screen without the system cursor by default («Nascondi il cursore»,
  remembered): `cursorInVideo: false`, and each 30 Hz sample logs the cursor kind (`NSCursor.currentSystem` matched
  pixel by pixel against the standard cursors, arrow otherwise) and the button state, plus a `mouseUp` event per
  release. The import copies `cursorInVideo` onto the recording; `RenderJob` then puts a `CursorOverlay` on every frame
  of that screen asset (`CursorPaths` parses and smooths the session once per file/style) and the compositor draws
  the macOS cursor image of that kind and the click ripples **on the source frame before its crop**, so the zoom
  keyframes move and magnify it with the screen. Defaults (`cursor.style`): scale 1.5, a critically damped spring of
  ω = 40·0.15^smoothing rad/s (smoothing 0.5 ≈ 15 rad/s; 0 = raw path; exact per-step solution at 120 Hz, no
  overshoot), hidden after 2 s without movement (> 0.5 pt between samples) or click, 0.3 s fade, back 0.15 s before it
  moves again, a 0.4 s ring per click (white, or `color`). Old sessions keep their baked-in cursor and draw nothing.
  `Drags.detect` / `RecordingSession.drags`: a press of ≥ 160 ms whose cursor gets farther than 1.5% of the screen
  diagonal from the press point (for the drag-aware zoom). `recording.synthesize cursor: false` writes such a take
  (with a drag at 6.2–7.0 s and the pointing hand over the buttons); scenario `tutorial-cursor` imports it, styles
  it and renders the frames.
- **Calmer camera (issue #43).** `safeZone` (follow only, default 0.6, 0 = the old dense follow): the camera holds while
  the smoothed cursor stays inside that central fraction of the visible frame (the free band when the face covers part
  of it) and moves just enough to bring it back; the path is eased with two 0.3 s moving averages (holds stay exactly
  still) and pulled back so the raw cursor never leaves the frame; collinear keyframes are dropped (the synthetic 9:16
  stack: 226 → 61 keyframes). **Drags** (`DragHold`): each drag of `Drags.detect` keeps the zoom until the release and
  carries the camera along the smoothed drag path (keys every 0.2 s), and click groups are measured from the release.
  Sessions recorded before the mouse-up log fall back to the cursor: a click whose cursor moves away within 0.3 s and
  keeps moving (until it rests 0.15 s) for ≥ 0.16 s over > 1.5% of the diagonal — `drags: false` turns it off. `easing: "spring"` is a critically damped spring (ω·T = 7, normalised to end exactly on the key) on the
  same key times; the default stays `smooth` (easeInOut): on the rendered frames the spring leaves each key at full
  speed, which reads snappier rather than calmer. **Motion blur** (`motionBlur`, default 0.5, stored as
  `Clip.motionBlur` on the screen clips): the layer's crop half a frame before and after gives two scale+shift maps
  (`VideoLayer.cameraBlur`); the compositor averages 3…24 scaled/shifted copies of the drawn crop (one per ~2.5 px of
  smear), before the box mask and placement; smear = speed × shutter, nothing under 0.75 px, capped at 6% × shutter of
  the drawing's width. A still camera costs nothing.
- **Styled frame** (issue #44, idea from Recordly — no code taken): `screen` and `bubble` take `frame: true` or any of
  `background` (`graphite`, `aurum`, `dusk`, `lagoon`, `mist`, `sand` — generated in code, no image assets — `brand`, a
  `#RRGGBB` colour or an image file), `gradient` (2–3 colours, `gradientKind`, `angle`), `padding` (0.06 of the shorter
  side), `radius` (0.016), `shadow` (0.5). The frame lives in the `LayoutSpec` (`frame`), so session.json, the applied
  layouts and old projects (no `frame`) all decode. `layout.apply` writes the screen as a box of its own aspect (never
  cropped) with a rounded `LayerMask` whose `frame: "float"` draws a two-layer soft shadow and a hairline rim, and the
  background as `settings.backdrop` (default: the kit's ink with a glow of its primary, else graphite; `brandkit.apply`
  recolours a default background). When the frame leaves room above or below the screen (4:5, 1:1, 9:16) the bubble
  straddles the screen's edge in its corner and the pair is centred. A layout without a frame over every range removes
  the backdrop. Gradients are computed per pixel with ±1 LSB dither, so they survive H.264 without banding.
- **keys.overlay**: the session's `key` events (`cmd+shift+k`, `k36`) → badges in the macOS order ⌃⌥⇧⌘ (`⇧⌘K`, `↩`,
  `F5`); shortcuts only (⌘/⌃/⌥ or an F-key) unless `allKeys` (then special keys, and typing runs collapsed into one badge
  of the text, ⌫ editing the run); the same shortcut within 0.8 s counts (`⌘Z ×3`). Badges are title clips on a `Tasti`
  overlay track (role `keys`, replaced on every run, `clear` removes it): a dark chip in the kit's ink and paper (Helvetica
  Neue, so the modifier glyphs match), inside the bottom of a boxed screen, else near the bottom edge (above the caption
  band in a tall reel), moved aside when they would touch the camera. Times go through the screen clips
  (`Clip.timelineTime(ofSource:)`: cuts, trims and speed respected); a badge stops at the end of its clip and keys of
  cut-out moments are dropped. Scenario `styled-frame.json` (footage only) checks it with a 4:5 export.
- **9:16 from the same session**: a second project at 1080×1920 and `recording.import` again (a split chosen while
  recording becomes the stack, also in 4:5); export presets of another aspect still reframe by crop, so formats are
  projects (a 1080×1350 project for the 4:5 feed, `export.render preset: "4:5"`).
- **MLT**: boxed layers export as crop + "Size, Position & Rotate" at their resting box; masks, cut-out and the
  backdrop are reported as not exported.
- **Real capture** (`ScreenSession`): an `SCContentFilter` on the display minus Regista's own app (editor, area picker,
  teleprompter, which is also `sharingType = .none`), or a single window, or a display with `sourceRect`; camera frames
  (`AVCaptureVideoDataOutput`) and mic buffers (the same `AudioTap` the teleprompter listens to) converted from the capture
  session's clock to the host clock; each `TrackWriter` starts its file at its first sample, so its offset is exact;
  pause drops samples and shifts later ones back. Clicks and cursor come from `NSEvent` global monitors (no permission),
  keys only with Accessibility. A denied Screen Recording permission throws an Italian explanation of where to allow it.

### `tutorial-synthetic` — the whole path without a human

Screen and camera capture need permissions an unattended session cannot grant, so `recording.synthesize` writes a
session in the real format: an animated desktop (editor + browser windows, session clock, buttons, moving cursor, click
ripples) at 1920×1080 60 fps, 14 s of the WeSites take as `camera.mov` and its sound as `mic.wav`, offsets screen 0 /
camera 0.25 s (7.5 frames: sub-frame on purpose) / mic 0.18 s, 4 clicks, a keystroke, a pause entry and 3 **sync
slates** (2 white screen frames, a +0.45 brightness camera frame and an 80 ms 1 kHz beep at the same session instants).
`recording.check` then measures an export: **sync** (flash frames found in the camera and screen regions, beep onset
by Goertzel; content times camera↔mic and screen↔camera must be within one frame and the flashes on the expected
frames), **faces** (Vision on the export: face centre inside the camera box and within 15% of the box of where the
layout puts the tracked face), **zoom** (at each click the export is closer to the zoomed render than to the unzoomed one,
planned zoom ≥ 1.2), **cutout** (inside the box, where the matte says background the export matches the screen-only
render, where it says person it matches the camera; ≥ 0.9 both).

```bash
regista-engine run Tests/Scenarios/tutorial-synthetic.json            # ~50 s, needs Vision + the WeSites take
regista-engine run Tests/Scenarios/tutorial-synthetic.json --mcp .build/debug/regista-mcp
```


Known gaps: the cut-out is not previewed live while recording (the box is);
layout switches cut the screen with no animation (the face glides or pops); the 9:16 cut-out hides the lower half of
the screen at rest (clicks there are zoomed out from behind the person, the rest is not); clicks on a window that moves
during a window capture are mapped with the window's first position.


## The app (P1-U, issue #2)

```
Editor/EditorStore      owns the Engine: one serial queue for every command (UI and agent), snapshot published on the main actor,
                        activity log, engine socket server, Simple-by-default when the agent edited last
Editor/PreviewController  AVPlayer on PreviewPlayer.makeItem (RegistaEngines): the export's AVMutableComposition + TimelineCompositor,
                        audio clips with their fades as volume ramps; frames pulled by AVPlayerItemVideoOutput, drawn by FrameView
Editor/AppUIHost        UIHost: ui.screenshot (offscreen NSHostingView of the same root view), preview.frame
Editor/Loudness         BS.1770-4 on the timeline mix: momentary / short-term every 100 ms, gated integrated, 4× true peak
Editor/MediaCache       thumbnails (AVAssetImageGenerator, 0.5 s steps) and 48 kHz audio / 10 ms peaks per file
UI/                     Shell (top bar, status bar, shortcuts), ProWorkspace, SimpleWorkspace (Editor/SimpleSteps: the six steps, their
                        states and SimpleCalls), ExportWorkspace, TimelineView,
                        AgentSidebar, LibraryPanel, EditorTheme (palette: neutral darks, Arkad gold only for live/chosen things),
                        Splitter (draggable dividers, ProLayout), Tooltip (.tip)
```

- **Splitters** (`UI/Splitter.swift`): each resizable size is an `@AppStorage` value `layout.pro.library|program|agent|lower`,
  `layout.export.panel`, `layout.record.script`, `layout.studio.deck`; 0 = automatic (the window-relative size the
  workspace computes), double-click stores 0 again. `ProLayout.compute` clamps stored sizes to what the window allows
  (the source monitor keeps 250 pt). Window minimum 1024×640. For screenshots with dragged sizes pass them as launch
  arguments (argument domain, nothing written): `Regista -layout.pro.library 430 -layout.pro.agent 420`.
- **Top bar**: the tabs start after the traffic lights, measured from the window's standard buttons (`WindowChrome`,
  zoom-button edge + 14 pt; 12 pt margin in full screen, followed from `willEnter/willExitFullScreen`); the traffic
  lights are moved onto the bar's middle (`WindowChrome.centreTrafficLights`, re-applied whenever AppKit lays them out).
  Every slot has a fixed width (`WorkspaceTab.width`, `AgentPill.width`, fixed icon buttons), so the bar is the same on
  every screen; the title sits on the window's centre, truncated there, and slides between the clusters only in a
  window too narrow to leave it 160 pt (`TopBarLayout`). Screens, Monta's level and the Graphics section are `Navigation` (UI
  state, no command), remembered in `nav.workspace` / `nav.montaLevel`; the recent projects in `recentProjects`
  (`RecentProjects`, updated after every successful `project.open` / `project.save`, also from MCP).
- **Screenshots of every screen**: `scripts/ui-shots.sh <outdir> [--lang it|en]` renders each `ui.screenshot`
  workspace (home, record, pro, semplice, export, the Graphics sections, …) at 1920×1050 through the engine socket and
  prints the paths; `--lang` relaunches the app in that language for the renders. `--real` instead captures the real
  window as it is on screen, native title bar included (`ui.screenshot {real: true}`: ScreenCaptureKit on the app's own
  window, only with the Screen Recording permission already granted — it never asks), and prints its geometry: window
  and title-row height, the three traffic lights, `contentTop` (must equal the title-row height: one band).
- **Tooltips** (`UI/Tooltip.swift`): `.tip("…", shortcut: "⌘Z")` — a borderless non-activating `NSPanel` (excluded from
  screen capture) placed from the control's screen frame, 350 ms after the pointer enters (instant when moving from
  one tip to the next), hidden on exit, click, scroll or key press. The text is the accessibility label; texts go
  through `Localizable.strings` like the other literals (`scripts/l10n.py` checks `.tip(`, `help:` and `tip:`).
  `ui.screenshot {workspace: "pro-fullscreen"}` renders the top bar as in full screen.

- **Every action is a command.** Buttons, menus and shortcuts call `EditorStore.run` → `Engine.execute`; drags become
  `timeline.move` / `timeline.trim`, the razor `timeline.cut`, transcript deletion `transcript.deleteWords {from, to,
  expect}`, takes `takes.select`, track toggles `track.set`, the pencil `transcript.editText`, the bin `track.delete`. Exception: **solo** is a monitoring state of the preview
  (the model has no solo), not a project edit.
- **ui.screenshot** renders a fresh copy of the editor root (same store, same players) in an offscreen borderless window
  at the requested size and workspace, waits 1.5 s for layout, monitor frames and thumbnails, and writes a 1× PNG with
  `cacheDisplay` — no Screen Recording permission, works with the screen locked, never touches the user's window. The
  result also carries `shown`: the workspace and the timeline lanes with their clip counts (the view model the window
  draws). **preview.frame** waits for the player to be rebuilt from the current project, seeks exactly and returns the
  frame the AVPlayerItemVideoOutput delivers.
- Gates: `scripts/app-check.sh <outdir>` with the app running (`scripts/build-app.sh`): wesites-v1 replayed through
  `regista-mcp` → socket → the app, then `Tests/Scenarios/app-ui.json` (state, UI, screenshots, parity frames), then
  ffmpeg SSIM of each preview frame against frame.render's.


## Analysis engines (P1-A, issue #8)

Free local engines replace OpenAI Whisper and ElevenLabs. Each one is an external process (or an Apple framework)
behind a Swift protocol in `RegistaCore/Engines/Services.swift` (`AudioToolkit`, `Transcriber`, `VoiceCleaner`,
`FaceTracker`), like `MediaProber`: commands only see the protocols and unit tests run on fakes. Results live in the
project: extracted audio paths, the transcript with word timings and the face-track summary on the asset
(`asset.analysis`), the script and the takes on the project; per-frame face boxes go to a sidecar JSON in
`<project>.regista/media/`, next to the generated wavs. Everything the automation changes on the timeline is done with
ordinary commands (`edit.autoCut` and `audio.clean` return the `track.add` / `timeline.delete` / `timeline.place` they
ran), so it is undoable in one step and scenario-testable.

| Engine | Used for | Tier | Where it comes from |
|---|---|---|---|
| ffmpeg / ffprobe (Homebrew) | audio extraction, voice chain, EBU R128 | Base | `/opt/homebrew/bin` |
| whisper.cpp **v1.9.5** (2026-10-06), Metal, static | transcription, DTW word timings | Base | `scripts/build-whisper.sh`: tag tarball sha256 `ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720`, built into `~/Library/Application Support/Regista/engines/whisper.cpp-1.9.5/` (binary sha256 `19212535…7fa5`, `BUILD-INFO.txt`). Not the Homebrew formula: it drags `ggml` + `llama.cpp` + `sdl2-compat` |
| ggml `large-v3-turbo` | whisper.cpp model | Base | `scripts/install.sh` → `<support>/engines/models/` (or a verified copy `engines.json` names), sha256 `1fc70f77…bc69` = the Hugging Face LFS hash of `ggerganov/whisper.cpp` |
| WhisperX (faster-whisper large-v3-turbo + wav2vec2 alignment) | transcription, precise word timings | Medium | `engines/whisperx/` installed by `scripts/install.sh` into `<support>/engines/whisperx/` (the defaults of the Python prototype): `uv run --frozen --project <env> python -I wx_align.py` (8 s chunks, Italian numbers spelled out) |
| DeepFilterNet3 `deep-filter` **v0.5.6** | voice denoise | Base | `scripts/install.sh` → `<support>/engines/deepfilternet/`, sha256 `4601e7f4e4c03e59a4c5b5000216ef3add3e808799cfccd95e14e83ea4611081` (checked by `engines.status`) |
| Apple Vision | face boxes | Base | macOS |

**Config.** Defaults are in `EngineConfig.swift`; any key can be overridden in
`~/Library/Application Support/Regista/engines.json` (or `$REGISTA_ENGINES`), e.g.
`{"whisperModel": "~/models/ggml-large-v3-turbo.bin", "tier": "base", "transcription": {"pro": "whisper.cpp"}}`.
Keys: `ffmpeg`, `ffprobe`, `whisperCpp`, `whisperModel`, `whisperModelSha256`, `whisperThreads`, `uv`,
`whisperXProject`, `whisperXScript`, `deepFilter`, `deepFilterSha256`, `cacheDirectory` (transcripts are cached by
audio hash + engine, default `~/Library/Caches/Regista`), `tier`, `transcription`.

**RAM tiers**, from `ProcessInfo.physicalMemory` at launch (`$REGISTA_TIER` or the config's `tier` override it), with
the thresholds and every engine's tier, size and licence in `scripts/engines.manifest.json` (download facts in
`scripts/engines.lock`; table in [docs/engines.md](docs/engines.md), regenerated by `scripts/engines.py docs` and
checked by the pre-commit hook). `engines.status` reports the tier, every engine's path, availability, checksum and
whether the tier enables it, the manifest's facts per engine, the rest of the manifest under `components`, and the
default transcription engine.

### Benchmark (2026-10-26 raw take, 94.7 s, Italian, M5 Pro 64 GB)

Word timing = `transcript.evaluate`, the Python prototype's `timing_eval.py` metric ported to Swift (word boundary vs the
10 ms energy envelope at the 29 interior pauses ≥ 0.25 s; the port reproduces the Python numbers exactly). Takes =
`takes.compare` of the timeline built by `edit.autoCut` against the hand edit `work/segments.json` (10 lines,
18 comparable boundaries, cut points frame-snapped at 30 fps).

| Engine | Time | Word starts median / p90 | starts ≤ 100 ms | Word ends median / p90 | ends ≤ 100 ms | Same take | Cut error median / max |
|---|---|---|---|---|---|---|---|
| whisper.cpp DTW, end = last token + 0.10 s | 2.8 s | 80 / 212 ms | 69% | 160 / 686 ms | 45% | 10/10 | 31.5 / 1420 ms |
| whisper.cpp DTW, end from the last *spoken* token | 2.8 s | 80 / 212 ms | 69% | 80 / 336 ms | 66% | 10/10 | 31.5 / 1420 ms |
| **whisper.cpp as shipped** (+ end pulled out of ≥ 150 ms of silence) | 2.8 s | 80 / 212 ms | 69% | 70 / 464 ms | 76%¹ | **10/10** | **22 / 87 ms** |
| **WhisperX** (8 s chunks, numbers spelled out) | 39 s (CPU) | **43 / 93 ms** | **97%** | 61 / 159 ms | 72% | **10/10** | **15 / 87 ms** |

¹ The silence clamp reads the same envelope the metric uses, so its end score flatters it; word starts are untouched.
The independent check is the take/cut comparison with the hand edit, where both engines pass (≤ 100 ms) and the
87 ms worst case is the Python prototype's 70 ms plus frame snapping. whisper.cpp's DTW puts the last token before a
pause at the end of the pause ("tuoi" 56.66–58.30 s, voice stops at 56.83 s), hence the two fixes.
Chunking whisper.cpp into 8 s pieces (the WhisperX lesson) did not help it (66% starts) and lost a restart, so it runs
on the whole file with `-mc 0`.

**Defaults:** Base → whisper.cpp (the only engine without Python; it passes the cut gate). Medium/Pro → WhisperX:
same cuts on this take, but word starts within 100 ms 97% vs 69% — what captions (C1) need. One take only: re-check
on the next reel.

**Voice** (`audio.clean`, DeepFilterNet 18 dB + voice.py chain, 11 timeline ranges): −15.0 LUFS integrated, true
peak −2.0 dBTP, LRA 1.8 LU; A/V lag −0.1 ms (0 frames, correlation 0.74) by cross-correlation against the camera
audio. Before normalization the timeline measures −31.9 LUFS / −13.9 dBTP: speech at that level peaks ~18 dB above
its loudness, so a pure linear gain to −15 would clip; a limiter without auto-level follows the static gain
(`mode: "limited"`, loudness corrected once after it). No afftdn, nothing with lookahead: the old 25 ms delay is gone.
The cleaned file is full length and sample-aligned with the source, so `audio.clean` swaps it onto the track's clips
with the same frame-snapped ranges (the old pipeline's 38–72 ms lag came from unsnapped audio cuts).

**Faces** (`faces.track`, Vision, half-resolution decode, ~125 fps): raw take 2841/2841 frames with a face, 0 false
cuts, jitter (RMS of the frame-to-frame second difference of the box centre) 0.72 px smoothed / 3.74 px raw; the hand
roughcut 1493/1493 frames, the 9 crop cuts found (same as MediaPipe), 0.82 px. The box is the extent of Vision's face
landmarks (brow to chin, excludes hair): the detector's own rectangle shakes 11 px RMS. One-Euro `minCutoff` 0.3,
`beta` 0.01 (0.02 gave 0.93 / 1.11 px; the extra lag is ~0.3 px).

### Engine scenarios

```bash
scripts/build-whisper.sh                                            # once: whisper-cli for the Base tier
B=$(swift build --show-bin-path); W=${TMPDIR:-/tmp}/regista-runs
$B/regista-engine run Tests/Scenarios/wesites-autocut.json --work $W/run        # in-process
scripts/scenario.sh Tests/Scenarios/wesites-autocut.json --work $W/run-mcp      # through regista-mcp
REGISTA_TIER=base $B/regista-engine run Tests/Scenarios/wesites-autocut.json    # Base tier: whisper.cpp, no Python
$B/regista-engine run Tests/Scenarios/wesites-faces.json
```

`wesites-autocut` imports the raw take, extracts audio, transcribes, sets `script.md`, lists takes, auto-cuts and
expects 10/10 lines on the hand edit's take with every cut within 100 ms, then cleans the voice and expects
−15 ±0.5 LUFS, true peak ≤ −1.5 dBTP and lag within one frame (also re-measured with `media.measureLoudness`), plus
undo/redo and a save/open round trip. ~25 s warm (cached transcript), ~60 s cold with WhisperX.

## Rendering, captions, export (R1/R2, C1, issues #3 and #5)

**One compositor for everything** (decision 2026-10-14). `RenderJob` (RegistaCore) says what each output frame draws: for
every visible video/overlay track bottom to top, the clip under the playhead, its source time, crop (fitted to the
output aspect), transform and grade, plus the caption state of that frame. In RegistaEngines, `TimelineCompositor` is
a custom `AVVideoCompositing`; its `FrameDrawer` draws with Core Image: source frame → display orientation → crop →
Lanczos scale to fill → transform → `eq` grade → over black, then the caption band. Colour is not managed (working
and output colour space `NSNull`): Y'CbCr → R'G'B' → Y'CbCr unchanged, like an ffmpeg filter graph; the `eq` grade is
ffmpeg's `vf_eq` integer arithmetic on limited-range luma/chroma expressed as one BT.709 colour matrix. `AVRenderer`
turns the timeline into an `AVMutableComposition` (one composition track per visual track) read through an
`AVVideoComposition` using that compositor. **`export.render`** pulls frames with `AVAssetReaderVideoCompositionOutput`
into an `AVAssetWriter`; **`frame.render`** pulls single frames through the very same reader and compositor and writes
PNGs (what Claude looks at is what gets exported). The app's preview will use the same composition (#2). Headless:
works in regista-engine / regista-mcp.

| | |
|---|---|
| Video | H.264 High, yuv420p (BT.709, video range), 30 fps CFR, 14 Mb/s default, keyframe every 2 s, `moov` first (faststart) |
| Audio | the unmuted audio tracks mixed by ffmpeg, sample-exact (`atrim` in samples, `adelay` in samples, clip fades), `alimiter` (no lookahead delay) 0.5 dB under the true-peak ceiling (default −1.5 dBTP), AAC-LC 48 kHz 192 kb/s CBR (Apple encoder) |
| Presets | `9:16` 1080×1920, `1:1` 1080×1080, `16:9` 1920×1080; an aspect other than the clip crop's reframes by crop (largest rectangle of the output aspect inside the crop, same centre). Captions scale with the width, the band keeps its height fraction |
| Speed | the 49 s WeSites reel: 1470 frames in ~6 s (M5 Pro) |

**Captions.** A caption track holds `Captions`: the style, keywords, fixes, the source track and its clip signature
(to tell when the timeline changed: `stale`), and the chunks (words with timeline times and keyword flags).
`captions.generate` builds them from `transcript.timeline` with `CaptionBuilder`, a port of the Python prototype's `captions.py`:
sub-word tokens merged, edge punctuation removed (it marks breaks), uppercase, `fixes` applied (an emptied word passes its
break and end time to the previous one), chunks of ≤ `maxWords` / `maxChars` ending at punctuation, a chunk never ends on a
stop word, a chunk lasts until the next one starts or `hold` after its last word. `numerals` turns spoken numbers back
into digits (WhisperX spells them out for alignment): "nove virgola due" → 9,2, "nove su dieci" → 9 SU 10, numbers ≥ 10
→ 2025 / 11.000, small standalone numbers stay words. Timing is frame-exact from absolute times: a frame at time t shows
the first state with start ≤ t < end (no per-state durations, so no drift). `CaptionRasterizer` draws them natively with
Core Text glyph outlines, as ImageMagick did: plain word = stroke under fill, trimmed to its ink; keyword = white ink on a
box of ink + padding; words side by side centred in the band, each centred by its own height. `export.srt` writes one
cue per chunk.

Style preset **`talking-head-v1`** (the approved WeSites look, reel 2026-10-26): Impact 100 px uppercase, white, black
outline 9 px, keywords white on `#FF2D6F` (padding 18×14), gap 24 px, ≤ 3 words / 17 characters, hold 0.4 s, word-by-word
reveal, band y 1244–1444 on 1080×1920, numerals on. `captions.setStyle` overrides any field (`bandY`, colours, `reveal:
"chunk"`…; chunking fields rebuild the chunks).

**Shotcut project** (`export.mlt`, ported from the Python prototype's `mltlib.py`): the MLT subset Shotcut saves; one chain
per clip with "Crop: Source" and `avfilter.eq`, sound clips with 1-frame fade filters, captions as one full-frame
transparent PNG per caption state (drawn by `CaptionRasterizer`, in `<name>.captions/`) on a "Captions" video track,
upper video tracks blended onto V1. Limits: keyframed crops keep their first crop, fades are 1 frame (Shotcut keyframes
are frames), scale/offset/rotation of full-frame clips are not exported (warnings say so); captions moved or resized
by hand are drawn where they are in their images. Check: `melt <file>.mlt -consumer null`.

## Golden checks (F4, issue #9)

| Command | Measures |
|---|---|
| `media.probe` | duration, frame count, codec/profile, pixel format, colour, fps, audio rate/bit rate, `moov` before `mdat` |
| `media.compare` | ffmpeg SSIM (Y and All) and PSNR on sampled frames vs a reference. `align: "source"` pairs each sampled frame with the reference frame showing the **same source frame** (candidate: the project's video track; reference: its `segments.json`, ffmpeg `trim` frame selection), ≥ 5 frames from any cut in both edits |
| `captions.checkTiming` | for every word, the first frame of the render where it is visibly there — normalized correlation of the frame (caption band, half resolution) with the rendered word under its glyph+outline mask, start of the trailing run above the midpoint within ±6 frames up to the end of its chunk — vs the first frame at or after its timeline start; plus every word box inside the band. A copy shifted by 3 frames reports −3 on every word |
| `media.checkSync` | the render's sound cross-correlated with the camera sound laid out on the timeline (each clip's source working wav), 2 s windows in the middle of the 8 longest clips |
| `media.measureLoudness` / `export.render` result | EBU R128 integrated loudness and true peak of the file |

### `wesites-v1` — the WeSites reel by commands only

`Tests/Scenarios/wesites-v1.json` (requires engines + footage): import → extractAudio → transcript.run → script.set →
takes.list → edit.autoCut → audio.clean → edit.punchIns (base [864,1536,152,384] / punch [760,1351,204,487], by line) →
clip.set grade (eq 0.02 / 1.06 / 1.08) → captions.generate (`work/keywords.json`, talking-head-v1) → export.render 9:16 →
probe, compare with `reel-v1.mp4`, caption timing, sync → frame.render ×5 → export.srt / export.mlt → save, undo/redo.

```bash
B=$(swift build --show-bin-path); W=${TMPDIR:-/tmp}/regista-runs
$B/regista-engine run Tests/Scenarios/wesites-v1.json --work $W/v1-direct      # in-process, ~60 s warm
scripts/scenario.sh Tests/Scenarios/wesites-v1.json --work $W/v1-mcp           # through regista-mcp
```


## Graphics layer (X1/X2, issue #5)

Everything is a clip on a track, drawn by the same compositor as the rest (`frame.render` = export), so moves,
trims, undo and scenarios work on graphics too.

- **Model** (`RegistaCore/Graphics/`): `Clip.placement` (`fill` = crop to fill the frame, the default for video;
  `native` = own pixel size at 1080 wide, centred at x/y fractions; `contain`), `blend` (normal, screen, multiply),
  `title` (a generated clip: no asset), `effects` (keyframable), `gain` (dB); `Keyframe.easing` (linear, easeIn,
  easeOut, easeInOut, expoOut, backOut, hold, spring — the curve towards the next keyframe); `Track.role`
  (`inserts`, `overlays`, `titles`, `music`, `sfx`) and `Track.ducking`; `Project.transitions` and `Project.brand`;
  `MediaAsset.image` (a still or an RGBA PNG sequence, with the union of its visible pixels for layout checks).
- **Overlays** (`overlay.add`): PNG/JPG stills, SVG (rasterized with AppKit at import), PNG sequences (a folder or a
  `%04d` pattern), alpha video (ProRes 4444 / HEVC-alpha / VP9-alpha, detected from the pixel format and decoded once
  to RGBA PNGs: AVFoundation composition tracks drop alpha), full-frame inserts (`fullFrame: true`, own `Inserts`
  track under overlays and titles). Stills and sequences are read from files by the compositor, video through the
  AVFoundation composition. Position: `band` (top y 110–640 / middle / lower), `position` [x, y] or `top` in
  1080×1920 pixels; `scale`, `opacity`, `rotation`; animation presets `pop`, `slideUp`, `slideDown`, `fade`,
  `kenBurns` (written as ordinary keyframes; `clip.keyframe` applies presets or explicit eased keyframes).
- **Titles** (`title.add`, `TitleRasterizer`): Core Text at the output scale — font by role, name or file
  (.ttf/.otf/.woff2 load directly), size, colour, highlighted words, tracking, wrap width, alignment, box or pill
  background, outline, soft shadow; pop in / fade out by default; the result reports the box and layout warnings.
- **Effects** (`effect.add`): `lut` (.cube, mixed by strength), `blur`, `glow` (bloom), `vignette`, `sharpen`,
  `punchZoom`, `shake` (deterministic), `flash`; strength = amount with attack/release ramps or keyframes.
  **Transitions** (`transition.add`): `flash`, `whip` (the picture slides with motion blur, edges smeared), `dip`,
  anchored to a clip edge or a time, applied to the picture under the captions.
- **Brand kits** (`brandkit.list`, `brandkit.apply`, `BrandKit.swift`): see "Brand kits, themes, custom controls" below.
  Title presets: hook, hookLight, question, kicker, card, stat, chipOK, chipWarn, word.
- **Audio**: `audio.addMusic` (music track levelled to −22 LUFS, looped, faded, ducked −12 dB under the voice words:
  raised-cosine ramps, attack 0.15 s, release 0.45 s, pauses < 0.7 s stay down; the envelope is a float wav that the
  ffmpeg mix multiplies with `amultiply`), `audio.duck`, `sfx.library` (the bank shipped in `Resources/SFX`: 185
  sounds made in code by earshot, MIT, rendered by `scripts/sfx-bank.py`; plus your own folder, `sfxLibrary` in
  engines.json), `sfx.add` (by name, volume, sample-accurate, a new SFX track when effects overlap, cut at the end of
  the picture). `export.render {loudness: -15}` re-makes the mix with one static gain before the limiter.
- **External engines** (Medium tier and up, listed by `engines.status`, cached in `~/Library/Caches/Regista/graphics`
  by parameters/content): `graphics.blenderTitle` runs `BlenderTitleScript` (the Python prototype's `title3d.py`, kit colours
  and font, EEVEE 64 samples, 1080×540 RGBA PNGs; 120 frames in 31 s on the M5 Pro) with
  `~/Applications/Blender.app` (5.2.2 LTS); `graphics.hyperframes` runs `npx --yes hyperframes@0.8.150 render
  --format png-sequence` with `npm_config_ignore_scripts=true` (the version is a constant, not configurable; npx is
  found in PATH, fnm or Homebrew). Test composition: `Tests/Fixtures/hyperframes-kicker` (3 s, rendered in 5.7 s).
- **Checks**: `graphics.checkLayout` (every title/overlay box, animations included, frame by frame against the caption
  band 1230–1460 and the Instagram zones), `media.checkOverlay` (decoded frames vs the timeline drawn without the
  clips, luma PSNR: inside the window must differ, the frames around it must match), `audio.checkDucking` (voice and
  music stems through the export mix, loudness inside the speech regions), `sfx.checkOnsets` (the rest of the mix —
  voice, music and any other effect sounding in the window — is subtracted around each effect, then its first 300 ms
  are matched against the residual of the mp4 by normalized cross-correlation over ±80 ms, vDSP; an effect whose best
  match is under `minCorrelation`, default 0.5, counts as undetected and fails the check).
  `timeline.mapTimes` translates times of a reference edit (its segments.json) through the source frames.
- **Shotcut** (`export.mlt`): stills and PNG sequences as `qimage` producers placed with "Size, Position & Rotate"
  (rest state), titles as one transparent PNG each (`<name>.titles/`), inserts as cropped chains, music and SFX with
  "Gain" and the ducking as volume keyframes, fades in frames. Not translated (MLT/Shotcut has no equivalent we
  can write reliably; `export.mlt` lists each one in `warnings`):
  - overlay and title **animations** (pop/slide/fade/kenBurns keyframes): exported at their rest state — Shotcut's
    keyframed "Size, Position & Rotate" exists but its easing curves differ from ours;
  - **effects** (sharpen, blur, glow, vignette, LUT, punchZoom, shake, flash) and **transitions** (flash, whip, dip);
  - **blend modes** (screen, multiply) of overlays (their position, size and rotation are exported: Size, Position &
    Rotate with `transition.fix_rotate_x`, checked with melt against frame.render);
  - **titles** are pictures (one PNG at rest per title), not editable Shotcut text;
  - the export's **loudness correction and final limiter** (the MLT mix plays the clip gains un-limited; re-export
    from Shotcut needs its own normalization);
  - keyframed crops keep their first crop (Shotcut's crop filter is not animatable).

### `wesites-v3` — the reel-v3 graphics by commands

`Tests/Scenarios/wesites-v3.json` (engines + footage; 64 steps): the wesites-v1 edit, then the compose.json times
(inserts, 25 SFX with their volumes, card moments) mapped from the 49.8 s roughcut onto the 49.0 s auto-cut timeline,
`brandkit.apply wesites`, a Blender 3D hook "AGGIORNATO = SICURO?" (top band, 0–4 s), Core Text titles (kicker
"MERCOLEDÌ 21 OTTOBRE", "CVSS 9,2 / 10 · CRITICAL", "TUOI.", the closing "Il tuo sito lavora per te?"), the HyperFrames
chip row, the two AI inserts (grade 1.04/1.05 + sharpen), the ComfyUI music bed ducked, 25 SFX, export 9:16.

```bash
B=$(swift build --show-bin-path); W=${TMPDIR:-/tmp}/regista-runs
$B/regista-engine run Tests/Scenarios/wesites-v3.json --work $W/v3-direct      # in-process (~1 min 45 s warm)
scripts/scenario.sh Tests/Scenarios/wesites-v3.json --work $W/v3-mcp           # through regista-mcp
```


### Text behind the person (X2)

`matte.track {from, to}` segments the camera frames the timeline shows in that window (Apple Vision
`VNGeneratePersonSegmentationRequest`, quality balanced: Apple's on-device model, fine on the Base tier). Frames are
decoded at half resolution, one request and one `VNSequenceRequestHandler` for the run, the display orientation
passed to Vision so masks come out upright (384×512 for the iPhone portrait take); each mask is written as the
[¼ ½ ¼] average with its two neighbours (less edge flicker, no lag) to `<project>.regista/media/<asset>-matte/%06d.png`,
named by source frame. Frames already there are skipped; `asset.analysis.matte` keeps the folder and the tracked
ranges. ~15 fps on the M5 Pro (a 3 s hook in ~6 s).

`behindSubject: true` on `title.add` / `overlay.add` (clip field `behindSubject`; it warns while frames under it have
no matte): the compositor draws the layer, then — wherever the person of the full-frame layer below is — puts back
what was there before (`CIBlendWithMask`). The matte goes through the same crop / Lanczos scale / transform /
keyframes as the camera picture (punch-ins and face reframing follow), then is steepened (0.3 → 0, 0.7 → 1) so the
type does not fade into a halo around the head; a few pixels of anti-aliasing stay. Layers above stay in front; when
the picture under the layer has no matte (a full-frame insert covers the speaker) the layer is simply drawn. Shotcut
export draws it in front (listed in `warnings`).

`graphics.checkBehindSubject {clipId, path?}` renders sample frames with the layer, without it and with it in front,
maps every layer pixel back to the matte: where the person is (matte ≥ 0.9) the frame must equal the render without
the layer, elsewhere (≤ 0.1) the render with it (render: within 9 levels over R+G+B; with `path`, frames decoded from
the mp4 must be closer to the expected render than to the other).

## Moving things by hand (P1-U3, issue #21)

**Model.** `Captions.place` (track) and `CaptionChunk.place` (per chunk) are `CaptionPlace {x, y, scale, align}` on
the style's reference frame: `x` = the line's left edge / centre / right edge (`align`), `y` = the vertical centre of
its band, `scale` multiplies every size of the style; nil fields stay automatic and a chunk's own fields win over the
track's (`Captions.manualPlace(chunk:)`). A chunk with a manual x or y is **pinned**: `CaptionPlacement.place`
(face avoidance) leaves it as it is and never splits it, and `captions.checkFaces` reports a face under it in
`warnings` (`placedOverFaces`) instead of failing. Rebuilds (`captions.generate`, fixes, chunking style fields) carry
each chunk placement to the new chunk starting at the same time (else the one showing then). Clips: `clip.place`
moves the placement centre (keyframes are relative to it, so animations follow), multiplies the rest and keyframe
scales, adds the rotation delta, and stores the clip's placement/transform/keyframes before its first move in
`Clip.placeOrigin` (`reset` restores it exactly).

**Geometry.** `RenderJob.captionBandOrigin(chunk:line:)` is the one place a band lands: automatic chunks keep the old
path bit for bit (style band or face band, `offsetX`); manual ones are anchored, scaled around their centre, clamped
so the line stays in the frame, on whole pixels. `CaptionBands` (RegistaEngines) holds one `CaptionRasterizer` per
chunk scale (band = output width × scale, style band height × scale) and serves the compositor, `captionLayout`,
`captionBands` (new `VideoRenderer` requirement, estimated on hosts without Core Text), the timing templates and the MLT
caption images, so `captions.checkTiming` follows moved and scaled bands. `CanvasLayout.elements(project, at:)`
(RegistaCore) lists what can be grabbed on a frame — titles, stickers, logos, image overlays with their centre,
unrotated size, rotation and box, and the caption chunk showing — from the render plan; full-frame pictures and
callouts are not grabbable. `PreviewMapping` maps view points ↔ frame pixels (aspect-fit, centred), `Snapper` snaps a
box's edges/centre to the frame's centre lines and thirds and to the other elements, `SafeZones.instagram` is the one
definition of the Instagram zones (top 110, bottom from 1540, right 120 px) used by the warnings, the static overlay
and the red drag overlay.

**Commands.** `captions.place {trackId?, chunk | chunks | time | from–to, x, y | dx, dy, units: px|fraction, scale,
align, reset}`, `clip.place {clipId, x, y | dx, dy, units, scale, rotation, reset}` (both clamp and return
Instagram/caption-band warnings), `frame.elements {time}`, and `media.checkPlacement {path, chunk | clipId, time?,
tolerance}`: the element's pixels are where the render with it differs from the render without it; the frame decoded
from the mp4 is matched to the render with it over ±12 px shifts and must also beat the "not there" hypothesis — pass
when the best shift is within the tolerance (4 px).

**App** (`UI/CanvasEditor.swift`). `CanvasOverlay` sits exactly over the picture of `ProgramPicture` (Pro and Simple).
Elements are recomputed per project version and frame (only the visible chunk is laid out); a click hit-tests them
(6 pt margin, rotated boxes in their own frame), a drag snaps and shows guides, corner handles / `MagnifyGesture` /
⌥-scroll (a local scroll monitor) resize, the knob rotates (snaps to 45° within 3°). At selection, `ElementSprites`
renders the element alone through the export compositor and the frame without it (`AVRenderer.renderImages`) in the
background: during a drag the sprite follows the pointer and the clean frame covers the old place. Release → one
`captions.place` / `clip.place` through `EditorStore.run` (one undo step, "Tu" in the Agent log); the dropped picture
stays until the preview plays the new project. Arrow nudges and ⌥-scroll bursts are committed 0.4 s after the last
key/scroll as one command. The floating bar (two rows on the narrow Pro monitor) has the scope, an `RSlider` for the
size and Ripristina; tooltips use `.tip`. `ui.screenshot {canvas: {select, drag?, scale?, scope?}}` draws a
selection or a drag without a mouse (`shown.canvas` = the selection and the hit boxes).

### `caption-place` — moves checked in the exported frames

`Tests/Scenarios/caption-place.json` (engines + footage): 12 s of the WeSites take captioned, the track moved to the
top left (`align: left, x: 60, y: 300`), chunk 2 to `y: 1400` at 1.35×, a boxed title to (700, 1000), the fire sticker
to (250, 700) at 1.5×, export 9:16. `media.checkPlacement` must find every moved element at its
place in the exported frames, and caption timing must stay frame-exact with the placed chunks.


## Effects for users (issue #16)

Everything Claude could do over MCP, now by hand, plus the missing trending effects. All of it is ordinary commands
(undo, agent log, MCP parity); the app's **Studio** (`Sources/Regista/UI/EffectsStudio.swift`) only runs them.

**Looks and adjustments** (`Graphics/Looks.swift`): `Grade` = a look id + amount + `Adjustments` (exposure, brilliance,
highlights, shadows, contrast, saturation, warmth, tint −1…1; sharpness, vignette 0…1) + per-property keyframes, on a clip
or on the project (`Project.grade`: video, inserts and layout boxes; never titles, stickers, logos). Pure colour math on
gamma-encoded R'G'B', baked by the compositor into one 33³ `CIColorCube` per state (cached, quantized so animated grades
reuse cubes); sharpness/vignette are `CISharpenLuminance`/`CIVignetteEffect`. Amount 0 resolves to no grade at all, so it
is pixel-identical to no look. `look.list`, `look.apply`, `adjust.set`.

**Speed** (`Graphics/Speed.swift`, `clip.speed`): constant rate, ramps (rate keyframes over source time, integrated on a
240 Hz grid), reverse (a reversed proxy of the range made with ffmpeg in the project's media folder), freeze frame (cut +
a one-frame clip held + ripple). `Clip.duration` = the retimed length (stored in `Speed.duration`); `Clip.sourceTime(atLocal:)`
and `timelineTime(ofSource:)` map both ways, and the renderer, transcript words, split and trim go through them. Picture:
scaled composition ranges (one per clip, or one per 2 frames for a ramp). Sound: `TimeStretch` (WSOLA driven by the exact
time map, ±2.7 ms alignment, pitch kept) pre-renders stretched clips before the ffmpeg mix — ffmpeg's `atempo` was measured
early by 30–120 ms and drifting; the preview uses AVFoundation's spectral time-pitch. Muted when reversed, frozen or
outside 0.25–4×. Later clips on every track ripple.

**Generated layers** (`Graphics/Stickers.swift`, drawn in `RegistaEngines/FXRasterizer.swift`): `sticker.add` (emoji via
Apple Color Emoji, SF Symbols via AppKit; 22-item library; pop/bounce), `callout.add` (arrow, circle, underline, box,
highlight drawn on with an eased stroke), `progress.add`, `logo.animate` (spin, orbit, pulse, sting with a short glow).
Effect kinds `glitch` (RGB split + seeded block jitter, deterministic per frame) and `chromaKey` (premultiplied RGBA cube:
hue window + spill suppression).

**Beat sync** (`Analysis/Beats.swift`, `edit.beatSync`): 3-band log-energy onset strength every 10 ms → tempo by weighted
autocorrelation (70–180 BPM) → beats by dynamic programming (Ellis 2007), silent ends trimmed → punch-ins, cuts with
alternating framing, or markers every n beats.

**Gallery and styles** (`Commands/StyleCommands.swift`): `effects.catalog` is the gallery's single source (categories,
Italian labels, and for each tile the command + params it runs for a target and an intensity) — the app and Claude read
the same list. `style.apply` (energico, pulito, tutorial) runs a bundle of nested commands in one context: one undo step;
it uses the brand kit's colours through the commands' defaults and reports what it skipped (e.g. tutorial zooms on a
non-recording).

**Previews**: the filter strip is the current frame rendered once by the compositor (`AVRenderer.renderImages`) and graded
per look with the compositor's own LUT code (`GradePreview`); tile animations apply the tile's command to a scratch engine
(`Engine(scratch:services:)`) and render 8 frames (cached per source frame). `ui.screenshot {workspace: "effects-filters" |
"effects-adjust" | "effects-effects" | "effects-styles"}`.

**Shotcut** (`export.mlt`): looks, speed changes (clips play at normal speed for their length), callout draw-ons and the
moving progress bar are listed in `warnings`.

### `effects-gallery` — every effect on the WeSites take

`Tests/Scenarios/effects-gallery.json` (needs only the footage; runs in the pre-commit hook, direct and through MCP): five
linked segments, the WeSites kit, film look 60 % + adjustments, 0.5× / hero ramp / reverse / freeze, glitch, punch-in,
sticker, callout, progress bar, logo sting, whip, punches on beats, the Pulito style (undo/redo as one step), 9:16 export.
`effects.check {path}` renders the frame where each effect is strongest with and without it (quarter size, same
compositor): all 10 visible; a look at intensity 0 vs none: max difference 0; nothing in the caption band; durations
equal their speed; stretched sound against the picture (energy envelopes): slow-mo −15 ms, hero ramp −19 ms (< 1 frame).
`media.checkSync` skips retimed clips and passes on the rest.


## Brand kits, themes, custom controls (issue #17)

**Model** (`Graphics/BrandKit.swift`): colour roles (`primary accent ink paper surface success highlight onHighlight`,
plus free roles such as WeSites' `rose`), font roles (`display text textBold mono`: a font name or a file relative to the
kit folder / absolute / `bundle:Fonts/…`), logo variants `onDark` / `onLight` / `mark` (SVG or PNG), `logoPlacement`
(corner topLeft|topRight|topCenter|bottomLeft|bottomRight, width px at 1080, margin, opacity, animation = an entrance
preset or a #16 logo motion spin|orbit|pulse|sting, variant), `watermark`, caption preset + overrides (colour fields
may name roles; keyword box = `highlight`, its text = `onHighlight`, else white/ink by contrast), title presets, notes.
A font file that is missing falls back to a system font of its role (Georgia, Helvetica Neue, Menlo) and is reported
(`fontReport`, `brandkit.apply.missingFonts`, `brandkit.check.fontFallbacks`). `LogoPlacement.frame` keeps every
corner inside the Instagram safe area and out of the caption band (bottom corners use the 1460–1540 strip and shrink
the logo to fit).

**Storage** (`Graphics/BrandKitStore.swift`): `~/Library/Application Support/Regista/brandkits/<id>/kit.json` +
`assets/` (`$REGISTA_BRANDKITS` overrides the folder; older `<id>.json` files still load). Saving copies outside assets
(bundled logos, fonts by path) into the folder, so a kit folder stands alone; `.registakit` = that folder zipped with
`ditto` (export/import; import refuses paths leaving the folder, renames on id clash unless `replace`). A user kit
with a built-in's id replaces it.

**Built-ins**: Arkad (official SVG logos in `Resources/Brand`, Fraunces/Geist bundled), WeSites (IKB #002FA7, ink
#141414, cream #F7F4EC, vermillon #E8442E, veronese #2E7D5B, rose #F27FA5; keyword pink #FF2D6F = highlight, as the
approved talking-head-v1; fonts from `<brand kits>/wesites/assets` or `$REGISTA_WESITES_ASSETS`, with fallback), Café Atelier (a fictional
bakery-café starter: espresso / oat / caramel, terracotta highlight #D2603A, Georgia + Avenir Next, captions in Avenir
Next Heavy, **placeholder** SVG wordmark).

**Commands**: `brandkit.create {name, from?, colors?, fonts?, …}`, `brandkit.update {kit, …}` (merge; a built-in becomes
a user copy), `brandkit.setLogo {kit, path, variant}`, `brandkit.setFont {kit, path, role}`, `brandkit.export {kit, path}`,
`brandkit.import {path, replace?}`, `brandkit.delete {kit}` — each one undo step: the command records the kit folder
before and after (`KitChange`, `KitSnapshot` in `BrandKitStore.swift`) and `history.undo` / `redo` put it back, with or
without a project open (E4 #3) —, `brandkit.apply {kit}` (recolours captions — their style is kept, #17 —, rebuilds titles
made from presets — `Clip.titlePreset`; hand-styled titles keep their look — and swaps logo clips),
`logo.add {corner?, width?, opacity?, animation?, start?, duration?, replace?}` (track role `logo`, the whole timeline by
default; SVG rasterised at 2× the drawn size), `brandkit.preview {kit | definition, width}` (9:16 PNG through the
compositor: hook title, caption with keyword, logo, over a frame of the open project or a backdrop in the kit's colours),
`brandkit.check {path?}` (rendered keyword box pixels vs the kit highlight, logos inside the safe zone, fonts).
SVGs are normalised before rasterising (root width/height moved into the viewBox: CoreSVG otherwise leaves
userSpaceOnUse gradients unscaled), tested sharp at 64/600/2400 px.

**App** (E4 #3): one place picks the project's kit — the Marca picker, the editor toolbar's "Marca: <kit>" popover
(`BrandPicker`, ⇧⌘B; `ui.screenshot {workspace: "brand-picker"}`). Kits are created and edited only in Settings › Brand
kit (`Settings/BrandKitSettings.swift`, `settings-brand`), through the brandkit.* commands (no view writes kit files).
The logo in the video is a Graphics element (Graphics › Logo: `logo.add`, `LogoPlacementControls`). Previews render
with `BrandKitPreview.render` on their own queue (never behind the agent's commands), cached by kit content.

**Controls** (`UI/Controls.swift`, reusable): `RSlider` (gradient track, value bubble, onCommit at release, ← →),
`RSegmented` (sliding pill), `IntensityBar` (poco ↔ tanto), `RToggle`, `ColorSwatch` (system colour panel via
`ColorPanelBridge`), `ClipPalette` (timeline clip fill/edge by type: footage, voice, music, sfx, caption, title, logo,
insert, overlay), `InspectorSection`, `Accent` (the editor accent: Arkad gold, or the active kit's most readable
colour — contrast ≥ 4.5 on the panels — when *Colore dell'app dal kit* is on; `Ed.gold` reads it). All take keyboard
focus with a visible ring. Export, zoom bar and agent panel use them.

### `brandkits` — three kits on the WeSites take

`Tests/Scenarios/brandkits.json` (`requires: engines, footage`; footage = `$REGISTA_TEST_MEDIA`, default the 2026-10-26
take): 12 s placed, transcribed, captioned with keywords; Arkad, WeSites, Café Atelier applied in turn with a hook title


## Motion templates, the catalog for Claude, 2.5D (issue #22)

**Catalog guidance.** Every item of `effects.catalog` — looks, adjustments, zooms, FX, text and callouts, stickers,
transitions, speed, logo motions, the `styles` category (style.apply) and the motion templates (`templates`) — carries an
English `description` (what it looks like), `useWhen`, `avoid` and `fields` (name, type, example, description, choices).
Built-in guidance lives in `Commands/CatalogGuide.swift`; templates carry their own (`MotionSpec.guide`). `effects.catalog
{brief: true}` lists id + description only; `{item, fields, start, clipId, intensity}` resolves the exact command (field
values override the resolved params; `start`/`end`/`clipId` move the target). A test fails when an item has no guidance,
no fields, a field without an example, or a field that is not a param of its command
(`everyCatalogItemHasGuidanceAndValidFields`, `templatesAreRegisteredWithGuidanceAndForms`).

**`effects.preview {item, fields?, at?, clipId?, intensity?, frames?}`** applies the item to a copy of the command context
(nothing reaches the engine, the project or the undo history), renders it with the export compositor at the moment it
shows best (templates: 70 % into their window) or `frames` 2–12 evenly over its window as one contact sheet, and returns
the image inline (like frame.render) with the command and params that would apply it. The MCP `instructions` and the
`reel-graphics` recipe (step 6, "Which layer when") tell the agent to read the catalog, propose 1–3 fitting items with a
one-line reason, preview on request, then apply.

**2.5D.** `Transform` gained `anchorX/anchorY` (pivot of scale and rotations, fractions of the picture; the picture does
not move at rest), `rotationX/rotationY` (degrees: top away / right away) and `perspective` (camera distance, px at 1080
wide, default 2000). Custom Codable: old project.json decodes with the defaults and default values are not written
(an untouched project saves byte for byte as before). Keyframes interpolate the new fields; `clip.set` / `clip.keyframe`
accept them. `Projection.corners` (RegistaCore) is the one projection: the compositor maps the picture onto the four
corners with `CIPerspectiveTransform` (fill and native layers; flat layers keep the old affine path exactly), layout boxes
use the projected bounds, templates place their sprites with it. `Clip.behindSwitches` (`clip.set behindSwitches:
[{time, behind}]`) moves a layer behind / in front of the person over time.

**Template framework.** A template is one file in `Sources/RegistaEngines/Motion/Templates/` — an enum conforming to
`MotionTemplate` with `static let spec: MotionSpec` (id, Italian tile label, symbol, guide, fields with examples = defaults,
the 3–5 form fields, duration, band, `layering` front/behind/split, `consumesBelow`, `syncField`, `coversFrame`) and
`static func draw(_ c: MotionCanvas) -> CIImage?` — plus one line in `MotionLibrary.templates` (`Motion/MotionKit.swift`).
`EngineServices.live` registers the specs into RegistaCore's `MotionRegistry`, so the catalog, the app gallery, `motion.add`
and MCP read the same list. `motion.add {template, start, duration|end, fields, band, position, sync, behind, trackId}`
validates fields against the spec (types, choices, unknown names), fills defaults, resolves colours/fonts from the brand kit
into `MotionStyle` (roles stay roles: `accent`, `ink`, `paper`…), times a list field to the transcript with `sync: true`
(each entry at its first word inside the clip window), and writes a generated clip (`Clip.motion`) on an overlay track.
Split templates become two `VideoLayer`s (back part behind the matte, front part over it); `consumesBelow` templates get
everything drawn below and replace it (device frame, before/after, video card, chat window, machine). Real edit data:
`MotionData` resolvers fill the fields the caller did not set (receipt, cut-visualizer, sfx-callout, logo-tile,
chat-window: cuts, seconds removed, raw and final durations, the sound effect under the clip, the kit logo).
`MotionCanvas` gives templates cached Core Graphics sprites, brand colours/fonts by role (variable fonts drawn at weight
700 for `textBold`), `place` with the 2.5D projection, photos (aspect fill, rounded), shadows, `dim`, `Inset` (the shot
aspect-filled into a rounded rect), `MockPanels` (generated editor panels), `Anim` (tame spring, envelope, damped swing)
and `Draw` (text, cards, console panels, SF Symbols, check marks). Not exported to Shotcut as animation (one still at
mid-clip, listed in `export.mlt` warnings). `effects.check` checks every template visible at 35/60/85 % of its clip and
none of its ink in the caption band (except `coversFrame` templates).

| Template | What |
|---|---|
| orbit-carousel | photo cards orbiting the head; far side behind the matte (split) |
| checklist | iOS card, ticks one by one or on the words (sync), light/dark, row accessories |
| counter | number / clock rolling to its value, SF Symbol, dimmed shot |
| swing-tag | paper tag on a string from the top edge, damped swing around its top anchor |
| marquee | numbered pill rows scrolling, each row behind or in front |
| device-frame | the shot zooms out into an iPhone and back (consumes below) |
| card-stack | tilted floating windows behind the speaker (screenshots or MockPanels) |
| hud-frame | viewfinder corners, typed mono labels, timecode, frame counter |
| chart | bar, line, donut, big number on a card |
| kicker-headline | kicker + huge word, or mixed sans + *serif italic* accent words; behind: true |
| annotation-chip | dot pill with a leader line |
| background-scene | dark glow + gliding grid floor, white canvas, paper, gradient |
| stat-card | counting number + mini chart beside the head |
| before-after | BEFORE (flattened shot or image) / AFTER (the shot) frames on a dark stage |
| scatter-wall | many tilted screenshots behind the head |
| mock-ui | one animated editor panel (timeline, wheels, curve, waveform, fx, sliders, number) |
| gallery-card | glass card, status badge, 2–4 thumbnails |
| thumbnail-ring | 3D ring of thumbnails around a word |
| script-card | document lines highlighted with the speech (sync) |
| bento-grid | dark panel of numbered step tiles filling in turn |
| card-row | numbered step cards under a mixed headline |
| video-card | the shot as a player card with a moving scrubber |
| prompt-bar | a prompt typing itself, send button lighting up |
| timeline-milestones | months axis with growing thumbnails |
| stacked-pages | fanned screenshot stacks with numbered labels |
| progress-rows | console rows with bars and status lights |
| sfx-callout | speaker in pulsing rings + waveform with the SFX block (the real sound effect) |
| cursor | pointer gliding along stops with click ripples |
| chat-window | console "new message" with the real clip attached and its duration |
| cut-visualizer | the raw take's removed parts flash red and collapse; raw → final counter (real cuts) |
| play-card | generic video-platform card, no third-party logo |
| receipt | receipt printing out of a slot with the edit's real numbers |
| machine | hopper, preview window, gears, status rows, conveyor with checked outputs |
| logo-tile | the kit logo in an app-icon tile with a glow |

**App.** The Graphics panel has a **Motion** section (category `templates`): rows with animated previews (they run
`motion.add` on a scratch engine), a click opens the template's form (`UI/MotionForm.swift`: text, lists, numbers, choices,
toggles, an image picker) and Applica adds it at the playhead.

### `motion-gallery` — every template on a synthetic speaker

`Tests/Scenarios/motion-gallery.json` (no engines, no footage: in the pre-commit hook, direct and through MCP):
`media.synthesize` writes a synthetic talking head (a speaker silhouette that sways and nods on a wall) with its exact
person matte attached, so split/behind templates are tested without Vision; the Arkad kit; every template in its own 3 s
window (`motion.add`, no warnings); the catalog lists them all; `effects.preview` renders one without touching the edit or
the history (undo/redo still land on the last motion.add); `effects.check` passes (every template visible at three moments,
nothing in the caption band); 9:16 export. A test fails when a registered template is missing from the scenario.


Not done here: full-screen 3D scenes (HyperFrames) — follow-up; a `typewriter` text preset for `title.add` (title
animations are transform keyframes; text reveal does not fit them cleanly — `prompt-bar` types instead); device-frame and
`layout.speaker inset-frame` use separate inset code.

## Looks: caption styles, speaker layouts, hands, HUD (issue #22, rounds 2–3)

From a round of reference ads. Every item is in `effects.catalog` with an
English description / useWhen / avoid and example fields (`Commands/LooksCatalog.swift`; categories `captions` and
`layouts`, plus `transition-blur`, `follow-hand-object`, `follow-face`, `status-bar`, `audio-meters`, `style-console`),
so Claude can propose and apply them; the app shows the same items (Graphics › Effects, categories Sottotitoli / Layout, the
caption style chips in Testi, the Console card in Graphics › Stili).

```
RegistaCore/Captions/Captions.swift       CaptionStyle presets elegant-serif, bold-keyword, ghost-karaoke (+ the optional style fields)
RegistaEngines/CaptionRasterizer          fill-only words, accent keywords without a box, ghosted words, shadow, balanced wrap, baseline
RegistaCore/Graphics/SpeakerLayouts       SpeakerLayout geometry (letterbox-headline, split-card, pip-bubble, inset-frame, full)
Commands/LayoutSpeakerCommands            layout.speaker            RegistaEngines/LayerShapes  card frames (neon, glass, plain, chips)
RegistaCore/Analysis/HandTrack            HandTrack, HandTracker protocol, FollowPath (source point → output, One-Euro)
RegistaEngines/VisionHandTracker          VNDetectHumanHandPoseRequest  Commands/FollowCommands  hands.track, clip.follow
Commands/HUDCommands                      status.add, meters.add    RegistaEngines/HUDRasterizer  halo, status row, level meters
```

- **Caption styles.** New optional `CaptionStyle` fields (nil = the old behaviour, old projects decode unchanged):
  `keywordMode` (`color`: the keyword drawn in `keywordBoxColor`, no box — brand kits recolour it as the highlight),
  `upcomingOpacity` (ghost karaoke: the whole chunk from its first word, unspoken words at that opacity),
  `shadowOpacity/Blur/Y`, `maxLineWidth` (two lines are balanced: the break that makes the longer line shortest),
  `lineSpacing`, `wordAlign: baseline` (mixed case with descenders). `captions.setStyle` sets them (null clears).
  `elegant-serif`: Didot Italic 82, cream #F6EEDF, gold keywords, whole phrase, ≤ 5 words. `bold-keyword`: Avenir Next
  Bold 86, white, accent keyword #FF8A3D, ≤ 2 lines of 860 px, whole phrase. `ghost-karaoke`: Avenir Next DemiBold 66,
  upcoming words at 28 %, word by word. Keywords now match in any case (a list typed in capitals still works on the
  mixed-case styles). Face placement and `captions.checkFaces` count every word of a whole-chunk or ghosted style
  from the chunk's start. `captions.checkTiming` scores styles without an outline (flat fill: no pattern for NCC) and
  ghosted words (already there, dim) by glyph contrast — mean luma of the glyph pixels minus the rest of the word box —
  instead of NCC; checking a project against another style's export fails (6/24 and 3/24 words found).
- **Blur transition** (`transition.add kind: blur`, 0.6 s): Gaussian defocus up to 44 px at 1080 wide on the cut,
  eased in and out (`FrameFX.defocus`).
- **layout.speaker** cuts the main video at the range edges (linked sound follows) and writes `Placement.box`, a crop
  around the face (median of `faces.track` over the clip; untracked: the face assumed mid-frame) and a `LayerMask`;
  keyframes in the range are replaced (warned). `settings.background` is the project's frame background (one for the
  reel: the last layout sets it). letterbox-headline: 1080×608 band centred at y 864, headline title at y ≈ 445 (52 px,
  white); split-card: 46 % wide 4:5 card, 6 % margin, light canvas, `freeArea` returned; pip-bubble: the speaker stays
  full frame below (captions and the transcript read it), a copy goes into a circle on a new top track (`pipTrack`),
  clear of the Instagram rail and above the caption band, `brollAssetId` fills the frame under it; inset-frame: a card
  at the frame's aspect (50 % wide, top at y 240), zooming from full frame in 0.5 s (expo) and back out at the end —
  the card's frame decorations fade out while it is zoomed up. Captions that matched the timeline are rebuilt and
  placed again afterwards. The motion template `device-frame` insets the picture with its own mechanism (`Inset`,
  a consuming template); bringing both onto one is a follow-up.
- **Hands.** `hands.track {assetId, from, to}` runs Vision hand pose on every frame of a source range (half
  resolution, ~110 frames/s here): palm (wrist + 4 knuckles), wrist, index tip, joint box, `open` 0…1 (fingertip reach
  over palm length), chirality; sidecar `<asset>-hands.json`, summary in `asset.analysis.hands`. `clip.follow {clipId,
  target: face|hand}` samples every frame of the follower's window, maps the tracked point through the layer that shows
  the asset (full frame or a layout box), smooths it (One-Euro, gaps ≤ 0.25 s held) and writes keyframes every 2
  frames over the clip's own animation (kept in `placeOrigin`, so re-running replaces and `clip.place reset` undoes it);
  `openOnly` fades the object in/out with the open palm, `hover` lifts it with a ±6 px float, `spin` turns it in depth
  (`rotationY` of the 2.5D transform), `halo` adds a `halo` shape on a track under it following the palm.
- **HUD.** `status.add` (shape `statusBar`: REC dot pulsing at 1 Hz, label, timer = timerStart + t × timerRate,
  numbered chapters sliding in over 0.3 s; left of the Instagram rail) and `meters.add` (shape `audioMeters`: the
  unmuted audio tracks mixed at 24 kHz, RMS ×2 and peak per channel every 1/30 s on −48…0 dBFS, 30 segments, peak
  hold over 0.8 s; beside the speaker's card when one is on screen). Both are drawn every frame from the clip time
  (`ShapeLayer.isLive`).
- **Console theme** (`style.apply {style: "console", chapters}`): neon inset-frame on the main video, dark backdrop,
  status row with an 8× session clock and the chapters, bold-keyword captions in the kit accent, and the grid + glow
  backdrop: the motion template `background-scene` (dark-grid, kit accent) on an overlay track under the speaker — one
  undo step. A host without the motion templates (RegistaCore alone) skips the backdrop and says so.

### `looks-layouts` and `looks` scenarios

`looks-layouts` (footage only, in the pre-commit hook): the four layouts on 12 s of the WeSites take, status row with
three chapters, meters over the inset, a blur at 6 s, then the console theme on a second project — boxes where the
geometry says, every headline/HUD shape/blur visible in its window (`effects.check`), the bubble exactly over its
window in the export (`media.checkOverlay`, < 34 dB inside, > 30 dB outside), one undo step per layout and for the
theme (27 steps, 29 checks). `looks` (engines + footage, by hand, ~35 s): the WeSites take in elegant-serif,
bold-keyword and ghost-karaoke — `captions.checkTiming` 24/24 words exact (max error 0 frames) and
`captions.checkFaces` pass for each; letterbox-headline on the tracked face; then a French test take (`REGISTA_HANDS_MEDIA`) 52–59 s:
`hands.track`, a sparkle held over the palm with hover, 3D spin and halo, `media.checkPlacement` in the export within
8 px and `effects.check` visible (33 steps, 27 checks). Contact sheets land in the work folder. Known limits: none of
the test takes has a palm-up "presenting" gesture — the follower sits on a hand on the chin (and, on another take, on a
child's open hand, which Vision ranks as the most open); `open` is a reach ratio, not palm orientation.

## Generated media (issue #11)

A **provider** (`GeneratorProvider`, `RegistaCore/Generation/`) turns a request — `kind` (image, video, music;
upscale internally), prompt, reference files, duration, size, seed, model, provider flags — into one file through a
separate process. The job folder `~/Library/Caches/Regista/generate/<provider>-<hash>/` (request.json, stdout, stderr,
`exit`, the result, output.json) is keyed by the request with every reference replaced by the SHA-256 of its content,
so the same request never runs (or costs) twice; the default seed is derived from the prompt for the same reason. The
result is copied to `<project>.regista/media/generated/` and imported as an asset with `generated` = provider, model,
kind, prompt, seed, cost, unit, created, job, source asset, remote id. Then it is ordinary media:
`overlay.add {path, fullFrame: true}` for B-roll, `audio.addMusic {path}` for a bed.

| Command | |
|---|---|
| `generate.providers` | providers, models, availability per kind (tier and tools), budget left |
| `generate.estimate` | credits (Higgsfield CLI `generate cost`, free) or free; cached?; for a paid provider it records a pending approval |
| `generate.approve` | **human only**: approve / decline a pending estimate → single-use token (2 h, this exact request) |
| `generate.run` | run (waits by default; `wait: false` = background job) or reuse; paid providers need `approval` |
| `generate.upscale` | ComfyUI Real-ESRGAN x4plus + RIFE 4.26: 464×832 32 fps → 1080×1920 30 fps, same duration |
| `generate.status` | jobs; collects a finished background job into the bin |
| `generate.list` | generated assets with metadata, jobs, budget, recent approvals (tokens of approved ones) |

**ComfyUI** (free, **Pro tier**, in `engines.status`): `comfy-gen image` (Z-Image Turbo, default 720×1280),
`comfy-gen video` (Wan 2.2 I2V 14B lightning from a start frame = `refs[0]`, 1–5 s at 464×832), the
`comfy_run.py music` runner (ACE-Step 1.5, FLAC) and `upscale`. Paths in engines.json: `comfyGen`, `comfyRun`, `python3`.
ComfyUI is stopped after every waited-for run (`comfy-gen stop`) unless `keepRunning: true` (chains).
Typical times on an M5 Pro: still 84 s cold, a 3 s clip ~5 min, upscale 7 min.

**Higgsfield** (paid): `higgsfield generate cost|create … --wait --json` (CLI found in PATH, fnm, ~/.local/bin, Homebrew;
`higgsfield` in engines.json). Defaults: `z_image` for stills (0.15 credits), `seedance1_5` for clips (480p 4 s: estimate
2.4 credits). Regista never logs in: an expired session comes back as "the human runs `higgsfield auth login`".

**Approval and the hard budget.** A paid `generate.run` needs `approval` = a token from `generate.approve` for the
same request hash (prompt, model, refs by content, params) and a cost not above the approved estimate; tokens are
single-use and expire after 2 h. `generate.approve` is human-only (see "Human-only commands"): the app shows a
confirmation sheet (prompt, model, kind, credits, calls left — "Approva e spendi N crediti") whenever an estimate is
pending (also at launch, for one left while the app was closed); from a terminal the owner runs
`regista-engine exec generate.approve '{"estimateId": "e-…"}'`. The agent reads
the token from `generate.list`. `~/Library/Application Support/Regista/budget.json` counts paid calls: **at most 2
Higgsfield calls in total** — the cap is a constant in code (`GenerationBudget.hardCaps`), the file
can lower it but never raise it, every call is counted *before* it starts, and at 0 every paid run fails with "budget
exhausted … use ComfyUI". A finished paid job whose result cannot be read is never re-run automatically.
`approvals.json` next to it holds the estimates and tokens.


### `wesites-generate` — generated B-roll and text behind the person

`Tests/Scenarios/wesites-generate.json` (engines + footage + ComfyUI; 29 steps): the wesites-v1 edit, then a ComfyUI
still → 3 s Wan clip from it → upscale, placed full-frame on "il motore sotto ogni sito WordPress" (8.37–10.17 s);
`matte.track` 0–3 s and the hook word "SICURO?" (IKB serif, 180 px, top band) behind the head; export.

```bash
B=$(swift build --show-bin-path); W=${TMPDIR:-/tmp}/regista-runs
$B/regista-engine run Tests/Scenarios/wesites-generate.json --work $W/generate-direct   # ~1 min with cached generations
scripts/scenario.sh Tests/Scenarios/wesites-generate.json --work $W/generate-mcp        # through regista-mcp
```


## G0 — Claude edits the reel by itself (issue #10)

`scripts/g0.sh <raw.mov> <script.md> <outdir>` runs the golden test: it clones the take and the script into a fresh media
root `<outdir>/media/`, writes `<outdir>/mcp.json` (the release `regista-mcp` from `scripts/build-mcp.sh`, `--media-root
<outdir>/media --output-dir <outdir>/work`), and starts a headless Claude Code session in `<outdir>/work` that has **only**
the regista tools: `--strict-mcp-config --tools "" --allowedTools mcp__regista --permission-mode dontAsk`, built-in tools
also in `--disallowedTools`, `--setting-sources project,local` (no user hooks, plugins or CLAUDE.md),
`--disable-slash-commands`, model `opus` / effort `high` (`--model`, `--effort`, `--max-budget-usd`). The task is a fixed
request in Italian (`<outdir>/task.txt`); the stream goes to `<outdir>/session.jsonl`.

Afterwards it runs the golden checks with `regista-engine exec` on the last exported mp4 and the saved project: duration
(35–70 s, = timeline), format, `media.compare` source-aligned vs `reel-v1.mp4` (SSIM ≥ 0.90), `takes.compare` vs the hand
edit's `segments.json`, `captions.checkTiming`, `media.checkSync`, loudness (ffmpeg EBU R128), the agent's keywords and
fixes vs `keywords.json` — and writes `<outdir>/g0-report.md` (tools called with counts and order, errors, takes, keywords,
the numbers, the session's final message; raw JSON in `<outdir>/checks/`). `--checks-only` re-runs checks and report on
an existing `<outdir>`; `--smoke` asks the session only to list tools and files and look at one contact sheet (~20 s).

```bash
D=$REGISTA_GOLDEN_MEDIA
scripts/g0.sh $D/raw/take.mov $D/script.md ${TMPDIR:-/tmp}/regista-runs/g0-run-1
```

## Real footage: languages, faces, script-less edits (issue #13)

The first takes outside the golden WeSites selfie (`IMG_3531`, a French Arkad spot with a quieter second
voice and no script; `IMG_3532`, a handheld French take of a speaker holding a small child) showed four gaps, now closed.

**Caption language** (`Sources/RegistaCore/Captions/Language.swift`). `LanguageProfile` (it, fr, en, pt) is chosen from
the transcript language (or `style.language`):
- *stop words* a chunk never ends on — French articles, prepositions, conjunctions, determiners and clitics (le la les
  des de du à au aux et ou en un une ce cette mon ma mes… je tu il qui que ne se…), the Italian list of the approved
  style, English and Portuguese equivalents. A chunk still ending on one gives it to the next chunk, else takes the
  next chunk's first word, else spills — lines stay ≤ maxChars + 4. `captions.generate` / `captions.get` report
  `language` and `stopWordEnds` (must be empty). A sentence end (punctuation, or a pause) may end on any word;
- *numerals*: spelled numbers become digits with the language's formatting — FR "dix ans" → 10, "neuf virgule deux sur
  dix" → 9,2 sur 10, "deux mille vingt-cinq" → 2025, "onze mille" → 11 000 (no-break space), "vingt pour cent" →
  20 %; small standalone numbers stay words ("trois petits enfants");
- *elisions* (l', d', qu', j', c') stay glued to the next word, also when the transcriber split them;
- *sentence pauses*: a source pause ends a caption sentence when the transcript has no punctuation there — 0.6 s for an
  unpunctuated transcript, 1 s otherwise (take joins: "…RÉPÉTITIVES | DES OUTILS…", "ET SI | VOUS ÊTES…").
`TextNorm.numbersToWords(_:language:)` and `engines/whisperx/textnorm.py` spell French numbers for matching and for the
WhisperX aligner. The French aligner is pinned in `scripts/engines.lock` (`wav2vec2-voxpopuli-fr`, torchaudio
`VOXPOPULI_ASR_BASE_10K_FR`, 2021-10-15, SHA256 checked), installed next to the Italian one and checked by doctor.

**Face-aware crops for any speaker** (`FaceFraming.swift`). `faces.track` now keeps every face of a frame (`others`:
a child in the arms, a second person). `edit.punchIns` with no crops derives them per shot from the face track: every
head (hair to chin, as far as the shot shows it) inside the crop with 5% headroom; the zoom asked for (`zoom`, default
base 0.8 / punch 0.7 of the largest crop) is eased when the main head is big (≤ 60% / 66% of the crop height, so a
close selfie is not pushed into the face); one static crop when it can hold the whole shot, else a path smoothed over
0.6 s, speed-limited, keyframed wherever the interpolation would cut a head. Stray detections (a face seen in a few
frames) are ignored. The old fixed crops are preset `wesites-selfie`; `base`/`punch` and `mode: "face"` still work.
`faces.checkFraming` fails when any head is cut on a sampled frame.

**Captions avoid all faces** (`CaptionPlacement.swift`). After chunking, each chunk's words are checked against the
caption zone of every face on every frame they show (from the frame each word appears, word-by-word reveal); the zone
covers hair, eyes, nose and mouth — the chin may stay under the band, as in the approved look. A chunk that touches a
face moves to the nearest clear band inside the Instagram safe zones (1290–1380 below, then up to 200), centred, then
shifted beside the face; if nothing is clear it is split in two (never leaving a stop word at the end) and each half
is placed again. Chunks carry `bandY` / `offsetX`; the compositor, the MLT caption images and `captions.checkTiming`
honour them. `captions.checkFaces` fails on any overlap. `captions.generate {avoidFaces: false}` turns it off.

**Script-less edits** (`ScriptFromTranscript.swift`). `script.fromTranscript` builds the script from the transcript:
sentences from punctuation, pauses (0.6 s without punctuation, 1 s with) and a capitalised word after a short pause;
repeated readings (a restart, a second take, a false start) within the last three lines fold into one line whose text
is the last full reading, so `takes.list` finds them as takes and `edit.autoCut` keeps the best. Each line reports its
readings and `relativeDB` (its loudness against the take's speech: far below 0 = an off-mic voice). Use `dryRun: true`,
read the lines, then `drop: [line numbers]` for chatter that is not part of the video.

**Second voice level** (`LevelMatch.swift`, in `audio.clean`). After DeepFilterNet and the per-take gains (each take
to −30 LUFS, as before), speech is cut into segments at 0.25 s silences; a segment more than `levelMatch` dB (default
6) from the main speaker (duration-weighted median) is gained toward it, at most `levelMatchMax` dB (default 12 —
raising further lifts the room as much as the voice), with 30 ms ramps in the silence around it. One per-sample gain
curve, so sync is untouched. The result lists `levelMatch.mainDB` and the gained segments. On the two French takes the
off-mic lines are whole takes, already matched by the per-take gain; the segment match catches a second voice inside
a take.

### `fr-arkad-3531` and `fr-handheld-3532` — real French footage, no script

`Tests/Scenarios/fr-*.json` (`requires: engines, footage`): import → whisper.cpp French transcript →
`script.fromTranscript` (3531 drops four off-script lines) → takes → auto cut → `audio.clean` → `faces.track` →
`edit.punchIns {by: "line"}` → `faces.checkFraming` (every frame) → grade → `captions.generate` (stopWordEnds empty) →
`captions.checkFaces` → export → `captions.checkTiming` → `media.checkSync` → contact sheet. Footage from
`$REGISTA_TEST_MEDIA_DIR` (default `~/Movies/Regista`); everything is written in the scenario's work folder.

## Test media

Scenarios name their footage through variables with overridable `defaults` (`REGISTA_GOLDEN_MEDIA`, the folder of
the WeSites test take, default `~/.config/regista/test-media/wesites-2026-10-26`; `REGISTA_TEST_MEDIA`, its raw take;
`REGISTA_TEST_MEDIA_DIR`, the French takes, default `~/Movies/Regista`; `REGISTA_SFX_LIBRARY`, `REGISTA_COMFY_RUN`).
The footage is not in the repository: a clone without it prints `skipped (footage missing …)` and passes. Code
defaults never name a personal folder: `EngineConfig` defaults are where `scripts/install.sh` puts the engines, and a
different setup goes in `engines.json`.
