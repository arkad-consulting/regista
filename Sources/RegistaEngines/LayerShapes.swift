import CoreGraphics
import CoreImage
import CoreText
import Foundation
import RegistaCore

/// Masks, borders and shadows of boxed layers (screen-recording layouts): antialiased shapes drawn with Core
/// Graphics at the box's pixel size, cached per size and shape.
final class LayerShapes: @unchecked Sendable {
    private let lock = NSLock()
    private var masks: [String: CIImage] = [:]
    private var borders: [String: CIImage] = [:]

    /// The shape's path in a `w`×`h` box (bottom-left origin), inset by `inset` px.
    static func path(_ mask: LayerMask, w: Double, h: Double, inset: Double = 0) -> CGPath {
        let rect = CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: inset, dy: inset)
        switch mask.shape {
        case .rect: return CGPath(rect: rect, transform: nil)
        case .circle:
            let d = min(rect.width, rect.height)
            return CGPath(ellipseIn: CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d), transform: nil)
        case .rounded:
            let r = min(max((mask.radius ?? 0.1) * min(w, h) - inset, 0), min(rect.width, rect.height) / 2)
            return CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        }
    }

    /// Grey mask (white inside the shape) of a `w`×`h` box, nil for a plain rectangle.
    func mask(_ mask: LayerMask, w: Int, h: Int) -> CIImage? {
        guard mask.shape != .rect, w > 0, h > 0 else { return nil }
        let key = "\(mask.shape.rawValue)-\(mask.radius ?? 0)-\(w)x\(h)"
        lock.lock(); defer { lock.unlock() }
        if let m = masks[key] { return m }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(Self.path(mask, w: Double(w), h: Double(h)))
        ctx.fillPath()
        guard let cg = ctx.makeImage() else { return nil }
        let img = CIImage(cgImage: cg)
        masks[key] = img
        return img
    }

    /// The border ring (inside the box edge) as an RGBA image, nil when there is none.
    func border(_ mask: LayerMask, w: Int, h: Int, width: Double) -> CIImage? {
        guard width > 0.2, let hex = mask.borderColor, w > 0, h > 0 else { return nil }
        let key = "\(mask.shape.rawValue)-\(mask.radius ?? 0)-\(w)x\(h)-\(width)-\(hex)-\(mask.borderOpacity ?? 1)"
        lock.lock(); defer { lock.unlock() }
        if let b = borders[key] { return b }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c = GraphicsStore.rgb(hex)
        ctx.setShouldAntialias(true)
        ctx.setStrokeColor(red: c.0, green: c.1, blue: c.2, alpha: mask.borderOpacity ?? 1)
        ctx.setLineWidth(width)
        ctx.addPath(Self.path(mask, w: Double(w), h: Double(h), inset: width / 2))
        ctx.strokePath()
        guard let cg = ctx.makeImage() else { return nil }
        let img = CIImage(cgImage: cg)
        borders[key] = img
        return img
    }

    // MARK: Card frames (layout.speaker inset-frame)

    private var decor: [String: (CIImage?, CIImage?)] = [:]

    /// What a card frame style adds around a `w`×`h` box (Core Image coordinates, box at the origin): `under` goes below
    /// the card (neon glow, glass rim), `over` on top of it (corner brackets, the label and badge chips). `short` is the
    /// output's shorter side, which sizes strokes and chips like the borders.
    func decoration(_ mask: LayerMask, w: Int, h: Int, short: Double) -> (under: CIImage?, over: CIImage?) {
        guard mask.frame != nil || mask.label != nil || mask.badge != nil, w > 0, h > 0 else { return (nil, nil) }
        let key = "\(mask.frame ?? "-")|\(mask.glowColor ?? "")|\(mask.label ?? "")|\(mask.badge ?? "")|\(mask.radius ?? 0)|\(mask.shadow ?? 0)|\(w)x\(h)|\(short)"
        lock.lock()
        if let d = decor[key] { lock.unlock(); return d }
        lock.unlock()
        let k = short / 1080
        let pad = (120 * k).rounded()
        let W = w + 2 * Int(pad), H = h + 2 * Int(pad)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func canvas() -> CGContext? {
            let c = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.setShouldAntialias(true)
            c?.translateBy(x: pad, y: pad)
            return c
        }
        func rgb(_ hex: String, _ a: Double) -> CGColor { let c = GraphicsStore.rgb(hex); return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a) }
        func image(_ c: CGContext?) -> CIImage? {
            guard let cg = c?.makeImage() else { return nil }
            return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: -pad, y: -pad))
        }
        let glow = mask.glowColor ?? "#FF7A1A"
        let card = Self.path(mask, w: Double(w), h: Double(h))
        var under: CIImage?, over: CIImage?
        switch mask.frame {
        case "neon":
            // A wide soft halo and a tight bright one, both from the card outline.
            if let c = canvas() {
                // A faint wash of the colour behind the whole card, then the halo of the outline.
                c.setShadow(offset: .zero, blur: 90 * k, color: rgb(glow, 0.55))
                c.addPath(card); c.setFillColor(rgb(glow, 0.35)); c.fillPath()
                c.setShadow(offset: .zero, blur: 46 * k, color: rgb(glow, 0.9))
                c.addPath(card); c.setStrokeColor(rgb(glow, 0.9)); c.setLineWidth(10 * k); c.strokePath()
                c.setShadow(offset: .zero, blur: 14 * k, color: rgb(glow, 1))
                c.addPath(card); c.setStrokeColor(rgb(glow, 1)); c.setLineWidth(5 * k); c.strokePath()
                under = image(c)
            }
        case "glass":
            if let c = canvas() {
                let rim = 16 * k
                let r = min(max((mask.radius ?? 0.1) * Double(min(w, h)) + rim, 0), Double(min(w, h)) / 2 + rim)
                let outer = CGPath(roundedRect: CGRect(x: -rim, y: -rim, width: Double(w) + 2 * rim, height: Double(h) + 2 * rim),
                                   cornerWidth: r, cornerHeight: r, transform: nil)
                c.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 40 * k, color: CGColor(gray: 0, alpha: 0.45))
                c.addPath(outer); c.setFillColor(CGColor(gray: 1, alpha: 0.12)); c.fillPath()
                c.setShadow(offset: .zero, blur: 0, color: nil)
                c.addPath(outer); c.setStrokeColor(CGColor(gray: 1, alpha: 0.38)); c.setLineWidth(1.5 * k); c.strokePath()
                under = image(c)
            }
        case "float":
            // A screen floating over the frame's background (styled frame, issue #44): a wide soft ambient shadow and a
            // tighter contact shadow, both falling slightly downwards, scaled by the mask's shadow opacity.
            if let c = canvas() {
                let o = mask.shadow ?? 0.5
                c.setShadow(offset: CGSize(width: 0, height: -26 * k), blur: 80 * k, color: CGColor(gray: 0, alpha: 0.55 * o))
                c.addPath(card); c.setFillColor(CGColor(gray: 0, alpha: 1)); c.fillPath()
                c.setShadow(offset: CGSize(width: 0, height: -6 * k), blur: 16 * k, color: CGColor(gray: 0, alpha: 0.5 * o))
                c.addPath(card); c.fillPath()
                under = image(c)
            }
        default: break
        }
        if let c = canvas() {
            var drew = false
            if mask.frame == "float" {
                // A hairline light rim inside the edge: the screen reads as a pane of glass even on a dark background.
                c.addPath(Self.path(mask, w: Double(w), h: Double(h), inset: 0.75 * k))
                c.setStrokeColor(CGColor(gray: 1, alpha: 0.10)); c.setLineWidth(1.5 * k); c.strokePath()
                drew = true
            }
            if mask.frame == "neon" {
                // Corner brackets just outside the card.
                let o = 16 * k, len = 0.09 * Double(min(w, h))
                c.setStrokeColor(rgb(glow, 0.95)); c.setLineWidth(4 * k); c.setLineCap(.round)
                c.setShadow(offset: .zero, blur: 10 * k, color: rgb(glow, 0.8))
                let x0 = -o, y0 = -o, x1 = Double(w) + o, y1 = Double(h) + o
                for (cx, cy, dx, dy) in [(x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0), (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0)] {
                    c.move(to: CGPoint(x: cx, y: cy + dy * len)); c.addLine(to: CGPoint(x: cx, y: cy)); c.addLine(to: CGPoint(x: cx + dx * len, y: cy))
                }
                c.strokePath()
                c.setShadow(offset: .zero, blur: 0, color: nil)
                drew = true
            }
            /// A chip whose top-left (or top-right) corner is inset into the card.
            func chip(_ text: String, right: Bool, dot: Bool) {
                let font = CTFontCreateWithName("Menlo-Bold" as CFString, 22 * k, nil)
                let attr = NSAttributedString(string: text.uppercased(), attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 0.94),
                    NSAttributedString.Key(kCTKernAttributeName as String): 2.2 * k])
                let line = CTLineCreateWithAttributedString(attr)
                let tb = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
                let ph = 46 * k, padX = 18 * k, dotW = dot ? 22 * k : 0
                let cw = tb.width + 2 * padX + dotW
                let inset = 24 * k
                let x = right ? Double(w) - inset - cw : inset, y = Double(h) - inset - ph
                let pill = CGPath(roundedRect: CGRect(x: x, y: y, width: cw, height: ph), cornerWidth: ph / 2, cornerHeight: ph / 2, transform: nil)
                c.addPath(pill); c.setFillColor(CGColor(gray: 0, alpha: 0.62)); c.fillPath()
                c.addPath(pill); c.setStrokeColor(CGColor(gray: 1, alpha: 0.16)); c.setLineWidth(1.5 * k); c.strokePath()
                if dot {
                    let r = 6 * k
                    c.setFillColor(rgb(glow, 1))
                    c.fillEllipse(in: CGRect(x: x + padX - 2 * k, y: y + ph / 2 - r, width: 2 * r, height: 2 * r))
                }
                c.textPosition = CGPoint(x: x + padX + dotW - tb.minX, y: y + (ph - tb.height) / 2 - tb.minY)
                CTLineDraw(line, c)
                drew = true
            }
            if let l = mask.label { chip(l, right: false, dot: true) }
            if let b = mask.badge { chip(b, right: true, dot: false) }
            if drew { over = image(c) }
        }
        lock.lock()
        if decor.count > 32 { decor.removeAll() }
        decor[key] = (under, over)
        lock.unlock()
        return (under, over)
    }

    /// Steepens a soft person matte around 0.5 so the cut-out has no halo of the camera's background while
    /// keeping a couple of pixels of anti-aliasing (0.35 → 0, 0.65 → 1).
    static func steepen(_ matte: CIImage) -> CIImage {
        matte.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 3.3, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 3.3, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 3.3, w: 0), "inputBiasVector": CIVector(x: -1.15, y: -1.15, z: -1.15, w: 0),
        ]).applyingFilter("CIColorClamp")
    }

    /// The matte faded to 0 over the outer 6% of the box on the left and right.
    static func featherSides(_ matte: CIImage, width w: Double, box: CGRect) -> CIImage {
        let ramp = 0.06 * w
        func gradient(_ x0: Double, _ x1: Double) -> CIImage {
            CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: x0, y: 0), "inputPoint1": CIVector(x: x1, y: 0),
                                                            "inputColor0": CIColor.black, "inputColor1": CIColor.white])!.outputImage!.cropped(to: box)
        }
        return matte.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gradient(0, ramp)])
            .applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: gradient(w, w - ramp)])
            .cropped(to: box)
    }

    /// A soft drop shadow of `content`'s alpha: black at `opacity`, blurred by `radius`, moved down by `drop` px.
    static func shadow(of content: CIImage, opacity: Double, radius: Double, drop: Double) -> CIImage {
        content.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
        ])
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .transformed(by: CGAffineTransform(translationX: 0, y: -drop))
    }
}
