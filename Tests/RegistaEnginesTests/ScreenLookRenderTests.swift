import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RegistaCore
@testable import RegistaEngines

// R2 #51 (#42 #43 #44) and #79 through the real compositor: a synthetic screen + camera session whose look the
// inspector's commands change — face layout, styled frame, drawn cursor, key badges, automatic zoom, output format —
// each change visible in the rendered frame and taken back by undo; and a picture fade drawn and exported.

/// A rendered PNG reduced to `w`×`h` RGB bytes (sRGB), for comparisons.
private func thumbnail(_ path: String, _ w: Int = 160, _ h: Int = 90) throws -> [UInt8] {
    let src = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
    let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    return draw(img, w, h)
}

private func draw(_ img: CGImage, _ w: Int, _ h: Int) -> [UInt8] {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    return (0..<(w * h)).flatMap { [p[$0 * 4], p[$0 * 4 + 1], p[$0 * 4 + 2]] }
}

/// Mean absolute difference per channel, 0…255.
private func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 255 }
    return Double(zip(a, b).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(a.count)
}

/// The largest channel difference of any pixel.
private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int { zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 255 }

private func mean(_ a: [UInt8]) -> Double { Double(a.reduce(0) { $0 + Int($1) }) / Double(max(a.count, 1)) }

private func frame(_ e: Engine, at t: Double, _ dir: URL, _ name: String) throws -> String {
    let r = try e.execute("frame.render", params: ["times": [.number(t)], "path": .string(dir.appendingPathComponent("\(name).png").path), "inline": false])
    return try #require(r.value(at: "frames.0.path")?.stringValue)
}

/// Runs blocking render work on a thread of its own and waits for it without holding one of the cooperative threads
/// for many seconds. (The renderer's bridges to AVFoundation's async loads no longer need a pool thread, #80; this only
/// keeps the long tests from slowing the async ones.)
private func offThePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in Thread { c.resume(with: Result { try body() }) }.start() }
}

private struct Look: Sendable {
    var split = 0.0, undo = 0.0, framed = 0.0, cornerBlue = 0, cornerRed = 0, cursor = 0.0
    var badge = 0.0, badgePeak = 0, zoom = 0.0, portrait = (0, 0)
}

@Test func theScreenLookControlsChangeTheRenderedFrameAndUndoRestoresIt() async throws {
    let m = try await offThePool { () throws -> Look in
        let dir = TemporaryFolder.url.appendingPathComponent("regista-screenlook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = Engine(prober: FFProbe(), services: .live())
        var m = Look()
        // The camera: a synthetic talking head; the session: screen + camera, recorded without the system cursor.
        try e.execute("project.new", params: ["name": "camera-take"])
        try e.execute("media.synthesize", params: ["path": .string(dir.appendingPathComponent("head.mov").path), "duration": 7])
        let synth = try e.execute("recording.synthesize", params: ["directory": .string(dir.appendingPathComponent("session").path),
                                                                   "camera": .string(dir.appendingPathComponent("head.mov").path),
                                                                   "sources": ["screen", "camera"], "duration": 6, "cursor": false])
        try e.execute("project.new", params: ["name": "screen-look", "width": 1920, "height": 1080])
        try e.execute("recording.import", params: ["path": .string(synth["session"]?.stringValue ?? ""), "layout": "bubble"])
        let at = 3.0
        let base = try thumbnail(try frame(e, at: at, dir, "base"))

        // Face layout: side by side, face on the left.
        try e.execute("layout.apply", params: ["preset": "split", "side": "left"])
        m.split = difference(base, try thumbnail(try frame(e, at: at, dir, "split")))
        try e.execute("history.undo")
        m.undo = difference(base, try thumbnail(try frame(e, at: at, dir, "undo")))

        // Styled frame on the dusk gradient: the corners of the frame are the background, not the screen.
        try e.execute("layout.apply", params: ["preset": "bubble", "background": "dusk", "padding": 0.1])
        let framed = try thumbnail(try frame(e, at: at, dir, "framed"))
        m.framed = difference(base, framed)
        (m.cornerRed, m.cornerBlue) = (Int(framed[0]), Int(framed[2]))

        // Drawn cursor four times bigger: a local change only.
        try e.execute("cursor.style", params: ["scale": 4, "hideWhenIdle": false])
        m.cursor = difference(framed, try thumbnail(try frame(e, at: at, dir, "cursor")))

        // Key badges: the ⌘S badge appears while it is shown.
        let keys = try e.execute("keys.overlay", params: ["allKeys": true])
        let badgeAt = (keys.value(at: "badges.0.start")?.doubleValue ?? 0) + 0.4
        let badge = try thumbnail(try frame(e, at: badgeAt, dir, "badge"))
        try e.execute("history.undo")
        let noBadge = try thumbnail(try frame(e, at: badgeAt, dir, "nobadge"))
        try e.execute("history.redo")
        (m.badge, m.badgePeak) = (difference(badge, noBadge), maxDifference(badge, noBadge))

        // Automatic zoom: at a click the screen is magnified.
        let zoom = try e.execute("edit.autoZoom", params: ["zoom": 2.2])
        let click = zoom.value(at: "clicks.0.time")?.doubleValue ?? 0
        let zoomed = try thumbnail(try frame(e, at: click + 0.05, dir, "zoom"))
        try e.execute("history.undo")
        let flat = try thumbnail(try frame(e, at: click + 0.05, dir, "nozoom"))
        try e.execute("history.redo")
        m.zoom = difference(zoomed, flat)

        // Output format 9:16: the frame is portrait and the layout is laid out again.
        try e.execute("project.format", params: ["preset": "9:16"])
        let portrait = try frame(e, at: at, dir, "portrait")
        if let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: portrait) as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            m.portrait = (img.width, img.height)
        }
        return m
    }
    #expect(m.split > 12)                                  // the face moved to the left, on a dark backdrop
    #expect(m.undo < 0.5)                                  // undo gives back the same frame
    #expect(m.framed > 8 && m.cornerBlue > m.cornerRed + 10)   // the corner is the dusk gradient
    #expect(m.cursor > 0.05 && m.cursor < 6)               // a bigger cursor: a local change
    #expect(m.badge > 0.05 && m.badgePeak > 60)            // the badge: small, but clearly there
    #expect(m.zoom > 8)                                    // magnified at the click
    #expect(m.portrait == (1080, 1920))
}

@Test func aPictureFadeIsDrawnAndExported() async throws {
    // Means of 16×16 thumbnails: frames at 0, 0.1 and 0.6 s, the export at 0.1, 0.6 and 0.95 s.
    let v = try await offThePool { () throws -> [Double] in
        let clip = try syntheticClip()
        defer { try? FileManager.default.removeItem(at: clip) }
        let e = Engine(scratch: project(clip), services: .live())
        try e.execute("clip.set", params: ["clipId": "c1", "pictureFadeIn": 0.5, "pictureFadeOut": 0.3])
        let dir = TemporaryFolder.url.appendingPathComponent("regista-fade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var out = try [0, 0.1, 0.6].map { mean(try thumbnail(try frame(e, at: $0, dir, "f\($0)"), 16, 16)) }
        let movie = dir.appendingPathComponent("fade.mp4")
        try e.execute("export.render", params: ["path": .string(movie.path)])
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        out += try [0.1, 0.6, 0.95].map { mean(draw(try gen.copyCGImage(at: CMTime(seconds: $0, preferredTimescale: 600), actualTime: nil), 16, 16)) }
        return out
    }
    // The clip shows all blue (its bottom half): black on the first frame, darker at the start, full in the middle.
    #expect(v[0] < 4 && v[2] > v[1] + 20)
    // The export carries the fade in and the fade out.
    #expect(v[4] > v[3] + 20 && v[5] < v[4] - 20)
}
