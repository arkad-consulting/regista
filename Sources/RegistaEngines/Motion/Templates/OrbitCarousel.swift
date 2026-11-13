import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Photo cards orbiting the speaker on a flat ellipse: the far half passes behind the person (matte), the near half
/// in front, with depth scale and opacity.
enum OrbitCarousel: MotionTemplate {
    static let spec = MotionSpec(
        id: "orbit-carousel", label: "Carosello orbitale", symbol: "rotate.3d",
        guide: CatalogGuide("3–8 rounded photo cards circle around the speaker on a tilted ellipse at chest/head height: cards at the back are smaller, dimmer and pass behind the person, cards at the front are bigger and pass in front. They pop in one by one, glide around slowly, and fade out.",
                            useWhen: "The line lists examples, clients, projects, products or places and you have their pictures (3–8): \"we built sites for restaurants, salons, gyms…\". Talking heads framed with room around the body. Needs matte.track over the window.",
                            avoid: "Without real images of the things named (placeholder panels are for previews only), wide shots where the person is small, busy moving cameras, or more than once per reel; text-heavy screenshots (they are too small to read)."),
        fields: [
            .init("images", "images", [], "Photos of the cards (3–8 paths). Empty: numbered panels in the brand colours (for previews)."),
            .init("count", "number", 6, "Number of cards when there are no images (3–8)."),
            .init("centerY", "number", 600, "Height of the orbit's centre, y on a 1080×1920 frame: just above the head, so the far side passes behind the hair and the near side over the forehead (check with frame.render; raise it if cards cover the eyes)."),
            .init("radius", "number", 430, "Horizontal radius of the orbit, px at 1080 wide."),
            .init("tilt", "number", 150, "Vertical radius: how much the ellipse is seen from above, px."),
            .init("cardWidth", "number", 200, "Card width at the front, px (cards are 4:5)."),
            .init("period", "number", 9, "Seconds per full turn (slower = calmer)."),
        ],
        form: ["images", "centerY", "radius", "period"], duration: 5, band: nil, layering: .split)

    struct Card { var index: Int; var x: Double; var y: Double; var depth: Double; var angle: Double }

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let images = m.strings("images").filter { !$0.isEmpty }
        let n = images.isEmpty ? min(max(Int(m.number("count", 6)), 3), 8) : min(images.count, 8)
        let cx = c.W / 2, cy = m.number("centerY", 600) / SafeZones.referenceHeight * c.H
        let grow = 0.65 + 0.35 * Anim.ease(Anim.p(c.t, 0, 0.9), .expoOut)
        let rx = c.px(m.number("radius", 430)) * grow, ry = c.px(m.number("tilt", 150)) * grow
        let omega = 2 * Double.pi / max(m.number("period", 9), 1)
        // Start with a card at the front-left so the first frame reads well.
        let base = -0.55 + omega * c.t
        var cards: [Card] = (0..<n).map { i in
            let a = base + 2 * .pi * Double(i) / Double(n)
            return Card(index: i, x: cx + rx * sin(a), y: cy + ry * cos(a), depth: cos(a), angle: a)
        }
        cards.sort { $0.depth < $1.depth }
        let w = c.px(m.number("cardWidth", 200)), h = w * 1.25
        let fadeOut = 1 - Anim.exit(c.t, c.d, 0.35)
        var layers: [CIImage] = []
        for card in cards {
            let back = card.depth < 0
            if c.part == .back && !back { continue }
            if c.part == .front && back { continue }
            let pop = Anim.spring(c.t, 0.08 * Double(card.index), length: 0.5)
            let near = (card.depth + 1) / 2
            let scale = (0.62 + 0.38 * near) * pop
            let opacity = (0.72 + 0.28 * near) * min(pop * 1.4, 1) * fadeOut
            let sprite = cardSprite(c, index: card.index, path: images.isEmpty ? nil : images[card.index], w: w, h: h)
            // Cards turn a little with the orbit (face the camera at the front, edge-on hints at the sides).
            layers.append(c.place(sprite, at: (card.x, card.y), scale: scale, opacity: opacity, rotationY: -sin(card.angle) * 28, perspective: 1600))
        }
        return MotionCanvas.stack(layers)
    }

    /// One card: the photo (or a numbered brand panel) with a thin light border and a soft shadow.
    static func cardSprite(_ c: MotionCanvas, index: Int, path: String?, w: Double, h: Double) -> CIImage {
        let pad = c.px(40), border = c.px(5), radius = c.px(22)
        let frame = c.sprite("card-frame|\(index)|\(path ?? "-")", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: radius, fill: c.cg("surface"), shadow: 0.3, blur: c.px(28), dy: c.px(12))
            if path == nil {
                // Placeholder: a brand-colour panel with a mono number.
                let colors = ["primary", "accent", "ink", "highlight", "success", "paper"]
                let fill = c.cg(colors[index % colors.count])
                Draw.roundedRect(ctx, r.insetBy(dx: border, dy: border), radius: radius - border, fill: fill)
                let dark = ["paper", "highlight"].contains(colors[index % colors.count])
                Draw.text(ctx, String(format: "%02d", index + 1), c.font("mono", 30), c.cg(dark ? "ink" : "paper", 0.9),
                          x: r.minX + c.px(22), baseline: r.minY + c.px(50))
                ctx.setStrokeColor(c.cg(dark ? "ink" : "paper", 0.35)); ctx.setLineWidth(c.px(2))
                for k in 0..<3 {
                    let y = r.maxY - c.px(36) - Double(k) * c.px(18)
                    ctx.move(to: CGPoint(x: r.minX + c.px(22), y: y)); ctx.addLine(to: CGPoint(x: r.maxX - c.px(22) - Double(k) * c.px(30), y: y)); ctx.strokePath()
                }
            }
        }
        guard let path, let photo = c.photo(path, w - 2 * border, h - 2 * border, radius: radius - border) else { return frame }
        return photo.transformed(by: CGAffineTransform(translationX: pad + border, y: pad + border)).composited(over: frame)
    }
}
