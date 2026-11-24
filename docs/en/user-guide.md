# Regista guide

Regista is a video editor for the Mac: reels where you talk to the camera, screen tutorials, faceless videos in your own
voice. You can edit by hand with the buttons, or ask Claude to edit for you: you see every step in the window and can
undo it.

It installs with one command in Terminal: everything is in [Installation and engines](install.md).

## The window

- *The bar on the left* has one icon per activity: **Home**, **Record**, **Media**, **Text & captions**, **Audio**,
  **Voice**, **Graphics**, **Generate**, **Export**. At the bottom are **Engines** and **Settings**. ⌘1 to ⌘9 open the
  activities in the same order. Rest the pointer on an icon to see its name.
- *The side panel* shows the content of the chosen activity. Hide and show it with ⌃⌘S; drag its edge to widen it.
- *The project tabs* sit at the top, in the middle. Each open project has its tab; the dot says whether it is saved.
  The + opens a **New tab**.
- *The main area* changes with the activity: in **Home** you choose where to start, in **Record** you see the preview,
  in the editing activities you see the edit, in **Export** the result.
- *The right panel* has the tabs **Claude** (every step Claude takes, in plain words) and **Inspector** (the settings of
  the selected clip); in **Record** it also has **Teleprompter** (the text you read while recording). Hide it
  with ⌥⌘I.
- *The status bar*, at the bottom, shows the Mac's memory and tier, the loudness of the edit and whether the project is
  saved. While Regista works (a transcription, an export) **Jobs** appears: click it to see the progress, **Cancel** and
  any errors.
- *The bar above the edit* chooses **Simple** or **Pro** and shows the video's format, for example Format 9:16 ·
  1080×1920 · 30 fps: a click opens 9:16, 4:5, 1:1 and 16:9. A change of format is a single ⌘Z step, and the camera
  clips stay framed on the face, never cut around the centre. The same choice is in the **Inspector**, **Project**
  section, under **Format**.

Every button makes one step you can undo with ⌘Z and redo with ⇧⌘Z, Claude's steps too.

## Your first reel, step by step

This is the simplest path: you record, Regista edits by itself, you check and export.

1. In **Home** choose **Talking-head reel**, then **Open Record**. If you already have a video, choose
   **or import a video** instead and skip to step 6.
2. In **Record**, under **What you record**, choose **Face only**. **Camera** and **Microphone** must be on. The first
   time, macOS asks permission for the camera and the microphone: allow it.
   Above the preview choose the video's format: **As the camera**, 9:16, 16:9, 4:5 or 1:1. A frame on the preview shows
   what stays in the video. If the tab's project has another format, it changes to the one chosen when you add the take;
   a take of another format is framed on the face.
3. In the right panel, **Teleprompter** tab, paste your text: one sentence per line. With **Teleprompter** on under
   **Sources**, the teleprompter opens and starts with the recording.
4. Press **Record** (⇧⌘R) and read. If you get a sentence wrong, start it again: the teleprompter goes back to the start
   of the sentence and marks a new take. To finish, press ⇧⌘R again.
5. When the recording ends you stay in **Record**: the take goes into the tab's project and you can record another one,
   which joins the same project. The notice at the top says where it went and how many takes the project holds; **Go to
   edit** opens the editor with the take. If you turn on **Automatic edit when the recording ends** (off by default),
   Regista opens the editor and makes the basic edit by itself. You follow it in **Jobs**, in the status bar.
6. In the bar above the edit choose **Simple** (⌥⌘1). On the left are six steps: **Cut & takes**, **Captions**,
   **Appearance**, **Music & sounds**, **Voice**, **Graphics**. Each says whether it is done, to do or optional.
7. If the edit is not done yet, press **Do everything**: it cuts the pauses, picks the takes, cleans the voice, adds the
   captions and a brighter light. You can stop it at any time; run it again and it adds nothing twice.
   First it finds the face in every frame (**Find the face**: Apple Vision, on the Mac, no cost), so captions and
   framing keep it clear; at the end it checks that no head is cut. If one is, the step says so and its button
   **Frame on the face** frames it again.
8. Open the steps one by one and watch the result in the monitor:
   - **Cut & takes**: how tight the cut is (long pauses go) and, for sentences read more than once, which take to keep.
     Regista picks the best one; you can try another.
   - **Captions**: **Captions in the video** on or off, and the style: **Talking head** (large capitals a few
     words at a time, the keyword on a coloured box), **Elegant serif**, **Bold + keyword**, **Ghost karaoke**.
   - **Appearance**: **Light grade** and, if you like, one colour for the whole video.
   - **Music & sounds**: **Choose music…** (it goes down by itself when you speak) and **A whoosh on the cuts**. Both are
     optional: on Instagram, trending music is usually added in the app.
   - **Voice**: **Clean the voice** removes noise and brings the voice to −15 LUFS, the right loudness for social media.
   - **Graphics**: a title, the **Logo in the video**, an animated card. Cards are added at the playhead: move it to the
     right sentence first.
9. Press **Export the reel**. **Export** opens on the **Reel 9:16** format. Look at the **Checks** (duration, loudness,
   peak, captions up to date), then press **Export video…** and choose the name and the folder. When it is done,
   **Show in Finder** opens the folder.

Every step starts from your direction (see "Direction & skills" below): the pace of the cut, the caption style, the
light, the music, the sound effects, the logo. A choice you change in a step holds for this project only: a dot appears
beside it (hover over it to see what your direction wants) and, beside the step's title, **Reset** takes the step back to
your direction. That too can be undone with ⌘Z.

In **Export**, the **Editing rules** card checks the video against the rules of its kind: no caption over a face,
captions gone with their words, music lowered under the voice, the voice at its loudness, on-screen text long enough to
read, the logo only at the end. A broken rule has a link to the moment and, where it can, **Fix** (one ⌘Z step); **Fix all and
export** fixes them all, and **Export anyway** is always there. A check that cannot be measured yet stays on a grey line,
"not checked", with the reason and a link that measures it: **Find the face** or **Export to measure**. It never counts
as passed.

Regista removes long pauses and keeps the best take of each sentence. It does not yet remove filler words such as "um"
inside a sentence: if you find one, remove it by hand from the transcript (see below).

With Claude: ask it to remove the filler words. It tells you how many hesitations ("um") it found and how many seconds
they take, removes them if you agree, and words such as "so" or "like" only when you name them. The transcript often
leaves hesitations out: they stay a pause, and cutting the long pauses usually removes them.

## What Pro adds

Choose **Pro** (⌥⌘2) in the bar above the edit. You get two monitors, **Source** and **Program**, and under them the
timeline with its tracks: captions, graphics, takes, voice, music and sound effects. Left of the timeline are the
select (V), blade (C), text (T) and hand (H) tools; on the right, the loudness meter. Simple and Pro show the same
project: what you change in one, you see in the other.

- **Media**: the project's files. **Import…** adds videos, sounds and images; a video that goes on an empty edit in a
  format other than the project's is framed on the face. Double-click a file to see it in the **Source** monitor.
- **Text & captions** has four tabs. **Steps** goes from the video to the captions one step at a time (**Transcribe**,
  **Find the face**, **Script**, **Choose the takes**, **Cut the pauses**, **Clean the voice**, **Captions**), or all at
  once with **Do everything**. **Captions** changes the style and the keywords. **Transcript** follows the playhead:
  click a word to go there; select words (⌥-click, ⇧-click) and take them out of the edit with ⌫. **Takes** shows every
  reading of each sentence: approve the chosen one or pick another, then redo the cut.
- **Audio** has two tabs. **Mix**: the loudness of the edit, the voice cleaning, the music (**Add music…**, its volume
  and how far it goes down under the voice). **Sound effects**: search for a sound, listen to it with a click and put it at
  the playhead.
- **Graphics**: **Filters**, **Adjust**, **Effects**, **Styles**, **Motion graphics** and **Logo**. Each item says what
  it does and, where it can, shows a preview on your own frame. A click applies it to the selected clip or at the
  playhead. An item that cannot run now stays visible, greyed, with the reason (a 3D title without Blender, for
  example).
- **Generate**: an **Image** from a description, a **Video clip** from a frame, **Music**, or **Upscale** on a generated clip.
  The local generator (ComfyUI, free) needs a Pro-tier Mac (32 GB) and is set up separately (see
  [Installation and engines](install.md)). The cloud generator (Higgsfield) is paid: you see the cost first, then
  approve the spending (the button shows the amount) or **Decline**. An approval is good for that one generation only.
  What you generate lands in **Media**.
- **Export**: the format (**Reel 9:16**, **Feed 4:5**, **Square**, **Landscape**), **Burned-in captions**, the
  **Bit rate**, the **Checks** and the files: **Export video…**, **Captions .srt…** and **Shotcut project…** (to finish
  the edit in Shotcut).
- **Cover**, in **Export** (vertical 9:16 videos only): move the playhead to the right frame and click
  **Use this frame**, type the title (3–5 words) and choose where it sits: **Top**, **Middle** or **Bottom**. The two
  dashed frames are the crops of the Instagram grid (3:4) and of the Shorts shelf (2:3): if the title leaves them, the
  line underneath says by how many pixels and what to choose. **Save cover…** writes the PNG to upload as the cover.
  The cover has no captions; the title's font and colours come from the **Brand** kit.
- **Inspector**, in the right panel: the settings of the selected clip (timing, position, colour, volume, speed).

### Moving captions and graphics

On the **Program** monitor (or Simple's monitor) click a caption, a title, a sticker or the logo: a frame appears. Drag
it where you want. While you drag, guides appear and, in red, the areas Instagram's interface covers. For the size,
drag a corner or use the slider that appears below. Double-click puts the element back where it was. The arrow keys
move it by one pixel, with ⇧ by ten; Esc lets go of it. Every move is a single ⌘Z step, and the export puts it exactly
where you see it.

## The teleprompter

The teleprompter is a window only you see: it stays above the others, near the webcam, and never appears in a screen
recording or a screen share. You write the text in the **Teleprompter** tab of the right panel: each numbered line is a
sentence, that is one take.

- **Scrolling**: **Voice** (the teleprompter listens and moves on as you read), **Speed** (it scrolls by itself) or
  **Manual**.
- **Follows your voice**: the language you read in. Recognition runs on the Mac: no audio leaves the computer.
- **Mirrored** flips the text for teleprompter glass.
- **Let me redo** and **Stop**: the words that, said out loud, restart the sentence or stop the recording.
- **Show the teleprompter**, **Listen and follow** and **Start over** try it without recording.

Space starts and stops the scrolling; ↓ goes to the next sentence, ↑ restarts the sentence. A Bluetooth pedal or a
presentation remote works with no setup.

## A screen tutorial

1. In **Home** choose **Screen tutorial**, or in **Record** choose **Screen only** or **Screen + face**.
2. In the **Screen** row choose what to record: a whole screen, a window or **Choose an area…**. Turn on **Mac audio**
   if you need the computer's sound.
3. With the face on, under **Face in the video** choose where it goes: **Bubble**, **Side by side**, **Stacked**,
   **Face**, **Cut-out** or **Screen only**. You can change it while recording too.
4. Press **Record** (⇧⌘R); ⇧⌘P pauses. Regista's windows and the teleprompter never end up in the video.
5. At the end a 16:9 project opens with the screen, the camera and the microphone already in sync. From there you edit
   as usual, or ask Claude, for example: "zoom on the clicks".

The first time, macOS asks for permission to record the screen: see [Troubleshooting](troubleshooting.md).

## Direction & skills: your own way of editing

**Settings › Direction & skills** holds the rules for every video (**For every video**: the checks before export, the
choices such as the caption style or the pace, and the rules Claude reads), the five recipes that are **Regista's** and
**Yours**, your skills. A skill is a way of editing: rules, choices and steps, in one file.

- Regista's recipes can be read, not changed: **Duplicate** makes a copy of your own to change as you like.
- **+ New skill…** makes an empty one; **Import a skill…** opens the file a colleague sent you and shows what it says
  before adding it; **Export…** makes the file to send.
- Every skill has three tabs: **Rules**, **Choices** and **Steps** (the steps Claude follows). Every change can be
  undone with ⌘Z.
- In **Rules** the checks stand in the parts of the video: **Always**, **Opening**, **Picture**, **Graphics and text**,
  **Ending**, **Sound**. Each one turns on or off; where it has a number (the pause before the logo, the voice's
  loudness) you change it there. In **Choices** you say how you want the video: the pace, the caption style, the colour,
  the music, the sound effects, the closing logo. Claude and the Simple steps start from these choices.
- You can also ask Claude, for example: "make a skill for long interviews, with elegant captions and no zoom". No skill
  changes the rules that always hold (only your own voice, originals never touched, nothing paid without your OK).

## Brand: colours, fonts and logo

A brand kit holds a brand's colours, fonts and logo. In the bar above the edit, the **Brand** button shows the
project's kit: one click opens the list, another picks the kit. Captions, titles and logo take its colours in one go.

Kits are created and edited in **Settings › Brand kit**: name, colours, fonts, logo and where it goes. Every change can
be undone with ⌘Z. To give a kit to someone else, **Export…** makes a single `.registakit` file (colours, fonts and
logo inside); whoever receives it uses **Import…** on the same screen. The logo goes into the video from **Graphics › Logo** or, in Simple, from the **Graphics** step.

## Working with Claude

Claude can do everything the buttons do, and also what is still awkward in the interface. To connect it, see
[Installation and engines](install.md). Keep Regista open: you watch every step live.

What you can ask, for example:

> With Regista, list my videos and tell me what you can do with them.

> Edit "test.mov" as a reel: the best takes, no pauses, clean voice, English captions, with my brand kit. Show me a few
> frames before exporting.

> Move the captions higher. Remove the second sentence. My brand's name is spelled wrong at 0:12.

- In the **Claude** tab of the right panel you read every step Claude takes, in plain words.
- Every step Claude takes is undone with ⌘Z, like yours.
- Claude spends nothing on its own: a paid generation starts only after you approve it in the app.
- Claude works with the files in Movies › Regista and never deletes or changes your originals.

## Where files go

Everything goes into the Movies › Regista folder (change it in **Settings › General**, **Regista folder**):

- `Registrazioni`: the videos you record;
- `Progetti`: the projects (`.regista`);
- `Export`: exported videos, `.srt` captions and Shotcut projects.

With **Automatic saving** on, Regista saves every minute the projects that already have a folder. A project never saved
you save yourself with ⌘S.

If Regista stops answering for a few seconds, it writes a hang report on the Mac by itself: nothing is sent.
**Settings › General › Show the hang reports** shows the newest one in the Finder, to attach to a bug report.

Every keyboard shortcut is in **Settings › Shortcuts**. If something goes wrong, read [Troubleshooting](troubleshooting.md);
for your cloned voice, [Recording your voice](voice.md).
