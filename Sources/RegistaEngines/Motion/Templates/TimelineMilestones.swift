import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A horizontal axis with labelled ticks (months), thumbnails growing along it, the last one large, a title above.
enum TimelineMilestones: MotionTemplate {
    static let spec = MotionSpec(
        id: "timeline-milestones", label: "Linea del tempo", symbol: "point.3.connected.trianglepath.dotted",
        guide: CatalogGuide("A mixed headline top-left (\"five *months*\"), then a thin horizontal axis with dots and small mono labels (MAY, JUN… OCT, the last one in the accent colour); above the ticks, rounded thumbnails appear one after the other, each a little bigger than the last, the final one large with a shadow — progress over time at a glance.",
                            useWhen: "A journey or a growth story over 4–7 steps in time (months, years, versions): \"in five months we went from this to this\", with real pictures of each stage. Interstitial on a white or paper scene.",
                            avoid: "More than 7 steps, events without a time order, pictures that do not show progress, over a busy shot."),
        fields: [
            .init("title", "text", "five *months*", "Headline (*starred* words in the serif italic accent)."),
            .init("labels", "list", ["MAY", "JUN", "JUL", "AUG", "SEP", "OCT"], "Tick labels (4–7)."),
            .init("images", "images", [], "One picture per milestone (the last one is shown large). Empty: generated thumbnails."),
            .init("ink", "color", "ink", "Axis and headline colour."),
        ],
        form: ["title", "labels", "images"], duration: 4, band: "middle")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let labels = Array(m.strings("labels").prefix(7))
        guard labels.count >= 2 else { return nil }
        let images = m.strings("images").filter { !$0.isEmpty }
        let ink = m.color("ink", "ink")
        let (_, cy) = c.centre
        let leave = Anim.exit(c.t, c.d, 0.25)
        var layers: [CIImage] = []
        // Title.
        let runs = KickerHeadline.runs(m.string("title", "five *months*"))
        let bold = c.font("textBold", 84), serif = (try? TitleRasterizer.font("Georgia-Italic", size: c.px(92))) ?? c.font("serif", 92)
        let tw = runs.reduce(0) { $0 + Draw.width($1.text, $1.accent ? serif : bold, tracking: -c.px(2)) }
        let title = c.sprite("tm-title|\(runs.map { "\($0.accent)\($0.text)" })|\(ink)", tw + c.px(20), c.px(130)) { ctx in
            var x = 0.0
            for r in runs { x += Draw.text(ctx, r.text, r.accent ? serif : bold, c.cg(r.accent ? "accent" : ink), x: x, baseline: c.px(96), tracking: -c.px(2)) }
        }
        layers.append(c.place(title, at: (c.px(60) + title.extent.width / 2, cy - c.px(250)), opacity: Anim.p(c.t, 0, 0.4) * (1 - leave)))
        // Axis.
        let x0 = c.px(60), x1 = c.W - c.px(60), ay = cy + c.px(120)
        let draw = Anim.ease(Anim.p(c.t, 0.15, 0.7), .easeInOut)
        let axis = c.sprite("tm-axis|\(labels)|\(ink)|\(Int(draw * 40))", c.W, c.px(70)) { ctx in
            ctx.setFillColor(c.cg(ink, 0.8)); ctx.fill(CGRect(x: x0, y: c.px(10), width: (x1 - x0) * draw, height: max(c.px(2), 1)))
            for (i, l) in labels.enumerated() {
                let x = x0 + (x1 - x0) * Double(i) / Double(labels.count - 1)
                guard (x - x0) / (x1 - x0) <= draw + 0.001 else { continue }
                let last = i == labels.count - 1
                ctx.setFillColor(last ? c.cg("accent") : c.cg(ink)); ctx.fillEllipse(in: CGRect(x: x - c.px(6), y: c.px(5), width: c.px(12), height: c.px(12)))
                Draw.text(ctx, l, c.font("mono", 18), last ? c.cg("accent") : c.cg(ink, 0.55), x: x, centreY: c.px(48), align: i == 0 ? 0.1 : last ? 0.9 : 0.5, tracking: c.px(2))
            }
        }
        layers.append(c.place(axis, at: (c.W / 2, ay + c.px(25)), opacity: 1 - leave))
        // Thumbnails growing along the axis.
        for i in labels.indices {
            let x = x0 + (x1 - x0) * Double(i) / Double(labels.count - 1)
            let pop = Anim.spring(c.t, 0.4 + 0.18 * Double(i), length: 0.45)
            guard pop > 0.001 else { continue }
            let last = i == labels.count - 1
            let f = 0.55 + 0.45 * Double(i) / Double(labels.count - 1)
            let w = last ? c.px(420) : c.px(200) * f, h = w * (last ? 0.62 : 0.6)
            var thumb: CIImage
            if i < images.count, let p = c.photo(images[i], w, h, radius: c.px(10)) { thumb = p } else { thumb = ThumbnailRing.thumb(c, i, w: w, h: h) }
            thumb = c.shadow(thumb, opacity: last ? 0.3 : 0.18, radius: last ? 28 : 14, drop: last ? 12 : 5)
            let px = last ? x1 - w / 2 + c.px(10) : max(x, x0 + w / 2 - c.px(10))
            layers.append(c.place(thumb, at: (px, ay - c.px(24) - h / 2), scale: 0.8 + 0.2 * pop, opacity: min(pop * 1.5, 1) * (1 - leave)))
        }
        return MotionCanvas.stack(layers)
    }
}
