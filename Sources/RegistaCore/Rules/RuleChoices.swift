import Foundation

// The person's choices (one regia): what the editing rules leave to the person who edits — caption style, pace, framing,
// music… A choice is a header line of a rule sheet like a check's (`id: value [number]`), resolved like the checks: the
// kind's sheet over the "For every video" sheet over the default written here. Claude reads them with the recipe
// (recipe.get), the app shows them in Settings › Rules; the rules themselves (what always holds) stay checks and prose.

/// A choice a sheet can set: its options (each with what it means), its default, its number when it has one, and the
/// kinds of video it applies to.
public struct RuleChoiceSpec: Sendable {
    public struct Option: Sendable {
        public var id: String
        /// English label (a lookup key).
        public var label: String
        /// What the option does, in English (a lookup key, with its numbers as values).
        public var meaning: RuleText
        /// The numbers the option stands for (a pace's pauses), by name.
        public var values: [String: Double] = [:]
    }

    /// The choice's own number (a zoom, seconds), or a range of two (from–to).
    public struct Number: Sendable {
        /// One value, or two for a range.
        public var defaultValue: [Double]
        public var unit: String
        public var range: ClosedRange<Double>
        /// What the number is, in English (a lookup key).
        public var meaning: String
        public var isRange: Bool { defaultValue.count == 2 }
    }

    public var id: String
    /// English title (a lookup key).
    public var title: String
    /// What the choice is about, in English (a lookup key).
    public var meaning: String
    /// The part of the regia it belongs to: opening, picture, text, sound, ending.
    public var section: String
    public var options: [Option]
    public var defaultOption: String
    public var number: Number?
    /// The built-in kinds it applies to (nil: every kind). A kind of the user's own gets every choice.
    public var kinds: [String]? = nil

    public func option(_ id: String) -> Option? { options.first { $0.id == id } }
    public var optionIDs: [String] { options.map(\.id) }

    /// Whether the choice is one of `kind`'s: every choice belongs to "for every video" and to a kind of the user's own.
    public func applies(to kind: String) -> Bool {
        guard let kinds, kind != RuleBook.everyVideo, RuleBook.builtInKinds.contains(kind) else { return true }
        return kinds.contains(kind)
    }

    static func option(_ id: String, _ label: String, _ meaning: String, _ args: RuleText.Arg..., values: [String: Double] = [:]) -> Option {
        var text = RuleText(meaning)
        text.args = args
        return Option(id: id, label: label, meaning: text, values: values)
    }

    /// A pace: pauses longer than `maxPause` are cut, keeping `keepPause` of breath on each side (edit.autoCut).
    static func pace(_ id: String, _ label: String, maxPause: Double, keepPause: Double) -> Option {
        option(id, label, rulePhrase("Pauses up to %1$@ s stay; longer ones are cut, keeping %2$@ s of breath."),
               .number(maxPause, decimals: nil), .number(keepPause, decimals: nil), values: ["maxPause": maxPause, "keepPause": keepPause])
    }

    public static let all: [RuleChoiceSpec] = [
        // Opening
        RuleChoiceSpec(id: "opening-title", title: rulePhrase("Opening title"), meaning: rulePhrase("A title over the first seconds"), section: "opening",
                       options: [option("off", rulePhrase("Off"), rulePhrase("No title: the face and the first sentence open the video.")),
                                 option("on", rulePhrase("On"), rulePhrase("A short title over the first seconds, with no captions under it."))],
                       defaultOption: "off"),
        RuleChoiceSpec(id: "hook", title: rulePhrase("How it opens"), meaning: rulePhrase("What the first seconds show"), section: "opening",
                       options: [option("question", rulePhrase("Question"), rulePhrase("It opens on a question the video answers.")),
                                 option("statement", rulePhrase("Statement"), rulePhrase("It opens on the point, said straight away.")),
                                 option("picture", rulePhrase("Picture"), rulePhrase("It opens on a picture that shows the point."))],
                       defaultOption: "statement"),
        RuleChoiceSpec(id: "structure", title: rulePhrase("Structure"), meaning: rulePhrase("How the video is built"), section: "opening",
                       options: [option("free", rulePhrase("Free"), rulePhrase("It follows what is said, with no set shape.")),
                                 option("list", rulePhrase("List"), rulePhrase("A few points in order, each one shown.")),
                                 option("workflow", rulePhrase("Steps"), rulePhrase("Steps one after another, from the start to the result.")),
                                 option("product", rulePhrase("Product"), rulePhrase("The problem, the product, what it changes."))],
                       defaultOption: "free"),
        // Picture
        RuleChoiceSpec(id: "pace", title: rulePhrase("Pace"), meaning: rulePhrase("How long the pauses between sentences last"), section: "picture",
                       options: [pace("calm", rulePhrase("Calm"), maxPause: 1.2, keepPause: 0.25),
                                 pace("normal", rulePhrase("Normal"), maxPause: 0.7, keepPause: 0.12),
                                 pace("fast", rulePhrase("Fast"), maxPause: 0.4, keepPause: 0.06)],
                       defaultOption: "normal", kinds: ["talking-head-reel", "screen-tutorial", "voice-over-video"]),
        RuleChoiceSpec(id: "framing", title: rulePhrase("Framing"), meaning: rulePhrase("Changes of framing that hide the cuts"), section: "picture",
                       options: [option("still", rulePhrase("Still"), rulePhrase("One framing for the whole video.")),
                                 option("alternate", rulePhrase("By line"), rulePhrase("A punch-in when the line of the script changes.")),
                                 option("alternate-cut", rulePhrase("At every cut"), rulePhrase("The framing changes at every cut."))],
                       defaultOption: "alternate",
                       number: Number(defaultValue: [1.15], unit: "×", range: 1...2, meaning: rulePhrase("How much closer the punch-in is")),
                       kinds: ["talking-head-reel"]),
        RuleChoiceSpec(id: "colour", title: rulePhrase("Colour"), meaning: rulePhrase("A touch-up of the picture"), section: "picture",
                       options: [option("none", rulePhrase("None"), rulePhrase("The picture as it was filmed.")),
                                 option("light", rulePhrase("Light"), rulePhrase("A light grade: a little contrast and warmth.")),
                                 option("look", rulePhrase("Look"), rulePhrase("A look from the catalogue."))],
                       defaultOption: "light"),
        RuleChoiceSpec(id: "format", title: rulePhrase("Format"), meaning: rulePhrase("The video's output format"), section: "picture",
                       options: [option("project", rulePhrase("The project's"), rulePhrase("The format the project already has.")),
                                 option("9:16", "9:16", rulePhrase("Vertical, for reels and stories.")),
                                 option("4:5", "4:5", rulePhrase("Portrait, for the feed.")),
                                 option("1:1", "1:1", rulePhrase("Square, for the feed.")),
                                 option("16:9", "16:9", rulePhrase("Landscape, for YouTube and the web."))],
                       defaultOption: "project"),
        // Text
        RuleChoiceSpec(id: "captions", title: rulePhrase("Caption style"), meaning: rulePhrase("How the captions look"), section: "text",
                       options: [option("talking-head-v1", rulePhrase("Talking head"), rulePhrase("Large capitals, a few words at a time, the keyword on a coloured box.")),
                                 option("elegant-serif", rulePhrase("Elegant serif"), rulePhrase("An italic serif in sentence case, the keyword in a soft colour.")),
                                 option("bold-keyword", rulePhrase("Bold keyword"), rulePhrase("A bold sans on up to two lines, the keyword in the brand's colour.")),
                                 option("ghost-karaoke", rulePhrase("Ghost karaoke"), rulePhrase("The whole line shown faint, each word lighting up as it is said.")),
                                 option("none", rulePhrase("No captions"), rulePhrase("The video has no captions."))],
                       defaultOption: "talking-head-v1"),
        RuleChoiceSpec(id: "keywords", title: rulePhrase("Keywords"), meaning: rulePhrase("Words highlighted in the captions"), section: "text",
                       options: [option("on", rulePhrase("On"), rulePhrase("One or two words per line stand out.")),
                                 option("off", rulePhrase("Off"), rulePhrase("Every word looks the same."))],
                       defaultOption: "on"),
        RuleChoiceSpec(id: "graphics", title: rulePhrase("Graphics before delivering"), meaning: rulePhrase("Proposals from the catalogue before the video is delivered"),
                       section: "text",
                       options: [option("off", rulePhrase("Off"), rulePhrase("The video is delivered as edited, with no proposals.")),
                                 option("on", rulePhrase("On"), rulePhrase("Graphics from the catalogue are proposed before delivering."))],
                       defaultOption: "on",
                       number: Number(defaultValue: [6, 12], unit: "", range: 0...40, meaning: rulePhrase("How many proposals, from–to"))),
        // Sound
        RuleChoiceSpec(id: "music", title: rulePhrase("Background music"), meaning: rulePhrase("A music bed under the voice"), section: "sound",
                       options: [option("on-request", rulePhrase("On request"), rulePhrase("Music only when the person asks for it.")),
                                 option("never", rulePhrase("Never"), rulePhrase("No music.")),
                                 option("bed", rulePhrase("Bed"), rulePhrase("A music bed under the whole video, lowered under the voice."))],
                       defaultOption: "on-request"),
        RuleChoiceSpec(id: "sfx", title: rulePhrase("Sound effects"), meaning: rulePhrase("Sounds on what happens in the picture"), section: "sound",
                       options: [option("none", rulePhrase("None"), rulePhrase("No sound effects.")),
                                 option("sparse", rulePhrase("Sparse"), rulePhrase("A few quiet sounds on the key moments.")),
                                 option("actions", rulePhrase("Every action"), rulePhrase("A sound on every action on screen: a click, an entrance."))],
                       defaultOption: "sparse"),
        RuleChoiceSpec(id: "faceless-sound", title: rulePhrase("Sound without a face"), meaning: rulePhrase("Silence and sound around the turn, in videos with no one on camera"),
                       section: "sound",
                       options: [option("plain", rulePhrase("Plain"), rulePhrase("Voice and music, with no directed silences.")),
                                 option("directed", rulePhrase("Directed"), rulePhrase("A near-silence before the turn, a sound that leads into the next picture (J-cut)."))],
                       defaultOption: "directed", kinds: ["voice-over-video"]),
        // Ending
        RuleChoiceSpec(id: "closing-logo", title: rulePhrase("Closing logo"), meaning: rulePhrase("The logo at the end of the video"), section: "ending",
                       options: [option("brand", rulePhrase("From the brand"), rulePhrase("The brand kit's logo, when the project's kit has one.")),
                                 option("on", rulePhrase("On"), rulePhrase("A logo at the end, always.")),
                                 option("off", rulePhrase("Off"), rulePhrase("No logo at the end."))],
                       defaultOption: "brand",
                       number: Number(defaultValue: [2], unit: "s", range: 0.5...10, meaning: rulePhrase("Seconds the logo stays"))),
    ]

    public static func named(_ id: String) -> RuleChoiceSpec? { all.first { $0.id == id } }
    public static var ids: [String] { all.map(\.id) }

    /// "1.15", "6-12": a choice's number as a header writes it.
    public static func format(_ values: [Double]) -> String { values.map(RuleSheetText.format).joined(separator: "-") }

    /// A number as the commands return it: one value, or [from, to].
    static func json(_ values: [Double]) -> JSONValue { values.count == 1 ? .number(values[0]) : .array(values.map { .number($0) }) }

    /// The choice as rules.list describes it: the options with what each does, the default, the number, the kinds.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(id), "title": .string(title), "meaning": .string(meaning), "section": .string(section),
            "default": .string(defaultOption),
            "options": .array(options.map { option in
                var m = option.meaning.json.objectValue!
                m["id"] = .string(option.id)
                m["label"] = .string(option.label)
                if !option.values.isEmpty { m["values"] = .object(option.values.mapValues { .number($0) }) }
                return .object(m)
            }),
            "kinds": kinds.map { .array($0.map { .string($0) }) } ?? .null,
        ]
        if let n = number {
            o["number"] = ["default": Self.json(n.defaultValue), "unit": .string(n.unit), "meaning": .string(n.meaning),
                           "min": .number(n.range.lowerBound), "max": .number(n.range.upperBound)]
        }
        return .object(o)
    }

    /// The number of a header or a command ("1,2", "1.2×", "6-12", "6–12"): nil when it is not one this choice takes.
    func parse(_ word: String) -> [Double]? {
        guard let number else { return nil }
        var w = word.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: "–", with: "-")
        if !number.unit.isEmpty, w.hasSuffix(number.unit) { w.removeLast(number.unit.count) }
        if number.unit == "×", w.hasSuffix("x") { w.removeLast() }
        let parts = number.isRange ? w.split(separator: "-", omittingEmptySubsequences: false).map(String.init) : [w]
        guard parts.count == number.defaultValue.count else { return nil }
        let values = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter(\.isFinite)
        guard values.count == parts.count else { return nil }
        return values
    }

    /// The problem with a number this choice was given (out of its range, a range backwards), nil when it is fine.
    func outOfRange(_ values: [Double]) -> Bool {
        guard let number else { return true }
        return !values.allSatisfy(number.range.contains) || (values.count == 2 && values[0] > values[1])
    }
}
