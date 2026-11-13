import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Many phone or page screenshots scattered and slightly tilted around the speaker (behind the head), popping in one
/// after the other.
enum ScatterWall: MotionTemplate {
    static let spec = MotionSpec(
        id: "scatter-wall", label: "Muro di screenshot", symbol: "square.on.square.dashed",
        guide: CatalogGuide("A wall of 6–12 phone-shaped screenshots (rounded, soft shadows) scattered around the upper half of the frame behind the speaker, each slightly tilted, popping in one after the other and drifting a little — like posts pinned behind the head. Without images, generated light and dark page mock-ups in the brand colours.",
                            useWhen: "Showing volume or social proof: \"all these videos\", the posts made with a tool, a portfolio, many clients' sites — with real screenshots. Needs matte.track (it goes behind the head).",
                            avoid: "Fewer than 5 images (use card-stack or orbit-carousel), screenshots that must be read, heads that fill the top of the frame, together with a headline in the same band."),
        fields: [
            .init("images", "images", [], "Screenshots (6–12 paths). Empty: generated page mock-ups."),
            .init("count", "number", 9, "Number of tiles without images."),
            .init("stagger", "number", 0.08, "Seconds between two tiles popping in."),
            .init("tileWidth", "number", 200, "Tile width, px (tiles are 9:16)."),
        ],
        form: ["images", "count", "tileWidth"], duration: 3.5, band: nil, layering: .behind)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let images = m.strings("images").filter { !$0.isEmpty }
        let n = images.isEmpty ? min(max(Int(m.number("count", 9)), 3), 14) : min(images.count, 14)
        var rng = SeededRandom(seed: 0x5CA77E2)
        let w = c.px(m.number("tileWidth", 200)), h = w * 16 / 9
        let fade = 1 - Anim.exit(c.t, c.d, 0.3)
        var layers: [CIImage] = []
        for i in 0..<n {
            // Two columns on the sides plus a top row, avoiding the face (x 0.32–0.68 below y 560).
            let side = i % 3
            var x: Double, y: Double
            switch side {
            case 0: x = 0.08 + 0.18 * rng.next(); y = 260 + Double(i / 3) * 330 + 60 * rng.next()
            case 1: x = 0.74 + 0.18 * rng.next(); y = 230 + Double(i / 3) * 330 + 60 * rng.next()
            default: x = 0.3 + 0.4 * rng.next(); y = 180 + 80 * rng.next()
            }
            let tilt = (rng.next() - 0.5) * 14
            let pop = Anim.spring(c.t, m.number("stagger", 0.08) * Double(i), length: 0.45)
            guard pop > 0.001 else { continue }
            let tile: CIImage
            if !images.isEmpty, let p = c.photo(images[i], w, h, radius: c.px(18)) {
                tile = c.shadow(p, opacity: 0.3, radius: 20, drop: 10)
            } else {
                tile = page(c, i, w: w, h: h)
            }
            let drift = c.px(5) * sin(c.t * 1.1 + Double(i))
            layers.append(c.place(tile, at: (x * c.W, y / SafeZones.referenceHeight * c.H + drift), scale: 0.8 + 0.2 * pop, rotation: tilt, opacity: min(pop * 1.5, 1) * fade))
        }
        return MotionCanvas.stack(layers)
    }

    /// A generated phone page: dark or light, a headline bar, a picture block, a button.
    static func page(_ c: MotionCanvas, _ i: Int, w: Double, h: Double) -> CIImage {
        let pad = c.px(30)
        return c.sprite("page|\(i)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            let dark = i % 2 == 0
            Draw.card(ctx, r, radius: c.px(20), fill: TitleRasterizer.color(dark ? "#141416" : "#FAF8F4"), shadow: 0.3, blur: c.px(22), dy: c.px(10))
            let ink = dark ? "#FFFFFF" : "#141414"
            Draw.roundedRect(ctx, CGRect(x: r.minX + c.px(16), y: r.minY + c.px(28), width: w * 0.62, height: c.px(14)), radius: c.px(4), fill: c.cg(ink, 0.85))
            Draw.roundedRect(ctx, CGRect(x: r.minX + c.px(16), y: r.minY + c.px(50), width: w * 0.42, height: c.px(14)), radius: c.px(4), fill: c.cg("accent"))
            Draw.roundedRect(ctx, CGRect(x: r.minX + c.px(16), y: r.minY + c.px(84), width: w - c.px(32), height: h * 0.42), radius: c.px(10),
                             fill: c.cg(["accent", "primary", "highlight", "success"][i % 4], dark ? 0.85 : 0.75))
            for k in 0..<3 {
                Draw.roundedRect(ctx, CGRect(x: r.minX + c.px(16), y: r.minY + c.px(100) + h * 0.42 + Double(k) * c.px(18), width: w * (0.8 - 0.15 * Double(k)), height: c.px(8)),
                                 radius: c.px(3), fill: c.cg(ink, 0.3))
            }
            Draw.roundedRect(ctx, CGRect(x: r.midX - w * 0.3, y: r.maxY - c.px(52), width: w * 0.6, height: c.px(30)), radius: c.px(15), fill: c.cg("accent"))
        }
    }
}
