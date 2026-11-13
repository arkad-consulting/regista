import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import RegistaCore

/// Previews and contact sheets with Core Graphics (scaling) and Core Text (labels), written as JPEG.
public struct CGImageToolkit: ImageToolkit {
    public var quality = 0.85

    public init() {}

    public func writePreview(of image: URL, maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int) {
        let cg = try Self.load(image)
        let scale = min(1, Double(maxWidth) / Double(cg.width), Double(maxHeight) / Double(cg.height))
        let w = max(1, Int((Double(cg.width) * scale).rounded())), h = max(1, Int((Double(cg.height) * scale).rounded()))
        let c = try Self.context(w, h)
        c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        try write(c, to: output)
        return (w, h)
    }

    public func rasterizeSVG(_ svg: URL, width: Int, to output: URL) throws -> (width: Int, height: Int) {
        guard let data = FileManager.default.contents(atPath: svg.path), let image = NSImage(data: Self.normalizedSVG(data)), image.size.width > 0 else {
            throw CommandError(.io, "cannot read SVG \(svg.path)")
        }
        let w = max(width, 1), h = max(Int((Double(w) * image.size.height / image.size.width).rounded()), 1)
        let c = CaptionRasterizer.context(w, h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = c.makeImage() else { throw CommandError(.io, "cannot draw SVG \(svg.path)") }
        try CaptionRasterizer.writePNG(cg, to: output)
        return (w, h)
    }

    /// The SVG with its root width/height moved into a viewBox: drawn at another size, CoreSVG scales the shapes of
    /// an SVG with explicit width/height but not its userSpaceOnUse gradients (they land off target). With only a
    /// viewBox everything scales together.
    static func normalizedSVG(_ data: Data) -> Data {
        guard var text = String(data: data, encoding: .utf8), let open = text.range(of: "<svg\\b[^>]*>", options: .regularExpression) else { return data }
        var tag = String(text[open])
        func attr(_ name: String) -> String? {
            guard let r = tag.range(of: "\\s\(name)\\s*=\\s*[\"']([^\"']*)[\"']", options: .regularExpression) else { return nil }
            return String(tag[r]).split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
        }
        guard let w = attr("width"), let h = attr("height") else { return data }
        func number(_ s: String) -> Double? { Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789.").inverted)) }
        if attr("viewBox") == nil {
            guard let wn = number(w), let hn = number(h), !w.hasSuffix("%"), !h.hasSuffix("%") else { return data }
            tag = tag.replacingOccurrences(of: "<svg", with: "<svg viewBox=\"0 0 \(wn) \(hn)\"")
        }
        for name in ["width", "height"] {
            if let r = tag.range(of: "\\s\(name)\\s*=\\s*[\"'][^\"']*[\"']", options: .regularExpression) { tag.removeSubrange(r) }
        }
        text.replaceSubrange(open, with: tag)
        return Data(text.utf8)
    }

    public func alphaBounds(of images: [URL]) throws -> [Double]? {
        var box: CGRect?
        for url in images {
            let cg = try Self.load(url)
            let c = CaptionRasterizer.context(cg.width, cg.height)
            c.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            if let ink = CaptionRasterizer.ink(c) { box = box.map { $0.union(ink) } ?? ink }
        }
        return box.map { [$0.minX, $0.minY, $0.width, $0.height] }
    }

    public func writeContactSheet(_ images: [URL], labels: [String], maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int) {
        guard !images.isEmpty else { throw CommandError(.invalidParams, "contact sheet: no images") }
        let frames = try images.map(Self.load)
        let fw = Double(frames[0].width), fh = Double(frames[0].height)
        let gap = 8.0
        // Label strip under each cell: a fixed fraction of the cell width, at least 18 px.
        func layout(_ columns: Int) -> (cell: Double, label: Double, rows: Int) {
            let rows = (frames.count + columns - 1) / columns
            let byWidth = (Double(maxWidth) - gap * Double(columns + 1)) / Double(columns)
            // cell height = cell·fh/fw + label (label ≈ 0.12·cell, ≥ 18)
            var cell = byWidth
            let height = { (c: Double) in Double(rows) * (c * fh / fw + max(18, 0.12 * c)) + gap * Double(rows + 1) }
            while cell > 8 && height(cell) > Double(maxHeight) { cell -= 1 }
            return (cell.rounded(.down), max(18, 0.12 * cell).rounded(), rows)
        }
        let columns = (1...frames.count).max { layout($0).cell < layout($1).cell }!
        let (cell, label, rows) = layout(columns)
        let cellH = (cell * fh / fw).rounded()
        let W = Int(gap * Double(columns + 1) + cell * Double(columns)), H = Int(Double(rows) * (cellH + label) + gap * Double(rows + 1))
        let c = try Self.context(W, H)
        c.setFillColor(CGColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, (label * 0.62).rounded(), nil)
        for (i, frame) in frames.enumerated() {
            let col = i % columns, row = i / columns
            let x = gap + Double(col) * (cell + gap)
            let top = gap + Double(row) * (cellH + label + gap)   // from the top
            let y = Double(H) - top - cellH                          // Core Graphics origin is bottom-left
            c.draw(frame, in: CGRect(x: x, y: y, width: cell, height: cellH))
            guard i < labels.count else { continue }
            let text = NSAttributedString(string: labels[i], attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
            let line = CTLineCreateWithAttributedString(text)
            let width = CTLineGetTypographicBounds(line, nil, nil, nil)
            c.textPosition = CGPoint(x: x + (cell - width) / 2, y: y - label * 0.75)
            CTLineDraw(line, c)
        }
        try write(c, to: output)
        return (W, H)
    }

    public func rgba(of image: URL, width: Int, height: Int) throws -> [UInt8] {
        let cg = try Self.load(image)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        try out.withUnsafeMutableBytes { buf in
            guard let c = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
                throw CommandError(.io, "cannot allocate a \(width)×\(height) image")
            }
            c.interpolationQuality = .none
            c.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return out
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw CommandError(.io, "cannot read the image \(url.path)")
        }
        return image
    }

    static func context(_ w: Int, _ h: Int) throws -> CGContext {
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw CommandError(.io, "cannot allocate a \(w)×\(h) image")
        }
        c.interpolationQuality = .high
        return c
    }

    func write(_ c: CGContext, to url: URL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let image = c.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw CommandError(.io, "cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CommandError(.io, "cannot write \(url.path)") }
    }
}
