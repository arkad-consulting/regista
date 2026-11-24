import CoreGraphics
import CoreImage
import CoreText
import Foundation
import RegistaCore

/// A small spaced kicker over a huge headline: one heavy word (it can go behind the speaker), or a mixed line where
/// the *starred* words are set in a serif italic in the accent colour ("every *job*").
enum KickerHeadline: MotionTemplate {
    static let spec = MotionSpec(
        id: "kicker-headline", label: "Titolone", symbol: "textformat.size.larger",
        guide: CatalogGuide("A small letter-spaced kicker in the accent colour (\"FROM NOW ON\") over one huge headline that rises into place: either a single heavy word filling the width (it can sit behind the speaker's head with behind: true), or a mixed line in a bold sans where the starred words switch to a serif italic in the accent colour — \"every *job*\", \"five *months*\".",
                            useWhen: "The one word or short phrase the whole line is about (a name, a turning point, \"every job\") — a chapter opener or a punchline, 1–3 words. On a plain background-scene it makes a clean interstitial; over the speaker with behind: true it gives the magazine-cover look.",
                            avoid: "More than ~4 words, repeating the caption at the same moment, busy backgrounds without behind: true or a scene, more than two per reel."),
        fields: [
            .init("kicker", "text", "FROM NOW ON", "Small spaced line above (\"\" = none)."),
            .init("headline", "text", "every *job*", "The headline; *starred* words are set in the serif italic accent style."),
            .init("color", "color", "#FFFFFF", "Headline colour (#FFFFFF over video, ink over a white scene)."),
            .init("accent", "color", "accent", "Kicker and starred-word colour."),
            .init("size", "number", 0, "Headline size, px (0 = fit the width: big)."),
            .init("serif", "text", "serif", "Font of the starred words (a role or a font name; serif = a classic italic)."),
        ],
        form: ["kicker", "headline", "color"], duration: 2.5, band: "top")

    struct Run { var text: String; var accent: Bool }

    static func runs(_ s: String) -> [Run] {
        var out: [Run] = [], cur = "", accent = false
        for ch in s {
            if ch == "*" { if !cur.isEmpty { out.append(Run(text: cur, accent: accent)) }; cur = ""; accent.toggle() } else { cur.append(ch) }
        }
        if !cur.isEmpty { out.append(Run(text: cur, accent: accent)) }
        return out
    }

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let rs = runs(m.string("headline", "every *job*"))
        guard !rs.isEmpty else { return nil }
        let mixed = rs.contains { $0.accent }
        let color = m.color("color", "#FFFFFF"), accent = m.color("accent", "accent")
        let serifName = m.string("serif", "serif")
        func fonts(_ size: Double) -> (CTFont, CTFont) {
            let bold = c.font("textBold", size)
            var serif = c.font(serifName, size * 1.08)
            if serifName == "serif" { serif = (try? TitleRasterizer.font("Georgia-Italic", size: size * 1.08 * c.k)) ?? serif }
            return (bold, serif)
        }
        func width(_ size: Double) -> Double {
            let (b, s) = fonts(size)
            return rs.reduce(0) { $0 + Draw.width(mixed ? $1.text : $1.text.uppercased(), $1.accent ? s : b, tracking: mixed ? -c.px(size * 0.02) : -c.px(size * 0.01)) }
        }
        var size = m.number("size", 0)
        if size <= 0 { size = min(220, 260 * 900 / max(width(260) / c.k, 1)) }
        let (bold, serif) = fonts(size)
        let total = width(size)
        let h = c.px(size * 1.3)
        let pad = c.px(40)
        let sprite = c.sprite("hl|\(rs.map { "\($0.accent)\($0.text)" })|\(color)|\(accent)|\(size)", total + 2 * pad, h + 2 * pad) { ctx in
            // A shadow offset ignores the flipped context: negative falls below.
            if color == "#FFFFFF" { ctx.setShadow(offset: CGSize(width: 0, height: -c.px(6)), blur: c.px(24), color: CGColor(gray: 0, alpha: 0.3)) }
            var x = pad
            let base = pad + h * 0.78
            for r in rs {
                let t = mixed ? r.text : r.text.uppercased()
                x += Draw.text(ctx, t, r.accent ? serif : bold, TitleRasterizer.color(r.accent ? accent : color), x: x, baseline: base,
                               tracking: mixed ? -c.px(size * 0.02) : -c.px(size * 0.01))
            }
        }
        let (cx, cy) = c.centre
        let rise = Anim.ease(Anim.p(c.t, 0.1, 0.55), .expoOut), leave = Anim.exit(c.t, c.d, 0.3)
        var layers = [c.place(sprite, at: (cx, cy + c.px(50) * (1 - rise)), scale: 0.94 + 0.06 * rise, opacity: rise * (1 - leave))]
        let kicker = m.string("kicker")
        if !kicker.isEmpty {
            let f = c.font("mono", 30)
            let kw = Draw.width(kicker.uppercased(), f, tracking: c.px(9)) + c.px(20)
            let k = c.sprite("kick|\(kicker)|\(accent)", kw, c.px(60)) { ctx in
                Draw.text(ctx, kicker.uppercased(), f, TitleRasterizer.color(accent), x: kw / 2, centreY: c.px(24), align: 0.5, tracking: c.px(9))
                ctx.setFillColor(TitleRasterizer.color(accent, alpha: 0.7)); ctx.fill(CGRect(x: kw / 2 - c.px(40), y: c.px(50), width: c.px(80), height: max(c.px(2), 1)))
            }
            let a = Anim.ease(Anim.p(c.t, 0, 0.4), .easeOut)
            layers.append(c.place(k, at: (cx, cy - h / 2 - c.px(10)), opacity: a * (1 - leave)))
        }
        return MotionCanvas.stack(layers)
    }
}
