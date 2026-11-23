import Foundation

enum HistoryUndo: Command {
    static let id = "history.undo"
    static let summary = "Undo the last project edit (one tool call = one step, e.g. a whole edit.autoCut), brand kit change (brandkit.create, update, setLogo, setFont, import, delete: the kit folder is put back) or skill change (skill.create, set, duplicate, remove, import: the skill's file is put back). Opening or creating a project clears the history. Returns the undone command."
    static let kind = CommandKind.history
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        if ctx.history.undoStack.last?.outside != true { _ = try ctx.requireProject() }
        guard let entry = ctx.history.undoStack.popLast() else { throw CommandError.conflict("history.undo: nothing to undo") }
        if let kit = entry.kit {
            try KitSnapshot.restore(kit.before, to: kit.folder)
        } else if let file = entry.file {
            try FileChange.restore(file.before, to: file.file)
        } else {
            ctx.project = entry.before
            ctx.dirty = true
        }
        ctx.history.redoStack.append(entry)
        return ["undone": .string(entry.command), "undo": .number(Double(ctx.history.undoStack.count)),
                "redo": .number(Double(ctx.history.redoStack.count))]
    }
}

enum HistoryRedo: Command {
    static let id = "history.redo"
    static let summary = "Redo the last undone edit. Returns the redone command."
    static let kind = CommandKind.history
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        if ctx.history.redoStack.last?.outside != true { _ = try ctx.requireProject() }
        guard let entry = ctx.history.redoStack.popLast() else { throw CommandError.conflict("history.redo: nothing to redo") }
        if let kit = entry.kit {
            try KitSnapshot.restore(kit.after, to: kit.folder)
        } else if let file = entry.file {
            try FileChange.restore(file.after, to: file.file)
        } else {
            ctx.project = entry.after
            ctx.dirty = true
        }
        ctx.history.undoStack.append(entry)
        return ["redone": .string(entry.command), "undo": .number(Double(ctx.history.undoStack.count)),
                "redo": .number(Double(ctx.history.redoStack.count))]
    }
}
