# Regista — AI video editing for the Mac

Regista is a macOS video editor that **Claude drives through MCP**. You record (with a teleprompter that follows your
voice), ask Claude to edit, and watch every step live in the editor: takes chosen, cuts, clean voice, captions,
graphics, music, export. Then you touch it up by hand — every button is the same command Claude uses, and everything
can be undone.

Everything runs on your Mac with free, local engines (whisper.cpp / WhisperX, DeepFilterNet, Apple Vision, ffmpeg,
optionally VoxCPM2, Blender, HyperFrames and ComfyUI). No API key and no cloud service are needed to edit.

- **Record** — the Mac's camera, a webcam or an iPhone (Continuity Camera), with a teleprompter near the webcam that
  is hidden from screen capture and marks a new take when you restart a sentence.
- **Tutorials** — record the screen (all of it, a window or an area) with camera and microphone, each in its own
  synchronised file; the face goes where you want (bubble, side by side, vertical, cut out over the screen) and the
  screen zooms on clicks by itself.
- **Edit** — two levels of the same project: **Pro** (monitors, track timeline, inspector) and **Simple** (big preview
  and big buttons, to review Claude's work). Effects, looks, motion templates, brand kits, sound effects and music.
- **Export** — 9:16 reels (or 4:5, 1:1, 16:9) with the same compositor as the preview, `.srt` captions and a Shotcut
  project.

Built with SwiftUI and SwiftPM (Swift 6). The Apple Command Line Tools are enough: Xcode is not needed.

## Requirements

- A Mac with Apple silicon (M1 or later) and **macOS 15** or later.
- The Apple Command Line Tools: `xcode-select --install` (once; wait for Apple's installer to finish).
- **Claude Desktop** (https://claude.ai/download) or **Claude Code** (https://claude.com/claude-code), signed in.
- **Homebrew** (https://brew.sh) — or let the installer set it up: in an interactive Terminal it offers to run the
  official Homebrew installer, pinned to a reviewed commit and checked with SHA256 (Homebrew may ask for the Mac's
  administrator password; the rest of the installation runs as your normal user, never with sudo).

## Install

One command in Terminal:

```bash
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

The installer checks the Mac, downloads the engines for its memory tier (every file has a fixed version and a
verified SHA256), builds the app locally (no Gatekeeper prompts), puts it in **Applications** and connects Regista
to Claude Desktop and/or Claude Code — whichever is installed (`--claude desktop|code|both|none` to choose). At the
end it prints a summary: what it found, what is missing, how to start. Allow 10–20 minutes the first time.

After installing, **quit Claude Desktop completely (⌘Q) and reopen it** so it loads the Regista connection.

**Update**: run the installer again — it pulls the latest version and rebuilds; your projects, settings and voice
stay as they are. If you changed tracked files in the clone, it keeps them and skips the update.

```bash
~/code/regista/scripts/install.sh
```

**If something is wrong**: `~/code/regista/scripts/doctor.sh` checks the whole installation again and says how to fix
each problem.

**Without Git**: `scripts/package.sh` (from a clean commit) makes a ZIP of the sources with a double-click installer,
`INSTALLA.command`; the guides in [`handoff/`](handoff/) explain it in French and Portuguese. It is a source
distribution that builds on the Mac, not a prebuilt app.

## Connect Claude

The installer registers Regista's MCP server for Claude Code (`claude mcp add --scope user regista`) and adds a
`regista` entry to Claude Desktop's `claude_desktop_config.json` (keeping everything else, with a backup first).

Open Regista, then in Claude write for example:

> *Edit this video: ~/Movies/Regista/Registrazioni/take.mov with the script script.md*

or, without a script: *"edit this French video, there is no script"*. With the app open, Claude works in the app and
you see each step live; with the app closed it works headless and saves the project for later.

For Claude Desktop, [`handoff/START-PROMPT.md`](handoff/START-PROMPT.md) is a ready-made set of Project instructions,
and [`handoff/skill/regista`](handoff/skill/regista/SKILL.md) is a skill for Claude Code (the installer adds it).

## What Claude can make: the recipes

Claude starts every job with `recipe_get`, which returns a step-by-step recipe with the house rules (caption style,
pacing, loudness, safe zones):

| Recipe | For |
|---|---|
| `talking-head-reel` | You speak to camera: takes chosen from the script (or a script built from the transcript), cuts, voice cleaned to −15 LUFS, face-aware punch-ins, captions with keywords, 9:16 export. |
| `screen-tutorial` | A screen recording made in Regista: layouts for the face, zoom on clicks, a calmer camera, keys, chapters. |
| `voice-over-video` | Nobody on screen: your cloned voice over images, captures and animations. |
| `reel-graphics` | Titles, cards, inserts, motion templates, sound effects and music on a finished edit. |

Every effect, look, caption style and motion template is listed by `effects_catalog` with what it looks like, when
to use it and when not to, so Claude can propose a few, preview one and apply it.

## Tiers by memory

The installer detects the tier from the Mac's RAM (`--tier base|medium|pro` forces one):

- **Base** (8 GB) records, cuts, captions, cleans the voice, adds graphics and exports — the full reel, no Python.
- **Medium** (16 GB) adds more precise word timings (WhisperX) and voice-over in your own cloned voice (VoxCPM2);
  Blender (3D titles) is offered.
- **Pro** (32 GB and more) adds training your voice and locally generated images, clips and music (ComfyUI, set up by
  hand: the installer prints the steps).

Shotcut is offered on every tier. Every engine with the RAM, disk and licence it needs and how it is installed:
[docs/engines.md](docs/engines.md).

## Languages

- **Interface**: Italian, English and French, following the macOS language (Portuguese is in progress).
- **Captions, teleprompter and transcription**: Italian, French, English and Portuguese.
- **Installer messages**: all four.

## Documentation

- [docs/user-guide.md](docs/user-guide.md) — the editor, moving captions and graphics, effects, brand kits, the
  teleprompter, tutorials, your own voice, shortcuts.
- [docs/architecture.md](docs/architecture.md) — how it is built: the command engine, the MCP server, the installer,
  rendering, captions, graphics, analysis engines, tests.
- [docs/engines.md](docs/engines.md) — the engines by tier (generated from `scripts/engines.manifest.json`).
- [LICENSES.md](LICENSES.md) — third-party engines, models, fonts and sound effects.

### Development

```bash
scripts/build-app.sh            # build and open build.noindex/Regista.app (and the matching regista-mcp)
scripts/test.sh                 # unit tests
git config core.hooksPath .githooks   # once per clone: the pre-commit gate (tests + scenarios)
```

Details in [docs/architecture.md](docs/architecture.md).

## Install in your language

### English

You need an Apple silicon Mac with macOS 15+, Claude Desktop or Claude Code, and the Command Line Tools
(`xcode-select --install`). In Terminal:

```bash
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

Then quit Claude Desktop (⌘Q) and reopen it. To update, run `~/code/regista/scripts/install.sh` again; if something
is wrong, `~/code/regista/scripts/doctor.sh` says how to fix it.

### Italiano

Serve un Mac con chip Apple e macOS 15 o successivo, Claude Desktop o Claude Code, e gli strumenti da riga di comando
(`xcode-select --install`). Nel Terminale:

```bash
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

Poi chiudi Claude Desktop del tutto (⌘Q) e riaprilo. Per aggiornare rilancia `~/code/regista/scripts/install.sh`; se
qualcosa non va, `~/code/regista/scripts/doctor.sh` dice come risolverlo.

### Français

Il faut un Mac avec puce Apple et macOS 15 ou plus récent, Claude Desktop ou Claude Code, et les outils en ligne de
commande (`xcode-select --install`). Dans le Terminal :

```bash
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

Ensuite, quitte complètement Claude Desktop (⌘Q) et rouvre-le. Pour mettre à jour, relance
`~/code/regista/scripts/install.sh` ; en cas de problème, `~/code/regista/scripts/doctor.sh` indique comment le
corriger.

### Português

É preciso um Mac com chip Apple e macOS 15 ou mais recente, o Claude Desktop ou o Claude Code, e as ferramentas de
linha de comandos (`xcode-select --install`). No Terminal:

```bash
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

Depois fecha completamente o Claude Desktop (⌘Q) e volta a abri-lo. Para atualizar, volta a executar
`~/code/regista/scripts/install.sh`; se algo correr mal, `~/code/regista/scripts/doctor.sh` diz como o resolver.

## Licence

Copyright © 2026 Arkad Consulting

Regista is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License
as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version
(SPDX: `GPL-3.0-or-later`). It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; see
[LICENSE](LICENSE) for the full text.

The name "Regista" and the Arkad name and logos are not licensed under the GPL: see [TRADEMARKS.md](TRADEMARKS.md).
Third-party engines, models, fonts and sound effects keep their own licences: see [LICENSES.md](LICENSES.md).

## About Arkad

Regista is made by **Arkad**, a consulting studio in Nice, France, that builds automation, AI tools and websites for
businesses. Learn more at [arkad-consulting.com](https://arkad-consulting.com).
