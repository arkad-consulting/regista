import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Many thumbnails on a tilted ellipse rotating around a centre text (an orbit carousel without a person).
enum ThumbnailRing: MotionTemplate {
    static let spec = MotionSpec(
        id: "thumbnail-ring", label: "Anello di miniature", symbol: "circle.dashed.rectangle",
        guide: CatalogGuide("A ring of 12–24 small landscape thumbnails standing on a tilted ellipse, slowly rotating in 3D around a short bold text in the middle (\"edited by AI\"): the near side bigger and sharper, the far side smaller and dimmer, each card turned along the ring. Usually on a white or dark background-scene.",
                            useWhen: "Showing a body of work or volume (\"200 videos\", \"every thumbnail we made\", a library) as an interstitial, with your own thumbnails; or a brand/topic word surrounded by examples.",
                            avoid: "Over a talking head (use orbit-carousel, which goes behind the person), fewer than 8 images, thumbnails whose text must be read."),
        fields: [
            .init("text", "text", "edited by AI", "Text in the middle (\"\" = none)."),
            .init("images", "images", [], "Thumbnails (12–24, landscape). Empty: generated thumbnails in the brand colours."),
            .init("count", "number", 18, "Thumbnails without images."),
            .init("textColor", "color", "ink", "Centre text colour."),
            .init("radius", "number", 430, "Ring radius, px."),
            .init("period", "number", 16, "Seconds per turn."),
        ],
        form: ["text", "images", "textColor"], duration: 4, band: "middle")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let images = m.strings("images").filter { !$0.isEmpty }
        let n = images.isEmpty ? min(max(Int(m.number("count", 18)), 6), 30) : min(images.count, 30)
        let (cx, cy) = c.centre
        let grow = 0.7 + 0.3 * Anim.ease(Anim.p(c.t, 0, 0.8), .expoOut)
        let rx = c.px(m.number("radius", 430)) * grow, ry = rx * 0.36
        let base = c.t * 2 * .pi / max(m.number("period", 16), 1)
        let tw = c.px(150), th = tw * 9 / 16
        let env = Anim.envelope(c.t, c.d, in: 0.4, out: 0.35)
        var cards: [(Double, CIImage)] = []
        for i in 0..<n {
            let a = base + 2 * .pi * Double(i) / Double(n)
            let depth = cos(a)   // 1 = front
            let x = cx + rx * sin(a), y = cy + ry * depth
            let near = (depth + 1) / 2
            let sprite: CIImage
            if !images.isEmpty, let p = c.photo(images[i], tw, th, radius: c.px(8)) { sprite = p } else { sprite = thumb(c, i, w: tw, h: th) }
            let pop = Anim.spring(c.t, 0.02 * Double(i), length: 0.4)
            cards.append((depth, c.place(sprite, at: (x, y), scale: (0.6 + 0.4 * near) * pop, opacity: (0.55 + 0.45 * near) * env, rotationY: -sin(a) * 55, perspective: 1400)))
        }
        cards.sort { $0.0 < $1.0 }
        var layers = cards.filter { $0.0 < 0 }.map(\.1)
        let text = m.string("text", "edited by AI")
        if !text.isEmpty {
            let f = c.font("textBold", 64)
            let w = Draw.width(text, f) + c.px(40)
            let s = c.sprite("ring-text|\(text)|\(m.string("textColor"))", w, c.px(100)) { ctx in
                Draw.text(ctx, text, f, c.cg(m.color("textColor", "ink")), x: w / 2, centreY: c.px(50), align: 0.5)
            }
            layers.append(c.place(s, at: (cx, cy), opacity: env * Anim.p(c.t, 0.3, 0.4)))
        }
        layers += cards.filter { $0.0 >= 0 }.map(\.1)
        return MotionCanvas.stack(layers)
    }

    /// A generated video thumbnail: a colour field, a bold caption block, a face-like circle.
    static func thumb(_ c: MotionCanvas, _ i: Int, w: Double, h: Double) -> CIImage {
        c.sprite("thumb|\(i)", w, h) { ctx in
            let cols = ["ink", "accent", "primary", "#2B2B30", "highlight", "success"]
            Draw.roundedRect(ctx, CGRect(x: 0, y: 0, width: w, height: h), radius: c.px(8), fill: c.cg(cols[i % cols.count]))
            ctx.setFillColor(c.cg("#FFFFFF", 0.9))
            ctx.fill(CGRect(x: w * 0.08, y: h * 0.2, width: w * 0.45, height: h * 0.16))
            ctx.fill(CGRect(x: w * 0.08, y: h * 0.42, width: w * 0.32, height: h * 0.16))
            ctx.setFillColor(c.cg("#F2C9A8")); ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.25, width: h * 0.5, height: h * 0.5))
            ctx.setFillColor(c.cg("#3A2A20")); ctx.fillEllipse(in: CGRect(x: w * 0.62, y: h * 0.2, width: h * 0.5, height: h * 0.22))
        }
    }
}
