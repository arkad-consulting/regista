import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A big number or clock that counts up (or ticks) to its value, with an optional SF Symbol beside it and the shot
/// dimmed under it.
enum Counter: MotionTemplate {
    static let spec = MotionSpec(
        id: "counter", label: "Contatore", symbol: "timer",
        guide: CatalogGuide("A huge bold number or clock in the top band (white with a soft shadow) that rolls up to its value — 0 → 8,000+, or a clock ticking from 23:00 to 23:46 — with an optional SF Symbol beside it (a moon, a bolt, a clock) and the shot gently darkened so the number reads. Fixed-width digits, so it never wobbles while counting.",
                            useWhen: "The line hinges on one number or time: a deadline, a price, a result (\"at 23:46 I was still editing\", \"8,000 members\", \"+212 %\"). One per reel, on the word that says the number.",
                            avoid: "Numbers that are not real or not said, several numbers at once (use a chart or a stat card), long decimals, or when the top band already carries a title."),
        fields: [
            .init("value", "text", "23:46", "Final value: a clock (\"23:46\"), a number (\"8000\", \"212\", \"4.9\")."),
            .init("from", "text", "", "Start value (default: 0, or one hour before for a clock)."),
            .init("prefix", "text", "", "Text before the number (\"€\", \"+\")."),
            .init("suffix", "text", "", "Text after the number (\"%\", \"+\", \" k\")."),
            .init("icon", "symbol", "moon.fill", "SF Symbol shown left of the number (\"\" = none): moon.fill, clock.fill, bolt.fill, flame.fill, star.fill…"),
            .init("iconColor", "color", "paper", "Icon colour (#RRGGBB or brand role)."),
            .init("color", "color", "#FFFFFF", "Number colour."),
            .init("size", "number", 190, "Number height, px at 1080 wide."),
            .init("font", "text", "textBold", "Font role (display, text, textBold, mono) or a font name."),
            .init("label", "text", "", "Small spaced label under the number (\"MEMBERS\")."),
            .init("dim", "number", 0.35, "How much the shot under it is darkened (0 = not at all, 0.6 = strongly)."),
            .init("countDuration", "number", 1.3, "Seconds the count takes."),
            .init("separator", "text", ",", "Thousands separator as the captions write it: \",\" English (8,000), \".\" Italian/Portuguese (11.000), \" \" French (11 000); the decimal mark is \".\" after \",\" and \",\" otherwise."),
        ],
        form: ["value", "from", "icon", "dim"], duration: 3, band: "top", coversFrame: true)

    /// "23:46" → minutes; "8,000" → 8000. (value, isClock, decimals)
    static func parse(_ s: String) -> (Double, Bool, Int)? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.contains(":") {
            let p = t.split(separator: ":").compactMap { Double($0) }
            guard p.count == 2 else { return nil }
            return (p[0] * 60 + p[1], true, 0)
        }
        let clean = t.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
        guard let v = Double(clean) else { return nil }
        let decimals = clean.split(separator: ".").dropFirst().first?.count ?? 0
        return (v, false, decimals)
    }

    static func format(_ v: Double, clock: Bool, decimals: Int, separator: String = ",") -> String {
        if clock {
            let m = Int(v.rounded(.down)) % (24 * 60)
            return String(format: "%02d:%02d", m / 60, m % 60)
        }
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        f.groupingSeparator = separator
        f.decimalSeparator = separator == "," ? "." : ","
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        guard let (target, clock, decimals) = parse(m.string("value", "23:46")) else { return nil }
        let start = parse(m.string("from")).map(\.0) ?? (clock ? target - 46 : 0)
        let dur = max(m.number("countDuration", 1.3), 0.05)
        let p = Anim.ease(Anim.p(c.t, 0.15, dur), .easeOut)
        let value = start + (target - start) * p
        let text = m.string("prefix") + format(clock ? value.rounded(.down) : (decimals == 0 ? value.rounded() : value), clock: clock, decimals: decimals, separator: m.string("separator", ",")) + m.string("suffix")
        let size = m.number("size", 190)
        let font = c.font(m.string("font", "textBold"), size)
        let color = m.color("color", "#FFFFFF")
        // Fixed slots: every digit takes the width of the widest one.
        let digit = (0...9).map { Draw.width(String($0), font) }.max() ?? c.px(size * 0.6)
        func slot(_ ch: Character) -> Double { ch.isNumber ? digit : Draw.width(String(ch), font) }
        let tw = text.reduce(0) { $0 + slot($1) }
        let icon = m.string("icon")
        let iconSize = c.px(size * 0.62), gap = icon.isEmpty ? 0 : c.px(size * 0.22)
        let pad = c.px(60)
        let total = tw + (icon.isEmpty ? 0 : iconSize + gap)
        let hgt = c.px(size * 1.25)
        let sprite = c.sprite("n|\(text)|\(color)|\(size)|\(icon)|\(m.string("font"))", total + 2 * pad, hgt + 2 * pad) { ctx in
            // A shadow offset ignores the flipped context: negative falls below.
            ctx.setShadow(offset: CGSize(width: 0, height: -c.px(8)), blur: c.px(30), color: CGColor(gray: 0, alpha: 0.35))
            var x = pad
            if !icon.isEmpty {
                Draw.symbol(ctx, icon, in: CGRect(x: x, y: pad + (hgt - iconSize) / 2, width: iconSize, height: iconSize), color: TitleRasterizer.color(m.color("iconColor", "paper")))
                x += iconSize + gap
            }
            for ch in text {
                let w = slot(ch)
                Draw.text(ctx, String(ch), font, TitleRasterizer.color(color), x: x + w / 2, centreY: pad + hgt / 2, align: 0.5)
                x += w
            }
        }
        let env = Anim.envelope(c.t, c.d, in: 0.3, out: 0.3)
        let pop = Anim.spring(c.t, 0, length: 0.5)
        let (cx, cy) = c.centre
        var layers = [c.dim(m.number("dim", 0.35) * env)]
        layers.append(c.place(sprite, at: (cx, cy), scale: 0.9 + 0.1 * pop, opacity: env))
        let label = m.string("label")
        if !label.isEmpty {
            let f = c.font("mono", 30)
            let lw = Draw.width(label.uppercased(), f, tracking: c.px(6)) + c.px(20)
            let ls = c.sprite("label|\(label)", lw, c.px(50)) { ctx in
                Draw.text(ctx, label.uppercased(), f, TitleRasterizer.color(color, alpha: 0.85), x: lw / 2, centreY: c.px(25), align: 0.5, tracking: c.px(6))
            }
            layers.append(c.place(ls, at: (cx, cy + hgt / 2 + c.px(10)), opacity: env * Anim.p(c.t, 0.3, 0.3)))
        }
        return MotionCanvas.stack(layers)
    }
}
