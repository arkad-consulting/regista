import Foundation

enum HistoryUndo: Command {
    static let id = "history.undo"
    static let summary = "Undo the last project edit (one tool call = one step, e.g. a whole edit.autoCut). Opening or creating a project clears the history. Returns the undone command."
    static let kind = CommandKind.history
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        _ = try ctx.requireProject()
        guard let entry = ctx.history.undoStack.popLast() else { throw CommandError.conflict("history.undo: nothing to undo") }
        ctx.project = entry.before
        ctx.history.redoStack.append(entry)
        ctx.dirty = true
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
        _ = try ctx.requireProject()
        guard let entry = ctx.history.redoStack.popLast() else { throw CommandError.conflict("history.redo: nothing to redo") }
        ctx.project = entry.after
        ctx.history.undoStack.append(entry)
        ctx.dirty = true
        return ["redone": .string(entry.command), "undo": .number(Double(ctx.history.undoStack.count)),
                "redo": .number(Double(ctx.history.redoStack.count))]
    }
}
