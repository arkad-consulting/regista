import Foundation
import Testing
@testable import RegistaCore

// The checks that measure (#145): reading time and text in frame, the «always» measures inside rules.check, the faceless
// reel's still stretches, jump cuts and the voice read back. Every engine is a stand-in: the fakes' audio toolkit and
// transcription, a frame sampler that hands synthetic frames, a render file that is an empty scratch file.

/// An engine on fakes with the 6 s take on V1 (a 1080×1920 reel: the talking-head kind) and the compositor stand-in.
private func measuringEngine(_ fakes: FakeServices = FakeServices(), configure: (inout EngineServices) -> Void = { _ in }) throws -> Engine {
    var services = fakes.make()
    services.renderer = FakeRenderer()
    configure(&services)
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "measures", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 6])
    return e
}

private func violations(_ check: JSONValue, _ id: String) -> [JSONValue] {
    check["violations"]?.arrayValue?.filter { $0["check"]?.stringValue == id } ?? []
}

private func row(_ check: JSONValue, _ id: String) -> JSONValue? {
    check["checks"]?.arrayValue?.first { $0["id"]?.stringValue == id }
}

// MARK: 1. Reading time and text in frame

@Test func theReadingTimeIsTheBasePlusTheLettersAndShortTextsAreExempt() throws {
    // 12 words, 40 letters: 0.6 + 40 / 12 = 3.93 s.
    let title = "Ecco tre modi per\nfare un reel che\nsi fa notare ora"
    #expect(title.split(whereSeparator: \.isWhitespace).count == 12)
    #expect(abs((RuleCheck.readingSeconds(title) ?? 0) - (0.6 + 40.0 / 12)) < 1e-9)
    // A dense script reads 6 characters a second.
    #expect(abs((RuleCheck.readingSeconds("今日は三つのこと") ?? 0) - (0.6 + 8.0 / 6)) < 1e-9)
    #expect(RuleCheck.readingSeconds("3") == nil && RuleCheck.readingSeconds("🔥") == nil && RuleCheck.readingSeconds("OK") == nil)
    #expect(RuleCheck.readingSeconds("WOW") != nil)
}

@Test func aTitleShownTooBrieflyFailsWithTheSecondsMissingAndAFixThatLengthensIt() throws {
    let e = try measuringEngine()
    let title = "Ecco tre modi per\nfare un reel che\nsi fa notare ora"
    let added = try e.execute("title.add", params: ["text": .string(title), "start": 1, "duration": 1.5])
    let id = try #require(added.value(at: "clip.id")?.stringValue)
    let check = try e.execute("rules.check", params: ["language": "en"])
    let v = try #require(violations(check, "reading-time").first, "\(check)")
    #expect(check["pass"] == false && v["severity"] == "fail" && v["clipId"]?.stringValue == id)
    #expect(v.value(at: "messageArgs.1") == 1.5 && v.value(at: "messageArgs.2") == 3.93 && v.value(at: "messageArgs.3") == 2.43, "\(v)")
    #expect(v.value(at: "fix.command") == "timeline.trim" && v.value(at: "fix.params.edge") == "end")
    let to = try #require(v.value(at: "fix.params.to")?.doubleValue)
    #expect(to >= 1 + 3.9333 - 1e-6 && to < 1 + 3.9333 + 1.0 / 30 + 1e-6, "the fix does not end it on the frame after the time needed: \(to)")
    // rules.fix lengthens it in one undo step; then it passes.
    let fixed = try e.checkUndoRedo("rules.fix", ["check": "reading-time"])
    #expect(violations(fixed["check"] ?? [:], "reading-time").isEmpty, "\(fixed)")
}

@Test func aTitleShownFourSecondsPassesAndOneWithNoRoomAfterItHasNoFix() throws {
    let e = try measuringEngine()
    let title = "Ecco tre modi per\nfare un reel che\nsi fa notare ora"
    try e.execute("title.add", params: ["text": .string(title), "start": 1, "duration": 4])
    let passing = try e.execute("rules.check", params: ["language": "en"])
    #expect(violations(passing, "reading-time").isEmpty, "\(violations(passing, "reading-time"))")
    try e.execute("history.undo")
    // Ending with the video: nothing to lengthen into, the text is too long.
    try e.execute("title.add", params: ["text": .string(title), "start": 4.5, "duration": 1.5])
    let v = try #require(violations(try e.execute("rules.check", params: ["language": "en"]), "reading-time").first)
    #expect(v["fix"] == .null && v["message"]?.stringValue?.contains("The text is too long") == true, "\(v)")
}

@Test func aTitleOutOfTheFrameFailsWithoutAFix() throws {
    let e = try measuringEngine()
    // Long enough to be read, its top edge 40 px above the frame.
    try e.execute("title.add", params: ["text": "TRE MODI", "start": 1, "duration": 3, "top": -40])
    let v = try #require(violations(try e.execute("rules.check", params: ["language": "en"]), "reading-time").first)
    #expect(v["messageKey"] == "«%1$@» goes out of the frame by %2$@ px." && v["fix"] == .null, "\(v)")
    #expect((v.value(at: "messageArgs.1")?.doubleValue ?? 0) >= 39)
}

@Test func captionsAreNeverMeasuredAndANumberStickerIsExempt() throws {
    var fakes = FakeServices()
    // A long caption line spoken fast: a caption follows its words, it is not a text to read.
    fakes.words = [Word("supercalifragilistichespiralidoso", 1.0, 1.2), Word("precipitevolissimevolmente", 1.2, 1.4)]
    let e = try measuringEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("captions.generate")
    try e.execute("sticker.add", params: ["emoji": "3", "start": 2, "duration": 0.4])
    let check = try e.execute("rules.check")
    #expect(violations(check, "reading-time").isEmpty, "\(check)")
    #expect(row(check, "reading-time")?["ran"] == true)
}

@Test func aHyperFramesSceneGivesTheTextItShows() {
    let html = "<html><head><title>x</title><style>h1{color:red}</style></head><body><h1>Tre&nbsp;modi</h1><!-- note --><p>per fare &amp; rifare</p><script>var a = 1</script></body></html>"
    #expect(GraphicsHyperframes.visibleText(html) == "Tre modi per fare & rifare")
}

// MARK: 2. The «always» measures

/// The audio toolkit stand-in of the sound checks: a loudness per stem, by the name the measuring code gives its file
/// (audio.checkDucking's voice and music while someone speaks, the voice mix of voice-loudness).
private final class StemAudio: AudioToolkit {
    var voice = Loudness(integrated: -15.1, truePeak: -2.0, range: 3, threshold: -25)
    var musicUnderSpeech = -32.0
    /// The whole mix (nil: as loud as the voice).
    var mix: Loudness?
    /// Set: every measure fails with it (an engine that is missing).
    var missing: String?

    private let wavs = FakeAudio()
    func extractAudio(from source: URL, channels: Int, speech: URL, working: URL) throws {
        try wavs.extractAudio(from: source, channels: channels, speech: speech, working: working)
    }
    func loudness(of spans: [AudioSpan]) throws -> Loudness {
        if let missing { throw CommandError(.io, missing) }
        let name = spans.first?.url.deletingPathExtension().lastPathComponent ?? ""
        switch name {
        case "m-speech": return Loudness(integrated: musicUnderSpeech, truePeak: -20, range: 2, threshold: -40)
        case "m-gaps": return Loudness(integrated: -24, truePeak: -18, range: 2, threshold: -35)
        case "v-speech": return Loudness(integrated: -15, truePeak: -2, range: 3, threshold: -25)
        case "mix": return mix ?? voice
        default: return voice
        }
    }
    func mix(_ clips: [AudioMixClip], length: Int, rate: Int, gain: Double, ceiling: Double, to output: URL) throws {
        if let missing { throw CommandError(.io, missing) }
        try WAVAudio(sampleRate: rate, channels: 2, samples: [Float](repeating: 0, count: 2 * max(length, 1))).write16(to: output)
    }
}

/// The 6 s take on V1 and its sound on A1 (the voice), transcribed; the sound checks measure through `audio`.
private func soundEngine(_ audio: StemAudio) throws -> Engine {
    let e = try measuringEngine { $0.audio = audio }
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "start": 0, "linkTo": "c1"])
    return e
}

@Test func theVoiceAtItsLoudnessPassesOffItFailsAndBlocksTheExportUnlessExportedAnyway() throws {
    let audio = StemAudio()
    let e = try soundEngine(audio)
    var check = try e.execute("rules.check")
    #expect(violations(check, "voice-loudness").isEmpty && row(check, "voice-loudness")?["ran"] == true, "\(check)")
    // A quiet voice alone: the export brings the mix (the voice) to −15, so the check (the app's export levels) passes;
    // export.render without loudness exports it as it is, and refuses it.
    audio.voice = Loudness(integrated: -20.4, truePeak: -6, range: 3, threshold: -30)
    try e.execute("clip.set", params: ["clipId": "c2", "gain": -5])
    #expect(violations(try e.execute("rules.check"), "voice-loudness").isEmpty)
    let out = tempDir().appendingPathComponent("out.mp4").path
    do {
        try e.execute("export.render", params: ["path": .string(out)])
        Issue.record("the export was not refused")
    } catch let error as CommandError {
        #expect(error.message.contains("voice-loudness") && error.message.contains("-20.4 LUFS"), "\(error.message)")
    }
    let anyway = try e.execute("export.render", params: ["path": .string(out), "exportAnyway": true])
    #expect(anyway.value(at: "rules.exportedAnyway") == true)
    // Music that makes the mix 4 dB louder than the voice: levelled, the voice ends at −19: a failure, here and at export.
    audio.mix = Loudness(integrated: -16.4, truePeak: -3, range: 3, threshold: -26)
    try e.execute("audio.addMusic", params: ["path": .string(fakeMedia("bed.wav"))])
    check = try e.execute("rules.check", params: ["language": "en"])
    let v = try #require(violations(check, "voice-loudness").first, "\(check)")
    #expect(v["severity"] == "fail" && v.value(at: "messageArgs.0") == -15 && v.value(at: "messageArgs.1") == -19 && v.value(at: "messageArgs.2") == -16, "\(v)")
    #expect(throws: CommandError.self) { try e.execute("export.render", params: ["path": .string(out), "loudness": -15]) }
    // Its number is the target: a sheet that says −19 lets this voice through.
    try e.execute("rules.set", params: ["kind": "every-video", "checks": ["voice-loudness": ["value": -19]]])
    #expect(violations(try e.execute("rules.check"), "voice-loudness").isEmpty)
}

@Test func aMissingSoundEngineIsNotCheckedAndNeverBlocksTheExport() throws {
    let audio = StemAudio()
    let e = try soundEngine(audio)
    try e.execute("audio.addMusic", params: ["path": .string(fakeMedia("bed.wav"))])
    audio.missing = "ffmpeg not found"
    let check = try e.execute("rules.check", params: ["language": "en"])
    for id in ["voice-loudness", "music-ducked"] {
        let r = try #require(row(check, id))
        #expect(r["ran"] == false && r.value(at: "skipped.messageArgs.0")?.stringValue?.contains("ffmpeg not found") == true, "\(id): \(r)")
        #expect(violations(check, id).isEmpty)
    }
    #expect(check["notChecked"]?.arrayValue?.map { $0["check"]?.stringValue ?? "" }.contains("voice-loudness") == true)
    #expect(check["pass"] == true)
    // The export is not refused for them (it fails further on, on the stand-in's own mix: not a rule).
    do {
        try e.execute("export.render", params: ["path": .string(tempDir().appendingPathComponent("out.mp4").path)])
    } catch let error as CommandError {
        #expect(!error.message.contains("editing rule"), "\(error.message)")
    }
}

@Test func musicUnderTheVoicePassesAndMusicTooLoudFailsWithAFixThatDucksIt() throws {
    let audio = StemAudio()
    let e = try soundEngine(audio)
    try e.execute("audio.addMusic", params: ["path": .string(fakeMedia("bed.wav"))])
    #expect(violations(try e.execute("rules.check"), "music-ducked").isEmpty)
    // 6 dB under the voice instead of 15: a failure, its fix ducks the music deeper.
    audio.musicUnderSpeech = -21
    try e.execute("clip.set", params: ["clipId": "c3", "gain": 2])
    let check = try e.execute("rules.check", params: ["language": "en"])
    let v = try #require(violations(check, "music-ducked").first, "\(check)")
    #expect(v["severity"] == "fail" && v.value(at: "messageArgs.0") == 6 && v.value(at: "fix.command") == "audio.duck", "\(v)")
    #expect((v.value(at: "fix.params.duck")?.doubleValue ?? 0) <= -10)
    #expect(throws: CommandError.self) { try e.execute("export.render", params: ["path": .string(tempDir().appendingPathComponent("o.mp4").path)]) }
}

@Test func captionsOverAFacePassWhenPlacedOffItFailOnItAndAreNotCheckedWithoutAFaceTrack() throws {
    var fakes = FakeServices()
    fakes.faceTrack = facesOverTheCaptions()
    fakes.words = [Word("bonjour", 0.2, 0.6), Word("je", 0.7, 0.8), Word("suis", 0.8, 1.0), Word("pâtissière.", 1.0, 1.6),
                   Word("chaque", 2.0, 2.3), Word("année.", 2.3, 2.8)]
    let e = try measuringEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1", "language": "fr"])
    try e.execute("captions.generate", params: ["avoidFaces": false])
    // No face track yet: not checked, and the export is not blocked by it.
    var check = try e.execute("rules.check", params: ["language": "en"])
    #expect(row(check, "captions-faces")?["ran"] == false && row(check, "captions-faces")?.value(at: "skipped.message")?.stringValue?.contains("faces.track") == true)
    try e.execute("faces.track", params: ["assetId": "a1"])
    check = try e.execute("rules.check", params: ["language": "en"])
    let v = try #require(violations(check, "captions-faces").first, "\(check)")
    #expect(v["severity"] == "fail" && check["pass"] == false)
    try e.execute("captions.generate", params: ["avoidFaces": true])
    check = try e.execute("rules.check")
    #expect(violations(check, "captions-faces").isEmpty && row(check, "captions-faces")?["ran"] == true, "\(check)")
}

@Test func captionTimingWaitsForARenderOfThisEditAndMeasuresIt() throws {
    nonisolated(unsafe) var answer: JSONValue = ["pass": true, "outliers": [], "band": ["inside": true]]
    nonisolated(unsafe) var asked: [[String: JSONValue]] = []
    let e = try measuringEngine { s in
        s.ruleMeasures["captions.checkTiming"] = { params in asked.append(params); return answer }
    }
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("captions.generate")
    var check = try e.execute("rules.check", params: ["language": "en"])
    #expect(row(check, "captions-timing")?["ran"] == false && row(check, "captions-timing")?.value(at: "skipped.messageKey") == "No render of this edit yet: export it, then check again.")
    let out = tempDir().appendingPathComponent("out.mp4").path
    try e.execute("export.render", params: ["path": .string(out)])
    check = try e.execute("rules.check")
    #expect(row(check, "captions-timing")?["ran"] == true && violations(check, "captions-timing").isEmpty && asked.last?["path"]?.stringValue == out)
    // The same render, the words late in it: a failure. The edit changed: no render of it, not checked.
    answer = ["pass": false, "outliers": [["word": "DUE", "expected": 45, "observed": 52, "error": 7]], "band": ["inside": true]]
    let other = try measuringEngine { s in s.ruleMeasures["captions.checkTiming"] = { _ in answer } }
    try other.execute("transcript.run", params: ["assetId": "a1"])
    try other.execute("captions.generate")
    try other.execute("export.render", params: ["path": .string(tempDir().appendingPathComponent("o.mp4").path)])
    let late = try #require(violations(try other.execute("rules.check", params: ["language": "en"]), "captions-timing").first)
    #expect(late["severity"] == "fail" && late.value(at: "messageArgs.1") == "DUE" && late.value(at: "messageArgs.2") == 1.5, "\(late)")
    try other.execute("title.add", params: ["text": "HOOK", "start": 0, "duration": 2])
    #expect(row(try other.execute("rules.check"), "captions-timing")?["ran"] == false)
}


/// A face over the opening seconds and a child's lower in the frame, where the fixed caption band would land (y 1050–1330).
private func facesOverTheCaptions(frames: Int = 300) -> FaceTrack {
    let fs = (0..<frames).map { i -> FaceTrack.Frame in
        let d = Double(i)
        let mother = [250 + d, 420, 360, 420.0]
        let child = [640 + d * 0.5, 1050, 260, 280.0]
        return FaceTrack.Frame(t: Double(i) / 30, raw: mother, smooth: mother, others: [child])
    }
    return FaceTrack(video: "v", engine: "test", width: 1080, height: 1920, fps: 30, minCutoff: 0.3, beta: 0.01, cuts: [], frames: fs)
}

// MARK: 3. Faceless reels

/// `count` grey 12×8 frames of one level each, a 4×4 block at `x(i)` when given.
private func frames(_ levels: [UInt8], block: ((Int) -> Int)? = nil) -> [[UInt8]] {
    levels.enumerated().map { i, level in
        var f = [UInt8](repeating: level, count: 12 * 8)
        if let x = block?(i) { for y in 2..<6 { for dx in 0..<4 where x + dx < 12 { f[y * 12 + x + dx] = 255 } } }
        return f
    }
}

@Test func aStillStretchLongerThanTheLimitIsFoundAndAMovingTitleOnAStillIsMotion() {
    // 4 fps: 3 s of the same frame between moving parts.
    let moving = (0..<4).map { UInt8(40 * $0) }
    let still3 = frames(moving + [UInt8](repeating: 200, count: 13) + moving)
    let found = RuleCheck.stillStretches(still3, fps: 4, limit: 2)
    #expect(found.count == 1 && abs(found[0].seconds - 3) < 1e-9 && abs(found[0].start - 1) < 1e-9, "\(found)")
    let still15 = frames(moving + [UInt8](repeating: 200, count: 7) + moving)
    #expect(RuleCheck.stillStretches(still15, fps: 4, limit: 2).isEmpty)
    // The same still image for 4 s with a title sliding across it: motion.
    let titled = frames([UInt8](repeating: 90, count: 17), block: { $0 % 8 })
    #expect(RuleCheck.stillStretches(titled, fps: 4, limit: 2).isEmpty)
    // At 30 fps the check looks at every 7th or 8th frame (4 a second).
    let still30 = frames([UInt8](repeating: 10, count: 120))
    #expect(RuleCheck.stillStretches(still30, fps: 30, limit: 2).first.map { $0.seconds > 3.5 } == true)
}

/// A voice-over video of two 3 s pictures cut at 3 s on V1, exported (a scratch file stands for the render), its frames
/// from `pictures` at 4 fps.
private func facelessEngine(_ pictures: [[UInt8]]) throws -> Engine {
    let e = try measuringEngine { s in s.frames = FixedFrames(frames: pictures) }
    try e.execute("project.setKind", params: ["kind": "voice-over-video"])
    try e.execute("timeline.trim", params: ["clipId": "c1", "edge": "end", "to": 3])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 3, "sourceOut": 6, "start": 3])
    let out = tempDir().appendingPathComponent("out.mp4")
    try e.execute("export.render", params: ["path": .string(out.path), "exportAnyway": true])
    return e
}

struct FixedFrames: FrameSampler {
    var frames: [[UInt8]]
    func greyFrames(of video: URL, width: Int, height: Int) throws -> [[UInt8]] { frames }
}

@Test func twoSameFramesAcrossACutWarnAndDifferentOnesDoNot() throws {
    // 30 fps frames as the render has them: frame 89 before the cut at 3 s, frame 90 after.
    let same = try facelessEngine(frames([UInt8](repeating: 100, count: 180)))
    let check = try same.execute("rules.check", params: ["language": "en"])
    let v = try #require(violations(check, "jump-cut").first, "\(check)")
    #expect(v["severity"] == "warn" && v["time"] == 3 && check["pass"] == true)
    let different = try facelessEngine(frames((0..<180).map { $0 < 90 ? 20 : 220 }))
    #expect(violations(try different.execute("rules.check"), "jump-cut").isEmpty)
}

@Test func theStillStretchCheckRunsOnTheRenderOfAFacelessReelOnly() throws {
    let e = try facelessEngine(frames([UInt8](repeating: 128, count: 180)))
    let check = try e.execute("rules.check", params: ["language": "en"])
    let v = try #require(violations(check, "still-stretch").first, "\(check)")
    #expect(v["severity"] == "warn" && v.value(at: "messageArgs.2") == 2)
    // A talking-head reel has neither check.
    let reel = try measuringEngine()
    let ids = try reel.execute("rules.check")["checks"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
    #expect(!ids.contains("still-stretch") && !ids.contains("jump-cut") && !ids.contains("voice-read-back") && ids.contains("reading-time"))
}

@Test func theVoiceReadBackReportsExactlyTheWordThatDiffers() throws {
    let script = "Oggi vi mostro come montare un reel in dieci minuti."
    let heard = [Word("Oggi", 0.1, 0.4), Word("vi", 0.45, 0.55), Word("mostro", 0.6, 0.9), Word("come", 0.95, 1.1),
                 Word("montare", 1.15, 1.5), Word("un", 1.55, 1.6), Word("rail", 1.65, 1.9), Word("in", 1.95, 2.0),
                 Word("dieci", 2.05, 2.3), Word("minuti.", 2.35, 2.8)]
    let d = VoiceReadBack.differences(script: script, heard: heard)
    #expect(d == [VoiceReadBack.Difference(heard: "rail", script: "reel", time: 1.65)], "\(d)")
    #expect(VoiceReadBack.differences(script: script, heard: heard.filter { $0.text != "rail" }) == [VoiceReadBack.Difference(heard: nil, script: "reel", time: 1.6)])

    // Through rules.check: a generated voice clip at 2 s, its words heard by the transcription stand-in.
    var fakes = FakeServices()
    fakes.words = heard
    var project = Project(name: "vo")
    project.kind = "voice-over-video"
    let path = fakeMedia("voice.wav")
    project.assets = [MediaAsset(id: "a1", name: "voice.wav", path: path, duration: t(3), video: nil, audio: AudioInfo(sampleRate: 48000, channels: 1, codec: "pcm"),
                                 generated: GenerationInfo(provider: "voxcpm", model: "test", kind: .voice, prompt: script, seed: nil, cost: 0, unit: "",
                                                           created: "", jobID: "j1", requestHash: "h1"))]
    var track = Track(id: "t1", kind: .audio, name: "Voce")
    track.clips = [Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: t(3), start: t(2))]
    project.tracks = [track]
    let e = Engine(scratch: project, services: fakes.make())
    let check = try e.execute("rules.check", params: ["language": "en"])
    let found = violations(check, "voice-read-back")
    #expect(found.count == 1 && found.first?["severity"] == "warn", "\(check)")
    #expect(found.first?.value(at: "messageArgs.0") == "rail" && found.first?.value(at: "messageArgs.1") == "reel" && found.first?["time"]?.doubleValue.map { abs($0 - 3.67) < 0.04 } == true)
    #expect(found.first?["message"]?.stringValue?.contains("voice.lexicon") == true)

    // Without a transcription engine: not checked.
    fakes.words = heard
    var none = fakes.make()
    none.transcribers = [WhisperCppTranscriber.engineID: FakeTranscriber(words: heard, reason: "no model")]
    none.tier = .base
    let off = try Engine(scratch: project, services: none).execute("rules.check")
    #expect(row(off, "voice-read-back")?["ran"] == false && violations(off, "voice-read-back").isEmpty)
}
