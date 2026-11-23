import Foundation
import Testing
@testable import RegistaCore

// The recipes carry steps only: the rules they used to repeat live in the sheets (always), in the person's choices
// (RuleChoiceSpec) or in the commands that already do them. The map below is the record of that move: every rule
// sentence a recipe lost, by subject, with where it lives now; a target that does not exist fails the test.

/// Where a rule lives now.
enum RuleHome: CustomStringConvertible {
    /// A shipped sheet (its English text): the kind, the `## ` section it is in (nil: anywhere), a phrase of it.
    case sheet(String, section: String?, phrase: String)
    /// A check a sheet switches (RuleCheckSpec).
    case check(String)
    /// A choice of the person's (RuleChoiceSpec), and the option that says it when one does.
    case choice(String, option: String? = nil)
    /// A fact of the engine: the command does it.
    case command(String)
    /// A step of the recipe itself (what to do or look at, not a rule of its own).
    case step(String, phrase: String)

    var description: String {
        switch self {
        case .sheet(let kind, let section, let phrase): "sheet \(kind) \(section ?? "") «\(phrase)»"
        case .check(let id): "check \(id)"
        case .choice(let id, let option): "choice \(id)\(option.map { ": \($0)" } ?? "")"
        case .command(let id): "command \(id)"
        case .step(let recipe, let phrase): "step of \(recipe) «\(phrase)»"
        }
    }
}

/// Every rule sentence a recipe lost, by subject → where it lives now.
let movedRules: [(recipe: String, subject: String, homes: [RuleHome])] = [
    // talking-head-reel
    ("talking-head-reel", "the kept take: the cleanest complete reading, usually the last; fillers and false starts go",
     [.sheet("talking-head-reel", section: nil, phrase: "keep the cleanest complete one")]),
    ("talking-head-reel", "natural pacing: breaths kept, gaps between lines", [.sheet("talking-head-reel", section: nil, phrase: "keep the breaths"), .choice("pace")]),
    ("talking-head-reel", "the pauses edit.autoCut keeps between lines", [.choice("pace")]),
    ("talking-head-reel", "jump cuts hidden by alternating punch-ins",
     [.sheet("talking-head-reel", section: nil, phrase: "so jump cuts do not show"), .choice("framing", option: "alternate")]),
    ("talking-head-reel", "the light grade", [.choice("colour", option: "light")]),
    ("talking-head-reel", "the voice at −15 LUFS, true peak ≤ −1.5 dBTP",
     [.sheet("every-video", section: "## Sound", phrase: "The voice at −15 LUFS"), .command("audio.clean")]),
    ("talking-head-reel", "never normalize twice", [.sheet("every-video", section: "## Sound", phrase: "The voice is brought to its level once")]),
    ("talking-head-reel", "a quiet, roomy take cannot be fixed by processing", [.step("talking-head-reel", phrase: "cannot be fixed by")]),
    ("talking-head-reel", "the export settings for the platform", [.command("export.render")]),
    ("talking-head-reel", "captions and graphics out of the platform's zones (top, bottom, right edge) and in their band",
     [.sheet("talking-head-reel", section: nil, phrase: "where the platform draws its buttons"),
      .sheet("every-video", section: "## Captions", phrase: "stay out of the platform's buttons"), .command("graphics.checkLayout"), .command("captions.checkTiming")]),
    ("talking-head-reel", "no music baked in", [.choice("music", option: "on-request")]),
    ("talking-head-reel", "never a bare edit: proposals from the catalog before delivering", [.choice("graphics", option: "on")]),
    ("talking-head-reel", "captions on one baseline", [.sheet("every-video", section: "## Captions", phrase: "sit on one baseline")]),
    ("talking-head-reel", "the caption style", [.choice("captions", option: "talking-head-v1")]),
    ("talking-head-reel", "how many keywords", [.choice("keywords", option: "on")]),
    ("talking-head-reel", "graphics, sound effects and music only when asked", [.choice("graphics"), .choice("sfx"), .choice("music")]),
    ("talking-head-reel", "one structure for the presenter's rhythm", [.choice("structure")]),
    ("talking-head-reel", "the format of the export", [.choice("format", option: "project")]),
    ("talking-head-reel", "the house look: large uppercase captions word by word, a keyword on a box, punch-ins, a light grade, short gaps",
     [.choice("captions", option: "talking-head-v1"), .choice("keywords", option: "on"), .choice("framing", option: "alternate"), .choice("colour", option: "light"),
      .choice("pace", option: "normal")]),
    ("talking-head-reel", "the names glossary", [.sheet("every-video", section: "## Names", phrase: "one per line"), .step("talking-head-reel", phrase: "«Nomi»")]),
    // screen-tutorial
    ("screen-tutorial", "the recording folder is never modified", [.sheet("every-video", section: "## Always", phrase: "original files are never modified")]),
    ("screen-tutorial", "one layout change every 20–30 s at most; the screen is the subject",
     [.sheet("screen-tutorial", section: nil, phrase: "one layout change every 20–30 s at most")]),
    ("screen-tutorial", "no music unless asked, ducked under the voice",
     [.choice("music", option: "on-request"), .sheet("every-video", section: "## Sound", phrase: "Music under the voice is always lowered"), .command("audio.checkDucking")]),
    ("screen-tutorial", "titles, cards and sound effects: the reel-graphics recipe", [.step("screen-tutorial", phrase: "the reel-graphics recipe")]),
    ("screen-tutorial", "never a bare edit", [.choice("graphics", option: "on")]),
    ("screen-tutorial", "the format, asked only if unclear", [.choice("format", option: "project")]),
    ("screen-tutorial", "captions on a reel, asked on a tutorial", [.choice("captions")]),
    // voice-over-video
    ("voice-over-video", "only the active profile's voice", [.sheet("every-video", section: "## Always", phrase: "A cloned voice is only ever the person's own")]),
    ("voice-over-video", "the person's face only when asked", [.sheet("voice-over-video", section: nil, phrase: "face is not on screen unless they ask")]),
    ("voice-over-video", "one visual idea per sentence, cut on the voice",
     [.sheet("voice-over-video", section: nil, phrase: "Show each piece when the voice names it"), .step("voice-over-video", phrase: "one visual per paragraph")]),
    ("voice-over-video", "brand kit colours and fonts only", [.sheet("every-video", section: "## Graphics and text", phrase: "from the brand kit only")]),
    ("voice-over-video", "no invented facts or numbers", [.sheet("every-video", section: "## Always", phrase: "Nothing invented on screen")]),
    ("voice-over-video", "every recording the person hands over is used where it belongs",
     [.sheet("voice-over-video", section: nil, phrase: "Every recording the person hands over")]),
    ("voice-over-video", "never a bare edit: the effects pass before the export", [.choice("graphics", option: "on")]),
    ("voice-over-video", "the closing logo after the last word, on a clean frame",
     [.sheet("every-video", section: "## Ending", phrase: "of clean picture, then the logo"), .check("logo-captions"), .check("logo-pause"), .choice("closing-logo")]),
    ("voice-over-video", "frame 0: the person's opening shot, at most two still titles, never reordered",
     [.sheet("voice-over-video", section: nil, phrase: "Frame 0 is the person's own opening shot"), .step("voice-over-video", phrase: "animIn \"none\"")]),
    ("voice-over-video", "never the result on frame 0", [.sheet("every-video", section: "## Opening", phrase: "Never give away the result")]),
    ("voice-over-video", "one fix asked for is that fix only", [.sheet("every-video", section: "## Always", phrase: "one fix asked for is that fix")]),
    ("voice-over-video", "a landscape recording in a vertical frame is shown whole",
     [.sheet("voice-over-video", section: nil, phrase: "shown whole, edge to edge"), .step("voice-over-video", phrase: "fit contain")]),
    ("voice-over-video", "a pasted image is not a file", [.step("voice-over-video", phrase: "not a file you can import")]),
    ("voice-over-video", "sound effects sparse and quiet", [.choice("sfx", option: "sparse")]),
    ("voice-over-video", "music only if asked", [.choice("music", option: "on-request")]),
    ("voice-over-video", "nothing important in the top 110 px", [.command("graphics.checkLayout")]),
    // prompt-to-reel (the voice-over video's sheet)
    ("prompt-to-reel", "the plan said yes to is what is built",
     [.sheet("every-video", section: "## Always", phrase: "Build what the person said yes to"), .step("prompt-to-reel", phrase: "what the user says yes to is what is built")]),
    ("prompt-to-reel", "one signature moment, the rest quiet", [.step("prompt-to-reel", phrase: "one signature moment")]),
    ("prompt-to-reel", "two actions never share one sound effect", [.sheet("voice-over-video", section: nil, phrase: "two actions never share one effect")]),
    ("prompt-to-reel", "the turn is the picture that changes most", [.sheet("voice-over-video", section: nil, phrase: "The turn is the picture that changes most")]),
    ("prompt-to-reel", "the near-silence kept in the mix", [.choice("faceless-sound", option: "directed"), .step("prompt-to-reel", phrase: "no tail rings through it")]),
    ("prompt-to-reel", "sound effects for each visible action", [.choice("sfx", option: "actions")]),
    ("prompt-to-reel", "brand kit colours and fonts, in every scene", [.sheet("every-video", section: "## Graphics and text", phrase: "in every graphic and scene")]),
    // reel-graphics
    ("reel-graphics", "the logo only as a closing card, never at the start or in a corner",
     [.check("logo-end"), .choice("closing-logo"), .sheet("reel-graphics", section: nil, phrase: "The logo is a closing card only")]),
    ("reel-graphics", "one hook title in the opening", [.choice("opening-title"), .choice("hook"), .sheet("reel-graphics", section: nil, phrase: "One hook title in the opening")]),
    ("reel-graphics", "text behind the person: the hook only, once", [.sheet("reel-graphics", section: nil, phrase: "Text behind the person: the hook title only")]),
    ("reel-graphics", "which layer when: title, card, insert, template, mostly nothing",
     [.sheet("reel-graphics", section: nil, phrase: "Most lines get nothing"), .sheet("reel-graphics", section: nil, phrase: "one layer at a time")]),
    ("reel-graphics", "the layout bands in numbers", [.sheet("reel-graphics", section: nil, phrase: "top band (y 110–640)"), .command("graphics.checkLayout")]),
    ("reel-graphics", "the platform's zones in numbers", [.command("graphics.checkLayout")]),
    ("reel-graphics", "abstract fine touches, no gimmicks; when in doubt leave it out", [.sheet("reel-graphics", section: nil, phrase: "no gimmicks")]),
    ("reel-graphics", "motion in and out", [.command("title.add"), .command("motion.add")]),
    ("reel-graphics", "sparse: how many cards, inserts and sound effects",
     [.sheet("reel-graphics", section: nil, phrase: "about one every 6–8 seconds"), .choice("sfx", option: "sparse")]),
    ("reel-graphics", "verified facts only on cards", [.sheet("every-video", section: "## Always", phrase: "Nothing invented on screen")]),
    ("reel-graphics", "brand fonts and colours from the kit only", [.sheet("every-video", section: "## Graphics and text", phrase: "from the brand kit only")]),
    ("reel-graphics", "the captions keep their look", [.choice("captions", option: "talking-head-v1")]),
    ("reel-graphics", "sound effects sparse, on beats, quiet, never two at once", [.sheet("reel-graphics", section: nil, phrase: "never two at once"), .choice("sfx", option: "sparse")]),
    ("reel-graphics", "music only when asked, always ducked",
     [.choice("music", option: "on-request"), .sheet("every-video", section: "## Sound", phrase: "always lowered"), .command("audio.checkDucking")]),
    ("reel-graphics", "readable text", [.check("text-size")]),
]

@Test func everyRuleARecipeLostLivesInASheetAChoiceOrACommand() throws {
    #expect(movedRules.count >= 50)
    for moved in movedRules {
        let recipe = try #require(Recipes.named(moved.recipe), "no recipe \(moved.recipe)")
        #expect(!moved.homes.isEmpty, "«\(moved.subject)» has nowhere to live")
        for home in moved.homes {
            let found: Bool
            switch home {
            case .sheet(let kind, let section, let phrase):
                let prose = RuleSheetText.parse(RuleDefaults.text(kind, language: "en") ?? "").prose
                var scope = prose
                if let section, let start = prose.range(of: "\n" + section + "\n") {
                    let rest = prose[start.upperBound...]
                    scope = String(rest[..<(rest.range(of: "\n## ")?.lowerBound ?? rest.endIndex)])
                } else if section != nil {
                    scope = ""
                }
                // The sheet is one the recipe reads.
                found = scope.contains(phrase) && [RuleBook.everyVideo, recipe.kind].contains(kind)
            case .check(let id):
                found = RuleCheckSpec.named(id) != nil
            case .choice(let id, let option):
                if let spec = RuleChoiceSpec.named(id) {
                    found = spec.applies(to: recipe.kind) && (option == nil || spec.option(option ?? "") != nil)
                } else {
                    found = false
                }
            case .command(let id):
                found = Commands.all.contains { $0.id == id }
            case .step(let name, let phrase):
                found = Recipes.named(name)?.steps.contains(phrase) == true
            }
            #expect(found, "\(moved.recipe): «\(moved.subject)» → \(home) does not exist")
        }
    }
}

/// The rule sections are gone; the steps name the person's choices, never a number of their own for them.
@Test func theRecipesCarryStepsAndEndWithOneLineOnTheRules() {
    for r in Recipes.all {
        let text = r.text()
        for heading in ["## House", "## Taste", "## Which layer when", "## Layout bands", "lossary"] {
            #expect(!text.contains(heading), "\(r.name) still has «\(heading)»")
        }
        for number in ["6–12", "0.2–0.7", "0.2–0.3 s", "12–16", "y 1540", "right 120 px"] {
            #expect(!text.contains(number), "\(r.name) says «\(number)» of its own")
        }
        #expect(text.hasSuffix("\n\n" + Recipe.closing), "\(r.name) does not end with the line on the person's rules")
        #expect(text.components(separatedBy: "win over").count == 2, "\(r.name) says more than once that the rules win")
    }
    // The choices the steps follow.
    let reel = Recipes.talkingHeadReel.steps
    for words in ["pace choice", "framing choice", "colour choice", "caption style choice", "keywords choice", "graphics choice", "structure choice", "format choice"] {
        #expect(reel.contains(words), "talking-head-reel does not follow the \(words)")
    }
    #expect(Recipes.reelGraphics.steps.contains("sfx choice") && Recipes.reelGraphics.steps.contains("music choice") && Recipes.reelGraphics.steps.contains("closing-logo choice"))
    #expect(Recipes.promptToReel.steps.contains("faceless-sound choice"))
}

/// No brand, no "approved" look and no names glossary in what a recipe says, nor in the caption commands and the catalog
/// (the punch-in preset keeps its name).
@Test func theRecipesAndTheCaptionDescriptionsNameNoBrandNorAnApprovedLook() {
    let banned = ["wesites", "approved", "claude duet", "hugging fe", "antropic", "arkad"]
    for r in Recipes.all {
        let said = ([r.title, r.description, r.text()] + r.arguments.map(\.description)).joined(separator: "\n").lowercased()
        for word in banned { #expect(!said.contains(word), "\(r.name) says «\(word)»") }
    }
    let descriptions = Commands.all.filter { $0.id.hasPrefix("captions.") || ["recipe.get", "effects.catalog", "edit.punchIns"].contains($0.id) }
        .map { c in ([c.summary] + c.descriptor.params.map(\.description)).joined(separator: "\n") }
    let guide = LooksCatalog.guides["caption-talking-head-v1"].map { [$0.description, $0.useWhen, $0.avoid].joined(separator: "\n") } ?? ""
    for text in descriptions + [guide] {
        let lower = text.lowercased().replacingOccurrences(of: "wesites-selfie", with: "")
        for word in banned { #expect(!lower.contains(word), "«\(word)» in «\(text.prefix(80))…»") }
    }
}

/// The names glossary is the person's: an optional «Nomi» / «Names» / «Noms» / «Nomes» section of their sheets and
/// skill. recipe.get states the names first, before the caption step that refers to them; the shipped example is not one.
@Test func theNamesThePersonWritesComeFirstInTheRecipe() throws {
    var services = FakeServices().make()
    services.renderer = FakeRenderer()
    let e = Engine(prober: FakeProber(), services: services)
    let book = services.rules
    #expect(!book.directory.path.contains("Library/Application Support"))
    // The shipped sheets have the section in every language, with an example only.
    for language in RuleBook.languages {
        let prose = RuleSheetText.parse(RuleDefaults.text(RuleBook.everyVideo, language: language) ?? "").prose
        #expect(["## Nomi", "## Names", "## Noms", "## Nomes"].contains { prose.contains("\n" + $0 + "\n") } && prose.contains("Miro Talen → MiroTalen"), "\(language)")
        #expect(book.names("talking-head-reel", language: language).isEmpty, "the example is taken as a name (\(language))")
    }
    let plain = try #require(e.execute("recipe.get", params: ["name": "talking-head-reel", "language": "en"])["text"]?.stringValue)
    #expect(plain.hasPrefix(Recipes.talkingHeadReel.text()))

    // A skill based on the talking-head reel, with its steps, and names in its rules.
    let slug = try #require(e.execute("skill.duplicate", params: ["from": "talking-head-reel", "title": "Interviews"])["skill"]?.stringValue)
    try e.execute("skill.set", params: ["skill": .string(slug), "rules": ["prose": "No zoom.\n\n## Nomi\n- Foo Bar → FooBar\n"]])
    let text = try #require(e.execute("recipe.get", params: ["name": .string(slug), "language": "en"])["text"]?.stringValue)
    let name = try #require(text.range(of: "- Foo Bar → FooBar")), reference = try #require(text.range(of: "«Nomi»"))
    let steps = try #require(text.range(of: "## Steps"))
    #expect(name.upperBound < steps.lowerBound && steps.upperBound < reference.lowerBound, "the names do not come before the caption step's reference")

    // A name the person wrote in their own «For every video» sheet reaches every recipe, before its steps.
    let sheet = try #require(RuleDefaults.text(RuleBook.everyVideo, language: "it"))
    try e.execute("rules.set", params: ["kind": "every-video", "prose": .string(RuleSheetText.parse(sheet).prose + "- Lumio Grafo → LumioGrafo\n"), "language": "it"])
    for r in Recipes.all {
        let said = try #require(e.execute("recipe.get", params: ["name": .string(r.name), "language": "en"])["text"]?.stringValue)
        #expect(said.hasPrefix("Names as the person spells them") && said.contains("- Lumio Grafo → LumioGrafo\n\n" + Recipes.named(r.name)!.text()), "\(r.name)")
    }
    #expect(book.names(slug, language: "en") == ["Lumio Grafo → LumioGrafo", "Foo Bar → FooBar"])
}

/// Every command a recipe named before it lost its rules is still named.
@Test func everyCommandARecipeNamedIsStillNamed() throws {
    let named: [String: [String]] = [
        "talking-head-reel": ["audio_clean", "callout_add", "captions_checkFaces", "captions_checkTiming", "captions_generate", "captions_get", "captions_place",
                              "captions_setKeywords", "captions_setStyle", "clip_place", "clip_set", "cover_make", "cover_set", "edit_autoCut", "edit_punchIns",
                              "effects_catalog", "export_mlt", "export_render", "export_srt", "faces_checkFraming", "faces_track", "frame_contactSheet",
                              "frame_elements", "frame_render", "graphics_checkLayout", "history_undo", "media_checkSync", "media_extractAudio", "media_import",
                              "media_list", "motion_add", "overlay_add", "project_new", "project_save", "recipe_get", "rules_check", "script_fromTranscript",
                              "script_set", "takes_list", "takes_select", "text_read", "transcript_deleteWords", "transcript_fillers", "transcript_run",
                              "transcript_timeline"],
        "reel-graphics": ["adjust_set", "audio_addMusic", "audio_checkDucking", "brandkit_apply", "brandkit_check", "brandkit_list", "callout_add",
                          "captions_checkTiming", "captions_generate", "clip_follow", "clip_set", "clip_speed", "edit_beatSync", "effect_add", "effects_catalog",
                          "effects_check", "effects_preview", "export_mlt", "export_render", "frame_contactSheet", "frame_render", "generate_estimate",
                          "generate_list", "generate_providers", "generate_run", "generate_status", "generate_upscale", "graphics_blenderTitle",
                          "graphics_checkBehindSubject", "graphics_checkLayout", "graphics_hyperframes", "hands_track", "history_undo", "layout_speaker",
                          "logo_add", "logo_animate", "look_apply", "matte_track", "media_checkOverlay", "meters_add", "motion_add", "overlay_add",
                          "progress_add", "rules_check", "sfx_add", "sfx_checkOnsets", "sfx_library", "sfx_onCuts", "status_add", "sticker_add", "style_apply",
                          "timeline_delete", "timeline_move", "timeline_trim", "title_add", "transcript_timeline", "transition_add"],
        "screen-tutorial": ["audio_addMusic", "audio_checkDucking", "audio_clean", "captions_generate", "clip_speed", "cover_make", "cover_set", "cursor_style",
                            "edit_autoZoom", "effects_catalog", "export_render", "export_srt", "frame_contactSheet", "history_undo", "keys_overlay", "layout_apply",
                            "layout_presets", "media_list", "project_format", "project_new", "project_save", "recording_check", "recording_import", "rules_check",
                            "transcript_deleteWords", "transcript_fillers", "transcript_run", "transcript_timeline", "voice_say"],
        "voice-over-video": ["audio_addMusic", "audio_checkDucking", "brandkit_apply", "captions_generate", "clip_set", "effect_add", "effects_catalog",
                             "effects_preview", "export_render", "export_srt", "frame_contactSheet", "generate_check", "generate_providers", "media_import",
                             "media_list", "motion_add", "profile_create", "project_new", "project_save", "project_state", "rules_check", "sfx_add",
                             "sfx_library", "text_read", "timeline_place", "timeline_trim", "track_add", "voice_lexicon", "voice_list", "voice_preview",
                             "voice_say"],
        "prompt-to-reel": ["audio_addMusic", "audio_checkDucking", "brandkit_apply", "brandkit_list", "captions_checkTiming", "captions_clear",
                           "captions_generate", "clip_place", "effects_catalog", "export_render", "export_srt", "frame_contactSheet", "frame_render",
                           "generate_check", "generate_providers", "graphics_checkLayout", "graphics_hyperframes", "media_import", "media_list", "motion_add",
                           "project_new", "project_save", "rules_check", "sfx_add", "sfx_checkOnsets", "sfx_library", "timeline_place", "title_add", "track_add",
                           "transition_add", "voice_list", "voice_preview", "voice_say"],
    ]
    #expect(Set(named.keys) == Set(Recipes.all.map(\.name)))
    for r in Recipes.all {
        let words = Set(r.text().components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "_")).inverted))
        let lost = try #require(named[r.name]).filter { !words.contains($0) }
        #expect(lost.isEmpty, "\(r.name) no longer names \(lost)")
    }
}
