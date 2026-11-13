import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Floating windows behind the speaker, tilted in perspective, popping in one after the other and drifting gently:
/// the user's images (screenshots) or generated editor panels (MockPanels).
enum CardStack: MotionTemplate {
    static let spec = MotionSpec(
        id: "card-stack", label: "Finestre", symbol: "macwindow.on.rectangle",
        guide: CatalogGuide("Four to six floating app windows (dark glass, traffic-light buttons) arranged around the upper half of the frame behind the speaker's head, slightly tilted back in perspective, popping in one after the other and drifting gently. Shows the user's screenshots, or generated editor panels (timeline, colour wheels, keyframe curve, waveform, effects grid).",
                            useWhen: "The speaker talks about tools, software, a workflow or \"everything you no longer have to touch\" — a busy-but-clean tech backdrop for 2–4 s. With real screenshots of the product, it shows the product without leaving the talking head. Needs matte.track.",
                            avoid: "Frames where the head fills the top half (nothing visible), non-tech topics, screenshots with tiny text that must be read, or together with other top-band graphics."),
        fields: [
            .init("images", "images", [], "Screenshots for the windows (up to 6). Empty: generated panels."),
            .init("panels", "list", ["timeline", "wheels", "curve", "waveform", "fx"], "Generated panels when there are no images: timeline, wheels, curve, waveform, fx, sliders, number."),
            .init("tilt", "number", 10, "How much the windows lean back, degrees."),
            .init("y", "number", 0, "Shift of the whole group, px (negative = up)."),
            .init("stagger", "number", 0.12, "Seconds between two windows popping in."),
        ],
        form: ["images", "panels", "tilt"], duration: 4, band: nil, layering: .behind)

    /// Slots: centre x (fraction of the width), centre y (px on a 1080×1920 frame), width, height (px), turn, roll.
    static let slots: [(Double, Double, Double, Double, Double, Double)] = [
        (0.27, 360, 560, 300, 12, -1.5), (0.74, 330, 520, 280, -12, 1.5), (0.5, 520, 500, 270, 0, 0),
        (0.25, 660, 480, 250, 14, 1), (0.76, 680, 500, 260, -14, -1), (0.5, 205, 420, 200, 0, 0.5),
    ]

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let images = m.strings("images").filter { !$0.isEmpty }
        let panels = m.strings("panels").filter { MockPanels.kinds.contains($0) }
        let n = min(max(images.isEmpty ? panels.count : images.count, 1), slots.count)
        let order = [5, 0, 1, 3, 4, 2]   // back to front: the top window first, the centre one last
        let fade = 1 - Anim.exit(c.t, c.d, 0.35)
        var layers: [CIImage] = []
        for (k, slot) in order.filter({ $0 < n }).enumerated() {
            let s = slots[slot]
            let pop = Anim.spring(c.t, m.number("stagger", 0.12) * Double(k), length: 0.5)
            guard pop > 0.001 else { continue }
            let w = c.px(s.2), h = c.px(s.3)
            let sprite: CIImage
            if !images.isEmpty, let photo = c.photo(images[slot % images.count], w, h - c.px(40), radius: 0) {
                sprite = window(c, photo, w: w, h: h, key: images[slot % images.count])
            } else {
                sprite = MockPanels.panel(c, kind: panels.isEmpty ? MockPanels.kinds[slot % MockPanels.kinds.count] : panels[slot % panels.count], w: w, h: h,
                                          phase: Anim.p(c.t, 0.3 + 0.1 * Double(k), 2.2))
            }
            let drift = c.px(7) * sin(c.t * 1.2 + Double(slot))
            let at = (s.0 * c.W, (s.1 + m.number("y", 0)) / SafeZones.referenceHeight * c.H + drift + c.px(30) * (1 - pop))
            layers.append(c.place(sprite, at: at, scale: 0.86 + 0.14 * pop, rotation: s.5, opacity: min(pop * 1.5, 1) * fade,
                                  rotationX: m.number("tilt", 10), rotationY: s.4, perspective: 1800))
        }
        return MotionCanvas.stack(layers)
    }

    /// A screenshot in the same dark window chrome as the generated panels.
    static func window(_ c: MotionCanvas, _ photo: CIImage, w: Double, h: Double, key: String) -> CIImage {
        let pad = c.px(40)
        let frame = c.sprite("win|\(key)|\(Int(w))x\(Int(h))", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(18), fill: TitleRasterizer.color("#1C1D21"), shadow: 0.4, blur: c.px(34), dy: c.px(14),
                      stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.09))
            for (i, col) in ["#FF5F57", "#FEBC2E", "#28C840"].enumerated() {
                ctx.setFillColor(TitleRasterizer.color(col))
                ctx.fillEllipse(in: CGRect(x: r.minX + c.px(18) + Double(i) * c.px(21), y: r.minY + c.px(14), width: c.px(13), height: c.px(13)))
            }
        }
        let body = MotionCanvas.round(photo, radius: c.px(12)).transformed(by: CGAffineTransform(translationX: pad, y: pad))
        return body.composited(over: frame)
    }
}
