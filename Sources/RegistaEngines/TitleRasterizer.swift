import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import ImageIO
import RegistaCore

/// Draws a `Title` with Core Text at the output scale: lines (wrapped at maxWidth), per-word highlight colour,
/// tracking, optional outline, a box or pill behind, a soft shadow. Returns the image and the box inside it
/// (the shadow spills outside the box; layout uses the box).
enum TitleRasterizer {
    struct Rendered {
        var image: CGImage
        /// The box (background, or the text block when there is none), image pixels, top-left origin.
        var box: CGRect
        /// The box centre, image pixels, bottom-left origin (Core Image).
        var anchor: CGPoint { CGPoint(x: box.midX, y: Double(image.height) - box.midY) }
    }

    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let fontLock = NSLock()
    nonisolated(unsafe) private static var fontFiles: [String: CTFontDescriptor] = [:]

    /// A font from a file path (.ttf/.otf/.woff2), a PostScript or family name, or a supplemental system font.
    static func font(_ spec: String, size: Double) throws -> CTFont {
        let path = EngineConfig.expand(spec)
        if spec.contains("/") || [".ttf", ".otf", ".woff2", ".woff", ".ttc"].contains(where: spec.lowercased().hasSuffix) {
            fontLock.lock(); defer { fontLock.unlock() }
            if let d = fontFiles[path] { return CTFontCreateWithFontDescriptor(d, size, nil) }
            guard FileManager.default.fileExists(atPath: path),
                  let descs = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: path) as CFURL) as? [CTFontDescriptor], let d = descs.first else {
                throw CommandError(.notFound, "title font file \(path) not found or unreadable")
            }
            fontFiles[path] = d
            return CTFontCreateWithFontDescriptor(d, size, nil)
        }
        let f = CTFontCreateWithName(spec as CFString, size, nil)
        let ps = CTFontCopyPostScriptName(f) as String, family = CTFontCopyFamilyName(f) as String
        if ps == spec || family == spec { return f }
        return try CaptionRasterizer.font(spec, size: size)
    }

    static func color(_ hex: String, alpha: Double = 1) -> CGColor {
        let c = GraphicsStore.rgb(hex)
        return CGColor(colorSpace: space, components: [c.0, c.1, c.2, alpha])!
    }

    /// Greedy word wrap of one paragraph at `width` points.
    static func wrap(_ text: String, width: Double?, measure: (String) -> Double) -> [String] {
        guard let width else { return [text] }
        var lines: [String] = [], current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if !current.isEmpty, measure(candidate) > width { lines.append(current); current = word } else { current = candidate }
        }
        lines.append(current)
        return lines
    }

    static func render(_ title: Title, outputWidth: Int) throws -> Rendered {
        let k = Double(outputWidth) / SafeZones.referenceWidth
        let size = title.size * k
        let font = try font(title.font, size: size)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let highlight = Set((title.highlight ?? []).map { normalize($0) })
        let strokeW = (title.stroke?.width ?? 0) * k

        func attributed(_ line: String) -> NSAttributedString {
            let s = NSMutableAttributedString()
            let words = line.split(separator: " ", omittingEmptySubsequences: false)
            for (i, w) in words.enumerated() {
                let hot = !highlight.isEmpty && highlight.contains(normalize(String(w)))
                var attrs: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(hot ? (title.highlightColor ?? title.color) : title.color),
                ]
                if let t = title.tracking, t != 0 { attrs[NSAttributedString.Key(kCTKernAttributeName as String)] = t * k }
                s.append(NSAttributedString(string: String(w) + (i < words.count - 1 ? " " : ""), attributes: attrs))
            }
            return s
        }
        func width(_ line: String) -> Double { CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(line)), nil, nil, nil) }

        let lines = title.displayText.components(separatedBy: "\n").flatMap { wrap($0, width: title.maxWidth.map { $0 * k - 2 * (title.background?.padX ?? 0) * k }, measure: width) }
        let ctLines = lines.map { CTLineCreateWithAttributedString(attributed($0)) }
        let widths = ctLines.map { CTLineGetTypographicBounds($0, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth($0) }
        let lineH = (title.lineHeight ?? 1.15) * size
        let textW = widths.max() ?? 0
        let textH = Double(max(lines.count - 1, 0)) * lineH + ascent + descent
        let padX = (title.background?.padX ?? 0) * k, padY = (title.background?.padY ?? 0) * k
        let boxW = textW + 2 * padX + strokeW, boxH = textH + 2 * padY + strokeW
        var margin = strokeW + 4
        if let sh = title.shadow { margin += sh.blur * k * 1.5 + max(abs(sh.x), abs(sh.y)) * k }
        let W = Int((boxW + 2 * margin).rounded(.up)), H = Int((boxH + 2 * margin).rounded(.up))
        let c = CaptionRasterizer.context(max(W, 1), max(H, 1))
        let boxRect = CGRect(x: margin, y: Double(H) - margin - boxH, width: boxW, height: boxH)   // CG coordinates

        func withShadow(_ body: () -> Void) {
            c.saveGState()
            if let sh = title.shadow {
                c.setShadow(offset: CGSize(width: sh.x * k, height: -sh.y * k), blur: sh.blur * k, color: color(sh.color, alpha: sh.opacity))
            }
            body()
            c.restoreGState()
        }
        if let bg = title.background {
            let radius = bg.kind == "pill" ? boxH / 2 : min((bg.radius ?? 16) * k, boxH / 2)
            withShadow {
                c.addPath(CGPath(roundedRect: boxRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                c.setFillColor(color(bg.color, alpha: bg.opacity ?? 1))
                c.fillPath()
            }
        }
        let align = title.align ?? "center"
        func drawText(stroke: Bool) {
            for (i, line) in ctLines.enumerated() {
                let x: Double = switch align {
                case "left": boxRect.minX + padX + strokeW / 2
                case "right": boxRect.maxX - padX - strokeW / 2 - widths[i]
                default: boxRect.minX + (boxW - widths[i]) / 2
                }
                let baseline = boxRect.maxY - padY - strokeW / 2 - ascent - Double(i) * lineH
                c.textPosition = CGPoint(x: x, y: baseline)
                if stroke {
                    c.setTextDrawingMode(.stroke)
                    c.setLineWidth(strokeW)
                    c.setLineJoin(.round)
                    c.setStrokeColor(color(title.stroke?.color ?? "#000000"))
                    // Stroke every glyph run with the outline colour (the runs carry their own fill colours).
                    for run in CTLineGetGlyphRuns(line) as! [CTRun] { CTRunDraw(run, c, CFRange(location: 0, length: 0)) }
                } else {
                    c.setTextDrawingMode(.fill)
                    CTLineDraw(line, c)
                }
            }
        }
        if strokeW > 0 { drawText(stroke: true) }
        if title.background == nil { withShadow { drawText(stroke: false) } } else { drawText(stroke: false) }
        guard let image = c.makeImage() else { throw CommandError(.io, "title: cannot draw \"\(title.text)\"") }
        return Rendered(image: image, box: CGRect(x: margin, y: margin, width: boxW, height: boxH))
    }

    static func normalize(_ w: String) -> String {
        w.lowercased().trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
    }
}

/// Caches for the compositor: decoded image files (stills, sequence frames), rendered titles, LUT cubes.
final class GraphicsStore: @unchecked Sendable {
    private let lock = NSLock()
    private var images: [String: CIImage] = [:]
    private var order: [String] = []
    private struct TitleKey: Hashable { var title: Title; var width: Int }
    private var titles: [TitleKey: TitleRasterizer.Rendered] = [:]
    private var cubes: [String: (size: Int, data: Data)] = [:]

    func image(_ path: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let i = images[path] { return i }
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let img = CIImage(cgImage: cg)
        images[path] = img
        order.append(path)
        if order.count > 96 { images[order.removeFirst()] = nil }
        return img
    }

    func title(_ t: Title, outputWidth: Int) throws -> TitleRasterizer.Rendered {
        let key = TitleKey(title: t, width: outputWidth)
        lock.lock()
        if let r = titles[key] { lock.unlock(); return r }
        lock.unlock()
        let r = try TitleRasterizer.render(t, outputWidth: outputWidth)
        lock.lock(); titles[key] = r; lock.unlock()
        return r
    }

    /// A .cube LUT as Core Image cube data (RGBA float32).
    func cube(_ path: String) -> (size: Int, data: Data)? {
        lock.lock(); defer { lock.unlock() }
        if let c = cubes[path] { return c }
        guard let lut = try? CubeLUT.load(path) else { return nil }
        var rgba = [Float](repeating: 1, count: lut.size * lut.size * lut.size * 4)
        for i in 0..<(lut.size * lut.size * lut.size) {
            rgba[4 * i] = lut.values[3 * i]; rgba[4 * i + 1] = lut.values[3 * i + 1]; rgba[4 * i + 2] = lut.values[3 * i + 2]
        }
        let c = (lut.size, rgba.withUnsafeBufferPointer { Data(buffer: $0) })
        cubes[path] = c
        return c
    }

    static func rgb(_ hex: String) -> (Double, Double, Double) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(h, radix: 16) ?? 0xFFFFFF
        return (Double((v >> 16) & 255) / 255, Double((v >> 8) & 255) / 255, Double(v & 255) / 255)
    }
}
