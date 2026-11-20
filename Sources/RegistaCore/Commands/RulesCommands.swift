import Foundation

// Editing rules (#31): the sheets (list, read, write, reset, kinds of the user's own), the project's kind, the check and
// its fixes, so an agent does everything the Settings › Rules tab and the Export card do. The sheets live outside the
// project: writing one is not an undo step (like a voice profile); the project's kind and every fix are.

enum Rules {
    static let languageParam = ParamSpec.optional("language", .oneOf(RuleBook.languages),
                                                  "Language of the default sheets read (it, en, fr, pt; default: the app's interface language). A sheet the user wrote is the same in every language.")

    static func language(_ p: CommandParams) -> String { p.string("language") ?? RuleBook.interfaceLanguage() }

    static func requireKind(_ kind: String, _ book: RuleBook, command: String) throws {
        guard book.exists(kind) else {
            throw CommandError.notFound("\(command): no rule sheet '\(kind)' — rules.list lists them (\(([RuleBook.everyVideo] + book.kinds).joined(separator: ", ")))")
        }
    }

    /// A sheet as the commands return it.
    static func sheet(_ kind: String, _ book: RuleBook, language: String, full: Bool) -> JSONValue {
        let text = book.text(kind, language: language) ?? ""
        let parsed = RuleSheetText.parse(text)
        var o: [String: JSONValue] = [
            "kind": .string(kind), "title": .string(book.title(kind, language: language)),
            "builtIn": .bool(RuleBook.isBuiltIn(kind)), "everyVideo": .bool(kind == RuleBook.everyVideo),
            "edited": .bool(book.edited(kind)), "path": book.edited(kind) ? .string(book.file(kind).path) : .null,
            "switches": .array(parsed.entries.map { e in
                ["id": .string(e.id), "on": .bool(e.on), "value": e.value.map { .number($0) } ?? .null, "line": .number(Double(e.line))]
            }),
            "status": ["ok": .bool(parsed.problems.isEmpty), "problems": .array(parsed.problems.map(\.json))],
        ]
        if full {
            o["language"] = .string(language)
            o["text"] = .string(text)
            o["prose"] = .string(parsed.prose)
            o["checks"] = .array(book.checks(kind, language: language).map(\.json))
        }
        return .object(o)
    }

    static func write(_ text: String, kind: String, _ book: RuleBook, command: String) throws {
        do {
            try FileManager.default.createDirectory(at: book.directory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: book.file(kind), options: .atomic)
        } catch {
            throw CommandError(.io, "\(command): cannot write \(book.file(kind).path): \(error.localizedDescription)")
        }
    }

    /// The switch changes of a `checks` param: {id: true | false | {on, value}}.
    static func changes(_ json: JSONValue?, command: String) throws -> [(id: String, on: Bool?, value: Double?)] {
        guard let o = json?.objectValue else { return [] }
        return try o.keys.sorted().map { id in
            guard let spec = RuleCheckSpec.named(id) else {
                throw CommandError.invalid("\(command): unknown check '\(id)' (checks: \(RuleCheckSpec.ids.joined(separator: ", ")))")
            }
            let v = o[id]!
            if let b = v.boolValue { return (id, b, nil) }
            guard let fields = v.objectValue, Set(fields.keys).isSubset(of: ["on", "value"]) else {
                throw CommandError.invalid("\(command): checks.\(id) is true, false or {on, value}")
            }
            let value = fields["value"]?.doubleValue
            if let value {
                guard let n = spec.number else { throw CommandError.invalid("\(command): \(id) takes no number") }
                guard n.range.contains(value) else {
                    throw CommandError.invalid("\(command): \(id) must be between \(RuleSheetText.format(n.range.lowerBound)) and \(RuleSheetText.format(n.range.upperBound)) \(n.unit)")
                }
            }
            return (id, fields["on"]?.boolValue, value)
        }
    }

    /// "YouTube tutorial" → "youtube-tutorial".
    static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = "", dash = false
        for ch in folded.unicodeScalars {
            if ("a"..."z").contains(ch) || ("0"..."9").contains(ch) { out.unicodeScalars.append(ch); dash = false }
            else if !dash, !out.isEmpty { out += "-"; dash = true }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return String(out.prefix(48))
    }
}

enum RulesList: Command {
    static let id = "rules.list"
    static let summary = "List the editing-rule sheets: every-video (always applies) and one per kind of video — the built-in kinds talking-head-reel, screen-tutorial, voice-over-video, reel-graphics, plus the user's own kinds. Each sheet is a Markdown file the user can edit (Settings › Rules); edited says the user's copy replaces the shipped default. Returns the sheets (kind, title, builtIn, edited, path, the switches written in its header, header status), the folder of the user's sheets and the open project's kind."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [Rules.languageParam]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, language = Rules.language(p)
        var result: [String: JSONValue] = [
            "folder": .string(book.directory.path), "language": .string(language),
            "sheets": .array(([RuleBook.everyVideo] + book.kinds).map { Rules.sheet($0, book, language: language, full: false) }),
            "checks": .array(RuleCheckSpec.all.map { s in
                var o: [String: JSONValue] = ["id": .string(s.id), "title": .string(s.title)]
                if let n = s.number { o["default"] = .number(n.defaultValue); o["unit"] = .string(n.unit); o["meaning"] = .string(n.meaning) }
                return .object(o)
            }),
        ]
        if let project = ctx.project {
            let k = book.kind(of: project)
            result["project"] = ["kind": .string(k.kind), "source": .string(k.source), "note": k.note?.json ?? .null]
        }
        return .object(result)
    }
}

enum RulesGet: Command {
    static let id = "rules.get"
    static let summary = "Read one rule sheet: its whole Markdown text (header + prose), the prose alone, the switches its header writes (one line per check between two --- lines: `id: on|off [number]`), the checks as they apply to that kind (defaults, then every-video, then the kind's own lines; source says which), and the header's status (an unknown check or a malformed line is listed with its line number and ignored, never fatal). Returns the sheet."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("kind", .string, "every-video, a built-in kind or a kind of the user's (rules.list)."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, kind = p.requiredString("kind")
        try Rules.requireKind(kind, book, command: id)
        return Rules.sheet(kind, book, language: Rules.language(p), full: true)
    }
}

enum RulesSet: Command {
    static let id = "rules.set"
    static let summary = "Write a rule sheet (the user's copy in the rules folder, which replaces the shipped default of that kind; rules.reset brings the default back): the whole text, or only the prose (the header is kept), and/or switches — checks {\"logo-pause\": {\"on\": true, \"value\": 0.4}, \"text-size\": false}. Only when the user asked to change their rules. Not an undo step. Returns the sheet as rules.get."
    static let kind = CommandKind.session
    static let undoNote: String? = "no — writes the rule sheets in the rules folder, outside the project (rules.reset brings back a built-in default)"
    static let params: [ParamSpec] = [
        .required("kind", .string, "every-video, a built-in kind or a kind of the user's."),
        .optional("text", .string, "The whole file: header between two --- lines, then the prose (written as given; header problems are reported)."),
        .optional("prose", .string, "New prose (Markdown) under the current header."),
        .optional("checks", .object, "Switches to change: {id: true | false | {on, value}} (ids: \(RuleCheckSpec.ids.joined(separator: ", ")))."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, kind = p.requiredString("kind"), language = Rules.language(p)
        try Rules.requireKind(kind, book, command: id)
        guard p.has("text") || p.has("prose") || p.has("checks") else { throw CommandError.invalid("\(id): pass text, prose or checks") }
        guard !(p.has("text") && p.has("prose")) else { throw CommandError.invalid("\(id): pass text or prose, not both") }
        let changes = try Rules.changes(p.json("checks"), command: id)
        var text = p.string("text") ?? book.text(kind, language: language) ?? ""
        if let prose = p.string("prose") {
            let parsed = RuleSheetText.parse(text)
            text = RuleSheetText.compose(header: parsed.header, prose: prose)
        }
        if !changes.isEmpty { text = RuleSheetText.parse(text).setting(changes) }
        try Rules.write(text, kind: kind, book, command: id)
        return Rules.sheet(kind, book, language: language, full: true)
    }
}

enum RulesReset: Command {
    static let id = "rules.reset"
    static let summary = "Bring back the shipped default of a built-in sheet (every-video or a built-in kind): removes the user's copy. Only when the user asked. A kind of the user's own has no default (rules.removeKind deletes it). Returns the sheet and whether a copy was removed."
    static let kind = CommandKind.session
    static let undoNote: String? = "no — writes the rule sheets in the rules folder, outside the project (rules.reset brings back a built-in default)"
    static let params: [ParamSpec] = [
        .required("kind", .string, "every-video or a built-in kind."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, kind = p.requiredString("kind")
        try Rules.requireKind(kind, book, command: id)
        guard RuleBook.isBuiltIn(kind) else { throw CommandError.conflict("\(id): '\(kind)' is a kind of the user's own and has no default — rules.removeKind deletes it") }
        let removed = book.edited(kind)
        if removed {
            do { try FileManager.default.removeItem(at: book.file(kind)) }
            catch { throw CommandError(.io, "\(id): cannot remove \(book.file(kind).path): \(error.localizedDescription)") }
        }
        return ["removed": .bool(removed), "sheet": Rules.sheet(kind, book, language: Rules.language(p), full: true)]
    }
}

enum RulesAddKind: Command {
    static let id = "rules.addKind"
    static let summary = "Add a kind of video of the user's own (e.g. \"YouTube tutorial\"): a new sheet in the rules folder, copied from an existing kind (from) or empty under its title; every-video still applies to it. Then project.setKind chooses it for a project. Returns the new sheet."
    static let kind = CommandKind.session
    static let undoNote: String? = "no — writes the rule sheets in the rules folder, outside the project (rules.reset brings back a built-in default)"
    static let params: [ParamSpec] = [
        .required("title", .string, "The kind's name as the user says it (the sheet's first heading)."),
        .optional("slug", .string, "Its id: lower-case letters, digits and hyphens (default: from the title)."),
        .optional("from", .string, "Kind whose sheet to start from (default: an empty sheet)."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, language = Rules.language(p)
        let title = p.requiredString("title").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !title.contains("\n") else { throw CommandError.invalid("\(id): title is one line of text") }
        let slug = p.string("slug") ?? Rules.slug(title)
        guard RuleBook.isSlug(slug) else { throw CommandError.invalid("\(id): '\(slug)' is not a valid id (lower-case letters, digits and hyphens): pass slug") }
        guard !book.exists(slug) else { throw CommandError.conflict("\(id): a sheet '\(slug)' already exists — pass another slug") }
        var text = "# \(title)\n"
        if let from = p.string("from") {
            try Rules.requireKind(from, book, command: id)
            let parsed = RuleSheetText.parse(book.text(from, language: language) ?? "")
            var lines = parsed.prose.components(separatedBy: "\n")
            if let h = lines.firstIndex(where: { $0.hasPrefix("# ") }) { lines[h] = "# \(title)" } else { lines.insert("# \(title)\n", at: 0) }
            text = RuleSheetText.compose(header: parsed.header, prose: lines.joined(separator: "\n"))
        }
        try Rules.write(text, kind: slug, book, command: id)
        return Rules.sheet(slug, book, language: language, full: true)
    }
}

enum RulesRemoveKind: Command {
    static let id = "rules.removeKind"
    static let summary = "Delete a kind of video of the user's own (its sheet). Only when the user asked. A project that had it falls back to the kind of its format (rules.check says so). Built-in kinds cannot be removed (rules.reset restores their default). Returns the removed kind."
    static let kind = CommandKind.session
    static let undoNote: String? = "no — writes the rule sheets in the rules folder, outside the project (rules.reset brings back a built-in default)"
    static let params: [ParamSpec] = [.required("kind", .string, "A kind of the user's own.")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, kind = p.requiredString("kind")
        try Rules.requireKind(kind, book, command: id)
        guard !RuleBook.isBuiltIn(kind) else { throw CommandError.conflict("\(id): '\(kind)' is built in — rules.reset brings its default back") }
        do { try FileManager.default.removeItem(at: book.file(kind)) }
        catch { throw CommandError(.io, "\(id): cannot remove \(book.file(kind).path): \(error.localizedDescription)") }
        return ["removed": .string(kind)]
    }
}

enum ProjectSetKind: Command {
    static let id = "project.setKind"
    static let summary = "Set the open project's kind of video, which selects its rule sheet (every-video always applies): a built-in kind (talking-head-reel, screen-tutorial, voice-over-video, reel-graphics) or one of the user's (rules.list). Without kind, the kind follows the format again (landscape: screen-tutorial, else talking-head-reel). One undo step. Returns the kind."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [.optional("kind", .string, "The kind (omit: from the format).")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let book = ctx.services.rules
        if let kind = p.string("kind") {
            guard book.kinds.contains(kind) else { throw CommandError.notFound("\(id): no kind '\(kind)' (kinds: \(book.kinds.joined(separator: ", ")))") }
            project.kind = kind
        } else {
            project.kind = nil
        }
        ctx.project = project
        let k = book.kind(of: project)
        return ["kind": .string(k.kind), "source": .string(k.source)]
    }
}

enum RulesCheck: Command {
    static let id = "rules.check"
    static let summary = "Check the edit against the rules of its kind before export (export.render runs it too and refuses while a check fails): no captions while the opening title is on screen, none on the closing logo, a clean pause between the last spoken word and the logo, a logo only at the end, no logo or title over the speaker's face, no text under the minimum size. Each violation has its time and, where a safe one exists, its fix as a command call (one undo step; rules.fix applies them). Warnings do not block. Returns pass, the violations, each check's state (on, number, skipped and why) and the problems of the sheets' headers."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [Rules.languageParam]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        RuleCheck.run(try ctx.requireProject(), book: ctx.services.rules, language: Rules.language(p), renderer: ctx.services.renderer).json
    }
}

enum RulesFix: Command {
    static let id = "rules.fix"
    static let summary = "Apply the safe fixes of the failing rule checks, all in one undo step: those of one check, or all of them; the check runs again after each fix (a moved logo changes what the captions must clear). A logo outside the end is kept for the closing seconds only. Violations without a fix (a title over the face, text too small) need an edit. Returns the fixes applied and the check after them."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("check", .oneOf(RuleCheckSpec.ids), "Fix only this check's violations."),
        .optional("all", .boolean, "Fix every failing check that has a fix."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        _ = try ctx.requireProject()
        let only = p.string("check")
        guard only != nil || p.bool("all") == true else { throw CommandError.invalid("\(id): pass check or all: true") }
        let language = RuleBook.interfaceLanguage()
        var applied: [JSONValue] = [], done: Set<String> = []
        for _ in 0..<20 {
            let report = RuleCheck.run(ctx.project!, book: ctx.services.rules, language: language, renderer: ctx.services.renderer)
            guard let v = report.failures.first(where: { $0.fix != nil && (only == nil || $0.check == only) && !done.contains($0.line) }),
                  let fix = v.fix else { break }
            done.insert(v.line)
            guard let command = Commands.all.first(where: { $0.id == fix.command }) else { continue }
            _ = try Nested.run(command, fix.params.objectValue ?? [:], &ctx)
            applied.append(["check": .string(v.check), "command": .string(fix.command), "params": fix.params, "message": .string(fix.label.english)])
        }
        let after = RuleCheck.run(ctx.project!, book: ctx.services.rules, language: language, renderer: ctx.services.renderer)
        return ["applied": .array(applied), "check": after.json]
    }
}

enum CaptionsClear: Command {
    static let id = "captions.clear"
    static let summary = "Take the captions off a stretch of time (the opening title, the closing logo): a chunk inside it goes, a chunk that crosses its start ends there, a chunk that crosses its end starts there with the words still being spoken. One undo step (captions.generate rebuilds them all). Returns the chunks removed and shortened."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("from", .time, "Start of the stretch."),
        .required("to", .time, "End of the stretch."),
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let from = p.requiredTime("from"), to = p.requiredTime("to")
        guard to > from else { throw CommandError.invalid("\(id): to must be after from") }
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        var captions = try CaptionsCommon.require(project.tracks[t], command: id)
        var removed = 0, shortened = 0
        var kept: [CaptionChunk] = []
        for var ch in captions.chunks {
            let start = ch.words.first?.start ?? ch.end
            guard start < to, from < ch.end else { kept.append(ch); continue }
            if start < from {
                // Crosses the start: ends there, with the words it had begun.
                ch.words = ch.words.filter { $0.start < from }.map { var w = $0; w.end = min(w.end, from); return w }
                ch.end = from
            } else {
                // Starts inside: keeps only the words still being spoken when the stretch ends, shown from its end.
                ch.words = ch.words.filter { $0.end > to }.map { var w = $0; w.start = max(w.start, to); return w }
            }
            if ch.words.isEmpty || ch.end <= (ch.words.first?.start ?? ch.end) { removed += 1; continue }
            shortened += 1
            kept.append(ch)
        }
        captions.chunks = kept
        project.tracks[t].captions = captions
        ctx.project = project
        return ["trackId": .string(project.tracks[t].id), "removed": .number(Double(removed)), "shortened": .number(Double(shortened)),
                "chunks": .number(Double(kept.count))]
    }
}
