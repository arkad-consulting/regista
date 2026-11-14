import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI
import Testing
@testable import Regista

// The whole editor window under a MouseRig (#29): a store of its own (scratch defaults, a socket nobody listens to,
// the test process's scratch brand-kit folder), a project with real synthetic media, and EditorRoot hosted with the
// environment the app gives it. Clicks change the store's navigation, selection and project as in the app.

/// Scratch folders of this test file.
func rigTempDir(_ tag: String = "rig") -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-\(tag)-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The test process's user brand-kit folder (the one RegistaCoreTests and RegistaEnginesTests set): a click on a kit
/// editor never writes the kits of the person running the suite.
let rigKitsDirectory: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-tests-kits-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    setenv("REGISTA_BRANDKITS", url.path, 1)
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

private struct FixtureTranscriber: RegistaCore.Transcriber {
    var id = WhisperCppTranscriber.engineID
    var model = "test"
    func unavailableReason() -> String? { nil }
    func transcribe(_ speech16k: URL, language: String) throws -> RegistaCore.Transcript {
        RegistaCore.Transcript(engine: id, model: model, language: "it", words: fixtureWords())
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
            var s = EngineServices.live()
            s.config.cacheDirectory = rigTempDir("cache").path
            s.tier = .base
            s.transcribers = [WhisperCppTranscriber.engineID: FixtureTranscriber()]
            s.profiles = ProfileStore(directory: rigTempDir("profiles"))
            s.generationState = rigTempDir("generation")
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
    let meter: LoudnessMeter
    let reset = RigReset()
    private(set) var rig: MouseRig!
    let defaults: UserDefaults
    private let defaultsName: String
    /// The project opened at the start (reopened when a click closed it).
    private(set) var projectPath: URL?

    /// `project`: nil = no project (Inizio's world), "empty" = a new empty project, "rich" = the fixture project.
    init(project: String? = "rich") async throws {
        _ = NSApplication.shared
        _ = rigKitsDirectory
        // A socket nobody listens to, with a path short enough for a Unix socket.
        setenv("REGISTA_ENGINE_SOCKET", FileManager.default.temporaryDirectory.appendingPathComponent("rg-\(UUID().uuidString.prefix(8)).sock").path, 1)
        defaultsName = "regista-rig-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsName)!
        store = EditorStore(defaults: defaults, seedFolders: [])
        recorder = Recorder(defaults: defaults)
        meter = LoudnessMeter()
        switch project {
        case "rich":
            let url = try RigProject.rich()
            projectPath = url
            try await store.perform("project.open", ["path": .string(url.path)])
            for _ in 0..<200 where store.project?.tracks.isEmpty != false { try await Task.sleep(for: .milliseconds(50)) }
        case "empty":
            try await store.perform("project.new", ["name": "vuoto"])
            for _ in 0..<200 where store.project == nil { try await Task.sleep(for: .milliseconds(50)) }
        default: break
        }
        RigGuard.events = []
        RigGuard.alertAnswer = .alertSecondButtonReturn
        UserDefaults.standard.removeObject(forKey: SettingsRoute.tabKey)
    }

    /// The editor window at a navigation state, on the tab on screen (another tab selected rebuilds it, as in the app).
    func hostEditor(_ nav: Navigation, size: CGSize = CGSize(width: 1440, height: 900), env: @escaping (AnyView) -> AnyView = { $0 }) {
        store.nav = nav
        let meter = meter, recorder = recorder
        let root = ActiveTab(bench: store.bench) { s in
            env(AnyView(EditorRoot(live: false)
                .environmentObject(s).environmentObject(s.preview).environmentObject(s.preview.playhead)
                .environmentObject(s.media).environmentObject(meter).environmentObject(recorder)))
        }
        mount(root, size: size)
    }

    /// Any view with the editor's environment.
    func host<V: View>(_ view: V, size: CGSize, env: (AnyView) -> AnyView = { $0 }) {
        mount(env(AnyView(view
            .environmentObject(store).environmentObject(store.preview).environmentObject(store.preview.playhead)
            .environmentObject(store.media).environmentObject(meter).environmentObject(recorder))), size: size)
    }

    private func mount<V: View>(_ root: V, size: CGSize) {
        rig = MouseRig(Resettable(reset: reset, content: root), size: size)
        // The editor's window, as the live window sets it (the keyboard monitor and the panels look for it).
        store.ui.window = rig.window
        rig.pump(0.3)
    }

    func close() {
        rig?.close()
        store.ui.window = nil
        if store.preview.isPlaying { store.preview.togglePlay() }
        defaults.removePersistentDomain(forName: defaultsName)
    }

    /// Waits for the commands started by a click to finish. The store logs and publishes from blocks on the main queue,
    /// which only run while the test yields the main actor: a read on the engine's serial queue returns after every
    /// command queued before it, then a short sleep lets their results land.
    func settle() async {
        rig.pump(0.03)
        try? await Task.sleep(for: .milliseconds(20))
        _ = try? await store.silent("project.state")
        try? await Task.sleep(for: .milliseconds(40))
        rig.pump(0.03)
    }

    /// The commands logged since `count` entries.
    func commands(since count: Int) -> [String] { store.activity.dropFirst(count).map(\.command) }

    var clips: [Clip] { store.project?.tracks.flatMap(\.clips) ?? [] }
}
