import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RegistaCore

// #111: a transparent VP9 .webm keeps its alpha with the ffmpeg a release build ships (libvpx's VP9 decoder: ffmpeg's own
// drops the alpha plane). The sample is made here: two 16×16 frames at 30 fps of half-transparent red (653 bytes, made with an
// ffmpeg that has libvpx's encoder; the shipped one only decodes).

/// The sample, base64 (VP9 profile 0, yuva420p, alpha_mode 1).
private let sampleBase64 = "GkXfo59ChoEBQveBAULygQRC84EIQoKEd2VibUKHgQJChYECGFOAZwEAAAAAAAJdEU2bdLpNu4tTq4QVSalmU6yBoU27i1OrhBZUrmtTrIHWTbuMU6uEElTDZ1OsggE2TbuMU6uEHFO7a1OsggJH7AEAAAAAAABZAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAVSalmsCrXsYMPQkBNgIxMYXZmNjMuMS4xMDJXQYxMYXZmNjMuMS4xMDJEiYhAUIAAAAAAABZUrmvbrgEAAAAAAABS14EBc8WIbUmAu8zDZEScgQAitZyDdW5kiIEAhoVWX1ZQOYOBASPjg4QB/KBV4JSwgRC6gRCagQJTwIEBVbCEVbmBAVXugQHsAQAAAAAAAAIAABJUw2f+c3OfY8CAZ8iZRaOHRU5DT0RFUkSHjExhdmY2My4xLjEwMnNz2WPAi2PFiG1JgLvMw2REZ8ikRaOHRU5DT0RFUkSHl0xhdmM2My4xLjEwMiBsaWJ2cHgtdnA5Z8ihRaOIRFVSQVRJT05Eh5MwMDowMDowMC4wNjYwMDAwMDAAH0O2dUCI54EAoNChrIEAAACCSYNCAADwAPYAOCQcGEIAADBwAABKp//7kIG///8ICD////uJhwAAdaGfpp3ugQGlmIJJg0IAAPAA9gA4JBwYQgAAMGAAAEJwAKCxoZOBACEAhgBAkpwASUAAAyAAAEJAdaGWppTugQGlj4YAQJKcAElAAAMgAABCQPuB3xxTu2uRu4+zgQC3iveBAfGCAbnwgQM="

/// The helpers a check gave (`REGISTA_HELPERS`: scripts/build-engines.sh's output), nil otherwise.
private var helpers: URL? { ShippedTools.directory.flatMap { ShippedTools.path("ffmpeg", in: $0) != nil ? $0 : nil } }

@Test(.enabled(if: helpers != nil, "needs REGISTA_HELPERS pointing at scripts/build-engines.sh's output"))
func aTransparentWebmKeepsItsAlphaWithTheShippedFFmpeg() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-webm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let webm = dir.appendingPathComponent("alpha.webm")
    try #require(Data(base64Encoded: sampleBase64)).write(to: webm)
    let h = try #require(helpers)
    var config = EngineConfig()
    #expect(config.ffmpeg == h.appendingPathComponent("ffmpeg").path, "the shipped ffmpeg is the one used")
    config.cacheDirectory = dir.appendingPathComponent("cache").path
    var s = FakeServices().make()
    s.config = config
    let e = Engine(prober: FFProbe(executable: h.appendingPathComponent("ffprobe")), services: s)
    try e.execute("project.new", params: ["name": "webm", "directory": .string(dir.path)])
    let r = try e.execute("overlay.add", params: ["path": .string(webm.path), "start": 0])
    let asset = try #require(e.project?.assets.first { $0.path.hasSuffix("alpha.webm") }, "\(r)")
    #expect(asset.video?.alpha == true)
    let seq = try #require(asset.image, "not decoded to frames")
    let frame = URL(fileURLWithPath: String(format: seq.path, seq.first))
    let src = try #require(CGImageSourceCreateWithURL(frame as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = try #require(CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    ctx.draw(image, in: CGRect(x: -8, y: -8, width: 16, height: 16))
    #expect(px[3] > 100 && px[3] < 160, "alpha \(px[3]): the frame is not half transparent")
}

/// With an ffmpeg that has no libvpx (a developer's build), the import says what to do instead of ffmpeg's own error.
@Test func aWebmWithoutLibvpxSaysWhatToDo() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-webm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let stub = dir.appendingPathComponent("ffmpeg")
    try Data("#!/bin/sh\necho \"Unknown decoder 'libvpx-vp9'\" >&2\nexit 1\n".utf8).write(to: stub)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    let webm = dir.appendingPathComponent("alpha.webm")
    try #require(Data(base64Encoded: sampleBase64)).write(to: webm)
    var s = FakeServices().make()
    s.config.ffmpeg = stub.path
    let e = Engine(prober: FakeProber(), services: s)
    try e.execute("project.new", params: ["name": "webm", "directory": .string(dir.path)])
    #expect { try e.execute("overlay.add", params: ["path": .string(webm.path), "start": 0, "alpha": true]) } throws: {
        "\($0)".contains("export it as a .mov with alpha")
    }
}
