# Recording your voice

Regista can say a text in your own voice, cloned on your Mac: for faceless videos, or to add a sentence you did not
record. The voice belongs to a profile, that is to you. Regista comes with no profiles and no voices: everyone records
and clones their own.

## What you need

- A Mac with at least 16 GB of memory (Medium tier) and the voice engine, VoxCPM2, which the Medium-tier installation
  adds by itself. If it is missing, the **Voice** panel says **Cloned voice not available** and why, with **Install…**
  when it can be installed.
- For the optional training, a Mac with at least 32 GB (Pro tier). Without training the voice works all the same.
- A quiet room with curtains or a sofa to soak up the echo, and always the same distance from the microphone. A phone
  with an external microphone is perfectly fine: record there, then import the file.

## 1. The profile

Open the **Voice** activity (or **Settings › Profile and voice**). If there is no profile yet, Regista asks for
**Your name**, then **Create the profile**. The name goes into the consent sentence.

## 2. The guided recording

In the **Voice** panel press **Record your voice…** (once you have a voice, the button is **Record…**). A window opens
with six steps on the left.

1. **Profile**: the profile you are recording.
2. **Language**: the language you record in. Each language has its own script and its own voice; start with the one
   you will make most videos in. Add the others later with **Change language**.
3. **Consent**: Regista explains in a few lines what happens to your voice. The first recording starts with a consent
   sentence read out loud, with your name. When you have read it, press **Got it, record**.
4. **Record**: the script of the first block, the **Neutral** tone, with the consent sentence at the top. Leave five
   seconds of silence at the start and a short pause between lines. If you make a mistake, stop for a moment and read
   the whole line again. Press **Record** to start and **Stop** to finish. If you recorded on your phone, use
   **Import an audio file…** instead. The neutral block takes about ten minutes.
5. **Check**: Regista compares the recording with the script and shows **Lines heard**, **Clips kept**,
   **Minutes recorded** and whether it recognised the **Consent**. At least seven lines out of ten are needed. If some
   are missing, the **Lines to read again** list says which: record them in a new recording of the same tone, which
   adds to this one. **Try the voice** lets you hear the result straight away; **Continue** moves on.
6. **Voice and training**: after the neutral block the voice is already usable. Regista imitates it from a reference
   taken from your recording. Here you see the **Tones** (**Neutral**, **Enthusiastic**, **Serious**, **Calm**,
   **Playful**, **Alarmed**, **Sad**): each has a block of about two minutes, which you record with
   **Record this tone**. The more tones you record, the richer the voice.

You can close the window at any time with **Close** and pick up later from the same point.

## 3. Training (optional)

Training makes the voice more faithful. You find it at the bottom of the last step, under **Training**: Regista says how
many minutes you recorded, how many are needed and how long it will take, usually about two hours. Press
**Train the voice**. You can close the window and keep working: training goes on in the background. Keep the Mac on and
plugged in.

If the button is greyed, the reason is written below it: a Mac under 32 GB, the neutral block not recorded yet, not
enough usable minutes yet, a training already running.

## 4. From text to voice-over

In the **Voice** panel, **Text** tab:

1. Write the text. A blank line separates paragraphs: each paragraph becomes one clip. Write numbers in words and brand
   names as they are spelled (the pronunciation is fixed in the **Pronunciation** tab).
2. Choose the **Language** and the **Tone**. Only the tones you recorded show up.
3. **Listen** plays the selection, or the paragraph where the cursor is, without touching the edit.
4. Under **On the timeline** choose **After the last voice** or **At the playhead**, then press **Put on the timeline**.
   Each paragraph becomes a clip on the Voice track, with the timing of every word.
5. **Captions from this text** makes the captions straight away: the words already have their timing, nothing needs to
   be transcribed.

Every step can be undone with ⌘Z. You can do the same in Simple, in the **Voice** step, once your voice is ready.

## The pronunciation list

In the **Pronunciation** tab you tell the model how to read a word it gets wrong, a brand name for example. The text,
the script and the captions stay spelled as they are: only the way the voice says the word changes.

- In **Word (as written)** type the word, in **Read as** how it should sound, then **Add**.
- Under **To confirm** you find the suggestions of the automatic pronunciation check. Listen to them first, then
  **Confirm** or **Discard**.

Each language has its own list.

## Consent and transparency

- The first recording of each language starts with the consent sentence, read by you with your name.
- The recordings and the voice model stay on this Mac, in your profile. They never go into the repository or into a
  package you share.
- Regista only uses the voice of the active profile. Switching, adopting or deleting a profile is done by you, in
  **Settings › Profile and voice**: Claude cannot do it.
- A profile copied from another Mac stays locked until you adopt it with **It's mine: use it here**.
- To delete everything: **Settings › Profile and voice**, **Delete my profile and my voice…**. Recordings, clips and
  models go to the Trash.
- A generated voice is content made with artificial intelligence. When you publish a video with your cloned voice, say
  so in the post description (for example "AI-generated voice"). The **Voice** panel reminds you under the text; when
  Claude does the export, it tells you in its answer. The **Export** screen does not repeat it for now.

If something does not work, see [Troubleshooting](troubleshooting.md). The rest of the app is in the
[Regista guide](user-guide.md).
