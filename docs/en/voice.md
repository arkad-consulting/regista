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

## 1. The first time: clone your voice

Open the **Voice** activity. Until you have a voice, the panel is the way into cloning it: **Clone your voice** and,
under **How it works**, the four steps with how long each takes.

1. **Choose the language**: each language has its own voice. Start with the language of your videos; add the others
   later.
2. **Read the neutral tone**, about ten minutes: as soon as it is done, the voice is ready to use.
3. **Add more tones**, optional, about two minutes each.
4. **Train the voice**, optional, usually a couple of hours: it makes the voice more faithful. It needs a Mac with at
   least 32 GB (Pro tier).

Press **Start cloning your voice**. The **Your voices** window opens.

- If there is no profile yet, the window asks for **Your name**, then **Create the profile**. The name is used in the
  consent sentence.
- On the left are the four languages, always all four, each with its state: **to record**,
  **training in progress**, or "ready" or "trained" with the number of tones. Pick the language to record.
- For a language without a voice, the right side recalls the same four steps. Press **Start**.
- Regista explains in a few lines what happens to your voice. The first recording starts with a consent sentence read
  aloud, with your name. Once you have read it, press **Got it, record**.
- The script of the **Neutral** tone, with the consent sentence at the top. Leave five seconds of silence at the start
  and a short pause between lines. If you make a mistake, stop for a moment and read the whole line again. Press
  **Record** to start and **Stop** to finish. If you recorded with your phone, use **Import an audio file…** instead.
- Regista compares the recording with the script and shows **Lines heard**, **Clips kept**, **Minutes recorded** and
  whether it recognised the **Consent**. At least seven lines out of ten are needed. If some are missing, the
  **Lines to read again** list says which: press **Record again** and read them in a new recording of the same tone,
  which adds to this one (or **Continue anyway**). **Try the voice** plays the result right away; **Continue** takes
  you to the language's page.

After the neutral tone the voice is already usable: Regista imitates it from a reference taken from your recording.
You can close the window at any time with **Close** and pick up later where you left off.

## 2. Manage voices: more tones, more languages

Once you have a voice, the **Voice** panel opens on the text, and cloning takes little room:

- **Manage voices…**, at the top, opens the window on the language you are using. The same button is in
  **Settings › Profile and voice**.
- The dashed + **Language** chip, next to the languages, opens the window on the first language without a voice yet.
- The dashed + **Tone** chip, next to the tones, opens the window on the chosen language's tones.

In the window, the page of a language with a voice shows the **Tones**: **Neutral**, **Enthusiastic**, **Serious**,
**Calm**, **Playful**, **Alarmed**, **Sad**. A recorded tone has a check mark and its recorded minutes; a tone still to
record is dashed and says how long its block takes ("Record · ~2 min"). A click on a tone opens its script; on a tone
already recorded it adds another recording. You record and check it like the neutral tone, and the
"‹ Français, all tones" link at the top takes you back to the language's page. Tones are optional: record only the ones
you need.

A voice trained outside Regista, with no recorded minutes in the profile, shows as "trained · 1 tone", with the
**Neutral** tone checked and no minutes.

## 3. Training (optional)

Training makes the voice more faithful. It is on the language's page, under **Training**: Regista says how long it will
take, usually about two hours. Press **Train the voice**. You can close the window and keep working: training goes on
in the background, with its progress on the same card. Keep the Mac on and plugged in.

If the button is grey, the reason is written under it: a Mac under 32 GB, the neutral tone not recorded yet, not enough
usable minutes yet, a training already running.

While a voice is not trained and this Mac can train it, the **Voice** panel says so in a single line:
**The voice is not trained yet: training makes it more faithful.** with the **Train…** link, which opens the language's
page. The × hides it for that language.

## 4. From text to voice-over

In the **Voice** panel, **Text** tab:

1. Write the text. A blank line separates paragraphs: each paragraph becomes one clip. Write numbers in words and brand
   names as they are spelled (the pronunciation is fixed in the **Pronunciation** tab).
2. Choose the **Language** and the **Tone**. Only the languages and tones your voice already has show up.
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
  so in the post description (for example "AI-generated voice"). The **Voice** panel reminds you under the text. When a
  generated voice is heard on the timeline, the **Export** screen shows, with the checks, the row **AI-generated voice**
  with the sentence to paste and a **Copy** button; after the export the same note stays under **Last export**. When
  Claude does the export, it tells you in its answer.

If something does not work, see [Troubleshooting](troubleshooting.md). The rest of the app is in the
[Regista guide](user-guide.md).
