import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// The brand logo in a rounded app-icon tile with a soft glow, popping in.
enum LogoTile: MotionTemplate {
    static let spec = MotionSpec(
        id: "logo-tile", label: "Icona logo", symbol: "app.badge",
        guide: CatalogGuide("The brand kit's logo inside a rounded app-icon tile (white, or the kit's paper colour) with a thin accent ring and a soft glow behind it, popping in with a tame spring and floating gently — like an app icon on a home screen.",
                            useWhen: "Introducing the brand or the product in a tech reel, the \"input\" of a machine or a workflow graphic, or a closing signature — when a full logo sting is too much.",
                            avoid: "Without a brand kit logo (the tile falls back to the kit's initial), third-party logos (never draw them), more than once per reel."),
        fields: [
            .init("logo", "image", "", "Logo file (default: the applied brand kit's mark or logo)."),
            .init("tile", "color", "#FFFFFF", "Tile colour."),
            .init("size", "number", 220, "Tile size, px."),
        ],
        form: ["tile", "size"], duration: 2.5, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let s = c.px(m.number("size", 220)), pad = c.px(60)
        let logo = m.string("logo")
        let tile = c.sprite("tile|\(m.string("tile"))|\(Int(s))", s + 2 * pad, s + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: s, height: s)
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: c.px(40), color: c.cg("accent", 0.6))
            Draw.roundedRect(ctx, r.insetBy(dx: -c.px(10), dy: -c.px(10)), radius: s * 0.27, fill: TitleRasterizer.color("#16110D"), stroke: c.cg("accent"), lineWidth: c.px(3))
            ctx.restoreGState()
            Draw.roundedRect(ctx, r, radius: s * 0.23, fill: c.cg(m.color("tile", "#FFFFFF")))
            if logo.isEmpty {
                let initial = String((c.m.style.fonts["display"] != nil ? "R" : "R"))
                Draw.text(ctx, initial, c.font("display", s / c.k * 0.5), c.cg("ink"), x: r.midX, centreY: r.midY, align: 0.5)
            }
        }
        var img = tile
        if let l = c.image(logo) {
            // Logo fitted in 60 % of the tile.
            let f = min(s * 0.6 / l.extent.width, s * 0.6 / l.extent.height)
            let placed = l.transformed(by: CGAffineTransform(translationX: -l.extent.minX, y: -l.extent.minY)).transformed(by: CGAffineTransform(scaleX: f, y: f))
            img = placed.transformed(by: CGAffineTransform(translationX: pad + (s - placed.extent.width) / 2, y: pad + (s - placed.extent.height) / 2)).composited(over: tile)
        }
        let pop = Anim.spring(c.t, 0, length: 0.5), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        let float = c.px(6) * sin(c.t * 2)
        return c.place(img, at: (cx, cy + float), scale: 0.6 + 0.4 * pop, rotation: -6 * (1 - pop), opacity: min(pop * 1.6, 1) * (1 - leave))
    }
}
