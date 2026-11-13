import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A generic video-platform card: a big play button over a player, placeholder video tiles and a "CONTENT · VIDEO"
/// label — no third-party logo.
enum PlayCard: MotionTemplate {
    static let spec = MotionSpec(
        id: "play-card", label: "Piattaforma video", symbol: "play.square.stack",
        guide: CatalogGuide("A clean video-platform card with no brand: a dark player area with a big round play button in the accent colour that pulses once, a progress line, a row of placeholder video tiles under it and a small mono label (\"CONTENT · VIDEO\"). It pops in and the play button presses.",
                            useWhen: "The speaker mentions publishing on a video platform, a channel, \"your content\", a course library — without naming or showing a third-party brand.",
                            avoid: "When a real channel screenshot would be more honest, alongside other cards in the same band, as a fake of a specific platform (keep it generic)."),
        fields: [
            .init("label", "text", "CONTENT · VIDEO", "Small label."),
            .init("title", "text", "New video", "Title under the player."),
            .init("theme", "choice", "dark", "Card style.", choices: ["dark", "light"]),
        ],
        form: ["label", "title", "theme"], duration: 3, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let dark = m.string("theme", "dark") == "dark"
        let w = c.px(760), h = c.px(560), pad = c.px(50)
        let prog = Anim.p(c.t, 0.6, max(c.d - 0.9, 0.5))
        let card = c.sprite("play|\(m.string("label"))|\(m.string("title"))|\(dark)|\(Int(prog * 60))", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: c.px(26), fill: dark ? TitleRasterizer.color("#141416") : TitleRasterizer.color("#FFFFFF"), shadow: 0.3, blur: c.px(34), dy: c.px(12),
                      stroke: dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.08) : nil)
            let player = CGRect(x: r.minX + c.px(22), y: r.minY + c.px(22), width: w - c.px(44), height: (w - c.px(44)) * 0.5)
            let g = CGGradient(colorsSpace: TitleRasterizer.space, colors: [TitleRasterizer.color("#2A2D36"), TitleRasterizer.color("#0E0F12")] as CFArray, locations: [0, 1])!
            ctx.saveGState(); ctx.addPath(CGPath(roundedRect: player, cornerWidth: c.px(16), cornerHeight: c.px(16), transform: nil)); ctx.clip()
            ctx.drawLinearGradient(g, start: CGPoint(x: player.minX, y: player.minY), end: CGPoint(x: player.maxX, y: player.maxY), options: [])
            ctx.restoreGState()
            ctx.setFillColor(TitleRasterizer.color("#FFFFFF", alpha: 0.25)); ctx.fill(CGRect(x: player.minX + c.px(16), y: player.maxY - c.px(18), width: player.width - c.px(32), height: c.px(4)))
            ctx.setFillColor(c.cg("accent")); ctx.fill(CGRect(x: player.minX + c.px(16), y: player.maxY - c.px(18), width: (player.width - c.px(32)) * prog, height: c.px(4)))
            let ink = dark ? "#FFFFFF" : "#111111"
            Draw.text(ctx, m.string("title"), c.font("textBold", 30), c.cg(ink), x: r.minX + c.px(26), centreY: player.maxY + c.px(40))
            Draw.text(ctx, m.string("label").uppercased(), c.font("mono", 16), c.cg(ink, 0.5), x: r.maxX - c.px(26), centreY: player.maxY + c.px(40), align: 1, tracking: c.px(3))
            let tw = (w - c.px(44) - c.px(24)) / 3
            for k in 0..<3 {
                let tile = CGRect(x: r.minX + c.px(22) + Double(k) * (tw + c.px(12)), y: player.maxY + c.px(76), width: tw, height: tw * 0.56)
                Draw.roundedRect(ctx, tile, radius: c.px(10), fill: c.cg(["primary", "accent", "ink"][k], dark ? 0.55 : 0.35))
                Draw.symbol(ctx, "play.fill", in: tile.insetBy(dx: tile.width * 0.42, dy: tile.height * 0.32), color: TitleRasterizer.color("#FFFFFF", alpha: 0.8))
            }
        }
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        let at = (cx, cy + c.px(24) * (1 - pop))
        var layers = [c.place(card, at: at, scale: 0.94 + 0.06 * pop, opacity: min(pop * 1.5, 1) * (1 - leave))]
        let d = c.px(120)
        let btn = c.sprite("playbtn", d + c.px(40), d + c.px(40)) { ctx in
            ctx.setShadow(offset: .zero, blur: c.px(20), color: c.cg("accent", 0.7))
            ctx.setFillColor(c.cg("accent")); ctx.fillEllipse(in: CGRect(x: c.px(20), y: c.px(20), width: d, height: d))
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            Draw.symbol(ctx, "play.fill", in: CGRect(x: c.px(20) + d * 0.34, y: c.px(20) + d * 0.28, width: d * 0.4, height: d * 0.44), color: TitleRasterizer.color("#FFFFFF"))
        }
        let press = c.t > 0.5 && c.t < 0.75 ? 1 - 0.1 * sin((c.t - 0.5) / 0.25 * .pi) : 1
        let playerCentreY = at.1 - h / 2 + c.px(22) + (w - c.px(44)) * 0.25
        layers.append(c.place(btn, at: (cx, playerCentreY), scale: press * (0.6 + 0.4 * Anim.spring(c.t, 0.15, length: 0.4)), opacity: min(pop * 1.5, 1) * (1 - leave)))
        return MotionCanvas.stack(layers)
    }
}
