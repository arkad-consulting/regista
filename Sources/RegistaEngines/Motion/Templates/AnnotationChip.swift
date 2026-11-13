import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A small pill with a dot ("• Added by Claude", "captions") that pops in next to a point, with an optional thin
/// leader line to what it labels.
enum AnnotationChip: MotionTemplate {
    static let spec = MotionSpec(
        id: "annotation-chip", label: "Etichetta", symbol: "capsule",
        guide: CatalogGuide("A small rounded pill — dark glass with white text, or white with dark text — with a coloured dot before the words (\"• Added by AI\", \"captions\"), popping in with a tame spring next to a point of the frame; an optional hairline leader runs from the pill to the exact spot it labels, and the dot pulses softly.",
                            useWhen: "Labelling one thing on screen in 1–4 words: an object in the speaker's hand, a detail in the room, an element added in post, a UI part (\"captions\", \"the cards\"). Several chips can appear one after the other on a list of elements.",
                            avoid: "Long sentences (use a card), labelling the speaker's face, more than 3 chips at once, chips in the caption band or under the Instagram buttons."),
        fields: [
            .init("text", "text", "Added by AI", "The label, 1–4 words."),
            .init("position", "point", [760, 860], "Centre of the pill [x, y] on a 1080×1920 frame."),
            .init("target", "numbers", [], "Optional [x, y] the leader line points to (empty = no line)."),
            .init("theme", "choice", "dark", "Pill style.", choices: ["dark", "light"]),
            .init("dot", "color", "accent", "Dot colour."),
        ],
        form: ["text", "position", "theme"], duration: 2.5, band: nil)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let text = m.string("text", "Added by AI")
        let dark = m.string("theme", "dark") == "dark"
        let f = c.font("textBold", 30)
        let tw = Draw.width(text, f)
        let h = c.px(58), w = tw + c.px(78), pad = c.px(24)
        let dot = m.color("dot", "accent")
        let pill = c.sprite("chip|\(text)|\(dark)|\(dot)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: h / 2, fill: dark ? TitleRasterizer.color("#18181B", alpha: 0.88) : TitleRasterizer.color("#FFFFFF"), shadow: 0.25, blur: c.px(16), dy: c.px(5),
                      stroke: dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.12) : TitleRasterizer.color("#000000", alpha: 0.08))
            Draw.text(ctx, text, f, dark ? TitleRasterizer.color("#FFFFFF") : TitleRasterizer.color("#111111"), x: r.minX + c.px(52), centreY: r.midY)
        }
        let p = m.fields["position"]?.arrayValue?.compactMap(\.doubleValue) ?? [760, 860]
        let at = (c.px(p.count > 0 ? p[0] : 760), (p.count > 1 ? p[1] : 860) / SafeZones.referenceHeight * c.H)
        let pop = Anim.spring(c.t, 0, length: 0.4), leave = Anim.exit(c.t, c.d, 0.25)
        var layers: [CIImage] = []
        let target = m.numbers("target")
        if target.count == 2 {
            let tx = c.px(target[0]), ty = target[1] / SafeZones.referenceHeight * c.H
            let draw = Anim.ease(Anim.p(c.t, 0.15, 0.35), .easeOut)
            let ex = at.0 + (tx - at.0) * draw, ey = at.1 + (ty - at.1) * draw
            let minX = min(at.0, ex) - 8, minY = min(at.1, ey) - 8
            let line = c.sprite("lead|\(Int(at.0))|\(Int(at.1))|\(Int(ex))|\(Int(ey))|\(dark)", abs(ex - at.0) + 16, abs(ey - at.1) + 16) { ctx in
                ctx.setStrokeColor(TitleRasterizer.color(dark ? "#FFFFFF" : "#111111", alpha: 0.8)); ctx.setLineWidth(max(c.px(2), 1))
                ctx.move(to: CGPoint(x: at.0 - minX, y: at.1 - minY)); ctx.addLine(to: CGPoint(x: ex - minX, y: ey - minY)); ctx.strokePath()
                ctx.setFillColor(TitleRasterizer.color(dark ? "#FFFFFF" : "#111111")); ctx.fillEllipse(in: CGRect(x: ex - minX - 5, y: ey - minY - 5, width: 10, height: 10))
            }
            layers.append(c.place(line, at: (minX + line.extent.width / 2, minY + line.extent.height / 2), opacity: (1 - leave) * min(pop * 2, 1)))
        }
        layers.append(c.place(pill, at: at, scale: 0.7 + 0.3 * pop, opacity: min(pop * 1.6, 1) * (1 - leave)))
        // The dot, pulsing.
        let pulse = 1 + 0.18 * sin(c.t * 5)
        let d = c.px(16)
        let dotImg = c.sprite("dot|\(dot)", d + 4, d + 4) { ctx in
            ctx.setFillColor(TitleRasterizer.color(dot)); ctx.fillEllipse(in: CGRect(x: 2, y: 2, width: d, height: d))
        }
        layers.append(c.place(dotImg, at: (at.0 - w / 2 + c.px(28) * (0.7 + 0.3 * pop), at.1), scale: pulse * pop, opacity: min(pop * 1.6, 1) * (1 - leave)))
        return MotionCanvas.stack(layers)
    }
}
