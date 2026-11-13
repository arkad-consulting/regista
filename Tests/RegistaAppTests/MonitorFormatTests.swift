import AppKit
import Foundation
import Testing
@testable import Regista
@testable import RegistaCore
import RegistaEngines

// E0 (#52): the monitors follow the project's format, letterboxed, never stretched.

@Test func monitorFitLetterboxesEveryFormat() {
    let area = CGRect(x: 0, y: 0, width: 600, height: 500)
    for (w, h) in [(1080, 1920), (1080, 1350), (1080, 1080), (1920, 1080), (1000, 700)] {
        let a = CGFloat(w) / CGFloat(h)
        let r = MonitorFit.rect(aspect: a, in: area)
        #expect(abs(r.width / r.height - a) < 1e-9)
        // Fills one side, centred on the other, inside the area.
        #expect(abs(r.width - area.width) < 1e-9 || abs(r.height - area.height) < 1e-9)
        #expect(area.contains(r.insetBy(dx: 0.001, dy: 0.001)))
        #expect(abs(r.midX - area.midX) < 1e-9 && abs(r.midY - area.midY) < 1e-9)
    }
    #expect(MonitorFit.rect(aspect: 0, in: area) == .zero)
    #expect(MonitorFit.label(width: 1080, height: 1920) == "9:16")
    #expect(MonitorFit.label(width: 1080, height: 1350) == "4:5")
    #expect(MonitorFit.label(width: 1080, height: 1080) == "1:1")
    #expect(MonitorFit.label(width: 1920, height: 1080) == "16:9")
    #expect(MonitorFit.label(width: 1280, height: 720) == "16:9")
    #expect(MonitorFit.label(width: 1000, height: 700) == "10:7")
    #expect(MonitorFit.label(width: 1366, height: 768) == "1366×768")
    #expect(MonitorFit.showsInstagramZones(width: 1080, height: 1920) && MonitorFit.showsInstagramZones(width: 720, height: 1280))
    #expect(!MonitorFit.showsInstagramZones(width: 1080, height: 1350) && !MonitorFit.showsInstagramZones(width: 1920, height: 1080))
    // The automatic Program width follows the format: a 16:9 monitor is wider than a 9:16 one.
    let size = CGSize(width: 1400, height: 800)
    #expect(ProLayout.compute(size, aspect: 16.0 / 9).program > ProLayout.compute(size, aspect: 9.0 / 16).program)
}

/// A circle overlay rendered through the export compositor (the one the Program player uses) for each format, then
/// drawn by the monitor's own drawing code into a monitor area: the circle stays a circle in the frame and on screen.
@Test func circleStaysACircleInEveryFormat() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-e0-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = dir.appendingPathComponent("circle.png")
    try writeCircle(400, to: png)
    let shots = ProcessInfo.processInfo.environment["REGISTA_E0_SHOTS"].map { URL(fileURLWithPath: $0) }
    for (w, h) in [(1080, 1920), (1080, 1350), (1080, 1080), (1920, 1080)] {
        var p = Project(name: "circle", settings: ProjectSettings(width: w, height: h))
        p.assets = [MediaAsset(id: "a1", name: "circle", path: png.path, duration: ImageSource.stillDuration,
                               video: VideoInfo(width: 400, height: 400, frameRate: Rational(30), codec: "png"), audio: nil,
                               image: ImageSource(kind: .still, path: png.path))]
        var o = Track(id: "t1", kind: .overlay, name: "O1")
        var c = Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: MediaTime(seconds: 1), start: .zero)
        c.placement = Placement(fit: .native)
        o.clips = [c]
        p.tracks = [o]
        let frame = try #require(try AVRenderer().renderImages(RenderJob(project: p, preset: .named(nil, project: p)), at: [MediaTime(seconds: 0.5)]).first)
        #expect(frame.width == w && frame.height == h)
        let fb = try #require(whiteBox(frame))
        #expect(abs(fb.width - fb.height) <= 2, "\(w)×\(h) frame: circle \(fb)")

        for area in [CGSize(width: 600, height: 500), CGSize(width: 320, height: 720)] {
            let picture = MonitorFit.rect(aspect: CGFloat(w) / CGFloat(h), in: CGRect(origin: .zero, size: area)).integral
            let ctx = CGContext(data: nil, width: Int(area.width), height: Int(area.height), bitsPerComponent: 8, bytesPerRow: Int(area.width) * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: 0.2, green: 0.2, blue: 0.25, alpha: 1))   // the monitor's well
            ctx.fill(CGRect(origin: .zero, size: area))
            ctx.translateBy(x: 0, y: area.height)   // top-left origin, like the flipped FrameView
            ctx.scaleBy(x: 1, y: -1)
            FrameView.draw(frame, in: ctx, picture: picture)
            let shot = try #require(ctx.makeImage())
            let mb = try #require(whiteBox(shot))
            #expect(abs(mb.width - mb.height) <= 2, "\(w)×\(h) in \(area): circle \(mb)")
            // The circle's size on screen is the frame's, scaled by the picture's single scale factor.
            let k = picture.width / CGFloat(w)
            #expect(abs(mb.width - fb.width * k) <= 3)
            if let shots {
                try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
                let url = shots.appendingPathComponent("monitor-\(w)x\(h)-in-\(Int(area.width))x\(Int(area.height)).png")
                let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, shot, nil)
                CGImageDestinationFinalize(dest)
                print("E0 \(w)×\(h) in \(Int(area.width))×\(Int(area.height)): picture \(picture), frame circle \(fb.width)×\(fb.height), monitor circle \(mb.width)×\(mb.height)")
            }
        }
    }
}

// MARK: - Helpers

func writeCircle(_ d: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: d * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: d, height: d))
    try savePNG(ctx.makeImage()!, url)
}

func savePNG(_ image: CGImage, _ url: URL) throws {
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
}

func rgba(_ img: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: img.width * img.height * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    }
    return data
}

/// Bounding box of the near-white pixels (the circle), pixels.
func whiteBox(_ img: CGImage) -> CGRect? {
    let px = rgba(img)
    var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    for y in 0..<img.height {
        for x in 0..<img.width {
            let o = (y * img.width + x) * 4
            if px[o] > 200, px[o + 1] > 200, px[o + 2] > 200 {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
    }
    return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
}
