import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import RegistaCore

// Motion templates (issue #22). Adding a template = one file in Motion/Templates with a type conforming to
// `MotionTemplate` (its `MotionSpec` + `draw`) and one line in `MotionLibrary.templates`. The kit below gives every
// template the same tools: cached Core Graphics sprites, brand colours and fonts, placement with the 2.5D projection,
// photos, shadows and the house easing (tame overshoot, ~0.35 s in, ~0.25 s out).

/// One motion template: its catalog entry and how it draws one instant.
public protocol MotionTemplate {
    static var spec: MotionSpec { get }
    /// The template at `c.t` seconds: a full-frame Core Image image (transparent where nothing is drawn), or nil.
    /// Split templates (`layering: .split`) are asked twice per frame, `c.part` = back then front.
    static func draw(_ c: MotionCanvas) -> CIImage?
}

public enum MotionLibrary {
    /// Every template. Register a new one here (one line).
    public static let templates: [any MotionTemplate.Type] = [
        OrbitCarousel.self,
        Checklist.self,
        Counter.self,
        SwingTag.self,
        Marquee.self,
        DeviceFrame.self,
        CardStack.self,
        HUDFrame.self,
        Chart.self,
        KickerHeadline.self,
        AnnotationChip.self,
        BackgroundScene.self,
        StatCard.self,
        BeforeAfter.self,
        ScatterWall.self,
        MockUI.self,
        GalleryCard.self,
        ThumbnailRing.self,
        ScriptCard.self,
        BentoGrid.self,
        CardRow.self,
        VideoCard.self,
        PromptBar.self,
        TimelineMilestones.self,
        StackedPages.self,
        ProgressRows.self,
        SFXCallout.self,
        Cursor.self,
        ChatWindow.self,
        CutVisualizer.self,
        PlayCard.self,
        Receipt.self,
        Machine.self,
        LogoTile.self,
        QuoteCard.self,
    ]

    /// Publishes the specs to RegistaCore (catalog, motion.add, MCP). Idempotent; `EngineServices.live` calls it.
    public static func registerAll() { MotionRegistry.register(templates.map { $0.spec }) }

    static func template(_ id: String) -> (any MotionTemplate.Type)? { templates.first { $0.spec.id == id } }
}

/// Caches shared by the templates of one compositor (sprites drawn once, photos decoded once).
final class MotionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sprites: [String: CIImage] = [:]
    private var order: [String] = []
    let graphics = GraphicsStore()

    func sprite(_ key: String, make: () -> CIImage) -> CIImage {
        lock.lock()
        if let s = sprites[key] { lock.unlock(); return s }
        lock.unlock()
        let s = make()
        lock.lock()
        sprites[key] = s
        order.append(key)
        if order.count > 400 { sprites[order.removeFirst()] = nil }
        lock.unlock()
        return s
    }

    /// The layer's template at its time (layer offset and opacity applied), or nil.
    func render(_ layer: VideoLayer, job: RenderJob, below: CIImage?) -> CIImage? {
        guard case .motion(let m, let t, let d, let part) = layer.source, let template = MotionLibrary.template(m.template) else { return nil }
        let c = MotionCanvas(m: m, t: t, d: d, part: part, W: Double(job.width), H: Double(job.height), store: self, below: below)
        guard var img = template.draw(c) else { return nil }
        if layer.x != 0 || layer.y != 0 {
            img = img.transformed(by: CGAffineTransform(translationX: layer.x * c.W, y: -layer.y * c.H))
        }
        if layer.opacity < 1 { img = MotionCanvas.fade(img, layer.opacity) }
        return img
    }
}

/// Everything a template needs to draw one instant. Positions are output pixels with a top-left origin; sizes given
/// as reference pixels (a 1080-wide frame) go through `px`.
public struct MotionCanvas {
    public let m: MotionLayer
    /// Seconds from the clip start, and the clip length.
    public let t: Double
    public let d: Double
    public let part: MotionPart
    public let W: Double
    public let H: Double
    let store: MotionStore
    /// The picture drawn under the layer (templates with `consumesBelow`).
    public let below: CIImage?

    /// Output pixels per reference pixel.
    public var k: Double { W / SafeZones.referenceWidth }
    public func px(_ v: Double) -> Double { v * k }
    public var canvas: CGRect { CGRect(x: 0, y: 0, width: W, height: H) }
    public static let empty = CIImage.empty()

    /// Vertical centre of the template's band (or `position` [x, y] on a 1080×1920 frame), output pixels.
    public var centre: (Double, Double) {
        if let p = m.fields["position"]?.arrayValue?.compactMap(\.doubleValue), p.count == 2 { return (p[0] * k, p[1] / SafeZones.referenceHeight * H) }
        let band = m.string("band", "top")
        return (W / 2, (SafeZones.centre(of: band) ?? 0.5) * H)
    }

    // MARK: Colour and type

    public func hex(_ field: String, _ role: String) -> String { m.color(field, role) }
    public func cg(_ hexOrRole: String, _ alpha: Double = 1) -> CGColor { TitleRasterizer.color(m.style.color(hexOrRole, "#FFFFFF"), alpha: alpha) }
    public func ci(_ hexOrRole: String, _ alpha: Double = 1) -> CIColor { FXStore.ciColor(m.style.color(hexOrRole, "#FFFFFF"), alpha: alpha) }

    /// A font by role (display, text, textBold, mono, serif) or name/file, at a reference size; falls back to the
    /// neutral role font, then Helvetica.
    public func font(_ role: String, _ size: Double) -> CTFont {
        let s = size * k
        let base = (try? TitleRasterizer.font(m.style.font(role), size: s)) ?? (try? TitleRasterizer.font(MotionStyle.neutral.font(role), size: s))
            ?? CTFontCreateWithName("Helvetica" as CFString, s, nil)
        // A variable font file serving the bold role (Geist for Arkad) is drawn at weight 700.
        return role == "textBold" ? Self.weighted(base, 700) : base
    }

    /// The font at a weight when it has a `wght` variation axis, else unchanged.
    static func weighted(_ font: CTFont, _ weight: Double) -> CTFont {
        guard let axes = CTFontCopyVariationAxes(font) as? [[String: Any]],
              let axis = axes.first(where: { ($0[kCTFontVariationAxisIdentifierKey as String] as? Int) == 0x77676874 }) else { return font }   // 'wght'
        let lo = axis[kCTFontVariationAxisMinimumValueKey as String] as? Double ?? weight, hi = axis[kCTFontVariationAxisMaximumValueKey as String] as? Double ?? weight
        let desc = CTFontDescriptorCreateCopyWithVariation(CTFontCopyFontDescriptor(font), 0x77676874 as CFNumber, CGFloat(min(max(weight, lo), hi)))
        return CTFontCreateWithFontDescriptor(desc, CTFontGetSize(font), nil)
    }

    // MARK: Sprites

    /// A cached Core Graphics drawing of `w`×`h` output pixels (top-left origin in `draw`), as an image at the origin.
    /// `key` must change whenever the drawing does (include the values it depends on).
    public func sprite(_ key: String, _ w: Double, _ h: Double, _ draw: @escaping (CGContext) -> Void) -> CIImage {
        let iw = max(Int(w.rounded(.up)), 1), ih = max(Int(h.rounded(.up)), 1)
        let full = "\(m.template)|\(key)|\(iw)x\(ih)|\(m.style.hashValue)"
        return store.sprite(full) {
            guard let ctx = CGContext(data: nil, width: iw, height: ih, bitsPerComponent: 8, bytesPerRow: 0, space: TitleRasterizer.space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .empty() }
            ctx.translateBy(x: 0, y: Double(ih))
            ctx.scaleBy(x: 1, y: -1)
            ctx.setShouldAntialias(true)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            draw(ctx)
            guard let img = ctx.makeImage() else { return .empty() }
            return CIImage(cgImage: img)
        }
    }

    /// A photo (any path) decoded once; nil when missing.
    public func image(_ path: String) -> CIImage? {
        guard !path.isEmpty else { return nil }
        return store.graphics.image(EngineConfig.expand(path))
    }

    /// A photo cropped to fill `w`×`h` output pixels (centred), rounded by `radius`, at the origin.
    public func photo(_ path: String, _ w: Double, _ h: Double, radius: Double) -> CIImage? {
        guard let img = image(path) else { return nil }
        let key = "photo|\(path)|\(Int(w))x\(Int(h))|\(Int(radius))"
        return store.sprite("\(m.template)|\(key)") {
            let e = img.extent
            let f = max(w / e.width, h / e.height)
            var s = img.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY)).transformed(by: CGAffineTransform(scaleX: f, y: f))
            s = s.transformed(by: CGAffineTransform(translationX: -(e.width * f - w) / 2, y: -(e.height * f - h) / 2)).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            return MotionCanvas.round(s, radius: radius)
        }
    }

    // MARK: Placement

    /// A sprite (extent at the origin) placed with its centre at `at` (top-left origin pixels), scaled and rotated
    /// around `anchor` (fractions of the sprite), tilted in 2.5D, faded.
    public func place(_ s: CIImage, at: (Double, Double), scale: Double = 1, rotation: Double = 0, opacity: Double = 1, anchor: (Double, Double) = (0.5, 0.5),
                      rotationX: Double = 0, rotationY: Double = 0, perspective: Double = Transform.defaultPerspective) -> CIImage {
        guard opacity > 0.002, scale > 0.001, !s.extent.isEmpty else { return .empty() }
        let w = s.extent.width, h = s.extent.height
        var out: CIImage
        if rotationX != 0 || rotationY != 0 {
            let c = Projection.corners(w: w, h: h, centre: at, scale: scale, rotation: rotation, anchorX: anchor.0, anchorY: anchor.1,
                                       rotationX: rotationX, rotationY: rotationY, distance: perspective * k)
            out = FrameDrawer.project(s, corners: c, height: H)
        } else {
            // Pivot = the anchor point of the sprite at rest.
            let px = at.0 + (anchor.0 - 0.5) * w, py = at.1 + (anchor.1 - 0.5) * h
            let t = CGAffineTransform(translationX: px, y: H - py).rotated(by: -rotation * .pi / 180).scaledBy(x: scale, y: scale)
                .translatedBy(x: -anchor.0 * w, y: -(1 - anchor.1) * h)
            out = s.transformed(by: t)
        }
        return opacity < 1 ? Self.fade(out, opacity) : out
    }

    /// Images composited bottom to top.
    public static func stack(_ images: [CIImage]) -> CIImage {
        images.reduce(CIImage.empty()) { $1.composited(over: $0) }
    }

    public static func fade(_ img: CIImage, _ opacity: Double) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                                                        "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
    }

    /// The image over a soft drop shadow of itself (reference pixels).
    public func shadow(_ img: CIImage, opacity: Double = 0.28, radius: Double = 26, drop: Double = 12) -> CIImage {
        img.composited(over: LayerShapes.shadow(of: img, opacity: opacity, radius: px(radius), drop: px(drop)))
    }

    /// An image cut to a rounded rectangle of its own extent.
    public static func round(_ img: CIImage, radius: Double) -> CIImage {
        guard radius > 0 else { return img }
        let e = img.extent
        guard let ctx = CGContext(data: nil, width: Int(e.width.rounded(.up)), height: Int(e.height.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return img }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: e.width, height: e.height), cornerWidth: min(radius, e.width / 2), cornerHeight: min(radius, e.height / 2), transform: nil))
        ctx.fillPath()
        guard let mask = ctx.makeImage() else { return img }
        let m = CIImage(cgImage: mask).transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: m]).cropped(to: e)
    }

    /// Darkens the frame (the shot under a counter): a full-frame black wash of `amount`, softer at the bottom.
    public func dim(_ amount: Double) -> CIImage {
        guard amount > 0.001 else { return .empty() }
        let top = CIColor(red: 0, green: 0, blue: 0, alpha: amount), bottom = CIColor(red: 0, green: 0, blue: 0, alpha: amount * 0.6)
        return CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: H), "inputPoint1": CIVector(x: 0, y: 0),
                                                               "inputColor0": top, "inputColor1": bottom])!.outputImage!.cropped(to: canvas)
    }
}

/// House motion curves for templates.
public enum Anim {
    /// 0…1 progress of [start, start + length] at t.
    public static func p(_ t: Double, _ start: Double, _ length: Double) -> Double { length <= 0 ? (t >= start ? 1 : 0) : min(max((t - start) / length, 0), 1) }

    public static func ease(_ x: Double, _ e: Easing = .easeOut) -> Double { e.apply(x) }

    /// A tame spring 0 → 1 (≈ 6 % overshoot, settled in ~`length` s).
    public static func spring(_ t: Double, _ start: Double = 0, length: Double = 0.45) -> Double {
        let x = (t - start) / max(length, 0.01)
        guard x > 0 else { return 0 }
        guard x < 1.6 else { return 1 }
        return 1 - exp(-5.2 * x) * cos(4.6 * x)
    }

    /// Entrance (0 → 1 over `inLength` from 0) times exit (1 → 0 over the last `outLength` s of `d`).
    public static func envelope(_ t: Double, _ d: Double, in inLength: Double = 0.35, out outLength: Double = 0.25) -> Double {
        let a = inLength > 0 ? Easing.easeOut.apply(t / inLength) : 1
        let b = outLength > 0 ? Easing.easeIn.apply((d - t) / outLength) : 1
        return min(max(min(a, b), 0), 1)
    }

    /// The exit progress 0 → 1 over the last `length` seconds.
    public static func exit(_ t: Double, _ d: Double, _ length: Double = 0.25) -> Double { Easing.easeIn.apply(p(t, d - length, length)) }

    /// A damped oscillation: amplitude × e^(−decay·t) × cos(2π·freq·t).
    public static func damped(_ t: Double, amplitude: Double, frequency: Double, decay: Double) -> Double {
        t < 0 ? amplitude : amplitude * exp(-decay * t) * cos(2 * .pi * frequency * t)
    }
}

/// Core Graphics drawing helpers (top-left origin contexts from `MotionCanvas.sprite`).
public enum Draw {
    public static func attributed(_ s: String, _ font: CTFont, _ color: CGColor, tracking: Double = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                   NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                                                   NSAttributedString.Key(kCTKernAttributeName as String): tracking])
    }

    /// Typographic width of a single line.
    public static func width(_ s: String, _ font: CTFont, tracking: Double = 0) -> Double {
        CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(s, font, CGColor(gray: 0, alpha: 1), tracking: tracking)), nil, nil, nil)
    }

    /// One line of text with its baseline at y (top-left origin context); align 0 = left at x, 0.5 = centred, 1 = right.
    @discardableResult
    public static func text(_ ctx: CGContext, _ s: String, _ font: CTFont, _ color: CGColor, x: Double, baseline y: Double, align: Double = 0,
                            tracking: Double = 0) -> Double {
        let line = CTLineCreateWithAttributedString(attributed(s, font, color, tracking: tracking))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x - w * align, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return w
    }

    /// Text vertically centred on `cy` (cap height centred).
    @discardableResult
    public static func text(_ ctx: CGContext, _ s: String, _ font: CTFont, _ color: CGColor, x: Double, centreY cy: Double, align: Double = 0,
                            tracking: Double = 0) -> Double {
        text(ctx, s, font, color, x: x, baseline: cy + CTFontGetCapHeight(font) / 2, align: align, tracking: tracking)
    }

    public static func roundedRect(_ ctx: CGContext, _ r: CGRect, radius: Double, fill: CGColor?, stroke: CGColor? = nil, lineWidth: Double = 1) {
        let path = CGPath(roundedRect: r, cornerWidth: min(radius, r.width / 2), cornerHeight: min(radius, r.height / 2), transform: nil)
        if let fill { ctx.addPath(path); ctx.setFillColor(fill); ctx.fillPath() }
        if let stroke { ctx.addPath(path); ctx.setStrokeColor(stroke); ctx.setLineWidth(lineWidth); ctx.strokePath() }
    }

    /// A card: rounded rectangle with a soft shadow under it (leave `shadowRoom` around it in the sprite).
    public static func card(_ ctx: CGContext, _ r: CGRect, radius: Double, fill: CGColor, shadow: Double = 0.22, blur: Double = 30, dy: Double = 10,
                            stroke: CGColor? = nil) {
        ctx.saveGState()
        if shadow > 0 { ctx.setShadow(offset: CGSize(width: 0, height: dy), blur: blur, color: CGColor(gray: 0, alpha: shadow)) }
        roundedRect(ctx, r, radius: radius, fill: fill)
        ctx.restoreGState()
        if let stroke { roundedRect(ctx, r.insetBy(dx: 0.5, dy: 0.5), radius: radius, fill: nil, stroke: stroke, lineWidth: 1) }
    }

    /// The "console" panel of the round-3 templates: dark warm glass with a thin accent border that glows.
    public static func console(_ ctx: CGContext, _ r: CGRect, radius: Double, accent: CGColor, glow: Double = 18, fillAlpha: Double = 0.92) {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: glow, color: accent.copy(alpha: 0.55))
        roundedRect(ctx, r, radius: radius, fill: TitleRasterizer.color("#16110D", alpha: fillAlpha), stroke: accent, lineWidth: max(glow / 9, 1.5))
        ctx.restoreGState()
    }

    /// An SF Symbol fitted into a rect in a colour.
    public static func symbol(_ ctx: CGContext, _ name: String, in r: CGRect, color: CGColor, weight: NSFont.Weight = .semibold) {
        let ns = NSColor(cgColor: color) ?? .white
        let config = NSImage.SymbolConfiguration(pointSize: r.height, weight: weight).applying(.init(paletteColors: [ns]))
        guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        var pr = CGRect(origin: .zero, size: sym.size)
        guard let cg = sym.cgImage(forProposedRect: &pr, context: nil, hints: nil) else { return }
        let f = min(r.width / sym.size.width, r.height / sym.size.height)
        let w = sym.size.width * f, h = sym.size.height * f
        ctx.saveGState()
        // The context is flipped: draw the image upright.
        ctx.translateBy(x: r.midX - w / 2, y: r.midY + h / 2)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.restoreGState()
    }

    /// A check mark inside a rect, drawn up to `progress` (0…1) of its stroke.
    public static func check(_ ctx: CGContext, in r: CGRect, color: CGColor, width: Double, progress: Double = 1) {
        let a = CGPoint(x: r.minX + r.width * 0.22, y: r.minY + r.height * 0.52), b = CGPoint(x: r.minX + r.width * 0.42, y: r.minY + r.height * 0.72),
            c = CGPoint(x: r.minX + r.width * 0.78, y: r.minY + r.height * 0.3)
        let l1 = hypot(b.x - a.x, b.y - a.y), l2 = hypot(c.x - b.x, c.y - b.y)
        let target = (l1 + l2) * min(max(progress, 0), 1)
        guard target > 0 else { return }
        ctx.saveGState()
        ctx.setStrokeColor(color); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        ctx.move(to: a)
        if target <= l1 { ctx.addLine(to: CGPoint(x: a.x + (b.x - a.x) * target / l1, y: a.y + (b.y - a.y) * target / l1)) }
        else {
            ctx.addLine(to: b)
            let f = (target - l1) / l2
            ctx.addLine(to: CGPoint(x: b.x + (c.x - b.x) * f, y: b.y + (c.y - b.y) * f))
        }
        ctx.strokePath()
        ctx.restoreGState()
    }
}
