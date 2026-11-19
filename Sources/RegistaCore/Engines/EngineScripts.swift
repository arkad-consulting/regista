import Foundation

/// The small helper scripts of an installed engine follow the app (#61). scripts/install.sh copies them from the
/// repository's `engines/` into the engines folder once (`wx_align.py`, `textnorm.py`, `vox_say.py`…: the manifest's
/// `scripts`); an app update that changes one would otherwise never reach a folder installed before it. At launch and
/// when the engine is used, each script of an installed engine that differs from the app's own copy is replaced.
/// Scripts only: never a lock file, an environment or a model; an engine that is not installed gets nothing; a failure
/// to write is a line in the log, never an error for the person.
public enum EngineScripts {
    public struct Report: Equatable, Sendable {
        /// Scripts written (relative to the engines folder).
        public var replaced: [String] = []
        /// "<script>: <reason>" for each one that could not be read or written.
        public var failed: [String] = []
    }

    /// The app's copy of `engines/`: the installer next to it (`$REGISTA_INSTALLER`, else `Contents/Resources/Installer`,
    /// both copied by scripts/build-app.sh), else the repository this file was built from (a development run).
    public static var source: URL? {
        let env = ProcessInfo.processInfo.environment["REGISTA_INSTALLER"].flatMap { $0.isEmpty ? nil : $0 }
        var candidates = [env.map { URL(fileURLWithPath: EngineConfig.expand($0)) },
                          Bundle.main.resourceURL?.appendingPathComponent("Installer")]
        #if !REGISTA_RELEASE   // a release build carries no path of the Mac that built it (#108)
        // Sources/RegistaCore/Engines/EngineScripts.swift → the repository.
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent())
        #endif
        return candidates.compactMap { $0?.appendingPathComponent("engines", isDirectory: true) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Installed = every file of the entry that is not one of its scripts (nor a folder holding them) is in the folder:
    /// the environment, the lock file, the project. A half-installed engine is left to the installer.
    public static func installed(_ e: EngineManifest.Entry, in engines: URL) -> Bool {
        let rest = e.files.filter { f in !e.scripts.contains { $0 == f || $0.hasPrefix(f + "/") } }
        return !e.scripts.isEmpty && !rest.isEmpty
            && rest.allSatisfy { FileManager.default.fileExists(atPath: engines.appendingPathComponent($0).path) }
    }

    /// The scripts of an installed entry that differ from the app's copy (a missing one included); empty when the entry
    /// is not installed or the app has no copy.
    public static func differing(_ e: EngineManifest.Entry, in engines: URL = EngineCatalog.enginesDirectory,
                                 source: URL? = Self.source) -> [String] {
        guard let source, installed(e, in: engines) else { return [] }
        return e.scripts.filter { f in
            guard let ours = FileManager.default.contents(atPath: source.appendingPathComponent(f).path) else { return false }
            return FileManager.default.contents(atPath: engines.appendingPathComponent(f).path) != ours
        }
    }

    /// Replaces the differing scripts of the installed entries (`ids`: those engines only; nil: every entry that has
    /// scripts). Each write is atomic; a failure is logged and the others still run.
    @discardableResult
    public static func refresh(_ ids: [String]? = nil, in engines: URL = EngineCatalog.enginesDirectory,
                               source: URL? = Self.source, manifest: EngineManifest = .shared,
                               log: (String) -> Void = { NSLog("Regista: %@", $0) }) -> Report {
        var report = Report()
        guard let source else { return report }
        for e in manifest.entries where !e.scripts.isEmpty && (ids?.contains(e.id) ?? true) {
            for f in differing(e, in: engines, source: source) {
                let target = engines.appendingPathComponent(f)
                do {
                    let data = try Data(contentsOf: source.appendingPathComponent(f))
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: target, options: .atomic)
                    report.replaced.append(f)
                    log("\(e.name): helper script \(f) replaced with the app's copy")
                } catch {
                    report.failed.append("\(f): \(error.localizedDescription)")
                    log("\(e.name): cannot replace helper script \(target.path) with the app's copy: \(error.localizedDescription)")
                }
            }
        }
        return report
    }
}
