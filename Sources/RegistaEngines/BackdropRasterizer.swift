import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// The frame backdrop of a styled screen layout (issue #44): a colour, a linear or radial gradient computed per pixel
/// with a little dither (smooth ramps survive the 8-bit H.264 export without banding), or an image filling the frame.
/// Rendered once per backdrop and size, then reused for every frame.
final class BackdropStore: @unchecked Sendable {
    private struct Key: Hashable { var backdrop: Backdrop; var width: Int; var height: Int }
    private let lock = NSLock()
    private var cache: [Key: CIImage] = [:]

    func image(_ b: Backdrop, width: Int, height: Int, graphics: GraphicsStore) -> CIImage? {
        let key = Key(backdrop: b, width: width, height: height)
        lock.lock()
        if let img = cache[key] { lock.unlock(); return img }
        lock.unlock()
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let img: CIImage?
        switch b.kind {
        case .solid:
            let c = GraphicsStore.rgb(b.colors?.first ?? "#000000")
            img = CIImage(color: CIColor(red: c.0, green: c.1, blue: c.2)).cropped(to: canvas)
        case .image:
            img = b.path.flatMap { graphics.image($0) }.map { Self.aspectFill($0, canvas: canvas) }
        case .linear, .radial:
            img = Self.gradient(b, width: width, height: height).map { CIImage(cgImage: $0) }
        }
        guard let img else { return nil }
        lock.lock()
        if cache.count > 8 { cache.removeAll() }
        cache[key] = img
        lock.unlock()
        return img
    }

    /// The picture scaled to cover the frame, centred, cropped.
    static func aspectFill(_ image: CIImage, canvas: CGRect) -> CIImage {
        let e = image.extent
        let s = max(canvas.width / e.width, canvas.height / e.height)
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY).concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: (canvas.width - e.width * s) / 2, y: (canvas.height - e.height * s) / 2))
        return image.clampedToExtent().transformed(by: t).cropped(to: canvas)
    }

    /// Position 0…1 along the gradient of pixel (x, y) (top-left origin, pixel centres).
    static func ramp(_ b: Backdrop, width W: Double, height H: Double) -> (Double, Double) -> Double {
        if b.kind == .radial {
            let c = b.center ?? [0.5, 0.5]
            let cx = c[0] * W, cy = c[1] * H
            // To the farthest corner.
            let r = [(0.0, 0.0), (W, 0), (0, H), (W, H)].map { hypot($0.0 - cx, $0.1 - cy) }.max() ?? 1
            return { x, y in min(hypot(x - cx, y - cy) / max(r, 1), 1) }
        }
        // CSS: 0° points up, 90° right; the line spans the frame's projection on that direction.
        let a = (b.angle ?? 180) * .pi / 180
        let dx = sin(a), dy = -cos(a)
        let half = (abs(dx) * W + abs(dy) * H) / 2
        return { x, y in min(max(((x - W / 2) * dx + (y - H / 2) * dy) / max(2 * half, 1) + 0.5, 0), 1) }
    }

    static func gradient(_ b: Backdrop, width: Int, height: Int) -> CGImage? {
        let stops = (b.colors ?? []).map { GraphicsStore.rgb($0) }
        guard stops.count >= 2, width > 0, height > 0 else { return nil }
        let at = ramp(b, width: Double(width), height: Double(height))
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        var seed: UInt32 = 0x9E37_79B9
        bytes.withUnsafeMutableBufferPointer { px in
            for y in 0..<height {
                for x in 0..<width {
                    let t = at(Double(x) + 0.5, Double(y) + 0.5) * Double(stops.count - 1)
                    let k = min(Int(t), stops.count - 2), f = t - Double(k)
                    let a = stops[k], c = stops[k + 1]
                    // Triangular dither of ±1 LSB: no visible noise, no bands.
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let n1 = Double(seed >> 16 & 0xFF) / 255
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    let d = n1 - Double(seed >> 16 & 0xFF) / 255
                    let i = (y * width + x) * 4
                    px[i] = UInt8(min(max((a.0 + (c.0 - a.0) * f) * 255 + d, 0), 255).rounded())
                    px[i + 1] = UInt8(min(max((a.1 + (c.1 - a.1) * f) * 255 + d, 0), 255).rounded())
                    px[i + 2] = UInt8(min(max((a.2 + (c.2 - a.2) * f) * 255 + d, 0), 255).rounded())
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
