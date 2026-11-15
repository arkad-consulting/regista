import AppKit
import AVFoundation
import RegistaCore
import RegistaEngines
import ScreenCaptureKit
import SwiftUI
import Testing
@testable import Regista

// The test window cannot reach outside the test (#35). The click audit clicks every control it finds, on the Mac of
// whoever runs the suite, so the rig is isolated by construction rather than by a list of labels:
// - its stores get their services from `RigServices` through the workbench's one seam (every tab, also a tab a click
//   opens): scratch folders for voice profiles, budget and approvals, generation providers whose job cannot start,
//   the fixture transcription, no ComfyUI server, heavy engines pointed at paths that do not exist;
// - everything else that leaves the process points at a scratch target of this test process (`RigOutside`):
//   engines.json, the engines folder, the installer (a stub that writes down its arguments), the Claude clients'
//   home folder (a stub `claude` command and a stub regista-mcp);
// - the recorder gets a capture stand-in (`RigCapture`): a "recording" state, no session, no camera or microphone opened,
//   no permission prompt, no speech recognition; copies go to a private pasteboard;
// - under all of it, RigGuard refuses every process that is not on `RigProcesses`' short allow-list and keeps the
//   Trash of the person running the tests untouched.

// MARK: - Scratch targets outside Regista's folder

/// The test process's stand-ins for what lies outside Regista's folder (named after the pid, like the other scratch
/// folders of the test targets).
struct RigOutside {
    let root: URL
    /// A copy of the engines.json in use when the tests started (the same engines; Forza livello writes the copy).
    let enginesFile: URL
    /// `REGISTA_SUPPORT_DIR`: its `engines` folder is the one Rimuovi deletes from.
    let support: URL
    var enginesFolder: URL { support.appendingPathComponent("engines", isDirectory: true) }
    /// `REGISTA_INSTALLER`: scripts/install.sh writes its arguments to `installLog` and installs nothing;
    /// scripts/claude_desktop.py is the repository's own (it edits the scratch Claude Desktop configuration).
    let installer: URL
    let installLog: URL
    /// `REGISTA_CLAUDE_HOME`: Claude Code's configuration names `mcp` as Regista's server; `claude` writes its arguments
    /// to `claudeLog`.
    let claudeHome: URL
    let mcp: URL
    let claudeLog: URL

    var desktopConfig: URL { claudeHome.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json") }

    /// The repository (this file is Tests/RegistaAppTests/RigIsolation.swift).
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func install() -> RigOutside {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("regista-tests-outside-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? fm.removeItem(at: root)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        func script(_ url: URL, _ text: String) {
            try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try! text.write(to: url, atomically: true, encoding: .utf8)
            try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        // engines.json: the one the tests started with, copied before the variable points at the copy.
        let engines = root.appendingPathComponent("engines.json")
        if let data = fm.contents(atPath: EngineConfig.defaultFile.path) { try! data.write(to: engines) }
        let support = root.appendingPathComponent("support", isDirectory: true)
        try! fm.createDirectory(at: support.appendingPathComponent("engines"), withIntermediateDirectories: true)
        let installer = root.appendingPathComponent("installer", isDirectory: true)
        let installLog = root.appendingPathComponent("installer.log")
        script(installer.appendingPathComponent("scripts/install.sh"), """
            #!/bin/bash
            # The test rig's installer: writes down what it was asked and installs nothing.
            echo "$@" >> "\(installLog.path)"
            echo "✓ test rig: nothing installed"
            """)
        try! fm.copyItem(at: repository.appendingPathComponent("scripts/claude_desktop.py"), to: installer.appendingPathComponent("scripts/claude_desktop.py"))
        let home = root.appendingPathComponent("claude-home", isDirectory: true)
        let mcp = home.appendingPathComponent("regista-mcp")
        let claudeLog = root.appendingPathComponent("claude.log")
        script(mcp, "#!/bin/bash\nexit 0\n")
        script(home.appendingPathComponent(".local/bin/claude"), """
            #!/bin/bash
            # The test rig's claude command: writes down what it was asked and changes nothing.
            echo "$@" >> "\(claudeLog.path)"
            """)
        try! #"{"mcpServers": {"regista": {"command": "\#(mcp.path)", "args": []}}}"#.write(to: home.appendingPathComponent(".claude.json"), atomically: true, encoding: .utf8)
        setenv("REGISTA_ENGINES", engines.path, 1)
        setenv("REGISTA_SUPPORT_DIR", support.path, 1)
        setenv("REGISTA_INSTALLER", installer.path, 1)
        setenv("REGISTA_CLAUDE_HOME", home.path, 1)
        return RigOutside(root: root, enginesFile: engines, support: support, installer: installer, installLog: installLog,
                          claudeHome: home, mcp: mcp, claudeLog: claudeLog)
    }

    /// Lines the installer stub wrote.
    var installs: [String] { ((try? String(contentsOf: installLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
}

/// Installed once, before the first rig: from then on the test process's engines.json, engines folder, installer and
/// Claude clients' home are the scratch ones.
let rigOutside = RigOutside.install()

// MARK: - Services

/// The services of the rig's stores (every tab of the rig's workbench).
enum RigServices {
    /// One scratch support folder per workbench, as the app has one support folder for all its tabs.
    static func factory() -> @MainActor () -> EngineServices {
        let folder = rigTempDir("services")
        return { make(in: folder) }
    }

    /// The live services with everything that leaves the process replaced: what a person's app gets, minus the reach.
    @MainActor static func make(in folder: URL) -> EngineServices {
        var s = Workbench.liveServices()
        s.config.cacheDirectory = folder.appendingPathComponent("cache").path
        // The heavy engines a click could start outside Regista's own work: nothing is found there, nothing runs.
        let none = folder.appendingPathComponent("not-installed", isDirectory: true)
        s.config.uv = none.appendingPathComponent("uv").path
        s.config.voxcpmProject = none.appendingPathComponent("voxcpm").path
        s.config.voxcpmScript = none.appendingPathComponent("voxcpm/vox_say.py").path
        s.config.voxcpmModel = none.appendingPathComponent("voxcpm/VoxCPM2").path
        s.config.comfyGen = none.appendingPathComponent("comfy-gen").path
        s.config.comfyRun = none.appendingPathComponent("comfy_run.py").path
        s.config.higgsfield = none.appendingPathComponent("higgsfield").path
        // Blender and the HyperFrames CLI (apps of their own, minutes of work per click) are not found either.
        s.config.blender = none.appendingPathComponent("Blender").path
        s.config.node = none.appendingPathComponent("node").path
        s.config.hyperframes = none.appendingPathComponent("hyperframes.mjs").path
        s.config.npx = none.appendingPathComponent("npx").path
        // WhisperX and its aligners read as missing (the transcription is the fixture's): Motori offers their install,
        // the non-commercial aligners behind their licence.
        s.config.whisperXProject = none.appendingPathComponent("whisperx").path
        s.config.whisperXScript = none.appendingPathComponent("whisperx/wx_align.py").path
        s.transcribers = [WhisperCppTranscriber.engineID: FixtureTranscriber(),
                          WhisperXTranscriber.engineID: FixtureTranscriber(id: WhisperXTranscriber.engineID)]
        s.profiles = ProfileStore(directory: folder.appendingPathComponent("profiles", isDirectory: true))
        s.generationState = folder.appendingPathComponent("generation", isDirectory: true)
        s.rules = RuleBook(directory: folder.appendingPathComponent("rules", isDirectory: true))
        s.generators = [:]
        for g in [ComfyUIProvider(config: s.config), HiggsfieldProvider(config: s.config),
                  VoxCPMProvider(config: s.config, profiles: s.profiles)] as [GeneratorProvider] {
            s.generators[g.id] = RigGenerator(real: g)
        }
        s.comfyServer = { nil }
        return s
    }
}

/// A generation provider as the panel and the agent see it (id, title, paid, tier, models, formats, times), whose job
/// cannot start: `process` fails with a clear message, so nothing is run and nothing is spent. A paid provider's estimate
/// is a fixed number (its CLI is never asked).
struct RigGenerator: GeneratorProvider {
    let real: GeneratorProvider
    static let estimate = 0.15
    static func refusal(_ title: String) -> String { "\(title): a stand-in of the test rig, no generation starts" }

    var id: String { real.id }
    var title: String { real.title }
    var paid: Bool { real.paid }
    var minimumTier: MachineTier { real.minimumTier }
    var models: [GeneratorModel] { real.models }

    func unavailableReason(_ kind: GenerationKind) -> String? {
        models.contains { $0.kind == kind } ? nil : real.unavailableReason(kind)
    }
    func estimate(_ request: GenerationRequest) throws -> Double { paid ? Self.estimate : 0 }
    func process(_ request: GenerationRequest, job: URL) throws -> GenerationProcess { throw CommandError(.io, Self.refusal(title)) }
    func prepare(_ request: GenerationRequest) throws -> GenerationRequest { try real.prepare(request) }
    func collect(_ request: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput { throw CommandError(.io, Self.refusal(title)) }
    func finish(keepRunning: Bool) {}
    func seconds(_ request: GenerationRequest, sourceSeconds: Double?) -> Double? { real.seconds(request, sourceSeconds: sourceSeconds) }
    func formats(_ kind: GenerationKind) -> [GenerationFormat] { real.formats(kind) }
}

// MARK: - Capture

/// The recorder's hardware in the rig: every permission reads as allowed (nothing is asked), the devices are the
/// connected ones as listed (none is opened), the session's setup never runs, a take is a "recording" state that writes
/// nothing, the screen is never offered, and the teleprompter gets no speech recognition. What the recorder asked is in
/// `log`.
@MainActor
final class RigCapture: CaptureHardware {
    private(set) var log: [String] = []
    struct Refused: LocalizedError {
        let errorDescription: String?
        init(_ what: String) { errorDescription = "the test rig's capture stand-in: \(what)" }
    }

    func permission(_ type: AVMediaType) -> CapturePermission { .granted }
    func requestAccess(_ type: AVMediaType) async { log.append("requestAccess \(type.rawValue)") }
    func screenAllowed() -> Bool { false }
    func requestScreen() { log.append("requestScreen") }
    func devices(_ type: AVMediaType) -> [AVCaptureDevice] {
        // Listing the devices opens none of them and asks nothing.
        let kinds: [AVCaptureDevice.DeviceType] = type == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: kinds, mediaType: type, position: .unspecified).devices
    }
    func openDevices(_ setup: @escaping @Sendable () -> Void) { log.append("openDevices") }
    func startMovie(_ output: AVCaptureMovieFileOutput, to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        log.append("startMovie \(url.lastPathComponent)")
        take = (url, delegate)
    }
    func stopMovie(_ output: AVCaptureMovieFileOutput) {
        log.append("stopMovie")
        guard let (url, delegate) = take else { return }
        take = nil
        let error = NSError(domain: "RigCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "nothing was recorded (test rig)",
                                                                       AVErrorRecordingSuccessfullyFinishedKey: false])
        delegate.fileOutput(output, didFinishRecordingTo: url, from: [], error: error)
    }
    func shareableContent() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
        log.append("shareableContent")
        throw Refused("no screen")
    }
    func listen(locale: Locale, contextualStrings: [String], emit: @escaping @Sendable (SpeechHypothesis) -> Void) async throws -> LiveSpeechSession {
        log.append("listen \(locale.identifier)")
        throw Refused("no speech recognition")
    }

    private var take: (URL, AVCaptureFileOutputRecordingDelegate)?
}

/// Copies made in the rig land here, never on the general pasteboard.
@MainActor let rigPasteboard = NSPasteboard(name: NSPasteboard.Name("regista-rig-\(ProcessInfo.processInfo.processIdentifier)"))

// MARK: - The process net

/// Every process the code starts while the rig is installed, and the ones refused. Thread-safe: engines start their
/// processes on their own queues.
enum RigProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _started: [String] = []
    nonisolated(unsafe) private static var _refused: [String] = []

    static var started: [String] { lock.withLock { _started } }
    static var refused: [String] { lock.withLock { _refused } }

    /// The tools the suite runs on scratch files (listed from every process a full run started, 2026-11-15): ffmpeg,
    /// ffprobe and DeepFilterNet of the engines.json in use, and ditto (brand kit packages).
    static let tools: Set<String> = {
        let c = EngineConfig.loadOrDefault().config
        return [c.ffmpeg, c.ffprobe, c.deepFilter].map(EngineConfig.expand).reduce(into: ["/usr/bin/ditto"]) { $0.insert($1) }
    }()
    /// Interpreters allowed to run a script of the repository or of a scratch folder (the installer tests, the fake
    /// engines of the generation tests, the rig's own stubs), never anything else.
    static let interpreters: Set<String> = ["/bin/sh", "/bin/bash", "/usr/bin/python3"]
    /// Where scripts and fakes may live: the temporary folder (the tests' scratch folders) and the repository.
    static let places: [String] = {
        let tmp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return [tmp, "/private" + tmp, FileManager.default.temporaryDirectory.path, RigOutside.repository.path].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }()

    static func inside(_ path: String) -> Bool { places.contains { path.hasPrefix($0) || path + "/" == $0 } }

    /// Why `executable` with `arguments` may not start (nil: it may).
    static func refusal(_ executable: String, _ arguments: [String]) -> String? {
        if tools.contains(executable) || inside(executable) { return nil }
        guard interpreters.contains(executable) else { return "not on the test rig's allow-list" }
        var args = arguments.drop { $0 == "-I" || $0 == "-e" || $0 == "-u" }
        if args.first == "-c" {
            args = args.dropFirst()
            let script = args.first ?? ""
            // A command line may name only scratch or repository paths…
            let re = try! NSRegularExpression(pattern: #"(?:^|[\s'"=;(])(/[A-Za-z][^\s'";)]*)"#)
            let paths = re.matches(in: script, range: NSRange(script.startIndex..., in: script)).compactMap { Range($0.range(at: 1), in: script).map { String(script[$0]) } }
            if let outside = paths.first(where: { !inside($0) && !tools.contains($0) && !interpreters.contains($0) }) {
                return "\(executable) -c names \(outside), outside the scratch folders and the repository"
            }
            // …and what it runs as "$0" is checked in turn (the generation wrapper runs it).
            guard let zero = args.dropFirst().first else { return nil }
            return inside(zero) ? nil : refusal(zero, Array(args.dropFirst(2)))
        }
        guard let script = args.first(where: { !$0.hasPrefix("-") }) else { return "\(executable) without a script" }
        return inside(script) ? nil : "\(executable) runs \(script), outside the scratch folders and the repository"
    }

    /// Called by RigGuard for each start: records it and says whether it may run.
    static func check(_ executable: String, _ arguments: [String]) -> String? {
        let line = ([executable] + arguments.prefix(4).map { $0.count > 120 ? String($0.prefix(120)) + "…" : $0 }).joined(separator: " ")
        let why = refusal(executable, arguments)
        lock.withLock {
            _started.append(line)
            if let why { _refused.append("\(line) — \(why)") }
        }
        if let why { FileHandle.standardError.write(Data("RigGuard: refused a process: \(line) — \(why)\n".utf8)) }
        return why
    }
}

/// Where the rig's Trash is: what the code sends to the Trash lands here (RigGuard), never in the Trash of the person
/// running the tests.
enum RigTrash {
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-tests-trash-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _taken: [String] = []
    /// The names of the items sent to the Trash.
    static var taken: [String] { lock.withLock { _taken } }

    static func take(_ url: URL) throws -> URL {
        let dest = folder.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(url.lastPathComponent)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: dest)
        lock.withLock { _taken.append(url.lastPathComponent) }
        return dest
    }
}

/// Writes to the general pasteboard the code tried (refused by RigGuard).
enum RigPasteboard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _generalWrites: [String] = []
    static var generalWrites: [String] { lock.withLock { _generalWrites } }
    nonisolated(unsafe) private static var _writes = 0
    /// Writes to the other pasteboards (the rig's), counted without asking the pasteboard server.
    static var writes: Int { lock.withLock { _writes } }
    static func recordWrite() { lock.withLock { _writes += 1 } }
    static func recordGeneralWrite(_ what: String) {
        lock.withLock { _generalWrites.append(what) }
        FileHandle.standardError.write(Data("RigGuard: refused a write to the general pasteboard (\(what))\n".utf8))
    }
}

// MARK: - The proof

/// What lies on the side of the person running the tests (#35): Regista's real support folder (voice profiles, budget
/// and approvals, engines.json, the engines, brand kits), Claude Desktop's configuration, Claude Code's servers and the
/// default folder of projects, recordings and exports. A listing of paths, sizes and modification times.
enum OwnerSide {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    static let support = home.appendingPathComponent("Library/Application Support/Regista", isDirectory: true)
    static let desktopConfig = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    static let codeConfig = home.appendingPathComponent(".claude.json")
    static let movies = home.appendingPathComponent("Movies/Regista", isDirectory: true)
    /// Written by Regista itself when the owner's app runs beside the tests (its log files and its engine socket):
    /// they are not the tests' to compare.
    static let ownersApp: Set<String> = ["logs", "engine.sock"]

    static func listing() -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]
        func line(_ url: URL) -> String {
            let v = try? url.resourceValues(forKeys: Set(keys))
            return "\(url.path) \(v?.fileSize ?? -1) \(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        for root in [support, movies] where fm.fileExists(atPath: root.path) {
            out.append(line(root))
            let e = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
            while let url = e?.nextObject() as? URL {
                if root == support, ownersApp.contains(url.pathComponents[support.pathComponents.count]) { e?.skipDescendants(); continue }
                out.append(line(url))
            }
        }
        if fm.fileExists(atPath: desktopConfig.path) { out.append(line(desktopConfig)) }
        // Claude Code rewrites its own file all the time: its servers are compared, not the file.
        if let d = fm.contents(atPath: codeConfig.path), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let servers = (o["mcpServers"] as? [String: Any]).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: .sortedKeys) }
            out.append("\(codeConfig.path) mcpServers \(servers.map { String(decoding: $0, as: UTF8.self) } ?? "none")")
        }
        return out.sorted()
    }
}

/// Every place the rig can write to, seam by seam (#35): each must resolve under the scratch root of the test process
/// (its temporary folder). This is the hard part of the proof: it holds whatever else runs on the Mac.
enum RigScratch {
    static var roots: [String] {
        let t = FileManager.default.temporaryDirectory
        return Set([t.path, t.resolvingSymlinksInPath().path, t.standardizedFileURL.path]).map { $0.hasSuffix("/") ? $0 : $0 + "/" }
    }

    /// The seams and where they point now (nil: the seam found nothing, which is a failure too).
    @MainActor static func seams() -> [(seam: String, path: URL?)] {
        _ = rigFolder
        _ = rigKitsDirectory
        _ = rigOutside
        let s = RigServices.factory()()
        return [
            ("Regista's folder", Paths.root), ("recordings", Paths.recordings),
            ("support folder (budget, approvals)", s.generationState), ("voice profiles", s.profiles.directory),
            ("rule sheets", s.rules.directory), ("rule sheets of the support folder", RuleBook.defaultDirectory),
            ("caches", URL(fileURLWithPath: EngineConfig.expand(s.config.cacheDirectory))),
            ("engines.json", EngineConfig.defaultFile), ("engines folder", EngineCatalog.enginesDirectory),
            ("brand kits", BrandKit.userDirectory),
            ("Claude home", ClaudeClients.home), ("Claude Desktop configuration", ClaudeClients.desktopConfig),
            ("Claude Code configuration", ClaudeClients.codeConfig), ("claude command", ClaudeClients.claudeCLI().map { URL(fileURLWithPath: $0) }),
            ("Trash target", RigTrash.folder), ("installer", EngineInstaller.locate(resources: nil)?.script),
        ]
    }

    /// The seams that point outside the scratch root, in words; empty when every one is inside.
    @MainActor static func outside() -> [String] {
        seams().compactMap { s in
            guard let url = s.path else { return "\(s.seam): nothing" }
            let paths = [url.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
            return paths.contains { p in roots.contains { p.hasPrefix($0) } } ? nil : "\(s.seam): \(url.path)"
        }
    }
}

/// What a difference in the owner-side listing means. The owner may use Regista while the audits run (the push hook
/// runs them on his Mac): his app autosaves projects and writes brand kits there. With it running, a difference is
/// reported as a known issue naming the paths, never a failure; with it closed, it fails.
enum OwnerSideVerdict: Equatable {
    case same
    case failure([String])
    case ownersAppMayHaveWritten([String])

    static func decide(changes: [String], ownersAppRunning: Bool) -> OwnerSideVerdict {
        if changes.isEmpty { return .same }
        return ownersAppRunning ? .ownersAppMayHaveWritten(changes) : .failure(changes)
    }

    /// A process named Regista whose executable is inside an app bundle (the test process is not one).
    @MainActor static var ownersAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.executableURL?.lastPathComponent == "Regista" && app.bundleURL?.pathExtension == "app"
        }
    }
}

/// Wraps the click audits of whole screens (#35). Always: every seam the rig writes through resolves under the scratch
/// root, no process was refused, the general pasteboard was not written. And the owner-side listing is the same after
/// them as before (a difference while the owner's app runs is a known issue: it may be the app's own writes).
struct OwnerSideUntouched: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        let outsideBefore = await MainActor.run { RigScratch.outside() }
        #expect(outsideBefore.isEmpty, "rig seams outside the scratch root: \(outsideBefore)")
        let before = OwnerSide.listing()
        let refused = RigProcesses.refused.count, writes = RigPasteboard.generalWrites.count
        try await function()
        let outsideAfter = await MainActor.run { RigScratch.outside() }
        #expect(outsideAfter.isEmpty, "rig seams outside the scratch root: \(outsideAfter)")
        #expect(RigProcesses.refused.count == refused, "processes refused during the click audits: \(RigProcesses.refused.dropFirst(refused))")
        #expect(RigPasteboard.generalWrites.count == writes, "writes to the general pasteboard: \(RigPasteboard.generalWrites.dropFirst(writes))")
        let after = OwnerSide.listing()
        let changes = Set(before).symmetricDifference(after).sorted()
        switch OwnerSideVerdict.decide(changes: changes, ownersAppRunning: await OwnerSideVerdict.ownersAppRunning) {
        case .same: break
        case .failure(let paths):
            Issue.record("the owner's side changed during the click audits (the owner's app is not running): \(paths.prefix(20))")
        case .ownersAppMayHaveWritten(let paths):
            withKnownIssue("the owner's app is running: these may be its own writes", isIntermittent: true) {
                Issue.record("the owner's side changed during the click audits: \(paths.prefix(20))")
            }
        }
        let started = RigProcesses.started
        FileHandle.standardError.write(Data(("RigGuard: \(started.count) processes started in this test process; by executable: "
            + Dictionary(grouping: started) { String($0.prefix { $0 != " " }) }.map { "\($0.key) ×\($0.value.count)" }.sorted().joined(separator: ", ")
            + "\n").utf8))
    }
}

extension Trait where Self == OwnerSideUntouched {
    /// The owner's side is the same after the suite as before it (#35).
    static var ownerSideUntouched: Self { Self() }
}
