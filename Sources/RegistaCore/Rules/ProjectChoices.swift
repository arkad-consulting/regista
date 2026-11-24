import Foundation

// What this person wants for this project (one regia): the kind's sheet over the "For every video" sheet over the
// default (RuleBook.choices), the project's own choices on top (project.setChoices: a change made in a step of the Simple
// level, or asked of Claude, for this project only). The commands start from it where a call leaves a value out and say
// which choices they used (`fromChoices`); the Simple steps and «Fai tutto» open on it. Nothing else holds a default for a
// choice.

/// A choice set for one project only: the option, and its number when the choice has one.
public struct ChoiceOverride: Codable, Hashable, Sendable {
    public var value: String
    public var number: [Double]?

    public init(value: String, number: [Double]? = nil) {
        self.value = value
        self.number = number
    }
}

/// Every choice of a project, resolved: the regia (the person's sheets for the project's kind) and the project's own.
public struct ProjectChoices: Sendable {
    /// The kind whose sheets the regia comes from.
    public let kind: String
    /// Each choice as the regia says, without the project's own.
    public let regia: [String: RuleBook.ChoiceState]
    /// The project's own choices (valid options only).
    public let overrides: [String: ChoiceOverride]

    /// The choices of `project` (none: the defaults); without a rule book, the defaults stand for the regia.
    public init(_ project: Project?, book: RuleBook?) {
        let kind = project.map { p in book?.kind(of: p).kind ?? RuleBook.kind(width: p.settings.width, height: p.settings.height) } ?? RuleBook.everyVideo
        let states = book?.choices(kind, language: "en", all: true)
            ?? RuleChoiceSpec.all.map { RuleBook.ChoiceState(spec: $0, value: $0.defaultOption, number: $0.number?.defaultValue, source: "default") }
        self.kind = kind
        regia = Dictionary(uniqueKeysWithValues: states.map { ($0.spec.id, $0) })
        overrides = (project?.choices ?? [:]).filter { id, o in RuleChoiceSpec.named(id)?.option(o.value) != nil }
    }

    private func spec(_ id: String) -> RuleChoiceSpec {
        guard let s = RuleChoiceSpec.named(id) else { preconditionFailure("unknown choice \(id)") }
        return s
    }

    /// The option the project has: its own, else the regia's.
    public func value(_ id: String) -> String { overrides[id]?.value ?? regiaValue(id) }

    /// The choice's number (a zoom, seconds, a range): the project's own, else the regia's; nil when the choice has none.
    public func number(_ id: String) -> [Double]? {
        guard spec(id).number != nil else { return nil }
        return overrides[id]?.number ?? regiaNumber(id)
    }

    public func regiaValue(_ id: String) -> String { regia[id]?.value ?? spec(id).defaultOption }
    public func regiaNumber(_ id: String) -> [Double]? { regia[id]?.number ?? spec(id).number?.defaultValue }

    /// The project's own choice differs from the regia (the Simple steps show a dot).
    public func differs(_ id: String) -> Bool {
        guard let o = overrides[id] else { return false }
        return o.value != regiaValue(id) || (o.number != nil && o.number != regiaNumber(id))
    }

    /// The pauses of the pace the project has: longer ones are cut, `keepPause` of breath stays (edit.autoCut).
    public var pace: (maxPause: Double, keepPause: Double) { Self.pace(value("pace")) }

    /// The pauses of a pace option.
    public static func pace(_ option: String) -> (maxPause: Double, keepPause: Double) {
        let o = RuleChoiceSpec.named("pace")?.option(option) ?? RuleChoiceSpec.named("pace")!.option(RuleChoiceSpec.named("pace")!.defaultOption)!
        return (o.values["maxPause"] ?? 0, o.values["keepPause"] ?? 0)
    }

    /// The pace option whose pauses these are; the presets of the steps before the choices map to their pace (natural
    /// 1.0/0.2 → calm; medium and tight had the numbers of normal and fast). nil for other numbers.
    public static func pace(maxPause: Double, keepPause: Double) -> String? {
        if abs(maxPause - 1.0) < 0.005, abs(keepPause - 0.2) < 0.005 { return "calm" }
        return RuleChoiceSpec.named("pace")?.options.first {
            abs(($0.values["maxPause"] ?? -1) - maxPause) < 0.005 && abs(($0.values["keepPause"] ?? -1) - keepPause) < 0.005
        }?.id
    }

    /// Where each choice comes from and what it is: rules.get's resolution with the project's own on top.
    public var json: JSONValue {
        .array(RuleChoiceSpec.all.map { s in
            var o: [String: JSONValue] = ["id": .string(s.id), "value": .string(value(s.id)), "regia": .string(regiaValue(s.id)),
                                          "source": .string(overrides[s.id] != nil ? "project" : regia[s.id]?.source ?? "default")]
            if let n = number(s.id) { o["number"] = RuleChoiceSpec.json(n) }
            if let n = regiaNumber(s.id), s.number != nil { o["regiaNumber"] = RuleChoiceSpec.json(n) }
            return .object(o)
        })
    }
}

/// The choices a command used where its call left a value out, for its result's `fromChoices`: {"pace": "fast"}; a number
/// used too follows the option ("alternate 1.15"), a number alone stands alone ("1.15").
public struct ChoicesUsed {
    public let choices: ProjectChoices
    private var used: [String: (value: Bool, number: Bool)] = [:]

    public init(_ choices: ProjectChoices) { self.choices = choices }

    /// The project's option of `id`, noted as used.
    public mutating func value(_ id: String) -> String {
        used[id, default: (false, false)].value = true
        return choices.value(id)
    }

    /// The project's number of `id`, noted as used.
    public mutating func number(_ id: String) -> [Double] {
        used[id, default: (false, false)].number = true
        return choices.number(id) ?? []
    }

    /// The pace's pauses, noted as used.
    public mutating func pace() -> (maxPause: Double, keepPause: Double) { ProjectChoices.pace(value("pace")) }

    public var json: JSONValue {
        var o: [String: JSONValue] = [:]
        for (id, u) in used {
            let number = u.number ? choices.number(id).map(RuleChoiceSpec.format) : nil
            o[id] = .string([u.value ? choices.value(id) : nil, number].compactMap { $0 }.joined(separator: " "))
        }
        return .object(o)
    }

    /// No choice used.
    public var isEmpty: Bool { used.isEmpty }
}
