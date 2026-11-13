import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A card that shows a sound effect playing: a speaker icon in pulsing rings, an EFFECT label, and a waveform strip
/// with the effect's block highlighted under a moving playhead — placed on a real sound effect of the timeline.
enum SFXCallout: MotionTemplate {
    static let spec = MotionSpec(
        id: "sfx-callout", label: "Effetto sonoro", symbol: "speaker.wave.3",
        guide: CatalogGuide("A dark console card: a round speaker icon with rings pulsing out on the left, a bold \"EFFECT\" label and the effect's name, a small AUDIO tag, and a waveform strip where the sound effect's block is highlighted in the accent colour while a playhead runs across it. It reads the real sound effect on the timeline under the clip (sfx.add): its name and where it sits.",
                            useWhen: "Behind-the-scenes or tutorial reels about editing, to make a sound design moment visible (\"and here it adds a whoosh\") — put it over an sfx.add sound, 1.5–2.5 s.",
                            avoid: "Over every sound effect, reels that are not about the edit itself, or where there is no sound effect under the clip (the name falls back to the example)."),
        fields: [
            .init("label", "text", "EFFECT", "Big label."),
            .init("name", "text", "WHOOSH", "Effect name (default: the sound effect on the timeline under the clip)."),
            .init("block", "numbers", [0.4, 0.62], "Where the effect sits in the strip, [from, to] fractions (default: from the timeline)."),
            .init("tag", "text", "AUDIO", "Small tag at the right (\"\" = none)."),
        ],
        form: ["label", "name"], duration: 2.5, band: "lower")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let w = c.px(820), h = c.px(250), pad = c.px(70)
        let accent = c.cg("accent")
        let block = m.numbers("block").count == 2 ? m.numbers("block") : [0.4, 0.62]
        let head = min(max(c.t / c.d, 0), 1)
        let card = c.sprite("sfx|\(m.string("label"))|\(m.string("name"))|\(block)|\(m.string("tag"))|\(Int(head * 120))", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.console(ctx, r, radius: c.px(24), accent: accent, glow: c.px(20))
            Draw.text(ctx, m.string("label").uppercased(), c.font("textBold", 52), TitleRasterizer.color("#FFFFFF"), x: r.minX + c.px(190), centreY: r.minY + c.px(66))
            Draw.text(ctx, m.string("name").uppercased(), c.font("mono", 20), c.cg("accent"), x: r.minX + c.px(192), centreY: r.minY + c.px(110), tracking: c.px(3))
            let tag = m.string("tag")
            if !tag.isEmpty {
                let f = c.font("mono", 16)
                let tw = Draw.width(tag, f, tracking: c.px(2)) + c.px(20)
                Draw.roundedRect(ctx, CGRect(x: r.maxX - tw - c.px(24), y: r.minY + c.px(50), width: tw, height: c.px(30)), radius: c.px(6), fill: nil,
                                 stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.35), lineWidth: 1)
                Draw.text(ctx, tag, f, TitleRasterizer.color("#FFFFFF", alpha: 0.7), x: r.maxX - tw / 2 - c.px(24), centreY: r.minY + c.px(65), align: 0.5, tracking: c.px(2))
            }
            // Waveform strip.
            let strip = CGRect(x: r.minX + c.px(24), y: r.minY + c.px(150), width: w - c.px(48), height: c.px(70))
            Draw.roundedRect(ctx, strip, radius: c.px(12), fill: TitleRasterizer.color("#000000", alpha: 0.35))
            var rng = SeededRandom(seed: 0x5F0)
            let n = Int(strip.width / c.px(7))
            for i in 0..<n {
                let f = Double(i) / Double(n)
                let x = strip.minX + c.px(8) + Double(i) * c.px(7) * (strip.width - c.px(16)) / strip.width
                let inBlock = f >= block[0] && f <= block[1]
                guard !inBlock else { continue }
                let a = 0.2 + 0.8 * abs(sin(Double(i) * 0.37)) * rng.next()
                ctx.setFillColor(TitleRasterizer.color("#2BD48A", alpha: 0.85)); ctx.fill(CGRect(x: x, y: strip.midY - strip.height * 0.35 * a, width: c.px(3), height: strip.height * 0.7 * a))
            }
            let b = CGRect(x: strip.minX + strip.width * block[0], y: strip.minY + c.px(8), width: strip.width * (block[1] - block[0]), height: strip.height - c.px(16))
            ctx.saveGState(); ctx.setShadow(offset: .zero, blur: c.px(14), color: accent)
            Draw.roundedRect(ctx, b, radius: c.px(8), fill: accent); ctx.restoreGState()
            Draw.text(ctx, "SFX", c.font("mono", 22), TitleRasterizer.color("#1A0F08"), x: b.midX, centreY: b.midY, align: 0.5, tracking: c.px(3))
            let px = strip.minX + strip.width * head
            ctx.setFillColor(TitleRasterizer.color("#FFFFFF")); ctx.fill(CGRect(x: px - c.px(1.5), y: strip.minY - c.px(10), width: c.px(3), height: strip.height + c.px(20)))
        }
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        let at = (cx, cy - c.px(50) + c.px(20) * (1 - pop))   // clear of the caption band
        var layers = [c.place(card, at: at, scale: 0.94 + 0.06 * pop, opacity: min(pop * 1.5, 1) * (1 - leave))]
        // Speaker icon with rings pulsing out (redrawn per frame, small).
        let iconC = (at.0 - w / 2 + c.px(100), at.1 - h / 2 + c.px(88))
        for k in 0..<2 {
            let ph = (c.t * 1.4 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
            let d = c.px(110) * (1 + 0.7 * ph)
            let ring = c.sprite("ring|\(Int(d))", d + 8, d + 8) { ctx in
                ctx.setStrokeColor(accent); ctx.setLineWidth(c.px(3)); ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: d, height: d))
            }
            layers.append(c.place(ring, at: iconC, opacity: (1 - ph) * 0.7 * (1 - leave) * min(pop * 1.5, 1)))
        }
        let disc = c.sprite("spk|\(m.string("label"))", c.px(116), c.px(116)) { ctx in
            ctx.setFillColor(accent); ctx.fillEllipse(in: CGRect(x: c.px(4), y: c.px(4), width: c.px(108), height: c.px(108)))
            Draw.symbol(ctx, "speaker.wave.2.fill", in: CGRect(x: c.px(30), y: c.px(32), width: c.px(56), height: c.px(52)), color: TitleRasterizer.color("#1A0F08"))
        }
        layers.append(c.place(disc, at: iconC, scale: 0.8 + 0.2 * pop * (1 + 0.04 * sin(c.t * 9)), opacity: min(pop * 1.5, 1) * (1 - leave)))
        return MotionCanvas.stack(layers)
    }
}
