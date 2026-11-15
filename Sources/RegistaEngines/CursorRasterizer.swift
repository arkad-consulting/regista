import AppKit
import CoreImage
import RegistaCore

/// The drawn cursor of screen takes recorded without the system cursor (issue #42): the macOS cursor image of the
/// logged kind and click ripples, composited on the screen's source frame before its crop, so the zoom keyframes move
/// and magnify it like the rest of the screen.
final class CursorSprites: @unchecked Sendable {
    static let shared = CursorSprites()

    struct Sprite {
        let image: CIImage
        /// Hot spot, pixels from the image's top-left corner.
        let hotSpot: CGPoint
    }

    private var cache: [String: Sprite] = [:]
    private let lock = NSLock()

    /// The cursor of `kind` at `size` pixels per point (cached per kind and size).
    func sprite(_ kind: CursorKind, size: Double) -> Sprite {
        let key = "\(kind.rawValue)@\((size * 100).rounded())"
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        var cursor = kind.nsCursor
        if cursor.image.size.width < 1 {
            // Headless (regista-engine): the system cursors (arrow, I-beam) load only once the app object exists.
            Self.ensureApplication()
            cursor = kind.nsCursor
        }
        let sprite = Self.render(cursor, size: size) ?? Self.vectorArrow(size: size)
        cache[key] = sprite
        return sprite
    }

    /// The app object, made on the main thread. Made on another thread first, AppKit's main event queue belongs to
    /// that thread, and the first event the main thread asks for afterwards traps (a render of a cursor on a worker
    /// thread, then a click in a text field: the process died). A headless tool whose main thread is busy and never
    /// asks for events gets it here after a short wait, as before.
    static func ensureApplication(wait: TimeInterval = 3) {
        if Thread.isMainThread { _ = NSApplication.shared; return }
        let made = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { _ = NSApplication.shared; made.signal() }
        if made.wait(timeout: .now() + wait) == .timedOut { _ = NSApplication.shared }
    }

    static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func render(_ cursor: NSCursor, size: Double) -> Sprite? {
        let pts = cursor.image.size
        guard pts.width >= 1, pts.height >= 1 else { return nil }
        let w = max(Int((pts.width * size).rounded(.up)), 1), h = max(Int((pts.height * size).rounded(.up)), 1)
        guard let ctx = context(w, h) else { return nil }
        ctx.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        cursor.image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        return Sprite(image: CIImage(cgImage: img), hotSpot: CGPoint(x: cursor.hotSpot.x * size, y: cursor.hotSpot.y * size))
    }

    /// A plain black arrow with a white edge, for a host where AppKit gives no cursor image.
    static func vectorArrow(size: Double) -> Sprite {
        let pts: [(Double, Double)] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 20), (10, 18.8), (7.1, 12.3), (12.6, 12.3)]
        let pad = 2.0, w = Int(((13 + 2 * pad) * size).rounded(.up)), h = Int(((21 + 2 * pad) * size).rounded(.up))
        let ctx = context(w, h)!
        ctx.translateBy(x: 0, y: Double(h))
        ctx.scaleBy(x: 1, y: -1)
        let path = CGMutablePath()
        path.addLines(between: pts.map { CGPoint(x: ($0.0 + pad) * size, y: ($0.1 + pad) * size) })
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
        ctx.setLineWidth(1.2 * size)
        ctx.strokePath()
        return Sprite(image: CIImage(cgImage: ctx.makeImage()!), hotSpot: CGPoint(x: pad * size, y: pad * size))
    }

    /// An expanding ring (and a soft disc early on) at `progress` 0…1, centred in a square image.
    static func ripple(progress p: Double, size: Double, color hex: String?) -> (image: CIImage, radius: Double) {
        let maxR = 24 * size, lineWidth = 2.5 * size
        let half = Int((maxR + 3 * lineWidth).rounded(.up))
        let ctx = context(2 * half, 2 * half)!
        let ease = 1 - pow(1 - p, 3)
        let r = (5 + 19 * ease) * size
        let fade = pow(1 - p, 2)
        let c = GraphicsStore.rgb(hex ?? "#FFFFFF")
        let rect = CGRect(x: Double(half) - r, y: Double(half) - r, width: 2 * r, height: 2 * r)
        ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.28 * fade))
        ctx.fillEllipse(in: rect)
        // A dark halo under the ring keeps it visible on white windows.
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.35 * fade))
        ctx.setLineWidth(lineWidth + 2 * size)
        ctx.strokeEllipse(in: rect)
        ctx.setStrokeColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: 0.95 * fade))
        ctx.setLineWidth(lineWidth)
        ctx.strokeEllipse(in: rect)
        return (CIImage(cgImage: ctx.makeImage()!), Double(half))
    }
}

extension FrameDrawer {
    /// `frame` (a screen source frame, display pixels, bottom-left origin at 0,0) with the layer's drawn cursor on it.
    func withCursor(_ layer: VideoLayer, _ frame: CIImage) -> CIImage {
        guard let c = layer.cursor else { return frame }
        let H = frame.extent.height
        var out = frame
        for r in c.ripples {
            let (img, half) = CursorSprites.ripple(progress: r.progress, size: c.size, color: c.color)
            out = img.transformed(by: CGAffineTransform(translationX: r.x - half, y: H - r.y - half)).composited(over: out)
        }
        if c.opacity > 0.001 {
            let s = CursorSprites.shared.sprite(c.kind, size: c.size)
            var img = s.image
            if c.opacity < 1 { img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: c.opacity)]) }
            let h = img.extent.height
            out = img.transformed(by: CGAffineTransform(translationX: c.x - s.hotSpot.x, y: H - c.y - (h - s.hotSpot.y))).composited(over: out)
        }
        return out.cropped(to: frame.extent)
    }
}

extension CursorKind {
    /// The AppKit cursor of this kind.
    public var nsCursor: NSCursor {
        switch self {
        case .arrow: .arrow
        case .pointingHand: .pointingHand
        case .iBeam: .iBeam
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .resizeLeftRight: .resizeLeftRight
        case .resizeUpDown: .resizeUpDown
        case .notAllowed: .operationNotAllowed
        case .contextualMenu: .contextualMenu
        case .dragCopy: .dragCopy
        case .dragLink: .dragLink
        }
    }
}
