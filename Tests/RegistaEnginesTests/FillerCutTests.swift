import Foundation
import Testing
@testable import RegistaCore
@testable import RegistaEngines

// #59: removing filler words leaves no click. The sound of a cut made by transcript.deleteWords (the ranges
// transcript.fillers gives) is mixed by ffmpeg as an export mixes it, and the samples around each cut are measured: with
// edit.autoCut's 15 ms fades the wave goes to silence on both sides of the cut, without them it jumps.

private let rate = 48000
private let tone = 227.0   // not a whole number of cycles per frame: a cut on the frame grid lands mid-wave

/// A 4 s stereo sine at half amplitude.
private func toneFile() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-fillercut-\(UUID().uuidString).wav")
    let samples = (0..<(4 * rate)).flatMap { n -> [Float] in
        let x = Float(0.5 * sin(2 * Double.pi * tone * Double(n) / Double(rate)))
        return [x, x]
    }
    try WAVAudio(sampleRate: rate, channels: 2, samples: samples).write16(to: url)
    return url
}

/// The tone as a take whose transcript says «allora ehm oggi parliamo di di lavoro», on one sound clip with `fades`.
private func take(_ file: URL, fades: Double) -> Project {
    var p = Project(name: "fillers")
    let words = [("allora", 0.20, 0.50), ("ehm", 0.62, 1.03), ("oggi", 1.11, 1.40), ("parliamo", 1.48, 1.90),
                 ("di", 2.00, 2.10), ("di", 2.17, 2.27), ("lavoro", 2.33, 2.80)]
    var a = MediaAsset(id: "a1", name: "take", path: file.path, duration: MediaTime(seconds: 4), video: nil,
                       audio: AudioInfo(sampleRate: rate, channels: 2, codec: "pcm_s16le"))
    a.analysis = AssetAnalysis(transcript: Transcript(engine: "test", model: "test", language: "it",
                                                      words: words.map { Word(text: $0.0, start: MediaTime(seconds: $0.1), end: MediaTime(seconds: $0.2)) }))
    p.assets = [a]
    var track = Track(id: "t1", kind: .audio, name: "A1")
    var c = Clip(id: "c1", assetID: "a1", sourceIn: MediaTime(seconds: 0.1), sourceOut: MediaTime(seconds: 3.0), start: .zero)
    if fades > 0 { c.fadeIn = MediaTime(seconds: fades); c.fadeOut = MediaTime(seconds: fades) }
    track.clips = [c]
    p.tracks = [track]
    p.idCounters = ["a": 1, "t": 1, "c": 1]
    return p
}

/// The fillers of the take removed as transcript.fillers says, mixed: the largest step between two samples within 1 ms of
/// each cut, and the largest level within 0.5 ms of it.
private func cuts(fades: Double) throws -> [(step: Float, level: Float)] {
    let file = try toneFile()
    defer { try? FileManager.default.removeItem(at: file) }
    let e = Engine(scratch: take(file, fades: fades), services: .live())
    let found = try e.execute("transcript.fillers")
    #expect(found["fillers"]?.arrayValue?.map { $0["text"] } == ["allora", "ehm", "di"])
    let ranges = (found.value(at: "delete.sure.ranges")?.arrayValue ?? []) + (found.value(at: "delete.repeat.ranges")?.arrayValue ?? [])
    try e.execute("transcript.deleteWords", params: ["ranges": .array(ranges)])
    let clips = e.project!.tracks[0].clips
    #expect(clips.count == 3 && e.project!.tracks[0].clips.allSatisfy { $0.fadeIn?.seconds ?? 0 == fades })
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("regista-fillercut-mix-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: out) }
    let length = Int((e.project!.duration.seconds * Double(rate)).rounded())
    try FFmpegAudio(config: EngineConfig()).mix(AudioPlan.clips(e.project!, rate: rate), length: length, rate: rate, ceiling: 0, to: out)
    let mix = try WAVAudio.read(out)
    let left = stride(from: 0, to: mix.samples.count, by: mix.channels).map { mix.samples[$0] }
    return clips.dropFirst().map { c in
        let k = Int((c.start.seconds * Double(rate)).rounded())
        let near = (k - rate / 1000)...(k + rate / 1000)
        let step = near.map { abs(left[$0] - left[$0 - 1]) }.max() ?? 0
        let level = ((k - rate / 2000)...(k + rate / 2000)).map { abs(left[$0]) }.max() ?? 0
        return (step, level)
    }
}

@Test func removedFillersLeaveNoClickAtTheCuts() throws {
    // The tone's own largest step between two samples: 2π·227/48000·0.5 ≈ 0.015.
    let natural = Float(2 * Double.pi * tone / Double(rate) * 0.5)
    let faded = try cuts(fades: 0.015)
    #expect(faded.count == 2)
    for c in faded {
        #expect(c.step <= natural * 1.5, "a click at a cut: a step of \(c.step) (the tone's own: \(natural))")
        #expect(c.level < 0.05, "the sound does not fade out at the cut: \(c.level)")
    }
    // The same cuts without fades: the measure sees the jump.
    let hard = try cuts(fades: 0)
    #expect(hard.contains { $0.step > 0.1 }, "no jump measured without fades: \(hard)")
}
