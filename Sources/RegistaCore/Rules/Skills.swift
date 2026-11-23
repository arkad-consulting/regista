import Foundation

// The person's own ways of editing (#157). A skill is one Markdown file in `skills/` of Regista's support folder: a
// small header between two `---` lines (`title:`, `based-on:` a built-in recipe or `none`, then the check and choice
// lines it changes, as a rule sheet writes them), a `## Steps` section (the steps an agent follows) and a `## Rules`
// section (the prose rules it adds). Seen as a rule sheet (rules.get / rules.set, the checks, the choices), a skill is
// its header and its prose rules, with the header's line numbers as in the file. The built-in recipes are skills an
// agent and the person can read and duplicate, never edit.

/// A skill's file: the header as written (its title and based-on lines included), the steps and the prose rules.
public struct SkillFile: Sendable, Equatable {
    /// Header keys of a skill that are neither a check nor a choice.
    public static let metaKeys = ["title", "based-on"]
    static let stepsHeading = "## Steps"
    static let rulesHeading = "## Rules"
    /// The longest title a skill takes.
    public static let maxTitle = 80

    /// The header's lines as written, title and based-on included.
    public var header: [String]
    /// The steps (Markdown), without their heading.
    public var steps: String
    /// The prose rules (Markdown), without their heading.
    public var rules: String

    public init(title: String, basedOn: String?, lines: [String] = [], steps: String = "", rules: String = "") {
        header = ["title: \(title)", "based-on: \(basedOn ?? "none")"] + lines
        self.steps = Self.trimmed(steps)
        self.rules = Self.normalized(rules)
    }

    init(header: [String], steps: String, rules: String) {
        self.header = header
        self.steps = Self.trimmed(steps)
        self.rules = Self.normalized(rules)
    }

    /// Reads a skill's file. A file with no header gives a skill with no title (its first heading or its slug names it).
    public static func parse(_ text: String) -> SkillFile {
        let sheet = RuleSheetText.parse(text)
        let (steps, rules) = split(sheet.prose)
        return SkillFile(header: sheet.header ?? [], steps: steps, rules: rules)
    }

    /// The prose after a header: the `## Steps` section and the rest (the `## Rules` heading taken off).
    static func split(_ prose: String) -> (steps: String, rules: String) {
        var lines = prose.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var steps = ""
        if let s = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == stepsHeading }) {
            let e = lines[(s + 1)...].firstIndex { $0.hasPrefix("# ") || $0.hasPrefix("## ") } ?? lines.count
            steps = lines[(s + 1)..<e].joined(separator: "\n")
            lines.removeSubrange(s..<e)
        }
        if let r = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == rulesHeading }) { lines.remove(at: r) }
        return (trimmed(steps), lines.joined(separator: "\n"))
    }

    /// The file.
    public var text: String {
        var body = Self.stepsHeading + "\n\n"
        if !steps.isEmpty { body += steps + "\n\n" }
        body += Self.rulesHeading + "\n"
        if !rules.isEmpty { body += "\n" + rules }
        return RuleSheetText.compose(header: header, prose: body)
    }

    /// The skill as a rule sheet: its header as written (the line numbers of the file) and its prose rules.
    public var sheetText: String { RuleSheetText.compose(header: header, prose: rules) }

    /// A header value of the skill's own (title, based-on), nil when the header has none.
    public func meta(_ key: String) -> String? {
        for line in header {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == key else { continue }
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? nil : v
        }
        return nil
    }

    /// Writes a header value of the skill's own: its line rewritten, or put first (title before based-on).
    public mutating func setMeta(_ key: String, _ value: String) {
        let line = "\(key): \(value)"
        if let i = header.firstIndex(where: { l in l.firstIndex(of: ":").map { l[..<$0].trimmingCharacters(in: .whitespaces).lowercased() == key } ?? false }) {
            header[i] = line
        } else {
            header.insert(line, at: key == "title" ? 0 : (meta("title") == nil ? 0 : 1))
        }
    }

    public var title: String? { meta("title") }
    /// The built-in recipe it is based on (nil: none).
    public var basedOn: String? { meta("based-on").flatMap { $0.lowercased() == "none" ? nil : $0 } }

    /// A rule sheet's text written for this skill (rules.set): its header and prose become the skill's; the title and
    /// based-on lines stay when the new header has none; the steps stay.
    mutating func adoptSheet(_ text: String) {
        let sheet = RuleSheetText.parse(text)
        var next = SkillFile(header: sheet.header ?? [], steps: steps, rules: sheet.prose)
        for key in Self.metaKeys.reversed() where next.meta(key) == nil {
            if let v = meta(key) { next.setMeta(key, v) }
        }
        self = next
    }

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Prose rules as a file holds them: no blank lines before, one line end after (empty stays empty).
    static func normalized(_ s: String) -> String {
        var lines = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        let t = lines.joined(separator: "\n").replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        return t.isEmpty ? "" : t + "\n"
    }
}

extension Recipe {
    /// The steps of a built-in recipe: its `## Steps` section.
    public var steps: String { SkillFile.split(body).steps }
}

extension RuleBook {
    /// The person's skill `slug` (nil: there is none, or `slug` is built in).
    public func skill(_ slug: String) -> SkillFile? {
        guard !Self.isReserved(slug), Self.isSlug(slug) else { return nil }
        migrateKinds()
        return FileManager.default.contents(atPath: file(slug).path).map { SkillFile.parse(String(decoding: $0, as: UTF8.self)) }
    }

    /// The sheets a kind's checks, choices and prose come from, in order: "For every video", the built-in sheet a skill is
    /// based on, the kind itself.
    func chain(_ kind: String) -> [String] {
        if kind == Self.everyVideo { return [Self.everyVideo] }
        if Self.isBuiltIn(kind) { return [Self.everyVideo, kind] }
        let base = skill(kind)?.basedOn.flatMap { Recipes.named($0)?.kind }
        return [Self.everyVideo] + (base.map { [$0] } ?? []) + [kind]
    }

    /// The kinds of the user's own still in `rules/` (sheets made before skills) move to `skills/`, once: the sheet's header
    /// and prose become the skill's rules (its first heading its title), with no steps. A skill of that name already
    /// there is left as it is, and so is the old sheet.
    func migrateKinds() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasSuffix(".md") && !name.hasPrefix(".") {
            let kind = String(name.dropLast(3))
            let old = directory.appendingPathComponent(name), new = skillsDirectory.appendingPathComponent(name)
            guard !Self.isReserved(kind), Self.isSlug(kind), !fm.fileExists(atPath: new.path), let data = fm.contents(atPath: old.path) else { continue }
            let sheet = RuleSheetText.parse(String(decoding: data, as: UTF8.self))
            let (title, rules) = Skills.takeHeading(sheet.prose)
            let skill = SkillFile(header: ["title: \(title ?? kind)", "based-on: none"] + (sheet.header ?? []), steps: "", rules: rules)
            do {
                try fm.createDirectory(at: skillsDirectory, withIntermediateDirectories: true)
                try Data(skill.text.utf8).write(to: new, options: .atomic)
                try fm.removeItem(at: old)
            } catch { continue }
        }
    }
}

/// A file a command changed outside the project (a skill): history.undo puts its bytes back (nil: no file), redo the new ones.
public struct FileChange: Sendable {
    public var file: URL
    public var before: Data?
    public var after: Data?

    /// Runs `body` (which writes or removes `file`) and returns its result with the change it made.
    static func record<T>(_ file: URL, _ body: () throws -> T) throws -> (T, FileChange) {
        let before = FileManager.default.contents(atPath: file.path)
        let result = try body()
        return (result, FileChange(file: file, before: before, after: FileManager.default.contents(atPath: file.path)))
    }

    /// Makes `file` hold `data` (nil removes it).
    static func restore(_ data: Data?, to file: URL) throws {
        let fm = FileManager.default
        if let data {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } else if fm.fileExists(atPath: file.path) {
            try fm.removeItem(at: file)
        }
    }
}

/// What the skill commands share: the skill as they return it, the checks of a title, the import of an untrusted file.
enum Skills {
    /// The largest skill file the importer reads.
    static let maxBytes = 256 * 1024

    /// A prose's first `# ` heading and the prose without it (and without the blank lines after it).
    static func takeHeading(_ prose: String) -> (String?, String) {
        var lines = prose.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[i].hasPrefix("# ") else { return (nil, prose) }
        let title = String(lines[i].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        lines.removeSubrange(0...i)
        return (title.isEmpty ? nil : title, lines.joined(separator: "\n"))
    }

    /// A built-in recipe's title (an English lookup key).
    static func builtInTitle(_ recipe: Recipe) -> String { RuleBook.builtInTitle(recipe.name) ?? recipe.title }

    /// The person's skills, sorted by their file name.
    static func slugs(_ book: RuleBook) -> [String] { book.userKinds }

    /// A skill's title, as the person wrote it.
    static func title(_ slug: String, _ book: RuleBook) -> String { book.title(slug, language: "en") }

    /// A title a skill can have: one line of text, not too long, with letters or digits.
    static func checkTitle(_ raw: String, command: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= SkillFile.maxTitle,
              !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CommandError.invalid("\(command): a title is one line of text, at most \(SkillFile.maxTitle) characters")
        }
        return title
    }

    /// The person's skill whose title is `title` (letters compared without case or accents), if any.
    static func titled(_ title: String, _ book: RuleBook, except: String? = nil) -> String? {
        let key = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return slugs(book).first { $0 != except && Self.title($0, book).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == key }
    }

    /// A free file name for a new skill titled `title`: its slug, with -2, -3… when the name is taken.
    static func newSlug(_ title: String, _ book: RuleBook, command: String) throws -> String {
        var base = Rules.slug(title)
        if base.isEmpty { base = "skill" }
        if RuleBook.isReserved(base) {
            throw CommandError.conflict("\(command): «\(title)» is the name of a built-in kind of video — choose another title")
        }
        var slug = base, n = 2
        while FileManager.default.fileExists(atPath: book.file(slug).path) || RuleBook.isReserved(slug) {
            slug = "\(base.prefix(44))-\(n)"
            n += 1
        }
        guard RuleBook.isSlug(slug) else { throw CommandError.invalid("\(command): «\(title)» makes no file name: use letters or digits") }
        return slug
    }

    /// A built-in recipe or a skill of the person's, by name.
    static func require(_ name: String, _ book: RuleBook, command: String, own: Bool) throws -> (recipe: Recipe?, skill: SkillFile?) {
        if let r = Recipes.named(name) {
            guard !own else { throw CommandError.conflict("\(command): «\(name)» is a built-in recipe: it can be duplicated (skill.duplicate), never changed") }
            return (r, nil)
        }
        if let s = book.skill(name) { return (nil, s) }
        let mine = slugs(book)
        throw CommandError.notFound("\(command): no skill '\(name)' — skill.list lists them (yours: \(mine.isEmpty ? "none" : mine.joined(separator: ", "));"
            + " built in: \(Recipes.all.map(\.name).joined(separator: ", ")))")
    }

    /// Writes the skill's file and records the change (one undo step).
    static func write(_ skill: SkillFile, slug: String, _ book: RuleBook, _ ctx: inout CommandContext, command: String) throws {
        let url = book.file(slug)
        guard url.deletingLastPathComponent().standardizedFileURL.path == book.skillsDirectory.standardizedFileURL.path else {
            throw CommandError.invalid("\(command): '\(slug)' is not a file name of the skills folder")
        }
        let (_, change) = try FileChange.record(url) {
            do {
                try FileManager.default.createDirectory(at: book.skillsDirectory, withIntermediateDirectories: true)
                try Data(skill.text.utf8).write(to: url, options: .atomic)
            } catch {
                throw CommandError(.io, "\(command): cannot write \(url.path): \(error.localizedDescription)")
            }
        }
        ctx.fileChange = change
    }

    /// A skill as the commands return it: title, what it is based on, its steps; with `full`, its file, rules (the prose,
    /// the checks as they apply, the lines it writes), its choices resolved, the problems of its header.
    static func json(_ name: String, _ book: RuleBook, language: String, full: Bool) -> JSONValue {
        var o: [String: JSONValue]
        let kind: String
        if let r = Recipes.named(name) {
            kind = r.kind
            o = ["skill": .string(name), "title": .string(builtInTitle(r)), "builtIn": .bool(true), "basedOn": .null, "kind": .string(kind),
                 "path": .null, "steps": .string(r.steps)]
            if full { o["rules"] = ["prose": .string(RuleSheetText.parse(book.text(kind, language: language) ?? "").prose)] }
        } else {
            kind = name
            let s = book.skill(name) ?? SkillFile(header: [], steps: "", rules: "")
            o = ["skill": .string(name), "title": .string(title(name, book)), "builtIn": .bool(false), "basedOn": s.basedOn.map(JSONValue.string) ?? .null,
                 "kind": .string(name), "path": .string(book.file(name).path), "steps": .string(s.steps)]
            if full {
                let sheet = RuleSheetText.parse(s.sheetText)
                o["text"] = .string(s.text)
                o["rules"] = [
                    "prose": .string(s.rules),
                    "switches": .array(sheet.entries.map { e in ["id": .string(e.id), "on": .bool(e.on), "value": e.value.map { .number($0) } ?? .null] }),
                ]
                o["choiceLines"] = .array(sheet.choices.map { c in ["id": .string(c.id), "value": .string(c.value), "number": c.number.map(RuleChoiceSpec.json) ?? .null] })
                o["status"] = ["ok": .bool(sheet.problems.isEmpty), "problems": .array(sheet.problems.map(\.json))]
            }
        }
        if full, case .object(var rules)? = o["rules"] {
            rules["checks"] = .array(book.checks(kind, language: language).map(\.json))
            o["rules"] = .object(rules)
            o["choices"] = .array(book.choices(kind, language: language).map(\.json))
            o["language"] = .string(language)
        }
        return .object(o)
    }

    // MARK: Parts given by a command

    /// A `basedOn` param: a built-in recipe, or none.
    static func basedOn(_ raw: String?, command: String) throws -> String? {
        guard let raw, raw != "none", !raw.isEmpty else { return nil }
        guard Recipes.named(raw) != nil else {
            throw CommandError.invalid("\(command): basedOn is a built-in recipe (\(Recipes.all.map(\.name).joined(separator: ", "))) or none")
        }
        return raw
    }

    /// Applies a `rules` param ({prose?, checks?}) and a `choices` param to `skill`; unknown keys are refused with the list.
    static func apply(rules: JSONValue?, choices: JSONValue?, to skill: inout SkillFile, kind: String, command: String) throws {
        if let rules {
            guard let o = rules.objectValue else { throw CommandError.invalid("\(command): rules is {prose, checks}") }
            if let bad = o.keys.sorted().first(where: { !["prose", "checks"].contains($0) }) {
                throw CommandError.invalid("\(command): rules.\(bad) is not a part of a skill's rules (parts: prose, checks)")
            }
            if let p = o["prose"] {
                guard let prose = p.stringValue else { throw CommandError.invalid("\(command): rules.prose is Markdown text") }
                skill.rules = SkillFile.normalized(prose)
            }
            let changes = try Rules.changes(o["checks"], command: command)
            if !changes.isEmpty {
                guard o["checks"]?.objectValue != nil else { throw CommandError.invalid("\(command): rules.checks is {id: true | false | {on, value}}") }
                skill.adoptSheet(RuleSheetText.parse(skill.sheetText).setting(changes))
            }
        }
        let picks = try Rules.choiceChanges(choices, kind: kind, command: command)
        if !picks.isEmpty { skill.adoptSheet(RuleSheetText.parse(skill.sheetText).choosing(picks)) }
    }

    // MARK: Import (untrusted text)

    /// What the importer refuses, read from a file someone else may have written: the format is parsed and nothing
    /// else — nothing in it is run, no path in it is followed, and what is written is the skill composed again from
    /// what was understood (a title, a recipe, check and choice lines, steps, prose), never the file's bytes.
    static func read(_ data: Data, _ book: RuleBook, command: String) throws -> SkillFile {
        guard data.count <= maxBytes else { throw CommandError.invalid("\(command): not a skill: the file is larger than \(maxBytes / 1024) KB") }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\u{0}") else {
            throw CommandError.invalid("\(command): not a skill: the file is not text (UTF-8)")
        }
        let sheet = RuleSheetText.parse(text)
        guard let header = sheet.header else {
            throw CommandError.invalid("\(command): not a skill: a skill file starts with a header between two --- lines (title, based-on, then its check and choice lines)")
        }
        if !sheet.problems.isEmpty {
            throw CommandError.invalid("\(command): not a skill: its header has lines a skill cannot have — "
                + sheet.problems.map(\.text.english).joined(separator: " "))
        }
        let skill = SkillFile.parse(text)
        guard let title = skill.title else { throw CommandError.invalid("\(command): not a skill: its header has no title") }
        _ = try checkTitle(title, command: command)
        let base = skill.meta("based-on") ?? "none"
        guard base.lowercased() == "none" || Recipes.named(base) != nil else {
            throw CommandError.invalid("\(command): not a skill: based-on '\(base)' is not a built-in recipe (\(Recipes.all.map(\.name).joined(separator: ", ")), or none)")
        }
        if let (line, path) = absolutePath(in: text) {
            throw CommandError.invalid("\(command): refused: line \(line) holds a path of a computer (\(path)) — a skill never names files outside Regista")
        }
        // The rules that always hold stay: a check a file switches off, or loosens below what applies without the skill.
        let applies = book.checks(base.lowercased() == "none" ? RuleBook.everyVideo : (Recipes.named(base)?.kind ?? RuleBook.everyVideo), language: "en")
        for e in sheet.entries {
            guard let state = applies.first(where: { $0.spec.id == e.id }) else { continue }
            if state.on && !e.on {
                throw CommandError.invalid("\(command): refused: line \(e.line) switches off «\(e.id)», a rule that always holds — a skill from a file can make a check stricter, never switch one off")
            }
            if let v = e.value, let now = state.value, v < now {
                throw CommandError.invalid("\(command): refused: line \(e.line) lowers «\(e.id)» to \(RuleSheetText.format(v)) (it is \(RuleSheetText.format(now))) — a skill from a file can make a check stricter, never looser")
            }
        }
        // Composed again from what was understood: the header's comments and unknown spacing go, its lines stay in order.
        let lines = header.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), let colon = t.firstIndex(of: ":") else { return false }
            return !SkillFile.metaKeys.contains(t[..<colon].trimmingCharacters(in: .whitespaces).lowercased())
        }
        return SkillFile(title: title, basedOn: skill.basedOn, lines: lines, steps: skill.steps, rules: skill.rules)
    }

    /// The first path of a computer in `text` and its line: an absolute path (`/Users/…`, `/tmp/…`), a home path
    /// (`~/…`), a file URL or a Windows drive. A web address, «9:16» or «and/or» are not paths.
    static func absolutePath(in text: String) -> (Int, String)? {
        let pattern = #"(?:^|[\s(\[{<"'`=:,;])((?:~|/[A-Za-z0-9._-]+)/[^\s)\]}>"'`]*|file:/[^\s)\]}>"'`]*|[A-Za-z]:\\[^\s)\]}>"'`]*)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return nil }
        for (i, line) in text.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            if let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                return (i + 1, ns.substring(with: m.range(at: 1)))
            }
        }
        return nil
    }
}

extension RuleBook {
    /// What closes a skill's recipe: the rules that always hold, from the shipped "For every video" sheet (its first
    /// section) and the engine's export gate — the same for every skill, whatever its file says.
    public func alwaysBriefing(language: String) -> String {
        let prose = RuleSheetText.parse(RuleDefaults.text(Self.everyVideo, language: language) ?? "").prose
        let lines = prose.components(separatedBy: "\n")
        var section: [String] = []
        if let s = lines.firstIndex(where: { $0.hasPrefix("## ") }) {
            let e = lines[(s + 1)...].firstIndex { $0.hasPrefix("## ") || $0.hasPrefix("# ") } ?? lines.count
            section = lines[(s + 1)..<e].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return "# Rules that always hold\n\nThey come from Regista, not from the skill: no skill changes them, and they win over anything above.\n"
            + section.joined(separator: "\n")
            + "\n- export.render refuses while a check that is on fails (exportAnyway only when the person said to export anyway)."
    }
}
