# Installation and engines

## The downloaded app

You need a Mac with Apple silicon (M1 or later) and macOS 15 or later. You need neither Terminal nor Apple's tools nor
Homebrew. Open the `Regista-<version>.dmg` file, drag Regista to Applications and open it from there: opened from the
disk image or from Downloads, Regista offers to move itself (**Move and reopen**).

ffmpeg, whisper.cpp and DeepFilterNet are already inside the app: recording, cutting, cleaning the voice, graphics and
export work right away. While something is missing, Home shows it under **Getting started**, one row for each:

- **Model to transcribe and make captions**: **Download** gets the transcription model (1.6 GB; also from
  **Settings › Engines**). When the download ends, the row goes away by itself.
- **Connect Claude to edit by talking**: **Connect…** opens **Settings › Claude**. **I don't use Claude** hides the row for
  good: Regista also works without Claude, by hand.

To install from the source code (if you develop Regista, or for a version not yet published as a disk image), follow
the steps below.

## What you need

- A Mac with Apple silicon (M1 or later) and macOS 15 or later.
- Apple's command line tools. If you do not have them, type `xcode-select --install` in Terminal and wait for Apple's
  installer to finish.
- Free disk space: about 4 GB for the Base tier, 16 GB for Medium and Pro. Local generation on the Pro tier, set up
  separately, takes much more (about 70 GB).
- A good connection and 20 to 40 minutes the first time.
- To work with Claude: Claude Desktop (https://claude.ai/download) or Claude Code, signed in to your account. Install it
  before Regista, so the installation connects it by itself. Regista also works without Claude, by hand.

## One command

Quit Claude Desktop (⌘Q), open Terminal, paste this line and press Return:

```
git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh
```

The installation checks the Mac, downloads the engines that suit its memory (every file has a fixed version and a
verified SHA-256), builds the app on your Mac, puts it in Applications and connects Regista to Claude Desktop or
Claude Code, whichever it finds. It asks a few questions: press Return for the suggested answer. If Homebrew is missing,
it offers to install it and may ask for the Mac's password. At the end it prints a summary: what it found, what is
missing, how to start.

If someone sent you a `regista-….zip` file, open it and double-click `INSTALLA.command`: it does the same thing,
without Git.

To check the installation at any time:

```
~/code/regista/scripts/doctor.sh
```

The last line should say "All good". Otherwise, under each problem there is a line that says how to
fix it.

## The tiers

Regista picks a tier from the Mac's memory. Each tier adds to the one before.

- **Base** (8 GB): record, cut, captions, clean voice, graphics and export. That is the whole reel.
- **Medium** (16 GB): more precise word timings, so cleaner cuts and captions; your cloned voice for voice-overs (it
  uses about 8 GB while it works); animated graphics in HTML; 3D titles with Blender, if you agree to install it.
- **Pro** (32 GB and more): training your voice (about two hours) and local, free generation of images, clips and music
  with ComfyUI. ComfyUI does not install by itself: you set it up by hand, following the steps Regista shows.
- **In the cloud**, on any tier: paid generation with Higgsfield. It is optional, needs an account, and every generation
  shows its cost and waits for your approval.

Shotcut, to finish an edit outside Regista, is offered on every tier. The Italian and French aligners are licensed for
non-commercial use only: the installation asks before adding them. Without them Regista still transcribes, with
whisper.cpp.

The full list, with sizes and licences, is in [docs/reference/engines.md](https://github.com/arkad-consulting/regista/blob/main/docs/reference/engines.md).

## Installing an engine later

Open **Settings › Engines** (also from the **Engines** icon at the bottom of the bar on the left). At the top,
**This Mac** shows **Memory**, **Tier** and **Free space**. Below, the engines are grouped by tier, each with its state:

- **Installed** or **Part of macOS**: ready.
- **Install**: Regista downloads and installs it. It is a job: the progress and **Cancel** are in **Jobs**, in the
  status bar. If the engine has a non-commercial licence, Regista shows it to you first.
- **How to install it**: an engine you set up by hand (ComfyUI and its models). Regista shows the steps.
- **Remove…**: deletes the engine's files, after telling you what stops working.

**Force tier** changes the tier: **Automatic** picks it from the memory. A higher tier shows and installs engines that
can slow the Mac down or stop for lack of memory.

## Connecting Claude

Open **Settings › Claude**.

- **Connection** says whether a Claude is connected to the app right now.
- Under **Claude Desktop**, press **Connect Claude Desktop…**. Regista tells you what it adds to Claude's configuration
  (it keeps everything else and makes a backup first); confirm with **Connect**. Then quit Claude Desktop completely
  (⌘Q) and open it again.
- Under **Claude Code**, press **Connect Claude Code…**, confirm, and open a new Claude Code session.
- If a row says **Connected to another copy of Regista**, press **Repoint to this app…**: Claude was using another copy
  of the app and may not know the new commands.
- **Copy the instructions** copies a text to paste into the instructions of a Claude Desktop project: every conversation
  in that project will know how to work with Regista.

The first time Claude uses Regista, Claude Desktop asks for permission: choose to always allow it, or it will ask at
every step. Open Regista before talking to Claude, so you watch the work live.

## Updating

Run the installation command again, or:

```
~/code/regista/scripts/install.sh
```

It fetches the latest version and rebuilds the app. Your projects, settings, downloaded engines and voice stay as they
are. If you installed from a zip file, open a newer zip and double-click its `INSTALLA.command`. After updating, quit and
reopen Regista and Claude Desktop.

If something goes wrong during the installation, see [Troubleshooting](troubleshooting.md).
