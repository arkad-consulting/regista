import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// An iOS-style rounded card: a spaced kicker title and 2–6 rows whose check boxes tick one by one (on the words when
/// synced to the transcript). Light or dark theme; each row can carry a right accessory (text, colour dots, a badge).
enum Checklist: MotionTemplate {
    static let spec = MotionSpec(
        id: "checklist", label: "Checklist", symbol: "checklist",
        guide: CatalogGuide("A clean rounded card (light or dark glass) in the top band: a small spaced title in the accent colour, then 2–6 rows, each with a rounded check box that fills with the accent colour and draws a tick, one row after the other — on the spoken words when synced. Rows can end with a small accessory (colour dots, \"Aa\", a badge).",
                            useWhen: "The speaker lists what is included, steps done, criteria met, or what a product covers (\"your style, your fonts, your captions, your colours\"): 2–6 short items said in a row. Sync it to the words (sync: true) so each tick lands as the item is spoken.",
                            avoid: "Long sentences per row (> 4 words), more than 6 items, items not said aloud, negative lists (use cross marks in a card instead), or over a busy top band where a light card disappears (use theme dark)."),
        fields: [
            .init("title", "text", "IN THIS VIDEO", "Small spaced title above the rows (empty = none)."),
            .init("rows", "list", ["Your style", "Your fonts", "Your captions", "Your colours"], "The rows, 2–6, ≤ 4 words each."),
            .init("accessories", "list", [], "Optional right accessory per row: text (\"Aa\"), colour dots (\"#141414 #C9A045 paper\"), or a badge (\"badge:NEW\"); \"\" = none."),
            .init("theme", "choice", "light", "Card theme.", choices: ["light", "dark"]),
            .init("color", "color", "accent", "Check box and title colour (#RRGGBB or a brand role)."),
            .init("interval", "number", 0.45, "Seconds between ticks when not synced."),
            .init("firstTick", "number", 0.6, "Seconds before the first tick when not synced."),
            .init("times", "numbers", [], "Tick times, seconds from the clip start (filled by sync: true)."),
            .init("width", "number", 780, "Card width, px at 1080 wide."),
        ],
        form: ["title", "rows", "theme", "color"], duration: 4, band: "top", syncField: "rows")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let rows = Array(m.strings("rows").prefix(6))
        guard !rows.isEmpty else { return nil }
        let title = m.string("title")
        let dark = m.string("theme", "light") == "dark"
        let accent = m.color("color", "accent")
        let acc = m.strings("accessories")
        let w = c.px(m.number("width", 780)), rowH = c.px(78), titleH = title.isEmpty ? c.px(22) : c.px(74), pad = c.px(30)
        let h = titleH + rowH * Double(rows.count) + c.px(18)
        let margin = c.px(50)
        let card = c.sprite("card|\(rows)|\(title)|\(dark)|\(accent)|\(acc)", w + 2 * margin, h + 2 * margin) { ctx in
            let r = CGRect(x: margin, y: margin, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(30), fill: dark ? TitleRasterizer.color("#16171A", alpha: 0.92) : TitleRasterizer.color("#FFFFFF", alpha: 0.96),
                      shadow: dark ? 0.35 : 0.18, blur: c.px(40), dy: c.px(14), stroke: dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.08) : nil)
            if !title.isEmpty {
                Draw.text(ctx, title.uppercased(), c.font("textBold", 25), TitleRasterizer.color(accent), x: r.minX + pad, centreY: r.minY + c.px(42), tracking: c.px(4))
            }
            let text = dark ? TitleRasterizer.color("#F5F3EE") : TitleRasterizer.color("#141414")
            for (i, row) in rows.enumerated() {
                let y = r.minY + titleH + rowH * Double(i)
                if i > 0 {
                    ctx.setFillColor(dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.08) : TitleRasterizer.color("#000000", alpha: 0.07))
                    ctx.fill(CGRect(x: r.minX + pad + c.px(62), y: y, width: w - 2 * pad - c.px(62), height: max(c.px(1.5), 1)))
                }
                // Empty box (the tick sprite covers it when ticked).
                let box = CGRect(x: r.minX + pad, y: y + rowH / 2 - c.px(19), width: c.px(38), height: c.px(38))
                Draw.roundedRect(ctx, box.insetBy(dx: c.px(1.5), dy: c.px(1.5)), radius: c.px(9), fill: nil,
                                 stroke: dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.3) : TitleRasterizer.color("#000000", alpha: 0.22), lineWidth: c.px(2.5))
                Draw.text(ctx, row, c.font("textBold", 33), text, x: box.maxX + c.px(24), centreY: y + rowH / 2)
                if i < acc.count { accessory(ctx, c, acc[i], right: r.maxX - pad, cy: y + rowH / 2, dark: dark) }
            }
        }
        let (cx, cy) = c.centre
        // Card: drops in 24 px with an expo ease and fades; leaves with a short fade up.
        let enter = Anim.ease(Anim.p(c.t, 0, 0.45), .expoOut), leave = Anim.exit(c.t, c.d, 0.3)
        let y = cy - c.px(24) * (1 - enter) - c.px(12) * leave
        var layers = [c.place(card, at: (cx, y), scale: 0.97 + 0.03 * enter, opacity: enter * (1 - leave))]
        // Ticks.
        let given = m.numbers("times")
        let first = m.number("firstTick", 0.6), step = m.number("interval", 0.45)
        let top = y - h / 2
        for i in rows.indices {
            let at = i < given.count ? given[i] : first + step * Double(i)
            let pop = Anim.spring(c.t, at, length: 0.35)
            guard pop > 0.001 else { continue }
            let draw = Int((Anim.p(c.t, at + 0.06, 0.2) * 12).rounded())
            let s = c.px(38)
            let tick = c.sprite("tick|\(accent)|\(draw)", s + 4, s + 4) { ctx in
                let b = CGRect(x: 2, y: 2, width: s, height: s)
                Draw.roundedRect(ctx, b, radius: c.px(9), fill: TitleRasterizer.color(accent))
                Draw.check(ctx, in: b, color: TitleRasterizer.color("#FFFFFF"), width: c.px(4.2), progress: Double(draw) / 12)
            }
            let bx = cx - w / 2 + pad + s / 2, by = top + titleH + rowH * (Double(i) + 0.5)
            layers.append(c.place(tick, at: (bx, by), scale: min(pop, 1.08), opacity: min(pop * 2, 1) * enter * (1 - leave)))
        }
        return MotionCanvas.stack(layers)
    }

    /// The right accessory of a row: colour dots, a badge, or text.
    static func accessory(_ ctx: CGContext, _ c: MotionCanvas, _ spec: String, right: Double, cy: Double, dark: Bool) {
        let s = spec.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        let ink = dark ? TitleRasterizer.color("#F5F3EE") : TitleRasterizer.color("#141414")
        if s.lowercased().hasPrefix("badge:") {
            let label = String(s.dropFirst(6)).uppercased()
            let f = c.font("mono", 20)
            let tw = Draw.width(label, f, tracking: c.px(1.5))
            let r = CGRect(x: right - tw - c.px(24), y: cy - c.px(17), width: tw + c.px(24), height: c.px(34))
            Draw.roundedRect(ctx, r, radius: c.px(17), fill: TitleRasterizer.color(c.m.style.color("accent"), alpha: 0.16))
            Draw.text(ctx, label, f, TitleRasterizer.color(c.m.style.color("accent")), x: r.midX, centreY: cy, align: 0.5, tracking: c.px(1.5))
            return
        }
        let parts = s.split(separator: " ").map(String.init)
        if parts.allSatisfy({ $0.hasPrefix("#") || c.m.style.colors[$0] != nil }) {
            let d = c.px(26)
            for (k, p) in parts.reversed().enumerated() {
                let r = CGRect(x: right - d - Double(k) * (d + c.px(6)), y: cy - d / 2, width: d, height: d)
                ctx.setFillColor(TitleRasterizer.color(c.m.style.color(p)))
                ctx.fillEllipse(in: r)
                ctx.setStrokeColor(dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.18) : TitleRasterizer.color("#000000", alpha: 0.1))
                ctx.setLineWidth(c.px(1.5)); ctx.strokeEllipse(in: r)
            }
            return
        }
        Draw.text(ctx, s, c.font("display", 30), ink, x: right, centreY: cy, align: 1)
    }
}
