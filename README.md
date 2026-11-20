# Regista — AI video editing for the Mac

Regista is a macOS video editor for talking-head reels, screen tutorials and faceless videos. You can edit by hand, or
ask **Claude** to edit for you through MCP and watch every step live in the app: takes chosen, cuts, clean voice,
captions, graphics, music, export. Every button is the same command Claude uses, and everything can be undone.

Everything runs on your Mac with free, local engines (whisper.cpp / WhisperX, DeepFilterNet, Apple Vision, ffmpeg, and
on bigger Macs VoxCPM2, Blender, HyperFrames and ComfyUI). No API key and no cloud service are needed to edit. The
interface is in Italian, English, French and Portuguese.

## Install

A Mac with Apple silicon and macOS 15 or later, the Apple Command Line Tools (`xcode-select --install`), and Claude
Desktop or Claude Code if you want Claude to edit. Then, in Terminal:

```bash
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

The installer picks the engines for the Mac's memory tier (every file pinned and checked with SHA-256), builds the app,
puts it in Applications and connects it to Claude. Run the same script again to update. Tiers, engines added later,
connecting Claude and updating: [Installation and engines](docs/en/install.md).

## Your first reel

1. **Home › Talking-head reel › Open Record**: camera and microphone on, your text in the teleprompter tab, ⇧⌘R to record.
2. When you stop, Regista imports the take and makes the basic edit: cuts, best takes, clean voice, captions.
3. In the **Simple** level, check the six steps (cut and takes, captions, appearance, music and sounds, voice, graphics).
4. **Export the reel**: a 9:16 mp4 at −15 LUFS, plus `.srt` captions and a Shotcut project if you want them.

Or ask Claude: *"With Regista, edit test.mov as a reel with English captions and show me a few frames before
exporting."*

## Documentation

The guides, in [English](docs/en/user-guide.md), [Italiano](docs/it/user-guide.md), [Français](docs/fr/user-guide.md)
and [Português](docs/pt/user-guide.md) — the app opens the same ones offline from its **Help** menu:

- **User guide**: the window, the first reel, what Pro adds, brand kits, working with Claude.
- **Recording your voice**: the guided recording, training, text to voice-over, pronunciation, consent.
- **Installation and engines**: the install, what each memory tier gets, connecting Claude, updating.
- **Troubleshooting**: greyed features, missing engines, permissions, "Claude not connected", failed jobs, logs.

The reference, generated from the code and checked by the pre-commit hook ([docs/reference/](docs/reference/)):
[commands](docs/reference/commands.md) (every command and MCP tool with its parameters),
[engines](docs/reference/engines.md), [keyboard shortcuts](docs/reference/shortcuts.md) and
[settings keys](docs/reference/settings.md). How it is built: [docs/architecture.md](docs/architecture.md).
For Claude: [`handoff/skill/regista`](handoff/skill/regista/SKILL.md) (a Claude Code skill the installer adds) and
[`handoff/START-PROMPT.md`](handoff/START-PROMPT.md) (instructions for a Claude Desktop project).

## Contributing

Built with SwiftUI and SwiftPM (Swift 6); the Apple Command Line Tools are enough, Xcode is not needed.

```bash
scripts/build-app.sh                  # build and open build.noindex/Regista.app (and the matching regista-mcp)
scripts/test.sh                       # unit tests
scripts/reference-docs.sh             # regenerate docs/reference after changing commands, engines, shortcuts or settings
git config core.hooksPath .githooks   # once per clone: the pre-commit gate (tests, scenarios, reference, words)
```

Report problems and propose changes on the [issues page](https://github.com/arkad-consulting/regista/issues). Details
on the code, the tests and the hook: [docs/architecture.md](docs/architecture.md).

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
