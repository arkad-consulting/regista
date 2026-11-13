import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// One or two columns of stacked screenshots (pages fanned slightly behind each other) with numbered mono labels.
enum StackedPages: MotionTemplate {
    static let spec = MotionSpec(
        id: "stacked-pages", label: "Pagine impilate", symbol: "square.stack",
        guide: CatalogGuide("One or two columns, each a small stack of rounded screenshots fanned slightly behind one another (soft shadows), with a numbered mono label above (\"01 · THE MODELS GOT BETTER\", \"02 · A BETTER SYSTEM\"); the stacks rise in one after the other and the back pages fan out a little.",
                            useWhen: "Giving two reasons or two sources side by side with evidence (articles, landing pages, docs, release notes), or one stack of pages for \"I read all of this\". Real screenshots.",
                            avoid: "More than two columns, labels longer than ~5 words, screenshots that must be read in full, generic placeholder pages in a final edit."),
        fields: [
            .init("labels", "list", ["The models got better", "A better system"], "One label per column (1–2)."),
            .init("images", "images", [], "Screenshots: the first half for column 1, the rest for column 2. Empty: generated pages."),
            .init("ink", "color", "ink", "Label colour."),
        ],
        form: ["labels", "images"], duration: 3.5, band: "middle")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let labels = Array(m.strings("labels").prefix(2))
        guard !labels.isEmpty else { return nil }
        let images = m.strings("images").filter { !$0.isEmpty }
        let cols = labels.count
        let (cx, cy) = c.centre
        let leave = Anim.exit(c.t, c.d, 0.25)
        let w = cols == 1 ? c.px(620) : c.px(440), h = w * 0.66
        var layers: [CIImage] = []
        for (k, label) in labels.enumerated() {
            let colX = cols == 1 ? cx : cx + (Double(k) - 0.5) * (w + c.px(60))
            let rise = Anim.ease(Anim.p(c.t, 0.1 + 0.25 * Double(k), 0.55), .expoOut)
            guard rise > 0.001 else { continue }
            let fan = Anim.ease(Anim.p(c.t, 0.4 + 0.25 * Double(k), 0.6), .easeOut)
            let mine = images.isEmpty ? [] : Array(images[(k * images.count / cols)..<((k + 1) * images.count / cols)])
            // The stack is composed first and faded as one picture (the back pages never show through the front one).
            var stack: [CIImage] = []
            for depth in (0..<3).reversed() {
                var page: CIImage
                if depth < mine.count, let p = c.photo(mine[depth], w, h, radius: c.px(14)) { page = p } else { page = landing(c, k * 3 + depth, w: w, h: h) }
                page = c.shadow(page, opacity: 0.22, radius: 22, drop: 10)
                let off = Double(depth) * c.px(14) * fan
                stack.append(c.place(page, at: (colX - off, cy - c.px(40) - off + c.px(50) * (1 - rise)), scale: 1 - 0.03 * Double(depth),
                                     rotation: -Double(depth) * 1.5 * fan))
            }
            layers.append(MotionCanvas.fade(MotionCanvas.stack(stack), rise * (1 - leave)))
            let f = c.font("mono", 18)
            let text = String(format: "%02d · %@", k + 1, label.uppercased())
            let lw = Draw.width(text, f, tracking: c.px(3)) + c.px(10)
            let lab = c.sprite("sp-lab|\(text)|\(m.string("ink"))", lw, c.px(30)) { ctx in
                Draw.text(ctx, text, f, c.cg(m.color("ink", "ink"), 0.6), x: 0, centreY: c.px(15), tracking: c.px(3))
            }
            layers.append(c.place(lab, at: (colX - w / 2 + lw / 2, cy - c.px(40) - h / 2 - c.px(52)), opacity: rise * (1 - leave)))
        }
        return MotionCanvas.stack(layers)
    }

    /// A generated landing page: a dusk gradient hero with a serif title, a nav bar, a button.
    static func landing(_ c: MotionCanvas, _ i: Int, w: Double, h: Double) -> CIImage {
        c.sprite("landing|\(i)|\(Int(w))", w, h) { ctx in
            let dark = i % 2 == 0
            Draw.roundedRect(ctx, CGRect(x: 0, y: 0, width: w, height: h), radius: c.px(14), fill: TitleRasterizer.color(dark ? "#101014" : "#F6F3EE"))
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: c.px(14), cornerHeight: c.px(14), transform: nil)); ctx.clip()
            if dark {
                let g = CGGradient(colorsSpace: TitleRasterizer.space, colors: [TitleRasterizer.color("#1B2340"), TitleRasterizer.color("#C8643B"), TitleRasterizer.color("#2A1A14")] as CFArray, locations: [0, 0.62, 1])!
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h * 0.12), end: CGPoint(x: 0, y: h), options: [])
            }
            ctx.restoreGState()
            let ink = dark ? "#FFFFFF" : "#141414"
            ctx.setFillColor(c.cg(ink, 0.6))
            for k in 0..<4 { ctx.fill(CGRect(x: w * 0.35 + Double(k) * w * 0.09, y: h * 0.06, width: w * 0.06, height: c.px(5))) }
            Draw.text(ctx, dark ? "A new model" : "SKILL.md", (try? TitleRasterizer.font(dark ? "Georgia" : "Menlo", size: c.px(dark ? 34 : 16))) ?? c.font("display", 34),
                      c.cg(ink), x: w / 2, centreY: h * 0.42, align: 0.5)
            Draw.roundedRect(ctx, CGRect(x: w / 2 - c.px(50), y: h * 0.62, width: c.px(100), height: c.px(22)), radius: c.px(11), fill: c.cg(dark ? "#FFFFFF" : "accent", 0.9))
        }
    }
}
