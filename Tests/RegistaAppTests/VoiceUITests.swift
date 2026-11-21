import AppKit
import Foundation
import RegistaCore
import SwiftUI
import Testing
import Vision
@testable import Regista

// V1 (#61), V2 (#62) and V3: the voice screens' logic — which panel state and which window page for which voice.list /
// voice.enroll.status, where each entry point opens the "Gestisci voci" window, the rail and the tone tiles, the training
// hint, the job model, the composer's calls — renders of the window and the panel read through their accessibility
// text, and an end-to-end enrolment with a synthetic voice, in a temporary folder, through exactly the calls the UI makes.

private func list(profile: String? = "Ada", locked: Bool = false, available: Bool = true, tier: String = "pro",
                  languages: [JSONValue] = []) -> JSONValue {
    var engine: [String: JSONValue] = ["available": .bool(available), "tier": .string(tier)]
    if !available { engine["reason"] = "needs the medium tier" }
    var p: JSONValue = .null
    if let profile {
        var o: [String: JSONValue] = ["name": .string(profile), "id": .string(profile.lowercased())]
        if locked { o["locked"] = "created on another Mac" }
        p = .object(o)
    }
    return ["profile": p, "languages": .array(languages), "engine": .object(engine)]
}

private func status(_ languages: [JSONValue], trainer: Bool = true, reason: String = "tier") -> JSONValue {
    var t: [String: JSONValue] = ["available": .bool(trainer)]
    if !trainer { t["reason"] = .string(reason) }
    return ["profile": "Ada", "languages": .array(languages), "trainer": .object(t)]
}

private func enrolled(_ code: String, consent: Bool, zeroShot: Bool, seconds: Double = 0, training: String = "never trained") -> JSONValue {
    ["language": .string(code), "consent": .bool(consent), "zeroShotReady": .bool(zeroShot), "tones": [:], "seconds": .number(seconds),
     "trainMinimumSeconds": 90, "trainEstimateMinutes": 8, "training": ["state": .string(training)]]
}

@Test func panelStateFollowsEngineProfileAndVoice() {
    #expect(VoicePanelState.from(VoiceSnapshot(list: list(available: false, tier: "base"))) ==
            .engineMissing("La voce clonata richiede un Mac con almeno 16 GB di RAM (livello Medio). Questo Mac è al livello Base."))
    if case .engineMissing(let why) = VoicePanelState.from(VoiceSnapshot(list: list(available: false, tier: "medium"))) {
        #expect(why.contains("non è installato"))           // the tier is enough: the install is what is missing
    } else { Issue.record("expected engineMissing") }
    #expect(VoicePanelState.from(VoiceSnapshot(list: list(profile: nil))) == .noProfile)
    #expect(VoicePanelState.from(VoiceSnapshot(list: list(locked: true))) == .locked("Ada"))
    #expect(VoicePanelState.from(VoiceSnapshot(list: list())) == .noVoice("Ada"))
    let notReady: JSONValue = ["language": "fr", "ready": false, "mode": "zero-shot", "tones": ["neutral"]]
    #expect(VoicePanelState.from(VoiceSnapshot(list: list(languages: [notReady]))) == .noVoice("Ada"))
    let ready: JSONValue = ["language": "fr", "ready": true, "mode": "lora", "tones": ["neutral", "serious"]]
    let s = VoiceSnapshot(list: list(languages: [ready]))
    #expect(VoicePanelState.from(s) == .ready)
    #expect(s.readyLanguages.map(\.code) == ["fr"] && s.languages[0].trained && s.languages[0].tones == ["neutral", "serious"])
}

@Test func windowPageIsComputedFromTheEnrolmentStatus() {
    func page(_ l: JSONValue?, profile: String? = "Ada", language: String? = "fr", started: Bool = false, consentRead: Bool = false,
              pending: String? = nil, check: Bool = false) -> VoiceWindowPage {
        let s = VoiceSnapshot(list: list(profile: profile), status: profile == nil ? nil : status(l.map { [$0] } ?? []))
        return VoiceWindowPage.compute(snapshot: s, language: language, started: started, consentRead: consentRead, pendingTone: pending, hasCheck: check)
    }
    #expect(page(nil, profile: nil) == .profile)
    #expect(page(nil) == .intro)                                           // nothing recorded in this language: what will happen
    #expect(page(nil, started: true) == .consent)
    #expect(page(nil, started: true, consentRead: true) == .record)
    #expect(page(enrolled("fr", consent: true, zeroShot: false, seconds: 20)) == .record)   // the neutral reference is missing
    #expect(page(enrolled("fr", consent: true, zeroShot: true, seconds: 600)) == .overview)
    #expect(page(enrolled("fr", consent: true, zeroShot: true), pending: "serious") == .record)
    #expect(page(enrolled("fr", consent: true, zeroShot: true), check: true) == .check)
    #expect(page(enrolled("fr", consent: true, zeroShot: true, training: "running")) == .overview)   // the progress is on the overview
    // Opening without an entry point picks the language in training, else the first with a voice, else the first recorded.
    let s = VoiceSnapshot(list: list(), status: status([enrolled("it", consent: true, zeroShot: true), enrolled("fr", consent: true, zeroShot: true, training: "running")]))
    #expect(VoiceWindowPage.resumeLanguage(s) == "fr")
    #expect(VoiceWindowPage.resumeLanguage(VoiceSnapshot(list: list(), status: status([]))) == nil)
    #expect(VoiceWindowPage.firstWithoutVoice(s) == "en")
}

/// With a usable voice the panel is the text tool; its cloning entries (Gestisci voci…, + Lingua, + Tono, Allena…) each
/// open the window where they say — never on the profile or a step 1.
@MainActor
@Test func panelOpensOnTheTextAndEachEntryOpensTheWindowWhereItSays() {
    let m = VoiceModel(store: nil)
    m.snapshot = VoiceDemo.snapshot("hint", tier: nil)           // it and fr usable, fr untrained, a Pro Mac
    m.language = "fr"
    #expect(m.state == .ready && m.pane == .text)
    m.setup.pendingTone = "sad"; m.setup.started = true          // leftovers of an earlier visit do not decide where it opens
    m.manageVoices()
    #expect(m.setup.language == "fr" && m.windowPage == .overview && m.setup.pendingTone == nil)
    m.addLanguage()
    #expect(m.setup.language == "en" && m.windowPage == .intro)  // the first language without a voice, its intro
    m.addTone()
    #expect(m.setup.language == "fr" && m.windowPage == .overview)
    m.setup.language = "it"
    m.openTraining()
    #expect(m.setup.language == "fr" && m.windowPage == .overview)
    // The way into cloning: no profile → the window asks the name; a profile without a voice → an intro, never step 1.
    m.snapshot = VoiceDemo.snapshot("no-profile", tier: nil)
    #expect(m.state.leadsToCloning)
    m.openWindow(language: nil)
    #expect(m.windowPage == .profile)
    m.snapshot = VoiceDemo.snapshot("no-voice", tier: nil)
    m.setup.language = nil
    m.openWindow(language: nil)
    #expect(m.state.leadsToCloning && m.windowPage == .intro && VoiceLanguages.all.contains(m.windowLanguage))
}

@MainActor
@Test func trainingHintOnlyForAnUntrainedVoiceThatCanTrainUntilDismissed() {
    let defaults = TestDefaults.make("voice-hint")
    defer { TestDefaults.end(defaults) }
    let m = VoiceModel(store: nil, defaults: defaults)
    m.snapshot = VoiceDemo.snapshot("hint", tier: nil)
    m.language = "fr"
    #expect(m.showsTrainHint)
    m.language = "it"
    #expect(m.showsTrainHint)                                     // it is untrained too
    m.snapshot = VoiceDemo.snapshot("ready", tier: nil); m.language = "fr"
    #expect(!m.showsTrainHint)                                    // trained
    m.snapshot = VoiceDemo.snapshot("hint", tier: "medium")
    #expect(!m.showsTrainHint)                                    // this Mac cannot train
    m.snapshot = VoiceDemo.snapshot("training", tier: nil)
    #expect(!m.showsTrainHint)                                    // already training
    m.snapshot = VoiceDemo.snapshot("hint", tier: nil)
    m.dismissTrainHint()
    #expect(!m.showsTrainHint)
    m.language = "it"
    #expect(m.showsTrainHint)                                     // dismissed for French only
    let again = VoiceModel(store: nil, defaults: defaults)        // and it stays dismissed
    again.snapshot = VoiceDemo.snapshot("hint", tier: nil); again.language = "fr"
    #expect(!again.showsTrainHint)
}

@MainActor
@Test func railShowsTheFourLanguagesAndTilesTheSevenTones() {
    let s = VoiceDemo.snapshot("training", tier: nil)            // it: neutral · fr: three tones, training
    #expect(VoiceLanguages.all.map { VoiceRailState.of(s.language($0)).label { $0 } }
            == ["pronta · 1 tono", "allenamento in corso", "da registrare", "da registrare"])
    let o = VoiceDemo.snapshot("overview", tier: nil)
    #expect(VoiceRailState.of(o.language("fr")).label { $0 } == "pronta · 3 toni")
    #expect(VoiceRailState.of(VoiceDemo.snapshot("ready", tier: nil).language("fr")).label { $0 } == "allenata · 3 toni")
    let tiles = VoiceToneTile.tiles(o.language("fr")!)
    #expect(tiles.map(\.tone) == RecordingScript.tones)
    #expect(tiles.filter(\.recorded).map(\.tone) == ["neutral", "serious", "calm"] && tiles.first?.minutes == 9.4)
    // A voice trained outside the app, no recorded minutes: "allenata · 1 tono", Neutro checked without minutes.
    let imported = VoiceDemo.snapshot("imported", tier: nil)
    #expect(VoiceRailState.of(imported.language("fr")).label { $0 } == "allenata · 1 tono")
    let first = VoiceToneTile.tiles(imported.language("fr")!).first
    #expect(first == VoiceToneTile(tone: "neutral", recorded: true, minutes: nil))
    // The same from the commands' own replies (voice.list says lora + neutral, the status has no clips).
    let fromCommands = VoiceSnapshot(list: list(languages: [["language": "fr", "ready": true, "mode": "lora", "tones": ["neutral"]]]),
                                     status: status([["language": "fr", "consent": false, "zeroShotReady": false, "tones": [:], "seconds": 0,
                                                      "lora": "lora/step_0001000", "training": ["state": "done"]]]))
    #expect(VoiceRailState.of(fromCommands.language("fr")).label { $0 } == "allenata · 1 tono")
    #expect(VoiceToneTile.tiles(fromCommands.language("fr")!).filter(\.recorded) == [VoiceToneTile(tone: "neutral", recorded: true, minutes: nil)])
}

@MainActor
@Test func cloneTimesComeFromTheModel() {
    let nominal = VoiceCloneTimes.from(lines: [:], language: nil)
    #expect(nominal.neutralMinutes == 10 && nominal.toneMinutes == 2)
    #expect(nominal.trainMinutes == VoiceEnrollment.estimatedTrainingMinutes(seconds: 600))
    #expect(nominal.trainTier == EngineManifest.shared.minimumTier("voice-training") && nominal.trainRAM >= 32)
    let lines = ["neutral": Array(repeating: "Une ligne de six mots pour voir.", count: 50), "calm": ["Deux mots."]]
    let t = VoiceCloneTimes.from(lines: lines, language: VoiceDemo.snapshot("overview", tier: nil).language("fr"))
    #expect(t.neutralMinutes == RecordingScript.minutes(lines: lines["neutral"]!) && t.toneMinutes == RecordingScript.minutes(lines: ["Deux mots."]))
    #expect(t.trainMinutes == 107)                                // the language's own estimate (voice.enroll.status)
    #expect(VoiceFormat.rough(107) == "1 h 47 min" && VoiceFormat.rough(9.6) == "10 min")
}

// MARK: - Renders, read back with text recognition

/// The view rendered at 2× in a borderless window, then read back with Apple Vision's text recognition: the lines a
/// person would see.
@MainActor
private func readRender<V: View>(_ root: V, size: CGSize) async throws -> [String] {
    _ = NSApplication.shared
    let view = NSHostingView(rootView: root)
    view.frame = CGRect(origin: .zero, size: size)
    let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.appearance = NSAppearance(named: .darkAqua)
    w.contentView = view
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    view.layoutSubtreeIfNeeded()
    let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    rep.size = size
    view.cacheDisplay(in: view.bounds, to: rep)
    w.contentView = nil
    let image = try #require(rep.cgImage)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.recognitionLanguages = ["it-IT", "fr-FR"]
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

/// The window on a voice trained outside the app reads all four languages and all seven tones, "allenata · 1 tono", and
/// never "0 min"; the same window on a recorded voice does show its minutes (the reading sees them when they are there).
@MainActor
@Test func theWindowRendersTheImportedModelWithoutZeroMinutes() async throws {
    let defaults = TestDefaults.make("voice-render")
    defer { TestDefaults.end(defaults) }
    let recorder = Recorder(defaults: defaults)
    func read(_ state: String) async throws -> [String] {
        let m = VoiceDemo.model(state, tier: nil)
        return try await readRender(VoiceSetupView(model: m, jobs: m.demoJobs!).environmentObject(recorder), size: VoiceSetupView.size)
    }
    let recorded = try await read("overview").joined(separator: "\n")
    #expect(recorded.contains("9,4 min") || recorded.contains("9.4 min"), "\(recorded)")
    let lines = try await read("imported")
    let all = lines.joined(separator: "\n")
    #expect(VoiceLanguages.all.allSatisfy { all.contains(VoiceLanguages.name($0)) }, "\(all)")
    #expect(VoiceTones.all.allSatisfy { all.contains(loc(VoiceTones.title($0))) }, "\(all)")
    #expect(all.replacingOccurrences(of: "•", with: "·").contains(loc("allenata · 1 tono")), "\(all)")   // the reading sees · as •
    #expect(!lines.contains { $0.range(of: #"(^|[^0-9,.])0([,.]0)? ?min"#, options: .regularExpression) != nil }, "\(all)")
}

/// The panel, 300 points wide as in the window: with a usable voice it opens on the text and its only cloning entries are
/// Gestisci voci…, + Lingua, + Tono and the hint; with no voice it is the way into cloning, the four steps with their times.
@MainActor
@Test func thePanelRendersTheTextToolOrTheWayIntoCloning() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-voice-panel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    setenv("REGISTA_ENGINE_SOCKET", dir.appendingPathComponent("e.sock").path, 1)
    let defaults = TestDefaults.make("voice-panel")
    defer { TestDefaults.end(defaults) }
    let store = EditorStore(defaults: defaults, seedFolders: [])
    func read(_ state: String) async throws -> String {
        let m = VoiceDemo.model(state, tier: nil)
        return try await readRender(VoicePanel(model: m, jobs: m.demoJobs!).environmentObject(store), size: CGSize(width: 300, height: 900))
            .joined(separator: "\n").replacingOccurrences(of: "•", with: "·").replacingOccurrences(of: "...", with: "…")   // as the reading sees them
    }
    let daily = try await read("hint")
    for label in ["Gestisci voci…", "Testo", "Pronuncia", "Lingua", "Tono", "Français", "Neutro", "Serio", "Calmo",
                  "La voce non è ancora allenata", "Allena…", "Ascolta", "Metti in timeline"] {
        #expect(daily.contains(label), "\(label) in \(daily)")
    }
    #expect(!daily.contains("Clona la tua voce") && !daily.contains("Registra…") && !daily.contains("Altri toni"), "\(daily)")
    let trained = try await read("ready")
    #expect(trained.contains("Gestisci voci…") && !trained.contains("non è ancora allenata"), "\(trained)")
    let first = try await read("no-voice")
    for label in ["Clona la tua voce", "COME FUNZIONA", "Scegli la lingua", "Leggi il tono neutro", "~10 min", "Aggiungi altri toni",
                  "~2 min", loc("voice.step.train"), "~1 h 47 min", "Inizia a clonare la tua voce"] {
        #expect(first.contains(label), "\(label) in \(first)")
    }
    #expect(!first.contains("Gestisci voci…"), "\(first)")
}

// MARK: - End to end with a synthetic voice

private final class Words: @unchecked Sendable { var now: [RegistaCore.Word] = [] }

private struct SpokenTranscriber: RegistaCore.Transcriber {
    var id: String
    var model = "fake"
    let words: Words
    func unavailableReason() -> String? { nil }
    func transcribe(_ speech16k: URL, language: String) throws -> RegistaCore.Transcript {
        RegistaCore.Transcript(engine: id, model: model, language: language, words: words.now)
    }
}

private struct ToneAudio: AudioToolkit {
    func extractAudio(from source: URL, channels: Int, speech: URL, working: URL) throws {
        let n = 60 * 16000
        let s = (0..<n).map { i in Float(sin(Double(i) * 0.05) * 0.2) }
        try WAVAudio(sampleRate: 16000, channels: 1, samples: s).write16(to: speech)
        try WAVAudio(sampleRate: 48000, channels: 1, samples: s.flatMap { [$0, $0, $0] }).write16(to: working)
    }
    func loudness(of spans: [AudioSpan]) throws -> Loudness { throw CommandError(.io, "unused") }
    func mix(_ clips: [AudioMixClip], length: Int, rate: Int, gain: Double, ceiling: Double, to output: URL) throws { throw CommandError(.io, "unused") }
}

private struct NoCleaner: VoiceCleaner {
    func unavailableReason() -> String? { "unused" }
    func clean(_ request: VoiceCleanRequest) throws -> VoiceCleanReport { throw CommandError(.io, "unused") }
}

private struct WavProber: MediaProber {
    func probe(_ url: URL) throws -> ProbedMedia {
        let audio = try JSONDecoder().decode(AudioInfo.self, from: Data(#"{"sampleRate": 48000, "channels": 1, "codec": "pcm_s16le"}"#.utf8))
        return ProbedMedia(duration: MediaTime(seconds: 6), audio: audio)
    }
}

private func spoken(_ sentences: [String], start: Double = 1) -> [RegistaCore.Word] {
    var t = start, out: [RegistaCore.Word] = []
    for s in sentences {
        for w in s.split(separator: " ") { out.append(RegistaCore.Word(text: String(w), start: MediaTime(seconds: t), end: MediaTime(seconds: t + 0.3))); t += 0.35 }
        t += 0.8
    }
    return out
}

@Test func fromAnEmptyProfileToAVoiceOnTheTimelineWithTheCallsTheUIMakes() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-voice-e2e-\(UUID().uuidString)")
    let fm = FileManager.default
    defer { try? fm.removeItem(at: dir) }
    // The engine files VoxCPM needs, with a fake uv that writes a WAV per request.
    let project = dir.appendingPathComponent("voxcpm"), model = dir.appendingPathComponent("VoxCPM2")
    try fm.createDirectory(at: project.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try fm.createDirectory(at: model, withIntermediateDirectories: true)
    fm.createFile(atPath: model.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
    fm.createFile(atPath: project.appendingPathComponent("pyproject.toml").path, contents: Data())
    fm.createFile(atPath: project.appendingPathComponent("vox_say.py").path, contents: Data())
    let lines = ["Le site est en ligne depuis ce matin.", "Votre téléphone affiche la page en une seconde.",
                 "On regarde ensemble les réglages de la newsletter.", "Chaque article apparaît tout de suite dans le menu."]
    let script = "# Voice recording script — French\n\nconsent: Je m'appelle {name}, et j'accepte que Regista apprenne ma voix pour en faire un clone.\n\n"
        + RecordingScript.tones.map { "## \($0)\n" + lines.map { "- \($0)" }.joined(separator: "\n") }.joined(separator: "\n") + "\n"
    try script.write(to: project.appendingPathComponent("scripts/fr.md"), atomically: true, encoding: .utf8)
    let uv = dir.appendingPathComponent("uv")
    try """
    #!/bin/sh
    for last; do :; done
    /usr/bin/python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); o=r["items"][0]["out"]; open(o,"wb").write(b"RIFF"); print(json.dumps({"files":[o],"seconds":[1.0],"wall_seconds":2.0}))' "$last"
    """.write(to: uv, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)

    var config = EngineConfig()
    config.uv = uv.path
    config.voxcpmProject = project.path
    config.voxcpmScript = project.appendingPathComponent("vox_say.py").path
    config.voxcpmModel = model.path
    config.cacheDirectory = dir.appendingPathComponent("cache").path
    let words = Words()
    let profiles = ProfileStore(directory: dir.appendingPathComponent("profiles"), machine: "this-mac")
    var services = EngineServices(config: config, tier: .medium, audio: ToneAudio(),
                                  transcribers: [SpokenTranscriber(id: WhisperCppTranscriber.engineID, words: words),
                                                 SpokenTranscriber(id: WhisperXTranscriber.engineID, words: words)],
                                  cleaner: NoCleaner(), faces: nil)
    services.profiles = profiles
    services.generators = ["voxcpm": VoxCPMProvider(config: config, profiles: profiles)]
    services.cancellation = GenerationCancellation()
    let e = Engine(prober: WavProber(), services: services)
    func run(_ c: VoiceCall) throws -> JSONValue { try e.execute(c.id, params: c.params) }
    func snapshot() throws -> VoiceSnapshot {
        let l = try run(VoiceCalls.list)
        let s = l["profile"]?.objectValue == nil ? nil : try run(VoiceCalls.status)
        return VoiceSnapshot(list: l, status: s)
    }

    // An empty Regista: no profile → create it in the panel.
    #expect(VoicePanelState.from(try snapshot()) == .noProfile)
    _ = try run(VoiceCalls.createProfile("Lucia"))
    var snap = try snapshot()
    #expect(VoicePanelState.from(snap) == .noVoice("Lucia"))
    // Inizia a clonare la tua voce → the window on a language's intro (the rail picks French), Inizia, Ho capito, registra.
    #expect(VoiceWindowPage.compute(snapshot: snap, language: "fr", started: false, consentRead: false, pendingTone: nil, hasCheck: false) == .intro)
    #expect(VoiceWindowPage.compute(snapshot: snap, language: "fr", started: true, consentRead: false, pendingTone: nil, hasCheck: false) == .consent)
    #expect(VoiceWindowPage.compute(snapshot: snap, language: "fr", started: true, consentRead: true, pendingTone: nil, hasCheck: false) == .record)

    // The record step's text, then a take of the neutral block that opens with the consent sentence.
    let s = try run(VoiceCalls.script("fr"))
    let consent = try #require(s["consent"]?.stringValue)
    let block = s["blocks"]?.arrayValue?.first { $0["tone"] == "neutral" }
    let neutral = (block?["lines"]?.arrayValue ?? []).compactMap(\.stringValue)
    #expect(neutral == lines)
    words.now = spoken([consent] + neutral)
    let take = dir.appendingPathComponent("take.m4a")
    fm.createFile(atPath: take.path, contents: Data("take".utf8))
    let check = VoiceTakeCheck(tone: "neutral", result: try run(VoiceCalls.addTake(take.path, language: "fr", tone: "neutral")))
    #expect(check.good && check.consent && check.reference && check.accepted == lines.count)

    snap = try snapshot()
    #expect(VoicePanelState.from(snap) == .ready)
    #expect(VoiceWindowPage.compute(snapshot: snap, language: "fr", started: false, consentRead: false, pendingTone: nil, hasCheck: false) == .overview)
    #expect(VoiceRailState.of(snap.language("fr")) == .ready(tones: 1))
    #expect(snap.language("fr")?.consent == true && (snap.language("fr")?.seconds ?? 0) > 0)
    // Training: gated by the RAM tier on this (medium) Mac, with the reason; the command refuses too.
    #expect(VoiceTraining.blockReason(snap, language: snap.language("fr")!)?.contains("32 GB") == true)
    #expect(throws: CommandError.self) { try run(VoiceCalls.train("fr")) }

    // The composer: Ascolta renders without touching the edit, Metti in timeline places the clips with word timings.
    let newProject: JSONValue = ["name": "vo", "directory": .string(dir.appendingPathComponent("projects").path)]
    _ = try e.execute("project.new", params: newProject)
    let text = "Bonjour, ici Lucia.\n\nDeuxième paragraphe."
    words.now = spoken(["Bonjour, ici Lucia."], start: 0.2)
    let heard = try run(VoiceCalls.preview(text, language: "fr", tone: "neutral", paragraph: 0))
    #expect(heard.value(at: "paragraphs")?.arrayValue?.first?["file"]?.stringValue != nil)
    #expect(e.project?.assets.isEmpty == true)
    let placed = try run(VoiceCalls.say(text, language: "fr", tone: "neutral", placement: .afterVoice, playhead: 0))
    let tid = try #require(placed["trackId"]?.stringValue)
    let track = try #require(e.project?.tracks.first { $0.id == tid })
    #expect(track.name == "Voce" && track.clips.count == 2)
    let timed = try #require(e.project?.asset(track.clips[0].assetID)?.analysis?.transcript?.words)
    #expect(timed.map(\.text) == ["Bonjour,", "ici", "Lucia."])
    #expect(timed[0].start.seconds == 0.2)
    _ = try run(VoiceCalls.captions(trackId: tid))
    #expect(e.project?.tracks.contains { $0.kind == .caption && $0.captions != nil } == true)
}

/// Waits until `done` holds, letting the main actor run (polling, up to 20 s).
@MainActor
private func waitFor(_ done: () -> Bool) async {
    for _ in 0..<2000 where !done() { try? await Task.sleep(for: .milliseconds(10)) }
}

private final class JobGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var open: Bool {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
