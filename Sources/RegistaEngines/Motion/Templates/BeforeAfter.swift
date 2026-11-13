import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Two stacked frames labelled BEFORE / AFTER on a dark stage, the after one with an accent glow border; a headline
/// on top with one accent word and an optional note pill. The frames show the shot itself (after) and a flat,
/// ungraded version of it (before) unless images are given.
enum BeforeAfter: MotionTemplate {
    static let spec = MotionSpec(
        id: "before-after", label: "Prima / dopo", symbol: "rectangle.split.1x2",
        guide: CatalogGuide("A dark stage with a two-line headline on top (one *accent* word in the brand colour), then two stacked rounded frames: BEFORE (a flat, grey, unedited-looking version of the shot, or an image you give) and AFTER (the edited shot itself, still playing) outlined with a soft accent glow; small labels with sublabels above each frame and an optional note pill at the bottom. The frames slide in one after the other.",
                            useWhen: "Showing the result of an edit, a redesign or a transformation: raw vs edited footage, old vs new website (with two screenshots), before/after a service. 3–5 s, once.",
                            avoid: "When the difference is invisible at phone size, without a real before (do not fake results), or mid-sentence on a talking head that does not discuss the change."),
        fields: [
            .init("headline", "text", "The method to edit\\nyour videos with *AI*", "Headline on top (\\n splits lines, *starred* = accent)."),
            .init("before", "text", "BEFORE", "Label of the top frame."),
            .init("beforeNote", "text", "Filmed, no edit", "Sublabel of the top frame."),
            .init("after", "text", "AFTER", "Label of the bottom frame."),
            .init("afterNote", "text", "Edited in Regista", "Sublabel of the bottom frame."),
            .init("beforeImage", "image", "", "Image for the BEFORE frame (default: the shot, flattened and grey)."),
            .init("afterImage", "image", "", "Image for the AFTER frame (default: the shot)."),
            .init("note", "text", "", "Optional pill at the bottom."),
        ],
        form: ["headline", "beforeNote", "afterNote", "note"], duration: 4, band: nil, consumesBelow: true, coversFrame: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let env = Anim.envelope(c.t, c.d, in: 0.35, out: 0.3)
        let shot = c.below ?? CIImage(color: c.ci("ink")).cropped(to: c.canvas)
        var stage = BackgroundScene.draw(MotionCanvas(m: MotionLayer(template: "background-scene", fields: ["style": "dark-grid", "color": .string(m.style.color("accent"))], style: m.style),
                                                      t: 1, d: 10, part: .whole, W: c.W, H: c.H, store: c.store, below: nil)) ?? .empty()
        stage = stage.cropped(to: c.canvas)
        var layers = [stage]
        // Headline.
        let lines = m.string("headline").replacingOccurrences(of: "\\n", with: "\n").components(separatedBy: "\n")
        let f = c.font("textBold", 58)
        let hl = c.sprite("ba-hl|\(lines)", c.W, c.px(170)) { ctx in
            for (i, line) in lines.prefix(2).enumerated() {
                let runs = KickerHeadline.runs(line)
                let total = runs.reduce(0) { $0 + Draw.width($1.text, f) }
                var x = (c.W - total) / 2
                for r in runs { x += Draw.text(ctx, r.text, f, c.cg(r.accent ? "accent" : "#FFFFFF"), x: x, baseline: c.px(64) + Double(i) * c.px(70)) }
            }
        }
        layers.append(c.place(hl, at: (c.W / 2, c.H * 235 / 1920), opacity: Anim.p(c.t, 0, 0.4)))
        // Frames.
        let fw = c.W * 0.86, fh = fw * 0.5
        let tops = [c.H * 400 / 1920, c.H * 400 / 1920 + fh + c.px(100)]
        for (k, top) in tops.enumerated() {
            let slide = Anim.ease(Anim.p(c.t, 0.15 + 0.25 * Double(k), 0.5), .expoOut)
            guard slide > 0.001 else { continue }
            let rect = CGRect(x: (c.W - fw) / 2, y: top, width: fw, height: fh)
            let path = m.string(k == 0 ? "beforeImage" : "afterImage")
            var pic: CIImage
            if !path.isEmpty, let img = c.photo(path, fw, fh, radius: c.px(18)) {
                pic = img.transformed(by: CGAffineTransform(translationX: rect.minX, y: c.H - rect.maxY))
            } else {
                pic = Inset.picture(shot, canvas: c.canvas, into: rect, radius: c.px(18), height: c.H)
                if k == 0 { pic = pic.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.25, kCIInputContrastKey: 0.85, kCIInputBrightnessKey: -0.04]) }
            }
            if k == 1 {
                let glow = c.sprite("ba-glow|\(Int(fw))", fw + c.px(80), fh + c.px(80)) { ctx in
                    let r = CGRect(x: c.px(40), y: c.px(40), width: fw, height: fh)
                    ctx.setShadow(offset: .zero, blur: c.px(30), color: c.cg("accent", 0.8))
                    Draw.roundedRect(ctx, r, radius: c.px(18), fill: nil, stroke: c.cg("accent"), lineWidth: c.px(3))
                }
                pic = c.place(glow, at: (rect.midX, rect.midY)).composited(over: pic)
            }
            let dx = c.px(60) * (1 - slide) * (k == 0 ? -1 : 1)
            layers.append(pic.transformed(by: CGAffineTransform(translationX: dx, y: 0)) |> { MotionCanvas.fade($0, slide) })
            let label = m.string(k == 0 ? "before" : "after"), sub = m.string(k == 0 ? "beforeNote" : "afterNote")
            let lab = c.sprite("ba-lab|\(k)|\(label)|\(sub)", fw, c.px(56)) { ctx in
                let w = Draw.text(ctx, label.uppercased(), c.font("textBold", 30), c.cg(k == 0 ? "#FFFFFF" : "accent"), x: 0, baseline: c.px(40))
                Draw.text(ctx, sub, c.font("text", 22), c.cg("#FFFFFF", 0.6), x: w + c.px(14), baseline: c.px(40))
            }
            layers.append(c.place(lab, at: (c.W / 2 + dx, top - c.px(34)), opacity: slide))
        }
        let note = m.string("note")
        if !note.isEmpty {
            let nf = c.font("textBold", 30)
            let nw = Draw.width(note, nf) + c.px(60)
            let pill = c.sprite("ba-note|\(note)", nw, c.px(70)) { ctx in
                Draw.roundedRect(ctx, CGRect(x: 0, y: 0, width: nw, height: c.px(70)), radius: c.px(14), fill: c.cg("paper"))
                Draw.text(ctx, note, nf, c.cg("ink"), x: nw / 2, centreY: c.px(35), align: 0.5)
            }
            layers.append(c.place(pill, at: (c.W / 2, c.H * 1495 / 1920), opacity: Anim.p(c.t, 0.8, 0.3)))
        }
        return MotionCanvas.fade(MotionCanvas.stack(layers), env).composited(over: shot)
    }
}

infix operator |>: AdditionPrecedence
/// Pipes a value into a function (keeps long Core Image chains readable).
func |> <A, B>(a: A, f: (A) -> B) -> B { f(a) }
