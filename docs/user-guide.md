# Regista user guide

How to use the app by hand. Claude uses the same commands (see [architecture.md](architecture.md)); installation is
in the [README](../README.md).

## Where files go

Everything in **Movies/Regista** (another folder can be chosen in Settings › General):
- `Registrazioni/` — the recorded videos
- `Progetti/` — the `.regista` project folders (media analysis and transcripts inside each project)
- `Export/` — the exported videos, `.srt` captions and `.mlt` projects

## The editor

One window, laid out like VS Code with macOS materials: one slim **title row**, the native compact toolbar band (the
traffic lights where macOS puts them; Claude's status and the
toggles of the side panel ⌃⌘S and of the right panel ⌥⌘I as its toolbar item; double-click zooms), the **activity bar** on the left
(**Home · Record · Media · Text and captions · Audio · Voice · Graphics · Generate · Export**, ⌘1–⌘9; at the bottom
Engines — Settings › Engines — and Settings), the **side panel** of the chosen activity (drag its edge to resize), the
**main area** with the **project tab** on top (saved / unsaved / recording dot, name, duration, × closes the project and
asks to save; + opens Home), the **right panel** (**Prompter · Claude · Inspector**, 320 pt, the same on every activity;
it remembers its tab) and the **status bar** (RAM and tier, loudness of the edit, the step running, save state). Every
button, menu item and shortcut is an engine **command**, the same ones Claude uses: everything is undone with ⌘Z,
Claude's steps too. The app reopens on the activity, Edit level and right-panel tab used last.

**Home**: "What do you want to make?" — Talking reel and Screen tutorial open Record (camera and microphone, or the
screen on), Faceless video starts an empty project on the Voice activity, Edit a video imports files into a new project
in Pro — then the recent projects (opened or saved by hand or by Claude; File › Open Recent and the Home side panel list
the same) and one line with this Mac's RAM, tier and engines ready.

**Record**: the sources, presets, display picker and face layout in the side panel, the live preview and "In the file:
…" in the main area, the teleprompter script in the right panel's Prompter tab.

**The editor** (Media, Text and captions, Audio, Voice, Graphics, Generate keep it in the main area and change the side
panel): a slim toolbar with the level (**Simple** · **Pro**, ⌥⌘1 · ⌥⌘2; the editor returns to the last one used), the
format, undo · redo · history, and the project's **Brand** button (the one place that picks the project's brand kit).
- **Media** (thumbnails and durations; double-click → Source monitor), **Text and captions** (captions, keywords and
  script · the **transcript** following the playhead: click a word → go there, ⌥click and ⇧click select, *Remove from
  the edit* takes those words out · the **takes** of each script line: approve, or pick another take and redo the cut),
  **Audio** (loudness, voice cleanup, music), **Voice** (text to voice-over), **Graphics** (filters, adjustments, effects,
  styles, motion templates, logo), **Generate** (placeholder: Claude starts generations for now);
- **Pro**: **Source** and **Program 9:16** monitors with the **safe zones** (caption band, Instagram interface); at the
  bottom the tools (select, blade, text, hand), the **timeline** with tracks T1 captions · V2 graphics/AI · V1 takes ·
  A1 voice · A2 music · A3 effects (lock, show/hide, mute, solo), thumbnails and waveforms, and the **meter** M/S/I LUFS
  + true peak (reel target −15 LUFS, peak ≤ −1.5 dBTP);
- **Simple**: six guided steps — **Cut & takes · Captions · Look · Music & sounds · Voice · Graphics** — each with its
  state worked out from the project (to do, done, optional, or unavailable with the reason and *Install…* when an engine
  is missing), one monitor in the project's format and the edit as a filmstrip underneath. Click a step to open its short
  panel of switches and presets (how tight the cut is and the take of each line read more than once; captions on/off and
  their style; the light grade and one colour look; music with its level and ducking, a whoosh on the cuts; voice
  cleaning on/off and a voice-over from text when your voice is ready; an opening title, the logo, three animated cards).
  **Do everything** cuts, picks the takes, cleans the voice, adds the captions and the light grade as one job you can
  stop; run twice, it adds nothing. **Export the reel** opens Export on the Reel 9:16 format (−15 LUFS, the checks).
  Every switch is one command (⌘Z undoes it) and Pro shows the same edit. This is the view that shows a project Claude
  creates or opens while you are in the editor or Export.

**Export**: format, checks and files in the side panel, the program monitor in the main area.

**Right panel**: **Prompter** (write the script, scrolling mode, voice following), **Claude** (every step in plain
words, yours too; looks such as screenshots and reads of the project collapse into one quiet line you can expand;
a calm "not connected" state), **Inspector** (the selected clip; its controls arrive with node E1).

**Panels and tooltips**: drag the thin lines between panels to resize them (side panel, Program, timeline height); double-click a line to go back to the automatic size. Sizes are remembered. Rest the pointer on
any icon: its name and shortcut appear after a moment.

| Shortcut | |
|---|---|
| Space | play / pause |
| J · K · L | back · stop · forward (repeated: 2×, 4×, 8×) |
| ← → (⇧ = 1 s) · Home · End | frame by frame · start · end |
| V · C · T · H | select · blade · text (caption keywords) · hand |
| ⌘K | cut every track at the playhead |
| ⌫ · ⇧⌫ | delete the selected clips · delete and close the gap (or the words selected in the transcript) |
| + · − · \\ | timeline zoom · fit |
| ⌘Z · ⇧⌘Z | undo · redo (Claude's steps too) |
| ⌘1 … ⌘9 | Home · Record · Media · Text and captions · Audio · Voice · Graphics · Generate · Export |
| ⌥⌘1 · ⌥⌘2 | the editor at the Simple · Pro level |
| ⌃⌘S · ⌥⌘I | show / hide the side panel · the right panel |
| ⌘N · ⌘O · ⌘S · ⇧⌘S · ⌘I | new · open · save · save as · import (File › Open Recent: the recent projects) |
| ⇧⌘M | local automatic edit (audio → transcript → teleprompter script → takes → cut) |
| ⇧⌘R · ⌥Space | record/stop · start/pause the teleprompter |
| ⇧⌘B | brand kit |
| ← → ↑ ↓ (⇧ = 10 px) · Esc | with a caption or graphic selected on the preview: nudge it · let go of it |

## Moving captions and graphics

Captions, titles, stickers and the logo can be moved on the preview with the mouse, like text in an Instagram story.

- **Click** a caption, a title, a sticker or the logo on the **Program** monitor (Pro) or on the monitor (Simple):
  a gold frame appears. **Drag it** where you want. While you drag, **guides** appear (centre, thirds, the edges of
  the other graphics: it snaps by itself; hold ⌘ not to snap) and, in **red**, the zones of Instagram's interface
  (account bar at the top, buttons and caption at the bottom, the action column on the right): an element that
  enters them turns red.
- **Size**: drag a corner, pinch on the trackpad, ⌥ + scroll, or the slider in the small bar that appears below.
  **Rotation** (titles, stickers, logo): the knob above the frame.
- **All captions / Only this one** (in the small bar): moves the whole caption track, or only the phrase you see. A
  phrase moved by hand stays there even if a face passes under it (the check reports it).
- **Reset** (↺ in the small bar) or **double-click**: captions go back to their automatic position, a graphic to
  where it was before you moved it. Arrows = 1 px, ⇧ + arrows = 10 px, Esc deselects.
- Every move is **a single ⌘Z step** and shows in the Claude panel. Claude can do the same: *"move the captions
  higher, to the left"*, *"only the one at 0:12, lower and bigger"*, *"put the logo back where it was"*.
- The export (mp4 and Shotcut project) puts them exactly where you see them.

## Effects: retouching like a photo

The **Graphics** activity (Simple's *More graphics in Pro* opens it too) shows one panel in the side panel, with
the edit in the main area: a search, then six sections — **Filters**, **Adjust**, **Effects**, **Styles**, **Motion**,
**Logo**. Every item has its plain name, one line saying what it does and, where the engine can draw one, a preview made
from **your** frame (it plays when the pointer rests on it). **Click** applies it to the selected clip, or at the
playhead; text items and motion templates open a small form under the row (already filled in: *Add* / *Apply* is
enough). An item that cannot run now stays visible, greyed, with the reason (a 3D title without Blender, a caption
style before captions exist). You can also **drag** a row onto a clip or a point of the timeline, or onto the Simple
view's strip. What is on the reel at the playhead is listed at the top of the section, each with × to remove it.

- **Filters**: 14 looks (Dorato, Brina, Pellicola, Grafite, Inchiostro, Vivido, Velluto, Riviera, Archivio, Opaco,
  Tramonto, Fiordo, Notte, Luce), each shown on your frame. Click to apply, click again to remove; the **intensity**
  slider appears once a look is on. On the whole video or only *this clip*; titles, stickers and logo keep their
  colours.
- **Adjust**: quick adjustments (brighter, warm, cool, contrast, vignette, sharpness, black and white), then one slider
  per tool: Exposure, Brilliance, Highlights, Shadows, Contrast, Saturation, Warmth, Tint, Sharpness, Vignette.
  *Applied* lists what the video carries: a × removes that item.
- **Effects**: Zoom, Motion, Text, Stickers, Transitions, Speed, Captions (four caption styles), Layout (letterbox with
  headline, side card, bubble, neon inset card, full frame), with one **Intensity** control (a little ↔ a lot).
- **Styles**: *Energetic reel* (vivid colours, a punch-in on every sentence, whooshes on a few cuts, word-by-word
  captions), *Clean* (soft light, gentle contrast, whole-sentence captions), *Tutorial* (zooms and circles on clicks,
  progress bar), *Console* (the video in a neon card with a PREVIEW chip, a REC bar with timer and chapters, bold
  captions with the keyword in the accent). One click = many steps, **a single ⌘Z** undoes them; it uses the brand kit's
  colours.
- **Motion**: animated cards, checklists, counters, charts, carousels, device frames…
- **Logo**: the brand's logo in the video (corner — always out of the captions and of Instagram's buttons —, size,
  presence, entrance) and the logo animations (end sting, spin, pulse, orbit).
- **Caption style**: in the Texts panel, under the captions — *Talking head* (the approved look), *Elegant serif*
  (cream italic, one phrase at a time), *Bold + keyword* (two lines, keyword in the brand colour), *Ghost karaoke* (the
  whole phrase, words light up as they are said). Keywords and hand placements stay.

Speed: slow motion, super slow motion, fast, timelapse, ramps (*hero*, *in*, *out*), reverse, freeze frame. The voice
keeps its pitch (stretched, not lower) up to 4× either way; beyond that, in reverse and in a freeze it is muted. After a
speed change, regenerate the captions. Every effect is also a command for Claude.

## Brand kits: each brand's colours, fonts and logo

A **brand kit** is a brand's look: colours by role (primary, accent, highlight, ink, paper…), fonts (titles, text,
labels), **logo** (SVG or PNG, versions for dark video / light background / symbol only), logo position and caption
style. Built in: **Arkad** (official SVG logo), **WeSites** and **Café Atelier** (a fictional bakery-café starter kit to copy:
its logo is a placeholder). The WeSites fonts and logo are not in the repository: put them in `~/Library/Application Support/Regista/brandkits/wesites/assets` (or point
`REGISTA_WESITES_ASSETS` at their folder).

- **Choose** — the editor's toolbar shows the project's kit: one click (also ⇧⌘B) opens the **Brand** picker, the
  only place that picks it. A click on a kit applies it: captions are recoloured (the keyword box takes the *Highlight*
  colour; the caption style you chose stays), preset titles and the logo change in one go.
- **Create or edit** — in **Settings › Brand kit**: the kits on the left (+ new, − delete, *Import…*), the selected kit
  on the right: name, colours by role (the macOS colour picker), fonts and logos (*Choose…*), the logo's corner, size,
  entrance and presence, *Duplicate*, *Export…*. The preview is drawn by the export engine. Every change is one step:
  **⌘Z** (or the *Undo* button there) puts the kit back. Editing a built-in kit creates your own copy (− restores the
  original).
- **The logo in the video** — Graphics › Logo → *Logo in the video*.
- **App colour** — Settings › General → *App colour from the kit*: buttons and highlights take the brand's colour (of
  its colours, the one readable on the dark background).

**Adding your logo**: Settings › Brand kit → the kit → *Logo* → *Choose…* next to *On dark video* (an SVG is better:
it stays sharp at any size; the light logo, for footage) and, if there is one, the dark version next to *On light*.
Or ask Claude: `brandkit.setLogo {kit, path}`.

**Sharing a kit** — gallery → *Export…*: a single `.registakit` file (colours, fonts and logo inside).
Whoever receives it does *Import…* (or `brandkit.import`) and has the same kit, fonts included. Kits live in
`~/Library/Application Support/Regista/brandkits/<id>/` (`kit.json` + `assets/`).

## The teleprompter

The teleprompter is a window **only you see**: it stays above the others, opens at the top centre (near the webcam),
you move it where you want and it remembers that for every screen. It **never appears** in a screen recording, a
screenshot or a screen share (the window is excluded from capture). With *Mirrored* the text flips for teleprompter
glass.

**The text.** One numbered line = one sentence = one take (the lines right under it continue the same sentence). Ask
Claude to prepare it: *"prepare my teleprompter script"* (`script.prepare`) splits it into short lines (≤ 32
characters), puts `/` where to breathe (a short pause in the teleprompter) and marks **keywords** with `*word*`
(slightly highlighted in the teleprompter; the same ones as in the captions). The agent's script reaches the
teleprompter by itself.

**Voice mode.** The teleprompter listens (Apple speech recognition **on the Mac**, free, nothing online; Italian or
French): the word just read is gold, the words already read fade, it stops if you talk about something else and
resumes when you pick up, even further on. **If you restart a sentence**, it goes back to its start by itself and marks
a new take ("sentence 3 · take 2" at the top). Top right, the **pace**: words per minute, gold between ~135 and 185
(150–170 is ideal), blue if you are slow, orange if you rush. *Speed* (fixed scrolling) and *Manual* remain; the scroll
wheel and the arrows always work.

| Command | What it does |
|---|---|
| **Space** | start / pause |
| **↓ → Page Down** | next sentence |
| **↑ ← Page Up** | restart the sentence (again: the previous one) |
| click a word | "I am here" |
| voice: **"rifaccio"** (FR "je recommence") | discard the take and go back to the start of the sentence |
| voice: **"stop"** | stop the recording |

A **Bluetooth pedal** or a **presentation remote** send exactly arrows and Page Up/Down: they work with no setup (when
the teleprompter is in use and you are not typing). The voice-command phrases are changed in the teleprompter's page
(several phrases separated by commas).

**Takes marked live.** When the recording ends the teleprompter saves `Registrazione ….takes.json` next to the file
(sentence, take, start, end, complete or not). On import the automatic edit starts from there: the choice of takes is
what the teleprompter saw, with the transcript alignment as a fallback.

**Permissions** (asked the first time): **Microphone** (the same as for recording). On macOS 26 recognition uses the
system speech model, downloaded once by macOS; on macOS 15 **Speech Recognition** is needed too (System Settings →
Privacy & Security).

## Tutorials: screen + camera

In **Record** turn on *Also record the screen (tutorial)*, choose what to record (whole screen, a window or *Choose an
area…*), *System audio* if needed, and where the face goes: **Bubble** (corner, size S/M/L, circle or square), **Side by
side** (screen 2/3 + face 1/3), **Vertical** (9:16 reel: screen on top, face below), **Face**, **Cut-out** (you without
background over the screen), **Screen only**. The preview shows the layout live and you can change it while recording
too; ⇧⌘P pauses. Regista's windows and the teleprompter never end up in the video.

At the end a 16:9 project opens with the **screen on V1, the camera on V2 with the layout, the microphone on A1**,
already synchronised. Then just ask Claude, for example: *"zoom on the clicks"* (`edit.autoZoom`), *"from minute 2 put
me side by side"* (`layout.apply`), *"also make the vertical reel with me cut out"* (a new 9:16 project from the same
session). Sessions live in **Movies/Regista/Registrazioni/Sessione …/** (`screen.mov`, `camera.mov`, `mic.wav`,
`session.json`).

**Permissions to give once** (System Settings → Privacy & Security), then quit and reopen Regista:
- **Screen & System Audio Recording** → Regista (without it the screen stays black and Regista says so);
- **Camera** and **Microphone** → Regista (already asked by the normal recording);
- **Accessibility** → Regista, only if you also want to record **key presses** (clicks and the cursor do not need it).

## Your own voice: profiles

Regista can speak a voice-over **in your own cloned voice** (VoxCPM2, local and free). The voice belongs to a
**profile**: the person this Regista belongs to. A fresh install, or a package someone shares with you, has **no profile and no
voice** — everyone records and clones their own.

1. **Create your profile**: Settings → *Profile and voice* → your name (or ask Claude: *"create my profile, I'm Ada"*).
2. **Record**: ask Claude *"record my voice in French"* (or Italian, English, Portuguese). It gives you the script
   (~30 min: a consent sentence with your name, then 7 tone blocks) and writes it to your profile as `script.md`.
   Best: a phone with an external microphone, in a quiet room with soft furnishings; one file per block. Regista's
   recorder works too (microphone only).
3. **Give the files to Claude** (*"here is the neutral block: …"*): each one is checked against the script and cut
   into clips. After the neutral block your voice already works (zero-shot).
4. **Train** (Pro tier, Mac with 32 GB+): *"train my French voice"* — about 2 h in the background, then voice-overs
   use it automatically.

**Privacy.** Recordings, clips and models stay in `~/Library/Application Support/Regista/profiles/<you>/`, never in
the repository or the package (the pre-commit hook and `scripts/package.sh` refuse voice data). A profile copied to
another Mac is locked. Only the active profile's voice is ever used; switching, adopting or deleting a profile is done
by the person in Settings (Claude cannot). The first recording of each language starts with a spoken consent
sentence. Deleting a profile moves it to the Trash. A generated voice is AI-generated content: say so when you publish.

