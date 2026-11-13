import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import RegistaCore

/// Draws the generated layers of issue #16 — stickers (emoji, SF Symbols), callouts and progress bars — and the
/// Core Image parts of looks, glitch and chroma key. Caches what does not change from frame to frame.
final class FXStore: @unchecked Sendable {
    private let lock = NSLock()
    private struct StickerKey: Hashable { var sticker: Sticker; var width: Int }
    private var stickers: [StickerKey: CGImage] = [:]
    private struct ShapeKey: Hashable { var shape: ShapeLayer; var progress: Int; var w: Int; var h: Int }
    private var shapes: [ShapeKey: CIImage] = [:]
    private var gradeCubes: [ResolvedGrade: Data] = [:]
    private struct KeyCube: Hashable { var color: String; var tolerance: Double; var spill: Double }
    private var keyCubes: [KeyCube: Data] = [:]

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: Stickers

    /// The sticker as an image whose size is its box at this output width.
    func sticker(_ s: Sticker, outputWidth: Int) -> CGImage? {
        let key = StickerKey(sticker: s, width: outputWidth)
        lock.lock()
        if let i = stickers[key] { lock.unlock(); return i }
        lock.unlock()
        guard let img = Self.drawSticker(s, outputWidth: outputWidth) else { return nil }
        lock.lock()
        if stickers.count > 64 { stickers.removeAll() }
        stickers[key] = img
        lock.unlock()
        return img
    }

    static func drawSticker(_ s: Sticker, outputWidth: Int) -> CGImage? {
        let k = Double(outputWidth) / SafeZones.referenceWidth
        let side = max(Int((s.box * k).rounded()), 4)
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let size = s.size * k
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        if let badge = s.badge {
            let c = GraphicsStore.rgb(badge)
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fillEllipse(in: rect.insetBy(dx: 1, dy: 1))
        }
        switch s.kind {
        case .emoji:
            let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size * 0.86, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s.value, attributes: [.font: font]))
            let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            ctx.textPosition = CGPoint(x: rect.midX - b.midX, y: rect.midY - b.midY)
            CTLineDraw(line, ctx)
        case .symbol:
            let c = GraphicsStore.rgb(s.color ?? "#FFFFFF")
            let color = NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            let config = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .semibold).applying(.init(paletteColors: [color]))
            guard let sym = NSImage(systemSymbolName: s.value, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return nil }
            var r = CGRect(origin: .zero, size: sym.size)
            guard let cg = sym.cgImage(forProposedRect: &r, context: nil, hints: nil) else { return nil }
            let scale = min(size / max(sym.size.width, sym.size.height), 4) * (s.badge == nil ? 1 : 0.85)
            let w = sym.size.width * scale, h = sym.size.height * scale
            // Soft shadow so white symbols read on bright footage.
            ctx.setShadow(offset: CGSize(width: 0, height: -3 * k), blur: 14 * k, color: CGColor(gray: 0, alpha: s.badge == nil ? 0.35 : 0))
            ctx.draw(cg, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
        }
        return ctx.makeImage()
    }

    // MARK: Shapes

    /// A callout or progress bar on a `w`×`h` canvas (Core Image coordinates).
    func shape(_ s: ShapeLayer, progress: Double, w: Int, h: Int) -> CIImage? {
        // HUD shapes change every frame (timer, levels): drawn directly from the clip time.
        if s.kind == .statusBar { return HUDRasterizer.statusBar(s, time: progress, w: w, h: h) }
        if s.kind == .audioMeters { return HUDRasterizer.audioMeters(s, time: progress, w: w, h: h) }
        let p = min(max(progress, 0), 1)
        if s.kind == .halo {
            let key = ShapeKey(shape: s, progress: Int((p * 240).rounded()), w: w, h: h)
            lock.lock()
            if let i = shapes[key] { lock.unlock(); return i }
            lock.unlock()
            guard let img = HUDRasterizer.halo(s, progress: p, w: w, h: h) else { return nil }
            lock.lock()
            if shapes.count > 160 { shapes.removeAll() }
            shapes[key] = img
            lock.unlock()
            return img
        }
        if s.kind == .progressBar || s.kind == .highlight { return Self.bar(s, progress: p, w: w, h: h) }
        let key = ShapeKey(shape: s, progress: Int((p * 240).rounded()), w: w, h: h)
        lock.lock()
        if let i = shapes[key] { lock.unlock(); return i }
        lock.unlock()
        guard let img = Self.drawStroke(s, progress: p, w: w, h: h) else { return nil }
        lock.lock()
        if shapes.count > 160 { shapes.removeAll() }
        shapes[key] = img
        lock.unlock()
        return img
    }

    static func ciColor(_ hex: String, alpha: Double = 1) -> CIColor {
        let c = GraphicsStore.rgb(hex)
        return CIColor(red: c.0 * alpha, green: c.1 * alpha, blue: c.2 * alpha, alpha: alpha)   // premultiplied
    }

    /// Progress bar (track + fill, rounded ends) or highlighter band, from rectangles: cheap enough per frame.
    static func bar(_ s: ShapeLayer, progress p: Double, w: Int, h: Int) -> CIImage? {
        let W = Double(w), H = Double(h), k = W / SafeZones.referenceWidth
        let r = s.rect
        let x = r[0] * W, top = r[1] * H, bw = r[2] * W
        let thick = s.kind == .progressBar ? max(s.width * k, 1) : r[3] * H
        let y = H - top - thick
        var out = CIImage.empty()
        if s.kind == .progressBar, let t = s.trackColor {
            out = CIImage(color: ciColor(t, alpha: 0.35)).cropped(to: CGRect(x: x, y: y, width: bw, height: thick))
        }
        let fill = CGRect(x: x, y: y, width: bw * p, height: thick)
        guard fill.width >= 0.5 else { return out }
        let alpha = s.kind == .highlight ? 0.38 : 1
        out = CIImage(color: ciColor(s.color, alpha: alpha)).cropped(to: fill).composited(over: out)
        return out
    }

    /// Points of a callout's stroke (top-left pixels) and whether it ends in an arrowhead.
    static func polyline(_ s: ShapeLayer, W: Double, H: Double) -> [CGPoint] {
        let r = s.rect
        let x = r[0] * W, y = r[1] * H, w = r[2] * W, h = r[3] * H
        switch s.kind {
        case .arrow:
            // A gentle arc from the tail to the head.
            let a = CGPoint(x: x, y: y), b = CGPoint(x: x + w, y: y + h)
            let mid = CGPoint(x: (a.x + b.x) / 2 - h * 0.12, y: (a.y + b.y) / 2 + w * 0.12)
            return (0...40).map { i in
                let t = Double(i) / 40
                return CGPoint(x: (1 - t) * (1 - t) * a.x + 2 * (1 - t) * t * mid.x + t * t * b.x,
                               y: (1 - t) * (1 - t) * a.y + 2 * (1 - t) * t * mid.y + t * t * b.y)
            }
        case .circle:
            // Hand-drawn: starts at ~10 o'clock, goes once round and overshoots a little, radius wobbles.
            let cx = x + w / 2, cy = y + h / 2, rx = w / 2 * 1.08, ry = h / 2 * 1.12
            return (0...90).map { i in
                let t = Double(i) / 90
                let a = -2.2 + t * (2 * Double.pi + 0.45)
                let wob = 1 + 0.035 * sin(3 * a + 0.6) + 0.02 * t
                return CGPoint(x: cx + rx * wob * cos(a), y: cy + ry * wob * sin(a))
            }
        case .underline:
            let base = y + h + max(6, h * 0.08)
            return (0...24).map { i in
                let t = Double(i) / 24
                return CGPoint(x: x + w * t, y: base + sin(t * Double.pi) * h * 0.04)
            }
        case .box:
            let rad = min(w, h) * 0.18
            var pts: [CGPoint] = []
            func arc(_ c: CGPoint, _ a0: Double) {
                for i in 0...6 { let a = a0 + Double(i) / 6 * Double.pi / 2; pts.append(CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))) }
            }
            arc(CGPoint(x: x + rad, y: y + rad), Double.pi)
            arc(CGPoint(x: x + w - rad, y: y + rad), 1.5 * Double.pi)
            arc(CGPoint(x: x + w - rad, y: y + h - rad), 0)
            arc(CGPoint(x: x + rad, y: y + h - rad), 0.5 * Double.pi)
            pts.append(pts[0])
            return pts
        case .highlight, .progressBar, .halo, .statusBar, .audioMeters:
            return []
        }
    }

    static func drawStroke(_ s: ShapeLayer, progress p: Double, w: Int, h: Int) -> CIImage? {
        let W = Double(w), H = Double(h), k = W / SafeZones.referenceWidth
        let pts = polyline(s, W: W, H: H)
        guard pts.count > 1, p > 0 else { return CIImage.empty() }
        var lengths = [0.0]
        for i in 1..<pts.count { lengths.append(lengths[i - 1] + hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y)) }
        let target = lengths.last! * p
        var drawn = [pts[0]]
        for i in 1..<pts.count {
            if lengths[i] <= target { drawn.append(pts[i]); continue }
            let f = (target - lengths[i - 1]) / max(lengths[i] - lengths[i - 1], 1e-9)
            drawn.append(CGPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f, y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f))
            break
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        let c = GraphicsStore.rgb(s.color)
        let color = CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        ctx.setStrokeColor(color)
        ctx.setFillColor(color)
        ctx.setLineWidth(max(s.width * k, 1))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setShadow(offset: CGSize(width: 0, height: 2 * k), blur: 10 * k, color: CGColor(gray: 0, alpha: 0.3))
        ctx.addLines(between: drawn)
        ctx.strokePath()
        if s.kind == .arrow, p > 0.82, let tip = drawn.last {
            // Arrowhead grows in over the last part of the draw.
            let f = min((p - 0.82) / 0.18, 1)
            let prev = drawn.count > 3 ? drawn[drawn.count - 4] : drawn[0]
            let ang = atan2(tip.y - prev.y, tip.x - prev.x)
            let len = (28 + s.width * 1.6) * k * f
            ctx.addLines(between: [CGPoint(x: tip.x - len * cos(ang - 0.5), y: tip.y - len * sin(ang - 0.5)), tip,
                                   CGPoint(x: tip.x - len * cos(ang + 0.5), y: tip.y - len * sin(ang + 0.5))])
            ctx.strokePath()
        }
        guard let img = ctx.makeImage() else { return nil }
        return CIImage(cgImage: img)
    }

    // MARK: Colour

    func gradeCube(_ g: ResolvedGrade) -> Data {
        let key = g.cacheKey
        lock.lock()
        if let d = gradeCubes[key] { lock.unlock(); return d }
        lock.unlock()
        let data = key.cube(size: Self.cubeSize).withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock()
        if gradeCubes.count > 256 { gradeCubes.removeAll() }
        gradeCubes[key] = data
        lock.unlock()
        return data
    }

    static let cubeSize = 33

    /// Look + adjustments: the colour cube, then sharpness and vignette (full-frame layers are clamped first).
    func applyGrade(_ g: ResolvedGrade, to image: CIImage, canvas: CGRect, outputWidth: Int, fill: Bool) -> CIImage {
        var img = image
        let extent = image.extent
        if !g.colorIsIdentity {
            img = img.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": Self.cubeSize, "inputCubeData": gradeCube(g)])
        }
        let k = Double(outputWidth) / SafeZones.referenceWidth
        if g.adjust.sharpness > 0 {
            img = (fill ? img.clampedToExtent() : img)
                .applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: 0.9 * g.adjust.sharpness, kCIInputRadiusKey: 1.6 * k])
                .cropped(to: extent)
        }
        if g.adjust.vignette > 0 {
            let c = CIVector(x: canvas.midX, y: canvas.midY)
            img = img.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: c, kCIInputRadiusKey: hypot(canvas.width, canvas.height) * 0.42,
                                                                       kCIInputIntensityKey: 0.95 * g.adjust.vignette, "inputFalloff": 0.55])
                .cropped(to: extent)
        }
        return img
    }

    func keyCube(color: String, tolerance: Double, spill: Double) -> Data {
        let key = KeyCube(color: color, tolerance: (tolerance * 100).rounded() / 100, spill: (spill * 100).rounded() / 100)
        lock.lock()
        if let d = keyCubes[key] { lock.unlock(); return d }
        lock.unlock()
        let data = ChromaKeyCube.cube(key: GraphicsStore.rgb(color), tolerance: key.tolerance, spill: key.spill, size: 32)
            .withUnsafeBufferPointer { Data(buffer: $0) }
        lock.lock(); keyCubes[key] = data; lock.unlock()
        return data
    }

    /// Green/blue screen: keyed pixels become transparent (premultiplied cube), mixed with the original by strength.
    func chromaKey(_ image: CIImage, _ e: LayerEffect) -> CIImage {
        let keyed = image.applyingFilter("CIColorCube", parameters: ["inputCubeDimension": 32,
                                                                     "inputCubeData": keyCube(color: e.color ?? "#00FF00", tolerance: e.tolerance ?? 0.4, spill: e.spill ?? 0.5)])
        return e.strength >= 1 ? keyed : keyed.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: 1 - e.strength])
    }

    /// Digital glitch: the red and blue channels pulled apart, plus a few horizontal slices shoved sideways. The slice
    /// pattern comes from `seed`, so a frame always renders the same.
    static func glitch(_ image: CIImage, _ e: LayerEffect, canvas: CGRect, outputWidth: Int) -> CIImage {
        var rng = SeededRandom(seed: UInt64(bitPattern: Int64(e.seed)))
        let k = Double(outputWidth) / SafeZones.referenceWidth
        let s = min(max(e.strength, 0), 2)
        let split = (6 + 14 * rng.next()) * k * s
        // One channel per copy (alpha kept), recombined with a per-component maximum.
        func channel(_ r: Double, _ g: Double, _ b: Double) -> CIImage {
            image.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: r, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                                                               "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        }
        let red = channel(1, 0, 0).clampedToExtent().transformed(by: CGAffineTransform(translationX: split, y: 0))
        let green = channel(0, 1, 0)
        let blue = channel(0, 0, 1).clampedToExtent().transformed(by: CGAffineTransform(translationX: -split, y: 0))
        var out = red.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
            .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
            .cropped(to: image.extent)
        let slices = Int(2 + 4 * rng.next() * min(s, 1))
        for _ in 0..<slices {
            let hgt = canvas.height * (0.015 + 0.06 * rng.next())
            let y = canvas.minY + (canvas.height - hgt) * rng.next()
            let dx = (rng.next() - 0.5) * 0.16 * canvas.width * s
            let band = out.clampedToExtent().cropped(to: CGRect(x: canvas.minX - abs(dx), y: y, width: canvas.width + 2 * abs(dx), height: hgt))
                .transformed(by: CGAffineTransform(translationX: dx, y: 0))
                .cropped(to: CGRect(x: canvas.minX, y: y, width: canvas.width, height: hgt))
            out = band.composited(over: out)
        }
        return out.cropped(to: image.extent)
    }
}

/// Small deterministic generator (SplitMix64) for glitch patterns.
struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    /// Uniform in [0, 1).
    mutating func next() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

/// Colour previews for the app (filter strip thumbnails, the live picture while a slider moves): a picture through a
/// look/adjustments state with the compositor's own LUT, sharpness and vignette code.
public enum GradePreview {
    nonisolated(unsafe) private static let store = FXStore()
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    public static func apply(_ grade: ResolvedGrade?, to image: CGImage, outputWidth: Int) -> CGImage? {
        guard let grade, !grade.isIdentity else { return image }
        let ci = CIImage(cgImage: image)
        let out = store.applyGrade(grade, to: ci, canvas: ci.extent, outputWidth: outputWidth, fill: true)
        return context.createCGImage(out, from: ci.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }
}
