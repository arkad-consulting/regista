import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Generated editor panels in a dark glass window (traffic lights + title): timeline, colour wheels, keyframe curve,
/// audio waveform, FX grid, sliders, a big-number panel. Used by card-stack, scatter-wall and mock-ui. Deterministic
/// (seeded by the kind), drawn once per size and cached; `phase` 0…1 animates the moving parts (playhead, sliders,
/// curve draw-on), quantised so caching still works.
public enum MockPanels {
    public static let kinds = ["timeline", "wheels", "curve", "waveform", "fx", "sliders", "number"]

    public static func title(_ kind: String) -> String {
        switch kind {
        case "timeline": "Timeline"
        case "wheels": "Colour"
        case "curve": "Keyframes"
        case "waveform": "Audio"
        case "fx": "Effects"
        case "sliders": "Adjust"
        case "number": "Stats"
        default: kind.capitalized
        }
    }

    /// A panel sprite of `w`×`h` output pixels (plus a 40 px margin for its shadow on each side).
    static func panel(_ c: MotionCanvas, kind: String, w: Double, h: Double, phase: Double = 1, label: String? = nil) -> CIImage {
        let q = Int((min(max(phase, 0), 1) * 24).rounded())
        let pad = c.px(40)
        return c.sprite("panel|\(kind)|\(label ?? "")|\(q)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(18), fill: TitleRasterizer.color("#1C1D21", alpha: 0.96), shadow: 0.4, blur: c.px(34), dy: c.px(14),
                      stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.09))
            // Title bar.
            for (i, col) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
                ctx.setFillColor(TitleRasterizer.color(col))
                let d = c.px(13)
                ctx.fillEllipse(in: CGRect(x: r.minX + c.px(18) + Double(i) * c.px(21), y: r.minY + c.px(16), width: d, height: d))
            }
            Draw.text(ctx, label ?? title(kind), c.font("text", 17), TitleRasterizer.color("#FFFFFF", alpha: 0.55), x: r.minX + c.px(90), centreY: r.minY + c.px(23))
            let body = CGRect(x: r.minX + c.px(18), y: r.minY + c.px(46), width: w - c.px(36), height: h - c.px(62))
            content(ctx, c, kind: kind, in: body, phase: Double(q) / 24)
        }
    }

    static func content(_ ctx: CGContext, _ c: MotionCanvas, kind: String, in b: CGRect, phase: Double) {
        var rng = SeededRandom(seed: UInt64(bitPattern: Int64(kind.hashValueStable)))
        let palette = ["#3B82F6", "#22A06B", "#E2A93B", "#8B5CF6", "#E5484D", "#14B8A6"]
        switch kind {
        case "timeline":
            let lanes = 5, lh = b.height / Double(lanes)
            for l in 0..<lanes {
                var x = b.minX
                while x < b.maxX - c.px(10) {
                    let cw = min(c.px(40) + rng.next() * c.px(110), b.maxX - x)
                    Draw.roundedRect(ctx, CGRect(x: x, y: b.minY + Double(l) * lh + c.px(3), width: cw - c.px(5), height: lh - c.px(7)), radius: c.px(4),
                                     fill: TitleRasterizer.color(palette[l % palette.count], alpha: 0.9))
                    x += cw
                }
            }
            let px = b.minX + b.width * (0.15 + 0.7 * phase)
            ctx.setFillColor(TitleRasterizer.color("#FFFFFF")); ctx.fill(CGRect(x: px - c.px(1.5), y: b.minY - c.px(6), width: c.px(3), height: b.height + c.px(6)))
            Draw.roundedRect(ctx, CGRect(x: px - c.px(30), y: b.minY - c.px(30), width: c.px(60), height: c.px(22)), radius: c.px(6), fill: TitleRasterizer.color("#FFFFFF"))
            Draw.text(ctx, String(format: "00:%02d", Int(4 + 20 * phase)), c.font("mono", 13), TitleRasterizer.color("#111111"), x: px, centreY: b.minY - c.px(19), align: 0.5)
        case "wheels":
            let n = 3, d = min(b.width / Double(n) - c.px(16), b.height - c.px(24))
            for i in 0..<n {
                let cx = b.minX + b.width * (Double(i) + 0.5) / Double(n), cy = b.minY + d / 2 + c.px(2)
                ctx.setFillColor(TitleRasterizer.color("#2A2B30")); ctx.fillEllipse(in: CGRect(x: cx - d / 2 - c.px(6), y: cy - d / 2 - c.px(6), width: d + c.px(12), height: d + c.px(12)))
                let steps = 36
                for s in 0..<steps {
                    let a0 = Double(s) / Double(steps) * 2 * .pi, a1 = Double(s + 1) / Double(steps) * 2 * .pi
                    let hue = Double(s) / Double(steps)
                    let rgb = hsv(hue, 0.75, 0.95)
                    ctx.setFillColor(CGColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1))
                    ctx.move(to: CGPoint(x: cx, y: cy))
                    ctx.addArc(center: CGPoint(x: cx, y: cy), radius: d / 2, startAngle: a0, endAngle: a1 + 0.02, clockwise: false)
                    ctx.fillPath()
                }
                let g = CGGradient(colorsSpace: TitleRasterizer.space, colors: [TitleRasterizer.color("#FFFFFF", alpha: 0.95), TitleRasterizer.color("#FFFFFF", alpha: 0)] as CFArray, locations: [0, 1])!
                ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: d / 2, options: [])
                let a = rng.next() * 2 * .pi + phase * 0.8, rr = d * 0.18
                ctx.setStrokeColor(TitleRasterizer.color("#FFFFFF")); ctx.setLineWidth(c.px(2.5))
                ctx.strokeEllipse(in: CGRect(x: cx + rr * cos(a) - c.px(7), y: cy + rr * sin(a) - c.px(7), width: c.px(14), height: c.px(14)))
                Draw.text(ctx, ["Shadows", "Midtones", "Highlights"][i], c.font("text", 13), TitleRasterizer.color("#FFFFFF", alpha: 0.5), x: cx, baseline: b.maxY - c.px(2), align: 0.5)
            }
        case "curve":
            ctx.setStrokeColor(TitleRasterizer.color("#FFFFFF", alpha: 0.06)); ctx.setLineWidth(1)
            for i in 1..<4 { let y = b.minY + b.height * Double(i) / 4; ctx.move(to: CGPoint(x: b.minX, y: y)); ctx.addLine(to: CGPoint(x: b.maxX, y: y)) }
            ctx.strokePath()
            let pts = (0...60).map { i -> CGPoint in
                let x = Double(i) / 60
                return CGPoint(x: b.minX + b.width * x, y: b.minY + b.height * (0.85 - 0.6 * (0.5 + 0.45 * sin(x * 5.2 - 1.2) * (1 - 0.3 * x))))
            }
            let shown = Int(Double(pts.count - 1) * max(phase, 0.02))
            ctx.setStrokeColor(TitleRasterizer.color("#E2A93B")); ctx.setLineWidth(c.px(3)); ctx.setLineCap(.round)
            ctx.addLines(between: Array(pts.prefix(shown + 1))); ctx.strokePath()
            for k in [0, 20, 40, 60] where k <= shown {
                let p = pts[k]
                ctx.setFillColor(TitleRasterizer.color("#FFFFFF"))
                ctx.fill(CGRect(x: p.x - c.px(6), y: p.y - c.px(6), width: c.px(12), height: c.px(12)))
            }
        case "waveform":
            let n = Int(b.width / c.px(6))
            for i in 0..<n {
                let x = b.minX + Double(i) * c.px(6)
                let env = 0.25 + 0.75 * abs(sin(Double(i) * 0.09)) * (0.6 + 0.4 * rng.next())
                let hh = b.height * 0.9 * env
                ctx.setFillColor(TitleRasterizer.color(Double(i) / Double(n) < phase ? "#2BD48A" : "#2BD48A", alpha: Double(i) / Double(n) < phase ? 1 : 0.35))
                ctx.fill(CGRect(x: x, y: b.midY - hh / 2, width: c.px(3.5), height: hh))
            }
        case "fx":
            let cols = 4, rows = 3
            let cw = b.width / Double(cols), rh = b.height / Double(rows)
            for r in 0..<rows { for k in 0..<cols {
                let cell = CGRect(x: b.minX + Double(k) * cw + c.px(4), y: b.minY + Double(r) * rh + c.px(4), width: cw - c.px(8), height: rh - c.px(8))
                let lit = Int(phase * Double(rows * cols)) == r * cols + k
                Draw.roundedRect(ctx, cell, radius: c.px(6), fill: TitleRasterizer.color(lit ? "#3A3B42" : "#2A2B30"))
                Draw.text(ctx, "FX \(r * cols + k + 1)", c.font("text", 14), TitleRasterizer.color("#FFFFFF", alpha: 0.55), x: cell.midX, centreY: cell.midY, align: 0.5)
            } }
        case "sliders":
            let names = ["Exposure", "Contrast", "Warmth", "Saturation"]
            let rh = b.height / Double(names.count)
            for (i, n) in names.enumerated() {
                let y = b.minY + rh * (Double(i) + 0.5)
                Draw.text(ctx, n, c.font("text", 15), TitleRasterizer.color("#FFFFFF", alpha: 0.6), x: b.minX, centreY: y)
                let tx = b.minX + b.width * 0.36, tw = b.width * 0.6
                Draw.roundedRect(ctx, CGRect(x: tx, y: y - c.px(3), width: tw, height: c.px(6)), radius: c.px(3), fill: TitleRasterizer.color("#FFFFFF", alpha: 0.12))
                let v = 0.3 + 0.5 * rng.next()
                let kx = tx + tw * (0.5 + (v - 0.5) * phase)
                Draw.roundedRect(ctx, CGRect(x: tx, y: y - c.px(3), width: kx - tx, height: c.px(6)), radius: c.px(3), fill: TitleRasterizer.color(palette[i]))
                ctx.setFillColor(TitleRasterizer.color("#FFFFFF")); ctx.fillEllipse(in: CGRect(x: kx - c.px(9), y: y - c.px(9), width: c.px(18), height: c.px(18)))
            }
        default:   // number
            let v = Int(8000 * phase)
            Draw.text(ctx, "\(v.formatted(.number.locale(Locale(identifier: "en_US"))))+", c.font("textBold", 64), TitleRasterizer.color("#FFFFFF"), x: b.minX, centreY: b.minY + b.height * 0.4)
            Draw.text(ctx, "views this week", c.font("text", 17), TitleRasterizer.color("#FFFFFF", alpha: 0.5), x: b.minX, centreY: b.minY + b.height * 0.78)
        }
    }

    static func hsv(_ h: Double, _ s: Double, _ v: Double) -> (Double, Double, Double) {
        let i = Int(h * 6) % 6, f = h * 6 - Double(Int(h * 6)), p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }
}
