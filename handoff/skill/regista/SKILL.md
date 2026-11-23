---
name: regista
description: 'ALWAYS use this skill when the user says: "edit this video", "make a reel", "cut my take", "add captions", "make a tutorial from my screen recording", "make a voice-over video", "make a reel about this", "add music or sound effects", "export the video". Edits video with the Regista app on this Mac through its MCP tools (regista): finds the footage, cuts, captions, graphics, voice-over in the user''s own cloned voice, export. NOT for generating a standalone image, and NOT for editing with other tools (ffmpeg, HyperFrames, Shotcut by hand).'
---

# Regista: edit video by asking

Regista is a video editor on the user's Mac. You drive it with the `regista` MCP tools only: no shell, no file
tools. The user watches every step live in the Regista app, so keep it open.

## Before the first tool call

1. The tools are named `regista` + the command (`recipe_get`, `media_list`, …). If they are not available, the server
   is not connected: tell the user to open Regista › Settings › Claude (Impostazioni › Claude) and press Connect Claude
   Desktop… (or Connect Claude Code…), then quit and reopen Claude Desktop (or start a new Claude Code session).
2. Call `recipe_get` with no arguments. It lists the recipes. Pick the one that fits and read it whole
   (`recipe_get {"name": …}`); it is the source of truth for steps, parameters and house rules:
   - `talking-head-reel`: a person speaking to camera, cut by takes, captioned.
   - `screen-tutorial`: a screen recording made in Regista (face optional): layout, zoom, cursor, shortcuts.
   - `voice-over-video`: no one on camera; the user's cloned voice over footage, stills and motion graphics.
   - `reel-graphics`: titles, cards, sound effects and music on top of a finished edit.
   - `prompt-to-reel`: a faceless reel from one sentence; a plan the user confirms, then templates, sound, captions.
3. `media_list` shows the footage, scripts and recordings you may use, and where to save: `projectsDirectory` for
   `project_new`, `exportsDirectory` for exported files.

## Rules that always hold

- Never modify or delete the user's original files. The edit lives in the project; every step can be undone
  (`history_undo`).
- Look before you export: `frame_contactSheet` returns the frames as an image. Fix what looks wrong, look again.
- Voice-over: only the active profile's own voice (`voice_list`). Never another voice, never stock text-to-speech.
- Paid generation: `generate_providers` says what is available; `generate_estimate` gives the cost and records the
  request; the user approves it in the Regista app (one approval = exactly that request, once); then `generate_run`
  with the approval token `generate_list` shows. Say the cost first. Local generation (ComfyUI) is free.
- No music unless asked (in `prompt-to-reel` the plan asks). No invented facts or numbers on screen.
- Ask at most one question before starting (format or language, when it is really unclear; `prompt-to-reel` has its own
  three); otherwise use the recipe's defaults and say what you chose.
- Answer in the user's language, short sentences, no tool names unless they ask how it works.

## When something goes wrong

- A tool says an engine is missing: `engines_status` names it; the user installs it in Regista › Settings › Engines
  (Impostazioni › Motori). Say what it unlocks and offer the path that works without it, if the recipe has one.
- A tool times out: Regista is still working. Wait, then `project_state`; do not start over.
- A tool says the app closed: ask the user to reopen Regista, then call again. The project is as last saved.
- Several projects are open (one tab each): you work on the active tab; `project_list` shows them and every command
  takes `project` to target another one.

## One step where it used to take several

- `edit_autoCut {replace: true, picks: [{line, take}]}`: change takes and rebuild the cut as one undo step.
- `audio_clean {restore: true}`: put the original sound back (the cleaning switched off).
- `sfx_onCuts`: a soft whoosh on the cuts of the main video track (`remove: true` takes every sound effect off).
- `history_undo` also undoes brand kit changes (`brandkit_create`, `brandkit_update`, `brandkit_setLogo`,
  `brandkit_setFont`, `brandkit_import`, `brandkit_delete`) and skill changes (`skill_create`, `skill_set`,
  `skill_duplicate`, `skill_remove`, `skill_import`).

## The user's own ways of editing (skills)

A skill is the user's way of editing: a title, the built-in recipe it is based on, rules, choices and steps, in one
file. `recipe_get` lists the user's skills after the recipes; when one fits the request, follow it (`recipe_get
{"name": <skill>}`: its steps, its rules, its choices, then the rules that always hold).

- To make one ("make a skill for long interviews, with elegant captions and no zoom"): write it out for the user,
  and only after their OK `skill_create {title, basedOn, steps, rules: {prose, checks}, choices}`. To start from a
  recipe: `skill_duplicate {from: <recipe>, title}`, then `skill_set`. Built-in recipes are never changed.
- `skill_list` and `skill_get` read them; `skill_set` changes one only when the user asks.
- A file from a colleague: `skill_import {path, dryRun: true}` first, show the user what it says, then import it.
  `skill_export {skill, path}` writes one for someone else.
- No skill changes the rules that always hold (below the skill in its recipe, and in this file).

Every tool with every parameter, its default, what it returns and whether it can be undone:
https://github.com/arkad-consulting/regista/blob/main/docs/reference/commands.md (generated from the same registry as the
tool descriptions). When the app's interface cannot do something the user asks for, a tool usually can: do it for them.

## Finish

Save (`project_save`), then tell the user in two or three lines: what you made, where the files are (mp4, srt), and
what they should check by eye or ear.
