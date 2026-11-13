import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A glass card with a title, a status badge ("READY" with a lock) and 2–4 thumbnails popping in.
enum GalleryCard: MotionTemplate {
    static let spec = MotionSpec(
        id: "gallery-card", label: "Scheda galleria", symbol: "rectangle.3.group",
        guide: CatalogGuide("A dark glass card in the top band with a title on the left (\"Your template\"), a small status badge on the right (\"READY\" with a lock symbol, in the accent colour) and a row of 2–4 rounded thumbnails (your images, or generated page mock-ups) popping in one after the other.",
                            useWhen: "Presenting a deliverable, a pack or a set: templates, a portfolio, the outputs of a process (\"your model is ready\"), 2–4 visuals with a status.",
                            avoid: "More than 4 thumbnails (use scatter-wall), images that must be read in detail, statuses that are not true."),
        fields: [
            .init("title", "text", "Your template", "Card title."),
            .init("status", "text", "READY", "Badge text (\"\" = none)."),
            .init("symbol", "symbol", "lock.fill", "SF Symbol after the badge (\"\" = none)."),
            .init("images", "images", [], "2–4 thumbnails. Empty: generated page mock-ups."),
            .init("count", "number", 3, "Thumbnails without images."),
        ],
        form: ["title", "status", "images"], duration: 3, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let images = m.strings("images").filter { !$0.isEmpty }
        let n = images.isEmpty ? min(max(Int(m.number("count", 3)), 2), 4) : min(images.count, 4)
        let w = c.px(860), pad = c.px(40), gap = c.px(16)
        let tw = (w - c.px(48) - gap * Double(n - 1)) / Double(n), th = tw * 1.05
        let h = th + c.px(110)
        let status = m.string("status", "READY"), symbol = m.string("symbol", "lock.fill"), title = m.string("title", "Your template")
        let card = c.sprite("gc|\(title)|\(status)|\(symbol)|\(n)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(26), fill: TitleRasterizer.color("#1A1A1D", alpha: 0.9), shadow: 0.35, blur: c.px(36), dy: c.px(14),
                      stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.1))
            Draw.text(ctx, title, c.font("textBold", 40), TitleRasterizer.color("#FFFFFF"), x: r.minX + c.px(26), centreY: r.minY + c.px(50))
            var right = r.maxX - c.px(24)
            if !symbol.isEmpty {
                Draw.symbol(ctx, symbol, in: CGRect(x: right - c.px(30), y: r.minY + c.px(35), width: c.px(30), height: c.px(30)), color: c.cg("accent"))
                right -= c.px(44)
            }
            if !status.isEmpty {
                let f = c.font("mono", 22)
                let sw = Draw.width(status.uppercased(), f, tracking: c.px(2)) + c.px(28)
                Draw.roundedRect(ctx, CGRect(x: right - sw, y: r.minY + c.px(32), width: sw, height: c.px(38)), radius: c.px(19), fill: nil,
                                 stroke: c.cg("accent", 0.8), lineWidth: c.px(2))
                Draw.text(ctx, status.uppercased(), f, c.cg("accent"), x: right - sw / 2, centreY: r.minY + c.px(51), align: 0.5, tracking: c.px(2))
            }
        }
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        let y = cy + c.px(24) * (1 - pop)
        var layers = [c.place(card, at: (cx, y), scale: 0.95 + 0.05 * pop, opacity: min(pop * 1.5, 1) * (1 - leave))]
        for i in 0..<n {
            let tp = Anim.spring(c.t, 0.2 + 0.1 * Double(i), length: 0.4)
            guard tp > 0.001 else { continue }
            let thumb: CIImage
            if !images.isEmpty, let p = c.photo(images[i], tw, th, radius: c.px(14)) { thumb = p } else {
                thumb = ScatterWall.page(c, i + 1, w: tw, h: th)
            }
            let x = cx - w / 2 + c.px(24) + tw / 2 + Double(i) * (tw + gap)
            layers.append(c.place(thumb, at: (x, y - h / 2 + c.px(88) + th / 2), scale: 0.85 + 0.15 * tp, opacity: min(tp * 1.5, 1) * (1 - leave)))
        }
        return MotionCanvas.stack(layers)
    }
}
