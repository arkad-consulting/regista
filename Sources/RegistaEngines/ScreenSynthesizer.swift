import AVFoundation
import CoreGraphics
import CoreText
import Foundation
import RegistaCore

/// Draws the synthetic screen recording of recording.synthesize: a dark desktop with a code editor and a browser
/// window, the session clock, buttons under the click targets, the cursor, click ripples, and white sync frames.
/// H.264 High in a .mov at the requested size and frame rate (AVAssetWriter).
public struct CGScreenSynthesizer: ScreenSynthesizer {
    public init() {}

    public func write(_ s: SyntheticScreen) throws {
        try? FileManager.default.removeItem(at: s.output)
        let writer = try AVAssetWriter(outputURL: s.output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: s.width, AVVideoHeightKey: s.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000, AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                                              AVVideoExpectedSourceFrameRateKey: s.fps, AVVideoMaxKeyFrameIntervalKey: s.fps],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: s.width, kCVPixelBufferHeightKey as String: s.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw CommandError(.io, "recording.synthesize: cannot write \(s.output.lastPathComponent): \(writer.error?.localizedDescription ?? "?")") }
        writer.startSession(atSourceTime: .zero)
        let scene = Scene(s)
        for i in 0..<s.frames {
            while !input.isReadyForMoreMediaData { usleep(500) }
            guard let pool = adaptor.pixelBufferPool else { throw CommandError(.io, "recording.synthesize: no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw CommandError(.io, "recording.synthesize: no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: s.width, height: s.height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            scene.draw(frame: i, in: ctx)
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(s.fps))) else {
                throw CommandError(.io, "recording.synthesize: encoding failed at frame \(i): \(writer.error?.localizedDescription ?? "?")")
            }
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw CommandError(.io, "recording.synthesize: \(writer.error?.localizedDescription ?? "writing failed")") }
    }

    /// The desktop drawn once, then the moving parts per frame. Coordinates top-left origin (the context is flipped).
    final class Scene {
        let s: SyntheticScreen
        let W: Double, H: Double
        let background: CGImage
        let editor: CGRect, browser: CGRect

        init(_ s: SyntheticScreen) {
            self.s = s
            W = Double(s.width); H = Double(s.height)
            editor = CGRect(x: 0.078 * W, y: 0.11 * H, width: 0.54 * W, height: 0.61 * H)
            browser = CGRect(x: 0.526 * W, y: 0.315 * H, width: 0.406 * W, height: 0.52 * H)
            let ctx = Self.context(s.width, s.height)
            background = Self.drawBackground(ctx, W: W, H: H, editor: editor, browser: browser, buttons: s.buttons)
        }

        static func context(_ w: Int, _ h: Int) -> CGContext {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: Double(h))
            ctx.scaleBy(x: 1, y: -1)
            return ctx
        }

        static func color(_ hex: UInt32, _ a: Double = 1) -> CGColor {
            CGColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, alpha: a)
        }

        /// Text with its baseline-left at (x, y) in the flipped context.
        static func text(_ ctx: CGContext, _ string: String, x: Double, y: Double, size: Double, color: CGColor, bold: Bool = false, mono: Bool = false) {
            let name = mono ? "Menlo-Regular" : (bold ? "HelveticaNeue-Bold" : "HelveticaNeue")
            let font = CTFontCreateWithName(name as CFString, size, nil)
            let attr = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                       NSAttributedString.Key(kCTForegroundColorAttributeName as String): color])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            ctx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }

        static func textWidth(_ string: String, size: Double, bold: Bool) -> Double {
            let font = CTFontCreateWithName((bold ? "HelveticaNeue-Bold" : "HelveticaNeue") as CFString, size, nil)
            let attr = NSAttributedString(string: string, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            return CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attr), nil, nil, nil)
        }

        static func window(_ ctx: CGContext, _ r: CGRect, title: String, dark: Bool, W: Double) {
            let k = W / 1920
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 40 * k, color: color(0x000000, 0.45))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12 * k, cornerHeight: 12 * k, transform: nil))
            ctx.setFillColor(color(dark ? 0x1E2228 : 0xF5F6F8))
            ctx.fillPath()
            ctx.restoreGState()
            // Title bar.
            let bar = CGRect(x: r.minX, y: r.minY, width: r.width, height: 38 * k)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12 * k, cornerHeight: 12 * k, transform: nil))
            ctx.clip()
            ctx.setFillColor(color(dark ? 0x2A2F37 : 0xE4E6EA))
            ctx.fill(bar)
            ctx.restoreGState()
            for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
                ctx.setFillColor(color(c))
                ctx.fillEllipse(in: CGRect(x: r.minX + (16 + 22 * Double(i)) * k, y: r.minY + 13 * k, width: 12 * k, height: 12 * k))
            }
            text(ctx, title, x: r.midX - textWidth(title, size: 15 * k, bold: false) / 2, y: r.minY + 25 * k, size: 15 * k,
                 color: color(dark ? 0xB8BEC8 : 0x4A505A))
        }

        static func drawBackground(_ ctx: CGContext, W: Double, H: Double, editor: CGRect, browser: CGRect, buttons: [SyntheticScreen.Button]) -> CGImage {
            let k = W / 1920
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [color(0x1B2740), color(0x352B52)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: W, y: H), options: [])
            // A faint grid: makes zoom and pan easy to read on the contact sheets.
            ctx.setStrokeColor(color(0xFFFFFF, 0.06))
            ctx.setLineWidth(1)
            for x in stride(from: 0.0, to: W, by: 64 * k) { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: H)) }
            for y in stride(from: 0.0, to: H, by: 64 * k) { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: W, y: y)) }
            ctx.strokePath()
            // Menu bar.
            ctx.setFillColor(color(0x0E1220, 0.7))
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: 30 * k))
            text(ctx, "Regista Demo     File     Modifica     Vista     Finestra", x: 22 * k, y: 21 * k, size: 15 * k, color: color(0xE8ECF4), bold: false)

            window(ctx, editor, title: "sito.astro — Editor", dark: true, W: W)
            // Code lines: deterministic widths and colours.
            let palette: [UInt32] = [0xC678DD, 0x61AFEF, 0x98C379, 0xE5C07B, 0xABB2BF, 0x56B6C2]
            var seed: UInt64 = 7
            func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
            for line in 0..<20 {
                let y = editor.minY + (70 + 25 * Double(line)) * k
                text(ctx, String(format: "%2d", line + 1), x: editor.minX + 18 * k, y: y + 9 * k, size: 13 * k, color: color(0x5C6370), mono: true)
                var x = editor.minX + (60 + 26 * Double(line % 5 == 0 ? 0 : (line % 3))) * k
                for _ in 0..<(1 + Int(rnd() * 4)) {
                    let w = (40 + rnd() * 160) * k
                    if x + w > editor.maxX - 30 * k { break }
                    ctx.setFillColor(color(palette[Int(rnd() * Double(palette.count)) % palette.count], 0.85))
                    ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: 11 * k), cornerWidth: 3 * k, cornerHeight: 3 * k, transform: nil))
                    ctx.fillPath()
                    x += w + 12 * k
                }
            }
            window(ctx, browser, title: "wesites.it — Anteprima", dark: false, W: W)
            // Address bar, hero, cards.
            let addr = CGRect(x: browser.minX + 20 * k, y: browser.minY + 50 * k, width: browser.width - 40 * k, height: 30 * k)
            ctx.setFillColor(color(0xFFFFFF))
            ctx.addPath(CGPath(roundedRect: addr, cornerWidth: 8 * k, cornerHeight: 8 * k, transform: nil))
            ctx.fillPath()
            text(ctx, "https://wesites.it/demo", x: addr.minX + 14 * k, y: addr.minY + 21 * k, size: 14 * k, color: color(0x5A606A))
            text(ctx, "Il tuo sito, pronto.", x: browser.minX + 40 * k, y: browser.minY + 150 * k, size: 40 * k, color: color(0x14161A), bold: true)
            text(ctx, "Veloce, sicuro, tuo. Pubblica in un clic.", x: browser.minX + 40 * k, y: browser.minY + 190 * k, size: 19 * k, color: color(0x5A606A))
            for i in 0..<3 {
                let r = CGRect(x: browser.minX + (40 + 240 * Double(i)) * k, y: browser.minY + 230 * k, width: 220 * k, height: 150 * k)
                ctx.setFillColor(color([UInt32(0xDDE6FF), 0xFFE7D6, 0xDDF5E6][i]))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12 * k, cornerHeight: 12 * k, transform: nil))
                ctx.fillPath()
            }
            for b in buttons {
                let w = textWidth(b.label, size: 18 * k, bold: true) + 48 * k, h = 44 * k
                let r = CGRect(x: b.x - w / 2, y: b.y - h / 2, width: w, height: h)
                ctx.setFillColor(color(0x2F6BFF))
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil))
                ctx.fillPath()
                text(ctx, b.label, x: r.minX + 24 * k, y: r.minY + 28 * k, size: 18 * k, color: color(0xFFFFFF), bold: true)
            }
            return ctx.makeImage()!
        }

        static func cursorPath(at p: CGPoint, scale k: Double) -> CGPath {
            let pts: [(Double, Double)] = [(0, 0), (0, 17), (4.2, 13.2), (7.2, 20), (10, 18.8), (7.1, 12.3), (12.6, 12.3)]
            let path = CGMutablePath()
            path.addLines(between: pts.map { CGPoint(x: p.x + $0.0 * 1.5 * k, y: p.y + $0.1 * 1.5 * k) })
            path.closeSubpath()
            return path
        }

        func draw(frame i: Int, in raw: CGContext) {
            let ctx = raw
            ctx.saveGState()
            ctx.translateBy(x: 0, y: H)
            ctx.scaleBy(x: 1, y: -1)
            defer { ctx.restoreGState() }
            if s.flashes.contains(i) {
                ctx.setFillColor(Self.color(0xFFFFFF))
                ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
                return
            }
            // The background image is drawn in an unflipped space.
            ctx.saveGState()
            ctx.translateBy(x: 0, y: H)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(background, in: CGRect(x: 0, y: 0, width: W, height: H))
            ctx.restoreGState()
            let k = W / 1920
            let t = Double(i) / Double(s.fps)
            // Session clock and a progress bar in the editor.
            let clock = t + s.clockOffset
            let label = String(format: "%02d:%05.2f", Int(clock) / 60, clock.truncatingRemainder(dividingBy: 60))
            Self.text(ctx, label, x: editor.minX + 24 * k, y: editor.maxY - 28 * k, size: 40 * k, color: Self.color(0xFFFFFF, 0.9), mono: true)
            let bar = CGRect(x: editor.minX + 270 * k, y: editor.maxY - 48 * k, width: 0.84 * (browser.minX - editor.minX) - 270 * k, height: 8 * k)
            ctx.setFillColor(Self.color(0xFFFFFF, 0.12))
            ctx.fill(bar)
            ctx.setFillColor(Self.color(0x61AFEF))
            ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * min(t / max(Double(s.frames) / Double(s.fps), 0.01), 1), height: bar.height))
            // Ripples and cursor (a take recorded without the system cursor has neither: the compositor draws them).
            guard s.drawsCursor else { return }
            for c in s.clicks {
                let dt = t - c.t
                guard dt >= 0, dt < 0.5 else { continue }
                let f = dt / 0.5
                let r = (10 + 46 * f) * k
                ctx.setStrokeColor(Self.color(0x4C8DFF, 0.9 * (1 - f)))
                ctx.setLineWidth(4 * k)
                ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                if dt < 0.15 {
                    ctx.setFillColor(Self.color(0x4C8DFF, 0.5))
                    ctx.fillEllipse(in: CGRect(x: c.x - 12 * k, y: c.y - 12 * k, width: 24 * k, height: 24 * k))
                }
            }
            // Cursor.
            let p = s.cursor[min(i, s.cursor.count - 1)]
            let path = Self.cursorPath(at: CGPoint(x: p[0], y: p[1]), scale: k)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -2 * k), blur: 4 * k, color: Self.color(0x000000, 0.4))
            ctx.addPath(path)
            ctx.setFillColor(Self.color(0x000000))
            ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(path)
            ctx.setStrokeColor(Self.color(0xFFFFFF))
            ctx.setLineWidth(1.6 * k)
            ctx.strokePath()
        }
    }
}
