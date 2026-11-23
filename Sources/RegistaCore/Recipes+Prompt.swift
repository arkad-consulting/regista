import Foundation

/// The recipe of a faceless reel made from one sentence of the person (#144): the plan is confirmed before anything is
/// built, the pictures are the catalog's templates first. Every step was run through regista-mcp (ToolJourneyTests'
/// journey 15 and a real render); keep the tool names and parameters in sync with the commands.
extension Recipes {
    public static let promptToReel = Recipe(
        name: "prompt-to-reel",
        title: "A reel from one sentence (no one on camera)",
        description: "Make a faceless 9:16 reel (20–45 s) from one sentence of the user: at most three questions, then a treatment, a script and a scene plan to confirm; the user's own cloned voice or no voice; scenes from the motion templates, HyperFrames only where no template fits; music, sound effects, captions, checks, export.",
        arguments: [
            .init(name: "sentence", description: "What the user wants the reel to say, in their words.", required: false),
            .init(name: "language", description: "Language of the reel: it, fr, en, pt. Default: the sentence's.", required: false),
            .init(name: "brand", description: "Brand kit (an id from brandkit_list).", required: false),
        ],
        body: """
        # A reel from one sentence — recipe

        You edit with the regista tools only.

        ## Steps
        1. Ask at most three short questions, in one message, and only what the sentence does not say: who it is for,
           what the viewer should do after, the language. Nothing else before the plan.
        2. Look at what there is, without asking: voice_list, brandkit_list, media_list, effects_catalog
           {category: "templates"}.
        3. The plan, in one message, then wait for the yes (or the changes); what the user says yes to is what is built:
           - Treatment: three structures this reel could have, one line each (a question answered, a mistake and its
             fix, a before and after, a countdown…), the one you chose and why. Its subject, goal and turn, the opening
             and how the ending echoes it, and one signature moment at the peak: the one picture that belongs to this
             reel only.
           - Script: one line per beat, 4–10 words (about 2.3 words a second; 20–45 s in all).
           - Scene plan, a table: scene | seconds | words said | what is seen | transition | music | sound. What is seen =
             a template with its fields, a HyperFrames scene in one line, a still, or footage from Media. Music = bed,
             build or stop for each section, as the music choice allows. Sound = a name from sfx_library or none, as the sfx choice
             says. With the faceless-sound choice
             directed, two moments are marked: a near-silence before the turn (0.4–0.8 s: music stop, no word, no
             effect, no tail rings through it) and a J-cut (a sound that starts 0.3–2 s before the
             picture it announces).
        4. project_new {name, directory: <projectsDirectory>, kind: "voice-over-video"} (1080×1920; this recipe follows
           that kind's rules), then brandkit_apply {kit}.
        5. Voice: as in the voice-over-video recipe (voice_preview {estimate: true}, then voice_say {text, language,
           gap: 0.3}). Say the lines up to the turn, then the
           rest with at = the last end + the near-silence. The clips' start and duration are the scenes' times. No
           profile, no voice in that language, or the user prefers none → no voice: music, sound effects and the lines
           as titles carry it.
        6. Scenes, one after the other, no gap, templates first: motion_add {template, fields, start, duration}.
           - The kit's own colour is the stage. background-scene is for the scenes that must contrast: it fades in and
             out, so overlap two of them by 0.5 s and never put one at 0 (frame 0 would be half faded).
           - Opening: title_add {preset, start: 0, animIn: "none", background: "none", band: "middle"}: frame 0 is
             already the thumbnail.
           - No face to leave room for: band "middle" for the banded templates (quote-card, checklist, chart,
             progress-rows). A template is drawn at its own size (clip_place does not scale it): the ones made to sit
             beside a head (script-card, stat-card, annotation-chip) are too small to carry a scene alone.
           - Good carriers: kicker-headline (two at most), counter (one), checklist, card-row, bento-grid, chart,
             before-after, quote-card, progress-rows, timeline-milestones, stacked-pages, logo-tile.
           - Footage and stills from Media: media_import → track_add {kind: "video"} once → timeline_place. A generated
             still only when the plan had it and the local engine makes it (generate_providers, generate_check:
             ComfyUI is free).
        7. HyperFrames, only for what no template does (often the signature moment), and only when your client can write
           a folder: index.html at the scene's size with a transparent background, the kit's colours and fonts, CSS
           animations, nothing loaded from the network. graphics_hyperframes {folder, start, duration, position}; about a
           minute for 3 s. Not installed, or no way to write files → the nearest template, and say so.
        8. Transitions as planned (transition_add, two at most: whip or flash into the turn or the signature moment);
           titles with title_add (background: "none" unless it is a card).
        9. Captions: with a voice, captions_generate {sourceTrackId: <Voce track>, keywords, fixes: the names at the top}, then captions_clear {from, to}
           over the near-silence (a caption stays a moment after its last word). Without one there are no words to caption: each line is a title_add (band "lower") or the scene's own
           text.
        10. Music as planned: a file of the user's (media_list); none → say so, the effects carry it. One audio_addMusic {path, start,
            end, sourceIn} per section: bed = the default level, build = level −19 with fadeIn, stop = no call (end the
            section before it with fadeOut 0.15). Effects: sfx_add {name, at, volume 0.2–0.3} so that the sound's peak
            (sfx_library gives it) lands on the frame of its action: at = action − peak. The J-cut is the one whose start
            falls in the scene before.
        11. Look: frame_render {time: 0}, then frame_contactSheet with one time in the middle of each scene and one on each
            change. Check: frame 0 reads, no flash of another colour between scenes, no empty box, no text under 28 px,
            nothing in the top 110 px or the caption band, the plan's scene on screen.
        12. Is it this reel's own? Compare it with what the templates give by default on five points: structure, opening,
            signature moment, shape of the music, ending. At least three must be its own; fewer → change the weakest.
        13. Checks: rules_check, graphics_checkLayout, then export_render {path: <exportsDirectory>/<name>.mp4, preset:
            "9:16", loudness: −15} and on the file sfx_checkOnsets {path} (every planned sound is in the mix, on its
            frame), audio_checkDucking (with voice and music), captions_checkTiming (with captions). The round of fixes,
            export again, export_srt (with captions), project_save.

        Finish with the report: the plan's scenes, what changed, the verdict of each check, the files; what you could not
        check is "not checked". With a cloned voice, the note the export gives ("AI-generated voice").
        """,
        sheet: "voice-over-video")
}
