import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RegistaCore
@testable import RegistaEngines

// The export shows what the preview shows (#30): after the full-frame camera is moved and shrunk by hand (clip.place),
// a frame rendered by the compositor has the picture exactly where the canvas element says it is.

/// The box [x, y, w, h] of the pixels of a rendered PNG that are clearly blue (the synthetic clip's colour).
private func blueBox(_ png: URL) throws -> [Double] {
    let src = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
    let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    let w = img.width, h = img.height
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var x0 = w, y0 = h, x1 = -1, y1 = -1
    for y in 0..<h {
        for x in 0..<w where p[(y * w + x) * 4 + 2] > 120 && p[(y * w + x) * 4] < 60 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
    }
    return [Double(x0), Double(y0), Double(x1 - x0 + 1), Double(y1 - y0 + 1)]
}

@Test func aFullFramePictureMovedByHandIsRenderedWhereTheCanvasSaysItIs() throws {
    let clip = try syntheticClip()
    defer { try? FileManager.default.removeItem(at: clip) }
    let e = Engine(scratch: project(clip), services: .live())
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-grab-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let t = MediaTime(seconds: 0.5)
    let full = dir.appendingPathComponent("full.png"), moved = dir.appendingPathComponent("moved.png")
    try AVRenderer().renderFrames(RenderJob(project: e.project!, preset: .vertical), at: [t], to: [full])
    let whole = try blueBox(full)
    // (the top row mixes with the red half just above the crop in the H.264 picture)
    #expect(zip(whole, [0.0, 0, 1080, 1920]).allSatisfy { abs($0 - $1) <= 2 }, "\(whole)")
    try e.execute("clip.place", params: ["clipId": "c1", "dx": 180, "dy": 300, "scale": 0.5])
    let el = try #require(CanvasLayout.elements(e.project!, at: t, renderer: AVRenderer()).first { $0.clipID == "c1" })
    #expect(el.kind == .picture)
    #expect(zip(el.box, [450.0, 780, 540, 960]).allSatisfy { abs($0 - $1) < 1e-6 }, "\(el.box)")
    try AVRenderer().renderFrames(RenderJob(project: e.project!, preset: .vertical), at: [t], to: [moved])
    let drawn = try blueBox(moved)
    for i in 0..<4 { #expect(abs(drawn[i] - el.box[i]) <= 2, "rendered \(drawn), canvas \(el.box)") }
    // The background shows around it.
    let corner = try pixel(moved, 40, 40)
    #expect(corner.0 < 20 && corner.1 < 20 && corner.2 < 20)
}
