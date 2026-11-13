import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Bar, line, donut and big-number charts on a card that animate in: bars grow one after the other, the line draws
/// itself with its dots, the donut sweeps, the number counts up. Data passed as fields.
enum Chart: MotionTemplate {
    static let spec = MotionSpec(
        id: "chart", label: "Grafico", symbol: "chart.bar.xaxis",
        guide: CatalogGuide("A clean rounded card in the top band with a small spaced title and an animated chart in the brand colours: bars that grow one after the other with their values, a line that draws itself with dots on each point, a donut whose segments sweep round with a legend, or one big number counting up with a caption. The last bar/point is in the accent colour.",
                            useWhen: "The speaker gives real figures that compare or evolve: growth over months (line), before vs after or options side by side (bar), a split or share (donut), one headline figure (number). 3–7 data points.",
                            avoid: "Made-up or approximate data, more than 7 values, labels longer than ~8 characters, or when the number alone is the message (use counter)."),
        fields: [
            .init("kind", "choice", "bar", "Chart type.", choices: ["bar", "line", "donut", "number"]),
            .init("title", "text", "VIEWS PER MONTH", "Small spaced title."),
            .init("values", "numbers", [12, 19, 31, 48, 74], "The data (3–7 values; number: the first one)."),
            .init("labels", "list", ["JUN", "JUL", "AUG", "SEP", "OCT"], "One short label per value."),
            .init("suffix", "text", "k", "Unit after each value (\"%\", \"k\", \"€\")."),
            .init("theme", "choice", "light", "Card theme.", choices: ["light", "dark"]),
            .init("color", "color", "accent", "Highlight colour (the last bar/point, the first donut segment)."),
        ],
        form: ["kind", "title", "values", "labels"], duration: 4, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let kind = m.string("kind", "bar")
        let values = Array(m.numbers("values").prefix(7))
        guard !values.isEmpty else { return nil }
        let labels = m.strings("labels"), title = m.string("title"), suffix = m.string("suffix")
        let dark = m.string("theme", "light") == "dark"
        let accent = m.color("color", "accent")
        let ink = dark ? "#F5F3EE" : "#141414", muted = dark ? "#FFFFFF" : "#141414"
        let w = c.px(780), h = c.px(kind == "number" ? 300 : 440), pad = c.px(40), margin = c.px(50)
        let grow = Anim.p(c.t, 0.35, kind == "donut" ? 1.2 : 1.0)
        let q = Int((grow * 30).rounded())
        let sprite = c.sprite("chart|\(kind)|\(values)|\(labels)|\(title)|\(suffix)|\(dark)|\(accent)|\(q)", w + 2 * margin, h + 2 * margin) { ctx in
            let r = CGRect(x: margin, y: margin, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(30), fill: dark ? TitleRasterizer.color("#16171A", alpha: 0.94) : TitleRasterizer.color("#FFFFFF", alpha: 0.96),
                      shadow: 0.2, blur: c.px(40), dy: c.px(14))
            if !title.isEmpty {
                Draw.text(ctx, title.uppercased(), c.font("textBold", 24), TitleRasterizer.color(accent), x: r.minX + pad, centreY: r.minY + c.px(46), tracking: c.px(4))
            }
            let plot = CGRect(x: r.minX + pad, y: r.minY + c.px(92), width: w - 2 * pad, height: h - c.px(92) - c.px(64))
            let p = Double(q) / 30
            let maxV = max(values.max() ?? 1, 1e-9)
            func label(_ i: Int) -> String { i < labels.count ? labels[i] : "" }
            func fmt(_ v: Double) -> String { (v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)) + suffix }
            switch kind {
            case "line":
                ctx.setFillColor(TitleRasterizer.color(muted, alpha: 0.08))
                for g in 0...3 { ctx.fill(CGRect(x: plot.minX, y: plot.minY + plot.height * Double(g) / 3, width: plot.width, height: max(c.px(1.5), 1))) }
                let pts = values.enumerated().map { i, v in
                    CGPoint(x: plot.minX + plot.width * (values.count == 1 ? 0.5 : Double(i) / Double(values.count - 1)), y: plot.maxY - plot.height * v / maxV)
                }
                let reach = p * Double(pts.count - 1)
                var path = [pts[0]]
                for i in 1..<max(pts.count, 1) where Double(i - 1) < reach {
                    let f = min(reach - Double(i - 1), 1)
                    path.append(CGPoint(x: pts[i - 1].x + (pts[i].x - pts[i - 1].x) * f, y: pts[i - 1].y + (pts[i].y - pts[i - 1].y) * f))
                }
                ctx.setStrokeColor(TitleRasterizer.color(accent)); ctx.setLineWidth(c.px(6)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.addLines(between: path); ctx.strokePath()
                for (i, pt) in pts.enumerated() where Double(i) <= reach + 0.001 {
                    ctx.setFillColor(TitleRasterizer.color(dark ? "#16171A" : "#FFFFFF")); ctx.fillEllipse(in: CGRect(x: pt.x - c.px(10), y: pt.y - c.px(10), width: c.px(20), height: c.px(20)))
                    ctx.setStrokeColor(TitleRasterizer.color(accent)); ctx.setLineWidth(c.px(5)); ctx.strokeEllipse(in: CGRect(x: pt.x - c.px(9), y: pt.y - c.px(9), width: c.px(18), height: c.px(18)))
                    if i == pts.count - 1 { Draw.text(ctx, fmt(values[i]), c.font("textBold", 30), TitleRasterizer.color(ink), x: pt.x, baseline: pt.y - c.px(22), align: 1) }
                    Draw.text(ctx, label(i), c.font("mono", 18), TitleRasterizer.color(muted, alpha: 0.55), x: pt.x, baseline: r.maxY - c.px(30), align: i == 0 ? 0 : i == pts.count - 1 ? 1 : 0.5)
                }
            case "donut":
                let d = min(plot.height + c.px(30), plot.width * 0.45)
                let centre = CGPoint(x: plot.minX + d / 2, y: plot.midY + c.px(14))
                let total = values.reduce(0, +)
                let colors = [accent, c.m.style.color("primary"), c.m.style.color("ink"), c.m.style.color("success"), c.m.style.color("highlight"), "#9A9A9A", "#C8C8C8"]
                var a = -Double.pi / 2
                for (i, v) in values.enumerated() {
                    let span = 2 * .pi * v / max(total, 1e-9) * p
                    ctx.setStrokeColor(TitleRasterizer.color(colors[i % colors.count])); ctx.setLineWidth(c.px(44)); ctx.setLineCap(.butt)
                    ctx.addArc(center: centre, radius: d / 2 - c.px(22), startAngle: a, endAngle: a + max(span - 0.02, 0), clockwise: false); ctx.strokePath()
                    a += 2 * .pi * v / max(total, 1e-9) * p
                    let ly = plot.minY + c.px(20) + Double(i) * c.px(48)
                    ctx.setFillColor(TitleRasterizer.color(colors[i % colors.count])); ctx.fillEllipse(in: CGRect(x: plot.minX + d + c.px(40), y: ly - c.px(9), width: c.px(18), height: c.px(18)))
                    Draw.text(ctx, label(i), c.font("text", 24), TitleRasterizer.color(ink), x: plot.minX + d + c.px(70), centreY: ly)
                    Draw.text(ctx, fmt((v / max(total, 1e-9) * 100).rounded()).replacingOccurrences(of: suffix, with: "") + "%", c.font("textBold", 24),
                              TitleRasterizer.color(ink), x: plot.maxX, centreY: ly, align: 1)
                }
            case "number":
                let v = values[0] * Anim.ease(p, .easeOut)
                let s = (values[0].rounded() == values[0] ? Int(v.rounded()).formatted(.number.locale(Locale(identifier: "en_US"))) : String(format: "%.1f", v)) + suffix
                Draw.text(ctx, s, c.font("textBold", 120), TitleRasterizer.color(ink), x: plot.minX, baseline: plot.minY + c.px(110))
                Draw.text(ctx, label(0), c.font("text", 26), TitleRasterizer.color(muted, alpha: 0.6), x: plot.minX, baseline: r.maxY - c.px(36))
            default:   // bar
                let n = Double(values.count), gap = c.px(22)
                let bw = (plot.width - gap * (n - 1)) / n
                for (i, v) in values.enumerated() {
                    let local = min(max(p * (n + 2) / n * 1.0 - Double(i) * 0.12, 0), 1)
                    let e = Easing.expoOut.apply(local)
                    let bh = (plot.height - c.px(40)) * v / maxV * e
                    let x = plot.minX + Double(i) * (bw + gap)
                    let last = i == values.count - 1
                    Draw.roundedRect(ctx, CGRect(x: x, y: plot.maxY - bh, width: bw, height: bh), radius: min(c.px(10), bw / 2),
                                     fill: last ? TitleRasterizer.color(accent) : TitleRasterizer.color(muted, alpha: dark ? 0.22 : 0.14))
                    if e > 0.6 { Draw.text(ctx, fmt(v), c.font("textBold", 24), TitleRasterizer.color(ink, alpha: (e - 0.6) / 0.4), x: x + bw / 2, baseline: plot.maxY - bh - c.px(12), align: 0.5) }
                    Draw.text(ctx, label(i), c.font("mono", 18), TitleRasterizer.color(muted, alpha: 0.55), x: x + bw / 2, baseline: r.maxY - c.px(30), align: 0.5)
                }
            }
        }
        let enter = Anim.ease(Anim.p(c.t, 0, 0.45), .expoOut), leave = Anim.exit(c.t, c.d, 0.3)
        let (cx, cy) = c.centre
        return c.place(sprite, at: (cx, cy - c.px(24) * (1 - enter)), scale: 0.97 + 0.03 * enter, opacity: enter * (1 - leave))
    }
}
