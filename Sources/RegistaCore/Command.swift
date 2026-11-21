import Foundation

/// Every user or agent action is a command: a string id, JSON params described by `params`
/// (that description becomes the MCP tool schema), a run function and an undo policy.
/// The UI, the CLI and the MCP server all go through `Engine.execute`.
public protocol Command {
    /// Namespaced id: "timeline.cut".
    static var id: String { get }
    /// One or two sentences for humans and agents (the MCP tool description).
    static var summary: String { get }
    static var params: [ParamSpec] { get }
    static var kind: CommandKind { get }
    /// Only the person at the Mac may run it (the app's UI, `regista-engine exec` in their terminal): the MCP server
    /// does not list it and refuses it, and the app's engine socket refuses it from agent clients.
    static var humanOnly: Bool { get }
    /// What undo does with it, when the kind's general answer would not be true for this command (a sheet or a profile
    /// outside the project, a background job that keeps running): the command reference shows it instead (nil: the kind's).
    static var undoNote: String? { get }
    /// Runs on a copy of the engine state: throwing leaves the engine untouched.
    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue
}

public enum CommandKind: String, Codable, Sendable {
    /// Reads only.
    case query
    /// Changes the project: recorded for undo (snapshot before/after).
    case edit
    /// Replaces or persists the project (new, open, save): not undoable, resets history on load.
    case session
    /// Moves through the undo history.
    case history
    /// Starts work outside the project that goes on after it answers (a download, a training): not undoable, the project
    /// unchanged; another command follows it (and stops it, when it can be stopped).
    case job
}

// MARK: - Parameter description

public indirect enum ParamType: Hashable, Sendable {
    case string
    case integer
    case number
    case boolean
    /// Seconds as a JSON number, stored as exact ticks.
    case time
    case oneOf([String])
    case array(ParamType)
    /// A JSON object whose fields the command documents in the description.
    case object

    var jsonSchema: JSONValue {
        switch self {
        case .string: ["type": "string"]
        case .integer: ["type": "integer"]
        case .number: ["type": "number"]
        case .boolean: ["type": "boolean"]
        case .time: ["type": "number", "minimum": 0]
        case .oneOf(let values): ["type": "string", "enum": .array(values.map { .string($0) })]
        case .array(let item): ["type": "array", "items": item.jsonSchema]
        case .object: ["type": "object"]
        }
    }

    var label: String {
        switch self {
        case .time: "number (seconds)"
        case .oneOf(let v): "one of " + v.joined(separator: "|")
        case .array(let item): "array of \(item.label)"
        default: jsonSchema["type"]?.stringValue ?? "?"
        }
    }

    /// Nil if `value` fits, otherwise what was wrong.
    func mismatch(_ value: JSONValue) -> String? {
        switch (self, value) {
        case (.string, .string), (.boolean, .bool), (.number, .number), (.object, .object): return nil
        case (.integer, .number(let n)): return n.rounded() == n ? nil : "expected an integer, got \(n)"
        case (.time, .number(let n)): return n >= 0 && n.isFinite ? nil : "expected seconds ≥ 0, got \(n)"
        case (.oneOf(let values), .string(let s)):
            return values.contains(s) ? nil : "expected one of \(values.joined(separator: ", ")), got \"\(s)\""
        case (.array(let item), .array(let a)):
            for (i, v) in a.enumerated() { if let m = item.mismatch(v) { return "item \(i): \(m)" } }
            return nil
        default: return "expected \(label), got \(value.typeName)"
        }
    }
}

public struct ParamSpec: Hashable, Sendable {
    public var name: String
    public var type: ParamType
    public var required: Bool
    public var description: String

    public static func required(_ name: String, _ type: ParamType, _ description: String) -> ParamSpec {
        ParamSpec(name: name, type: type, required: true, description: description)
    }

    public static func optional(_ name: String, _ type: ParamType, _ description: String) -> ParamSpec {
        ParamSpec(name: name, type: type, required: false, description: description)
    }
}

/// Serializable description of a command: what a remote host sends, what MCP lists.
public struct CommandDescriptor: Hashable, Sendable {
    public var id: String
    public var summary: String
    public var kind: CommandKind
    public var params: [ParamSpec]
    public var humanOnly = false
    /// The command's own undo answer (Command.undoNote), nil for the kind's.
    public var undoNote: String?

    /// JSON Schema (draft 2020-12 subset) of the params object.
    public var inputSchema: JSONValue {
        var props: [String: JSONValue] = [:]
        for p in params {
            var s = p.type.jsonSchema.objectValue ?? [:]
            s["description"] = .string(p.description)
            props[p.name] = .object(s)
        }
        return [
            "type": "object",
            "properties": .object(props),
            "required": .array(params.filter(\.required).map { .string($0.name) }),
            "additionalProperties": false,
        ]
    }
}

extension Command {
    public static var humanOnly: Bool { false }
    public static var undoNote: String? { nil }

    public static var descriptor: CommandDescriptor {
        CommandDescriptor(id: id, summary: summary, kind: kind, params: params, humanOnly: humanOnly, undoNote: undoNote)
    }
}

extension CommandDescriptor {
    /// The refusal an agent gets for a human-only command.
    public var humanOnlyRefusal: String {
        "\(id) is reserved to the person at the Mac: they confirm it in the Regista app (confirmation sheet) or run "
            + "`regista-engine exec \(id) …` in their own terminal. Ask them, then continue with what it returns."
    }
}

// MARK: - Errors

public struct CommandError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public enum Code: String, Sendable { case unknownCommand, invalidParams, noProject, notFound, conflict, io }
    public let code: Code
    public let message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }

    static func invalid(_ m: String) -> CommandError { CommandError(.invalidParams, m) }
    static func notFound(_ m: String) -> CommandError { CommandError(.notFound, m) }
    static func conflict(_ m: String) -> CommandError { CommandError(.conflict, m) }
}

// MARK: - Validated params

/// Params already checked against the command's spec. Accessors only accept declared names,
/// so the spec (and the MCP schema built from it) cannot drift from what the code reads.
public struct CommandParams {
    public let commandID: String
    public let values: [String: JSONValue]
    let specs: [String: ParamSpec]

    /// Checks presence, types and unknown names.
    public init(validating raw: JSONValue, for d: CommandDescriptor) throws {
        commandID = d.id
        specs = Dictionary(uniqueKeysWithValues: d.params.map { ($0.name, $0) })
        let object: [String: JSONValue]
        switch raw {
        case .null: object = [:]
        case .object(let o): object = o.filter { $0.value != .null }   // null = omitted
        default: throw CommandError.invalid("\(d.id): params must be a JSON object, got \(raw.typeName)")
        }
        for name in object.keys.sorted() where specs[name] == nil {
            let known = d.params.map(\.name).joined(separator: ", ")
            throw CommandError.invalid("\(d.id): unknown parameter '\(name)' (accepted: \(known.isEmpty ? "none" : known))")
        }
        for p in d.params {
            guard let v = object[p.name] else {
                if p.required { throw CommandError.invalid("\(d.id): missing required parameter '\(p.name)' (\(p.type.label))") }
                continue
            }
            if let m = p.type.mismatch(v) { throw CommandError.invalid("\(d.id): parameter '\(p.name)': \(m)") }
        }
        values = object
    }

    private func raw(_ name: String) -> JSONValue? {
        precondition(specs[name] != nil, "\(commandID) reads undeclared parameter '\(name)'")
        return values[name]
    }

    public func has(_ name: String) -> Bool { raw(name) != nil }
    public func string(_ name: String) -> String? { raw(name)?.stringValue }
    public func bool(_ name: String) -> Bool? { raw(name)?.boolValue }
    public func number(_ name: String) -> Double? { raw(name)?.doubleValue }
    public func int(_ name: String) -> Int? { raw(name)?.doubleValue.map { Int($0) } }
    public func time(_ name: String) -> MediaTime? { raw(name)?.doubleValue.map(MediaTime.init(seconds:)) }
    public func strings(_ name: String) -> [String]? { raw(name)?.arrayValue?.compactMap(\.stringValue) }
    public func numbers(_ name: String) -> [Double]? { raw(name)?.arrayValue?.compactMap(\.doubleValue) }
    public func json(_ name: String) -> JSONValue? { raw(name) }

    /// For required params (validation guarantees presence).
    public func requiredString(_ name: String) -> String { string(name) ?? "" }
    public func requiredTime(_ name: String) -> MediaTime { time(name) ?? .zero }
}

// MARK: - Context

/// Everything a command may read or change. Copied per execution: commit on success only.
public struct CommandContext {
    public var project: Project?
    /// The `.regista` folder the project lives in (nil until first save path is known).
    public var projectURL: URL?
    public var history = History()
    public var dirty = false
    /// Set by a command that wrote a user brand kit: the engine records it as one undo step.
    public var kitChange: KitChange?
    public var prober: MediaProber
    public var services: EngineServices
    /// Where derived media goes while the project has no folder yet.
    var scratch: URL?

    public init(prober: MediaProber, services: EngineServices) {
        self.prober = prober
        self.services = services
    }

    /// Folder for files Regista generates (extracted audio, cleaned voice, face tracks):
    /// `<project>.regista/media`, or a temporary folder until the project has a location.
    public mutating func mediaDirectory() throws -> URL {
        let dir: URL
        if let projectURL { dir = projectURL.appendingPathComponent("media") }
        else if let scratch { dir = scratch }
        else {
            dir = TemporaryFolder.url.appendingPathComponent("regista-media-\(UUID().uuidString.prefix(8))")
            scratch = dir
        }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw CommandError(.io, "Cannot create \(dir.path): \(error.localizedDescription)") }
        return dir
    }

    /// The open project, or a clear error.
    public func requireProject() throws -> Project {
        guard let project else { throw CommandError(.noProject, "No project open: call project.new or project.open first") }
        return project
    }

    /// Timeline time from a param, snapped to the project's frame grid.
    func timelineTime(_ p: CommandParams, _ name: String, in project: Project) -> MediaTime? {
        p.time(name)?.snapped(to: project.settings.frameRate)
    }
}

/// Undo/redo as project snapshots: projects are small values, so storing the state before and
/// after each edit is the simplest scheme that is obviously correct (no inverse to get wrong). A brand kit edit
/// (the kit lives outside the project) is a step too: its folder before and after.
public struct History: Sendable {
    public struct Entry: Sendable {
        public var command: String
        public var params: JSONValue
        /// nil for a kit edit made with no project open.
        public var before: Project?
        public var after: Project?
        public var kit: KitChange?

        public init(command: String, params: JSONValue, before: Project?, after: Project?, kit: KitChange? = nil) {
            self.command = command
            self.params = params
            self.before = before
            self.after = after
            self.kit = kit
        }
    }

    public var undoStack: [Entry] = []
    public var redoStack: [Entry] = []
    public var limit = 500

    mutating func record(_ e: Entry) {
        undoStack.append(e)
        if undoStack.count > limit { undoStack.removeFirst(undoStack.count - limit) }
        redoStack.removeAll()
    }

    mutating func reset() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
