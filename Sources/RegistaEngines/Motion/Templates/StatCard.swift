import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A small card that pops next to the speaker: a big number counting up, a caption and a mini line chart drawing on.
enum StatCard: MotionTemplate {
    static let spec = MotionSpec(
        id: "stat-card", label: "Scheda numero", symbol: "chart.line.uptrend.xyaxis",
        guide: CatalogGuide("A compact rounded card (dark or white) that pops in beside the speaker's head: a big bold number counting up (\"8,000+\"), a one-line caption under it and a mini line chart with two coloured lines drawing themselves on — a quick proof point that does not take over the frame.",
                            useWhen: "A single real metric said in passing (subscribers, views, members, revenue growth) while the speaker keeps talking; next to the head in the top band, 2–3 s.",
                            avoid: "Made-up numbers, several metrics at once (use chart or bento-grid), or when the number is the hook of the reel (use counter, bigger)."),
        fields: [
            .init("value", "text", "8000", "The number (counts up to it)."),
            .init("prefix", "text", "", "Before the number (\"€\", \"+\")."),
            .init("suffix", "text", "+", "After the number (\"+\", \"%\", \"k\")."),
            .init("caption", "text", "creators in the community", "One short line under the number."),
            .init("position", "point", [790, 540], "Card centre [x, y] on a 1080×1920 frame."),
            .init("theme", "choice", "dark", "Card style.", choices: ["dark", "light"]),
        ],
        form: ["value", "suffix", "caption", "theme"], duration: 2.8, band: nil)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        guard let (target, _, decimals) = Counter.parse(m.string("value", "8000")) else { return nil }
        let p = Anim.ease(Anim.p(c.t, 0.2, 1.1), .easeOut)
        let text = m.string("prefix") + Counter.format(decimals == 0 ? (target * p).rounded() : target * p, clock: false, decimals: decimals) + m.string("suffix")
        let dark = m.string("theme", "dark") == "dark"
        let w = c.px(330), h = c.px(220), pad = c.px(36)
        let q = Int((p * 24).rounded())
        let card = c.sprite("stat|\(text)|\(m.string("caption"))|\(dark)|\(q)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(22), fill: dark ? TitleRasterizer.color("#151519", alpha: 0.95) : TitleRasterizer.color("#FFFFFF"), shadow: 0.3, blur: c.px(26), dy: c.px(10),
                      stroke: dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.1) : nil)
            let ink = TitleRasterizer.color(dark ? "#FFFFFF" : "#111111")
            Draw.text(ctx, text, c.font("textBold", 64), ink, x: r.minX + c.px(24), baseline: r.minY + c.px(78))
            Draw.text(ctx, m.string("caption"), c.font("text", 19), TitleRasterizer.color(dark ? "#FFFFFF" : "#111111", alpha: 0.55), x: r.minX + c.px(24), baseline: r.minY + c.px(110))
            let plot = CGRect(x: r.minX + c.px(24), y: r.minY + c.px(130), width: w - c.px(48), height: c.px(64))
            for (k, col) in [c.m.style.color("accent"), c.m.style.color("primary") == c.m.style.color("ink") ? "#5B7CFA" : c.m.style.color("primary")].enumerated() {
                let pts = (0...20).map { i -> CGPoint in
                    let x = Double(i) / 20
                    let y = k == 0 ? 0.15 + 0.75 * pow(x, 1.6) + 0.05 * sin(x * 13) : 0.2 + 0.4 * x + 0.06 * sin(x * 9 + 1)
                    return CGPoint(x: plot.minX + plot.width * x, y: plot.maxY - plot.height * y)
                }
                let shown = max(Int(Double(pts.count - 1) * Double(q) / 24), 1)
                ctx.setStrokeColor(TitleRasterizer.color(col)); ctx.setLineWidth(c.px(k == 0 ? 4 : 3)); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                ctx.addLines(between: Array(pts.prefix(shown + 1))); ctx.strokePath()
            }
        }
        let pos = m.fields["position"]?.arrayValue?.compactMap(\.doubleValue) ?? [790, 540]
        let at = (c.px(pos.first ?? 790), (pos.count > 1 ? pos[1] : 540) / SafeZones.referenceHeight * c.H)
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        return c.place(card, at: at, scale: 0.75 + 0.25 * pop, rotation: -2 * (1 - pop), opacity: min(pop * 1.5, 1) * (1 - leave))
    }
}
