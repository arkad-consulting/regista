import Foundation
import Testing
@testable import RegistaCore

// MARK: Pure helpers

@Test func italianNumbersAndTokens() {
    #expect(TextNorm.numbersToWords("9,2 su 10, nel 2025 più di 11.000 e 21, 108, 3,05")
        == "nove virgola due su dieci, nel duemilaventicinque più di undicimila e ventuno, centotto, tre virgola zero cinque")
    #expect(TextNorm.tokens("PHP, il motore ha chiuso d'urgenza. Mercoledì all’IA")
        == ["php", "il", "motore", "ha", "chiuso", "d", "urgenza", "mercoledi", "all", "ia"])
    #expect(TextNorm.integerWords(1_000_000) == "un milione")
}

@Test func similarityMatchesDifflib() {
    // Reference values from Python's difflib.SequenceMatcher(None, a, b).ratio().
    let cases: [(String, String, Double)] = [("chiede", "chiedi", 0.8333333333333334), ("abcd", "bcde", 0.75), ("alia", "ia", 0.6666666666666666),
                                             ("aggiornate", "aggiornati", 0.9), ("tenere", "tenerli", 0.7692307692307693),
                                             ("abab", "baba", 0.75), ("wordpress", "word", 0.6153846153846154), ("abc", "xyz", 0)]
    for (a, b, r) in cases { #expect(abs(SequenceSimilarity.ratio(a, b) - r) < 1e-12, "\(a)/\(b)") }
}

@Test func scriptParsing() {
    let md = """
    # Title
    Intro 1. not a line
    ## Testo (una riga = una ripresa)

    1. Prima riga.
    2) Seconda riga, con virgola.
    ## Hook alternativi
    3. Not in the script.
    """
    #expect(Script.parse(md).lines == ["Prima riga.", "Seconda riga, con virgola."])
    #expect(Script.parse("Ciao a tutti.\n\nSeconda frase.\n").lines == ["Ciao a tutti.", "Seconda frase."])
}

@Test func wavRoundTripAndEnvelope() throws {
    let url = tempDir().appendingPathComponent("s.wav")
    try syntheticSpeech([(1.0, 2.0), (3.0, 4.5)], duration: 6).write16(to: url)
    let wav = try WAVAudio.read(url)
    #expect(wav.sampleRate == 16000 && wav.channels == 1 && wav.frameCount == 96000)
    let env = try Envelope.read(url)
    #expect(env.db.count == 600)
    let (thr, floor) = env.speechThreshold()
    #expect(floor < -55 && thr < -40)
    let gaps = env.silences(below: thr, minLength: 0.25)
    #expect(gaps.count == 3)
    #expect(abs(gaps[1].start - 2.0) < 0.011 && abs(gaps[1].end - 3.0) < 0.011)
    #expect(abs(env.onset(near: 1.1, threshold: thr) - 1.0) < 0.011)
    #expect(abs(env.offset(near: 1.95, threshold: thr) - 2.0) < 0.011)
    // A word ending inside the silence is pulled back to where the silence starts.
    let clamped = WhisperCppTranscriber.clampEnds([Word("a", 1.2, 2.8), Word("b", 3.1, 3.4)], env)
    #expect(abs(clamped[0].end.seconds - 2.0) < 0.011)
    #expect(clamped[1].end == MediaTime(seconds: 3.4))
}

@Test func timingEvaluationAtPauses() throws {
    let wav = syntheticSpeech([(1.0, 2.0), (3.0, 4.5)], duration: 6)
    let env = Envelope(samples: wav.samples, sampleRate: 16000)
    let good = TimingEvaluation.evaluate(words: [Word("a", 1.0, 2.0), Word("b", 3.05, 4.5)], envelope: env)
    #expect(good.pauses == 1)
    #expect(good.starts.within100 == 1 && good.starts.medianMs == 50)
    let late = TimingEvaluation.evaluate(words: [Word("a", 1.0, 2.3), Word("b", 3.3, 4.5)], envelope: env)
    #expect(late.starts.within100 == 0 && late.ends.medianMs == 300)
}

@Test func syncCheckFindsAShift() {
    let rate = 48000
    let speech = syntheticSpeech([(0.5, 1.5), (2.0, 3.5)], duration: 4, rate: rate).samples
    let shift = 480   // 10 ms late
    let late = [Float](repeating: 0, count: shift) + speech.dropLast(shift)
    let r = SyncCheck.lag(original: speech, processed: late, sampleRate: rate, windows: [(0.6, 1.4), (2.2, 3.2)])
    #expect(abs(r.lagSeconds - 0.010) < 0.0002)
    #expect(r.correlation > 0.9)
    let same = SyncCheck.lag(original: speech, processed: speech, sampleRate: rate, windows: [(0.6, 1.4)])
    #expect(same.lagSeconds == 0)
}

@Test func engineOutputsParse() throws {
    let wcpp = #"""
    {"transcription": [{"tokens": [
      {"text": "[_BEG_]", "offsets": {"from": 0, "to": 0}, "t_dtw": -1},
      {"text": " ti", "offsets": {"from": 0, "to": 300}, "t_dtw": 266},
      {"text": " sit", "offsets": {"from": 300, "to": 500}, "t_dtw": 270},
      {"text": "o", "offsets": {"from": 500, "to": 600}, "t_dtw": 320},
      {"text": ".", "offsets": {"from": 600, "to": 700}, "t_dtw": 500},
      {"text": " ,", "offsets": {"from": 700, "to": 710}, "t_dtw": 505}
    ]}]}
    """#
    let words = try WhisperCppTranscriber.parse(Data(wcpp.utf8))
    #expect(words.map(\.text) == ["ti", "sito."])
    #expect(words[0].start == MediaTime(seconds: 2.66) && words[0].end == MediaTime(seconds: 2.7))   // capped at "sito"
    #expect(words[1].end == MediaTime(seconds: 3.3))   // last spoken token "o" + 0.10, not the late "."

    let wx = #"{"words": [{"w": "Ti", "s": 2.662, "e": 2.703, "p": 0.3}, {"w": "9,2", "s": null, "e": null}]}"#
    let wxWords = try WhisperXTranscriber.parse(Data(wx.utf8))
    #expect(wxWords.count == 1 && wxWords[0].probability == 0.3)

    let log = """
    [Parsed_ebur128_3 @ 0x1] Summary:

      Integrated loudness:
        I:         -15.0 LUFS
        Threshold: -25.4 LUFS

      Loudness range:
        LRA:         1.8 LU
        Threshold: -35.3 LUFS

      True peak:
        Peak:       -2.0 dBFS
    """
    let l = try FFmpegAudio.parseEBUR128(log)
    #expect(l.integrated == -15 && l.truePeak == -2 && l.range == 1.8 && l.threshold == -25.4)
}

@Test func configAndTiers() throws {
    let file = tempDir().appendingPathComponent("engines.json")
    try Data(#"{"ffmpeg": "/usr/local/bin/ffmpeg", "tier": "base", "transcription": {"pro": "whisper.cpp"}}"#.utf8).write(to: file)
    let c = try EngineConfig.load(from: file)
    #expect(c.ffmpeg == "/usr/local/bin/ffmpeg")
    #expect(c.deepFilterSha256 == EngineConfig().deepFilterSha256)   // untouched keys keep their defaults
    #expect(MachineTier.pro.defaultTranscriber(c) == "whisper.cpp")
    #expect(MachineTier.medium.defaultTranscriber(EngineConfig()) == "whisperx")
    #expect(MachineTier.base.defaultTranscriber(EngineConfig()) == "whisper.cpp")
    let gb: UInt64 = 1 << 30
    #expect(MachineTier.detect(physicalMemory: 8 * gb) == .base)
    #expect(MachineTier.detect(physicalMemory: 16 * gb) == .medium)
    #expect(MachineTier.detect(physicalMemory: 32 * gb) == .pro)
    try Data("{nope".utf8).write(to: file)
    #expect(throws: CommandError.self) { try EngineConfig.load(from: file) }
}

@Test func oneEuroSmoothsAndResetsAtCuts() throws {
    var track = try FakeFaces().track(URL(fileURLWithPath: "/x.mov"), options: FaceTrackOptions())
    track.smooth()
    #expect(track.frames[10].smooth == track.frames[9].smooth)    // held through the missed detection
    #expect(track.frames[50].smooth?[0] == track.frames[50].raw?[0])   // reset at the cut: no lag carried over
    #expect(track.jitter(smoothed: false) > 10)
    #expect(track.jitter(smoothed: true) < track.jitter(smoothed: false) / 3)
}

@Test func scenarioBoundsAndRequires() throws {
    let check = ScenarioRunner.check
    #expect(check(.number(-15.2), ["min": -15.5, "max": -14.5]) == nil)
    #expect(check(.number(-1.4), ["max": -1.5]) != nil)
    #expect(check(.number(3), ["min": 4]) != nil)
    let s = try Scenario(json: ["requires": ["engines"], "steps": []])
    #expect(s.requires == ["engines"])
}

// MARK: Commands on fake engines

@Test func extractTranscribeAndCache() throws {
    let fakes = FakeServices()
    let e = try analysisEngine(fakes)
    let x = try e.checkUndoRedo("media.extractAudio", ["assetId": "a1"])
    #expect(x.value(at: "speech.sampleRate") == 16000)
    let audio = try #require(e.project?.assets[0].analysis?.audio)
    #expect(audio.speech.hasSuffix("an.regista/media/a1-speech16k.wav"))
    #expect(FileManager.default.fileExists(atPath: audio.working))

    let r = try e.checkUndoRedo("transcript.run", ["assetId": "a1"])
    #expect(r["engine"] == "whisperx")   // pro tier default
    #expect(r["words"] == 4 && r["cached"] == false)
    let again = try e.execute("transcript.run", params: ["assetId": "a1"])
    #expect(again["cached"] == true)

    let got = try e.execute("transcript.get", params: ["assetId": "a1", "from": 2.5])
    #expect(got["text"] == "tre quattro")
    let eval = try e.execute("transcript.evaluate", params: ["assetId": "a1"])
    #expect(eval["pauses"] == 1)
    #expect(eval.value(at: "starts.within100ms") == 1)
}

@Test func transcriptRunRespectsTiersAndAvailability() throws {
    var fakes = FakeServices()
    fakes.tier = .base
    let e = try analysisEngine(fakes)
    #expect(throws: CommandError.self) { try e.execute("transcript.run", params: ["assetId": "a1", "engine": "whisperx"]) }
    let r = try e.execute("transcript.run", params: ["assetId": "a1"])   // base default, extracts audio itself
    #expect(r["engine"] == "whisper.cpp")
    #expect(e.project?.assets[0].analysis?.audio != nil)
    #expect(throws: CommandError.self) { try e.execute("transcript.get", params: ["assetId": "a9"]) }
}

@Test func enginesStatusReportsTierAndEngines() throws {
    var fakes = FakeServices()
    fakes.tier = .base
    let e = Engine(prober: FakeProber(), services: fakes.make())
    let s = try e.execute("engines.status")
    #expect(s["tier"] == "base")
    let engines = try #require(s["engines"]?.arrayValue)
    let wx = try #require(engines.first { $0["id"] == "whisperx" })
    #expect(wx["minimumTier"] == "medium" && wx["enabled"] == false)
    #expect(engines.contains { $0["id"] == "vision" && $0["available"] == true })
    #expect(s.value(at: "defaults.transcription") == "whisper.cpp")
}

@Test func measureLoudnessOfAssetAndTrack() throws {
    let fakes = FakeServices()
    let e = try analysisEngine(fakes)
    try e.execute("track.add", params: ["kind": "audio"])
    #expect(throws: CommandError.self) { try e.execute("media.measureLoudness", params: ["trackId": "t1"]) }
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 1, "sourceOut": 2])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 5, "sourceOut": 7])
    let l = try e.execute("media.measureLoudness", params: ["trackId": "t1"])
    #expect(l["integrated"] == -15.1 && l["spans"] == 2)
    #expect(fakes.audio.spans.last?.map(\.start) == [t(1), t(5)])
    #expect(fakes.audio.spans.last?.first?.channels == 2)
    _ = try e.execute("media.measureLoudness", params: ["assetId": "a1"])
    #expect(fakes.audio.spans.last?.first?.start == nil)
}

@Test func audioCleanSwapsTheSourceKeepingRanges() throws {
    let fakes = FakeServices()
    let e = try analysisEngine(fakes)
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    for (a, b) in [(1.0, 2.0), (3.0, 4.4)] {
        let v = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": .number(a), "sourceOut": .number(b)])
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": .number(a), "sourceOut": .number(b),
                                                 "linkTo": v.value(at: "clip.id") ?? .null])
    }
    try e.execute("clip.set", params: ["trackId": "t2", "fadeIn": 0.015, "fadeOut": 0.015])
    let before = e.clips(1)
    let r = try e.checkUndoRedo("audio.clean", [:])
    #expect(r.value(at: "asset.id") == "a2")
    #expect(r.value(at: "sync.lagMs") == 0)
    #expect(r.value(at: "loudness.integrated") == -15.1)
    #expect(r["commands"]?.arrayValue?.first?["command"] == "timeline.delete")
    let after = e.clips(1)
    #expect(after.map(\.assetID) == ["a2", "a2"])
    #expect(after.map(\.sourceIn) == before.map(\.sourceIn) && after.map(\.start) == before.map(\.start))
    #expect(after.map(\.duration) == before.map(\.duration))
    // Links to the pictures and the edge fades survive the swap; the pictures stay.
    #expect(after.map(\.link) == e.clips(0).map(\.link) && after.allSatisfy { $0.fadeIn == t(0.015) && $0.fadeOut == t(0.015) })
    #expect(e.clips(0).count == 2)
    #expect(e.project?.asset("a2")?.origin == AssetOrigin(assetID: "a1", process: "audio.clean"))
    #expect(fakes.cleaner.requests.last?.attenuation == 18 && fakes.cleaner.requests.last?.targetLUFS == -15)
    // Cleaning again starts from the camera audio, not from the cleaned file.
    try e.execute("audio.clean", params: ["attenuation": 12])
    #expect(fakes.cleaner.requests.last?.input.lastPathComponent == "a1-work48k.wav")
    #expect(e.clips(1).map(\.assetID) == ["a3", "a3"])
}

@Test func facesTrackWritesASidecar() throws {
    let e = try analysisEngine()
    let r = try e.checkUndoRedo("faces.track", ["assetId": "a1"])
    #expect(r["frames"] == 100 && r["detected"] == 99 && r["cuts"] == 1)
    let summary = try #require(e.project?.assets[0].analysis?.faces)
    let saved = try JSONDecoder().decode(FaceTrack.self, from: Data(contentsOf: URL(fileURLWithPath: summary.path)))
    #expect(saved.frames.count == 100 && saved.frames[20].smooth != nil)
    #expect(summary.jitterPx < summary.rawJitterPx)
    let noFaces = Engine(prober: FakeProber(), services: { var s = FakeServices().make(); s.faces = nil; return s }())
    try noFaces.execute("project.new", params: ["name": "x"])
    try noFaces.execute("media.import", params: ["path": .string(fakeMedia())])
    #expect(throws: CommandError.self) { try noFaces.execute("faces.track", params: ["assetId": "a1"]) }
}
