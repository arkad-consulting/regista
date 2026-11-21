import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import RegistaCore
@testable import RegistaEngines

/// A stereo 48 kHz float WAV of `seconds` (a quiet 220 Hz tone): stands in for a voice.say voice-over and its mix.
func syntheticVoice(seconds: Double) throws -> URL {
    let url = TemporaryFolder.url.appendingPathComponent("regista-voice-\(UUID().uuidString).wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    let n = AVAudioFrameCount(seconds * 48_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
    buffer.frameLength = n
    for ch in 0..<2 {
        let p = buffer.floatChannelData![ch]
        for i in 0..<Int(n) { p[i] = 0.2 * Float(sin(2 * Double.pi * 220 * Double(i) / 48_000)) }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    return url
}

/// A voice-only project (Inizio › Video senza volto before any picture): one audio clip and captions on it.
func voiceOnlyProject(_ voice: URL, seconds: Double, width: Int = 1080, height: Int = 1920) -> Project {
    var p = Project(name: "faceless", settings: ProjectSettings(width: width, height: height))
    p.assets = [MediaAsset(id: "a1", name: "voice", path: voice.path, duration: MediaTime(seconds: seconds), video: nil,
                           audio: AudioInfo(sampleRate: 48_000, channels: 2, codec: "pcm_f32le"))]
    var a = Track(id: "t1", kind: .audio, name: "Voce")
    a.clips = [Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: MediaTime(seconds: seconds), start: .zero)]
    let words: [(text: String, start: MediaTime, end: MediaTime)] = [("una", .zero, MediaTime(seconds: 0.5)), ("voce", MediaTime(seconds: 0.6), MediaTime(seconds: 1.2))]
    var caps = Track(id: "t2", kind: .caption, name: "C1")
    caps.captions = Captions(style: .talkingHeadV1, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "",
                             chunks: CaptionBuilder.build(words: words, style: .talkingHeadV1, keywords: [], fixes: [:]))
    p.tracks = [a, caps]
    p.idCounters = ["a": 1, "t": 2, "c": 1]
    return p
}

/// #72: a project with only a voice exports an mp4 with a video stream of the project size and the voice's duration,
/// drawn on the kit's surface colour (no kit: black), captions included.
@Test func voiceOnlyProjectExportsBackgroundCaptionsAndAudio() throws {
    let seconds = 2.0
    let voice = try syntheticVoice(seconds: seconds)
    defer { try? FileManager.default.removeItem(at: voice) }
    var p = voiceOnlyProject(voice, seconds: seconds)
    p.brand = BrandKit.arkad   // surface #14100A
    let job = RenderJob(project: p, preset: .named(nil, project: p))
    #expect(job.background == "#14100A")
    let out = TemporaryFolder.url.appendingPathComponent("regista-faceless-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    let report = try AVRenderer().export(job, audio: voice, to: out, bitrate: 4_000_000)
    #expect(report.frames == 60)
    let asset = AVURLAsset(url: out)
    let video = try #require(VisionFaceTracker.load({ try await asset.loadTracks(withMediaType: .video) })?.first)
    #expect(VisionFaceTracker.load({ try await video.load(.naturalSize) }) == CGSize(width: 1080, height: 1920))
    let audio = VisionFaceTracker.load({ try await asset.loadTracks(withMediaType: .audio) }) ?? []
    #expect(audio.count == 1)
    let duration = VisionFaceTracker.load({ try await asset.load(.duration) })?.seconds ?? 0
    #expect(abs(duration - seconds) < 0.05)

    // The frames: the surface colour in a corner, the caption drawn at 0.3 s (bright pixels in the caption band).
    let images = try AVRenderer().renderImages(job, at: [MediaTime(seconds: 0.3), MediaTime(seconds: 1.8)])
    let (r, g, b) = rgb(images[0], 20, 20)
    #expect(abs(r - 0x14) <= 3 && abs(g - 0x10) <= 3 && abs(b - 0x0A) <= 3)
    #expect(brightPixels(images[0]) > 500)
    #expect(brightPixels(images[1]) == 0)   // after the last word: background only

    // No kit, no background: black.
    #expect(RenderJob(project: voiceOnlyProject(voice, seconds: seconds), preset: .vertical).background == nil)
}

/// Pixel (x, y from the top) of an image as 8-bit RGB.
func rgb(_ img: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
    let px = rgbaBytes(img)
    let o = (y * img.width + x) * 4
    return (Int(px[o]), Int(px[o + 1]), Int(px[o + 2]))
}

func rgbaBytes(_ img: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return data
}

func brightPixels(_ img: CGImage) -> Int {
    let px = rgbaBytes(img)
    var n = 0
    for i in stride(from: 0, to: px.count, by: 4) where Int(px[i]) + Int(px[i + 1]) + Int(px[i + 2]) > 600 { n += 1 }
    return n
}
