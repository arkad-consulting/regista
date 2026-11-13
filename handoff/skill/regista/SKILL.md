---
name: regista
description: 'ALWAYS use this skill when the user says: "edit this video", "make a reel", "cut my take", "add captions", "make a tutorial from my screen recording", "make a voice-over video", "add music or sound effects", "export the video". Edits video with the Regista app on this Mac through its MCP tools (regista): finds the footage, cuts, captions, graphics, voice-over in the user''s own cloned voice, export. NOT for generating a standalone image, and NOT for editing with other tools (ffmpeg, HyperFrames, Shotcut by hand).'
---

# Regista: edit video by asking

Regista is a video editor on the user's Mac. You drive it with the `regista` MCP tools only: no shell, no file
tools. The user watches every step live in the Regista app, so keep it open.

## Before the first tool call

1. The tools are named `regista` + the command (`recipe_get`, `media_list`, …). If they are not available, the server
   is not connected: tell the user to open Regista › Settings › Claude and press Connect, then restart Claude.
2. Call `recipe_get` with no arguments. It lists the recipes. Pick the one that fits and read it whole
   (`recipe_get {"name": …}`); it is the source of truth for steps, parameters and house rules:
   - `talking-head-reel`: a person speaking to camera, cut by takes, captioned.
   - `screen-tutorial`: a screen recording made in Regista (face optional): layout, zoom, cursor, shortcuts.
   - `voice-over-video`: no one on camera; the user's cloned voice over footage, stills and motion graphics.
   - `reel-graphics`: titles, cards, sound effects and music on top of a finished edit.
3. `media_list` shows the footage, scripts and recordings you may use, and where to save: `projectsDirectory` for
   `project_new`, `exportsDirectory` for exported files.

## Rules that always hold

- Never modify or delete the user's original files. The edit lives in the project; every step can be undone
  (`history_undo`).
- Look before you export: `frame_contactSheet` returns the frames as an image. Fix what looks wrong, look again.
- Voice-over: only the active profile's own voice (`voice_list`). Never another voice, never stock text-to-speech.
- Paid generation: say the cost first; it runs only after the user approves it in the app. Local generation is free.
- No music unless asked. No invented facts or numbers on screen.
- Ask at most one question before starting (format or language, when it is really unclear); otherwise use the
  recipe's defaults and say what you chose.
- Answer in the user's language, short sentences, no tool names unless they ask how it works.

## When something goes wrong

- A tool says an engine is missing: `engines_status` names it; the user installs it in Regista › Settings ›
  Motori. Say what it unlocks and offer the path that works without it, if the recipe has one.
- A tool times out: Regista is still working. Wait, then `project_state`; do not start over.
- A tool says the app closed: ask the user to reopen Regista, then call again. The project is as last saved.
- Several projects are open (one tab each): you work on the active tab; `project_list` shows them and every command
  takes `project` to target another one.

## Finish

Save (`project_save`), then tell the user in two or three lines: what you made, where the files are (mp4, srt), and
what they should check by eye or ear.
