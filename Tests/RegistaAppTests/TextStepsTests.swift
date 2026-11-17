import AppKit
import Foundation
import RegistaCore
import Testing
@testable import Regista

// E2 (#54): the steps from an imported clip to captions, by hand — the state machine (enabled / blocked with the reason
// and the missing step / out of date after an edit), the commands behind each button, the jobs (progress, a real
// Cancel, a readable error), "Fai tutto" in order and stoppable, and a headless scenario from a synthetic clip to
// captions through exactly the calls the buttons make.

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-steps-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A 6 s clip with picture and sound (its wav files: sound only).
private struct ClipProber: MediaProber {
    func probe(_ url: URL) throws -> ProbedMedia {
        let audio = try JSONDecoder().decode(AudioInfo.self, from: Data(#"{"sampleRate": 48000, "channels": 1, "codec": "pcm_s16le"}"#.utf8))
        if url.pathExtension == "wav" { return ProbedMedia(duration: MediaTime(seconds: 6), audio: audio) }
        let video = try JSONDecoder().decode(VideoInfo.self, from: Data(#"{"width": 1080, "height": 1920, "frameRate": {"num": 30, "den": 1}, "codec": "h264", "rotation": 0}"#.utf8))
        return ProbedMedia(duration: MediaTime(seconds: 6), video: video, audio: audio)
    }
}

/// Speech bursts where the words are, near silence elsewhere: the envelope, the takes and the sync check work on it.
private struct SpeechAudio: AudioToolkit {
    static let bursts: [(Double, Double)] = [(0.5, 2.3), (3.0, 4.6)]
    static func samples(rate: Int) -> [Float] {
        (0..<(6 * rate)).map { i in
            let t = Double(i) / Double(rate)
            let loud = bursts.contains { t >= $0.0 && t < $0.1 }
            return Float(sin(Double(i) * 0.3) * (loud ? 0.3 : 0.001))
        }
    }
    func extractAudio(from source: URL, channels: Int, speech: URL, working: URL) throws {
        try WAVAudio(sampleRate: 16000, channels: 1, samples: Self.samples(rate: 16000)).write16(to: speech)
        try WAVAudio(sampleRate: 48000, channels: 1, samples: Self.samples(rate: 48000)).write16(to: working)
    }
    func loudness(of spans: [AudioSpan]) throws -> Loudness { Loudness(integrated: -15, truePeak: -2, range: 3, threshold: -25) }
    func mix(_ clips: [AudioMixClip], length: Int, rate: Int, gain: Double, ceiling: Double, to output: URL) throws {}
}

/// Two sentences, read once each, inside the bursts.
private struct SpeechTranscriber: RegistaCore.Transcriber {
    var id = WhisperCppTranscriber.engineID
    var model = "fake"
    func unavailableReason() -> String? { nil }
    func transcribe(_ speech16k: URL, language: String) throws -> RegistaCore.Transcript {
        let text = "Oggi Regista monta il reel. Le pause spariscono da sole."
        var t = 0.6, words: [RegistaCore.Word] = []
        for (i, w) in text.split(separator: " ").enumerated() {
            if i == 5 { t = 3.1 }
            words.append(RegistaCore.Word(text: String(w), start: MediaTime(seconds: t), end: MediaTime(seconds: t + 0.28)))
            t += 0.33
        }
        return RegistaCore.Transcript(engine: id, model: model, language: language == "auto" ? "it" : language, words: words)
    }
}

/// Copies the working wav as dual-mono stereo (in sync by construction).
private struct CopyCleaner: VoiceCleaner {
    func unavailableReason() -> String? { nil }
    func clean(_ r: VoiceCleanRequest) throws -> VoiceCleanReport {
        let input = try WAVAudio.read(r.input)
        try WAVAudio(sampleRate: input.sampleRate, channels: 2, samples: input.samples.flatMap { [$0, $0] }).write16(to: r.output)
        return VoiceCleanReport(rangeGains: r.ranges.map { _ in 0 }, measured: Loudness(integrated: -20, truePeak: -6, range: 3, threshold: -30),
                                gain: 5, mode: "linear", denoiseSeconds: 0)
    }
}

/// A headless engine on those fakes with a new project, the synthetic clip imported and placed (picture on V1, sound
/// on A1, linked) — what Importa does.
private func importedClip() throws -> Engine {
    var config = EngineConfig()
    config.cacheDirectory = tempDir().path
    let services = EngineServices(config: config, tier: .base, audio: SpeechAudio(), transcribers: [SpeechTranscriber()],
                                  cleaner: CopyCleaner(), faces: nil)
    let e = Engine(prober: ClipProber(), services: services)
    try e.execute("project.new", params: ["name": "steps", "directory": .string(tempDir().path)])
    let clip = tempDir().appendingPathComponent("clip.mov")
    FileManager.default.createFile(atPath: clip.path, contents: Data())
    try e.execute("media.import", params: ["path": .string(clip.path)])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "linkTo": "c1"])
    return e
}

private func run(_ e: Engine, _ c: StepCall) throws { _ = try e.execute(c.id, params: c.params) }
private func states(_ e: Engine) -> TextSteps { TextSteps.compute(e.project, lookup: { $0 }) }
private let settings = StepSettings(language: "it")

/// Every blocked step says why and offers a way on (the missing step or Importa), except a mixed audio track.
private func everyBlockedStepSaysWhy(_ s: TextSteps, sourceLocation: SourceLocation = #_sourceLocation) {
    for step in TextStep.allCases where s[step].status == .blocked {
        #expect(!s[step].line.isEmpty && (s[step].needs != nil || s[step].needsImport), "\(step) is blocked without a way on", sourceLocation: sourceLocation)
    }
}

@Test func stepsAreBlockedWithTheReasonUntilTheyCanRun() throws {
    let none = TextSteps.compute(nil, lookup: { $0 })
    #expect(TextStep.allCases.allSatisfy { none[$0].status == .blocked && none[$0].needsImport })

    let e = try importedClip()
    var s = states(e)
    #expect(s[.transcribe].status == .todo && s[.transcribe].canRun)
    #expect(s[.script].status == .todo)
    #expect(s[.takes].status == .blocked && s[.takes].needs == .transcribe)
    #expect(s[.cut].needs == .transcribe && s[.captions].needs == .transcribe)
    #expect(s[.clean].status == .todo)                 // the clip is on the timeline: its voice can be cleaned
    #expect(s.next == .transcribe)
    everyBlockedStepSaysWhy(s)

    for c in StepCalls.plan(.transcribe, project: e.project!, settings: settings, keywords: []) { try run(e, c) }
    s = states(e)
    #expect(s[.transcribe].status == .done && s[.transcribe].line == "10 parole · Italiano")
    #expect(s[.takes].status == .todo && s[.takes].line.contains("dal parlato"))
    #expect(s[.cut].status == .blocked && s[.cut].needs == .takes)
    #expect(s[.captions].status == .todo)              // words on the timeline already
    everyBlockedStepSaysWhy(s)

    for c in StepCalls.plan(.takes, project: e.project!, settings: settings, keywords: []) { try run(e, c) }
    s = states(e)
    #expect(s[.script].status == .done && s[.takes].status == .done)
    #expect(s[.cut].status == .todo)                   // the whole clip as imported: nothing cut yet

    try run(e, StepCalls.cut(minPause: 0.7, breath: 0.12))
    s = states(e)
    guard case .done = s[.cut].status else { Issue.record("cut not done: \(s[.cut])"); return }
    try run(e, StepCalls.clean)
    try run(e, StepCalls.captions(style: "talking-head-v1", keywords: ["REGISTA"]))
    s = states(e)
    #expect([TextStep.transcribe, .script, .takes, .cut, .clean, .captions].allSatisfy { s[$0].status == .done })
    #expect(s.next == nil)

    // Another pick, then a new cut: the cut first, then the voice and the captions go out of date.
    let lines = e.project!.takes!.lines
    if let k = lines.firstIndex(where: { $0.takes.count > 1 }) {
        try run(e, StepCalls.select(line: k + 1, take: 1))
        #expect(states(e)[.cut].status == .stale)
    }
    try run(e, StepCalls.cut(minPause: 0.3, breath: 0.05))   // shorter pauses removed: a different cut
    s = states(e)
    #expect(s[.cut].status == .done)
    #expect(s[.clean].status == .stale && s[.clean].line.contains("ripulita"))
    #expect(s[.captions].status == .stale)
    #expect(s.next == .clean)
}

@Test func eachButtonRunsTheRightCommands() throws {
    let e = try importedClip()
    let p0 = e.project!
    #expect(StepCalls.plan(.transcribe, project: p0, settings: StepSettings(language: "fr"), keywords: [])
            == [StepCall(id: "media.extractAudio", params: ["assetId": "a1"]),
                StepCall(id: "transcript.run", params: ["assetId": "a1", "language": "fr"])])
    try e.execute("media.extractAudio", params: ["assetId": "a1"])
    #expect(StepCalls.plan(.transcribe, project: e.project!, settings: StepSettings(language: "auto"), keywords: [])
            == [StepCall(id: "transcript.run", params: ["assetId": "a1", "language": "auto"])])   // no second extraction
    #expect(StepCalls.plan(.takes, project: p0, settings: settings, keywords: []).map(\.id) == ["script.fromTranscript", "takes.list"])
    try e.execute("script.set", params: ["text": "Oggi Regista monta il reel.\nLe pause spariscono da sole."])
    #expect(StepCalls.plan(.takes, project: e.project!, settings: settings, keywords: []).map(\.id) == ["takes.list"])
    var s = settings
    s.minPause = 1.25
    s.breath = 0.08
    #expect(StepCalls.plan(.cut, project: p0, settings: s, keywords: [])
            == [StepCall(id: "edit.autoCut", params: ["replace": true, "maxPause": 1.25, "keepPause": 0.08])])
    #expect(StepCalls.plan(.clean, project: p0, settings: s, keywords: []) == [StepCall(id: "audio.clean", params: ["target": -15])])
    s.style = "bold-keyword"
    #expect(StepCalls.plan(.captions, project: p0, settings: s, keywords: ["REEL", "3"])
            == [StepCall(id: "captions.generate", params: ["style": "bold-keyword", "keywords": ["REEL", "3"]])])
    #expect(StepCalls.suggestKeywords(style: "talking-head-v1") == StepCall(id: "captions.generate", params: ["style": "talking-head-v1", "dryRun": true]))
    #expect(StepCalls.plan(.transcribe, project: Project(name: "vuoto", settings: ProjectSettings()), settings: s, keywords: []).isEmpty)
}

/// "Fai tutto" through the driver the app uses, on a headless engine, recording each command.
@MainActor
private func doAll(_ e: Engine, script: String?, stopAt: String? = nil) async throws -> [String] {
    var ran: [String] = []
    var stepsSeen: [Int] = []
    let driver = StepDriver(project: { e.project },
                            perform: { call, _, _ in
                                if call.id == stopAt { throw CancellationError() }   // the job's Cancel at this command
                                ran.append(call.id)
                                return try e.execute(call.id, params: call.params)
                            },
                            suggest: { style in
                                let c = StepCalls.suggestKeywords(style: style)
                                return (try? e.execute(c.id, params: c.params))?["suggestedKeywords"]?.arrayValue?.compactMap(\.stringValue) ?? []
                            },
                            step: { stepsSeen.append($0) })
    let steps = EditorStore.allSteps(hasScriptText: !(script ?? "").isEmpty)
    try await driver.runAll(steps, settings: settings, script: script)
    #expect(stepsSeen == Array(0...steps.count))
    return ran
}

@MainActor
@Test func doEverythingRunsTheStepsInOrderAndStopsOnCancel() async throws {
    // From an imported synthetic clip to captions with only the commands the buttons call.
    let e = try importedClip()
    let ran = try await doAll(e, script: nil)
    #expect(ran == ["media.extractAudio", "transcript.run", "script.fromTranscript", "takes.list", "edit.autoCut", "audio.clean", "captions.generate"])
    let s = states(e)
    #expect([TextStep.transcribe, .takes, .cut, .clean, .captions].allSatisfy { s[$0].status == .done })
    let captions = try #require(e.project?.tracks.first { $0.kind == .caption }?.captions)
    #expect(!captions.chunks.isEmpty && !captions.keywords.isEmpty)   // with the suggested keywords
    // Again: everything is done, nothing runs.
    #expect(try await doAll(e, script: nil).isEmpty)

    // With the teleprompter's text it becomes the copione; Cancel at the cut stops there: nothing after it ran.
    let f = try importedClip()
    var stopped = false
    do { _ = try await doAll(f, script: "Oggi Regista monta il reel.\nLe pause spariscono da sole.", stopAt: "edit.autoCut") }
    catch is CancellationError { stopped = true }
    #expect(stopped)
    #expect(f.project?.script?.lines.count == 2 && f.project?.takes != nil)
    #expect(f.project?.tracks.first { $0.kind == .caption } == nil)
    #expect(f.project?.assets.contains { $0.origin != nil } == false)   // the voice was not cleaned
    #expect(states(f)[.cut].status == .todo)
}

@MainActor
@Test func aStepThatCannotRunStopsDoEverythingWithItsReason() async throws {
    let e = Engine(prober: ClipProber(), services: EngineServices(config: EngineConfig(), tier: .base, audio: SpeechAudio(),
                                                                  transcribers: [], cleaner: CopyCleaner(), faces: nil))
    try e.execute("project.new", params: ["name": "vuoto", "directory": .string(tempDir().path)])
    do {
        _ = try await doAll(e, script: nil)
        Issue.record("expected a stop")
    } catch let error as StepError {
        #expect(error.message.hasPrefix(TextStep.transcribe.title()) && error.message.contains("Importa"))
    }
}

@Test func errorsAreReadable() {
    let missing = StepError.readable(CommandError(.io, "transcript.run: whisper-cli not found at /x/whisper-cli (run scripts/build-whisper.sh)"), { $0 })
    #expect(missing.hasPrefix("Il motore che serve non è installato"))
    #expect(StepError.readable(CommandError(.io, "transcript.run: whisper.cpp returned no words"), { $0 }).hasPrefix("Non ho sentito parole"))
    #expect(StepError.readable(CommandError(.io, "transcript.run: whisper-cli: cancelled"), { $0 }).hasPrefix("Annullato"))
    let other = StepError.readable(CommandError(.io, "export.render: something odd"), { $0 })
    #expect(other == "Non è riuscito: something odd")   // the command id never shows
}

/// A workbench without the engine socket (tests never reach a running app).
@MainActor
private func bench() -> Workbench {
    _ = NSApplication.shared
    let name = "regista-steps-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return Workbench(defaults: d, seedFolders: [], socketPath: nil)
}

@MainActor
@Test func aJobReportsProgressCancelsItsProcessForRealAndShowsAReadableError() async throws {
    let tab = bench().newTab()
    let pidFile = tempDir().appendingPathComponent("pid")
    // The work of a command: progress, then an engine process that would run for a minute.
    let id = tab.startJob(kind: "test", title: "Lungo") { _, job in
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread {
                let r = Result {
                    try CommandJob.$current.withValue(job) {
                        CommandJob.report(0.4)
                        _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo $$ > '\(pidFile.path)'; exec sleep 60"])
                    }
                }
                cont.resume(with: r)
            }
        }
    }
    // Until the engine process runs and the job shows its progress (up to 20 s: a busy Mac, #80).
    for _ in 0..<200 where !(FileManager.default.fileExists(atPath: pidFile.path) && tab.jobs.job(id)?.progress == 0.4) {
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(tab.jobs.job(id)?.progress == 0.4 && tab.jobs.job(id)?.isRunning == true)
    #expect(tab.runningWork == "Lungo")   // the tab's state dot shows it working
    let pid = Int32((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
    tab.jobs.cancel(id)
    #expect(tab.jobs.job(id)?.state == .cancelled)
    var gone = false
    for _ in 0..<50 where !gone {
        gone = kill(pid, 0) != 0
        if !gone { try await Task.sleep(for: .milliseconds(100)) }
    }
    #expect(gone)   // the engine process was killed, not left running

    // A failure shows in words.
    let failing = tab.startJob(kind: "test-fail", title: "Trascrivi") { _, _ in
        throw StepError(message: StepError.readable(CommandError(.io, "transcript.run: whisper-cli not found at /nowhere")))
    }
    for _ in 0..<200 where tab.jobs.job(failing)?.isRunning == true { try await Task.sleep(for: .milliseconds(100)) }
    guard case .failed(let message) = tab.jobs.job(failing)?.state else { Issue.record("expected a failure"); return }
    #expect(message == loc("Il motore che serve non è installato su questo Mac: Impostazioni › Motori dice come installarlo."))
}

/// #13: an engine that prints no progress fills its job with an estimate — the same bar and percentage as any job, said
/// to be an estimate in the card's line ("stima") and to an assistive client; the job ends at 100 %, measured.
extension MouseSuites {
@Suite(.serialized) @MainActor struct EstimatedJobTests {
    @Test func anEstimatedJobShowsItsPercentageAndSaysItIsAnEstimate() async throws {
        let tab = bench().newTab()
        let id = tab.startJob(kind: "test-estimate", title: "Pulisci la voce") { _, job in
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                Thread.detachNewThread {
                    let r = Result {
                        try CommandJob.$current.withValue(job) {
                            try CommandJob.stage(0, 1) {
                                // An engine that prints nothing for 2 s, expected to take 2.5 s here.
                                try CommandJob.estimating(2.5) { _ = try Subprocess.check(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 2"]) }
                            }
                        }
                    }
                    cont.resume(with: r)
                }
            }
        }
        var seen: [Double] = []
        for _ in 0..<100 where (tab.jobs.job(id)?.progress ?? 0) < 0.3 {
            if let p = tab.jobs.job(id)?.progress { seen.append(p) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let running = try #require(tab.jobs.job(id))
        #expect(running.isRunning && running.estimated && (running.progress ?? 0) >= 0.3 && (running.progress ?? 1) <= 0.95)
        // The card in the jobs list: the bar's value and the line both say it is an estimate.
        let rig = MouseRig(JobsListView(groups: [(tab: "Reel", jobs: [running])], bench: nil).frame(width: 360), size: CGSize(width: 360, height: 220))
        defer { rig.close() }
        let percent = String(Int(((running.progress ?? 0) * 100).rounded())) + " %"
        let bar = try #require(rig.element("Avanzamento"))
        #expect(bar.value == percent + " · " + loc("stima") || bar.valueDescription == percent + " · " + loc("stima"), "\(bar)")
        #expect(!rig.elements(containing: percent + " · " + loc("stima") + " · ").isEmpty)
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            let v = rig.host
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("job-estimated.png"))
            }
        }
        for _ in 0..<200 where tab.jobs.job(id)?.isRunning == true {
            if let p = tab.jobs.job(id)?.progress { seen.append(p) }
            try await Task.sleep(for: .milliseconds(50))
        }
        let done = try #require(tab.jobs.job(id))
        #expect(done.state == .done && done.progress == 1 && !done.estimated)
        #expect(seen == seen.sorted())   // never back
    }
}
}
