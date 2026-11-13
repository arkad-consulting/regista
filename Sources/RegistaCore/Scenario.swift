import Foundation

/// A scripted editing session with expectations, replayed directly on an Engine
/// (`regista-engine run`) or through the MCP server (`scripts/scenario.sh`).
///
/// ```json
/// {"name": "basic", "steps": [
///   {"command": "timeline.cut", "params": {"at": 10},
///    "expect": {"result.cuts": {"count": 2}, "state.tracks.0.clips.1.start": 10},
///    "capture": {"mid": "result.cuts.0.right"}},
///   {"command": "history.redo", "expectError": "nothing to redo"}
/// ]}
/// ```
/// - `expect` keys are paths into `result` (the command's answer) or `state` (project.state
///   after the step). A plain value means equality (numbers ±1e-6); an object is a matcher:
///   `equals`, `approx` (+ `tol`, default 0.001), `min` / `max` (inclusive), `count`, `exists`, `contains`, and
///   `includes` (an array that has, for each listed object, an element with those fields: `{"includes": [{"id": "whisperx",
///   "available": true}]}`, so a list that grows, like engines.status, is not pinned to a count).
/// - `requires` (top level, e.g. `["engines"]`) marks scenarios that need the analysis engines; the
///   pre-commit hook skips them (`regista-engine run --skip-requiring engines`). `"footage"` marks
///   scenarios that need the test media listed in `footage` (paths, `${VAR}` expanded): they are
///   skipped when any of it is missing (a clone without the test footage).
/// - `defaults` (top level) gives environment variables a value when they are not set, e.g.
///   `{"REGISTA_TEST_MEDIA_DIR": "${HOME}/Movies/Regista"}`: footage paths are written `${REGISTA_TEST_MEDIA_DIR}/…`
///   and a clone without that folder skips the scenario. A default may use an earlier one.
/// - `show` lists paths printed after the step (numbers for a report).
/// - `capture` stores values for later `${name}` / `${name.path}` substitution in params and
///   expectations. `${WORK}` (scratch folder), `${SCENARIO_DIR}` and environment variables
///   (`${HOME}`) are predefined.
public struct Scenario {
    public struct Step {
        public var command: String
        public var params: JSONValue
        public var expect: [(path: String, matcher: JSONValue)]
        public var expectError: String?
        public var capture: [(name: String, path: String)]
        /// Paths of `result`/`state` printed after the step (the numbers a golden run reports).
        public var show: [String] = []
    }

    public var name: String
    public var steps: [Step]
    public var requires: [String]
    /// Media files a `requires: footage` scenario reads.
    public var footage: [String]
    /// Values for environment variables that are not set (`${VAR}` in them is expanded from the environment).
    public var defaults: [String: String] = [:]

    public init(json: JSONValue, fallbackName: String = "scenario") throws {
        guard let steps = json["steps"]?.arrayValue else { throw ScenarioError("scenario: missing \"steps\" array") }
        name = json["name"]?.stringValue ?? fallbackName
        requires = json["requires"]?.arrayValue?.compactMap(\.stringValue) ?? []
        footage = json["footage"]?.arrayValue?.compactMap(\.stringValue) ?? []
        defaults = (json["defaults"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        self.steps = try steps.enumerated().map { i, s in
            guard let command = s["command"]?.stringValue else { throw ScenarioError("step \(i + 1): missing \"command\"") }
            return Step(
                command: command,
                params: s["params"] ?? .object([:]),
                expect: (s["expect"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) },
                expectError: s["expectError"]?.stringValue,
                capture: (s["capture"]?.objectValue ?? [:]).sorted { $0.key < $1.key }.compactMap { k, v in v.stringValue.map { (k, $0) } },
                show: s["show"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
    }

    /// The environment with the scenario's defaults for the variables it does not set.
    public func environment(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        // Twice, so a default can use another default (REGISTA_TEST_MEDIA from REGISTA_GOLDEN_MEDIA).
        for _ in 0..<2 {
            for (k, v) in defaults where (base[k] ?? "").isEmpty {
                var value = v
                for (name, x) in env { value = value.replacingOccurrences(of: "${\(name)}", with: x) }
                env[k] = EngineConfig.expand(value)
            }
        }
        return env
    }

    /// Footage paths (environment variables expanded) that are not on disk; empty unless `requires` has "footage".
    public func missingFootage(environment base: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        guard requires.contains("footage") else { return [] }
        let environment = self.environment(base)
        let paths = footage.map { path in
            var out = path
            for (k, v) in environment { out = out.replacingOccurrences(of: "${\(k)}", with: v) }
            return EngineConfig.expand(out)
        }
        return paths.isEmpty ? ["(no footage listed)"] : paths.filter { !FileManager.default.fileExists(atPath: $0) }
    }

    public static func load(_ url: URL) throws -> Scenario {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw ScenarioError("cannot read \(url.path)") }
        return try Scenario(json: JSONValue.parse(data), fallbackName: url.deletingPathExtension().lastPathComponent)
    }
}

public struct ScenarioError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

public struct ScenarioRunner {
    /// Runs one command and returns its result; throws on command errors.
    public typealias Execute = (_ command: String, _ params: JSONValue) throws -> JSONValue

    public var variables: [String: JSONValue]
    let execute: Execute
    let output: (String) -> Void

    public init(variables: [String: JSONValue] = [:], output: @escaping (String) -> Void = { print($0) }, execute: @escaping Execute) {
        self.variables = variables
        self.execute = execute
        self.output = output
    }

    /// Stops at the first failing step. Returns true if every step passed.
    @discardableResult
    public mutating func run(_ scenario: Scenario) -> Bool {
        output("▶ \(scenario.name) — \(scenario.steps.count) steps")
        var checks = 0
        for (i, step) in scenario.steps.enumerated() {
            let label = "\(i + 1). \(step.command)"
            do {
                let n = try run(step)
                checks += n
                output("  ✓ \(label)\(n > 0 ? " (\(n) check\(n == 1 ? "" : "s"))" : "")")
            } catch {
                output("  ✗ \(label): \(error)")
                output("✗ \(scenario.name): failed at step \(i + 1)")
                return false
            }
        }
        output("✓ \(scenario.name): \(scenario.steps.count) steps, \(checks) checks passed")
        return true
    }

    /// Returns the number of checks performed.
    mutating func run(_ step: Scenario.Step) throws -> Int {
        let params = try substitute(step.params)
        var result: JSONValue = .null
        do {
            result = try execute(step.command, params)
            if let expected = step.expectError { throw ScenarioError("expected an error containing \"\(expected)\", got success: \(result)") }
        } catch let error as ScenarioError {
            throw error
        } catch {
            guard let expected = step.expectError else { throw ScenarioError("command failed: \(error)") }
            guard "\(error)".contains(expected) else { throw ScenarioError("error \"\(error)\" does not contain \"\(expected)\"") }
            return 1
        }

        let needsState = (step.expect.map(\.path) + step.capture.map(\.path) + step.show).contains { $0.hasPrefix("state") }
        let root: JSONValue = ["result": result, "state": needsState ? try execute("project.state", [:]) : .null]
        for (path, raw) in step.expect {
            let matcher = try substitute(raw)
            if let failure = Self.check(root.value(at: path), matcher) {
                // The values asked for with `show` explain a failure too.
                for path in step.show { output("      \(path) = \(root.value(at: path).map { "\($0)" } ?? "—")") }
                throw ScenarioError("\(path): \(failure)")
            }
        }
        for (name, path) in step.capture {
            guard let v = root.value(at: path) else { throw ScenarioError("capture \(name): nothing at \(path)") }
            variables[name] = v
        }
        for path in step.show { output("      \(path) = \(root.value(at: path).map { "\($0)" } ?? "—")") }
        return step.expect.count
    }

    // MARK: Matching

    /// Nil if `actual` satisfies `matcher`, otherwise why not.
    static func check(_ actual: JSONValue?, _ matcher: JSONValue) -> String? {
        guard case .object(let m) = matcher else { return equal(actual, matcher) }
        let known: Set = ["equals", "approx", "tol", "min", "max", "count", "exists", "contains", "includes"]
        if let unknown = m.keys.first(where: { !known.contains($0) }) { return "unknown matcher \"\(unknown)\"" }
        if let exists = m["exists"]?.boolValue, (actual != nil && actual != .null) != exists {
            return exists ? "expected a value, found nothing" : "expected nothing, found \(actual!)"
        }
        if let expected = m["equals"], let f = equal(actual, expected) { return f }
        if let target = m["approx"]?.doubleValue {
            let tol = m["tol"]?.doubleValue ?? 0.001
            guard let a = actual?.doubleValue else { return "expected ≈\(target), found \(actual.map { $0.text() } ?? "nothing")" }
            if abs(a - target) > tol { return "expected \(target) ±\(tol), found \(a)" }
        }
        for (key, bound) in [("min", m["min"]?.doubleValue), ("max", m["max"]?.doubleValue)] {
            guard let bound else { continue }
            guard let a = actual?.doubleValue else { return "expected a number (\(key) \(bound)), found \(actual.map { $0.text() } ?? "nothing")" }
            if key == "min" ? a < bound : a > bound { return "expected \(key == "min" ? "≥" : "≤") \(bound), found \(a)" }
        }
        if let n = m["count"]?.doubleValue {
            let count = actual?.arrayValue?.count ?? actual?.objectValue?.count
            guard let count else { return "expected \(Int(n)) items, found \(actual.map { $0.text() } ?? "nothing")" }
            if Double(count) != n { return "expected \(Int(n)) items, found \(count)" }
        }
        if let s = m["contains"]?.stringValue {
            let text = actual?.stringValue ?? actual?.text() ?? ""
            if !text.contains(s) { return "expected to contain \"\(s)\", found \(text)" }
        }
        if let wanted = m["includes"]?.arrayValue {
            guard let items = actual?.arrayValue else { return "expected a list, found \(actual.map { $0.text() } ?? "nothing")" }
            for w in wanted {
                let fields = w.objectValue ?? [:]
                let found = items.contains { item in
                    fields.isEmpty ? approxEqual(item, w) : fields.allSatisfy { k, v in item[k].map { approxEqual($0, v) } ?? false }
                }
                if !found { return "expected an element with \(w.text()), found none among \(items.count)" }
            }
        }
        return nil
    }

    static func equal(_ actual: JSONValue?, _ expected: JSONValue) -> String? {
        guard let actual else { return "expected \(expected), found nothing" }
        return approxEqual(actual, expected) ? nil : "expected \(expected), found \(actual)"
    }

    /// Deep equality with a 1e-6 tolerance on numbers (summaries are rounded to the µs).
    static func approxEqual(_ a: JSONValue, _ b: JSONValue) -> Bool {
        switch (a, b) {
        case (.number(let x), .number(let y)): return abs(x - y) <= 1e-6
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy(approxEqual)
        case (.object(let x), .object(let y)):
            return x.count == y.count && x.allSatisfy { k, v in y[k].map { approxEqual(v, $0) } ?? false }
        default: return a == b
        }
    }

    // MARK: Substitution

    func substitute(_ v: JSONValue) throws -> JSONValue {
        switch v {
        case .string(let s): return try substitute(s)
        case .array(let a): return .array(try a.map(substitute))
        case .object(let o): return .object(try o.mapValues(substitute))
        default: return v
        }
    }

    /// "${x}" alone becomes x's JSON value; inside a longer string it is spliced as text.
    private func substitute(_ s: String) throws -> JSONValue {
        guard s.contains("${") else { return .string(s) }
        let pattern = try NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_.]*)\}"#)
        let ns = s as NSString
        let matches = pattern.matches(in: s, range: NSRange(location: 0, length: ns.length))
        if matches.count == 1, matches[0].range.length == ns.length {
            return try lookup(ns.substring(with: matches[0].range(at: 1)))
        }
        var out = s
        for m in matches.reversed() {
            let v = try lookup(ns.substring(with: m.range(at: 1)))
            out = (out as NSString).replacingCharacters(in: m.range, with: v.stringValue ?? v.text())
        }
        return .string(out)
    }

    private func lookup(_ ref: String) throws -> JSONValue {
        let parts = ref.split(separator: ".", maxSplits: 1).map(String.init)
        let base: JSONValue
        if let v = variables[parts[0]] { base = v }
        else if let env = ProcessInfo.processInfo.environment[parts[0]] { base = .string(env) }
        else { throw ScenarioError("unknown variable ${\(ref)}") }
        guard parts.count == 2 else { return base }
        guard let v = base.value(at: parts[1]) else { throw ScenarioError("${\(ref)}: nothing at \(parts[1])") }
        return v
    }
}
