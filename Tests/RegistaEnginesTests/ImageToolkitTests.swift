import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RegistaCore
@testable import RegistaEngines

/// A 1080×1920 PNG: top half red, bottom half blue.
private func framePNG(in dir: URL, _ name: String) throws -> URL {
    let c = try CGImageToolkit.context(1080, 1920)
    c.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 1080, height: 960))
    c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 960, width: 1080, height: 960))
    let url = dir.appendingPathComponent(name)
    try CaptionRasterizer.writePNG(c.makeImage()!, to: url)
    return url
}

private func jpegSize(_ url: URL) throws -> (Int, Int, String?) {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    return (image.width, image.height, CGImageSourceGetType(src) as String?)
}

@Test func previewsAndContactSheetsAreDownscaledJPEGs() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-img-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let tk = CGImageToolkit()
    let png = try framePNG(in: dir, "f.png")

    let preview = dir.appendingPathComponent("p.jpg")
    let size = try tk.writePreview(of: png, maxWidth: 540, maxHeight: 2160, to: preview)
    #expect(size == (540, 960))
    let (w, h, type) = try jpegSize(preview)
    #expect(w == 540 && h == 960 && type == "public.jpeg")
    let pixels = try CGImageToolkit.load(preview).dataProvider!.data! as Data
    #expect(pixels[0] > 200 && pixels[2] < 50)   // top-left is still red: not flipped

    let frames = try (0..<12).map { try framePNG(in: dir, "f\($0).png") }
    let sheet = dir.appendingPathComponent("s.jpg")
    let s = try tk.writeContactSheet(frames, labels: frames.indices.map { "\($0).00 s" }, maxWidth: 1600, maxHeight: 1600, to: sheet)
    let (sw, sh, stype) = try jpegSize(sheet)
    #expect(sw == s.width && sh == s.height && stype == "public.jpeg")
    #expect(sw <= 1600 && sh <= 1600)
    // 12 tall frames get the largest cells in 4 columns × 3 rows (275 px wide, vs 257 px in 6 × 2).
    #expect(sw == 5 * 8 + 4 * 275 && sh > 1500)
    #expect(throws: CommandError.self) { try tk.writeContactSheet([], labels: [], maxWidth: 100, maxHeight: 100, to: sheet) }
}
