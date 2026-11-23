import Foundation

// The person's skills (#157): list, read, create, change, duplicate, remove, export and import, so an agent does what
// Settings › Regia e skill does. A skill lives outside the project (`skills/` of the support folder); every command that
// changes one is one undo step that puts its file back (history.undo). The built-in recipes can be read and duplicated,
// never changed.

private let skillUndoNote = "yes — history.undo puts the skill's file back"

enum SkillList: Command {
    static let id = "skill.list"
    static let summary = "List the person's skills — their own ways of editing: each one a title, the built-in recipe it is based on (or none), rules, choices and steps, in one Markdown file — and the built-in recipes, which can be duplicated (skill.duplicate) but never changed. A project's kind can be a skill (project.setKind); recipe.get {name: <skill>} reads it as a recipe. Returns the skills (skill, title, basedOn, path, steps), the built-ins and the folder."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules
        return [
            "skills": .array(Skills.slugs(book).map { Skills.json($0, book, language: "en", full: false) }),
            "builtIns": .array(Recipes.all.map { ["skill": .string($0.name), "title": .string(Skills.builtInTitle($0)), "kind": .string($0.kind)] }),
            "folder": .string(book.skillsDirectory.path),
        ]
    }
}

enum SkillGet: Command {
    static let id = "skill.get"
    static let summary = "Read one skill whole: its title, the recipe it is based on, its steps (Markdown), its rules (the prose it adds, its check lines and the checks as they apply), its choices resolved (the skill's lines over the sheet of the recipe it is based on over \"For every video\" over the defaults), the problems of its header, and its file (path and text). A built-in recipe reads the same way, read-only (its steps, its kind's sheet). Returns the skill."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("skill", .string, "A skill of the person's or a built-in recipe (skill.list)."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, name = p.requiredString("skill")
        _ = try Skills.require(name, book, command: id, own: false)
        return Skills.json(name, book, language: Rules.language(p), full: true)
    }
}

enum SkillCreate: Command {
    static let id = "skill.create"
    static let summary = "Write a new skill of the person's — only when the person asked for it, after showing them what it will say: a title, the built-in recipe it is based on (its sheet then sits under the skill's own lines; omit for none), its steps (Markdown: what to do, in order), its rules — {prose: the rules it adds, in Markdown; checks: {id: true | false | {on, value}}} — and its choices, as rules.set takes them ({\"captions\": \"elegant-serif\", \"music\": \"never\"}). A skill can never change \"For every video\" or the rules that always hold. One undo step. Returns the skill as skill.get."
    static let kind = CommandKind.query
    static let undoNote: String? = skillUndoNote
    static let params: [ParamSpec] = [
        .required("title", .string, "The skill's name as the person says it (one line)."),
        .optional("basedOn", .string, "A built-in recipe (\(Recipes.all.map(\.name).joined(separator: ", "))) or none (default)."),
        .optional("steps", .string, "Its steps, in Markdown (a numbered list)."),
        .optional("rules", .object, "Its rules: {prose: Markdown, checks: {id: true | false | {on, value}}} (ids: \(RuleCheckSpec.ids.joined(separator: ", ")))."),
        .optional("choices", .object, "Its choices: {id: option | {value, number}} (ids: \(RuleChoiceSpec.ids.joined(separator: ", ")))."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules
        let title = try Skills.checkTitle(p.requiredString("title"), command: id)
        if let other = Skills.titled(title, book) { throw CommandError.conflict("\(id): a skill «\(title)» exists ('\(other)') — skill.set changes it, or choose another title") }
        let slug = try Skills.newSlug(title, book, command: id)
        var skill = SkillFile(title: title, basedOn: try Skills.basedOn(p.string("basedOn"), command: id), steps: p.string("steps") ?? "")
        try Skills.apply(rules: p.json("rules"), choices: p.json("choices"), to: &skill, kind: slug, command: id)
        try Skills.write(skill, slug: slug, book, &ctx, command: id)
        return Skills.json(slug, book, language: Rules.language(p), full: true)
    }
}

enum SkillSet: Command {
    static let id = "skill.set"
    static let summary = "Change a skill of the person's — only when the person asked: one or more of its title, its steps (Markdown, replaced whole), its rules ({prose, checks}: the prose replaced, each check's line rewritten) and its choices (each key rewrites only its own line). Its file name stays. A built-in recipe is refused (skill.duplicate makes a copy to change); an unknown key is refused with the list. One undo step. Returns the skill as skill.get."
    static let kind = CommandKind.query
    static let undoNote: String? = skillUndoNote
    static let params: [ParamSpec] = [
        .required("skill", .string, "A skill of the person's (skill.list)."),
        .optional("title", .string, "New title (one line)."),
        .optional("steps", .string, "New steps, in Markdown."),
        .optional("rules", .object, "Rules to change: {prose: Markdown, checks: {id: true | false | {on, value}}}."),
        .optional("choices", .object, "Choices to change: {id: option | {value, number}}."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, slug = p.requiredString("skill")
        guard p.has("title") || p.has("steps") || p.has("rules") || p.has("choices") else {
            throw CommandError.invalid("\(id): pass one or more of title, steps, rules, choices")
        }
        guard var skill = try Skills.require(slug, book, command: id, own: true).skill else { throw CommandError.notFound("\(id): no skill '\(slug)'") }
        if let raw = p.string("title") {
            let title = try Skills.checkTitle(raw, command: id)
            if let other = Skills.titled(title, book, except: slug) { throw CommandError.conflict("\(id): another skill is called «\(title)» ('\(other)')") }
            skill.setMeta("title", title)
        }
        if let steps = p.string("steps") { skill.steps = SkillFile.trimmed(steps) }
        try Skills.apply(rules: p.json("rules"), choices: p.json("choices"), to: &skill, kind: slug, command: id)
        try Skills.write(skill, slug: slug, book, &ctx, command: id)
        return Skills.json(slug, book, language: Rules.language(p), full: true)
    }
}

enum SkillDuplicate: Command {
    static let id = "skill.duplicate"
    static let summary = "Copy a skill under a new title — the way to change a built-in recipe: its copy is based on it (the recipe's sheet still applies under the copy's own lines) and starts with the recipe's steps, which the person can then change. A skill of the person's is copied whole. One undo step. Returns the new skill as skill.get."
    static let kind = CommandKind.query
    static let undoNote: String? = skillUndoNote
    static let params: [ParamSpec] = [
        .required("from", .string, "A built-in recipe or a skill of the person's (skill.list)."),
        .required("title", .string, "The copy's title (one line)."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules
        let source = try Skills.require(p.requiredString("from"), book, command: id, own: false)
        let title = try Skills.checkTitle(p.requiredString("title"), command: id)
        if let other = Skills.titled(title, book) { throw CommandError.conflict("\(id): a skill «\(title)» exists ('\(other)') — choose another title") }
        let slug = try Skills.newSlug(title, book, command: id)
        var copy: SkillFile
        if let recipe = source.recipe {
            copy = SkillFile(title: title, basedOn: recipe.name, steps: recipe.steps)
        } else {
            copy = source.skill!
            copy.setMeta("title", title)
        }
        try Skills.write(copy, slug: slug, book, &ctx, command: id)
        return Skills.json(slug, book, language: Rules.language(p), full: true)
    }
}

enum SkillRemove: Command {
    static let id = "skill.remove"
    static let summary = "Remove a skill of the person's — only when the person asked. A project whose kind it was follows the kind of its format again (rules.check says so). Built-in recipes cannot be removed. One undo step: history.undo brings the skill back. Returns the removed skill."
    static let kind = CommandKind.query
    static let undoNote: String? = skillUndoNote
    static let params: [ParamSpec] = [.required("skill", .string, "A skill of the person's (skill.list).")]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, slug = p.requiredString("skill")
        _ = try Skills.require(slug, book, command: id, own: true)
        let title = Skills.title(slug, book)
        let (_, change) = try FileChange.record(book.file(slug)) {
            do { try FileManager.default.removeItem(at: book.file(slug)) }
            catch { throw CommandError(.io, "\(id): cannot remove \(book.file(slug).path): \(error.localizedDescription)") }
        }
        ctx.fileChange = change
        return ["removed": .string(slug), "title": .string(title)]
    }
}

enum SkillExport: Command {
    static let id = "skill.export"
    static let summary = "Write a skill of the person's as one Markdown file where the person chose (to send to a colleague, who adds it with skill.import or «Importa una skill…»). A built-in recipe is not exported (duplicate it first). Returns the file."
    static let kind = CommandKind.query
    static let undoNote: String? = "no — writes a file where the person chose, outside the project"
    static let params: [ParamSpec] = [
        .required("skill", .string, "A skill of the person's (skill.list)."),
        .required("path", .string, "The file to write (.md added if missing), or a folder (the skill's file name in it)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, slug = p.requiredString("skill")
        guard let skill = try Skills.require(slug, book, command: id, own: true).skill else { throw CommandError.notFound("\(id): no skill '\(slug)'") }
        var out = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path")))
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: out.path, isDirectory: &isDir), isDir.boolValue { out.appendPathComponent("\(slug).md") }
        else if out.pathExtension.lowercased() != "md" { out.appendPathExtension("md") }
        do {
            try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(skill.text.utf8).write(to: out, options: .atomic)
        } catch {
            throw CommandError(.io, "\(id): cannot write \(out.path): \(error.localizedDescription)")
        }
        return ["path": .string(out.path), "skill": .string(slug), "title": .string(Skills.title(slug, book)), "bytes": .number(Double(skill.text.utf8.count))]
    }
}

enum SkillImport: Command {
    static let id = "skill.import"
    static let summary = "Add a skill from a Markdown file (from skill.export, or written by someone). The file is untrusted text: only the skill format is read (title, based-on, check and choice lines, steps, prose rules); a file that is not a skill, holds a path of a computer, or switches off or loosens a rule that always holds is refused, and nothing in it is ever run. dryRun: true reads it and returns what it would add (title, based on, rules, choices, steps) and whether a skill of that title exists, writing nothing — show that to the person first. Without dryRun it writes the skill, refused when a skill of that title exists unless replace: true (the person asked to replace it) or a new title is given. One undo step. Returns the skill and what changed."
    static let kind = CommandKind.query
    static let undoNote: String? = skillUndoNote
    static let params: [ParamSpec] = [
        .required("path", .string, "The skill's .md file."),
        .optional("dryRun", .boolean, "Read and describe it, write nothing (default false)."),
        .optional("replace", .boolean, "Replace the person's skill of the same title (only when the person asked)."),
        .optional("title", .string, "Add it under this title instead of the file's (a conflict's other way out)."),
        Rules.languageParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let book = ctx.services.rules, language = Rules.language(p)
        let url = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("path")))
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CommandError.notFound("\(id): cannot read \(url.path)") }
        var skill = try Skills.read(data, book, command: id)
        if let raw = p.string("title") { skill.setMeta("title", try Skills.checkTitle(raw, command: id)) }
        let title = skill.title ?? ""
        let existing = Skills.titled(title, book)
        var slug: String
        if let existing { slug = existing } else { slug = try Skills.newSlug(title, book, command: id) }
        let sheet = RuleSheetText.parse(skill.sheetText)
        var described: [String: JSONValue] = [
            "title": .string(title), "basedOn": skill.basedOn.map(JSONValue.string) ?? .null, "steps": .string(skill.steps),
            "rules": ["prose": .string(skill.rules),
                      "switches": .array(sheet.entries.map { ["id": .string($0.id), "on": .bool($0.on), "value": $0.value.map { .number($0) } ?? .null] })],
            "choices": .array(sheet.choices.map { c in
                var o: [String: JSONValue] = ["id": .string(c.id), "value": .string(c.value), "number": c.number.map(RuleChoiceSpec.json) ?? .null]
                if let spec = RuleChoiceSpec.named(c.id) { o["title"] = .string(spec.title); o["label"] = .string(spec.option(c.value)?.label ?? c.value) }
                return .object(o)
            }),
        ]
        described["conflict"] = existing.map { ["skill": .string($0), "title": .string(Skills.title($0, book))] } ?? .null
        if p.bool("dryRun") == true {
            return ["dryRun": true, "skill": .object(described), "wouldWrite": .string(existing == nil ? "new" : "replace"), "file": .string(book.file(slug).path)]
        }
        if existing != nil, p.bool("replace") != true {
            throw CommandError.conflict("\(id): a skill «\(title)» exists ('\(slug)') — pass replace: true if the person asked to replace it, or title for a new name")
        }
        if existing == nil { slug = try Skills.newSlug(title, book, command: id) }
        try Skills.write(skill, slug: slug, book, &ctx, command: id)
        return ["added": .string(slug), "replaced": .bool(existing != nil), "skill": Skills.json(slug, book, language: language, full: true)]
    }
}
