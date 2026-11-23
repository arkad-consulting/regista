import Foundation

/// The two recipes for videos without a talking head: a screen recording made in Regista's Registra workspace, and a
/// video carried by a voice-over in the user's own cloned voice. Every step was run through the MCP server on
/// synthetic footage (see RecipeTests); keep the tool names and parameters in sync with the commands.
extension Recipes {
    public static let screenTutorial = Recipe(
        name: "screen-tutorial",
        title: "Screen tutorial (16:9 or 9:16, face optional)",
        description: "Turn a screen recording made in Regista (screen, optional webcam and microphone) into a tutorial: face layout, styled frame, automatic zoom on clicks, drawn cursor, shortcut badges, clean voice, optional captions; check it by looking at frames, export, and reframe for another format.",
        arguments: [
            .init(name: "session", description: "The recording folder (the one with session.json, from media.list). Default: the newest.", required: false),
            .init(name: "format", description: "16:9 (tutorial, YouTube) or 9:16 (reel). Default 16:9.", required: false),
            .init(name: "language", description: "Language spoken in the take: it, fr, en, pt.", required: false),
        ],
        body: """
        # Screen tutorial — recipe

        You edit with the regista tools only. A take recorded in Regista › Registra is a folder under
        Registrazioni holding session.json + screen.mov (+ camera.mov, mic.wav when those sources were on).
        Every edit is undoable (history_undo). Nothing is on disk until project_save / export_*.

        ## Steps
        1. Find the take: media_list → the files named session.json (their folder is the take; the newest unless the
           user names one). The format: the format choice ("project": ask only if unclear; 16:9 for a
           tutorial, 9:16 for a reel).
        2. project_new {name, directory: <projectsDirectory from media_list>, width: 1920, height: 1080, kind:
           "screen-tutorial"} for 16:9 (no width/height = 1080×1920, a 9:16 reel).
        3. recording_import {path: <the take's folder>, faces: true}. It builds the timeline — Schermo (screen),
           Camera above it, Microfono — in sync, and returns recordingId, assets {screen, camera, mic}, tracks and
           cursorInVideo. A take without camera gets the layout "screen"; without microphone there is no voice
           (for a narration afterwards see the voice-over-video recipe: voice_say works on this timeline too).
        4. Face layout (skip without camera): layout_presets shows the boxes for this format. Defaults that work:
           16:9 → layout_apply {preset: "bubble", corner: "bottomRight", shape: "circle", size: "M"};
           9:16 → layout_apply {preset: "stack"} (screen on top, face below). "split" when the face matters as much
           as the screen, "face" for an intro or outro said to camera, "screen" where the face would cover the
           action. Change layout mid-video by calling layout_apply again with from / to (seconds).
           A styled frame (the screen padded on a soft background with rounded corners and a shadow) suits demos
           and reels: add frame: true to bubble or screen. Leave it off for dense UIs that need every pixel.
        5. Zoom on the action: edit_autoZoom {zoom: 1.8} in 16:9; {zoom: 1.4, follow: true} in 9:16 (the frame also
           follows the cursor). It returns the clicks it used. Too busy → lower zoom or call it with clear: true.
        6. Cursor: cursor_style {scale: 1.5, clickRipple: true, hideWhenIdle: true}. It answers drawn: true when the
           take was recorded without the system cursor (then the cursor is redrawn smoothed and bigger); with
           drawn: false the cursor is baked in the video and stays as it is — say so, do not insist.
        7. Shortcuts: keys_overlay {} shows the ⌘ / ⌃ / ⌥ shortcuts that were pressed as badges; allKeys: true also
           shows typing (only when the lesson is about typing). clear: true removes them.
        8. Words (only with a microphone): transcript_run {assetId: <assets.mic>, language}. Then transcript_fillers:
           tell the user the sure fillers (count, seconds), list the maybe ones and the repeats; remove the sure ones
           (delete.sure) when they agree, a maybe or a repeat only when named. transcript_timeline lists every word with an index: remove stumbles and
           false starts with transcript_deleteWords {from, to} (it cuts picture and sound together). Keep the silent stretches
           where something happens on screen; speed up a long wait with clip_speed {clipId: <screen clip>,
           rate: 2…4} instead of cutting through an action.
        9. Voice: audio_clean {} (denoise, −15 LUFS, true peak ≤ −1.5). Run it after the cuts.
        10. Captions, in the person's caption style choice (none: no captions; for a 16:9 tutorial ask first):
            captions_generate {style: <that choice>, keywords: [the names of the buttons and features shown], fixes:
            {misheard: "right"}} (names: as listed at the top). Re-run after any cut.
        11. Look: frame_contactSheet {times: [the click times from step 5, plus the start and the end]}. Check: the
            face never covers what is being clicked (move the bubble to another corner for that range), the zoom
            lands on the right element, captions are readable and clear of the face, no black frame. Fix, look again.
        11b. Before the export: proposals from effects_catalog as the graphics choice says (a yes/no list, one line
            each); titles, cards and sound effects: the reel-graphics recipe; music as the music choice says
            (audio_addMusic, then audio_checkDucking).
        12. Export: rules_check first (fix what fails), then export_render {path: <exportsDirectory>/<name>.mp4, preset: "16:9" | "9:16"} (expect −15 ±0.5
            LUFS when there is a voice), export_srt if there are captions, then recording_check {path: <mp4>}
            (sync, face in its box, zoom on the clicks) and project_save. When the project is 9:16, the cover: cover_set {time:
            the frame that shows the result, title: 3–5 words, place} then cover_make {}; when its check fails, the
            cover_set it names.
        13. Another format from the same edit: project_format {preset: "9:16" | "4:5" | "1:1" | "16:9"} lays the
            face and the frame out again and recomputes zoom and badges; look (step 11) and export again under
            another file name.

        Finish with a short report: the take used, the layout per range, how many zooms and cuts, where the
        files are, and anything you could not do (cursor baked in, no microphone, an engine missing).
        """)

    public static let voiceOverVideo = Recipe(
        name: "voice-over-video",
        title: "Voice-over video (no one on camera)",
        description: "Make a video without a talking head: the script said by the user's own cloned voice (never another voice), over their footage, screen recordings, stills and motion graphics, with captions from the script's exact words, optional ducked music, checked by looking at frames, exported with the AI-voice note.",
        arguments: [
            .init(name: "script", description: "The text to say (a .md/.txt from media.list, or pasted by the user).", required: false),
            .init(name: "language", description: "Language of the voice: it, fr, en, pt (must be one the profile's voice speaks).", required: false),
            .init(name: "format", description: "9:16 (default), 16:9, 4:5 or 1:1.", required: false),
        ],
        body: """
        # Voice-over video — recipe

        You edit with the regista tools only. The voice is the user's own, cloned on this Mac: only the active
        profile's voice can speak, in the languages it was recorded in. Rendering takes time (roughly the length
        of the audio, or more): agree on the text before rendering it.

        ## Steps
        1. Voice first: voice_list. You need engine.available true and the language under languages with ready
           true (it lists the tones that voice can say). Not there → stop and tell the user what is missing, in
           plain words: no profile → profile_create {name}; no voice in that language → they record it in the app
           (the Voce panel's record button, or Settings › Profile and voice: a guided reading); engine missing →
           Settings › Motori. Never offer another voice, never a stock TTS.
        2. The script: text_read it, or write it with the user. One idea per paragraph (a blank line between
           paragraphs: each becomes one clip and one visual beat). Numbers in words, brand names as they are
           spelled. Show the final text and get a yes before step 4.
        3. project_new {name, directory: <projectsDirectory from media_list>, kind: "voice-over-video"} (1080×1920;
           pass width/height for another format).
        4. voice_preview {text, language, estimate: true} gives the paragraphs with their length without
           rendering. To let the user hear one first: voice_preview {text, language, paragraph: 0} returns the
           audio file. A name said wrong → voice_lexicon {language, add: {word, say}} and preview that paragraph again.
        5. voice_say {text, language, tone: "neutral", at: 0, gap: 0.3}. It lays the clips on the «Voce» track
           with word timings (no transcription needed) and returns each clip's start and end: these are your
           beats for the picture.
        6. Picture, one visual per paragraph, covering the whole voice with no black gap:
           - the user's own material first — screen recordings, phone B-roll, photos (media_list → media_import →
             track_add {kind: "video"} once → timeline_place {assetId, trackId, start, sourceIn, sourceOut});
             a photo is a 5 s still by default (timeline_trim to the paragraph's length); frame 0 is their opening
             shot, and titles there use animIn "none" (a title that pops in is not on frame 0);
           - a landscape screen recording in a vertical frame: fit contain, scale 1; behind it, on the video track
             below, the same picture cropped to fill, effect_add blur (radius ~45), clip_set brightness −0.3…−0.45;
           - an image the user pastes in the chat is not a file you can import: ask them to save it in a media
             folder, never swap in another picture of your own choosing;
           - motion graphics for numbers, lists and comparisons: effects_catalog {category: "templates"} →
             effects_preview → motion_add (colours and fonts from brandkit_apply);
           - generated shots only if the user asks: generate_providers (local ComfyUI is free on a Pro-tier Mac;
             generate_check first). Real footage beats generated images.
           project_state shows the tracks and the duration: the last picture clip must end at or after the last
           voice clip.
        7. Captions, in the person's caption style choice (none: no captions): captions_generate {style: <that
           choice>, keywords: [the hook word, names, numbers]}. They use the script's own words and spelling from the
           Voce track; a name listed otherwise at the top goes in fixes. Re-run after moving voice clips.
        8. Titles, cards and sound effects: the reel-graphics recipe (titles land on the word; sound effects as the
           sfx choice says: sfx_library → sfx_add); the closing logo as the closing-logo choice says.
        8b. Dress the edit, as the person's graphics choice says — on: read effects_catalog and propose to the user,
            line by line, as many items as its number says that fit what is said (a counter or clock on the number, a
            headline on the punchline, a chip on the thing shown, punch-ins on the strong words, transitions on
            section changes, the logo of a brand that is named, a photo of a place that is named, a closing logo).
            One line each: what it is, where it lands, why. Ask as a yes/no list (a multiple-choice question when the
            client has one) and apply only what they accept. With the choice on, a first export without this pass is
            a draft, never the delivery.
        9. Music, as the person's music choice says (on-request: only if asked): audio_addMusic {path} (ducked under
           the voice by default), then audio_checkDucking (pass: music at least 15 dB under the voice while it speaks).
        10. Look: frame_contactSheet {times: [the start of each voice clip + 0.5]}. Check: every beat has its
            picture, nothing important sits under the caption band or in the platform's zones (graphics_checkLayout
            gives both), text is readable. Fix, look again.
        11. Export: rules_check first (fix what fails), then export_render {path: <exportsDirectory>/<name>.mp4, preset: "9:16", loudness: \(Int(LoudnessTarget.integrated))} (the mix is
            brought to −15 LUFS; the result gives the measured loudness and any warning), export_srt, project_save.

        Finish with a short report: text said, visuals used per paragraph, where the files are — and remind the
        user to add the note the export gives ("AI-generated voice") to the post description.
        """)
}
