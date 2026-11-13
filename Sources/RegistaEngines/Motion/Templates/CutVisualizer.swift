import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// The raw take as a waveform strip: the parts the edit removed flash red with a cross and collapse, the kept parts
/// slide together; a counter goes from the raw to the final duration. Driven by the project's real cuts.
enum CutVisualizer: MotionTemplate {
    static let spec = MotionSpec(
        id: "cut-visualizer", label: "Tagli", symbol: "scissors",
        guide: CatalogGuide("A dark console strip showing the raw take as a waveform of segments: the parts the edit removed turn red with a ✕, then collapse while the kept parts slide together, and a big counter rolls from the raw length to the final one (1:42 → 0:57). By default it reads the project's real cuts: the kept ranges of the main take and the raw and final durations.",
                            useWhen: "Explaining or showing off the cut (\"it removed every pause and mistake\"), in a behind-the-scenes or before/after reel, once the cut is final.",
                            avoid: "Before the edit is cut (no ranges: it shows an example), multi-camera edits from many files (it reads the main take), as decoration on reels that are not about editing."),
        fields: [
            .init("kept", "numbers", [0, 0.12, 0.18, 0.4, 0.47, 0.62, 0.7, 0.92], "Kept ranges of the raw take as from, to pairs (fractions); default: the real cuts."),
            .init("raw", "text", "1:42", "Raw duration (default: the real one)."),
            .init("final", "text", "0:57", "Final duration (default: the real one)."),
            .init("label", "text", "RAW TAKE", "Small label above the strip."),
        ],
        form: ["label"], duration: 4, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let flat = m.numbers("kept")
        var kept: [(Double, Double)] = stride(from: 0, to: flat.count - 1, by: 2).map { (flat[$0], flat[$0 + 1]) }.filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        if kept.isEmpty { kept = [(0, 1)] }
        // Removed ranges = gaps.
        var removed: [(Double, Double)] = []
        var cursor = 0.0
        for k in kept { if k.0 > cursor + 0.002 { removed.append((cursor, k.0)) }; cursor = max(cursor, k.1) }
        if cursor < 0.998 { removed.append((cursor, 1)) }
        let flash = Anim.p(c.t, 0.5, 0.5), collapse = Anim.ease(Anim.p(c.t, 1.2, 1.0), .easeInOut)
        let keptTotal = kept.reduce(0) { $0 + $1.1 - $1.0 }
        let w = c.px(940), h = c.px(330), pad = c.px(50)
        let strip = CGRect(x: pad + c.px(24), y: pad + c.px(190), width: w - c.px(48), height: c.px(110))
        // Where each kept segment sits: from its raw place towards a packed layout (centred).
        let packedStart = (1 - keptTotal) / 2
        var segs: [(x: Double, w: Double, kept: Bool, raw: Double)] = []
        var packed = packedStart
        for k in kept {
            let x = k.0 + (packed - k.0) * collapse
            segs.append((x, k.1 - k.0, true, k.0))
            packed += k.1 - k.0
        }
        for r in removed { segs.append((r.0, (r.1 - r.0) * (1 - collapse), false, r.0)) }
        let raw = m.string("raw", "1:42"), fin = m.string("final", "0:57")
        func seconds(_ s: String) -> Double { let p = s.split(separator: ":").compactMap { Double($0) }; return p.count == 2 ? p[0] * 60 + p[1] : (p.first ?? 0) }
        let now = seconds(raw) + (seconds(fin) - seconds(raw)) * collapse
        let shown = MotionData.clock(now)
        let q = Int((collapse * 60).rounded()), fq = Int((flash * 10).rounded())
        let panel = c.sprite("cuts|\(flat)|\(raw)|\(fin)|\(q)|\(fq)|\(m.string("label"))", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.console(ctx, r, radius: c.px(24), accent: c.cg("accent"), glow: c.px(20))
            Draw.text(ctx, m.string("label").uppercased(), c.font("mono", 22), c.cg("#FFFFFF", 0.6), x: r.minX + c.px(28), centreY: r.minY + c.px(40), tracking: c.px(4))
            Draw.text(ctx, shown, c.font("textBold", 96), TitleRasterizer.color("#FFFFFF"), x: r.maxX - c.px(28), centreY: r.minY + c.px(110), align: 1)
            Draw.text(ctx, "\(raw) → \(fin)", c.font("mono", 20), c.cg("accent"), x: r.minX + c.px(28), centreY: r.minY + c.px(120), tracking: c.px(2))
            var rng = SeededRandom(seed: 0xC07)
            let bars = (0..<200).map { _ in 0.25 + 0.75 * rng.next() }
            for s in segs where s.w > 0.0005 {
                let rect = CGRect(x: strip.minX + strip.width * s.x, y: strip.minY, width: max(strip.width * s.w - c.px(3), 1), height: strip.height)
                let red = !s.kept && flash > 0
                Draw.roundedRect(ctx, rect, radius: c.px(6), fill: s.kept ? c.cg("accent", 0.9) : TitleRasterizer.color(red ? "#E5484D" : "#5A4A40", alpha: red ? 0.85 : 0.6))
                // Waveform inside the segment, from its raw position (so the shape travels with it).
                var x = rect.minX + c.px(4)
                while x < rect.maxX - c.px(4) {
                    let f = s.raw + (x - rect.minX) / strip.width
                    let a = bars[min(Int(f * 199), 199)]
                    ctx.setFillColor(TitleRasterizer.color("#1A0F08", alpha: 0.55)); ctx.fill(CGRect(x: x, y: rect.midY - rect.height * 0.35 * a, width: c.px(2.5), height: rect.height * 0.7 * a))
                    x += c.px(6)
                }
                if red && rect.width > c.px(30) {
                    Draw.text(ctx, "✕", c.font("textBold", 34), TitleRasterizer.color("#FFFFFF"), x: rect.midX, centreY: rect.midY, align: 0.5)
                }
            }
        }
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        return c.place(panel, at: (cx, cy + c.px(24) * (1 - pop)), scale: 0.95 + 0.05 * pop, opacity: min(pop * 1.5, 1) * (1 - leave))
    }
}
