import Foundation

/// What the installer's Python helpers did, in the app's own code (#106): a Mac without Apple's Command Line Tools has
/// only a `python3` stub that asks to install them, so nothing an app downloaded by a person runs may call it.
/// `regista-engine` answers these for scripts/install.sh, scripts/lib.sh and scripts/doctor.sh (`regista-engine manifest …`,
/// `config …`, `claude-desktop …`); Settings › Claude calls `ClaudeDesktopConfig` directly.
public struct HelperOutput: Equatable, Sendable {
    public var status: Int32
    public var out: String
    public var err: String

    public init(status: Int32 = 0, out: String = "", err: String = "") {
        self.status = status
        self.out = out
        self.err = err
    }

    static func fail(_ message: String, _ status: Int32 = 1) -> HelperOutput { HelperOutput(status: status, err: message + "\n") }
}

// MARK: - Manifest queries (scripts/engines.py)

/// The queries of scripts/engines.py on the engine manifest and engines.lock, with the same output, line for line
/// (`validate` and `docs` stay in Python: they serve a developer's clone and the commit hook, never an installed app).
public enum ManifestQuery {
    public static let usage = """
    regista-engine manifest <command> …  (the queries of scripts/engines.py)
      tier-for-ram <GB> · need-gb <tier|id> [--detail] · disk <tier> · steps <id> · name <id> · size <id> ·
      field <id> <key> · comfy-bytes · others <id,id,…> · scripts <id> · install-info <id> · ids
    """

    /// The manifest and lock the installer reads: `$REGISTA_MANIFEST` / `$REGISTA_LOCK` when set (the installer tests'
    /// fake engine), else the copies compiled into the app.
    public static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> (EngineManifest, raw: [String: Any]) {
        func file(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }
        let manifestData: Data
        if let m = file(environment["REGISTA_MANIFEST"]) {
            guard let d = FileManager.default.contents(atPath: m) else { throw EngineManifest.ParseError(description: "cannot read \(m)") }
            manifestData = d
        } else {
            manifestData = Data(PackageResources.engines_manifest_json)
        }
        let lock: String
        if let l = file(environment["REGISTA_LOCK"]) {
            guard let d = FileManager.default.contents(atPath: l) else { throw EngineManifest.ParseError(description: "cannot read \(l)") }
            lock = String(decoding: d, as: UTF8.self)
        } else {
            lock = String(decoding: PackageResources.engines_lock, as: UTF8.self)
        }
        let manifest = try EngineManifest.parse(manifest: manifestData, lock: lock)
        let raw = (try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any]) ?? [:]
        return (manifest, raw)
    }

    public static func run(_ args: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> HelperOutput {
        let loaded: (EngineManifest, raw: [String: Any])
        do { loaded = try load(environment: environment) } catch { return .fail("regista-engine manifest: \(error)") }
        return run(args, manifest: loaded.0, raw: loaded.raw)
    }

    static func run(_ args: [String], manifest m: EngineManifest, raw: [String: Any]) -> HelperOutput {
        guard let cmd = args.first else { return .fail(usage) }
        let a = Array(args.dropFirst())
        var lines: [String] = []
        func arg(_ i: Int) -> String? { i < a.count ? a[i] : nil }
        func entry(_ i: Int) -> EngineManifest.Entry? { arg(i).flatMap { m.entry($0) } }
        func noEntry(_ i: Int) -> HelperOutput { .fail("regista-engine manifest: no entry '\(arg(i) ?? "")'") }
        func tier(_ s: String?) -> MachineTier? { s.flatMap { MachineTier(rawValue: $0) } }
        func installs(_ t: MachineTier) -> Double {
            Double(m.installerEntries(t).reduce(Int64(0)) { $0 + (m.diskBytes($1) ?? 0) }) / 1e9
        }

        switch cmd {
        case "tier-for-ram":
            guard let gb = arg(0).flatMap(Double.init) else { return .fail("regista-engine manifest: tier-for-ram <GB>") }
            lines = [m.tier(forMemoryGB: gb).rawValue]
        case "need-gb":
            if let e = entry(0) {
                lines = [String(Int((Double(m.diskBytes(e) ?? 0) / 1e9 + m.diskMarginGB).rounded(.up)))]
            } else if let t = tier(arg(0)) {
                lines = [arg(1) == "--detail"
                    ? String(format: "%d %.1f %g", m.installerNeedGB(t), installs(t), m.diskMarginGB)
                    : String(m.installerNeedGB(t))]
            } else {
                return .fail("regista-engine manifest: unknown tier '\(arg(0) ?? "")'")
            }
        case "disk":
            guard let t = tier(arg(0)) else { return .fail("regista-engine manifest: unknown tier '\(arg(0) ?? "")'") }
            for e in m.installerEntries(t) { lines.append(pad(e.id) + " " + gbText(m.diskBytes(e))) }
            lines.append(pad("+") + " " + String(format: "%g", m.diskMarginGB) + " GB margin")
            lines.append(pad("= need") + " " + "\(m.installerNeedGB(t)) GB")
        case "steps":
            guard let e = entry(0) else { return noEntry(0) }
            lines = e.install.steps ?? []
        case "name":
            guard let e = entry(0) else { return noEntry(0) }
            lines = [e.name]
        case "size":
            guard let e = entry(0) else { return noEntry(0) }
            lines = [m.diskBytes(e).map(String.init) ?? ""]
        case "field":
            guard entry(0) != nil, let key = arg(1) else { return noEntry(0) }
            let engines = raw["engines"] as? [[String: Any]] ?? []
            let value = engines.first { $0["id"] as? String == arg(0) }?[key]
            lines = [pythonText(value)]
        case "comfy-bytes":
            let total = m.entries.filter { $0.id == "comfyui" || $0.dependsOn.contains("comfyui") }.reduce(Int64(0)) { $0 + (m.diskBytes($1) ?? 0) }
            lines = [String(total)]
        case "others":
            let known = Set((arg(0) ?? "").split(separator: ",").map(String.init))
            lines = [m.entries.filter { !$0.planned && !known.contains($0.id) }.map(\.name).joined(separator: ", ")]
        case "scripts":
            guard let e = entry(0) else { return noEntry(0) }
            lines = e.scripts
        case "install-info":
            guard let e = entry(0) else { return noEntry(0) }
            lines = [[e.install.method, e.install.step ?? "", e.install.formula ?? "", m.artifacts(of: e).map(\.id).joined(separator: ","),
                      e.files.joined(separator: ","), m.tier(of: e)?.rawValue ?? "", e.status].joined(separator: "|")]
        case "ids":
            lines = m.entries.map(\.id)
        default:
            return .fail("regista-engine manifest: unknown command '\(cmd)'\n\(usage)")
        }
        return HelperOutput(out: lines.map { $0 + "\n" }.joined())
    }

    /// engines.py's `gb`: "?" unknown, "–" nothing, whole MB below 100 MB, GB with two decimals above.
    static func gbText(_ b: Int64?) -> String {
        guard let b else { return "?" }
        if b == 0 { return "–" }
        return b < 100_000_000 ? String(format: "%.0f MB", Double(b) / 1e6) : String(format: "%.2f GB", Double(b) / 1e9)
    }

    /// Python's "%-28s".
    static func pad(_ s: String) -> String { s.count >= 28 ? s : s + String(repeating: " ", count: 28 - s.count) }
}

/// How Python's `print` shows a JSON value (`None` printed as the empty line the scripts expect).
func pythonText(_ value: Any?) -> String {
    switch value {
    case nil, is NSNull: return ""
    case let s as String: return s
    case let n as NSNumber:
        if CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? "True" : "False" }
        if CFNumberIsFloatType(n) {
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : "\(d)"
        }
        return n.stringValue
    case let a as [Any]: return "[" + a.map(pythonRepr).joined(separator: ", ") + "]"
    case let o as [String: Any]: return "{" + o.keys.sorted().map { "'\($0)': " + pythonRepr(o[$0]) }.joined(separator: ", ") + "}"
    default: return "\(value!)"
    }
}

private func pythonRepr(_ value: Any?) -> String {
    if let s = value as? String { return "'" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'" }
    if value == nil || value is NSNull { return "None" }
    return pythonText(value)
}

// MARK: - engines.json (json_get / write_config)

/// The installer's reads and writes of engines.json: managed keys only, everything else the person set is kept.
public enum EnginesFile {
    /// The value of `key` as the scripts print it (empty when the file or the key is missing).
    public static func get(_ file: URL, _ key: String) -> HelperOutput {
        guard let data = FileManager.default.contents(atPath: file.path) else { return HelperOutput() }
        guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .fail("\(file.path) is not valid JSON")
        }
        return HelperOutput(out: pythonText(o[key]) + "\n")
    }

    /// Sets each key to its value (an empty value removes the key), keeping every other key; written to a temporary
    /// file first, then moved into place. A file that is not a JSON object is refused and left as it is.
    public static func set(_ file: URL, _ pairs: [(String, String)]) -> HelperOutput {
        var o: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: file.path) {
            guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .fail("\(file.path) is not valid JSON: not touched")
            }
            o = parsed
        }
        for (k, v) in pairs { if v.isEmpty { o.removeValue(forKey: k) } else { o[k] = v } }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try (out + Data("\n".utf8)).write(to: file, options: .atomic)
        } catch {
            return .fail("cannot write \(file.path): \(error.localizedDescription)")
        }
        return HelperOutput()
    }

    /// Exit 0 when the file holds valid JSON.
    public static func check(_ file: URL) -> HelperOutput {
        guard let data = FileManager.default.contents(atPath: file.path) else { return .fail("\(file.path): no such file") }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil ? HelperOutput()
            : .fail("\(file.path) is not valid JSON")
    }
}

// MARK: - Claude Desktop's configuration

/// The `regista` entry of Claude Desktop's config (what scripts/claude_desktop.py did): the same exit codes, the same
/// backup before every change, the same file layout (keys in their order, two-space indent, non-ASCII kept), and every
/// other key and server left as it was.
public enum ClaudeDesktopConfig {
    public static let usage = """
    regista-engine claude-desktop status <config> <regista-mcp> [KEY=VALUE …]
        exit 0 = mcpServers.regista is exactly the entry `set` writes · 1 = no file or no regista entry ·
        2 = regista is something else (its command is printed) · 3 = the file is not valid JSON / not an object
    regista-engine claude-desktop set <config> <regista-mcp> [KEY=VALUE …]
        adds or replaces mcpServers.regista = {"command": <regista-mcp>, "args": [], "env": {KEY: VALUE}}, keeping every
        other key and server; an existing file is first copied to <config>.regista-backup-<timestamp> (printed)
    regista-engine claude-desktop remove <config>
        removes mcpServers.regista (after the same backup), keeping everything else
    """

    /// Runs `status`, `set` or `remove` with the scripts' arguments.
    public static func run(_ args: [String]) -> HelperOutput {
        guard let cmd = args.first, args.count >= 2 else { return HelperOutput(status: 64, out: usage + "\n") }
        let file = URL(fileURLWithPath: args[1])
        switch cmd {
        case "remove" where args.count == 2: return remove(file)
        case "status", "set":
            guard args.count >= 3 else { break }
            let env = Array(args.dropFirst(3))
            guard env.allSatisfy({ $0.contains("=") }) else { break }
            let pairs = env.map { p -> (String, String) in
                let i = p.firstIndex(of: "=")!
                return (String(p[..<i]), String(p[p.index(after: i)...]))
            }
            return cmd == "status" ? status(file, mcp: args[2], env: pairs) : set(file, mcp: args[2], env: pairs)
        default: break
        }
        return HelperOutput(status: 64, out: usage + "\n")
    }

    /// The entry `set` writes.
    public static func expected(_ mcp: String, env: [(String, String)] = []) -> OrderedJSON {
        var fields: [(String, OrderedJSON)] = [("command", .string(mcp)), ("args", .array([]))]
        if !env.isEmpty {
            var e = OrderedJSON.object([])
            for (k, v) in env { e[k] = .string(v) }
            fields.append(("env", e))
        }
        return .object(fields)
    }

    /// (config, nil) · (nil, nil) when the file is missing · (nil, reason) when it is not usable.
    static func load(_ file: URL) -> (OrderedJSON?, String?) {
        guard FileManager.default.fileExists(atPath: file.path) else { return (nil, nil) }
        guard let data = FileManager.default.contents(atPath: file.path) else { return (nil, "\(file.path) is not valid JSON (unreadable)") }
        let cfg: OrderedJSON
        do { cfg = try OrderedJSON.parse(data) } catch { return (nil, "\(file.path) is not valid JSON (\(error))") }
        guard case .object = cfg, cfg["mcpServers"].map({ if case .object = $0 { return true } else { return false } }) ?? true else {
            return (nil, "\(file.path): expected a JSON object with an mcpServers object")
        }
        return (cfg, nil)
    }

    public static func status(_ file: URL, mcp: String, env: [(String, String)] = []) -> HelperOutput {
        let (cfg, err) = load(file)
        if let err { return HelperOutput(status: 3, out: err + "\n") }
        guard let entry = cfg?["mcpServers"]?["regista"], case .object = entry else { return HelperOutput(status: 1) }
        if entry.sameValue(expected(mcp, env: env)) { return HelperOutput() }
        let command = entry["command"]?.stringValue
        return HelperOutput(status: 2, out: (command ?? "(no command)") + (command == mcp ? " (other arguments or env)" : "") + "\n")
    }

    public static func set(_ file: URL, mcp: String, env: [(String, String)] = []) -> HelperOutput {
        let (loaded, err) = load(file)
        if let err { return HelperOutput(status: 3, out: err + "\n") }
        let entry = expected(mcp, env: env)
        var cfg = loaded ?? .object([])
        let old = cfg["mcpServers"]?["regista"]
        if let old, old.sameValue(entry) { return HelperOutput(out: "unchanged\n") }
        var servers = cfg["mcpServers"] ?? .object([])
        servers["regista"] = entry
        cfg["mcpServers"] = servers
        var out = ""
        switch write(cfg, to: file, backup: loaded != nil, check: { written in
            written["mcpServers"]?["regista"].map { $0.sameValue(entry) } == true
                && others(written).sameValue(others(loaded ?? .object([])))
        }) {
        case .failure(let message): return HelperOutput(status: 1, out: message + "\n")
        case .success(let backup): if let backup { out += "backup \(backup.path)\n" }
        }
        if let old { out += "replaced \(old["command"]?.stringValue ?? old.text())\n" } else { out += "added\n" }
        return HelperOutput(out: out)
    }

    public static func remove(_ file: URL) -> HelperOutput {
        let (loaded, err) = load(file)
        if let err { return HelperOutput(status: 3, out: err + "\n") }
        guard var cfg = loaded, var servers = cfg["mcpServers"], servers["regista"] != nil else { return HelperOutput(out: "absent\n") }
        servers.removeKey("regista")
        cfg["mcpServers"] = servers
        var out = ""
        switch write(cfg, to: file, backup: true, check: { written in
            written["mcpServers"]?["regista"] == nil && others(written).sameValue(others(loaded!))
        }) {
        case .failure(let message): return HelperOutput(status: 1, out: message + "\n")
        case .success(let backup): if let backup { out += "backup \(backup.path)\n" }
        }
        return HelperOutput(out: out + "removed\n")
    }

    /// The servers other than regista.
    private static func others(_ cfg: OrderedJSON) -> OrderedJSON {
        var s = cfg["mcpServers"] ?? .object([])
        s.removeKey("regista")
        return s
    }

    private enum WriteResult { case success(URL?), failure(String) }

    /// Backup (when the file existed), temporary file, read back and checked, then moved into place: a failure leaves the
    /// original untouched.
    private static func write(_ cfg: OrderedJSON, to file: URL, backup: Bool, check: (OrderedJSON) -> Bool) -> WriteResult {
        let fm = FileManager.default
        var copy: URL?
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if backup {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                let b = URL(fileURLWithPath: file.path + ".regista-backup-" + f.string(from: Date()))
                try? fm.removeItem(at: b)
                try fm.copyItem(at: file, to: b)
                copy = b
            }
            let tmp = URL(fileURLWithPath: file.path + ".regista-tmp")
            try Data((cfg.text(indent: 2) + "\n").utf8).write(to: tmp)
            guard let back = try? OrderedJSON.parse(Data(contentsOf: tmp)), check(back) else {
                try? fm.removeItem(at: tmp)
                return .failure("the written file did not read back as expected: original left untouched")
            }
            guard rename(tmp.path, file.path) == 0 else {
                try? fm.removeItem(at: tmp)
                return .failure("cannot replace \(file.path): \(String(cString: strerror(errno)))")
            }
        } catch {
            return .failure("cannot write \(file.path): \(error.localizedDescription)")
        }
        return .success(copy)
    }
}

// MARK: - JSON that keeps its key order

/// JSON whose objects keep their keys in the file's order, written the way Python's `json.dump(indent=2,
/// ensure_ascii=False)` writes it: a person's configuration comes back laid out as it was.
public indirect enum OrderedJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The number as written in the file.
    case number(String)
    case string(String)
    case array([OrderedJSON])
    case object([(String, OrderedJSON)])

    public static func == (a: OrderedJSON, b: OrderedJSON) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    /// Equal as values (Python's `==` on dicts: key order does not matter; 1 and 1.0 are equal).
    public func sameValue(_ other: OrderedJSON) -> Bool {
        switch (self, other) {
        case (.number(let x), .number(let y)): return x == y || (Double(x) != nil && Double(x) == Double(y))
        case (.array(let x), .array(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.sameValue($1) }
        case (.object(let x), .object(let y)):
            guard x.count == y.count else { return false }
            let other = Dictionary(y, uniquingKeysWith: { $1 })
            return x.allSatisfy { k, v in other[k].map { v.sameValue($0) } ?? false }
        default: return self == other
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }

    public subscript(key: String) -> OrderedJSON? {
        get {
            guard case .object(let fields) = self else { return nil }
            return fields.last { $0.0 == key }?.1
        }
        set {
            guard case .object(var fields) = self else { return }
            if let i = fields.firstIndex(where: { $0.0 == key }) {
                if let newValue { fields[i].1 = newValue } else { fields.remove(at: i) }
            } else if let newValue {
                fields.append((key, newValue))
            }
            self = .object(fields)
        }
    }

    public mutating func removeKey(_ key: String) { self[key] = nil }

    // MARK: writing

    /// Python's `json.dumps(value, indent=…, ensure_ascii=False)` (no indent: one line with ", " and ": ").
    public func text(indent: Int? = nil) -> String {
        var out = ""
        write(&out, indent: indent, level: 0)
        return out
    }

    private func write(_ out: inout String, indent: Int?, level: Int) {
        func newline(_ l: Int) { if let indent { out += "\n" + String(repeating: " ", count: indent * l) } }
        let comma = indent == nil ? ", " : ","
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): Self.quote(s, into: &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += comma }
                newline(level + 1)
                v.write(&out, indent: indent, level: level + 1)
            }
            newline(level)
            out += "]"
        case .object(let fields):
            if fields.isEmpty { out += "{}"; return }
            out += "{"
            for (i, (k, v)) in fields.enumerated() {
                if i > 0 { out += comma }
                newline(level + 1)
                Self.quote(k, into: &out)
                out += ": "
                v.write(&out, indent: indent, level: level + 1)
            }
            newline(level)
            out += "}"
        }
    }

    private static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }

    // MARK: reading

    public struct ParseError: Error, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ data: Data) throws -> OrderedJSON {
        var p = Parser(bytes: Array(data))
        p.skipSpace()
        let v = try p.value(depth: 0)
        p.skipSpace()
        guard p.i == p.bytes.count else { throw p.error("extra data") }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        func error(_ what: String) -> ParseError { ParseError(description: "\(what) at byte \(i)") }

        mutating func skipSpace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func literal(_ word: String, _ v: OrderedJSON) throws -> OrderedJSON {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw error("unexpected character") }
            i += w.count
            return v
        }

        mutating func value(depth: Int) throws -> OrderedJSON {
            guard depth < 512 else { throw error("nested too deep") }
            guard i < bytes.count else { throw error("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var fields: [(String, OrderedJSON)] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(fields) }
                while true {
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("expected a key") }
                    let k = try string()
                    skipSpace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("expected ':'") }
                    i += 1
                    skipSpace()
                    let v = try value(depth: depth + 1)
                    // A repeated key keeps its first place and its last value (Python's dict).
                    if let j = fields.firstIndex(where: { $0.0 == k }) { fields[j].1 = v } else { fields.append((k, v)) }
                    skipSpace()
                    guard i < bytes.count else { throw error("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(fields) }
                    throw error("expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [OrderedJSON] = []
                skipSpace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipSpace()
                    items.append(try value(depth: depth + 1))
                    skipSpace()
                    guard i < bytes.count else { throw error("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw error("expected ',' or ']'")
                }
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): return try literal("true", .bool(true))
            case UInt8(ascii: "f"): return try literal("false", .bool(false))
            case UInt8(ascii: "n"): return try literal("null", .null)
            default: return try number()
            }
        }

        mutating func number() throws -> OrderedJSON {
            let start = i
            func digits() -> Int { let s = i; while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }; return i - s }
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard digits() > 0 else { i = start; throw error("unexpected character") }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") { i += 1; guard digits() > 0 else { throw error("bad number") } }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digits() > 0 else { throw error("bad number") }
            }
            return .number(String(decoding: bytes[start..<i], as: UTF8.self))
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw error("bad \\u escape") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1   // the opening quote
            var out = String.UnicodeScalarView()
            var run = i
            func flush() throws {
                guard let s = String(bytes: bytes[run..<i], encoding: .utf8) else { throw error("invalid UTF-8") }
                out.append(contentsOf: s.unicodeScalars)
            }
            while true {
                guard i < bytes.count else { throw error("unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") { try flush(); i += 1; return String(out) }
                if c < 0x20 { throw error("control character in a string") }
                if c != UInt8(ascii: "\\") { i += 1; continue }
                try flush()
                i += 1
                guard i < bytes.count else { throw error("unterminated string") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append("\"")
                case UInt8(ascii: "\\"): out.append("\\")
                case UInt8(ascii: "/"): out.append("/")
                case UInt8(ascii: "b"): out.append("\u{08}")
                case UInt8(ascii: "f"): out.append("\u{0C}")
                case UInt8(ascii: "n"): out.append("\n")
                case UInt8(ascii: "r"): out.append("\r")
                case UInt8(ascii: "t"): out.append("\t")
                case UInt8(ascii: "u"):
                    var v = try hex4()
                    if (0xD800...0xDBFF).contains(v), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("bad surrogate pair") }
                        v = 0x10000 + ((v - 0xD800) << 10) + (low - 0xDC00)
                    }
                    guard let s = Unicode.Scalar(v) else { throw error("lone surrogate") }
                    out.append(s)
                default: throw error("bad escape")
                }
                run = i
            }
        }
    }
}
