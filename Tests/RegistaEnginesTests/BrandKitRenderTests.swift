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

/// No user kits (#18): kits are looked up by id, and the folder of the person running the suite must not change the
/// result. The same folder as RegistaCoreTests' `testKitsDirectory` (one per test process, named after the pid): the two
/// targets run in one process, and two different values of the variable made a kit command write where the other
/// target's test was not looking.
private let testKitsFolder: URL = {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("regista-tests-kits-\(ProcessInfo.processInfo.processIdentifier)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    setenv("REGISTA_BRANDKITS", d.path, 1)
    return d
}()

private func scratch() -> URL {
    _ = testKitsFolder
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

/// A PNG logo of `width`×`height`: a solid colour on the left half, transparent elsewhere.
private func pngLogo(_ url: URL, width: Int = 240, height: Int = 120, color: CGColor) throws {
    let c = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    c.setFillColor(color)
    c.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    let image = try #require(c.makeImage())
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

/// #101: a project holds the files of its kit. A user kit with a font file and a PNG logo, applied (one undo step); a logo
/// and a hook title added; the kit deleted, its folder with it: the files the project refers to are the project's own
/// (in its media folder) and still there, and the frame is the frame drawn before the delete — the kit's font, the kit's
/// logo. The same kit applied again uses the same copies.
@Test func aProjectHoldsTheFilesOfItsKitAndTheKitCanGo() throws {
    let dir = scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let e = Engine(services: .live())
    try e.execute("project.new", params: ["name": "holds-kit", "directory": .string(dir.path)])
    let head = try e.execute("media.synthesize", params: ["path": .string(dir.appendingPathComponent("head.mov").path), "duration": 4])
    let asset = try #require(head.value(at: "asset.id")?.stringValue)
    let v = try #require(try e.execute("track.add", params: ["kind": "video"]).value(at: "track.id")?.stringValue)
    try e.execute("timeline.place", params: ["assetId": .string(asset), "trackId": .string(v), "sourceIn": 0, "sourceOut": 4])

    // The kit's own files, chosen from a folder of the person's (a font file and a PNG logo).
    let mine = dir.appendingPathComponent("my-files")
    try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
    let font = mine.appendingPathComponent("ForneriaDisplay.ttf")
    try FileManager.default.copyItem(atPath: BrandKit.bundled("Fonts/Fraunces.ttf"), toPath: font.path)
    let logo = mine.appendingPathComponent("forneria.png")
    try pngLogo(logo, color: CGColor(red: 0.1, green: 0.8, blue: 0.2, alpha: 1))
    let id = "n24-forneria"
    _ = try? BrandKitStore().delete(id)
    try e.execute("brandkit.create", params: ["name": "Forneria", "id": .string(id)])
    try e.execute("brandkit.setFont", params: ["kit": .string(id), "path": .string(font.path), "role": "display"])
    try e.execute("brandkit.setLogo", params: ["kit": .string(id), "path": .string(logo.path), "variant": "onDark"])
    let kitFolder = BrandKitStore().folder(id)

    let undo = e.context.history.undoStack.count
    try e.execute("brandkit.apply", params: ["kit": .string(id)])
    #expect(e.context.history.undoStack.count == undo + 1 && e.context.history.undoStack.last?.command == "brandkit.apply", "brandkit.apply is not one undo step")
    let copy = try #require(e.project?.brand)
    let media = dir.appendingPathComponent("holds-kit.regista/media").standardizedFileURL.path
    let display = try #require(copy.fonts["display"])
    let logoFile = try #require(copy.logos?["onDark"])
    for file in [display, logoFile] {
        #expect(file.hasPrefix(media + "/"), "the copy refers to \(file), not to a file of the project's media folder")
        #expect(copy.originals?[file]?.contains("/\(id)/") == true, "the copy does not say which kit file \(file) came from: \(copy.originals ?? [:])")
    }
    try e.execute("logo.add", params: ["start": 0, "duration": 4])
    try e.execute("title.add", params: ["text": "FORNERIA", "start": 0, "duration": 4, "preset": "hook"])
    let title = try #require(e.project?.tracks.flatMap(\.clips).first { $0.title?.text == "FORNERIA" }?.title)
    #expect(title.font == display, "the hook title uses \(title.font), not the project's copy of the kit's font")
    let logoClip = try #require(e.project?.tracks.first { $0.role == "logo" }?.clips.first)
    #expect(e.project?.asset(logoClip.assetID)?.path == logoFile, "the logo clip's picture is not the project's copy of the logo")
    let before = dir.appendingPathComponent("before.png"), after = dir.appendingPathComponent("after.png")
    try e.execute("frame.render", params: ["time": 1, "path": .string(before.path), "inline": false])

    // The kit deleted: its folder goes, the project's files stay, the frame does not change.
    try e.execute("brandkit.delete", params: ["kit": .string(id)])
    #expect(!FileManager.default.fileExists(atPath: kitFolder.path), "the kit's folder is still there")
    #expect(FileManager.default.fileExists(atPath: display) && FileManager.default.fileExists(atPath: logoFile), "the project lost its files with the kit")
    #expect(e.project?.brand?.missingFiles == [], "the copy misses \(e.project?.brand?.missingFiles ?? [])")
    #expect(e.project?.brand?.font("display") == display, "the copy's display font falls back to \(e.project?.brand?.font("display") ?? "-")")
    try e.execute("frame.render", params: ["time": 1, "path": .string(after.path), "inline": false])
    let a = try pixels(before), b = try pixels(after)
    #expect(a.width == b.width && a.height == b.height)
    // The kit's logo is on the frame (its green), before and after.
    func greens(_ p: (width: Int, height: Int, data: [UInt8])) -> Int {
        stride(from: 0, to: p.data.count, by: 4).filter { p.data[$0] < 60 && p.data[$0 + 1] > 170 && p.data[$0 + 2] < 90 }.count
    }
    #expect(greens(a) > 500 && greens(b) == greens(a), "the logo's green: \(greens(a)) pixels before the delete, \(greens(b)) after")
    let differ = zip(a.data, b.data).filter { abs(Int($0) - Int($1)) > 2 }.count
    #expect(differ == 0, "the frame changed when the kit was deleted (\(differ) channels differ)")
    if let shots = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
        try? FileManager.default.copyItem(at: after, to: URL(fileURLWithPath: shots).appendingPathComponent("n24-kit-deleted-frame.png"))
    }

    // The kit made again with the same files and applied again: the project's copies are used again, none added.
    try e.execute("brandkit.create", params: ["name": "Forneria", "id": .string(id)])
    try e.execute("brandkit.setFont", params: ["kit": .string(id), "path": .string(font.path), "role": "display"])
    try e.execute("brandkit.setLogo", params: ["kit": .string(id), "path": .string(logo.path), "variant": "onDark"])
    let files = try FileManager.default.contentsOfDirectory(atPath: (display as NSString).deletingLastPathComponent).sorted()
    try e.execute("brandkit.apply", params: ["kit": .string(id)])
    #expect(e.project?.brand?.fonts["display"] == display && e.project?.brand?.logos?["onDark"] == logoFile, "applied again, the kit's files were copied again")
    #expect(try FileManager.default.contentsOfDirectory(atPath: (display as NSString).deletingLastPathComponent).sorted() == files)
    _ = try? BrandKitStore().delete(id)

    // A built-in kit's files ship with Regista and do not go away: nothing is copied.
    try e.execute("brandkit.apply", params: ["kit": "arkad"])
    #expect(e.project?.brand?.fonts == BrandKit.arkad.absolutized().fonts && e.project?.brand?.logos == BrandKit.arkad.absolutized().logos,
            "the built-in kit's bundled files were copied")
    #expect(e.project?.brand?.originals == nil)
}
