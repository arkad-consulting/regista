import Foundation
import RegistaCore
import Testing
@testable import Regista

// V1 (#61) and V2 (#62): the voice screens' logic — which panel state and which flow step for which voice.list /
// voice.enroll.status, the job model, the composer's calls — and an end-to-end enrolment with a synthetic voice, in a
// temporary folder, through exactly the calls the UI makes.

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

@Test func setupStepIsComputedFromTheEnrolmentStatus() {
    func step(_ l: JSONValue?, profile: String? = "Ada", language: String? = "fr", consentRead: Bool = false, pending: String? = nil,
              check: Bool = false) -> VoiceSetupStep {
        let s = VoiceSnapshot(list: list(profile: profile), status: profile == nil ? nil : status(l.map { [$0] } ?? []))
        return VoiceSetupStep.compute(snapshot: s, language: language, consentRead: consentRead, pendingTone: pending, hasCheck: check)
    }
    #expect(step(nil, profile: nil) == .profile)
    #expect(step(nil, language: nil) == .language)
    #expect(step(nil) == .consent)                                         // nothing recorded in this language
    #expect(step(nil, consentRead: true) == .record)
    #expect(step(enrolled("fr", consent: true, zeroShot: false, seconds: 20)) == .record)   // the neutral reference is missing
    #expect(step(enrolled("fr", consent: true, zeroShot: true, seconds: 600)) == .overview)
    #expect(step(enrolled("fr", consent: true, zeroShot: true), pending: "serious") == .record)
    #expect(step(enrolled("fr", consent: true, zeroShot: true), check: true) == .check)
    #expect(step(enrolled("fr", consent: true, zeroShot: true, training: "running")) == .training)
    // Reopening picks the language in training, else the first one recorded.
    let s = VoiceSnapshot(list: list(), status: status([enrolled("it", consent: true, zeroShot: true), enrolled("fr", consent: true, zeroShot: true, training: "running")]))
    #expect(VoiceSetupStep.resumeLanguage(s) == "fr")
    #expect(VoiceSetupStep.resumeLanguage(VoiceSnapshot(list: list(), status: status([]))) == nil)
}

@Test func trainingIsGatedByRamThenByMaterial() {
    let l = enrolled("fr", consent: true, zeroShot: true, seconds: 600)
    let medium = VoiceSnapshot(list: list(tier: "medium"), status: status([l], trainer: false, reason: "tier"))
    let why = VoiceTraining.blockReason(medium, language: medium.languages[0])
    #expect(why?.contains("32 GB") == true && why?.contains("Medio") == true)
    let pro = VoiceSnapshot(list: list(tier: "pro"), status: status([l]))
    #expect(VoiceTraining.blockReason(pro, language: pro.languages[0]) == nil)
    let thin = VoiceSnapshot(list: list(tier: "pro"), status: status([enrolled("fr", consent: true, zeroShot: true, seconds: 30)]))
    #expect(VoiceTraining.blockReason(thin, language: thin.languages[0])?.contains("60") == true)   // 90 − 30 s still missing
    let installed = VoiceSnapshot(list: list(tier: "pro"), status: status([l], trainer: false, reason: "trainer"))
    #expect(VoiceTraining.blockReason(installed, language: installed.languages[0])?.contains("non è installato") == true)
}

@Test func composerBuildsTheCommandsCalls() {
    let say = VoiceCalls.say("Un.\n\nDeux.", language: "fr", tone: "serious", placement: .playhead, playhead: 12.5)
    #expect(say.id == "voice.say")
    #expect(say.params == ["text": "Un.\n\nDeux.", "language": "fr", "tone": "serious", "at": 12.5])
    let after = VoiceCalls.say("Un.", language: "fr", tone: "neutral", placement: .afterVoice, playhead: 3)
    #expect(after.params == ["text": "Un.", "language": "fr"])            // voice.say's default: after the last voice clip
    #expect(VoiceCalls.preview("Un.\n\nDeux.", language: "it", tone: "neutral", paragraph: 1).params == ["text": "Un.\n\nDeux.", "language": "it", "paragraph": 1])

    let text = "Premier paragraphe ici.\n\nDeuxième, plus loin."
    let inSecond = text.range(of: "plus")!
    #expect(VoiceCalls.listenText(text, selection: inSecond.lowerBound..<inSecond.lowerBound) == "Deuxième, plus loin.")
    #expect(VoiceCalls.listenText(text, selection: inSecond) == "plus")
    #expect(VoiceCalls.listenText(text, selection: nil) == "Premier paragraphe ici.")
    #expect(VoiceCalls.listenText("", selection: nil) == nil)
}

@MainActor
@Test func jobsReportProgressCancelForRealAndFailReadably() async throws {
    let center = JobCenter()
    // Progress, then done (when the test says so: fixed pauses failed on a busy Mac, #80).
    let finish = JobGate()
    let ok = center.start(kind: "voice", title: "ok") { h in
        h.update(progress: 0.5, detail: "metà")
        while !finish.open { try await Task.sleep(for: .milliseconds(10)) }
    }
    #expect(center.job(ok)?.isRunning == true)
    await waitFor { center.job(ok)?.progress == 0.5 }
    #expect(center.job(ok)?.progress == 0.5 && center.job(ok)?.detail == "metà")
    finish.open = true
    await waitFor { center.job(ok)?.state == .done }
    #expect(center.job(ok)?.state == .done && center.job(ok)?.progress == 1)

    // Cancel: the hook runs (it stops the process), the job ends cancelled and a late result is ignored.
    var stopped = false
    let long = center.start(kind: "voice", title: "long", onCancel: { stopped = true }) { _ in
        try await Task.sleep(for: .seconds(30))
    }
    #expect(center.latest("voice")?.id == long)                         // one finished job per kind is replaced
    center.cancel(long)
    #expect(stopped && center.job(long)?.state == .cancelled)

    // An error: the command's message without its id.
    let bad = center.start(kind: "voice-take", title: "bad") { _ in throw CommandError(.invalidParams, "voice.enroll.add: the first recording must start with the consent sentence") }
    await waitFor { center.job(bad)?.isRunning == false }
    #expect(center.job(bad)?.state == .failed("the first recording must start with the consent sentence"))
    center.dismiss(bad)
    #expect(center.job(bad) == nil)
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
    #expect(VoiceSetupStep.compute(snapshot: snap, language: nil, consentRead: false, pendingTone: nil, hasCheck: false) == .language)
    #expect(VoiceSetupStep.compute(snapshot: snap, language: "fr", consentRead: false, pendingTone: nil, hasCheck: false) == .consent)
    #expect(VoiceSetupStep.compute(snapshot: snap, language: "fr", consentRead: true, pendingTone: nil, hasCheck: false) == .record)

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
    #expect(VoiceSetupStep.compute(snapshot: snap, language: "fr", consentRead: false, pendingTone: nil, hasCheck: false) == .overview)
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
