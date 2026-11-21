import AppKit
import Combine
import RegistaCore
import RegistaEngines
import SwiftUI
import Testing
@testable import Regista

// The whole editor window under a MouseRig (#29): a store of its own (scratch defaults, a socket nobody listens to,
// the test process's scratch brand-kit folder), a project with real synthetic media, and EditorRoot hosted with the
// environment the app gives it. Clicks change the store's navigation, selection and project as in the app. Nothing a
// click does reaches outside the test (#35, RigIsolation.swift): the store's services (every tab's), the recorder's
// hardware, the pasteboard and everything outside Regista's folder are the rig's stand-ins.

/// Scratch folders of this test file.
func rigTempDir(_ tag: String = "rig") -> URL {
    let url = TemporaryFolder.url.appendingPathComponent("regista-\(tag)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The test process's user brand-kit folder (the one RegistaCoreTests and RegistaEnginesTests set): a click on a kit
/// editor never writes the kits of the person running the suite.
let rigKitsDirectory: URL = {
    let url = TemporaryFolder.url.appendingPathComponent("regista-tests-kits-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    setenv("REGISTA_BRANDKITS", url.path, 1)
    return url
}()

/// The test process's Regista folder (projects, recordings, exports): a project a click or a finished recording saves
/// never lands in the folder of the person running the suite (#39).
let rigFolder: URL = {
    let url = TemporaryFolder.url.appendingPathComponent("regista-tests-folder-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    setenv("REGISTA_FOLDER", url.path, 1)
    return url
}()

/// Rebuilds the hosted tree from scratch (every view's local state) when its token changes.
@MainActor
final class RigReset: ObservableObject {
    @Published var token = 0
    func bump() { token += 1 }
}

private struct Resettable<Content: View>: View {
    @ObservedObject var reset: RigReset
    let content: Content
    var body: some View { content.id(reset.token) }
}

// MARK: - The project

/// The words the fake transcription hears: two lines, a pause between.
private let fixtureLines: [(text: String, start: Double)] = [("Oggi Regista monta il reel.", 0.4), ("Le pause spariscono da sole.", 3.0)]
private let wordLength = 0.26, wordGap = 0.04, takeLength = 6.0

private func fixtureWords() -> [RegistaCore.Word] {
    fixtureLines.flatMap { r in
        r.text.split(separator: " ").enumerated().map { i, w in
            let t = r.start + Double(i) * (wordLength + wordGap)
            return RegistaCore.Word(text: String(w), start: MediaTime(seconds: t), end: MediaTime(seconds: t + wordLength))
        }
    }
}

struct FixtureTranscriber: RegistaCore.Transcriber {
    var id = WhisperCppTranscriber.engineID
    var model = "test"
    func unavailableReason() -> String? { nil }
    func transcribe(_ speech16k: URL, language: String) throws -> RegistaCore.Transcript {
        if let heard = RigHearing.words { return RegistaCore.Transcript(engine: id, model: model, language: language, words: heard) }
        return RegistaCore.Transcript(engine: id, model: model, language: "it", words: fixtureWords())
    }
}

/// What the rig's transcription hears in the next takes instead of the fixture's two lines (a guided reading of the
/// voice: the consent sentence, then the text), while a test sets it; nil = the fixture's words.
enum RigHearing {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _words: [RegistaCore.Word]?
    static var words: [RegistaCore.Word]? {
        get { lock.withLock { _words } }
        set { lock.withLock { _words = newValue } }
    }

    /// `sentences` read one after the other from 1 s: 0.35 s a word, 0.8 s between sentences.
    static func reading(_ sentences: [String]) -> [RegistaCore.Word] {
        var t = 1.0, out: [RegistaCore.Word] = []
        for s in sentences {
            for w in s.split(separator: " ") { out.append(RegistaCore.Word(text: String(w), start: MediaTime(seconds: t), end: MediaTime(seconds: t + 0.3))); t += 0.35 }
            t += 0.8
        }
        return out
    }
}

/// Speech-like bursts on each word, near silence elsewhere.
private func speech(rate: Int) -> [Float] {
    let ws = fixtureWords()
    return (0..<Int(takeLength * Double(rate))).map { i in
        let t = Double(i) / Double(rate)
        guard let w = ws.first(where: { t >= $0.start.seconds && t < $0.end.seconds }) else { return Float(sin(Double(i) * 0.7) * 0.0005) }
        let phase = (t - w.start.seconds) / wordLength
        return Float(0.3 * sin(.pi * phase) * sin(2 * .pi * 200 * t))
    }
}

enum RigProject {
    /// A saved project with a 6 s talking-head take on V1 (transcribed, captioned), a title, a sticker, a picture
    /// overlay, a music bed and a script: built once per test process with a stand-in transcription, copied per test.
    @MainActor static func rich() throws -> URL {
        let source = try built
        let copy = rigTempDir("project").appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: copy)
        return copy
    }

    /// The take and the picture of the project (absolute paths inside the built folder).
    static let media: Result<URL, Error> = Result {
        let dir = rigTempDir("media")
        let ffmpeg = EngineConfig.expand(EngineConfig().ffmpeg)
        let wav = dir.appendingPathComponent("speech.wav"), mov = dir.appendingPathComponent("take.mov")
        try WAVAudio(sampleRate: 48_000, channels: 1, samples: speech(rate: 48_000)).write16(to: wav)
        try Subprocess.check(URL(fileURLWithPath: ffmpeg), ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=540x960:r=30:d=\(Int(takeLength))",
                                                             "-i", wav.path, "-c:v", "h264_videotoolbox", "-b:v", "2M", "-pix_fmt", "yuv420p",
                                                             "-c:a", "aac", "-b:a", "128k", "-shortest", mov.path])
        // A music bed (a soft chord) and a picture.
        let rate = 48_000
        let bed = (0..<(4 * rate)).map { i -> Float in
            let t = Double(i) / Double(rate)
            return Float(0.1 * (sin(2 * .pi * 261.6 * t) + sin(2 * .pi * 329.6 * t)) / 2)
        }
        try WAVAudio(sampleRate: rate, channels: 1, samples: bed).write16(to: dir.appendingPathComponent("bed.wav"))
        let ctx = CGContext(data: nil, width: 600, height: 400, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
        try NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("card.png"))
        return dir
    }

    nonisolated(unsafe) private static var cached: URL?
    @MainActor private static var built: URL {
        get throws {
            if let cached { return cached }
            let media = try Self.media.get()
            var s = RigServices.make(in: rigTempDir("built-services"))
            s.tier = .base
            let e = Engine(services: s)
            let dir = rigTempDir("built")
            _ = try e.execute("project.new", params: ["name": "clicks", "directory": .string(dir.path)])
            let take = try e.execute("media.import", params: ["path": .string(media.appendingPathComponent("take.mov").path)])
            let asset = take.value(at: "asset.id")?.stringValue ?? ""
            let v1 = try e.execute("track.add", params: ["kind": "video"]).value(at: "track.id")?.stringValue ?? ""
            let picture = try e.execute("timeline.place", params: ["assetId": .string(asset), "trackId": .string(v1), "sourceIn": 0,
                                                                   "sourceOut": .number(takeLength)]).value(at: "clip.id")?.stringValue ?? ""
            // Its sound on A1, linked to the picture: what a drop from Media makes (MediaDrop.place).
            let a1 = try e.execute("track.add", params: ["kind": "audio"]).value(at: "track.id")?.stringValue ?? ""
            _ = try e.execute("timeline.place", params: ["assetId": .string(asset), "trackId": .string(a1), "start": 0, "linkTo": .string(picture)])
            _ = try e.execute("transcript.run", params: ["assetId": .string(asset), "language": "it"])
            _ = try e.execute("captions.generate", params: ["style": "talking-head-v1", "keywords": ["REGISTA"]])
            _ = try e.execute("title.add", params: ["text": "TITOLO", "start": 1, "duration": 2])
            _ = try e.execute("sticker.add", params: ["sticker": "fire", "start": 2, "duration": 2])
            _ = try e.execute("overlay.add", params: ["path": .string(media.appendingPathComponent("card.png").path), "start": 3, "duration": 2,
                                                      "fit": "contain", "scale": 0.4])
            _ = try e.execute("audio.addMusic", params: ["path": .string(media.appendingPathComponent("bed.wav").path)])
            _ = try e.execute("script.set", params: ["text": "1. Oggi Regista monta il reel.\n2. Le pause spariscono da sole."])
            let saved = try e.execute("project.save")
            let url = URL(fileURLWithPath: saved.value(at: "path")?.stringValue ?? dir.appendingPathComponent("clicks.regista").path)
            cached = url
            return url
        }
    }
}

// MARK: - The window

/// What the rig hosts: the main window (EditorRoot as a render draws it: the title row, both panels) or any view
/// with the editor's environment.
@MainActor
final class AppRig {
    let store: EditorStore
    let recorder: Recorder
    /// The recorder's hardware: what it asked (no device is opened).
    let capture: RigCapture
    let meter: LoudnessMeter
    let reset = RigReset()
    private(set) var rig: MouseRig!
    let defaults: UserDefaults
    /// The rig's own defaults suite (TestDefaults): the one `defaults` reads, ended at close.
    private let suite: UserDefaults
    /// The project opened at the start (reopened when a click closed it).
    private(set) var projectPath: URL?
    /// The recorder's ends, wired to the workbench (`followRecorder`).
    private var recorderLink: AnyCancellable?

    /// `project`: nil = no project (Inizio's world), "empty" = a new empty project, "rich" = the fixture project.
    /// `services`: changes the rig's services of every tab (a test's own engine state: a missing model…).
    init(project: String? = "rich", services adjust: (@MainActor (inout EngineServices) -> Void)? = nil) async throws {
        _ = NSApplication.shared
        _ = rigKitsDirectory
        _ = rigFolder
        _ = rigOutside
        RigGuard.install()
        // A socket nobody listens to, with a path short enough for a Unix socket.
        setenv("REGISTA_ENGINE_SOCKET", TemporaryFolder.url.appendingPathComponent("rg-\(UUID().uuidString.prefix(8)).sock").path, 1)
        suite = TestDefaults.make("rig")
        defaults = suite
        let factory = RigServices.factory()
        store = EditorStore(defaults: defaults, seedFolders: [], services: adjust.map { adjust in { var s = factory(); adjust(&s); return s } } ?? factory)
        capture = RigCapture()
        recorder = Recorder(defaults: defaults, hardware: capture)
        store.bench.recorder = recorder
        // The app gives the teleprompter its recorder at launch: "Ascolta e segui" listens through the capture stand-in.
        TeleprompterController.shared.recorder = recorder
        meter = LoudnessMeter()
        switch project {
        case "rich":
            let url = try RigProject.rich()
            projectPath = url
            RigTrace.note("AppRig.init: project.open")
            try await store.perform("project.open", ["path": .string(url.path)])
            for _ in 0..<200 where store.project?.tracks.isEmpty != false { try await Task.sleep(for: .milliseconds(50)) }
        case "empty":
            RigTrace.note("AppRig.init: project.new")
            try await store.perform("project.new", ["name": "vuoto"])
            for _ in 0..<200 where store.project == nil { try await Task.sleep(for: .milliseconds(50)) }
        default: break
        }
        // RigGuard's record only grows (suites of other files run beside this one: a test compares counts).
        RigGuard.alertAnswer = .alertSecondButtonReturn
        UserDefaults.standard.removeObject(forKey: SettingsRoute.tabKey)
        // What the app keeps in the test process's own defaults and the window tests count on, at its default (#137): an
        // earlier run (a drag, a click of the Settings audit, a run stopped in the middle) may have left another value.
        // The window's panes at their automatic sizes: a lower pane left short hid the timeline's lanes. New projects in
        // the default format, 9:16: a 16:9 one put the journeys' clicks on the picture outside it.
        for key in ["layout.pro.program", "layout.pro.lower", ShellPrefs.sideWidth] { UserDefaults.standard.set(SplitSize.automatic, forKey: key) }
        UserDefaults.standard.set(GeneralPrefs.formats[0].id, forKey: GeneralPrefs.formatKey)
    }

    /// The app launched again on `old`'s defaults and the same scratch support folder: `old`'s window closes (its defaults
    /// kept, this rig owns them now), then a workbench is built as the app's AppState builds it, with no tab of its own,
    /// and its tabs come back as at launch (`Workbench.restoreTabs`).
    init(relaunching old: AppRig, services adjust: (@MainActor (inout EngineServices) -> Void)? = nil) async throws {
        old.close(keepingDefaults: true)
        setenv("REGISTA_ENGINE_SOCKET", TemporaryFolder.url.appendingPathComponent("rg-\(UUID().uuidString.prefix(8)).sock").path, 1)
        suite = old.suite
        defaults = UserDefaults(suiteName: TestDefaults.domain(of: old.suite)!)!
        let factory = RigServices.factory()
        let bench = Workbench(defaults: defaults, seedFolders: [], services: adjust.map { adjust in { var s = factory(); adjust(&s); return s } } ?? factory)
        capture = RigCapture()
        recorder = Recorder(defaults: defaults, hardware: capture)
        bench.recorder = recorder
        TeleprompterController.shared.recorder = recorder
        meter = LoudnessMeter()
        RigTrace.note("AppRig.init(relaunching:): restoreTabs")
        bench.restoreTabs()
        store = bench.active
        RigGuard.alertAnswer = .alertSecondButtonReturn
    }

    /// The editor window at a navigation state, on the tab on screen (another tab selected rebuilds it, as in the app).
    /// `language`: the window's words in that language (MouseRig), nil for the Italian keys.
    func hostEditor(_ nav: Navigation, size: CGSize = CGSize(width: 1440, height: 900), language: String? = nil,
                    env: @escaping (AnyView) -> AnyView = { $0 }) {
        store.nav = nav
        let meter = meter, recorder = recorder
        let root = ActiveTab(bench: store.bench) { s in
            env(AnyView(EditorRoot(live: false)
                .environmentObject(s).environmentObject(s.preview).environmentObject(s.preview.playhead)
                .environmentObject(s.media).environmentObject(meter).environmentObject(recorder)))
        }
        mount(root, size: size, language: language)
    }

    /// Any view with the editor's environment.
    func host<V: View>(_ view: V, size: CGSize, language: String? = nil, env: (AnyView) -> AnyView = { $0 }) {
        mount(env(AnyView(view
            .environmentObject(store).environmentObject(store.preview).environmentObject(store.preview.playhead)
            .environmentObject(store.media).environmentObject(meter).environmentObject(recorder))), size: size, language: language)
    }

    private func mount<V: View>(_ root: V, size: CGSize, language: String? = nil) {
        RigTrace.note("AppRig.mount \(V.self)".prefix(120).description)
        rig = MouseRig(Resettable(reset: reset, content: root.environment(\.pasteboard, rigPasteboard)), size: size, language: language)
        // The editor's window, as the live window sets it (the keyboard monitor and the panels look for it).
        store.ui.window = rig.window
        rig.pump(0.3)
    }

    /// A finished take goes where the app sends it: the recorder's ends wired to the workbench as the app wires them at
    /// launch (Workbench.follow). The click audits leave them unwired (a take there writes nothing).
    func followRecorder() { recorderLink = store.bench.follow(recorder) }

    func close() { close(keepingDefaults: false) }

    /// `keepingDefaults`: the app's defaults stay for a relaunch (`init(relaunching:)`).
    func close(keepingDefaults: Bool) {
        recorderLink = nil
        recorder.onFinished = nil
        recorder.onSessionFinished = nil
        rig?.close()
        store.ui.window = nil
        if recorder.isRecording { recorder.stop() }
        if TeleprompterController.shared.recorder === recorder { TeleprompterController.shared.recorder = nil }
        if store.preview.isPlaying { store.preview.togglePlay() }
        if !keepingDefaults { TestDefaults.end(suite) }
    }

    /// Waits `seconds` with the main run loop turning inside a nested loop of ours: the store's results (blocks on the
    /// main queue) land, and a stop that some framework queues on the running loop meanwhile stops this nested one, never
    /// the test runner's loop (which would end the test process).
    func idle(_ seconds: Double) async {
        RigTrace.note("AppRig.idle(\(seconds))")
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end { RigTrace.run("idle", 0.01) }
                c.resume()
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    /// Waits until `condition` holds (at most `timeout` seconds, returning whether it did), idling between looks so the
    /// main actor runs meanwhile: a job's end, a store refresh's result. `rig.wait` pumps the run loop from inside the
    /// test's own main-actor job, where no other main-actor work can run: a condition only such work makes true never
    /// turns true during it (#127).
    @discardableResult
    func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            await idle(0.05)
        }
        return true
    }

    /// Waits for the commands started by a click to finish: a read on the engine's serial queue returns after every
    /// command queued before it, then a short wait lets their results land.
    func settle() async {
        RigTrace.note("AppRig.settle")
        rig.pump(0.03)
        rig.drain()
        await idle(0.02)
        RigTrace.note("AppRig.settle: project.state")
        _ = try? await store.silent("project.state")
        await idle(0.05)
        rig.drain()
    }

    /// The hosted window as a PNG (with REGISTA_UI_SNAPSHOTS: a look at a state a test drove with the mouse).
    func snapshot(to url: URL) throws {
        let v = rig.host
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The commands logged since `count` entries.
    func commands(since count: Int) -> [String] { store.activity.dropFirst(count).map(\.command) }

    var clips: [Clip] { store.project?.tracks.flatMap(\.clips) ?? [] }
}
