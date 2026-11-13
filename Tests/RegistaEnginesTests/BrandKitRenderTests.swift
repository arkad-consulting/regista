import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RegistaCore
@testable import RegistaEngines

/// RGBA of a PNG, top-left origin.
private func pixels(_ url: URL) throws -> (width: Int, height: Int, data: [UInt8]) {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
    data.withUnsafeMutableBytes { buf in
        let c = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return (img.width, img.height, data)
}

/// No user kits (#18): kits are looked up by id, and the folder of the person running the suite must not change the result.
private let emptyKitsFolder: URL = {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("regista-brand-kits-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    setenv("REGISTA_BRANDKITS", d.path, 1)
    return d
}()

private func scratch() -> URL {
    _ = emptyKitsFolder
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("regista-brand-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A logo-like SVG with explicit width/height (as design tools export it): a gold userSpaceOnUse gradient on the left
/// half, a solid square on the right half, transparent elsewhere.
private let logoSVG = """
<svg xmlns="http://www.w3.org/2000/svg" width="200px" height="100px" viewBox="0 0 200 100">
  <defs><linearGradient id="g" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="100" y2="0">
    <stop offset="0" stop-color="#FF0000"/><stop offset="1" stop-color="#0000FF"/></linearGradient></defs>
  <rect x="0" y="0" width="100" height="100" fill="url(#g)"/>
  <rect x="120" y="20" width="60" height="60" fill="#00FF00"/>
</svg>
"""

@Test func svgLogosRasteriseSharplyAtAnySizeHeadless() throws {
    let dir = scratch()
    let svg = dir.appendingPathComponent("logo.svg")
    try logoSVG.write(to: svg, atomically: true, encoding: .utf8)
    for width in [64, 600, 2400] {
        let out = dir.appendingPathComponent("logo-\(width).png")
        let size = try CGImageToolkit().rasterizeSVG(svg, width: width, to: out)
        #expect(size.width == width && size.height == width / 2)
        let p = try pixels(out)
        #expect(p.width == width && p.height == width / 2)
        func at(_ fx: Double, _ fy: Double) -> [Int] {
            let i = (Int(fy * Double(p.height)) * p.width + Int(fx * Double(p.width))) * 4
            return (0..<4).map { Int(p.data[i + $0]) }
        }
        // The gradient follows the drawing: red at the left edge, blue near the middle (it used to stay at 200 px).
        let left = at(0.02, 0.5), mid = at(0.48, 0.5)
        #expect(left[0] > 200 && left[2] < 60, "\(width): left \(left)")
        #expect(mid[2] > 180 && mid[0] < 80, "\(width): mid \(mid)")
        #expect(at(0.75, 0.5)[1] > 240 && at(0.75, 0.05)[3] == 0)        // green square; transparent above it
        // Sharp: across the square's left edge (x = 120/200), at most 2 partly covered pixels per row.
        let y = p.height / 2, x0 = Int(0.55 * Double(p.width)), x1 = Int(0.65 * Double(p.width))
        let partial = (x0..<x1).filter { x in let a = p.data[(y * p.width + x) * 4 + 3]; return a > 10 && a < 245 }.count
        #expect(partial <= 2, "\(width): \(partial) soft pixels on the edge")
    }
    // Normalisation keeps an SVG without width/height as it is, and drops them otherwise (viewBox kept).
    let plain = Data(#"<svg viewBox="0 0 10 10"><rect width="10" height="10"/></svg>"#.utf8)
    #expect(CGImageToolkit.normalizedSVG(plain) == plain)
    let fixed = String(decoding: CGImageToolkit.normalizedSVG(Data(#"<svg width="40" height="20"><rect stroke-width="2" width="4" height="2"/></svg>"#.utf8)), as: UTF8.self)
    #expect(fixed.contains(#"viewBox="0 0 40.0 20.0""#) && !fixed.contains(#"<svg viewBox="0 0 40.0 20.0" width"#) && fixed.contains(#"stroke-width="2" width="4""#))
}

@Test func kitPreviewDrawsTheKeywordBoxInTheKitHighlight() throws {
    let e = Engine(services: .live())
    let dir = scratch()
    for kit in [BrandKit.arkad, .wesites, .cafeAtelier] {
        let out = dir.appendingPathComponent("\(kit.id).png")
        let r = try e.execute("brandkit.preview", params: ["kit": .string(kit.id), "path": .string(out.path), "width": 540])
        #expect(r["width"] == 540 && r["height"] == 960)
        let p = try pixels(out)
        // The keyword ("BRAND") box: the most frequent saturated colour in the caption band equals the highlight.
        let band = (Int(1244.0 / 1920 * 960)..<Int(1444.0 / 1920 * 960))
        var counts: [String: Int] = [:]
        for y in band { for x in stride(from: 0, to: p.width, by: 2) {
            let i = (y * p.width + x) * 4
            let (r, g, b) = (Int(p.data[i]), Int(p.data[i + 1]), Int(p.data[i + 2]))
            if max(r, g, b) - min(r, g, b) > 60 { counts[String(format: "#%02X%02X%02X", r, g, b), default: 0] += 1 }
        } }
        let top = try #require(counts.max { $0.value < $1.value }?.key)
        let want = BrandKit.rgb(kit.colors["highlight"]!), got = BrandKit.rgb(top)
        #expect(zip(want, got).allSatisfy { abs($0 - $1) <= 6 }, "\(kit.id): \(top) vs \(kit.colors["highlight"]!)")
    }
}
