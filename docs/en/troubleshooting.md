# Troubleshooting

## A button or an item is greyed

Regista hides nothing: a feature that cannot start now stays visible, greyed, and the reason is next to it or below it.
The most common cases:

- *An engine is missing.* For example "The engine that transcribes speech is missing: install it from Settings ›
  Engines." or "Needs Blender: install it in Settings › Engines.". Press **Install…** when it is there, or open
  **Settings › Engines** and install it from there (see [Installation and engines](install.md)).
- *The Mac has too little memory for that feature.* For example "Needs the Pro tier" or "The cloned voice needs a Mac
  with at least 16 GB of RAM". The cloned voice needs the Medium tier (16 GB); voice training and local generation need
  the Pro tier (32 GB).
- *A step is missing first.* For example "Transcribe first." or "Put the video on the timeline first: cut the
  pauses.". Do the step it names first: in Simple, each step also says which one comes next.
- *No project is open.* Many buttons need a video in the project: in **Home**, open a project or import one.
- *Generation has no generator ready.* In **Generate**, each greyed generator says why: ComfyUI not installed or not
  ready (model files or nodes missing), Higgsfield without a connected account. The local generator is set up by hand:
  **Settings › Engines**, **How to install it**.

## An engine is missing or does not work

1. Open **Settings › Engines** and look at the engine's state. If there is **Install**, press it and follow the progress
   in **Jobs**.
2. If the install fails, the job says "Install failed" and the reason. Check the free space and the connection, then try
   again.
3. In Terminal, `~/code/regista/scripts/doctor.sh` checks the whole installation and says how to fix each problem.
4. If that is not enough, run the installation again: `~/code/regista/scripts/install.sh`. What is already installed and
   verified stays as it is.

## Permissions: camera, microphone, screen

macOS asks for permission the first time Regista uses the camera, the microphone or the screen. If you said no, or the
permission is not in effect yet:

- In **Record** the source's row says the macOS permission is missing. Press **Allow…**: System Settings › Privacy &
  Security opens, where you allow Regista.
- **Camera** and **Microphone**: Privacy & Security › Camera and Microphone, turn Regista on.
- **Screen** (and **Mac audio**): Privacy & Security › Screen & System Audio Recording, turn Regista on. Then quit and
  reopen Regista: in **Record** there is **Reopen Regista**. The permission only counts from then on; until it does,
  Regista says **Screen recording not in effect yet**.
- **Keys pressed in the video** (in tutorials): Privacy & Security › Accessibility is needed too. Clicks and the cursor
  do not need it.
- The **Teleprompter** following your voice uses the microphone permission; on macOS 15, Speech Recognition is needed
  too.

An update of Regista should not ask for the permissions again. If it does, allow them again and reopen the app.

## "Claude not connected"

The **Claude** tab of the right panel, and the bar at the top, say **Claude not connected** until Claude uses Regista.
That is normal until you ask it something. If Claude cannot find Regista:

1. Open **Settings › Claude**. Under **Claude Desktop** (or **Claude Code**) it should say **Connected to this app**.
   If it says **Not connected**, press **Connect Claude Desktop…** (or **Connect Claude Code…**). If it says
   **Connected to another copy of Regista**, press **Repoint to this app…**.
2. Quit Claude Desktop completely (⌘Q, not just the window) and open it again. For Claude Code, open a new session.
3. In Claude Desktop's developer settings, "regista" should show as running.
4. Open Regista, then ask Claude, for example: "With Regista, list my videos".

Claude works but you see nothing in the window? Regista was closed the first time Claude used it: Claude then works
without the window and saves the project, which you open later from **Home**. To watch live, open Regista, then quit
and reopen Claude Desktop (or open a new Claude Code session).

If Claude says "timed out" during a long job (a transcription, an export), Regista is still working. Ask it to wait a
minute and look at the state of the project, without starting over.

## A job fails

Transcriptions, voice cleaning, exports, installs and generations are jobs. You find them in **Jobs**, in the status
bar: each has its progress and **Cancel**. A job that fails leaves the project as it was and says why in plain words; a
cancelled job says **Cancelled: nothing was changed.**. Read the reason, fix the cause (an engine, the free space, a file
that moved) and run it again. **Remove from the list** removes the row.

A command that fails, yours or Claude's, changes nothing either: you can try again without harm.

## Where the logs are

- Installation: `~/Library/Application Support/Regista/logs` (one file per step that can fail).
- The connection with Claude Desktop: `~/Library/Logs/Claude/mcp-server-regista.log`, written by Claude Desktop.
- The full check, to attach to a report: in Terminal,
  `~/code/regista/scripts/doctor.sh > ~/Desktop/regista-doctor.txt 2>&1` creates the file `regista-doctor.txt` on the
  Desktop.

## Reporting a problem

In the **Help** menu, **Report a problem…** opens the public issues page:
https://github.com/arkad-consulting/regista/issues. Write:

- what you did or asked (copy your request to Claude, if any);
- what you expected and what happened;
- a screenshot (⇧⌘4 or ⇧⌘5) and the length of the video;
- the file `regista-doctor.txt`, if the problem is about the installation or an engine.

The page is public: do not attach videos, voices or data you do not want to show.
