import CoreGraphics
import CoreImage
import CoreText
import Foundation
import RegistaCore

/// A paper tag hanging from a thin string from the top edge: it drops in, swings with a damped oscillation around the
/// string's top (anchor at the top) and turns a little in depth.
enum SwingTag: MotionTemplate {
    static let spec = MotionSpec(
        id: "swing-tag", label: "Cartellino", symbol: "tag",
        guide: CatalogGuide("A cream paper tag with a punched hole hangs from a thin string coming down from the top edge, beside the head: it drops in, swings and settles with a tame damped swing, turning slightly in depth. A small spaced kicker over one or two lines of heavy type (\"MONTEUR / UNE FORTUNE\").",
                            useWhen: "Labelling a price, a cost, a claim or a role in two words (\"COSTS A FORTUNE\", \"€9 / MONTH\", \"SOLD OUT\") — a playful but premium price-tag metaphor beside the speaker's head.",
                            avoid: "More than ~4 words, serious or sad topics, frames whose top corner is busy or where the head fills the top (the tag would cover it), several tags at once."),
        fields: [
            .init("kicker", "text", "PRICE", "Small spaced word above the title (\"\" = none)."),
            .init("title", "text", "A FORTUNE", "One or two short lines (\\n splits); heavy type."),
            .init("x", "number", 790, "Where the string hangs from, x on a 1080-wide frame."),
            .init("length", "number", 250, "String length above the tag, px."),
            .init("width", "number", 340, "Tag width, px."),
            .init("color", "color", "paper", "Tag colour."),
            .init("textColor", "color", "ink", "Text colour."),
            .init("swing", "number", 13, "First swing, degrees (the swing decays)."),
        ],
        form: ["kicker", "title", "x", "color"], duration: 3.5, band: nil)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let kicker = m.string("kicker"), lines = m.string("title", "A FORTUNE").replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: "\n").prefix(2)
        let w = c.px(m.number("width", 340)), string = c.px(m.number("length", 250))
        // The heaviest line fits 84 % of the tag.
        let base = lines.count > 1 ? 58.0 : 66.0
        let widest = lines.map { Draw.width($0.uppercased(), c.font("textBold", base), tracking: -c.px(1)) }.max() ?? 1
        let titleFont = c.font("textBold", base * min(1, w * 0.84 / max(widest, 1))), kickerFont = c.font("mono", 21)
        let lineH = CTFontGetSize(titleFont) * 0.98
        let h = c.px(150) + lineH * Double(lines.count) + (kicker.isEmpty ? 0 : c.px(16))
        let pad = c.px(40)
        let paper = m.color("color", "paper"), ink = m.color("textColor", "ink")
        let sw = w + 2 * pad, sh = string + h + 2 * pad
        let sprite = c.sprite("tag|\(kicker)|\(lines)|\(paper)|\(ink)", sw, sh) { ctx in
            let hole = CGPoint(x: sw / 2, y: pad + string + c.px(34))
            // String.
            ctx.setStrokeColor(TitleRasterizer.color("#1B1B1B", alpha: 0.85)); ctx.setLineWidth(max(c.px(2.2), 1))
            ctx.move(to: CGPoint(x: sw / 2, y: 0)); ctx.addLine(to: hole); ctx.strokePath()
            // Tag: a rectangle with clipped top corners (a luggage-tag shape).
            let r = CGRect(x: pad, y: pad + string, width: w, height: h)
            let cut = c.px(46), rad = c.px(10)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: r.minX + cut, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX - cut, y: r.minY))
            path.addLine(to: CGPoint(x: r.maxX, y: r.minY + cut))
            path.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: rad)
            path.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: rad)
            path.addLine(to: CGPoint(x: r.minX, y: r.minY + cut))
            path.closeSubpath()
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: c.px(6), height: c.px(14)), blur: c.px(26), color: CGColor(gray: 0, alpha: 0.28))
            ctx.addPath(path); ctx.setFillColor(TitleRasterizer.color(paper)); ctx.fillPath()
            ctx.restoreGState()
            // A faint paper shade towards the bottom.
            ctx.saveGState(); ctx.addPath(path); ctx.clip()
            let g = CGGradient(colorsSpace: TitleRasterizer.space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.06)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: r.minY), end: CGPoint(x: 0, y: r.maxY), options: [])
            ctx.restoreGState()
            // Punched hole with a ring.
            let hr = c.px(10)
            ctx.setFillColor(TitleRasterizer.color("#000000", alpha: 0.18)); ctx.fillEllipse(in: CGRect(x: hole.x - hr, y: hole.y - hr, width: 2 * hr, height: 2 * hr))
            ctx.setStrokeColor(TitleRasterizer.color("#B9A57A")); ctx.setLineWidth(c.px(3)); ctx.strokeEllipse(in: CGRect(x: hole.x - hr - c.px(3), y: hole.y - hr - c.px(3), width: 2 * hr + c.px(6), height: 2 * hr + c.px(6)))
            var y = hole.y + c.px(54)
            if !kicker.isEmpty {
                Draw.text(ctx, kicker.uppercased(), kickerFont, TitleRasterizer.color(ink, alpha: 0.7), x: sw / 2, centreY: y, align: 0.5, tracking: c.px(4))
                y += c.px(28)
            }
            for line in lines {
                Draw.text(ctx, line.uppercased(), titleFont, TitleRasterizer.color(ink), x: sw / 2, baseline: y + CTFontGetCapHeight(titleFont), align: 0.5, tracking: -c.px(1))
                y += lineH
            }
            ctx.setFillColor(TitleRasterizer.color("#B9A57A")); ctx.fill(CGRect(x: sw / 2 - c.px(36), y: y + c.px(10), width: c.px(72), height: max(c.px(2), 1)))
        }
        // Drop from above (0.45 s, ease-in then the swing takes over), damped swing, a slight turn in depth.
        let drop = Anim.ease(Anim.p(c.t, 0, 0.45), .easeIn)
        let lift = Anim.exit(c.t, c.d, 0.4)
        let swingT = c.t - 0.45
        let angle = swingT < 0 ? -m.number("swing", 13) * 0.4 : Anim.damped(swingT, amplitude: m.number("swing", 13), frequency: 0.85, decay: 1.5)
        let turn = swingT < 0 ? 0 : Anim.damped(swingT + 0.2, amplitude: 12, frequency: 0.6, decay: 1.0)
        let px = c.px(m.number("x", 790))
        let top = -sh * (1 - drop) - sh * lift + pad * 0   // sprite top (string top at the frame edge at rest)
        let centre = (px, top + sh / 2 - pad)
        return c.place(sprite, at: centre, rotation: angle, opacity: 1 - lift * 0.6, anchor: (0.5, pad / sh), rotationY: turn, perspective: 1600)
    }
}
