import CoreGraphics
import CoreText
import Foundation
import ImageIO
import RegistaCore

/// Draws caption words with Core Text glyph outlines, the way captions.py drew them with ImageMagick:
/// a plain word is a black outline (stroke centred on the glyph edge) under a white fill, trimmed to
/// its ink; a keyword is white on a box of the keyword colour, the box being the word's ink plus the
/// padding. Words of a chunk sit side by side, centred in the band, each centred vertically by its
/// own height. No files: everything stays in memory as CGImages.
final class CaptionRasterizer {
    struct Word { var image: CGImage; var x: Int; var y: Int }

    let style: CaptionStyle
    let scale: Double
    let font: CTFont
    let bandWidth: Int
    let bandHeight: Int
    private var words: [String: CGImage] = [:]
    /// Per word image: distance from its top row to the text baseline (baseline alignment, wrapped lines).
    private var baselines: [String: Int] = [:]
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    /// - size: the chunk's size factor (captions.place; 1 = the style's): the band grows with it.
    init(style: CaptionStyle, outputWidth: Int, size: Double = 1) throws {
        self.style = style
        scale = Double(outputWidth) / style.referenceWidth * size
        bandWidth = Int((Double(outputWidth) * size).rounded())
        bandHeight = Int((style.bandHeight * scale).rounded())
        font = try Self.font(style.font, size: style.fontSize * scale)
    }

    static func font(_ name: String, size: Double) throws -> CTFont {
        let f = CTFontCreateWithName(name as CFString, size, nil)
        if CTFontCopyPostScriptName(f) as String == name { return f }
        // Not registered: try the supplemental fonts folder (Impact lives there).
        let url = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/\(name).ttf") as CFURL
        if let descs = CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor], let d = descs.first {
            return CTFontCreateWithFontDescriptor(d, size, nil)
        }
        throw CommandError(.io, "caption font \(name) not found")
    }

    static func color(_ hex: String) -> CGColor {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(h, radix: 16) ?? 0xFFFFFF
        return CGColor(colorSpace: space, components: [CGFloat((v >> 16) & 255) / 255, CGFloat((v >> 8) & 255) / 255,
                                                       CGFloat(v & 255) / 255, 1])!
    }

    /// Glyph outlines of a line of text, baseline at y = 0.
    func path(_ text: String) -> CGPath {
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let path = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), positions = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
            let runFont = (CTRunGetAttributes(run) as Dictionary)[kCTFontAttributeName] as! CTFont
            for (g, p) in zip(glyphs, positions) {
                if let gp = CTFontCreatePathForGlyph(runFont, g, nil) {
                    path.addPath(gp, transform: CGAffineTransform(translationX: p.x, y: p.y))
                }
            }
        }
        return path
    }

    static func context(_ w: Int, _ h: Int) -> CGContext {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setShouldAntialias(true)
        return c
    }

    /// The ink box of a drawing (any non-transparent pixel), image coordinates (top-left origin).
    static func ink(_ c: CGContext) -> CGRect? {
        guard let data = c.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: c.bytesPerRow * c.height)
        var x0 = c.width, y0 = c.height, x1 = -1, y1 = -1
        for y in 0..<c.height {
            let row = p + y * c.bytesPerRow
            for x in 0..<c.width where row[4 * x + 3] != 0 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        return x1 < 0 ? nil : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// One word, trimmed like ImageMagick's -trim (+ border for keywords). Styles without an outline draw the fill
    /// only; keywords of `keywordMode: color` styles are the word in the accent colour, without a box.
    func word(_ text: String, keyword: Bool) -> CGImage {
        let key = "\(keyword ? "K" : "W")\(text)"
        if let cached = words[key] { return cached }
        let glyphs = path(text)
        let stroke = style.strokeWidth * scale
        let outlined = stroke >= 0.5
        let boxed = keyword && !style.keywordColorOnly
        let b = glyphs.boundingBoxOfPath
        let margin = (outlined ? stroke : 0) + 4
        let w = Int((b.width + 2 * margin).rounded(.up)), h = Int((b.height + 2 * margin).rounded(.up))
        let c = Self.context(max(w, 1), max(h, 1))
        c.translateBy(x: margin - b.minX, y: margin - b.minY)
        c.addPath(glyphs)
        if boxed {
            c.setFillColor(Self.color(style.keywordTextColor))
            c.fillPath()
        } else if !outlined {
            c.setFillColor(Self.color(keyword ? style.keywordBoxColor : style.textColor))
            c.fillPath()
        } else {
            c.setLineWidth(stroke)
            c.setLineJoin(.miter)
            c.setStrokeColor(Self.color(style.strokeColor))
            c.setFillColor(Self.color(style.strokeColor))
            c.drawPath(using: .fillStroke)
            c.addPath(glyphs)
            c.setFillColor(Self.color(keyword ? (style.keywordColorOnly ? style.keywordBoxColor : style.textColor) : style.textColor))
            c.fillPath()
        }
        let full = c.makeImage()!
        let inkBox = Self.ink(c) ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        var image = full.cropping(to: inkBox)!
        // Baseline row in the full canvas (top-left origin), then in the trimmed image.
        var baseline = Double(h) - (margin - b.minY) - inkBox.minY
        if boxed {
            let px = Int((style.boxPadX * scale).rounded()), py = Int((style.boxPadY * scale).rounded())
            let box = Self.context(image.width + 2 * px, image.height + 2 * py)
            box.setFillColor(Self.color(style.keywordBoxColor))
            box.fill(CGRect(x: 0, y: 0, width: box.width, height: box.height))
            box.draw(image, in: CGRect(x: px, y: py, width: image.width, height: image.height))
            image = box.makeImage()!
            baseline += Double(py)
        }
        words[key] = image
        baselines[key] = Int(baseline.rounded())
        return image
    }

    /// The chunk's words split into lines no wider than `maxLineWidth` (one line without it); two lines are balanced
    /// (the break that makes the longer line shortest), more are filled greedily.
    func lines(_ widths: [Int], gap: Int) -> [Range<Int>] {
        let n = widths.count
        func width(_ r: Range<Int>) -> Int { r.isEmpty ? 0 : widths[r].reduce(0, +) + gap * (r.count - 1) }
        guard let maxW = style.maxLineWidth.map({ Int(($0 * scale).rounded()) }), n > 1, width(0..<n) > maxW else { return [0..<n] }
        let two = (1..<n).map { k in (k, max(width(0..<k), width(k..<n))) }.min { $0.1 < $1.1 }!
        if two.1 <= maxW { return [0..<two.0, two.0..<n] }
        var out: [Range<Int>] = [], start = 0
        for i in 1...n where i == n || width(start..<(i + 1)) > maxW {
            out.append(start..<i)
            start = i
        }
        return out
    }

    /// Positions in the band (top-left origin), captions.py: x from (W − total) // 2, y = (H − h) // 2 — or, for
    /// baseline-aligned styles, every word of a line on one baseline; wrapped lines are stacked and centred.
    func layout(_ chunk: CaptionChunk) -> [Word] {
        let images = chunk.words.map { word($0.text, keyword: $0.keyword) }
        let bases = chunk.words.map { baselines["\($0.keyword ? "K" : "W")\($0.text)"] ?? 0 }
        let gap = Int((style.gap * scale).rounded())
        let rows = lines(images.map(\.width), gap: gap)
        let baselineAligned = style.wordAlign == "baseline"
        let pitch = Int((style.fontSize * 1.08 + (style.lineSpacing ?? 0.12 * style.fontSize)) * scale)
        // Ink above / below the baseline of each row, and the block's height.
        let above = rows.map { r in r.map { bases[$0] }.max() ?? 0 }
        let below = rows.map { r in r.map { images[$0].height - bases[$0] }.max() ?? 0 }
        let tallest = rows.map { r in r.map { images[$0].height }.max() ?? 0 }
        let blockH = rows.count == 1 ? (baselineAligned ? above[0] + below[0] : tallest[0])
            : (baselineAligned ? above[0] + (rows.count - 1) * pitch + below[rows.count - 1] : (rows.count - 1) * pitch + tallest[0])
        let top = Int((Double(bandHeight - blockH) / 2).rounded(.down))
        var out: [Word] = []
        for (li, r) in rows.enumerated() {
            let total = r.map { images[$0].width }.reduce(0, +) + gap * max(r.count - 1, 0)
            var x = Int((Double(bandWidth - total) / 2).rounded(.down))
            for i in r {
                let img = images[i]
                let y: Int
                if baselineAligned { y = top + above[0] + li * pitch - bases[i] }
                else if rows.count == 1 { y = Int((Double(bandHeight - img.height) / 2).rounded(.down)) }
                else { y = top + li * pitch + (tallest[0] - img.height) / 2 }
                out.append(Word(image: img, x: x, y: y))
                x += img.width + gap
            }
        }
        return out
    }

    /// The band with the first `count` words of a chunk (later words keep their place; ghost-karaoke styles draw them
    /// at `upcomingOpacity`), with the style's soft shadow.
    func state(_ chunk: CaptionChunk, count: Int) -> CGImage {
        let c = Self.context(bandWidth, bandHeight)
        if let o = style.shadowOpacity, o > 0 {
            c.setShadow(offset: CGSize(width: 0, height: -(style.shadowY ?? 3) * scale), blur: (style.shadowBlur ?? 14) * scale,
                        color: CGColor(colorSpace: Self.space, components: [0, 0, 0, CGFloat(o)])!)
        }
        let ghost = style.upcomingOpacity ?? 0
        for (k, w) in layout(chunk).enumerated() {
            if k >= count {
                guard ghost > 0 else { break }
                c.setAlpha(ghost)
            }
            c.draw(w.image, in: CGRect(x: w.x, y: bandHeight - w.y - w.image.height, width: w.image.width, height: w.image.height))
        }
        return c.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw CommandError(.io, "cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CommandError(.io, "cannot write \(url.path)") }
    }
}

/// The caption rasterizers of a job (one per chunk size) and where each chunk's band lands on the frame
/// (`RenderJob.captionBandOrigin`): the compositor, the layout, the timing templates and the MLT images share it.
final class CaptionBands {
    let job: RenderJob
    let captions: Captions
    private var rasterizers: [Double: CaptionRasterizer] = [:]

    init(job: RenderJob) throws {
        guard let c = job.captions else { throw CommandError(.io, "no captions to draw") }
        self.job = job
        captions = c
        rasterizers[1] = try CaptionRasterizer(style: c.style, outputWidth: job.width)
    }

    func rasterizer(chunk i: Int) -> CaptionRasterizer {
        let s = (captions.scale(chunk: i) * 1000).rounded() / 1000
        if let r = rasterizers[s] { return r }
        let r = (try? CaptionRasterizer(style: captions.style, outputWidth: job.width, size: s)) ?? rasterizers[1]!
        rasterizers[s] = r
        return r
    }

    /// Ink box of chunk `i`'s whole line inside its band [x, y, w, h] (later words keep their place).
    func line(chunk i: Int) -> [Double] {
        let words = rasterizer(chunk: i).layout(captions.chunks[i])
        guard let f = words.first else { return [0, 0, 0, 0] }
        var x0 = f.x, y0 = f.y, x1 = f.x + f.image.width, y1 = f.y + f.image.height
        for w in words { x0 = min(x0, w.x); y0 = min(y0, w.y); x1 = max(x1, w.x + w.image.width); y1 = max(y1, w.y + w.image.height) }
        return [Double(x0), Double(y0), Double(x1 - x0), Double(y1 - y0)]
    }

    /// Top-left corner of chunk `i`'s band on the frame, output pixels.
    func origin(chunk i: Int) -> (x: Double, y: Double) {
        let o = job.captionBandOrigin(chunk: i, line: captions.isManual(chunk: i) ? line(chunk: i) : [0, 0, 0, 0])
        return (o.x, o.y)
    }

    /// Word boxes of chunk `i` on the frame [x, y, w, h], output pixels.
    func wordBoxes(chunk i: Int) -> [[Double]] {
        let o = origin(chunk: i)
        return rasterizer(chunk: i).layout(captions.chunks[i]).map { [Double($0.x) + o.x, o.y + Double($0.y), Double($0.image.width), Double($0.image.height)] }
    }

    /// The band image of a state (the first `count` words of chunk `chunk`).
    func state(_ chunk: Int, count: Int) -> CGImage { rasterizer(chunk: chunk).state(captions.chunks[chunk], count: count) }
}
