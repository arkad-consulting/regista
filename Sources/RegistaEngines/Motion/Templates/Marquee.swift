import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// One or two rows of numbered pills scrolling endlessly in opposite directions; each row goes behind or in front of
/// the speaker.
enum Marquee: MotionTemplate {
    static let spec = MotionSpec(
        id: "marquee", label: "Scorrimento", symbol: "text.line.first.and.arrowtriangle.forward",
        guide: CatalogGuide("One or two horizontal rows of rounded pills, each with a small number (01, 02…) and a bold capitalised word, scrolling endlessly in opposite directions across the frame. Typically the upper row is dark and passes behind the speaker's head, the lower row is light and passes in front of the chest.",
                            useWhen: "A list of many features, services or topics said quickly (\"subtitles, zoom, sound, rhythm, logo…\") where a checklist would be too long; an energetic \"everything included\" beat. 5–12 short words.",
                            avoid: "Fewer than 4 items (use a checklist), long phrases, calm premium edits, rows crossing the face or the caption band; the behind row needs matte.track."),
        fields: [
            .init("items", "list", ["Subtitles", "Zoom", "Sound", "Rhythm", "Logo", "Colour"], "Words of the first row (4–12)."),
            .init("items2", "list", ["Motion", "Grading", "Captions", "Transitions", "Music"], "Words of the second row (empty = one row)."),
            .init("y1", "number", 820, "First row centre, y on a 1080×1920 frame (forehead height: it passes behind the head)."),
            .init("y2", "number", 1170, "Second row centre, y (chest/chin height, above the caption band)."),
            .init("behind1", "boolean", true, "First row passes behind the speaker."),
            .init("behind2", "boolean", false, "Second row passes behind the speaker."),
            .init("theme1", "choice", "dark", "First row pills.", choices: ["dark", "light", "accent"]),
            .init("theme2", "choice", "light", "Second row pills.", choices: ["dark", "light", "accent"]),
            .init("speed", "number", 110, "Scroll speed, px per second."),
        ],
        form: ["items", "items2", "y1", "y2"], duration: 4, band: nil, layering: .split, scrolls: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        var rows: [(items: [String], y: Double, behind: Bool, theme: String, dir: Double)] = []
        let a = m.strings("items"), b = m.strings("items2")
        if !a.isEmpty { rows.append((a, m.number("y1", 820), m.bool("behind1", true), m.string("theme1", "dark"), -1)) }
        if !b.isEmpty { rows.append((b, m.number("y2", 1170), m.bool("behind2", false), m.string("theme2", "light"), 1)) }
        let env = Anim.envelope(c.t, c.d, in: 0.4, out: 0.3)
        var layers: [CIImage] = []
        for (r, row) in rows.enumerated() {
            if c.part == .back && !row.behind { continue }
            if c.part == .front && row.behind { continue }
            let pills = row.items.enumerated().map { pill(c, String(format: "%02d", $0.offset + 1), $0.element, theme: row.theme) }
            let gap = c.px(18)
            let period = pills.reduce(0) { $0 + $1.extent.width - c.px(40) + gap }
            guard period > 1 else { continue }
            let slide = c.px(m.number("speed", 110)) * c.t + c.px(60) * (1 - Anim.ease(Anim.p(c.t, 0, 0.5), .expoOut))
            var x = (row.dir < 0 ? -slide : slide - period).truncatingRemainder(dividingBy: period)
            if x > 0 { x -= period }
            let y = row.y / SafeZones.referenceHeight * c.H
            var k = 0
            while x < c.W + period {
                let p = pills[k % pills.count]
                let w = p.extent.width - c.px(40)
                layers.append(c.place(p, at: (x + w / 2, y), rotation: r == 0 ? -1.2 : 0.8, opacity: env))
                x += w + gap
                k += 1
                if k > 200 { break }
            }
        }
        return MotionCanvas.stack(layers)
    }

    static func pill(_ c: MotionCanvas, _ number: String, _ label: String, theme: String) -> CIImage {
        let f = c.font("textBold", 40), nf = c.font("mono", 17)
        let tw = Draw.width(label.uppercased(), f, tracking: -c.px(0.5))
        let h = c.px(92), w = tw + c.px(52), pad = c.px(20)
        return c.sprite("pill|\(number)|\(label)|\(theme)", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            let fill: CGColor, text: CGColor, num: CGColor
            switch theme {
            case "light": (fill, text, num) = (TitleRasterizer.color("#FFFFFF"), TitleRasterizer.color("#111111"), c.cg("accent"))
            case "accent": (fill, text, num) = (c.cg("accent"), TitleRasterizer.color("#FFFFFF"), TitleRasterizer.color("#FFFFFF", alpha: 0.75))
            default: (fill, text, num) = (TitleRasterizer.color("#121212"), TitleRasterizer.color("#FFFFFF"), c.cg("highlight"))
            }
            Draw.card(ctx, r, radius: c.px(16), fill: fill, shadow: 0.25, blur: c.px(18), dy: c.px(6),
                      stroke: theme == "light" ? TitleRasterizer.color("#000000", alpha: 0.12) : nil)
            Draw.text(ctx, number, nf, num, x: r.minX + c.px(22), baseline: r.minY + c.px(26))
            Draw.text(ctx, label.uppercased(), f, text, x: r.minX + c.px(24), baseline: r.maxY - c.px(18), tracking: -c.px(0.5))
        }
    }
}
