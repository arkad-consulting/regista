import Foundation

/// Step-by-step editing recipes with the house rules, for an agent driving Regista. The MCP server lists
/// them as prompts (`prompts/list`, `prompts/get`); `recipe.get` returns the same text as a tool result,
/// for clients that do not surface prompts to the model. House rules come from the approved talking-head reels
/// (the WeSites test of 2026-10-26) and the editor's feedback on them — keep them in sync with the README.
public struct Recipe: Sendable {
    public struct Argument: Sendable {
        public var name: String
        public var description: String
        public var required: Bool
    }

    public var name: String
    public var title: String
    public var description: String
    public var arguments: [Argument]
    let body: String

    /// The recipe with the given arguments stated at the top (unknown or empty ones are ignored).
    public func text(_ arguments: [String: String] = [:]) -> String {
        let given = self.arguments.compactMap { a -> String? in
            guard let v = arguments[a.name]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return "- \(a.name): \(v)"
        }
        return given.isEmpty ? body : "Inputs:\n" + given.joined(separator: "\n") + "\n\n" + body
    }
}

public enum Recipes {
    public static let all: [Recipe] = [talkingHeadReel, screenTutorial, voiceOverVideo, reelGraphics]

    public static func named(_ name: String) -> Recipe? { all.first { $0.name == name } }

    public static let talkingHeadReel = Recipe(
        name: "talking-head-reel",
        title: "Talking-head reel (9:16, captioned)",
        description: "Edit a raw talking-head take (the speaker repeats each script line until it comes out right) into a captioned 9:16 Instagram reel in the approved WeSites style, check it by looking at frames, and export mp4 + srt + Shotcut project.",
        arguments: [
            .init(name: "footage", description: "The raw take (path from media.list).", required: false),
            .init(name: "script", description: "The script the speaker read, one line per take (a .md/.txt from media.list).", required: false),
            .init(name: "brand", description: "Brand or product the reel is for (e.g. WeSites).", required: false),
        ],
        body: """
        # Talking-head reel — recipe and house rules

        You edit with the regista tools only. Times are seconds on the timeline unless a tool says "source".
        Every edit is undoable (history_undo). Nothing is on disk until project_save / export_*.

        ## Steps
        1. Find the material: media_list (footage = kind "video", script = the .md/.txt next to it); text_read the
           script to know what was meant to be said (names, numbers, the hook). media_list also says where to
           save: projectsDirectory for the project, exportsDirectory for the mp4 / srt / mlt.
        2. project_new {name, directory: <projectsDirectory>, kind: "talking-head-reel"} (default 1080×1920, 30 fps),
           then media_import the take.
        3. media_extractAudio → transcript_run {language: "it" | "fr" | "en" | "pt"} (word timings; cached). Captions follow
           the transcript language: its stop words (a chunk never ends on an article, preposition or conjunction —
           captions_get reports any in stopWordEnds) and how numbers are written (French: "10", "9,2", "11 000", "20 %").
        4. script_set {path: <script>} (the numbered lines of its "## Testo" section; or pass text, one line per take).
           No script (a skit, an interview, an improvised spot): script_fromTranscript {dryRun: true}, read the lines
           (repeated readings are already folded into one line; relativeDB far below 0 = an off-mic voice), then
           script_fromTranscript {drop: [the chatter lines that are not part of the video]}.
        5. takes_list: every reading of every line; the best complete take is picked per line. WRITE THE KEPT-TAKE
           LIST AS TEXT for the user (line → take, its words, in/out) before building. If a pick is wrong (a
           stumble, a cut-off ending, a weaker reading) use takes_select {line, take}.
        6. edit_autoCut: one linked picture+sound clip per kept range (long pauses inside a take removed; ~0.2–0.3 s
           between lines; filler words stay: step 6b). After changing picks later:
           edit_autoCut {replace: true, picks: [{line, take}]} (the new picks and the cut are one undo step; or
           takes_select, then edit_autoCut {replace: true}), then redo steps 6b–10.
        6b. Filler words: transcript_fillers (it changes nothing). Tell the user the sure ones (hesitations: «ehm», «euh»,
           «um») as a count with the seconds they take, and the maybe ones («allora», «so», «du coup» standing alone)
           and the repeats («il il») as a list in words. When the user agrees, transcript_deleteWords with its
           delete.sure as it is (one undo step); a maybe word or a repeat only when the user names it (send only those
           entries of delete.maybe.ranges / delete.repeat.ranges). The list is often empty: the speech engines leave
           most hesitations out of the text, and the long pauses edit_autoCut removed are where they were.
        7. audio_clean (defaults: DeepFilterNet + voice chain, −15 LUFS, true peak ≤ −1.5 dBTP). Expect ≈ −15 LUFS
           and lag ≈ 0 in its result. audio_clean {restore: true} puts the original sound back if the user prefers it.
        8. faces_track {assetId}, then edit_punchIns {by: "line"}: a base framing alternating with a punch-in to hide
           the jump cuts, the framing changing when the script line changes. With no crops given the crops come from
           the face track, per shot: every detected face kept in frame (two speakers, a child in the speaker's arms), room
           above the hair, never a head cut — check with faces_checkFraming (must pass). The WeSites selfie take
           (1080×1920, the approved look) uses preset "wesites-selfie" instead. Then the light grade: clip_set
           {trackId: <video track>, brightness: 0.02, contrast: 1.06, saturation: 1.08}.
        9. Choose caption keywords (the words that get the pink box): about one per caption chunk's worth of
           meaning — 1–2 per script line, ≈12–16 for a 45 s reel. Prefer the hook word, product/brand names,
           numbers, and the word that carries each line's point (a threat, a benefit, the call to action).
           Never stop words (articles, prepositions, "è", "e", "non"). Write them in display form: UPPERCASE as
           shown, numbers as the numerals step makes them ("nove virgola due" → "9,2", "undicimila" → "11.000").
        Caption style (effects_catalog category captions says when to use each): talking-head-v1 is the approved
            default; propose another only when the brand or the user asks for it — elegant-serif (cream serif italic,
            one calm phrase at a time: premium, beauty, interiors, storytelling), bold-keyword (bold white sans on up to
            two lines, keyword in the brand accent: modern creator / tech / explainers), ghost-karaoke (whole phrase
            shown, next words ghosted, lit word by word: fast conversational creators). Keywords match any case; the
            mixed-case styles show them in the accent colour without a box. Switch later with captions_setStyle {style}.
        10. captions_generate {style: "talking-head-v1", keywords: [...], fixes: {...}}. With a face track, chunks that
            would cover a face (any face: a child in the arms too) move to another band or beside it, or split
            shorter; captions_checkFaces must pass. Read its preview (and
            captions_get for the full list): fix misheard or wrongly split words with fixes (display form,
            {"WRONG": "RIGHT"}, "" removes a word), spelled as in the script — see the glossary. If a keyword
            never appears in the preview, it does not match a displayed word: use the displayed spelling.
        11. Look at the result: frame_contactSheet (12 frames over the reel) and frame_render on suspicious
            moments. Check: every face is fully in frame and framing alternates; captions sit in the band at
            ~65–75% of the height unless moved off a face, never over any face or mouth, never in the bottom 20%
            or top 8%; every caption
            word is spelled right (names!); keyword boxes are on meaningful words; no black or frozen frames;
            no "stale captions" warning. Fix what is wrong (takes_select / transcript_deleteWords for a stumble
            or repeated word, captions_setKeywords, captions_generate with fixes, edit_punchIns) and look again.
        12. Export: rules_check first (fix what fails), then export_render {path: <exportsDirectory>/<name>.mp4, preset: "9:16"} (check frames, duration and
            loudness in the result: −15 ±0.5 LUFS, true peak ≤ −1.5), export_srt {path: …/<name>.srt},
            export_mlt {path: …/<name>.mlt} (Shotcut project), then project_save.
            Cover (once per reel): cover_set {time: a frame with the face and the point, title: 3–5 words — ask the user
            or take the hook's words, place} then cover_make {} (the PNG next to the exports, <name>-cover.png); when its
            check fails, the cover_set it names (another place, or fewer words). export_render {appendCover: true} holds
            it for the last 3 frames when the user picks the thumbnail in the phone app.
        13. Verify the file: captions_checkTiming {path: <mp4>} (pass, words on their frame, band inside),
            captions_checkFaces and faces_checkFraming (pass), and media_checkSync {path: <mp4>} (lag < 1 frame). Finish with a short report: takes kept, keywords,
            fixes, what you corrected after looking, the numbers, and the paths of the mp4 / srt / mlt.
        14. Graphics (only when asked: titles, cards, B-roll inserts, sound effects, music): recipe_get
            {name: "reel-graphics"} and follow it on top of the finished edit, after step 11 and before step 12.
        15. Presenter rhythm (the cards of step 14, so before step 12): read the script and pick ONE structure; tell the
            user which, with one line why.
            - A list: the script counts its points ("three mistakes", "first… then… last").
            - A workflow: the script walks through doing something step by step (open, write, check, publish).
            - A product: the script shows one product part by part (the problem, how it works, the result).
            The rhythm of each point: the face says it → a number or keyword card on the word that names it → a proof
            card on the words that back it (a screen, a figure, a quote) → the face again before the next point.
            Timing: a card starts on its word (motion_add start = that word's start in transcript_timeline, ±1
            frame; sync: true for checklist rows), stays while the idea is said (keyword 1–2.5 s, proof 2.5–4 s) and
            is gone before the next point. At most 2 cards in any 10 s (these numbers replace the ~4 templates of
            the reel-graphics recipe: 3–4 points in a 45 s reel, ~8 cards). The face alone: the first 2 s (a hook
            title may be there), at least 1.5 s between two points, the last line (the call to action). A point said
            in under 3 s gets the keyword card only; one with no proof gets no proof card.
            Never over the mouth: faces_track first, then motion_add (without band or position a banded template
            takes the first place that leaves the face free); read faceCheck and the warnings in its result, and
            give a position when it covers the face; cards sit in the top band (y 110–640), never in the caption
            band; a proof that fills the frame replaces the face for 4 s at most. graphics_checkLayout and
            faces_checkFraming must pass; frame_render the first frame of every card.
            What serves each beat (effects_catalog gives the fields; keep one treatment for all the points):
            - number or keyword: annotation-chip ("02 · Deadlines", position [540, 330]: above the head, the same place
              each time; its default point is beside a centred face's mouth);
              kicker-headline (kicker "01 / 03", the keyword) for two points at most; counter once, when the point IS
              a number.
            - proof, a screen: the user's own recording or screenshot as an insert (overlay_add with fullFrame), inside
              device-frame when it is a vertical app or site (the template frames whatever is under it); stacked-pages
              (screenshots of articles, documents); before-after (two real pictures).
            - proof, a figure: stat-card (a metric said in passing), chart (figures that compare or grow).
            - proof, a quote: quote-card (a customer's words, a review, a line of a report).
            - a workflow's steps at a glance, once: checklist (ticks on the words), card-row, progress-rows.
            - a product's part: annotation-chip with a target (the part named), cursor on a screenshot (a real
              recording has its own), callout_add on the thing the voice names.
            Real material only: screens from media_list, figures and quotes as the script says them. mock-ui is a
            generic panel: it may illustrate an editing step, it is never proof.

        ## Moving captions and graphics by hand (when the user asks)
        The user can drag them on the preview like text in an Instagram story; the same moves are commands (pixels of the
        1080×1920 frame; each call is one undo step):
        - "sposta i sottotitoli più in alto a sinistra" / "move the captions up and to the left": the whole track,
          captions_place {align: "left", x: 60, y: 300} (x = the line's left edge, y = its vertical centre; the usual
          band centre is y 1344; y 300 sits just under the Instagram account bar). Relative: captions_place {dy: -200}.
          Centred again: captions_place {align: "center", x: 540}.
        - "solo quello a 0:12 più in basso" / "only the one at 0:12 lower": captions_place {time: 12, dy: 150} (or
          chunk: <index from captions_get>); "più grande" / "bigger": add scale 1.3 (1 = the style's size, 0.3…4).
        - Titles, stickers, the logo: frame_elements {time} says what is on that frame and where (box, centre, scale,
          rotation), then clip_place {clipId, x, y (the centre) | dx, dy, scale, rotation}; its animation follows.
        - "rimettili come prima" / "put them back": captions_place {reset: true} (one chunk: + time or chunk);
          clip_place {clipId, reset: true}.
        - A chunk placed by hand stays there even over a face (captions_checkFaces reports it as a warning, not a
          failure): say so if it happens. Lines are kept inside the frame; read the warnings for the Instagram zones
          (top 110, below 1540, right 120 px) and the caption band, then look with frame_render at that time.

        ## House rules (do not re-litigate)
        - Approved look (reel test 1, 2026-10-26, "top"): Impact uppercase captions, black outline, keyword white
          on a pink #FF2D6F box, word-by-word reveal, 2–3 words per chunk = caption style talking-head-v1; fixed
          face crop + alternating punch-ins; light grade; ~0.2 s between sentences. Keep it, build on top.
        - The speaker repeats a line until it comes out right: keep the cleanest complete take (no stumble, no
          restart, complete ending) — usually the last complete one; drop fillers ("ehm", "allora") and false starts.
        - Pacing: natural, gaps 0.2–0.7 s, keep breaths, cut stumbles and restarts; jump cuts on the same framing
          are fine because every other line is punched in.
        - Voice: one linear normalization to −15 LUFS, peaks ≤ −1.5 dBTP (audio_clean does exactly this — never
          normalize twice or add other loudness processing). Very quiet, roomy takes cannot be fixed by processing.
        - Export for Instagram: 1080×1920, 30 fps, H.264 High, yuv420p, faststart, AAC 48 kHz 192k (export_render
          does it). Keep captions and key graphics out of the bottom ~20%, the right edge and the top ~8%.
        - No music baked in (the user adds trending music in the Instagram app).
        - Glossary — Whisper gets these wrong, write the right form: Claude2 / Cloud Duet → Claude Duet;
          Antropic → Anthropic; Game Face / Hugging Fees → Hugging Face; Cloud Code → Claude Code. Brand and
          product names follow the script's spelling (e.g. WeSites, WordPress, PHP). "IA" (Italian for AI) is
          often split or glued wrong ("AL" + "IA" for "all'IA"): fix it so the caption reads like the script.
        - Never deliver a bare edit: before the export the user sees, read effects_catalog and propose 6–12
          items that fit the lines (one line each: what, where, why) as a yes/no list; apply what they accept.
        - Captions sit on one baseline (captions_setStyle wordAlign "baseline"): words of different heights must
          not jump up and down inside a line.
        """)
}

extension Recipes {
    public static let reelGraphics = Recipe(
        name: "reel-graphics",
        title: "Graphics on a reel (titles, cards, inserts, music, SFX)",
        description: "Dress an edited talking-head reel with the graphics layer: a hook title, a few cards in the top band, AI B-roll inserts, sparse sound effects on beats, an optional ducked music bed; check layout, loudness and timing; export mp4 + Shotcut project.",
        arguments: [
            .init(name: "brand", description: "Brand kit (wesites, arkad).", required: false),
            .init(name: "brief", description: "What the graphics must say (the cards brief, if any).", required: false),
        ],
        body: """
        # Reel graphics — recipe and taste

        Start from a finished edit (talking-head-reel: cut, voice at −15 LUFS, punch-ins, captions). Graphics are
        ordinary clips on overlay tracks: timeline_move / timeline_trim / timeline_delete and history_undo work on them.

        ## Steps
        1. brandkit_apply {kit} (arkad / wesites / cafe-atelier / a user kit: brandkit_list). It brings the title presets
           (hook, hookLight, question, kicker, card, stat, chipOK, chipWarn, word), colour roles (primary, ink, paper,
           accent, success, highlight) and font roles (display, text, mono), and recolours the captions (keyword box =
           highlight). Re-run it after captions_generate, or any time to switch kit: preset titles and the logo follow.
           Brand logo: only as a closing card at the end, logo_add {start: <last word's end + 0.4>, duration} — never at
           the start, never the whole reel in a corner (the editing rules check it); brandkit_check verifies keyword
           colour, logo zone and fonts on a rendered frame.
        2. Read the transcript (transcript_timeline) and pick the beats: the hook word, each number, the product
           name, the call to action. Graphics land ON the word (title start = word start, ±1 frame).
        3. Hook (0–4 s): one title. graphics_blenderTitle {line1, line2, start: 0, duration: 4, scale: 0.85} for a real
           3D title (EEVEE, ~1–2 min once, cached), or title_add {preset: "hook"} for flat type. Never both.
           Text behind the person (once per reel, the hook only): matte_track {from: 0, to: <hook end>}, then title_add
           {preset: "hook", background: "none", big type (size 120–150) centred just above the eyes so the head
           passes in front of it, behindSubject: true}; graphics_checkBehindSubject {clipId} must pass. Not on cards,
           not on captions, not over an insert (there is no person there: the text is simply drawn).
        4. Cards: title_add with presets (kicker = mono label, card = text block, stat = one big number, chips =
           ✓ / ✕ states) or graphics_hyperframes {folder: the HyperFrames project folder, start} for anything that
           needs layout or UI motion (HTML/GSAP, transparent, pinned CLI). One idea per card, ≤ 7 words, on screen 2–4 s, pop in (default) and fade out.
        5. Inserts: overlay_add {path, start, duration, fullFrame: true} for AI B-roll that illustrates a line (a
           restaurant, a salon). 0.8–1.6 s each, on the words they illustrate; clip_set grade (contrast 1.04,
           saturation 1.05) and effect_add sharpen 0.5 for 464-px shots scaled up by the compositor (not needed after
           generate_upscale). Captions stay on top by themselves.
           Generate or reuse: reuse footage and existing shots first. Generate B-roll only for an abstract or
           illustrative beat the footage cannot show (a metaphor: "il motore sotto ogni sito", a server room, a
           plugin maze), never for something the speaker can show or say on camera. ComfyUI first (free, local):
           generate_run {kind: "image", prompt} → generate_run {kind: "video", refs: [the still], duration: 3,
           prompt: the motion} → generate_upscale (1080×1920, 30 fps) → overlay_add {path, fullFrame: true}. Pass
           keepRunning: true while chaining and leave it off on the last job (ComfyUI is stopped after use). A clip
           takes ~5–10 min, an upscale ~4–7 min: wait: false + generate_status if you have other work. generate_providers
           says which provider can run which kind on this Mac. Higgsfield (paid) only for the final hero shot and only
           with the human's approval: generate_estimate (kind "upscale" prices an upscale), ask them to approve it in the
           Regista app (the approval is good for exactly that request, once), read the token from generate_list,
           generate_run {provider: "higgsfield", approval}. The budget is 2 Higgsfield calls in total — never ask for
           drafts there.
        6. Catalog first: effects_catalog lists every effect, look, style and motion template with description (what it
           looks like), useWhen, avoid and fields with examples — the same items the user sees in the app's Graphics
           panel. For each beat picked in step 2, propose 1–3 fitting items to the user with a one-line reason
           ("23:46 → counter over a dimmed shot: the time is the hook"; "the three steps → checklist card, ticks on the
           words"), never a menu of everything. effects_preview {item, fields, at} renders one on a throwaway copy
           (frames: 6 for an animated template) when they ask "show me"; apply with the command and params
           effects_catalog {item, fields, start} returns. Motion templates (category templates): motion_add {template,
           fields, start, duration, band} — brand colours and fonts by default; templates that go behind the speaker
           (orbit-carousel, card-stack, marquee rows) need matte_track over their window first. One template at a
           time, on screen 2–5 s, max ~4 per reel; data on charts and counters must be real.
           Accents (optional, max 2 per reel): effect_add punchZoom on the strongest word, transition_add flash or
           whip at a real section change (into or out of an insert), blur for a soft change or into a graphic card.
           Layouts (category layouts, layout_speaker): letterbox-headline when the footage is landscape or the reel's
           promise should stay on screen (one headline); split-card while a graphic or UI must sit beside the face
           (put the graphic in the returned freeArea); pip-bubble over full-frame B-roll or a graphic (brollAssetId);
           inset-frame for 'behind the edit' looks, with status_add (REC timer, one chapter per script section) and
           meters_add on a sound beat around the card — or all of it at once with style_apply {style: "console",
           chapters}. An object held in the open hand: hands_track over the gesture, a logo/sticker clip, then
           clip_follow {target: "hand", hover: 90, spin: 2.5, halo: true} — the brand logo or a generic icon, never a
           third-party logo; clip_follow {target: "face"} for a tag that rides with the head.
           Look: look_apply {look, amount} on the whole picture — one look for the reel at 40–70 % (film, golden,
           airy suit talking heads; graphite/ink for a single dramatic beat on one clip). adjust_set for corrections
           (exposure, shadows, warmth: small values, ±0.1–0.3). Never stack a look per clip.
           Speed (clip_speed): slow motion or a hero ramp on a B-roll insert or a gesture, a freeze frame on the
           punchline (0.6–1.2 s), reverse only as a short visual joke. Not on talking parts: the sound is stretched
           (pitch kept) and slow speech reads as a mistake. Run captions_generate again after any speed change.
           Stickers (sticker_add): one on a punchline, 1–1.5 s, top band. Callouts (callout_add circle / arrow /
           underline / box / highlight): on the thing the voice names, one at a time; tutorials: on clicks.
           progress_add for tutorials and lists. glitch: a few frames on a hard cut, never a sentence. chromaKey
           only for real green-screen overlays.
           Logo (logo_animate): a sting at the very end only (outro) — logo intros and a spinning logo on every cut
           are out. The outro starts after the last spoken word with 0.3–0.6 s of clean picture (pass start: the last
           word's end + 0.4 s, extend the picture or let it end on black): the closing frame carries the logo alone,
           never a caption, a header title or a card over the last line. Beat sync (edit_beatSync, needs a music bed): punches on
           the downbeats of one section, not on every beat of the reel.
           One-click styles (style_apply energico / pulito / tutorial) bundle these moves as one undo step: use one
           as a starting point when the user asks for "a style", then tune.
        7. Sound effects: sfx_library {group?: whoosh | ui | pop | impact | …} (the shipped bank, made in code), then
           sfx_add {name, at, volume}; a whoosh's loudest moment is `peak` s into it. sfx_onCuts puts a quiet whoosh on
           the cuts in one step (remove: true takes every effect off). Whoosh on title/insert entrances, pop on
           chips/cards, soft click on UI beats, one bass impact on the key number or the final line. Volumes 0.2–0.3.
        8. Music only when asked (Instagram users add trending audio in the app): audio_addMusic {path} — levelled to
           −22 LUFS, ducked −12 dB under the words (≈19 dB under the voice), faded in and out.
        9. Look: frame_contactSheet {times: [the graphics beats]} and frame_render on each card's first frame. Check:
           nothing in the caption band (y 1230–1460), nothing above y 110, below y 1540 or in the right 120 px;
           text readable (≥ 28 px), no card over the mouth, no two cards at once, no gimmicks.
        10. Checks: graphics_checkLayout (pass = caption band clean), rules_check (fix what fails), export_render {path, preset: "9:16",
            loudness: −15} (−15 ±1 LUFS, true peak ≤ −1.5), audio_checkDucking (music ≥ 15 dB under the voice),
            sfx_checkOnsets {path} (every effect within 1 frame), media_checkOverlay {path, trackId: <inserts>}
            (inserts exactly in their windows), captions_checkTiming, effects_check {path} (every effect visible in
            its window, look at 0 = identity, retimed sound on the picture), then export_mlt (Shotcut: overlays,
            titles, music and SFX with gain and ducking; animations, effects, transitions, looks, speed changes and
            callout draw-ons are listed as not exported).

        ## Which layer when
        - Title (title_add, or graphics_blenderTitle for the hook): a few words that ARE the point of the line — the
          hook question, one number, one word that lands ("TUOI."). Type only, from the kit's presets.
        - Card (title_add kicker/card/stat/chip presets, or graphics_hyperframes): context the voice does not say —
          a date, a source, a list of states, a UI moment. A surface (paper or ink box) with a mono kicker on top.
          A single big word over a busy background (hair, a window) goes on a surface too, never bare.
        - Insert (overlay_add fullFrame): the line names something we can show (a pizzeria, a salon) or an abstract
          beat worth a generated metaphor (ComfyUI). Replaces the picture for 0.8–1.6 s, never under a title or
          card; captions stay on top.
        - Motion template (motion_add, effects_catalog category templates): a beat that is structured information —
          a list or steps (checklist), a time or a number (counter, chart), a set of examples or clients (orbit
          carousel, marquee, card stack), an app or a site on a phone (device frame), a label on a person or a
          price (swing tag). Animated, branded, one at a time; it replaces a card, never stacks on one.
        - Behind the subject (title_add behindSubject): the hook title only, once per reel, when the head moves
          through the top of the frame; everything else stays in front.
        - Nothing: most lines. The face and the captions carry the reel.

        ## Layout bands (1080×1920)
        - Top band y 110–640: titles and cards live here (they cover ceiling and hair, never the face). With the
          approved crops the head starts at y ≈ 250: centre small cards at y ≈ 170–230 so they sit on the wall.
        - Face y ~420–1180: keep it clear except for a full-frame insert or one ≤ 1.2 s full-screen stat.
        - Caption band y 1230–1460: reserved for captions, always clean.
        - Instagram chrome: nothing important above y 110, below y 1540, or in the right 120 px.

        ## Taste (house style, do not re-litigate)
        - Abstract fine touches, clean product UI, real motion. No literal decoration, no gimmicks, no stock icons
          of hackers or locks, no emoji rain, no shaking text.
        - Motion: in ~0.35 s spring/expo (pop, slideUp), out ~0.25 s; small offsets; heroes move.
        - Sparse: a reel of 45–50 s carries ~8 cards, 2 inserts, ~25 quiet SFX at most, one hook. When in doubt,
          leave it out. Verified facts only on cards (no invented numbers).
        - Brand fonts and colours from the kit only (font/colour roles, never ad-hoc hex or system fonts); captions
          keep the approved talking-head-v1 look.
        - Sound: SFX sparse and on beats (the frame of the visual event), quiet (0.2–0.3), never two at once; the
          music bed only when asked, always ducked (≥ 15 dB under the voice while someone speaks).
        """)
}

enum RecipeGet: Command {
    static let id = "recipe.get"
    static let summary = "Read this before making any video: the step-by-step recipe and the house rules for a kind of video — talking-head-reel (a person speaking to camera), screen-tutorial (a screen recording made in Regista, with or without the face), voice-over-video (no one on camera: the user's cloned voice over footage, stills and graphics), reel-graphics (titles, cards, sound effects and music on top of an edit). Without name, lists the recipes with what each is for: call it first and pick. The text ends with the editing rules of that kind of video (the user's rule sheets: they always hold, and export.render refuses while one of their checks fails). Returns {name, title, text, kind}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("name", .oneOf(Recipes.all.map(\.name)), "Recipe: \(Recipes.all.map(\.name).joined(separator: ", "))."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        guard let name = p.string("name"), let r = Recipes.named(name) else {
            return ["recipes": .array(Recipes.all.map { ["name": .string($0.name), "title": .string($0.title), "description": .string($0.description)] })]
        }
        let rules = ctx.services.rules.briefing(r.name, language: Rules.language(p))
        return ["name": .string(r.name), "title": .string(r.title), "text": .string(r.text() + "\n\n" + rules), "kind": .string(r.name)]
    }
}
