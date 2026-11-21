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
//   a VoxCPM2 environment whose uv is a stub (RigVoice: a synthetic tone, a placeholder checkpoint), the fixture
//   transcription, no ComfyUI server, the other heavy engines pointed at paths that do not exist;
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
    /// `REGISTA_INSTALLER`: scripts/install.sh writes its arguments to `installLog` and installs nothing (Claude Desktop's
    /// scratch configuration is edited by the app's own code, ClaudeDesktopConfig).
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
        let root = TemporaryFolder.url.appendingPathComponent("regista-tests-outside-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
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
        // The voice: the rig's VoxCPM2 environment, whose uv is a stub (RigVoice): a click on «Ascolta», «Metti in
        // timeline» or «Allena la voce» runs its command through the real provider, nothing is synthesised or trained.
        let vox = RigVoice.install(in: folder)
        s.config.uv = vox.appendingPathComponent("uv").path
        s.config.voxcpmProject = vox.path
        s.config.voxcpmScript = vox.appendingPathComponent("vox_say.py").path
        s.config.voxcpmModel = vox.appendingPathComponent("VoxCPM2").path
        // ComfyUI: an address where nothing listens, no folder set, none looked for in the person's home.
        s.config.comfyServer = "http://127.0.0.1:9"
        s.config.comfyStart = nil
        s.comfyPlaces = []
        // Model file downloads (#121): an address where nothing listens.
        s.modelSource = ModelFetch.Source.unreachable
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
        for g in [ComfyUIProvider(config: s.config, places: []), HiggsfieldProvider(config: s.config)] as [GeneratorProvider] {
            s.generators[g.id] = RigGenerator(real: g)
        }
        // VoxCPM2 is the real provider on the rig's environment: its process is the stub uv.
        s.generators["voxcpm"] = VoxCPMProvider(config: s.config, profiles: s.profiles)
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

// MARK: - Voice

/// The rig's VoxCPM2 environment (#36): what the real VoxCPM provider and the trainer look for — pyproject.toml, the
/// recording scripts (the repository's own), vox_say.py, the trainer, the model's config.json — in a scratch folder,
/// and a `uv` that is a stub: asked for vox_say.py it writes a short synthetic tone where the request says (nothing is
/// synthesised by an engine), asked for the trainer it writes a LoRA checkpoint of placeholder files. What it was asked
/// is in `log`. Nothing is played (RigGuard mutes every player) and nothing is recorded (the capture stand-in).
enum RigVoice {
    /// The stub's record of its calls, one line each ("say <out>", "train <config>").
    static func log(_ folder: URL) -> URL { folder.appendingPathComponent("uv.log") }

    static func install(in folder: URL) -> URL {
        let fm = FileManager.default
        let vox = folder.appendingPathComponent("voxcpm", isDirectory: true)
        if fm.fileExists(atPath: vox.appendingPathComponent("uv").path) { return vox }
        let repo = RigOutside.repository.appendingPathComponent("engines/voxcpm")
        try? fm.createDirectory(at: vox.appendingPathComponent("VoxCPM2"), withIntermediateDirectories: true)
        try? fm.copyItem(at: repo.appendingPathComponent("pyproject.toml"), to: vox.appendingPathComponent("pyproject.toml"))
        try? fm.copyItem(at: repo.appendingPathComponent("scripts"), to: vox.appendingPathComponent("scripts"))
        for placeholder in ["vox_say.py", "train_voxcpm_finetune.py"] {
            try? "# the test rig's placeholder: the stub uv never runs it\n".write(to: vox.appendingPathComponent(placeholder), atomically: true, encoding: .utf8)
        }
        try? "{}".write(to: vox.appendingPathComponent("VoxCPM2/config.json"), atomically: true, encoding: .utf8)
        let uv = vox.appendingPathComponent("uv")
        try? stub(log: log(vox)).write(to: uv, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        return vox
    }

    /// `uv run --frozen --project <p> python -I <script> <args…>`, as VoxCPM's provider and the trainer call it.
    private static func stub(log: URL) -> String {
        """
        #!/usr/bin/python3 -I
        # The test rig's uv (#36): no engine runs. vox_say.py writes a 1.2 s synthetic tone where the request says;
        # the trainer writes a LoRA checkpoint of placeholder files next to its config.
        import json, math, os, struct, sys, wave
        args = sys.argv[1:]
        script = next((a for a in args if a.endswith(".py")), "")
        rest = args[args.index(script) + 1:] if script else []
        with open(\(log.path.debugDescription), "a") as f:
            f.write(os.path.basename(script) + " " + " ".join(a[:80] for a in rest) + "\\n")
        if script.endswith("vox_say.py"):
            request = json.loads(rest[0])
            files = []
            for item in request["items"]:
                rate = 24000
                with wave.open(item["out"], "wb") as w:
                    w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate)
                    w.writeframes(b"".join(struct.pack("<h", int(6000 * math.sin(2 * math.pi * 220 * i / rate))) for i in range(int(rate * 1.2))))
                files.append(item["out"])
            print(json.dumps({"files": files, "wall_seconds": 0.1}))
        elif script.endswith("train_voxcpm_finetune.py"):
            config = rest[rest.index("--config_path") + 1]
            step = os.path.join(os.path.dirname(config), "step_0000300")
            os.makedirs(step, exist_ok=True)
            for name in ("lora_weights.safetensors", "lora_config.json"):
                with open(os.path.join(step, name), "w") as f:
                    f.write("{}")
            print("[train] step 299: loss 0.1, log interval: 1.0s")
        else:
            sys.exit("the test rig's uv runs vox_say.py and the trainer only")
        """
    }
}

// MARK: - Capture

/// The recorder's hardware in the rig: every permission reads as allowed (nothing is asked), the devices are the
/// connected ones as listed (none is opened), the session's setup never runs, and the teleprompter gets no speech
/// recognition. A take is a "recording" state that writes nothing, unless the test gives `take`: then Stop hands the
/// recorder a copy of that movie as the take it recorded. The screen is never offered, unless the test sets `screen`:
/// then the rig's displays are the targets and a screen take is `RigScreenSession`, which writes a synthetic session
/// (recording.synthesize) on Stop. No device is opened and nothing is captured either way. What the recorder asked is
/// in `log`.
@MainActor
final class RigCapture: CaptureHardware {
    private(set) var log: [String] = []
    /// The movie a camera or voice take hands over on Stop, and the camera stretch of a screen session (nil: a take
    /// writes nothing and ends with an error, as before).
    var take: URL?
    /// Screen recording reads as allowed, the displays (`displays`) as its targets, and a screen take writes a synthetic session.
    var screen = false
    /// The displays the rig says are connected (nil: the main display alone, as macOS lists it). A test gives 1 or 4
    /// (DisplayInfo.samples); a display is never outlined on the screen (`log` says it was asked).
    var displays: [DisplayInfo]?
    /// The screen sessions the recorder made (the last one is the take in progress or just finished).
    private(set) var sessions: [RigScreenSession] = []

    struct Refused: LocalizedError {
        let errorDescription: String?
        init(_ what: String) { errorDescription = "the test rig's capture stand-in: \(what)" }
    }

    func permission(_ type: AVMediaType) -> CapturePermission { .granted }
    func requestAccess(_ type: AVMediaType) async { log.append("requestAccess \(type.rawValue)") }
    func screenAllowed() -> Bool { screen }
    func requestScreen() { log.append("requestScreen") }
    func devices(_ type: AVMediaType) -> [AVCaptureDevice] {
        // Listing the devices opens none of them and asks nothing.
        let kinds: [AVCaptureDevice.DeviceType] = type == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: kinds, mediaType: type, position: .unspecified).devices
    }
    func openDevices(_ setup: @escaping @Sendable () -> Void) { log.append("openDevices") }
    func startMovie(_ output: AVCaptureMovieFileOutput, to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        log.append("startMovie \(url.lastPathComponent)")
        running = (url, delegate)
        movieClock = MovieClock(started: ProcessInfo.processInfo.systemUptime)
    }
    func pauseMovie(_ output: AVCaptureMovieFileOutput) {
        log.append("pauseMovie")
        movieClock?.pause(at: ProcessInfo.processInfo.systemUptime)
    }
    func resumeMovie(_ output: AVCaptureMovieFileOutput) {
        log.append("resumeMovie")
        movieClock?.resume(at: ProcessInfo.processInfo.systemUptime)
    }
    func stopMovie(_ output: AVCaptureMovieFileOutput) {
        log.append("stopMovie")
        if var clock = movieClock {
            clock.stop(at: ProcessInfo.processInfo.systemUptime)
            lastMovie = clock.samples()
            movieClock = nil
        }
        guard let (url, delegate) = running else { return }
        running = nil
        if let take {
            // The take "recorded": the fixture movie where the recorder asked for it, delivered as AVFoundation does.
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: take, to: url)
                delegate.fileOutput(output, didFinishRecordingTo: url, from: [], error: nil)
                return
            } catch {
                log.append("take not copied: \(error.localizedDescription)")
            }
        }
        let error = NSError(domain: "RigCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "nothing was recorded (test rig)",
                                                                       AVErrorRecordingSuccessfullyFinishedKey: false])
        delegate.fileOutput(output, didFinishRecordingTo: url, from: [], error: error)
    }
    func shareableContent() async throws -> (displays: [CGDirectDisplayID], windows: [SCWindow]) {
        log.append("shareableContent")
        guard screen else { throw Refused("no screen") }
        return (connectedDisplays().map(\.id), [])
    }
    func connectedDisplays() -> [DisplayInfo] {
        if let displays { return displays }
        let all = DisplayInfo.connected()
        return all.filter(\.main).isEmpty ? Array(all.prefix(1)) : all.filter(\.main)
    }
    func outline(_ display: DisplayInfo) { log.append("outline \(display.id)") }
    func screenSession(folder: URL, layout: LayoutSpec, systemAudio: Bool, cursorInVideo: Bool) -> ScreenRecording {
        log.append("screenSession \(folder.lastPathComponent)")
        let s = RigScreenSession(folder: folder, layout: layout, camera: take, cursorInVideo: cursorInVideo)
        sessions.append(s)
        return s
    }
    func listen(locale: Locale, contextualStrings: [String], emit: @escaping @Sendable (SpeechHypothesis) -> Void) async throws -> LiveSpeechSession {
        log.append("listen \(locale.identifier)")
        throw Refused("no speech recognition")
    }

    private var running: (URL, AVCaptureFileOutputRecordingDelegate)?
    private var movieClock: MovieClock?
    /// The samples the last movie take wrote, as AVCaptureMovieFileOutput writes them (#19).
    private(set) var lastMovie: MovieSamples?

    /// The stand-in's camera and microphone: a frame every 1/30 s and a sound buffer every 1024/48000 s on the host
    /// clock from Record to Stop. Like AVCaptureFileOutput, a paused take writes none of them, and what comes after a
    /// pause is stamped right after what came before it (no gap in the file's timestamps).
    struct MovieClock {
        let started: Double
        private(set) var pauses: [(start: Double, end: Double)] = []
        private var pausedAt: Double?
        private var stopped: Double?

        init(started: Double) { self.started = started }

        mutating func pause(at t: Double) { if pausedAt == nil, stopped == nil { pausedAt = t } }
        mutating func resume(at t: Double) {
            guard let p = pausedAt else { return }
            pauses.append((p, t))
            pausedAt = nil
        }
        mutating func stop(at t: Double) {
            resume(at: t)
            stopped = t
        }

        /// Each stream's sample times in the file: the device's samples outside the pauses, each stamped right after the
        /// one written before it.
        func samples() -> MovieSamples {
            let end = stopped ?? started
            func stream(_ step: Double) -> [Double] {
                let kept = stride(from: started, to: end, by: step).filter { t in !pauses.contains { t >= $0.start && t < $0.end } }.count
                return (0..<kept).map { Double($0) * step }
            }
            return MovieSamples(video: stream(1.0 / 30), audio: stream(1024.0 / 48000), pauses: pauses.count,
                                paused: pauses.reduce(0) { $0 + $1.end - $1.start })
        }
    }

    struct MovieSamples {
        let video: [Double]
        let audio: [Double]
        let pauses: Int
        let paused: Double
        /// The file's length: its last frame's end.
        var duration: Double { (video.last ?? 0) + 1.0 / 30 }
    }
}

/// A screen take in the rig: no stream, no capture. Stop writes a synthetic session into the recorder's folder
/// (recording.synthesize: screen, and camera and microphone from `camera` when the recorder named a camera), with the
/// layout the recorder chose (the last one set before the take), and returns its session.json as a real take does.
final class RigScreenSession: ScreenRecording, @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var layout: LayoutSpec
    private let camera: URL?
    private let cursorInVideo: Bool
    private var _calls: [String] = []
    var cameraName: String?
    var micName: String?
    var onPreviewFrame: ((IOSurface) -> Void)?
    var onStreamError: ((String) -> Void)?
    /// Seconds of synthetic screen recording a take writes.
    static let seconds = 4.0

    init(folder: URL, layout: LayoutSpec, camera: URL?, cursorInVideo: Bool) {
        self.folder = folder
        self.layout = layout
        self.camera = camera
        self.cursorInVideo = cursorInVideo
    }

    /// What the recorder asked of the session, in order.
    var calls: [String] { lock.withLock { _calls } }
    private func note(_ s: String) { lock.withLock { _calls.append(s) } }

    func start(target: ScreenTarget) async throws { note("start") }
    func stopStream() async { note("stopStream") }
    func beginRecording() { note("beginRecording") }
    func pause() { note("pause") }
    func resume() { note("resume") }
    func click(kind: String, at p: CGPoint, host: Double) {}
    func mouseUp(at p: CGPoint, host: Double) {}
    func key(_ text: String, host: Double) {}
    func cursorMoved(to p: CGPoint, kind: CursorKind, down: Bool, host: Double) {}
    func setLayout(_ spec: LayoutSpec) { lock.withLock { layout = spec } }
    func capture(_ buffer: CMSampleBuffer, camera: Bool, clock: CMClock?) {}

    func finish() async throws -> URL {
        note("finish")
        let withCamera = cameraName != nil && camera != nil
        var params: [String: JSONValue] = ["directory": .string(folder.path), "duration": .number(Self.seconds), "screenSize": [1920, 1080],
                                           "fps": 30, "cursor": .bool(cursorInVideo)]
        if withCamera, let camera {
            params["camera"] = .string(camera.path)
            params["cameraIn"] = 0.5
            params["sources"] = ["screen", "camera", "mic"]
        } else {
            params["sources"] = ["screen"]
        }
        let services = await MainActor.run { RigServices.make(in: rigTempDir("screen-take")) }
        let request = JSONValue.object(params)
        try await Task.detached { _ = try Engine(services: services).execute("recording.synthesize", params: request) }.value
        let file = folder.appendingPathComponent(RecordingSession.fileName)
        var session = try RecordingSession.load(file)
        session.layout = lock.withLock { layout }
        try session.write(to: file)
        return file
    }
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
        let tmp = TemporaryFolder.url.resolvingSymlinksInPath().path
        return [tmp, "/private" + tmp, TemporaryFolder.url.path, RigOutside.repository.path].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
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

    /// What a recorded line keeps (#60): the executable whole, then the first `keptArguments` arguments, each cut after
    /// `argumentLimit` characters (200: a scratch folder inside a test run's own temporary folder, #138, is about 120).
    static let keptArguments = 4
    static let argumentLimit = 200

    /// The line `check` records for a start.
    static func line(_ executable: String, _ arguments: [String]) -> String {
        ([executable] + arguments.prefix(keptArguments).map { $0.count > argumentLimit ? String($0.prefix(argumentLimit)) + "…" : $0 }).joined(separator: " ")
    }

    /// Called by RigGuard for each start: records it and says whether it may run.
    static func check(_ executable: String, _ arguments: [String]) -> String? {
        let line = line(executable, arguments)
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
        let url = TemporaryFolder.url.appendingPathComponent("regista-tests-trash-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
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
        let t = TemporaryFolder.url
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
/// runs them on his Mac): his app autosaves projects and writes brand kits there, and an agent of his can drive Regista
/// with the app closed (an MCP server that edits and exports). With his Regista at work, a difference is reported as a
/// known issue naming the paths, never a failure; with nothing of his at work, it fails.
enum OwnerSideVerdict: Equatable {
    case same
    case failure([String])
    case ownersAppMayHaveWritten([String])

    static func decide(changes: [String], ownerAtWork: Bool) -> OwnerSideVerdict {
        if changes.isEmpty { return .same }
        return ownerAtWork ? .ownersAppMayHaveWritten(changes) : .failure(changes)
    }

    /// A process named Regista whose executable is inside an app bundle (the test process is not one).
    @MainActor static var ownersAppRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.executableURL?.lastPathComponent == "Regista" && app.bundleURL?.pathExtension == "app"
        }
    }
}

/// The other Regista processes on this Mac that this test process did not start: the app, and the MCP servers and
/// engines of other sessions. A server left open by a session is idle and uses no CPU time; one that used some during
/// the audits, or that started or ended during them, was working or may have been, and what changed on the owner's
/// side may be its work. (Seen: the owner's app opened, driven by an agent to an export and closed while the push
/// hook ran; the server that passed the commands on used almost no CPU time itself.)
enum OtherRegista {
    static let names: Set<String> = ["Regista", "regista-mcp", "regista-engine"]

    /// Each such process with the CPU time it has used so far, in seconds.
    static func cpu() -> [pid_t: Double] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let me = getpid()
        var out: [pid_t: Double] = [:]
        for pid in pids.prefix(max(0, count)) where pid > 0 && pid != me {
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { continue }
            guard names.contains(URL(fileURLWithPath: String(cString: path)).lastPathComponent) else { continue }
            var bsd = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size) == size, pid_t(bsd.pbi_ppid) == me { continue }
            var usage = rusage_info_v2()
            let read = withUnsafeMutablePointer(to: &usage) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard read == 0 else { continue }
            // The times are in the Mac's own clock units.
            out[pid] = Double(usage.ri_user_time + usage.ri_system_time) * Double(timebase.numer) / Double(timebase.denom) / 1e9
        }
        return out
    }

    /// The processes that worked, or may have, between two readings: started or ended in between (what one that ended
    /// did before it left cannot be read: the owner's app opened, used and closed during the audits), or with CPU time
    /// used.
    static func worked(before: [pid_t: Double], after: [pid_t: Double], idle: Double = 0.05) -> [String] {
        Set(before.keys).union(after.keys).sorted().compactMap { pid in
            guard let was = before[pid] else { return "process \(pid) started" }
            guard let now = after[pid] else { return "process \(pid) ended" }
            return now - was > idle ? "process \(pid) used \(String(format: "%.2f", now - was)) s of CPU" : nil
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
        let othersBefore = OtherRegista.cpu()
        let appBefore = await OwnerSideVerdict.ownersAppRunning
        let refused = RigProcesses.refused.count, writes = RigPasteboard.generalWrites.count
        try await function()
        let outsideAfter = await MainActor.run { RigScratch.outside() }
        #expect(outsideAfter.isEmpty, "rig seams outside the scratch root: \(outsideAfter)")
        #expect(RigProcesses.refused.count == refused, "processes refused during the click audits: \(RigProcesses.refused.dropFirst(refused))")
        #expect(RigPasteboard.generalWrites.count == writes, "writes to the general pasteboard: \(RigPasteboard.generalWrites.dropFirst(writes))")
        let after = OwnerSide.listing()
        let changes = Set(before).symmetricDifference(after).sorted()
        let others = OtherRegista.worked(before: othersBefore, after: OtherRegista.cpu())
        let appRunning = await OwnerSideVerdict.ownersAppRunning || appBefore
        switch OwnerSideVerdict.decide(changes: changes, ownerAtWork: appRunning || !others.isEmpty) {
        case .same: break
        case .failure(let paths):
            Issue.record("the owner's side changed during the click audits (no other Regista was at work): \(paths.prefix(20))")
        case .ownersAppMayHaveWritten(let paths):
            withKnownIssue("another Regista was at work (the app running: \(appRunning); \(others.prefix(6))): these may be its own writes", isIntermittent: true) {
                Issue.record("the owner's side changed during the click audits: \(paths.prefix(20))")
            }
        }
        FileHandle.standardError.write(Data("RigGuard: \(othersBefore.count) other Regista processes on this Mac before the audits; at work during them: \(others)\n".utf8))
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
