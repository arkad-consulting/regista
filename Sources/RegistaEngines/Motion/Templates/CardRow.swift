import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A row of 3–6 numbered step cards (number, an icon, a label) popping in one after the other under a title.
enum CardRow: MotionTemplate {
    static let spec = MotionSpec(
        id: "card-row", label: "Fila di schede", symbol: "rectangle.split.3x1",
        guide: CatalogGuide("A headline (mixed bold sans + *serif italic accent* word, e.g. \"every *job*\") over a row of 3–6 small white cards with soft shadows; each card has a coloured number (01, 02…), an SF Symbol icon on a light tile and a one-word label, popping in from left to right.",
                            useWhen: "Listing the steps or parts of a process in order (research, cut, plan, graphics, check, learn) as an interstitial on a white or paper background-scene, or in the top band over a calm shot.",
                            avoid: "More than 6 steps, labels longer than one or two words, icons that do not mean anything (leave the default symbols generic)."),
        fields: [
            .init("title", "text", "every *job*", "Headline (*starred* words in the serif italic accent)."),
            .init("labels", "list", ["Research", "Cut", "Plan", "Graphics", "Check", "Learn"], "Card labels (3–6)."),
            .init("symbols", "list", ["doc.text.magnifyingglass", "scissors", "square.grid.2x2", "sparkles", "checkmark.seal", "brain"], "One SF Symbol per card."),
            .init("titleColor", "color", "ink", "Headline colour."),
        ],
        form: ["title", "labels", "titleColor"], duration: 3.5, band: "middle")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let labels = Array(m.strings("labels").prefix(6)), symbols = m.strings("symbols")
        guard !labels.isEmpty else { return nil }
        let (cx, cy) = c.centre
        let leave = Anim.exit(c.t, c.d, 0.25)
        var layers: [CIImage] = []
        // Headline.
        let runs = KickerHeadline.runs(m.string("title", "every *job*"))
        let bold = c.font("textBold", 92), serif = (try? TitleRasterizer.font("Georgia-Italic", size: c.px(100))) ?? c.font("serif", 100)
        let tw = runs.reduce(0) { $0 + Draw.width($1.text, $1.accent ? serif : bold, tracking: -c.px(2)) }
        let title = c.sprite("cr-title|\(runs.map { "\($0.accent)\($0.text)" })|\(m.string("titleColor"))", tw + c.px(40), c.px(140)) { ctx in
            var x = c.px(20)
            for r in runs { x += Draw.text(ctx, r.text, r.accent ? serif : bold, c.cg(r.accent ? "accent" : m.color("titleColor", "ink")), x: x, baseline: c.px(100), tracking: -c.px(2)) }
        }
        let ta = Anim.ease(Anim.p(c.t, 0, 0.45), .expoOut)
        layers.append(c.place(title, at: (cx, cy - c.px(150) + c.px(20) * (1 - ta)), opacity: ta * (1 - leave)))
        // Cards.
        let n = Double(labels.count), gap = c.px(14)
        let w = min((c.W - c.px(60) - gap * (n - 1)) / n, c.px(220)), h = w * 1.18
        let total = w * n + gap * (n - 1)
        for (i, label) in labels.enumerated() {
            let pop = Anim.spring(c.t, 0.3 + 0.1 * Double(i), length: 0.4)
            guard pop > 0.001 else { continue }
            let col = BentoGrid.palette[i % BentoGrid.palette.count]
            let pad = c.px(24)
            let card = c.sprite("cr|\(i)|\(label)|\(i < symbols.count ? symbols[i] : "")|\(Int(w))", w + 2 * pad, h + 2 * pad) { ctx in
                let r = CGRect(x: pad, y: pad, width: w, height: h)
                Draw.card(ctx, r, radius: c.px(12), fill: TitleRasterizer.color("#FFFFFF"), shadow: 0.16, blur: c.px(18), dy: c.px(6))
                Draw.text(ctx, String(format: "%02d", i + 1), c.font("mono", 15), TitleRasterizer.color(col), x: r.minX + c.px(10), centreY: r.minY + c.px(16))
                let tile = CGRect(x: r.minX + c.px(10), y: r.minY + c.px(30), width: w - c.px(20), height: h * 0.52)
                Draw.roundedRect(ctx, tile, radius: c.px(8), fill: TitleRasterizer.color("#F2F1EE"))
                if i < symbols.count { Draw.symbol(ctx, symbols[i], in: tile.insetBy(dx: tile.width * 0.3, dy: tile.height * 0.25), color: TitleRasterizer.color(col)) }
                let lf = c.font("textBold", min(20, w / c.k / 6.5))
                Draw.text(ctx, label, lf, TitleRasterizer.color("#111111"), x: r.minX + c.px(10), centreY: r.maxY - c.px(20))
            }
            let x = cx - total / 2 + w / 2 + Double(i) * (w + gap)
            layers.append(c.place(card, at: (x, cy + c.px(70) + c.px(24) * (1 - pop)), scale: 0.85 + 0.15 * pop, opacity: min(pop * 1.5, 1) * (1 - leave)))
        }
        return MotionCanvas.stack(layers)
    }
}
