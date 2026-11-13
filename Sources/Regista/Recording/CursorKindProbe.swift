import AppKit
import RegistaCore
import RegistaEngines

/// Which standard cursor the system shows (issue #42): NSCursor.currentSystem is a fresh object each time and several
/// standard cursors share size and hot spot, so its image is compared pixel by pixel (at 1×) with the standard ones.
/// Anything unknown is the arrow.
@MainActor
final class CursorKindProbe {
    private struct Print {
        let kind: CursorKind
        let hotSpot: NSPoint
        let size: NSSize
        let pixels: [UInt8]
    }

    private lazy var prints: [Print] = CursorKind.allCases.compactMap { k in
        let c = k.nsCursor
        return Self.pixels(c.image).map { Print(kind: k, hotSpot: c.hotSpot, size: c.image.size, pixels: $0) }
    }

    func current() -> CursorKind {
        guard let c = NSCursor.currentSystem else { return .arrow }
        let same = prints.filter { $0.size == c.image.size && $0.hotSpot == c.hotSpot }
        guard !same.isEmpty, let px = Self.pixels(c.image) else { return .arrow }
        let best = same.map { p in (p.kind, zip(p.pixels, px).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) }.min { $0.1 < $1.1 }
        // Same picture up to resampling noise (mean difference under 4 levels per channel).
        guard let best, Double(best.1) / Double(max(px.count, 1)) < 4 else { return .arrow }
        return best.0
    }

    /// RGBA pixels of the image drawn at its point size.
    private static func pixels(_ image: NSImage) -> [UInt8]? {
        let w = Int(image.size.width), h = Int(image.size.height)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let n = ctx.bytesPerRow * h
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: n))
    }
}
