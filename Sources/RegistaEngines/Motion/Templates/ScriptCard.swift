import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A document card ("READ_TO_CAMERA.md", a line count) whose lines highlight one by one with the speech: the current
/// line bold and dark, past lines grey, the next ones faint.
enum ScriptCard: MotionTemplate {
    static let spec = MotionSpec(
        id: "script-card", label: "Copione", symbol: "doc.plaintext",
        guide: CatalogGuide("A small white document card beside the speaker: a file name with a document icon (\"READ_TO_CAMERA.md\") and a line count in mono at the top, a spaced section tag (\"— HOOK —\") in the accent colour, then 4–7 short script lines; the line being spoken turns bold and dark (and gets a soft highlight), the lines already said go grey, the next ones stay faint. Synced to the transcript.",
                            useWhen: "Behind-the-scenes or teleprompter content (\"I just read a script\"), showing that the words come from a script, quoting a few lines of a document while they are said.",
                            avoid: "Long paragraphs, lines that are not actually said (the highlight would be wrong), small text over a busy background."),
        fields: [
            .init("filename", "text", "READ_TO_CAMERA.md", "File name at the top."),
            .init("meta", "text", "144 LINES", "Mono note at the top right."),
            .init("section", "text", "HOOK", "Section tag (\"\" = none)."),
            .init("lines", "list", ["AI edited this entire video.", "Look at everything on screen right now.", "Not a single frame was cut by hand.",
                                    "I sat down and read a script,", "and the agent did everything else."], "Script lines (4–7, short)."),
            .init("times", "numbers", [], "When each line starts, seconds from the clip start (filled by sync: true)."),
            .init("position", "point", [800, 520], "Card centre [x, y] on a 1080×1920 frame."),
        ],
        form: ["filename", "section", "lines"], duration: 5, band: nil, syncField: "lines")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let lines = Array(m.strings("lines").prefix(8))
        guard !lines.isEmpty else { return nil }
        let given = m.numbers("times")
        let step = max(c.d - 0.8, 1) / Double(lines.count)
        let starts = lines.indices.map { i in i < given.count ? given[i] : 0.4 + step * Double(i) }
        let current = starts.lastIndex { $0 <= c.t } ?? -1
        let w = c.px(480), lh = c.px(38), pad = c.px(30)
        let hasSection = !m.string("section").isEmpty
        let h = c.px(78) + (hasSection ? c.px(36) : 0) + lh * Double(lines.count) + c.px(20)
        let f = c.font("text", 22), fb = c.font("textBold", 22)
        let card = c.sprite("script|\(lines)|\(current)|\(m.string("filename"))|\(m.string("section"))", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(16), fill: TitleRasterizer.color("#FFFFFF"), shadow: 0.25, blur: c.px(26), dy: c.px(10))
            Draw.symbol(ctx, "doc.text", in: CGRect(x: r.minX + c.px(18), y: r.minY + c.px(18), width: c.px(20), height: c.px(20)), color: TitleRasterizer.color("#111111", alpha: 0.7))
            Draw.text(ctx, m.string("filename"), c.font("mono", 17), TitleRasterizer.color("#111111", alpha: 0.85), x: r.minX + c.px(46), centreY: r.minY + c.px(29))
            Draw.text(ctx, m.string("meta"), c.font("mono", 14), TitleRasterizer.color("#111111", alpha: 0.4), x: r.maxX - c.px(18), centreY: r.minY + c.px(29), align: 1, tracking: c.px(1))
            ctx.setFillColor(TitleRasterizer.color("#000000", alpha: 0.08)); ctx.fill(CGRect(x: r.minX, y: r.minY + c.px(54), width: w, height: max(c.px(1.5), 1)))
            var y = r.minY + c.px(78)
            if hasSection {
                Draw.text(ctx, "— \(m.string("section").uppercased()) —", c.font("mono", 15), c.cg("accent"), x: r.minX + c.px(20), centreY: y, tracking: c.px(3))
                y += c.px(36)
            }
            for (i, line) in lines.enumerated() {
                let cy = y + lh * Double(i)
                if i == current {
                    Draw.roundedRect(ctx, CGRect(x: r.minX + c.px(12), y: cy - lh / 2 + c.px(2), width: w - c.px(24), height: lh - c.px(4)), radius: c.px(6),
                                     fill: c.cg("accent", 0.12))
                }
                let alpha = i == current ? 1.0 : i < current ? 0.42 : 0.22
                Draw.text(ctx, line, i == current ? fb : f, TitleRasterizer.color("#111111", alpha: alpha), x: r.minX + c.px(20), centreY: cy)
            }
        }
        let pos = m.fields["position"]?.arrayValue?.compactMap(\.doubleValue) ?? [800, 520]
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        return c.place(card, at: (c.px(pos.first ?? 800), (pos.count > 1 ? pos[1] : 520) / SafeZones.referenceHeight * c.H + c.px(20) * (1 - pop)),
                       scale: 0.92 + 0.08 * pop, opacity: min(pop * 1.5, 1) * (1 - leave))
    }
}
