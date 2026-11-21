import AppKit
import Foundation
import RegistaCore
import RegistaEngines
import Testing
@testable import Regista

// E5 (#4): the Semplice level. The six steps' states (an empty project, after each step, a missing engine, "Fai tutto"
// twice), undo after each control, and a headless reel from raw synthetic footage to an export at −15 LUFS that passes
// the caption timing and sync checks — every command the one a Simple control sends (SimpleCalls, the steps' job plan,
// ExportCalls), on an engine with real ffmpeg and the real compositor; only the transcription and the voice cleaning are
// stand-ins (the speech is synthetic).

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-simple-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The words of the synthetic take: the first line read twice (a retake), then two more lines, with pauses between.
private let readings: [(text: String, start: Double)] = [
    ("Oggi Regista monta il reel.", 0.5), ("Oggi Regista monta il reel.", 3.2),
    ("Le pause spariscono da sole.", 5.6), ("E il reel è pronto.", 8.1),
]
private let wordLength = 0.26, wordGap = 0.04, takeLength = 10.0

private func words() -> [RegistaCore.Word] {
    readings.flatMap { r in
        r.text.split(separator: " ").enumerated().map { i, w in
            let t = r.start + Double(i) * (wordLength + wordGap)
            return RegistaCore.Word(text: String(w), start: MediaTime(seconds: t), end: MediaTime(seconds: t + wordLength))
        }
    }
}

/// Speech-like bursts (a 200 Hz tone with a syllable envelope) on each word, near silence elsewhere.
private func speech(rate: Int) -> [Float] {
    let ws = words()
    return (0..<Int(takeLength * Double(rate))).map { i in
        let t = Double(i) / Double(rate)
        guard let w = ws.first(where: { t >= $0.start.seconds && t < $0.end.seconds }) else { return Float(sin(Double(i) * 0.7) * 0.0005) }
        let phase = (t - w.start.seconds) / wordLength
        return Float(0.3 * sin(.pi * phase) * sin(2 * .pi * 200 * t))
    }
}

/// The transcription of the synthetic take (whisper cannot hear a tone).
private struct TakeTranscriber: RegistaCore.Transcriber {
    var id = WhisperCppTranscriber.engineID
    var model = "test"
    func unavailableReason() -> String? { nil }
    func transcribe(_ speech16k: URL, language: String) throws -> RegistaCore.Transcript {
        RegistaCore.Transcript(engine: id, model: model, language: "it", words: words())
    }
}

/// The voice cleaning without DeepFilterNet: the used ranges brought to the target loudness with one gain (real ffmpeg
/// measures them), written as dual-mono stereo, in sync by construction.
private struct LevelCleaner: VoiceCleaner {
    let audio: AudioToolkit
    func unavailableReason() -> String? { nil }
    func clean(_ r: VoiceCleanRequest) throws -> VoiceCleanReport {
        let input = try WAVAudio.read(r.input)
        let measured = try audio.loudness(of: r.ranges.map { AudioSpan(url: r.input, start: $0.start, end: $0.end, channels: 1) })
        let gain = Float(pow(10, (r.targetLUFS - measured.integrated) / 20))
        try WAVAudio(sampleRate: input.sampleRate, channels: 2, samples: input.samples.flatMap { [$0 * gain, $0 * gain] }).write16(to: r.output)
        return VoiceCleanReport(rangeGains: r.ranges.map { _ in 0 }, measured: measured, gain: r.targetLUFS - measured.integrated,
                                mode: "linear", denoiseSeconds: 0)
    }
}

/// A missing engine (what this Mac would say without whisper.cpp or DeepFilterNet).
private struct MissingTranscriber: RegistaCore.Transcriber {
    var id = WhisperCppTranscriber.engineID
    var model = "none"
    func unavailableReason() -> String? { "whisper-cli not found" }
    func transcribe(_ speech16k: URL, language: String) throws -> RegistaCore.Transcript { throw CommandError(.io, "missing") }
}

private struct MissingCleaner: VoiceCleaner {
    func unavailableReason() -> String? { "deep-filter not found" }
    func clean(_ r: VoiceCleanRequest) throws -> VoiceCleanReport { throw CommandError(.io, "missing") }
}

private var ffmpeg: String { EngineConfig.expand(EngineConfig().ffmpeg) }

/// An engine with real ffmpeg, the compositor and the shipped sound bank; the synthetic take's transcription and a
/// levelling cleaner (or the missing engines). Scratch folders only: never the owner's profiles, budget or caches.
private func engine(transcriber: RegistaCore.Transcriber = TakeTranscriber(), cleaner: VoiceCleaner? = nil) -> Engine {
    var s = EngineServices.live()
    s.config.cacheDirectory = tempDir().path
    s.tier = .base   // the stand-in transcriber is whisper.cpp's, the base tier's default
    s.transcribers = [transcriber.id: transcriber]
    s.cleaner = cleaner ?? LevelCleaner(audio: s.audio)
    s.profiles = ProfileStore(directory: tempDir())
    s.generationState = tempDir()
    return Engine(services: s)
}

/// Raw footage: a 1080×1920 30 fps test picture with the synthetic speech, as an iPhone-like .mov.
private func footage(in dir: URL) throws -> URL {
    let wav = dir.appendingPathComponent("speech.wav"), mov = dir.appendingPathComponent("take.mov")
    try WAVAudio(sampleRate: 48_000, channels: 1, samples: speech(rate: 48_000)).write16(to: wav)
    try Subprocess.check(URL(fileURLWithPath: ffmpeg), ["-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=s=1080x1920:r=30:d=\(Int(takeLength))",
                                                         "-i", wav.path, "-c:v", "h264_videotoolbox", "-b:v", "4M", "-pix_fmt", "yuv420p",
                                                         "-c:a", "aac", "-b:a", "192k", "-shortest", mov.path])
    return mov
}

/// A music bed: a soft chord, 4 s (looped by audio.addMusic).
private func musicFile(in dir: URL) throws -> URL {
    let rate = 48_000
    let m = (0..<(4 * rate)).map { i -> Float in
        let t = Double(i) / Double(rate)
        return Float(0.1 * (sin(2 * .pi * 261.6 * t) + sin(2 * .pi * 329.6 * t) + sin(2 * .pi * 392 * t)) / 3)
    }
    let url = dir.appendingPathComponent("bed.wav")
    try WAVAudio(sampleRate: rate, channels: 1, samples: m).write16(to: url)
    return url
}

/// What Importa does: a new project, the take imported and placed (picture on V1, sound on A1, linked).
private func imported(_ e: Engine, _ dir: URL) throws {
    let take = try footage(in: dir)
    try e.execute("project.new", params: ["name": "semplice", "directory": .string(dir.path)])
    try e.execute("media.import", params: ["path": .string(take.path)])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "linkTo": "c1"])
}

/// The job a Simple control starts (its steps through the app's driver), on the headless engine; returns the commands run.
@MainActor
@discardableResult
private func job(_ e: Engine, _ steps: [TextStep], _ settings: StepSettings, extras: (Project?) -> [StepCall] = { _ in [] }) async throws -> [String] {
    var ran: [String] = []
    let driver = StepDriver(project: { e.project },
                            perform: { call, _, _ in ran.append(call.id); return try e.execute(call.id, params: call.params) },
                            suggest: { style in
                                let c = StepCalls.suggestKeywords(style: style)
                                return (try? e.execute(c.id, params: c.params))?["suggestedKeywords"]?.arrayValue?.compactMap(\.stringValue) ?? []
                            })
    try await driver.runAll(steps, settings: settings, script: nil, extras: extras)
    return ran
}

/// One instant control: its command, then undo puts the project back exactly, then redo again (the control's effect).
private func control(_ e: Engine, _ c: StepCall, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let before = e.project
    _ = try e.execute(c.id, params: c.params)
    let after = e.project
    #expect(after != before, "\(c.id) changed nothing", sourceLocation: sourceLocation)
    try e.execute("history.undo")
    #expect(e.project == before, "undo after \(c.id) did not restore the project", sourceLocation: sourceLocation)
    try e.execute("history.redo")
    #expect(e.project == after, sourceLocation: sourceLocation)
}

private func snap(_ e: Engine, engines: SimpleEngines = .ready) -> SimpleSnapshot {
    SimpleSnapshot.compute(e.project, engines: engines, lookup: { $0 })
}

private let base = StepSettings(language: "it")

@MainActor
@Test func theStepsFollowTheProjectFromEmptyToDone() async throws {
    guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return }   // needs ffmpeg
    // No project: every step waits for a video, the first one says so and offers Importa.
    let none = SimpleSnapshot.compute(nil, engines: .ready, lookup: { $0 })
    #expect(SimpleStep.allCases.allSatisfy { none[$0].status == .blocked && none[$0].needsImport })
    #expect(none.next == nil && !none.canDoEverything)

    let e = engine(), dir = tempDir()
    try imported(e, dir)
    var s = snap(e)
    #expect(s[.cut].status == .todo && s[.captions].status == .todo && s[.look].status == .todo && s[.voice].status == .todo)
    #expect(s[.sound].status == .notNeeded && s[.graphics].status == .notNeeded)
    #expect(s.next == .cut && s.canDoEverything)

    // Taglio e riprese: the first cut is one job (transcribe, takes, cut) with the preset's pauses.
    let tight = SimpleCalls.cutSettings(.tight, pauses: true, base: base)
    #expect(try await job(e, SimpleCalls.cutSteps, tight) == ["media.extractAudio", "transcript.run", "script.fromTranscript", "takes.list", "edit.autoCut"])
    s = snap(e)
    #expect(s[.cut].status == .done && s.cutPreset == .tight && s.pauses)
    #expect(s.next == .captions)
    let retake = try #require(s.retakes.first, "the first line was read twice")
    #expect(retake.takes == 2)
    // Another take, and the cut that uses it: one undo step.
    try control(e, SimpleCalls.pick(line: retake.line, take: retake.chosen == 1 ? 2 : 1))
    #expect(snap(e)[.cut].status == .done)
    try control(e, SimpleCalls.cut(.natural, pauses: true))
    #expect(snap(e).cutPreset == .natural)
    try control(e, SimpleCalls.cut(.natural, pauses: false))
    #expect(!snap(e).pauses && snap(e).cutPreset == .natural)

    // Sottotitoli: on (a job), another style, off — each undoable.
    try await job(e, SimpleCalls.captionSteps, SimpleCalls.captionSettings(style: "bold-keyword", base: base))
    s = snap(e)
    #expect(s[.captions].status == .done && s.captionStyle == "bold-keyword" && s.keywords > 0)
    try control(e, SimpleCalls.captionStyle("talking-head-v1"))
    try control(e, SimpleCalls.captionsOff(trackID: try #require(snap(e).captionsTrack)))
    #expect(snap(e)[.captions].status == .todo)
    try e.execute("history.undo")
    #expect(snap(e)[.captions].status == .done)

    // Aspetto: the light grade and a look.
    let video = try #require(snap(e).videoTrack)
    try control(e, SimpleCalls.light(true, trackID: video))
    #expect(snap(e).light && snap(e)[.look].status == .done)
    try control(e, SimpleCalls.look("film", amount: 0.6))
    #expect(snap(e).look == "film")
    try control(e, SimpleCalls.light(false, trackID: video))
    #expect(!snap(e).light && snap(e)[.look].status == .done)   // the look is still on

    // Musica e suoni: whooshes on the cuts (on, off).
    try control(e, SimpleCalls.soundEffects(true))
    s = snap(e)
    #expect(s.effects > 0 && s[.sound].status == .done)
    let again = try e.execute("sfx.onCuts")
    #expect(again["placed"]?.doubleValue == 0 && snap(e).effects == s.effects)   // twice adds nothing
    try control(e, SimpleCalls.soundEffects(false))
    #expect(snap(e).effects == 0 && snap(e)[.sound].status == .notNeeded)

    // Voce: cleaned (the step's job), then off (the original sound back).
    try await job(e, [.clean], base)
    #expect(snap(e).cleaned && snap(e)[.voice].status == .done)
    try control(e, SimpleCalls.clean(false))
    #expect(!snap(e).cleaned && snap(e)[.voice].status == .todo)
    try e.execute("history.undo")

    // Grafica: an opening title (the Titolo row's command) makes the step done.
    let title = try #require(GraphicsActions.command("text-hook", project: e.project!, at: 0, overrides: ["text": "Oggi monta il reel"]))
    try control(e, StepCall(id: title.command, params: title.params))
    #expect(snap(e)[.graphics].status == .done)
    #expect(snap(e).next == nil)   // every step in place: the export comes next
}

@MainActor
@Test func aMissingEngineLeavesTheStepVisibleAndDisabledWithTheReason() throws {
    let e = Engine(prober: StubProber(), services: {
        var s = EngineServices(config: EngineConfig(), tier: .base, audio: FFmpegAudio(config: EngineConfig()),
                               transcribers: [MissingTranscriber()], cleaner: MissingCleaner(), faces: nil)
        s.config.cacheDirectory = tempDir().path
        return s
    }())
    let dir = tempDir()
    let clip = dir.appendingPathComponent("clip.mov")
    FileManager.default.createFile(atPath: clip.path, contents: Data())
    try e.execute("project.new", params: ["name": "senza-motori", "directory": .string(dir.path)])
    try e.execute("media.import", params: ["path": .string(clip.path)])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "linkTo": "c1"])

    let engines = SimpleEngines.of(e.context.services)
    #expect(engines.transcribe == SimpleEngines.transcribeMissing && engines.clean == SimpleEngines.cleanMissing)
    let s = snap(e, engines: engines)
    for step in [SimpleStep.cut, .captions, .voice] {
        #expect(s[step].status == .unavailable && !s[step].canAct, "\(step)")
        #expect(!s[step].line.isEmpty && s[step].install != nil, "\(step) says why and what to install")
    }
    #expect(s[.cut].install == WhisperCppTranscriber.engineID && s[.voice].install == "deepfilternet")
    #expect(!s.canDoEverything)
    // The other steps still work.
    #expect(s[.look].status == .todo && s[.sound].status == .notNeeded && s[.graphics].status == .notNeeded)
    // "Fai tutto" leaves out the voice cleaning when this Mac cannot clean.
    #expect(!SimpleCalls.doEverythingSteps(hasScriptText: false, engines: engines).contains(.clean))
    #expect(SimpleCalls.doEverythingSteps(hasScriptText: false, engines: .ready).contains(.clean))
}

/// #112: on a Medium Mac whose WhisperX is not installed yet, the window's transcription is available (whisper.cpp runs
/// it); with neither engine it is not.
@MainActor
@Test func aMediumMacWithoutWhisperXStillTranscribes() {
    func services(_ transcribers: [RegistaCore.Transcriber]) -> EngineServices {
        EngineServices(config: EngineConfig(), tier: .medium, audio: FFmpegAudio(config: EngineConfig()),
                       transcribers: transcribers, cleaner: MissingCleaner(), faces: nil)
    }
    let fallback = services([FixtureTranscriber(), MissingTranscriber(id: WhisperXTranscriber.engineID)])
    #expect(SimpleEngines.of(fallback).transcribe == nil, "the window's transcription is refused on a Medium Mac without WhisperX")
    let neither = services([MissingTranscriber(), MissingTranscriber(id: WhisperXTranscriber.engineID)])
    #expect(SimpleEngines.of(neither).transcribe == SimpleEngines.transcribeMissing)
}

/// A clip with picture and sound, without reading the file (the missing-engine test never decodes it).
private struct StubProber: MediaProber {
    func probe(_ url: URL) throws -> ProbedMedia {
        let audio = try JSONDecoder().decode(AudioInfo.self, from: Data(#"{"sampleRate": 48000, "channels": 1, "codec": "pcm_s16le"}"#.utf8))
        let video = try JSONDecoder().decode(VideoInfo.self, from: Data(#"{"width": 1080, "height": 1920, "frameRate": {"num": 30, "den": 1}, "codec": "h264", "rotation": 0}"#.utf8))
        return ProbedMedia(duration: MediaTime(seconds: 6), video: video, audio: audio)
    }
}

@MainActor
@Test func doEverythingTwiceDoesNotDoubleAnything() async throws {
    guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return }
    let e = engine(), dir = tempDir()
    try imported(e, dir)
    let steps = SimpleCalls.doEverythingSteps(hasScriptText: false, engines: .ready)
    let first = try await job(e, steps, base, extras: SimpleCalls.lookExtras)
    #expect(first == ["media.extractAudio", "transcript.run", "script.fromTranscript", "takes.list", "edit.autoCut", "audio.clean",
                      "captions.generate", "clip.set"])
    let s = snap(e)
    #expect([SimpleStep.cut, .captions, .look, .voice].allSatisfy { s[$0].status == .done })
    #expect(s.light && s[.sound].status == .notNeeded && s[.graphics].status == .notNeeded)   // no music or graphics unasked
    let after = e.project
    let second = try await job(e, steps, base, extras: SimpleCalls.lookExtras)
    #expect(second.isEmpty)                                     // every step done: nothing runs
    #expect(e.project == after)                                 // and nothing changes
    #expect(e.project?.tracks.filter { $0.kind == .caption }.count == 1)
    #expect(e.project?.assets.filter { $0.origin?.process == "audio.clean" }.count == 1)
}

@MainActor
@Test func aReelFromRawFootageWithTheSimpleControlsExportsAtMinus15LUFS() async throws {
    guard FileManager.default.isExecutableFile(atPath: ffmpeg) else { return }
    let e = engine(), dir = tempDir()
    try imported(e, dir)
    // Taglio e riprese (Medio), the other take of the line read twice.
    try await job(e, SimpleCalls.cutSteps, SimpleCalls.cutSettings(.medium, pauses: true, base: base))
    if let r = snap(e).retakes.first { _ = try e.execute("edit.autoCut", params: SimpleCalls.pick(line: r.line, take: r.takes).params) }
    // Sottotitoli in the approved style.
    try await job(e, SimpleCalls.captionSteps, SimpleCalls.captionSettings(style: "talking-head-v1", base: base))
    // Aspetto: the light grade and Pellicola at Medio.
    let video = try #require(snap(e).videoTrack)
    for c in [SimpleCalls.light(true, trackID: video), SimpleCalls.look("film", amount: 0.6)] { _ = try e.execute(c.id, params: c.params) }
    // Voce: cleaned to −15 LUFS.
    try await job(e, [.clean], base)
    // Musica e suoni: a music bed (Scegli una musica…), its level Bassa, whooshes on the cuts.
    let bed = AudioCalls.addMusic(path: try musicFile(in: dir).path)
    _ = try e.execute(bed.id, params: bed.params)
    let music = try #require(AudioCalls.musicTrack(e.project))
    let measured = try #require(try e.execute("media.measureLoudness", params: ["assetId": .string(music.clips[0].assetID)])["integrated"]?.doubleValue)
    for c in [SimpleCalls.musicLevel(.low, trackID: music.id, measured: measured), SimpleCalls.soundEffects(true)] {
        _ = try e.execute(c.id, params: c.params)
    }
    // Grafica: an opening title.
    let title = try #require(GraphicsActions.command("text-hook", project: e.project!, at: 0, overrides: ["text": "Oggi monta il reel"]))
    _ = try e.execute(title.command, params: title.params)
    let s = snap(e)
    #expect(SimpleStep.allCases.allSatisfy { s[$0].status == .done }, "\(SimpleStep.allCases.map { "\($0): \(s[$0].status)" })")

    // Esporta il reel: the editing rules first, as the Export card's «Sistema tutto ed esporta» (#31: the opening title
    // over the captions), then Reel 9:16, the mix at −15 LUFS, then the checks.
    _ = try e.execute(ExportCalls.fixAll.id, params: ExportCalls.fixAll.params)
    let out = dir.appendingPathComponent("reel.mp4")
    let render = ExportCalls.render(path: out.path, preset: "9:16", captions: true, bitrate: 8)
    let r = try e.execute(render.id, params: render.params)
    let lufs = try #require(r["loudness"]?["integrated"]?.doubleValue)
    let peak = r["loudness"]?["truePeak"]?.doubleValue ?? 0
    print("E5 Simple reel: \(lufs) LUFS, true peak \(peak) dBTP, \(r["frames"]?.doubleValue ?? 0) frames")
    #expect(abs(lufs - LoudnessTarget.integrated) <= 0.5)
    #expect(peak <= LoudnessTarget.truePeak + 0.05)
    let timing = try e.execute("captions.checkTiming", params: ["path": .string(out.path)])
    #expect(timing["pass"]?.boolValue == true, "\(timing)")
    let sync = try e.execute("media.checkSync", params: ["path": .string(out.path)])
    print("E5 Simple reel sync: \(sync)")
    #expect(abs(sync["lagFrames"]?.doubleValue ?? 9) < 1 && (sync["correlation"]?.doubleValue ?? 0) >= 0.5, "\(sync)")   // the scenarios' pass
}

@MainActor
@Test func switchingLevelsKeepsTheProjectSelectionAndPlayheadAndIsRemembered() {
    _ = NSApplication.shared
    let d = TestDefaults.make("simple-tests")
    defer { TestDefaults.end(d) }
    let bench = Workbench(defaults: d, seedFolders: [], socketPath: nil)
    let store = bench.newTab()
    store.selection = ["c1"]
    store.workspace = .simple
    #expect(store.nav.level == .simple && store.nav.inEditor)
    #expect(d.string(forKey: Navigation.levelKey) == "simple")
    store.workspace = .pro
    store.workspace = .simple
    #expect(store.selection == ["c1"])                    // one store: the same project, selection and player on both levels
    let next = Workbench(defaults: d, seedFolders: [], socketPath: nil)
    #expect(next.nav.level == .simple)                    // the level is remembered
    #expect(Navigation.restored(activity: "media", level: "quick", rightTab: nil, hasRecents: true).level == .simple)   // before E5
}
