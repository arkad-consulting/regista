import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A paper receipt printing out of a slot: rows of the edit's real numbers with dotted leaders and checks, a TOTAL.
enum Receipt: MotionTemplate {
    static let spec = MotionSpec(
        id: "receipt", label: "Scontrino", symbol: "doc.text",
        guide: CatalogGuide("A cream paper receipt with a torn zig-zag edge slides down out of a dark slot, line by line: a mono title (\"THIS EDIT\"), rows like \"29 cuts ········ ✓\", \"44 s removed ······ ✓\" with dotted leaders and green checks, then a TOTAL line in big accent type. By default the rows are the real numbers of this edit — cuts, seconds removed, caption words, sound effects, graphics — and the total is raw → final duration.",
                            useWhen: "Showing the cost or the result of an edit in a playful, concrete way (\"what this edit took\"), at the end of a behind-the-scenes or a before/after; after the cut is final.",
                            avoid: "Before the edit is finished (the numbers would be wrong — add it again after re-cutting), invented prices, long receipts (> 6 rows)."),
        fields: [
            .init("title", "text", "THIS EDIT", "Title at the top of the receipt."),
            .init("rows", "list", ["Cuts: 29", "Seconds removed: 44", "Captions: 120 words"], "Rows \"label: value\" (default: the real numbers of the edit)."),
            .init("total", "text", "1:42 → 0:57", "TOTAL line (default: raw → final duration)."),
            .init("totalLabel", "text", "TOTAL", "Label of the total line."),
        ],
        form: ["title", "totalLabel"], duration: 3.5, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let rows = Array(m.strings("rows").prefix(6))
        let w = c.px(560), rowH = c.px(66)
        let h = c.px(110) + rowH * Double(rows.count) + c.px(150)
        let paper = c.sprite("rcpt|\(m.string("title"))|\(rows)|\(m.string("total"))|\(m.string("totalLabel"))", w, h) { ctx in
            // Paper with a torn bottom edge.
            let path = CGMutablePath()
            path.move(to: .zero); path.addLine(to: CGPoint(x: w, y: 0)); path.addLine(to: CGPoint(x: w, y: h - c.px(16)))
            let teeth = 18
            for i in 0...teeth { path.addLine(to: CGPoint(x: w - w * Double(i) / Double(teeth), y: h - (i % 2 == 0 ? c.px(16) : 0))) }
            path.closeSubpath()
            ctx.addPath(path); ctx.setFillColor(TitleRasterizer.color("#F6F0E2")); ctx.fillPath()
            let ink = TitleRasterizer.color("#1A1714")
            Draw.text(ctx, m.string("title").uppercased(), c.font("mono", 30), ink, x: w / 2, centreY: c.px(52), align: 0.5, tracking: c.px(3))
            ctx.setStrokeColor(TitleRasterizer.color("#1A1714", alpha: 0.4)); ctx.setLineWidth(c.px(1.5)); ctx.setLineDash(phase: 0, lengths: [c.px(6), c.px(5)])
            ctx.move(to: CGPoint(x: c.px(30), y: c.px(90))); ctx.addLine(to: CGPoint(x: w - c.px(30), y: c.px(90))); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            for (i, row) in rows.enumerated() {
                let y = c.px(110) + rowH * (Double(i) + 0.5)
                let parts = row.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                let (label, value) = parts.count == 2 ? (parts[0], parts[1]) : (row, "")
                var x = c.px(30)
                if !value.isEmpty { x += Draw.text(ctx, value, c.font("textBold", 40), ink, x: x, centreY: y) + c.px(12) }
                x += Draw.text(ctx, label.lowercased(), c.font("mono", 26), ink, x: x, centreY: y) + c.px(12)
                ctx.setFillColor(TitleRasterizer.color("#1A1714", alpha: 0.35))
                var dx = x
                while dx < w - c.px(80) { ctx.fill(CGRect(x: dx, y: y + c.px(6), width: c.px(3), height: c.px(3))); dx += c.px(9) }
                Draw.check(ctx, in: CGRect(x: w - c.px(66), y: y - c.px(18), width: c.px(36), height: c.px(36)), color: TitleRasterizer.color("#2E9E62"), width: c.px(4))
            }
            let ty = c.px(110) + rowH * Double(rows.count) + c.px(30)
            ctx.setStrokeColor(TitleRasterizer.color("#1A1714", alpha: 0.4)); ctx.setLineDash(phase: 0, lengths: [c.px(6), c.px(5)])
            ctx.move(to: CGPoint(x: c.px(30), y: ty - c.px(10))); ctx.addLine(to: CGPoint(x: w - c.px(30), y: ty - c.px(10))); ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            Draw.text(ctx, m.string("totalLabel").uppercased(), c.font("mono", 24), ink, x: c.px(30), centreY: ty + c.px(52), tracking: c.px(2))
            let total = m.string("total")
            let tf = c.font("textBold", min(60, 60 * (w * 0.62) / max(Draw.width(total, c.font("textBold", 60)), 1)))
            Draw.text(ctx, total, tf, c.cg("accent"), x: w - c.px(30), centreY: ty + c.px(52), align: 1)
        }
        let (cx, cy) = c.centre
        let slotY = cy - h / 2 - c.px(30)
        let print = Anim.ease(Anim.p(c.t, 0.25, min(1.4, c.d * 0.5)), .easeOut)
        let leave = Anim.exit(c.t, c.d, 0.3)
        let shown = h * print
        // The paper slides out of the slot: only what has come out is visible.
        let placed = c.place(paper, at: (cx, slotY + shown - h / 2), opacity: 1 - leave)
        let visible = placed.cropped(to: CGRect(x: 0, y: 0, width: c.W, height: c.H - slotY))
        let slot = c.sprite("slot|\(Int(w))", w + c.px(80), c.px(44)) { ctx in
            Draw.console(ctx, CGRect(x: c.px(10), y: c.px(10), width: w + c.px(60), height: c.px(24)), radius: c.px(12), accent: c.cg("accent"), glow: c.px(14))
        }
        let slotIn = Anim.ease(Anim.p(c.t, 0, 0.3), .easeOut)
        return MotionCanvas.stack([c.shadow(visible, opacity: 0.25, radius: 20, drop: 10), c.place(slot, at: (cx, slotY), opacity: slotIn * (1 - leave))])
    }
}
