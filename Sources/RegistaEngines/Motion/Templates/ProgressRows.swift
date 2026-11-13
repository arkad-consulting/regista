import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Rows with an icon, a label, a bar that fills and a status light that turns into a check (CUT / MOTION / SOUND):
/// the checklist's sibling for processes that run.
enum ProgressRows: MotionTemplate {
    static let spec = MotionSpec(
        id: "progress-rows", label: "Avanzamento", symbol: "list.bullet.rectangle",
        guide: CatalogGuide("A dark console panel with a thin glowing accent border; 2–5 rows, each with an SF Symbol icon, a mono capitalised label, a bar that fills in the accent colour and a status light that turns into a check when its bar is full — the rows run one after the other, like a machine working through steps.",
                            useWhen: "Showing a process running or finishing (\"cut, motion, sound — done\"), what an automation is doing, the stages of a render, while the speaker explains it.",
                            avoid: "Static lists of items (use checklist), more than 5 rows, steps that are not really happening in order, calm light brands (it is a dark tech look)."),
        fields: [
            .init("title", "text", "", "Optional mono title above the rows."),
            .init("rows", "list", ["Cut", "Motion", "Sound"], "Row labels (2–5)."),
            .init("symbols", "list", ["scissors", "sparkles", "speaker.wave.2.fill"], "One SF Symbol per row."),
            .init("width", "number", 760, "Panel width, px."),
        ],
        form: ["title", "rows", "symbols"], duration: 3.5, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let rows = Array(m.strings("rows").prefix(5)), symbols = m.strings("symbols")
        guard !rows.isEmpty else { return nil }
        let title = m.string("title")
        let w = c.px(m.number("width", 760)), rh = c.px(92), pad = c.px(44), top = title.isEmpty ? c.px(20) : c.px(70)
        let h = top + rh * Double(rows.count) + c.px(14)
        let per = max(c.d - 1.0, 0.8) / Double(rows.count)
        let fills = rows.indices.map { Anim.ease(Anim.p(c.t, 0.4 + per * Double($0), per * 0.85), .easeInOut) }
        let q = fills.map { Int(($0 * 30).rounded()) }
        let accent = c.cg("accent")
        let panel = c.sprite("prows|\(rows)|\(symbols)|\(title)|\(q)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.console(ctx, r, radius: c.px(22), accent: accent, glow: c.px(22))
            if !title.isEmpty { Draw.text(ctx, title.uppercased(), c.font("mono", 22), c.cg("#FFFFFF", 0.6), x: r.minX + c.px(28), centreY: r.minY + c.px(38), tracking: c.px(4)) }
            for (i, row) in rows.enumerated() {
                let y = r.minY + top + rh * (Double(i) + 0.5)
                let box = CGRect(x: r.minX + c.px(18), y: y - rh / 2 + c.px(8), width: w - c.px(36), height: rh - c.px(16))
                Draw.roundedRect(ctx, box, radius: c.px(14), fill: TitleRasterizer.color("#FFFFFF", alpha: 0.04), stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.08), lineWidth: 1)
                let p = Double(q[i]) / 30
                if i < symbols.count {
                    Draw.symbol(ctx, symbols[i], in: CGRect(x: box.minX + c.px(18), y: y - c.px(16), width: c.px(32), height: c.px(32)), color: p > 0 ? accent : c.cg("#FFFFFF", 0.4))
                }
                Draw.text(ctx, row.uppercased(), c.font("mono", 30), c.cg("#FFFFFF", p > 0 ? 0.95 : 0.5), x: box.minX + c.px(70), centreY: y, tracking: c.px(3))
                let bar = CGRect(x: box.minX + box.width * 0.5, y: y - c.px(4), width: box.width * 0.36, height: c.px(8))
                Draw.roundedRect(ctx, bar, radius: c.px(4), fill: TitleRasterizer.color("#FFFFFF", alpha: 0.1))
                if p > 0 { Draw.roundedRect(ctx, CGRect(x: bar.minX, y: bar.minY, width: bar.width * p, height: bar.height), radius: c.px(4), fill: accent) }
                let light = CGRect(x: box.maxX - c.px(46), y: y - c.px(14), width: c.px(28), height: c.px(28))
                if p >= 1 {
                    ctx.setFillColor(TitleRasterizer.color("#2BD48A")); ctx.fillEllipse(in: light)
                    Draw.check(ctx, in: light, color: TitleRasterizer.color("#0E1A12"), width: c.px(3.5))
                } else {
                    ctx.setFillColor(p > 0 ? accent : TitleRasterizer.color("#FFFFFF", alpha: 0.18)); ctx.fillEllipse(in: light.insetBy(dx: c.px(7), dy: c.px(7)))
                }
            }
        }
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        return c.place(panel, at: (cx, cy + c.px(24) * (1 - pop)), scale: 0.95 + 0.05 * pop, opacity: min(pop * 1.5, 1) * (1 - leave))
    }
}
