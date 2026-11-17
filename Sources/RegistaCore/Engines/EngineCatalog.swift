import Foundation

/// The Motori screen's data (M2 #59): every manifest entry as engines.status reports it, grouped by tier, with its
/// state on this Mac and the one action the screen offers for it. Built from the engines.status result (the same data
/// Claude reads) and a tier — the Mac's, or a forced one — so a forced tier changes the rows before the app restarts.
public struct EngineCatalog: Equatable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case base, medium, pro, cloud, planned
    }

    public enum State: Equatable, Sendable {
        case installed
        case missing
        /// Regista cannot see it (ComfyUI's model folders).
        case notChecked
        case planned
        /// The engine needs a higher tier than the one shown.
        case needsTier(MachineTier)
    }

    public enum Action: Equatable, Sendable {
        /// `scripts/install.sh --only <id>` can install it.
        case install
        /// Its files in the engines folder can be deleted (after a confirmation that says what stops working).
        case remove
        /// Set up by hand: the manifest's steps, and "check again".
        case howTo([String])
        /// Downloaded by its engine the first time it is needed.
        case firstUse([String])
        /// Part of macOS, or planned: nothing to do.
        case nothing
    }

    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let name: String
        public let unlocks: [String]
        public let disk: String
        public let licence: String
        public let nonCommercial: Bool
        public let paid: Bool
        public let optional: Bool
        public let method: String
        public let group: Group
        public let state: State
        public let action: Action
        /// The engine's own reason when it is missing (engines.status `reason`), e.g. "npx (Node.js) not found".
        public let reason: String?
        /// False when the engine's helper scripts differ from the app's and could not be replaced (#61).
        public var scriptsCurrent = true
    }

    public let tier: MachineTier
    public let detected: MachineTier?
    public let memoryGB: Int
    public let rows: [Row]

    public func rows(_ g: Group) -> [Row] { rows.filter { $0.group == g } }
    public func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// From an engines.status result. `tier`: show the rows as on that tier (nil: the one engines.status reports).
    /// `enginesDirectory`: where removable files are looked for (default: the installer's folder).
    public init(status: JSONValue, tier forced: MachineTier? = nil, manifest: EngineManifest = .shared,
                enginesDirectory: URL = EngineCatalog.enginesDirectory) {
        let reported = (status["engines"]?.arrayValue ?? []) + (status["components"]?.arrayValue ?? [])
        let byID = Dictionary(reported.compactMap { r in r["id"]?.stringValue.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let tier = forced ?? status["tier"]?.stringValue.flatMap(MachineTier.init) ?? .base
        self.tier = tier
        memoryGB = Int(status["memoryGB"]?.doubleValue ?? 0)
        detected = status["memoryGB"]?.doubleValue.map { manifest.tier(forMemoryGB: $0) }
        rows = manifest.entries.map { e in
            let r = byID[e.id]
            let needed = manifest.tier(of: e)
            var state: State
            switch r?["state"]?.stringValue ?? (e.planned ? "planned" : "notChecked") {
            case "installed": state = .installed
            case "missing": state = .missing
            case "planned": state = .planned
            default: state = .notChecked
            }
            if let needed, needed > tier, state != .planned { state = .needsTier(needed) }
            let group: Group = e.planned ? .planned : e.install.method == "cloud" ? .cloud
                : Group(rawValue: (needed ?? .base).rawValue) ?? .base
            let action: Action
            switch e.install.method {
            case _ where e.planned: action = .nothing
            case "installer", "homebrew":
                if state == .missing { action = .install }
                else if state == .installed, !EngineCatalog.removable(e, in: enginesDirectory).isEmpty { action = .remove }
                else { action = .nothing }
            case "manual", "cloud": action = state == .installed ? .nothing : .howTo(e.install.steps ?? [])
            case "firstUse":
                action = state == .installed && !EngineCatalog.removable(e, in: enginesDirectory).isEmpty ? .remove
                    : state == .installed ? .nothing : .firstUse(e.install.steps ?? [])
            default: action = .nothing
            }
            return Row(id: e.id, name: e.name, unlocks: e.unlocks, disk: manifest.diskText(e.id), licence: e.licence,
                       nonCommercial: e.nonCommercial, paid: e.paid, optional: e.optional, method: e.install.method,
                       group: group, state: state, action: action, reason: r?["reason"]?.stringValue,
                       scriptsCurrent: r?["scriptsCurrent"]?.boolValue ?? true)
        }
    }

    // MARK: Removal

    /// Where scripts/install.sh puts the engines (`$REGISTA_SUPPORT_DIR/engines` when set, as in scripts/lib.sh).
    public static var enginesDirectory: URL {
        if let s = ProcessInfo.processInfo.environment["REGISTA_SUPPORT_DIR"], !s.isEmpty {
            return URL(fileURLWithPath: EngineConfig.expand(s)).appendingPathComponent("engines", isDirectory: true)
        }
        return URL(fileURLWithPath: EngineConfig.expand(EngineConfig.managedDirectory), isDirectory: true)
    }

    /// The entry's files that exist in the engines folder (nothing outside it, whatever the manifest says).
    public static func removable(_ e: EngineManifest.Entry, in engines: URL = enginesDirectory) -> [URL] {
        let root = engines.standardizedFileURL.path + "/"
        return e.files.compactMap { f in
            let url = engines.appendingPathComponent(f).standardizedFileURL
            guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
    }

    /// The available entries that need `id`, directly or through another one.
    public static func dependents(of id: String, manifest: EngineManifest = .shared) -> [EngineManifest.Entry] {
        var found: [EngineManifest.Entry] = [], queue = [id]
        while let next = queue.popLast() {
            for e in manifest.entries where !e.planned && e.dependsOn.contains(next) && !found.contains(e) && e.id != id {
                found.append(e)
                queue.append(e.id)
            }
        }
        return found
    }

    /// What stops working once `id` is removed: its own unlocks, then those of what needs it (no repeats).
    public static func stopsWorking(_ id: String, manifest: EngineManifest = .shared) -> [String] {
        var out: [String] = []
        for e in [manifest.entry(id)].compactMap({ $0 }) + dependents(of: id, manifest: manifest) {
            for u in e.unlocks where !out.contains(u) { out.append(u) }
        }
        return out
    }

    /// Deletes the entry's files in the engines folder and nothing else; returns what it deleted.
    @discardableResult
    public static func remove(_ id: String, manifest: EngineManifest = .shared, in engines: URL = enginesDirectory) throws -> [URL] {
        guard let e = manifest.entry(id) else { throw CommandError.invalid("unknown engine \(id)") }
        let urls = removable(e, in: engines)
        for u in urls { try FileManager.default.removeItem(at: u) }
        return urls
    }
}

/// Runs `scripts/install.sh --only <id>` — the installer copied into the app bundle (`Contents/Resources/Installer`, by
/// scripts/build-app.sh) or the one `$REGISTA_INSTALLER` names. Inside a `CommandJob` its progress (steps, downloads)
/// reaches the job, and Cancel stops it and everything it started. Never sudo, never a password: stdin is /dev/null,
/// so the installer takes its defaults and Homebrew cannot prompt.
public struct EngineInstaller: Sendable {
    public let script: URL
    public var environment: [String: String]

    public init(script: URL, environment: [String: String] = [:]) {
        self.script = script
        // An app started from the Finder gets launchd's short PATH: the system tools the installer calls (sysctl,
        // hdiutil, shasum) and Homebrew's, whatever the shell profile says.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        self.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin" + (path.isEmpty ? "" : ":" + path)].merging(environment) { $1 }
    }

    /// The installer next to the app (nil when this build has none: a plain `swift build`).
    public static func locate(resources: URL? = Bundle.main.resourceURL) -> EngineInstaller? {
        let env = ProcessInfo.processInfo.environment["REGISTA_INSTALLER"].flatMap { $0.isEmpty ? nil : $0 }
        let dirs = [env.map { URL(fileURLWithPath: EngineConfig.expand($0)) }, resources?.appendingPathComponent("Installer")].compactMap { $0 }
        for d in dirs {
            let s = d.appendingPathComponent("scripts/install.sh")
            if FileManager.default.isExecutableFile(atPath: s.path) { return EngineInstaller(script: s) }
        }
        return nil
    }

    /// Installs one engine; throws the installer's own last error line when it fails.
    public func install(_ id: String) throws {
        let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), [script.path, "--only", id], environment: environment,
                                   currentDirectory: script.deletingLastPathComponent(), progress: .installer)
        guard r.status == 0 else { throw CommandError(.io, Self.failure(r.stderrText + "\n" + r.stdoutText)) }
    }

    /// The installer's reason (its "✗ …" line), else the last lines it printed.
    static func failure(_ output: String) -> String {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let x = lines.last(where: { $0.hasPrefix("✗") }) { return String(x.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return lines.suffix(3).joined(separator: " · ")
    }
}
