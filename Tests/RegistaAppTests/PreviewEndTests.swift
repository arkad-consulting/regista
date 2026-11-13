import AppKit
import Foundation
import Testing
@testable import Regista
@testable import RegistaCore
import RegistaEngines

/// #32: the player parks on the last frame that has a picture, and does not resume playing at the end after a rebuild.
@Test func previewParksOnTheLastFrameAndDoesNotResumeAtTheEnd() throws {
    let rate = Rational(30)
    // 33.97 s (a test reel) and 34 s both have 1020 frames: the last starts at 1019/30 s (33:29), the end time has none.
    #expect(RenderJob.lastFrame(duration: MediaTime(seconds: 33.97), rate: rate) == MediaTime(seconds: 1019.0 / 30))
    #expect(RenderJob.lastFrame(duration: MediaTime(seconds: 34), rate: rate) == MediaTime(seconds: 1019.0 / 30))
    #expect(RenderJob.lastFrame(duration: .zero, rate: rate) == .zero)
    let last = 1019.0 / 30
    // Playing at the end (the player stopped on the end time): parked on the last frame, not playing again.
    let atEnd = PreviewController.resume(at: 34, lastFrame: last, wasPlaying: true)
    #expect(atEnd.time == last && !atEnd.play)
    #expect(PreviewController.resume(at: last, lastFrame: last, wasPlaying: true).play == false)
    // In the middle: same time, plays on if it was playing.
    #expect(PreviewController.resume(at: 10, lastFrame: last, wasPlaying: true) == (10, true))
    #expect(PreviewController.resume(at: 10, lastFrame: last, wasPlaying: false) == (10, false))

    // The last frame has a picture (a red full-frame still), the end time does not exist as a frame.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-32-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = dir.appendingPathComponent("red.png")
    let ctx = CGContext(data: nil, width: 108, height: 192, bitsPerComponent: 8, bytesPerRow: 108 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 108, height: 192))
    try savePNG(ctx.makeImage()!, png)
    var p = Project(name: "end", settings: ProjectSettings(width: 108, height: 192))
    p.assets = [MediaAsset(id: "a1", name: "red", path: png.path, duration: ImageSource.stillDuration,
                           video: VideoInfo(width: 108, height: 192, frameRate: rate, codec: "png"), audio: nil, image: ImageSource(kind: .still, path: png.path))]
    var o = Track(id: "t1", kind: .overlay, name: "O1")
    o.clips = [Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: MediaTime(seconds: 1.5), start: .zero)]
    p.tracks = [o]
    let job = RenderJob(project: p, preset: .named(nil, project: p))
    let img = try #require(try AVRenderer().renderImages(job, at: [job.lastFrame]).first)
    let px = rgba(img)
    let mid = (96 * 108 + 54) * 4
    #expect(px[mid] > 200 && px[mid + 1] < 40, "last frame \(job.lastFrame.seconds) s is not the picture")
}
