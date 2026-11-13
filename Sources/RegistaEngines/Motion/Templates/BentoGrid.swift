import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A dark app panel with a 2×3 (or 2×2, 3×2) grid of tiles: each a numbered coloured label, some content (text
/// lines, an image, bars, a word, a contact sheet with checks, a bullet list) and a coloured underline that fills;
/// tiles appear one after the other.
enum BentoGrid: MotionTemplate {
    static let spec = MotionSpec(
        id: "bento-grid", label: "Griglia bento", symbol: "square.grid.3x2",
        guide: CatalogGuide("A dark rounded app panel (title and a green \"• DONE\" status in mono) holding a bento grid of 4–6 tiles; each tile has a small numbered label in its own colour (\"01 RESEARCH\", \"02 CUT\"…), generated content (text lines, a picture, coloured blocks, a big word, a grid of thumbnails with check marks, a bullet list) and an underline in its colour that fills when the tile completes. Tiles light up one after the other.",
                            useWhen: "Summarising a multi-step process or everything a tool does (research → cut → plan → graphics → check → learn) in one look, as an interstitial or in the top band; 4–6 steps with one-word names.",
                            avoid: "Steps with long names, more than 6 steps, when each step deserves its own moment (use card-row or a checklist), small screens of detail that must be read."),
        fields: [
            .init("title", "text", "Workflow", "Panel title."),
            .init("status", "text", "DONE", "Status at the top right (\"\" = none)."),
            .init("labels", "list", ["Research", "Cut", "Plan", "Graphics", "Check", "Learn"], "Tile names (4–6)."),
            .init("images", "images", [], "Optional pictures used by the picture tiles."),
            .init("columns", "number", 3, "Columns (2 or 3)."),
        ],
        form: ["title", "labels", "status"], duration: 4, band: "top")

    static let palette = ["#6C7CFF", "#E5484D", "#8B5CF6", "#E2A93B", "#22A06B", "#E8B04B"]

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let labels = Array(m.strings("labels").prefix(6))
        guard !labels.isEmpty else { return nil }
        let cols = min(max(Int(m.number("columns", 3)), 2), 3), rows = Int(ceil(Double(labels.count) / Double(cols)))
        let w = c.px(960), cellGap = c.px(12), head = c.px(64), pad = c.px(40)
        let cw = (w - c.px(36) - cellGap * Double(cols - 1)) / Double(cols), ch = cw * 0.78
        let h = head + Double(rows) * ch + Double(rows - 1) * cellGap + c.px(24)
        let per = max(c.d - 1.0, 1) / Double(labels.count)
        let done = labels.indices.map { Anim.p(c.t, 0.35 + per * Double($0), per * 0.9) }
        let q = done.map { Int(($0 * 10).rounded()) }
        let images = m.strings("images").filter { !$0.isEmpty }
        let panel = c.sprite("bento|\(labels)|\(m.string("title"))|\(m.string("status"))|\(q)|\(cols)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(24), fill: TitleRasterizer.color("#141416"), shadow: 0.35, blur: c.px(36), dy: c.px(14), stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.08))
            Draw.symbol(ctx, "sparkle", in: CGRect(x: r.minX + c.px(18), y: r.minY + c.px(20), width: c.px(24), height: c.px(24)), color: c.cg("accent"))
            Draw.text(ctx, m.string("title"), c.font("textBold", 24), TitleRasterizer.color("#FFFFFF"), x: r.minX + c.px(52), centreY: r.minY + c.px(32))
            let status = m.string("status")
            if !status.isEmpty && done.last ?? 0 >= 1 {
                Draw.text(ctx, "● " + status.uppercased(), c.font("mono", 15), TitleRasterizer.color("#2BD48A"), x: r.maxX - c.px(20), centreY: r.minY + c.px(32), align: 1, tracking: c.px(2))
            }
            for (i, label) in labels.enumerated() {
                let col = palette[i % palette.count]
                let cell = CGRect(x: r.minX + c.px(18) + Double(i % cols) * (cw + cellGap), y: r.minY + head + Double(i / cols) * (ch + cellGap), width: cw, height: ch)
                let p = Double(q[i]) / 10
                Draw.roundedRect(ctx, cell, radius: c.px(12), fill: TitleRasterizer.color("#1E1F23"), stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.06))
                guard p > 0 else { continue }
                Draw.text(ctx, String(format: "■ %02d  %@", i + 1, label.uppercased()), c.font("mono", 14), TitleRasterizer.color(col), x: cell.minX + c.px(14), centreY: cell.minY + c.px(22), tracking: c.px(1.5))
                let body = CGRect(x: cell.minX + c.px(14), y: cell.minY + c.px(42), width: cw - c.px(28), height: ch - c.px(70))
                content(ctx, c, i, body, color: col, progress: p, image: images.isEmpty ? nil : images[i % images.count])
                ctx.setFillColor(TitleRasterizer.color(col, alpha: 0.25)); ctx.fill(CGRect(x: cell.minX + c.px(14), y: cell.maxY - c.px(16), width: cw - c.px(28), height: c.px(3)))
                ctx.setFillColor(TitleRasterizer.color(col)); ctx.fill(CGRect(x: cell.minX + c.px(14), y: cell.maxY - c.px(16), width: (cw - c.px(28)) * p, height: c.px(3)))
            }
        }
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        return c.place(panel, at: (cx, cy + c.px(24) * (1 - pop)), scale: 0.95 + 0.05 * pop, opacity: min(pop * 1.5, 1) * (1 - leave))
    }

    static func content(_ ctx: CGContext, _ c: MotionCanvas, _ i: Int, _ b: CGRect, color: String, progress: Double, image: String?) {
        let white = TitleRasterizer.color("#FFFFFF", alpha: 0.75)
        switch i % 6 {
        case 0:
            for k in 0..<4 { Draw.roundedRect(ctx, CGRect(x: b.minX, y: b.minY + Double(k) * c.px(18), width: b.width * [0.9, 0.75, 0.85, 0.5][k] * min(progress * 1.5, 1), height: c.px(8)), radius: c.px(3), fill: white) }
        case 1:
            Draw.roundedRect(ctx, CGRect(x: b.minX, y: b.minY, width: b.width, height: b.height * 0.62), radius: c.px(6), fill: TitleRasterizer.color("#3A3B42"))
            for k in 0..<3 { Draw.roundedRect(ctx, CGRect(x: b.minX + Double(k) * b.width / 3, y: b.minY + b.height * 0.7, width: b.width / 3 - c.px(4), height: b.height * 0.3), radius: c.px(4), fill: TitleRasterizer.color("#3A3B42")) }
            ctx.setFillColor(TitleRasterizer.color("#FFFFFF")); ctx.fill(CGRect(x: b.minX + b.width * progress, y: b.minY, width: c.px(2), height: b.height))
        case 2:
            for k in 0..<6 {
                let x = b.minX + Double(k % 3) * b.width / 3, y = b.minY + Double(k / 3) * b.height / 2
                if Double(k) / 6 < progress { Draw.roundedRect(ctx, CGRect(x: x, y: y + c.px(4), width: b.width / 3 * (0.6 + 0.4 * Double((k * 7) % 3) / 2) - c.px(6), height: b.height / 2 - c.px(12)), radius: c.px(4), fill: TitleRasterizer.color(color)) }
            }
        case 3:
            Draw.roundedRect(ctx, CGRect(x: b.minX + b.width * 0.12, y: b.minY + b.height * 0.1, width: b.width * 0.76, height: b.height * 0.7), radius: c.px(6), fill: TitleRasterizer.color("#FFFFFF"))
            Draw.text(ctx, "six jobs", (try? TitleRasterizer.font("Georgia-Italic", size: c.px(28))) ?? c.font("serif", 28), c.cg("accent"), x: b.midX, centreY: b.minY + b.height * 0.45, align: 0.5)
        case 4:
            for k in 0..<8 {
                let tw = b.width / 4, th = b.height / 2
                let x = b.minX + Double(k % 4) * tw, y = b.minY + Double(k / 4) * th
                Draw.roundedRect(ctx, CGRect(x: x + c.px(2), y: y + c.px(2), width: tw - c.px(4), height: th - c.px(4)), radius: c.px(4), fill: TitleRasterizer.color(["#C9A27A", "#3A3B42", "#7A8FA6", "#B5655A"][k % 4]))
                if Double(k) / 8 < progress {
                    ctx.setFillColor(TitleRasterizer.color("#22A06B")); ctx.fillEllipse(in: CGRect(x: x + tw - c.px(16), y: y + th - c.px(16), width: c.px(12), height: c.px(12)))
                }
            }
        default:
            for (k, s) in ["keep the face on key lines", "land graphics on the word", "solid grounds", "let the reel play"].enumerated() where Double(k) / 4 < progress {
                Draw.text(ctx, "· " + s, c.font("text", 14), k == 3 ? TitleRasterizer.color("#FFFFFF") : white, x: b.minX, centreY: b.minY + c.px(8) + Double(k) * c.px(20))
            }
        }
        _ = image
    }
}
