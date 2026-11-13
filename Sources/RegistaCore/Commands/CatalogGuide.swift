import Foundation

// What an agent needs to recommend a catalog item (issue #22): what it looks like on screen, when to propose it and
// when not to. English only (the app's tile labels stay Italian). A test fails when an item has no entry here.

public struct CatalogGuide: Sendable, Hashable {
    /// What the viewer sees.
    public var description: String
    /// When an agent should propose it.
    public var useWhen: String
    /// When it is the wrong choice.
    public var avoid: String

    public init(_ description: String, useWhen: String, avoid: String) {
        self.description = description
        self.useWhen = useWhen
        self.avoid = avoid
    }

    public var isComplete: Bool { !description.isEmpty && !useWhen.isEmpty && !avoid.isEmpty }

    static let missing = CatalogGuide("", useWhen: "", avoid: "")

    /// The guide of a catalog item id.
    static func of(_ id: String) -> CatalogGuide {
        if let g = entries[id] ?? LooksCatalog.guides[id] { return g }
        if id.hasPrefix("look-"), let g = looks[String(id.dropFirst(5))] { return g }
        if id.hasPrefix("sticker-"), let g = sticker(String(id.dropFirst(8))) { return g }
        return missing
    }

    // MARK: Looks

    static let lookAvoid = "Stacking looks per clip (one look for the whole reel), amounts above ~70 % on faces, or a look on top of footage that is already graded."

    static let looks: [String: CatalogGuide] = [
        "golden": CatalogGuide("The whole picture turns warm and gently lifted, like late-afternoon sun: golden skin, soft shadows, a slight amber cast in the highlights.",
                               useWhen: "Talking heads shot indoors under cool or flat light, lifestyle, food, beauty, hospitality — anything that should feel welcoming. 40–60 %.",
                               avoid: "Footage that is already warm or orange (tungsten), cold tech/security topics, or when the brand colours are cool blues that would turn muddy. " + lookAvoid),
        "frost": CatalogGuide("Cool, clean and slightly desaturated: whites go blue-white, skin a little paler, the frame feels crisp and quiet.",
                              useWhen: "Tech, SaaS, finance, winter or clinical topics; footage that came out too warm; a calm, precise tone.",
                              avoid: "Warm lifestyle, food or beauty content, and skin-heavy close-ups where it reads as sickly. " + lookAvoid),
        "film": CatalogGuide("A soft film print: faded (lifted) blacks, teal in the shadows, warm highlights, gentle contrast. Reads as 'shot on film', premium but not loud.",
                             useWhen: "The default premium look for talking heads, storytelling and brand reels; when the phone footage looks too digital. 40–70 %.",
                             avoid: "Screen recordings and UI (the faded blacks wash out the interface), or hard-news tone. " + lookAvoid),
        "graphite": CatalogGuide("Neutral black and white with a touch of contrast: every colour becomes grey, nothing tinted.",
                                 useWhen: "One dramatic or reflective beat (a flashback, a 'before' shot, a serious statement) on a single clip.",
                                 avoid: "The whole reel (colour sells on Instagram), or anything where brand colours or product colours matter. " + lookAvoid),
        "ink": CatalogGuide("Hard black and white: deep crushed blacks, bright whites, graphic and punchy.",
                            useWhen: "A short, bold editorial beat or a hook frame that must feel intense; fashion or music content.",
                            avoid: "Long stretches of talking (it is tiring and hides skin detail), dark footage (blacks block up). " + lookAvoid),
        "vivid": CatalogGuide("More colour and contrast: flat phone footage gets saturated, contrasty colour with highlights held back.",
                              useWhen: "Flat or grey phone footage, energetic reels, products and food that should pop; the 'energico' style uses it.",
                              avoid: "Footage that is already saturated or skin that is already red — faces go orange — and calm premium brands. " + lookAvoid),
        "velvet": CatalogGuide("Low contrast and lifted, pastel colours: a soft, dreamy, gentle frame.",
                               useWhen: "Beauty, wellness, wedding, soft lifestyle; harsh contrasty footage that needs calming.",
                               avoid: "Footage that is already low contrast (it goes milky), tech or energetic content. " + lookAvoid),
        "riviera": CatalogGuide("Cinematic teal and orange: skin warm, shadows and backgrounds pushed towards teal.",
                                useWhen: "Travel, outdoor, sport, 'cinematic' brand pieces with sky or sea in frame.",
                                avoid: "Indoor talking heads against warm walls (the background goes green), or subtle premium brands. " + lookAvoid),
        "archive": CatalogGuide("A yellowed, faded old print: low saturation, warm cast, lifted blacks.",
                                useWhen: "A memory, a 'how it used to be' beat, history or nostalgia — usually on one clip.",
                                avoid: "The present-tense main story, product shots that must look new. " + lookAvoid),
        "matte": CatalogGuide("Matte blacks and muted colour: understated, editorial, slightly flat in a deliberate way.",
                              useWhen: "Minimal brands, architecture, fashion, interiors; a sober alternative to film.",
                              avoid: "Dark footage (it looks foggy), energetic content that needs punch. " + lookAvoid),
        "sunset": CatalogGuide("Rose and amber warmth across the frame: romantic, glowing skin.",
                               useWhen: "Golden-hour outdoor footage, romantic or hospitality content, warm brand palettes with pinks.",
                               avoid: "Already warm footage (skin turns pink-orange), corporate or tech topics. " + lookAvoid),
        "fjord": CatalogGuide("Cool green-blue with quiet colour: calm, Nordic, restrained.",
                              useWhen: "Nature, wellness, sustainability, calm tech; footage that is too warm or too saturated.",
                              avoid: "Skin-heavy close-ups (faces look cold), food. " + lookAvoid),
        "night": CatalogGuide("Darker, cooler and contrastier: a moody night-time frame.",
                              useWhen: "A tense or mysterious beat, security/risk topics, footage shot at night that needs mood.",
                              avoid: "Dark or underexposed footage (faces disappear), the whole reel of a friendly brand. " + lookAvoid),
        "airy": CatalogGuide("Bright and airy: exposure and shadows lifted, highlights held, clean whites, a touch more colour.",
                             useWhen: "Slightly dark indoor talking heads, clean lifestyle and beauty, the 'pulito' style.",
                             avoid: "Footage that is already bright or has blown windows (it clips), moody topics. " + lookAvoid),
    ]

    // MARK: Stickers

    static let stickerMeaning: [String: String] = [
        "fire": "a fire emoji: hot, trending, impressive", "sparkles": "sparkles: new, magic, a small win",
        "eyes": "the eyes emoji: look at this, curiosity", "idea": "a light-bulb emoji: an idea, a tip",
        "check": "a green check emoji: done, correct, approved", "cross": "a red cross emoji: wrong, don't, a myth",
        "rocket": "a rocket emoji: launch, growth, speed", "point": "a pointing hand emoji: look here, next",
        "laugh": "a laughing emoji: a joke landed", "target": "a target emoji: the goal, precision",
        "heart": "a red heart emoji: love, favourite", "clap": "clapping hands: congratulations, well done",
        "seal": "a green check-seal symbol: verified, guaranteed", "star": "a gold star symbol: rating, best, quality",
        "bolt": "a gold lightning-bolt symbol: fast, energy, power", "arrowDown": "a white down arrow: look below, link in bio",
        "tap": "a tapping-hand symbol: tap, try it, interact", "warning": "an orange warning triangle: careful, risk",
        "bulb": "a gold light-bulb symbol: an idea, a tip (cleaner than the emoji)", "click": "a cursor-click symbol: click here, a UI step",
        "bell": "a bell symbol: notifications, subscribe, reminder", "thumbsUp": "a thumbs-up symbol: approval, recommended",
    ]

    static func sticker(_ id: String) -> CatalogGuide? {
        guard let m = stickerMeaning[id] else { return nil }
        return CatalogGuide("Pops in over the video for ~1.4 s, in the top band: \(m).",
                            useWhen: "A punchline or a single beat whose meaning matches the sticker exactly — one sticker in a reel, on the word.",
                            avoid: "Decorating sentences, several stickers in a row, literal illustration of every noun, premium/serious brands that avoid emoji, the caption band or the face.")
    }

    // MARK: Everything else

    static let entries: [String: CatalogGuide] = [
        "look-none": CatalogGuide("Removes the look: the picture goes back to its original colours (adjustments stay).",
                                  useWhen: "The user wants the original colour back, or before trying another look.",
                                  avoid: "Removing a look the user chose on purpose without asking."),
        // Adjust
        "adjust-light": CatalogGuide("Brighter picture: exposure up and shadows lifted, highlights kept.",
                                     useWhen: "Underexposed talking heads, faces in shadow, a dark room.",
                                     avoid: "Footage that is already bright or has a blown window behind the speaker (it clips to white)."),
        "adjust-warm": CatalogGuide("Warmer colour temperature: whites go slightly yellow-orange, skin warmer.",
                                    useWhen: "Footage that looks blue or cold (shade, LED, cloudy daylight); a friendlier tone.",
                                    avoid: "Tungsten-lit footage that is already orange, cool brand colours on set."),
        "adjust-cool": CatalogGuide("Cooler colour temperature: whites go slightly blue, a crisper tone.",
                                    useWhen: "Footage that came out orange (tungsten bulbs), tech or clinical topics.",
                                    avoid: "Skin-heavy close-ups already pale or cold, warm lifestyle content."),
        "adjust-contrast": CatalogGuide("More contrast: darker darks and brighter lights, a punchier picture.",
                                        useWhen: "Flat, grey or hazy footage; to add bite to a phone take.",
                                        avoid: "Already contrasty footage, harsh sunlight on faces (crushed shadows), dark skin in low light."),
        "adjust-vignette": CatalogGuide("Darker frame edges that pull the eye to the centre.",
                                        useWhen: "A centred talking head on a busy background; a cinematic touch at low strength.",
                                        avoid: "Screen recordings and UI (corners matter), split layouts, graphics in the corners."),
        "adjust-sharp": CatalogGuide("Crisper detail: edges and textures sharpened.",
                                     useWhen: "Soft footage, upscaled AI inserts, slightly out-of-focus takes.",
                                     avoid: "Noisy low-light footage (it sharpens the noise), skin close-ups at high strength."),
        "adjust-mono": CatalogGuide("Removes all colour: a plain black-and-white picture.",
                                    useWhen: "A quick black-and-white beat when no look is wanted; 'before' shots.",
                                    avoid: "The whole reel, brand-colour content; prefer the graphite/ink looks for designed black and white."),
        // Zoom
        "zoom-punch": CatalogGuide("The picture jumps in by 5–25 % for half a second and eases back: a quick zoom bump that hits a word.",
                                   useWhen: "The strongest word of a line, a number, a beat of the music — max 2 per reel outside beat sync.",
                                   avoid: "Every sentence, clips that are already punched in tight (faces get cropped), screen recordings with small text."),
        "zoom-slow": CatalogGuide("A slow push-in over the whole clip (1 → 1.08) with a slight drift: the shot breathes and feels alive.",
                                  useWhen: "Stills, B-roll inserts, long static talking shots that need life.",
                                  avoid: "Clips that already have punch-ins or keyframes, very short clips (it barely shows), screen recordings."),
        "zoom-shake": CatalogGuide("A short hand-held camera shake for a fraction of a second.",
                                   useWhen: "An impact moment: a bass hit, a surprising reveal, a 'boom' word.",
                                   avoid: "Talking passages, premium calm brands, more than once or twice per reel — it reads as a gimmick."),
        // FX
        "fx-glitch": CatalogGuide("A few frames of digital glitch: red/blue split and horizontal slices jittering sideways.",
                                  useWhen: "A hard cut into a tech or error topic, a 'system broken' beat, a few frames only.",
                                  avoid: "A whole sentence, calm or premium brands, faces in close-up for long, people sensitive to flicker."),
        "fx-flash": CatalogGuide("The whole frame flashes white (to ~90 %) and fades back in a quarter of a second.",
                                 useWhen: "A beat drop, a reveal, a camera-shutter moment, a real section change.",
                                 avoid: "Repeated flashes (photosensitivity), talking passages, under captions you need to read."),
        "fx-blur": CatalogGuide("The picture softly blurs and comes back into focus.",
                                useWhen: "A transition out of a thought, a dream/flashback, putting a card in focus over a blurred speaker.",
                                avoid: "Moments where the face or text must stay readable, long durations."),
        "fx-glow": CatalogGuide("Highlights bloom softly: bright parts bleed light, a dreamy halo.",
                                useWhen: "Beauty, romance, magic moments, a reveal of a product on a bright background.",
                                avoid: "Bright overexposed footage (it washes out), UI and text, business content."),
        "fx-chroma": CatalogGuide("Removes a green screen from an overlay clip so only the subject remains over the video below.",
                                  useWhen: "The user has a real green/blue-screen overlay clip on an overlay track.",
                                  avoid: "The main camera clip, footage without a green screen (it eats green objects)."),
        // Text
        "text-hook": CatalogGuide("A big title in the brand's hook style (display font, brand colours) that pops in in the top band and fades out.",
                                  useWhen: "The first 0–4 s: the hook question or claim in a few words; one per reel.",
                                  avoid: "Repeating what the captions already say word for word, more than one hook, long sentences (> 7 words)."),
        "text-kicker": CatalogGuide("A small label (mono/kicker style) in the top band: a date, a source, a category.",
                                    useWhen: "Context the voice does not say: 'MERCOLEDÌ 21 OTTOBRE', 'FONTE: ISTAT', a chapter name.",
                                    avoid: "Restating the caption, long text, several labels at once."),
        "text-3d": CatalogGuide("A real extruded 3D title rendered with Blender (two lines, brand colour and font), animating in.",
                                useWhen: "The hook of a premium reel when Blender is installed and there is time to render (~1–2 min once).",
                                avoid: "Anything after the hook, quick drafts, machines without Blender; never together with a 2D hook title."),
        "callout-circle": CatalogGuide("A hand-drawn circle that draws itself around a region of the frame, then fades.",
                                       useWhen: "Pointing at something visible the voice names: a button, a price, a detail in a screenshot; tutorials on clicks.",
                                       avoid: "Circling the speaker's face, more than one callout at a time, regions that move."),
        "callout-underline": CatalogGuide("A hand-drawn line that draws itself under a region (a word or a number on screen).",
                                          useWhen: "Stressing a word or a number visible in the frame (a screenshot, a sign, a card).",
                                          avoid: "Underlining captions (they move), things not on screen."),
        "callout-box": CatalogGuide("A rounded rectangle that draws itself around a region of the frame.",
                                    useWhen: "Framing a UI panel, a block of text or a product in a screenshot or a screen recording.",
                                    avoid: "Faces, moving subjects, cluttering a frame that already has cards."),
        "callout-highlight": CatalogGuide("A translucent marker band swept left to right over a region, like a highlighter pen.",
                                          useWhen: "Highlighting a line of text in a document, an article or a UI on screen.",
                                          avoid: "Over faces or footage without text, over the captions."),
        "callout-arrow": CatalogGuide("An arrow that draws itself from one point to another along a gentle arc.",
                                      useWhen: "Directing attention to a specific spot: 'this button', 'look here', a detail in the background.",
                                      avoid: "Pointing at the speaker, several arrows at once, arrows crossing the caption band."),
        "progress-bar": CatalogGuide("A thin bar along the top (or bottom) edge that fills left to right while the video plays.",
                                     useWhen: "Tutorials, lists, long reels (> 40 s) where viewers like to know how much is left; the 'tutorial' style.",
                                     avoid: "Short reels, ads that hide their length, frames whose edge already carries graphics."),
        // Transitions
        "transition-flash": CatalogGuide("At a cut, the frame flashes to white and back over ~0.2 s.",
                                         useWhen: "A real section change, into or out of an insert, a beat drop.",
                                         avoid: "Every cut, jump cuts inside a sentence, more than 2 per reel."),
        "transition-whip": CatalogGuide("At a cut, the picture whips sideways with motion blur and the next shot slides in: a fast camera pan.",
                                        useWhen: "Energetic changes of topic or place, into/out of B-roll, list items.",
                                        avoid: "Calm premium edits, talking-head jump cuts every few seconds, screen recordings."),
        "transition-dip": CatalogGuide("At a cut, the picture dips through black and comes back over ~0.5 s.",
                                       useWhen: "A time skip, the end of a chapter, a calm emotional change.",
                                       avoid: "Fast reels (it slows them down), mid-sentence cuts."),
        // Speed
        "speed-slowmo": CatalogGuide("The clip plays at half speed (sound time-stretched, pitch kept).",
                                     useWhen: "B-roll, a gesture, a product reveal or action you want to savour.",
                                     avoid: "Talking passages (slow speech reads as a mistake), clips you need in sync with music."),
        "speed-superSlowmo": CatalogGuide("The clip plays at a quarter speed; the sound is muted.",
                                          useWhen: "A dramatic moment of motion (a splash, a jump, a hair flip) shot at a high frame rate.",
                                          avoid: "Speech, 30 fps footage with big motion (it stutters), long clips."),
        "speed-fast": CatalogGuide("The clip plays at double speed (sound time-stretched, pitch kept).",
                                   useWhen: "Skipping through a process (setup, cooking, scrolling a page), a comic speed-up.",
                                   avoid: "Speech that must be understood, the hook."),
        "speed-timelapse": CatalogGuide("The clip plays four times faster: a time-lapse.",
                                        useWhen: "Long processes condensed (a build, a day, a drive), screen recordings of a long task.",
                                        avoid: "Speech, short clips (they vanish)."),
        "speed-hero": CatalogGuide("A speed ramp: normal speed, a dramatic slow-motion middle, back to normal.",
                                   useWhen: "One hero moment of action or a product reveal in B-roll.",
                                   avoid: "Talking clips, more than one per reel."),
        "speed-rampIn": CatalogGuide("A speed ramp that starts fast and settles into slow motion.",
                                     useWhen: "Arriving on a subject or a detail: the end of a move that should land softly.",
                                     avoid: "Talking clips, clips without motion."),
        "speed-rampOut": CatalogGuide("A speed ramp that starts in slow motion and accelerates out.",
                                      useWhen: "Leaving a moment with energy, into a cut or a transition.",
                                      avoid: "Talking clips, clips without motion."),
        "speed-reverse": CatalogGuide("The clip plays backwards (sound muted).",
                                      useWhen: "A short visual joke or a rewind gag ('let's go back'), up to a few seconds.",
                                      avoid: "Anything with speech or readable text, clips over 30 s."),
        "speed-normal": CatalogGuide("Puts the clip back to its original speed.",
                                     useWhen: "Undoing a speed change on one clip.",
                                     avoid: "Clips that were never retimed (nothing happens)."),
        "speed-freeze": CatalogGuide("The picture freezes on one frame for a moment while the timeline continues, then the clip resumes.",
                                     useWhen: "The punchline, a funny face, a 'wait…' beat, introducing a person with a label (0.6–1.2 s).",
                                     avoid: "Mid-word (the sound stops too), more than once per reel."),
        // Logo
        "logo-sting": CatalogGuide("The brand logo pops in past full size with a short glow, settles and lifts away (~1.6 s), by default at the very end.",
                                   useWhen: "The outro of a branded reel, or within the first second as a signature.",
                                   avoid: "Long logo intros, a logo on every cut, reels without a brand kit logo."),
        "logo-spin": CatalogGuide("The logo grows in while turning once, then rests and fades.",
                                  useWhen: "A playful brand, a short outro alternative to the sting.",
                                  avoid: "Serious or premium brands, logos with text (unreadable while spinning)."),
        "logo-pulse": CatalogGuide("The logo breathes gently (scale 1 → 1.06 → 1 every 1.2 s).",
                                   useWhen: "A closing card that holds the logo for a few seconds.",
                                   avoid: "A logo over the whole reel (distracting), next to a call-to-action that should be the focus."),
        "logo-orbit": CatalogGuide("The logo drifts slowly on a small circle around its place.",
                                   useWhen: "A calm closing card or a floating brand mark over a still.",
                                   avoid: "Over talking footage, corners near the Instagram buttons."),
        // Styles
        "style-energico": CatalogGuide("A bundle in one undo step: a vivid look, alternating punch-in framing per sentence, soft whooshes on a few cuts and word-by-word pop captions.",
                                       useWhen: "The user asks for an energetic / dynamic / 'TikTok' reel and the edit is cut; a starting point to tune.",
                                       avoid: "Calm premium brands, tutorials, an edit with hand-tuned framing (punch-ins are overwritten on alternate clips)."),
        "style-pulito": CatalogGuide("A bundle in one undo step: a light airy look, gentle contrast and sharpness, calm whole-line captions, no sound effects.",
                                     useWhen: "The user asks for clean / minimal / elegant; premium and corporate brands.",
                                     avoid: "Energetic content that needs punch, footage that is already bright."),
        "style-tutorial": CatalogGuide("A bundle in one undo step: auto-zoom on the recording's clicks with a circle on each, a progress bar and a crisper picture.",
                                       useWhen: "Screen recordings imported with recording.import (the zooms need the click events).",
                                       avoid: "Talking heads without a screen recording (only the bar and sharpness apply)."),
    ]
}
