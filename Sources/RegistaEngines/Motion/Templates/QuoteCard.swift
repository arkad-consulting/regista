import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A quote as proof: a paper (or ink) card in the top band with a large accent quotation mark, the words in a serif
/// italic revealed line by line, a short accent rule and who said it in mono capitals.
enum QuoteCard: MotionTemplate {
    static let spec = MotionSpec(
        id: "quote-card", label: "Citazione", symbol: "quote.opening",
        guide: CatalogGuide("A calm rounded card in the top band (the kit's paper colour with ink text, or ink with paper text): a large quotation mark in the accent colour, the quote in a serif italic over two or three lines that rise in one after the other, then a short accent rule and the source in small spaced mono capitals (\"— A CUSTOMER, MARCH 2026\"). It pops in with a tame spring and leaves with a short fade.",
                            useWhen: "The proof beat of a point is something a real person or document said: a customer's words, a review, a line of a report or of the press, the speaker's own earlier post. Land it on the words that introduce it and keep it while the idea is said, 3–4 s, one per point.",
                            avoid: "Invented or paraphrased quotes presented as real, more than ~22 words, a quote that repeats the caption at the same moment, two quotes in a row (alternate with the face), or a number (use stat-card or counter)."),
        fields: [
            .init("quote", "text", "We cut the editing time of every reel in half.", "The words, as they were said or written (up to ~22 words)."),
            .init("source", "text", "A customer, March 2026", "Who said it and when (\"\" = none)."),
            .init("theme", "choice", "light", "Card style: light = paper with ink text, dark = ink with paper text.", choices: ["light", "dark"]),
            .init("accent", "color", "accent", "Quotation mark and rule colour."),
        ],
        form: ["quote", "source", "theme"], duration: 3.5, band: "top")

    /// The words in lines no wider than `width` (greedy; a word longer than the line gets a line of its own).
    static func wrap(_ text: String, width: Double, measure: (String) -> Double) -> [String] {
        var lines: [String] = [], line = ""
        for word in text.split(whereSeparator: \.isWhitespace).map(String.init) {
            let candidate = line.isEmpty ? word : line + " " + word
            if line.isEmpty || measure(candidate) <= width { line = candidate } else { lines.append(line); line = word }
        }
        if !line.isEmpty { lines.append(line) }
        return lines
    }

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let quote = m.string("quote").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !quote.isEmpty else { return nil }
        let source = m.string("source").trimmingCharacters(in: .whitespacesAndNewlines)
        let dark = m.string("theme", "light") == "dark"
        let surface = c.cg(dark ? "ink" : "paper"), ink = c.cg(dark ? "paper" : "ink"), accent = c.cg(m.color("accent", "accent"))
        let widest = c.px(780), inset = c.px(56), pad = c.px(40)
        // The quote shrinks a step at a time until it fits in three lines.
        var size = 46.0, lines: [String] = []
        repeat {
            let f = c.font("serif", size)
            lines = wrap(quote, width: widest - 2 * inset) { Draw.width($0, f) }
            if lines.count <= 3 { break }
            size -= 4
        } while size >= 30
        let serif = c.font("serif", size), mono = c.font("mono", 18)
        let sourceText = source.isEmpty ? "" : "— " + source.uppercased()
        // The card is as wide as its longest line (or the source), between 560 and 780 reference pixels.
        let content = max(lines.map { Draw.width($0, serif) }.max() ?? 0, Draw.width(sourceText, mono, tracking: c.px(3)))
        let w = min(max(content + 2 * inset + c.px(12), c.px(560)), widest)
        let lh = c.px(size * 1.3)
        let top = c.px(116), h = top + lh * Double(lines.count) + (source.isEmpty ? c.px(36) : c.px(96))
        let (cx, cy) = c.centre
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let fade = 1 - leave
        let card = c.sprite("quote-card|\(dark)", w + 2 * pad, h + 2 * pad) { ctx in
            Draw.card(ctx, CGRect(x: pad, y: pad, width: w, height: h), radius: c.px(26), fill: surface, shadow: 0.28, blur: c.px(30), dy: c.px(12),
                      stroke: dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.1) : TitleRasterizer.color("#000000", alpha: 0.06))
        }
        let cardTop = cy - h / 2 + c.px(18) * (1 - pop)
        var layers = [c.place(card, at: (cx, cy + c.px(18) * (1 - pop)), scale: 0.94 + 0.06 * pop, opacity: min(pop * 1.5, 1) * fade)]
        // The quotation mark lands first, a little bigger than its rest size.
        let markFont = c.font("serif", 120)
        let mark = c.sprite("quote-mark|\(m.color("accent", "accent"))", c.px(90), c.px(110)) { ctx in
            Draw.text(ctx, "\u{201C}", markFont, accent, x: c.px(4), baseline: c.px(100))
        }
        let markIn = Anim.spring(c.t, 0.1, length: 0.4)
        layers.append(c.place(mark, at: (cx - w / 2 + inset + c.px(30), cardTop + c.px(90)), scale: 1.25 - 0.25 * markIn, opacity: min(markIn * 1.5, 1) * fade))
        // Then the lines, one after the other, rising a few pixels.
        for (i, line) in lines.enumerated() {
            let s = c.sprite("quote-line|\(line)|\(size)|\(dark)", w - 2 * inset + c.px(20), lh + c.px(16)) { ctx in
                Draw.text(ctx, line, serif, ink, x: 0, baseline: lh * 0.78)
            }
            let a = Anim.ease(Anim.p(c.t, 0.3 + 0.16 * Double(i), 0.4), .expoOut)
            let y = cardTop + top + lh * (Double(i) + 0.5) + c.px(12) * (1 - a)
            layers.append(c.place(s, at: (cx + c.px(10), y), opacity: a * fade))
        }
        if !source.isEmpty {
            let text = sourceText
            let sw = Draw.width(text, mono, tracking: c.px(3))
            let s = c.sprite("quote-source|\(text)|\(dark)|\(m.color("accent", "accent"))", max(sw, c.px(60)) + c.px(8), c.px(56)) { ctx in
                ctx.setFillColor(accent)
                ctx.fill(CGRect(x: 0, y: 0, width: c.px(48), height: max(c.px(3), 1)))
                Draw.text(ctx, text, mono, ink.copy(alpha: 0.7) ?? ink, x: 0, baseline: c.px(40), tracking: c.px(3))
            }
            let a = Anim.ease(Anim.p(c.t, 0.35 + 0.16 * Double(lines.count), 0.4), .easeOut)
            let width = s.extent.width
            layers.append(c.place(s, at: (cx - w / 2 + inset + width / 2, cardTop + top + lh * Double(lines.count) + c.px(40)), opacity: a * fade))
        }
        return MotionCanvas.stack(layers)
    }
}
