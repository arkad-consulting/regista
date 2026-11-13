import CoreGraphics
import CoreImage
import CoreText
import Foundation
import RegistaCore

/// The HUD shapes of round 3 (issue #22): the halo under a held object, the top status row (REC pill + running timer,
/// chapter badge) and the stereo level meters. Drawn with Core Graphics into a buffer the size of their own region and
/// placed on the canvas (Core Image coordinates); the status row and the meters change every frame, the halo is cached.
enum HUDRasterizer {
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!

    static func rgb(_ hex: String, _ a: Double = 1) -> CGColor {
        let c = GraphicsStore.rgb(hex)
        return CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a)
    }

    /// A `w`×`h` drawing context (bottom-left origin) placed at the frame rect's top-left `x`, `top` of an `H`-high canvas.
    static func region(_ w: Int, _ h: Int, x: Double, top: Double, H: Double, _ draw: (CGContext) -> Void) -> CIImage? {
        guard w > 0, h > 0, let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setShouldAntialias(true)
        draw(c)
        guard let cg = c.makeImage() else { return nil }
        return CIImage(cgImage: cg).transformed(by: CGAffineTransform(translationX: x.rounded(), y: (H - top - Double(h)).rounded()))
    }

    static func line(_ text: String, font: String, size: Double, color: CGColor, kern: Double = 0) -> CTLine {
        let f = CTFontCreateWithName(font as CFString, size, nil)
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): f, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern]))
    }

    // MARK: Halo

    /// A perspective ellipse ring: a soft inner wash and a bright rim with a glow, growing in over `drawOn`.
    static func halo(_ s: ShapeLayer, progress p: Double, w: Int, h: Int) -> CIImage? {
        let W = Double(w), H = Double(h), k = W / SafeZones.referenceWidth
        let r = s.rect
        let pad = 40 * k
        let rw = r[2] * W, rh = r[3] * H
        let grow = 0.6 + 0.4 * p
        return region(Int(rw + 2 * pad), Int(rh + 2 * pad), x: r[0] * W - pad, top: r[1] * H - pad, H: H) { c in
            let e = CGRect(x: pad + rw * (1 - grow) / 2, y: pad + rh * (1 - grow) / 2, width: rw * grow, height: rh * grow)
            c.setAlpha(p)
            c.setShadow(offset: .zero, blur: 30 * k, color: rgb(s.color, 0.7))
            c.setFillColor(rgb(s.color, 0.16))
            c.fillEllipse(in: e)
            c.setShadow(offset: .zero, blur: 12 * k, color: rgb(s.color, 1))
            c.setStrokeColor(rgb(s.color, 0.95))
            c.setLineWidth(max(s.width, 1) * k)
            c.strokeEllipse(in: e)
            // A thin white core on the near (lower) half for a lit-edge look.
            c.setShadow(offset: .zero, blur: 0, color: nil)
            c.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
            c.setLineWidth(1.2 * k)
            c.saveGState()
            c.translateBy(x: e.midX, y: e.midY)
            c.scaleBy(x: e.width / 2, y: e.height / 2)
            c.addArc(center: .zero, radius: 1, startAngle: .pi * 1.1, endAngle: .pi * 1.9, clockwise: false)
            c.restoreGState()
            c.strokePath()
        }
    }

    // MARK: Status bar

    /// "00:01:10" from seconds.
    static func clock(_ s: Double) -> String {
        let t = max(Int(s.rounded(.down)), 0)
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// The REC pill on the left (pulsing dot, label, timer) and the chapter badge on the right; a new chapter slides in.
    static func statusBar(_ s: ShapeLayer, time t: Double, w: Int, h: Int) -> CIImage? {
        let W = Double(w), H = Double(h), k = W / SafeZones.referenceWidth
        let r = s.rect
        let x0 = r[0] * W, top = r[1] * H, bw = r[2] * W
        let ph = 44 * k
        let accent = s.color
        let mono = "Menlo-Bold"
        return region(Int(bw), Int(ph + 24 * k), x: x0, top: top, H: H) { c in
            let y = 12 * k
            func pill(_ x: Double, _ width: Double, alpha: Double) {
                let p = CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: ph), cornerWidth: ph / 2, cornerHeight: ph / 2, transform: nil)
                c.setAlpha(alpha)
                c.addPath(p); c.setFillColor(CGColor(gray: 0.04, alpha: 0.72)); c.fillPath()
                c.addPath(p); c.setStrokeColor(rgb(accent, 0.35)); c.setLineWidth(1.5 * k); c.strokePath()
            }
            // Left: ● LABEL  00:00:00
            let label = line((s.label ?? "LIVE").uppercased(), font: mono, size: 19 * k, color: CGColor(gray: 1, alpha: 0.9), kern: 2 * k)
            let timer = line(clock((s.timerStart ?? 0) + t * (s.timerRate ?? 1)), font: mono, size: 19 * k, color: rgb(accent, 0.95), kern: 1.5 * k)
            let lb = CTLineGetBoundsWithOptions(label, .useOpticalBounds), tb = CTLineGetBoundsWithOptions(timer, .useOpticalBounds)
            let padX = 18 * k, dot = 12 * k
            let leftW = padX + dot + 12 * k + lb.width + 14 * k + tb.width + padX
            pill(0, leftW, alpha: 1)
            c.setAlpha(0.45 + 0.55 * (0.5 + 0.5 * cos(2 * .pi * t)))
            c.setFillColor(rgb("#FF3B30"))
            c.fillEllipse(in: CGRect(x: padX, y: y + ph / 2 - dot / 2, width: dot, height: dot))
            c.setAlpha(1)
            c.textPosition = CGPoint(x: padX + dot + 12 * k - lb.minX, y: y + (ph - lb.height) / 2 - lb.minY)
            CTLineDraw(label, c)
            c.textPosition = CGPoint(x: padX + dot + 12 * k + lb.width + 14 * k - tb.minX, y: y + (ph - tb.height) / 2 - tb.minY)
            CTLineDraw(timer, c)
            // Right: the chapter badge, the new one sliding down into place over 0.3 s.
            guard let chapters = s.chapters, !chapters.isEmpty else { return }
            guard let n = chapters.lastIndex(where: { $0.at <= t }) else { return }
            let into = t - chapters[n].at
            let f = min(max(into / 0.3, 0), 1), e = 1 - pow(1 - f, 3)
            let number = line(String(format: "%02d", n + 1), font: mono, size: 19 * k, color: rgb(accent), kern: 1.5 * k)
            let name = line(chapters[n].label.uppercased(), font: mono, size: 19 * k, color: CGColor(gray: 1, alpha: 0.9), kern: 2 * k)
            let nb = CTLineGetBoundsWithOptions(number, .useOpticalBounds), mb = CTLineGetBoundsWithOptions(name, .useOpticalBounds)
            let rightW = padX + nb.width + 12 * k + mb.width + padX
            let bx = bw - rightW
            c.saveGState()
            c.translateBy(x: 0, y: (1 - e) * 10 * k)
            pill(bx, rightW, alpha: e)
            c.textPosition = CGPoint(x: bx + padX - nb.minX, y: y + (ph - nb.height) / 2 - nb.minY)
            CTLineDraw(number, c)
            c.textPosition = CGPoint(x: bx + padX + nb.width + 12 * k - mb.minX, y: y + (ph - mb.height) / 2 - mb.minY)
            CTLineDraw(name, c)
            c.restoreGState()
        }
    }

    // MARK: Level meters

    /// Two segmented bars per side (RMS inside, peak outside) with a falling peak-hold tick, labelled L and R.
    static func audioMeters(_ s: ShapeLayer, time t: Double, w: Int, h: Int) -> CIImage? {
        let W = Double(w), H = Double(h), k = W / SafeZones.referenceWidth
        let r = s.rect
        let x0 = r[0] * W, top = r[1] * H, rw = r[2] * W, rh = r[3] * H
        let levels = s.levels ?? []
        let rate = s.levelRate ?? 30
        func sample(_ at: Double) -> [Double] {
            guard !levels.isEmpty else { return [0, 0, 0, 0] }
            let i = min(max(Int((at * rate).rounded(.down)), 0), levels.count - 1)
            return levels[i]
        }
        let now = sample(t)
        // Peak hold: the highest peak of the last 0.8 s, falling after it.
        func hold(_ ch: Int) -> Double {
            var best = 0.0
            for j in 0..<Int(0.8 * rate) {
                let at = t - Double(j) / rate
                guard at >= 0 else { break }
                best = max(best, (sample(at)[safe: ch + 2] ?? 0) - Double(j) / rate * 0.15)
            }
            return best
        }
        let segments = 30
        let barW = 18 * k, gap = 6 * k, labelH = 34 * k
        let accent = s.color
        return region(Int(rw), Int(rh + labelH), x: x0, top: top, H: H) { c in
            let mh = rh
            let segH = mh / Double(segments)
            func bar(_ x: Double, value: Double, peak: Double?) {
                let lit = Int((value * Double(segments)).rounded())
                for i in 0..<segments {
                    let y = labelH + Double(i) * segH
                    let f = Double(i) / Double(segments - 1)
                    let color: CGColor = f > 0.82 ? rgb(accent) : f > 0.62 ? rgb("#F2C14E") : rgb("#3DDC97")
                    c.setFillColor(i < lit ? color : CGColor(gray: 1, alpha: 0.07))
                    c.fill(CGRect(x: x, y: y + 1.2 * k, width: barW, height: segH - 2.4 * k))
                }
                if let p = peak, p > 0.02 {
                    let y = labelH + min(p, 1) * mh - segH
                    c.setFillColor(CGColor(gray: 1, alpha: 0.85))
                    c.fill(CGRect(x: x, y: y + 1.2 * k, width: barW, height: segH - 2.4 * k))
                }
            }
            // Frames.
            for side in [0.0, rw - (2 * barW + gap + 16 * k)] {
                let fr = CGRect(x: side, y: labelH - 8 * k, width: 2 * barW + gap + 16 * k, height: mh + 16 * k)
                c.addPath(CGPath(roundedRect: fr, cornerWidth: 8 * k, cornerHeight: 8 * k, transform: nil))
                c.setFillColor(CGColor(gray: 0.03, alpha: 0.6)); c.fillPath()
            }
            let lx = 8 * k, rx = rw - (2 * barW + gap + 8 * k)
            bar(lx, value: now[safe: 0] ?? 0, peak: nil)
            bar(lx + barW + gap, value: now[safe: 2] ?? 0, peak: hold(0))
            bar(rx, value: now[safe: 3] ?? 0, peak: hold(1))
            bar(rx + barW + gap, value: now[safe: 1] ?? 0, peak: nil)
            for (text, x) in [("L", lx + barW + gap / 2), ("R", rx + barW + gap / 2)] {
                let l = line(text, font: "Menlo-Bold", size: 18 * k, color: CGColor(gray: 1, alpha: 0.7))
                let b = CTLineGetBoundsWithOptions(l, .useOpticalBounds)
                c.textPosition = CGPoint(x: x - b.width / 2 - b.minX, y: 2 * k)
                CTLineDraw(l, c)
            }
        }
    }
}

extension Array {
    fileprivate subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
