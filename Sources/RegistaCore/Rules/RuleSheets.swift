import Foundation

// Editing rules (#31): one Markdown sheet per kind of video plus one for every video. A sheet is a small header that
// switches the checks (one line per check: `id: on|off [number]`, between two `---` lines), sets the person's choices
// (one line per choice: `id: option [number]`, RuleChoices.swift) and the prose an agent reads
// before editing. The defaults ship inside the app in the four interface languages; a user's sheet in `rules/` of
// Regista's support folder replaces the default of its kind, and a sheet there with another name is a kind of the
// user's own. Checks are code (RuleCheck.swift); the sheets only switch them and set their numbers.

/// Marks an English phrase the interface looks up in its tables (keyed by the English text, as the engine manifest's
/// phrases are): scripts/l10n.py finds every call of it and checks its text is in every table.
@inline(__always) func rulePhrase(_ english: String) -> String { english }

/// A text for the person: the English sentence (what an agent reads), its lookup key and the values that fill it.
/// Numbers stay numbers (#47): the engine's English sentence writes them with a point, the interface in its own language.
public struct RuleText: Hashable, Sendable {
    /// A value that fills a placeholder.
    public enum Arg: Hashable, Sendable {
        /// Words (a check's id, a title's text, a kind).
        case text(String)
        /// A number, with the decimals the English sentence shows ("0.30": 2; nil: as few as it needs).
        case number(Double, decimals: Int?)

        var english: String {
            switch self {
            case .text(let s): s
            case .number(let v, let d?): String(format: "%.\(d)f", v)
            case .number(let v, nil): RuleSheetText.format(v)
            }
        }

        var json: JSONValue {
            switch self {
            case .text(let s): .string(s)
            case .number(let v, _): .number(v)
            }
        }
    }

    public var key: String
    public var args: [Arg]

    init(_ key: String, _ args: Arg...) {
        self.key = key
        self.args = args
    }

    public var english: String { args.isEmpty ? key : String(format: key, arguments: args.map { $0.english as CVarArg }) }

    public var json: JSONValue {
        ["message": .string(english), "messageKey": .string(key), "messageArgs": .array(args.map(\.json))]
    }

    /// Seconds as the messages give them: rounded to the hundredth ("1.25" in the English sentence).
    static func s(_ t: MediaTime) -> Arg { s(t.seconds) }
    static func s(_ v: Double) -> Arg { .number((v * 100).rounded() / 100, decimals: 2) }
    /// A whole number (a line of a sheet, pixels).
    static func n(_ v: Double) -> Arg { .number(v.rounded(), decimals: 0) }
    static func n(_ v: Int) -> Arg { .number(Double(v), decimals: 0) }
}

/// A check a sheet can switch: id, title, and its number when it has one.
public struct RuleCheckSpec: Sendable {
    public struct Number: Sendable {
        public var defaultValue: Double
        public var unit: String
        public var range: ClosedRange<Double>
        /// What the number is, in English (a lookup key).
        public var meaning: String
    }

    public var id: String
    /// English title (a lookup key).
    public var title: String
    public var number: Number?

    public static let all: [RuleCheckSpec] = [
        RuleCheckSpec(id: "title-captions", title: rulePhrase("No captions while the opening title is on screen")),
        RuleCheckSpec(id: "logo-captions", title: rulePhrase("No captions on the closing logo")),
        RuleCheckSpec(id: "logo-pause", title: rulePhrase("A clean pause before the logo"),
                      number: Number(defaultValue: 0.3, unit: "s", range: 0...5,
                                     meaning: rulePhrase("Minimum seconds between the last spoken word and the logo"))),
        RuleCheckSpec(id: "logo-end", title: rulePhrase("The logo only at the end")),
        RuleCheckSpec(id: "face-clear", title: rulePhrase("No logo or title over the speaker's face")),
        RuleCheckSpec(id: "text-size", title: rulePhrase("Minimum text size"),
                      number: Number(defaultValue: 28, unit: "px", range: 1...500,
                                     meaning: rulePhrase("Smallest text, in pixels on a 1080-wide frame"))),
    ]

    public static func named(_ id: String) -> RuleCheckSpec? { all.first { $0.id == id } }
    public static var ids: [String] { all.map(\.id) }
}

/// A sheet's text split into its header (the check switches) and its prose, with what is wrong in the header.
public struct RuleSheetText: Sendable {
    public struct Entry: Hashable, Sendable {
        /// 1-based line of the file.
        public var line: Int
        public var id: String
        public var on: Bool
        public var value: Double?
    }

    public struct Problem: Hashable, Sendable {
        public var line: Int?
        public var text: RuleText
        public var json: JSONValue {
            var o = text.json.objectValue!
            o["line"] = line.map { .number(Double($0)) } ?? .null
            return .object(o)
        }
    }

    /// The header's lines as written (nil: the file has no header).
    public var header: [String]?
    /// A choice's valid line: the option chosen and its number when it has one.
    public struct ChoiceEntry: Hashable, Sendable {
        /// 1-based line of the file.
        public var line: Int
        public var id: String
        public var value: String
        public var number: [Double]?
    }

    /// Valid lines, first occurrence of each id.
    public var entries: [Entry] = []
    /// Valid choice lines, first occurrence of each id.
    public var choices: [ChoiceEntry] = []
    public var problems: [Problem] = []
    public var prose: String

    public static func parse(_ text: String) -> RuleSheetText {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if let first = lines.first, first.hasPrefix("\u{FEFF}") { lines[0] = String(first.dropFirst()) }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return RuleSheetText(header: nil, prose: text)
        }
        guard let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            // Not closed: nothing is taken as a switch, and the person is told.
            return RuleSheetText(header: nil, problems: [Problem(line: 1, text: RuleText(rulePhrase("The header has no closing ---: its switches are ignored.")))],
                                 prose: text)
        }
        var sheet = RuleSheetText(header: Array(lines[1..<close]), prose: lines[(close + 1)...].joined(separator: "\n"))
        if sheet.prose.hasPrefix("\n") { sheet.prose.removeFirst() }
        var seen = Set<String>()
        for (k, raw) in lines[1..<close].enumerated() {
            let n = k + 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let malformed = Problem(line: n, text: RuleText(rulePhrase("Line %1$@: write «id: on» or «id: off», then the number when the check has one."), RuleText.n(n)))
            guard let colon = line.firstIndex(of: ":") else { sheet.problems.append(malformed); continue }
            let id = line[..<colon].trimmingCharacters(in: .whitespaces)
            let words = line[line.index(after: colon)...].split(whereSeparator: \.isWhitespace).map(String.init)
            // A skill's own lines (its title, the recipe it is based on): read by SkillFile, not switches.
            if SkillFile.metaKeys.contains(id.lowercased()) { continue }
            if let choice = RuleChoiceSpec.named(id) {
                if let problem = sheet.readChoice(choice, words, line: n, seen: &seen) { sheet.problems.append(problem) }
                continue
            }
            guard let spec = RuleCheckSpec.named(id) else {
                sheet.problems.append(Problem(line: n, text: RuleText(rulePhrase("Line %1$@: unknown check or choice «%2$@»."), RuleText.n(n), .text(id))))
                continue
            }
            guard let state = words.first?.lowercased(), state == "on" || state == "off", words.count <= 2 else {
                sheet.problems.append(malformed)
                continue
            }
            var value: Double?
            if words.count == 2 {
                guard let number = spec.number else {
                    sheet.problems.append(Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ takes no number."), RuleText.n(n), .text(id))))
                    continue
                }
                var w = words[1].replacingOccurrences(of: ",", with: ".")
                if w.hasSuffix(number.unit) { w.removeLast(number.unit.count) }
                guard let v = Double(w), v.isFinite else {
                    sheet.problems.append(Problem(line: n, text: RuleText(rulePhrase("Line %1$@: «%2$@» is not a number."), RuleText.n(n), .text(words[1]))))
                    continue
                }
                guard number.range.contains(v) else {
                    sheet.problems.append(Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ must be between %3$@ and %4$@."), RuleText.n(n), .text(id),
                                                                          .number(number.range.lowerBound, decimals: nil),
                                                                          .number(number.range.upperBound, decimals: nil))))
                    continue
                }
                value = v
            }
            guard !seen.contains(id) else {
                sheet.problems.append(Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ is listed twice; the first line counts."), RuleText.n(n), .text(id))))
                continue
            }
            seen.insert(id)
            sheet.entries.append(Entry(line: n, id: id, on: state == "on", value: value))
        }
        return sheet
    }

    /// A choice's line (`id: option [number]`): kept in `choices`, or the problem with it.
    private mutating func readChoice(_ choice: RuleChoiceSpec, _ words: [String], line n: Int, seen: inout Set<String>) -> Problem? {
        guard let value = words.first?.lowercased(), choice.option(value) != nil, words.count <= 2 else {
            return Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ is one of %3$@."), RuleText.n(n), .text(choice.id),
                                                  .text(choice.optionIDs.joined(separator: ", "))))
        }
        var number: [Double]?
        if words.count == 2 {
            guard let spec = choice.number else {
                return Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ takes no number."), RuleText.n(n), .text(choice.id)))
            }
            guard let v = choice.parse(words[1]) else {
                return spec.isRange
                    ? Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ takes two numbers, such as %3$@."), RuleText.n(n), .text(choice.id),
                                                      .text(RuleChoiceSpec.format(spec.defaultValue))))
                    : Problem(line: n, text: RuleText(rulePhrase("Line %1$@: «%2$@» is not a number."), RuleText.n(n), .text(words[1])))
            }
            guard !choice.outOfRange(v) else {
                return Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ must be between %3$@ and %4$@."), RuleText.n(n), .text(choice.id),
                                                      .number(spec.range.lowerBound, decimals: nil), .number(spec.range.upperBound, decimals: nil)))
            }
            number = v
        }
        guard seen.insert(choice.id).inserted else {
            return Problem(line: n, text: RuleText(rulePhrase("Line %1$@: %2$@ is listed twice; the first line counts."), RuleText.n(n), .text(choice.id)))
        }
        choices.append(ChoiceEntry(line: n, id: choice.id, value: value, number: number))
        return nil
    }

    /// "0.3", "28": a number as a header writes it.
    static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%g", v)
    }

    /// The header line of a check.
    static func line(_ id: String, on: Bool, value: Double?) -> String {
        "\(id): \(on ? "on" : "off")" + (value.map { " " + format($0) } ?? "")
    }

    /// The header line of a choice ("graphics: on 6-12").
    static func choiceLine(_ id: String, value: String, number: [Double]?) -> String {
        "\(id): \(value)" + (number.map { " " + RuleChoiceSpec.format($0) } ?? "")
    }

    /// The file: header (when there is one) and prose.
    static func compose(header: [String]?, prose: String) -> String {
        guard let header else { return prose }
        return (["---"] + header + ["---"]).joined(separator: "\n") + "\n" + prose
    }

    /// The file with these switches changed (a line rewritten where the check has one, appended otherwise; every other
    /// line kept as written).
    func setting(_ changes: [(id: String, on: Bool?, value: Double?)]) -> String {
        var header = self.header ?? []
        for c in changes {
            let current = entries.first { $0.id == c.id }
            let spec = RuleCheckSpec.named(c.id)
            let on = c.on ?? current?.on ?? true
            let value = spec?.number == nil ? nil : (c.value ?? current?.value)
            let text = Self.line(c.id, on: on, value: value)
            if let current { header[current.line - 2] = text } else { header.append(text) }
        }
        return Self.compose(header: header, prose: prose)
    }

    /// The file with these choices changed: the line of each one rewritten (its number kept unless a new one is given),
    /// appended when the header has none; every other line kept as written.
    func choosing(_ changes: [(id: String, value: String?, number: [Double]?)]) -> String {
        var header = self.header ?? []
        for c in changes {
            let current = choices.first { $0.id == c.id }
            let spec = RuleChoiceSpec.named(c.id)
            let value = c.value ?? current?.value ?? spec?.defaultOption ?? ""
            let number = spec?.number == nil ? nil : (c.number ?? current?.number)
            let text = Self.choiceLine(c.id, value: value, number: number)
            if let current { header[current.line - 2] = text } else { header.append(text) }
        }
        return Self.compose(header: header, prose: prose)
    }
}

/// Where the sheets are and what applies to a project.
public struct RuleBook: Sendable {
    public static let everyVideo = "every-video"
    public static let languages = ["it", "en", "fr", "pt"]
    /// The built-in kinds: the recipes with a rule sheet of their own (prompt-to-reel follows the voice-over video's).
    public static var builtInKinds: [String] { Recipes.all.filter { $0.kind == $0.name }.map(\.name) }

    /// The user's copies of the built-in sheets (`rules/` of Regista's support folder).
    public var directory: URL
    /// The person's skills (`skills/` beside `rules/`, #157): a kind of the user's own is the rules of a skill.
    public var skillsDirectory: URL

    /// `skills` defaults to `skills/` beside a folder named `rules`, else to `<folder>-skills` beside it.
    public init(directory: URL, skills: URL? = nil) {
        self.directory = directory
        let parent = directory.deletingLastPathComponent()
        skillsDirectory = skills ?? parent.appendingPathComponent(directory.lastPathComponent == "rules" ? "skills" : directory.lastPathComponent + "-skills",
                                                                  isDirectory: true)
    }

    /// `$REGISTA_SUPPORT_DIR/rules`, else `~/Library/Application Support/Regista/rules`.
    public static var defaultDirectory: URL {
        if let s = ProcessInfo.processInfo.environment["REGISTA_SUPPORT_DIR"], !s.isEmpty {
            return URL(fileURLWithPath: EngineConfig.expand(s)).appendingPathComponent("rules", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Regista/rules", isDirectory: true)
    }

    /// English title of a built-in sheet (a lookup key).
    public static func builtInTitle(_ kind: String) -> String? {
        switch kind {
        case everyVideo: rulePhrase("For every video")
        case "talking-head-reel": rulePhrase("Talking-head reel")
        case "screen-tutorial": rulePhrase("Screen tutorial")
        case "voice-over-video": rulePhrase("Voice-over video")
        case "reel-graphics": rulePhrase("Graphics on a reel")
        case "prompt-to-reel": rulePhrase("Reel from one sentence")
        default: nil
        }
    }

    /// The interface language: the app's own choice, else the system's first language, among the four (else English).
    public static func interfaceLanguage() -> String {
        let domain = UserDefaults.standard.persistentDomain(forName: "com.arkad.regista")
        let candidates = ((domain?["AppleLanguages"] as? [String]) ?? []) + Locale.preferredLanguages
        return candidates.map { String($0.prefix(2)) }.first { languages.contains($0) } ?? "en"
    }

    static func isBuiltIn(_ kind: String) -> Bool { kind == everyVideo || builtInKinds.contains(kind) }

    /// A name no skill of the person's can take: a built-in sheet's or a built-in recipe's.
    static func isReserved(_ name: String) -> Bool { isBuiltIn(name) || Recipes.named(name) != nil }

    /// A valid slug for a kind of the user's: lower-case letters, digits and hyphens.
    static func isSlug(_ s: String) -> Bool {
        s.range(of: #"^[a-z0-9][a-z0-9-]{0,47}$"#, options: .regularExpression) != nil
    }

    /// The file of a sheet: the user's copy of a built-in sheet in `rules/`, a skill's file in `skills/`.
    public func file(_ kind: String) -> URL {
        (Self.isBuiltIn(kind) ? directory : skillsDirectory).appendingPathComponent("\(kind).md")
    }

    /// The kinds of the user's own: the person's skills (#157), sorted by file name.
    public var userKinds: [String] {
        migrateKinds()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: skillsDirectory.path)) ?? []
        return names.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.filter { !Self.isReserved($0) && Self.isSlug($0) }.sorted()
    }

    /// Every kind a project can have.
    public var kinds: [String] { Self.builtInKinds + userKinds }

    public func exists(_ kind: String) -> Bool { Self.isBuiltIn(kind) || skill(kind) != nil }
    public func edited(_ kind: String) -> Bool { FileManager.default.fileExists(atPath: file(kind).path) }

    /// The sheet's text: the user's file, else the default in `language`; a skill's rules as a sheet (its header and
    /// prose rules, without its steps).
    public func text(_ kind: String, language: String) -> String? {
        guard Self.isBuiltIn(kind) else { return skill(kind)?.sheetText }
        if let data = FileManager.default.contents(atPath: file(kind).path) { return String(decoding: data, as: UTF8.self) }
        return RuleDefaults.text(kind, language: language)
    }

    /// A kind's title: the built-in title (English key), a skill's title, or the first `# ` heading of its rules.
    public func title(_ kind: String, language: String) -> String {
        if let t = Self.builtInTitle(kind) { return t }
        if let t = skill(kind)?.title { return t }
        let prose = RuleSheetText.parse(text(kind, language: language) ?? "").prose
        let heading = prose.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
        return heading.map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) } ?? kind
    }

    /// What a check does on a kind and where that comes from.
    public struct CheckState: Sendable {
        public var spec: RuleCheckSpec
        public var on: Bool
        public var value: Double?
        /// "default", "every-video" or the kind.
        public var source: String

        public var json: JSONValue {
            var o: [String: JSONValue] = ["id": .string(spec.id), "title": .string(spec.title), "on": .bool(on), "source": .string(source)]
            if let n = spec.number {
                o["value"] = .number(value ?? n.defaultValue)
                o["default"] = .number(n.defaultValue)
                o["unit"] = .string(n.unit)
                o["meaning"] = .string(n.meaning)
            }
            return .object(o)
        }
    }

    /// The checks of `kind`: the defaults, then the "for every video" sheet's lines, then the kind's own.
    public func checks(_ kind: String, language: String) -> [CheckState] {
        var states = RuleCheckSpec.all.map { CheckState(spec: $0, on: true, value: $0.number?.defaultValue, source: "default") }
        for sheet in chain(kind) {
            for e in RuleSheetText.parse(text(sheet, language: language) ?? "").entries {
                guard let i = states.firstIndex(where: { $0.spec.id == e.id }) else { continue }
                states[i].on = e.on
                if let v = e.value { states[i].value = v }
                states[i].source = sheet
            }
        }
        return states
    }

    /// What a choice is on a kind and where that comes from.
    public struct ChoiceState: Sendable {
        public var spec: RuleChoiceSpec
        public var value: String
        public var number: [Double]?
        /// "default", "every-video" or the kind.
        public var source: String

        public var json: JSONValue {
            var o = spec.json.objectValue!
            o["value"] = .string(value)
            o["source"] = .string(source)
            if let option = spec.option(value) {
                o["label"] = .string(option.label)
                o["optionMeaning"] = option.meaning.json
            }
            if let n = spec.number, case .object(var no)? = o["number"] {
                no["value"] = RuleChoiceSpec.json(number ?? n.defaultValue)
                o["number"] = .object(no)
            }
            return .object(o)
        }
    }

    /// The choices of `kind` (those that apply to it; `all`: every choice): the defaults, then the "for every video" sheet's
    /// lines, then the kind's own.
    public func choices(_ kind: String, language: String, all: Bool = false) -> [ChoiceState] {
        var states = RuleChoiceSpec.all.filter { all || $0.applies(to: kind) }
            .map { ChoiceState(spec: $0, value: $0.defaultOption, number: $0.number?.defaultValue, source: "default") }
        for sheet in chain(kind) {
            for e in RuleSheetText.parse(text(sheet, language: language) ?? "").choices {
                guard let i = states.firstIndex(where: { $0.spec.id == e.id }) else { continue }
                states[i].value = e.value
                if let n = e.number { states[i].number = n }
                states[i].source = sheet
            }
        }
        return states
    }

    /// The person's choices an agent reads with a recipe, after the rules: one line per choice of the kind, the option
    /// with what it does, the number with what it is.
    public func choicesBriefing(_ kind: String, language: String) -> String {
        var out = "# The person's choices (\(kind))\n\nWhat the person chose for this kind of video (rules.get reads them; rules.set changes "
            + "one only when the person asks; Settings › Rules in the app)."
        for c in choices(kind, language: language) {
            out += "\n- \(c.spec.id): \(c.value)"
            if let option = c.spec.option(c.value) { out += " — " + option.meaning.english }
            if let n = c.spec.number {
                out += " \(n.meaning): \(RuleChoiceSpec.format(c.number ?? n.defaultValue))\(n.unit == "s" ? " s" : n.unit)."
            }
        }
        return out
    }

    /// The headings of a sheet's optional names section, in the four languages.
    static let namesHeadings: Set<String> = ["nomi", "names", "noms", "nomes"]

    /// How the person spells names (`Wrong → Right`, one per line): the lines of the «Nomi» / «Names» / «Noms» / «Nomes»
    /// sections of the sheets `kind` reads ("For every video", the recipe a skill is based on, the kind or skill), in
    /// that order, each once. A line with a code span is an example (the shipped sheets carry one), not a name.
    public func names(_ kind: String, language: String) -> [String] {
        var out: [String] = []
        for sheet in chain(kind) {
            var inside = false
            for raw in RuleSheetText.parse(text(sheet, language: language) ?? "").prose.components(separatedBy: "\n") {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    inside = line.hasPrefix("## ") && Self.namesHeadings.contains(line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased())
                    continue
                }
                guard inside, !line.contains("`") else { continue }
                var entry = line
                if entry.hasPrefix("- ") || entry.hasPrefix("* ") { entry = entry.dropFirst(2).trimmingCharacters(in: .whitespaces) }
                guard entry.contains("→") || entry.contains("->"), !out.contains(entry) else { continue }
                out.append(entry)
            }
        }
        return out
    }

    /// What recipe.get says first when the person wrote names: the names, for captions, titles and fixes.
    public func namesBriefing(_ kind: String, language: String) -> String? {
        let names = names(kind, language: language)
        guard !names.isEmpty else { return nil }
        return "Names as the person spells them (the Names sections of their sheets and skill): spell them so in captions and titles, "
            + "and pass them to captions_generate as fixes.\n" + names.map { "- " + $0 }.joined(separator: "\n")
    }

    /// Header problems of the sheets that apply to `kind`, each with its sheet.
    public func problems(_ kind: String, language: String) -> [(sheet: String, problem: RuleSheetText.Problem)] {
        chain(kind).flatMap { sheet in
            RuleSheetText.parse(text(sheet, language: language) ?? "").problems.map { (sheet, $0) }
        }
    }

    /// The kind a frame of this size gets when the project has none of its own: landscape frames screen-tutorial, the
    /// rest talking-head-reel.
    public static func kind(width: Int, height: Int) -> String { width > height ? "screen-tutorial" : "talking-head-reel" }

    /// A project's kind: the stored one when it still exists, else from its format (16:9 and other landscape frames:
    /// screen-tutorial; the rest: talking-head-reel). `note` says why a stored kind was not used.
    public func kind(of project: Project) -> (kind: String, source: String, note: RuleText?) {
        let fromFormat = Self.kind(width: project.settings.width, height: project.settings.height)
        guard let stored = project.kind else { return (fromFormat, "format", nil) }
        guard exists(stored), stored != Self.everyVideo else {
            return (fromFormat, "format", RuleText(rulePhrase("The project's kind «%1$@» no longer exists: the rules of «%2$@» apply."), .text(stored), .text(fromFormat)))
        }
        return (stored, "project", nil)
    }

    /// Whether the project's kind has «The logo only at the end» on (#74): a logo added with no time of its own then goes
    /// in the closing seconds of the video, and the switches that add it say so.
    public func logoOnlyAtEnd(_ project: Project) -> Bool {
        checks(kind(of: project).kind, language: "en").first { $0.spec.id == "logo-end" }?.on ?? false
    }

    /// The rules an agent reads with a recipe: the checks that run, then the prose of "for every video" and of the kind.
    public func briefing(_ kind: String, language: String) -> String {
        let on = checks(kind, language: language).filter(\.on).map { c -> String in
            c.spec.number.map { "\(c.spec.id) (\(RuleSheetText.format(c.value ?? $0.defaultValue)) \($0.unit))" } ?? c.spec.id
        }
        var out = "# Editing rules (\(kind))\n\nThese rules come from the user's rule sheets (rules.get / rules.set; Settings › Rules in the app) "
            + "and always hold. Before export run rules.check: export.render refuses while a check fails. Checks on: "
            + (on.isEmpty ? "none" : on.joined(separator: ", ")) + "."
        for sheet in chain(kind) {
            let prose = RuleSheetText.parse(text(sheet, language: language) ?? "").prose.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prose.isEmpty { out += "\n\n" + prose }
        }
        return out
    }
}

/// The default sheets, compiled in (Sources/RegistaCore/Rules/Sheets/<kind>.<language>.md).
enum RuleDefaults {
    static func text(_ kind: String, language: String) -> String? {
        let lang = RuleBook.languages.contains(language) ? language : "en"
        return table["\(kind).\(lang)"].map { String(decoding: $0, as: UTF8.self) }
    }

    static let table: [String: [UInt8]] = [
        "every-video.it": PackageResources.every_video_it_md, "every-video.en": PackageResources.every_video_en_md,
        "every-video.fr": PackageResources.every_video_fr_md, "every-video.pt": PackageResources.every_video_pt_md,
        "talking-head-reel.it": PackageResources.talking_head_reel_it_md, "talking-head-reel.en": PackageResources.talking_head_reel_en_md,
        "talking-head-reel.fr": PackageResources.talking_head_reel_fr_md, "talking-head-reel.pt": PackageResources.talking_head_reel_pt_md,
        "screen-tutorial.it": PackageResources.screen_tutorial_it_md, "screen-tutorial.en": PackageResources.screen_tutorial_en_md,
        "screen-tutorial.fr": PackageResources.screen_tutorial_fr_md, "screen-tutorial.pt": PackageResources.screen_tutorial_pt_md,
        "voice-over-video.it": PackageResources.voice_over_video_it_md, "voice-over-video.en": PackageResources.voice_over_video_en_md,
        "voice-over-video.fr": PackageResources.voice_over_video_fr_md, "voice-over-video.pt": PackageResources.voice_over_video_pt_md,
        "reel-graphics.it": PackageResources.reel_graphics_it_md, "reel-graphics.en": PackageResources.reel_graphics_en_md,
        "reel-graphics.fr": PackageResources.reel_graphics_fr_md, "reel-graphics.pt": PackageResources.reel_graphics_pt_md,
    ]
}
