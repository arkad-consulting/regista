import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// An "editing machine": a hopper on top, the clip in a preview window, gears spinning, status rows lighting up and
/// a conveyor carrying output cards that get a check; a big two-colour title.
enum Machine: MotionTemplate {
    static let spec = MotionSpec(
        id: "machine", label: "Macchina", symbol: "gearshape.2",
        guide: CatalogGuide("A playful console machine on the grid backdrop: a big two-colour title on top (\"EDITING *MACHINE*\"), a hopper feeding a dark glowing cabinet that shows the clip in a PREVIEW window, three gears spinning in the accent tones, status rows (CUT / MOTION / SOUND) lighting up one after the other, and at the bottom a conveyor belt with bolts carrying small output cards that each get a green check.",
                            useWhen: "Explaining an automated process end to end (\"you put the raw take in, the machine cuts, adds motion and sound\") in a behind-the-scenes, a product pitch or a tutorial intro; 3–5 s.",
                            avoid: "Serious or premium brands that avoid playful metaphors, short beats (it needs time to read), reels where the process is not the topic."),
        fields: [
            .init("title", "text", "EDITING *MACHINE*", "Title (*starred* words in the accent colour)."),
            .init("rows", "list", ["Cut", "Motion", "Sound"], "Status rows (2–4)."),
            .init("label", "text", "PRODUCTION LINE", "Small label under the belt."),
        ],
        form: ["title", "rows", "label"], duration: 4.5, band: nil, consumesBelow: true, coversFrame: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let shot = c.below ?? CIImage(color: c.ci("ink")).cropped(to: c.canvas)
        let env = Anim.envelope(c.t, c.d, in: 0.35, out: 0.3)
        let accent = c.cg("accent")
        var layers: [CIImage] = []
        let stage = BackgroundScene.draw(MotionCanvas(m: MotionLayer(template: "background-scene", fields: ["style": "dark-grid", "color": .string(m.style.color("accent"))], style: m.style),
                                                      t: 1, d: 10, part: .whole, W: c.W, H: c.H, store: c.store, below: nil)) ?? .empty()
        layers.append(stage)
        // Title.
        let runs = KickerHeadline.runs(m.string("title", "EDITING *MACHINE*"))
        let f = c.font("textBold", 96)
        let tw = runs.reduce(0) { $0 + Draw.width($1.text, f, tracking: -c.px(2)) }
        let scale = min(1, (c.W - c.px(80)) / max(tw, 1))
        let tf = c.font("textBold", 96 * scale)
        let title = c.sprite("mach-title|\(runs.map { "\($0.accent)\($0.text)" })", c.W, c.px(130)) { ctx in
            var x = (c.W - tw * scale) / 2
            for r in runs { x += Draw.text(ctx, r.text, tf, r.accent ? accent : TitleRasterizer.color("#FFFFFF"), x: x, baseline: c.px(100), tracking: -c.px(2) * scale) }
        }
        layers.append(c.place(title, at: (c.W / 2, c.H * 230 / 1920), opacity: Anim.p(c.t, 0.1, 0.4)))
        // Cabinet.
        let cab = CGRect(x: c.px(70), y: c.H * 470 / 1920, width: c.W - c.px(140), height: c.px(720))
        let rows = Array(m.strings("rows").prefix(4))
        let per = max(c.d - 1.4, 1) / Double(max(rows.count, 1))
        let lit = rows.indices.map { c.t >= 0.6 + per * Double($0) }
        let cabinet = c.sprite("mach-cab|\(rows)|\(lit)", cab.width + c.px(80), cab.height + c.px(200)) { ctx in
            let r = CGRect(x: c.px(40), y: c.px(160), width: cab.width, height: cab.height)
            // Hopper.
            let hop = CGMutablePath()
            hop.move(to: CGPoint(x: r.midX - c.px(110), y: c.px(60))); hop.addLine(to: CGPoint(x: r.midX + c.px(110), y: c.px(60)))
            hop.addLine(to: CGPoint(x: r.midX + c.px(55), y: r.minY)); hop.addLine(to: CGPoint(x: r.midX - c.px(55), y: r.minY)); hop.closeSubpath()
            ctx.addPath(hop); ctx.setFillColor(accent); ctx.fillPath()
            Draw.console(ctx, r, radius: c.px(30), accent: accent, glow: c.px(24))
            // Gear panel and status rows on the right.
            let right = CGRect(x: r.minX + r.width * 0.53, y: r.minY + c.px(28), width: r.width * 0.47 - c.px(28), height: r.height - c.px(56))
            Draw.roundedRect(ctx, CGRect(x: right.minX, y: right.minY, width: right.width, height: right.height * 0.52), radius: c.px(18), fill: TitleRasterizer.color("#000000", alpha: 0.35),
                             stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.08), lineWidth: 1)
            for (i, row) in rows.enumerated() {
                let rh = (right.height * 0.48 - c.px(16)) / Double(max(rows.count, 1))
                let b = CGRect(x: right.minX, y: right.minY + right.height * 0.52 + c.px(16) + Double(i) * rh, width: right.width, height: rh - c.px(12))
                Draw.roundedRect(ctx, b, radius: c.px(14), fill: TitleRasterizer.color("#FFFFFF", alpha: lit[i] ? 0.07 : 0.03), stroke: lit[i] ? accent : TitleRasterizer.color("#FFFFFF", alpha: 0.1), lineWidth: c.px(1.5))
                ctx.setFillColor(lit[i] ? TitleRasterizer.color("#2BD48A") : TitleRasterizer.color("#FFFFFF", alpha: 0.2))
                ctx.fillEllipse(in: CGRect(x: b.minX + c.px(18), y: b.midY - c.px(9), width: c.px(18), height: c.px(18)))
                Draw.text(ctx, row.uppercased(), c.font("mono", 26), c.cg("#FFFFFF", lit[i] ? 0.95 : 0.5), x: b.minX + c.px(52), centreY: b.midY, tracking: c.px(3))
            }
        }
        layers.append(c.place(cabinet, at: (cab.midX, cab.minY - c.px(160) + (cab.height + c.px(200)) / 2), opacity: Anim.p(c.t, 0, 0.35)))
        // Preview window with the clip.
        let win = CGRect(x: cab.minX + c.px(28), y: cab.minY + c.px(28), width: cab.width * 0.53 - c.px(48), height: cab.height - c.px(56))
        var clip = Inset.picture(shot, canvas: c.canvas, into: win, radius: c.px(18), height: c.H)
        let ring = c.sprite("mach-ring|\(Int(win.width))", win.width + c.px(20), win.height + c.px(20)) { ctx in
            Draw.roundedRect(ctx, CGRect(x: c.px(10), y: c.px(10), width: win.width, height: win.height), radius: c.px(18), fill: nil, stroke: accent, lineWidth: c.px(4))
        }
        clip = c.place(ring, at: (win.midX, win.midY)).composited(over: clip)
        layers.append(MotionCanvas.fade(clip, Anim.p(c.t, 0.15, 0.3)))
        // Gears.
        let gearArea = CGRect(x: cab.minX + cab.width * 0.53, y: cab.minY + c.px(28), width: cab.width * 0.47 - c.px(28), height: (cab.height - c.px(56)) * 0.52)
        for (k, g) in [(0.42, 0.52, 150.0, 12, 1.0), (0.78, 0.28, 70.0, 8, -2.1), (0.76, 0.76, 85.0, 9, -1.8)].enumerated() {
            let d = c.px(g.2 * 2)
            let gear = c.sprite("gear|\(k)|\(Int(d))", d + 4, d + 4) { ctx in drawGear(ctx, centre: CGPoint(x: d / 2 + 2, y: d / 2 + 2), radius: d / 2, teeth: g.3, color: k == 1 ? accent : c.cg(k == 0 ? "accent" : "#F2C79A")) }
            layers.append(c.place(gear, at: (gearArea.minX + gearArea.width * g.0, gearArea.minY + gearArea.height * g.1), rotation: c.t * 60 * g.4, opacity: Anim.p(c.t, 0.2, 0.3)))
        }
        // Conveyor with bolts and output cards.
        let beltY = cab.maxY + c.px(110)
        let shift = (c.t * c.px(120)).truncatingRemainder(dividingBy: c.px(90))
        let belt = c.sprite("belt|\(Int(shift))|\(m.string("label"))", c.W, c.px(110)) { ctx in
            ctx.setFillColor(TitleRasterizer.color("#2A1E15")); ctx.fill(CGRect(x: 0, y: c.px(10), width: c.W, height: c.px(46)))
            ctx.setFillColor(accent.copy(alpha: 0.9) ?? accent); ctx.fill(CGRect(x: 0, y: c.px(8), width: c.W, height: c.px(3))); ctx.fill(CGRect(x: 0, y: c.px(55), width: c.W, height: c.px(3)))
            var x = -c.px(90) + shift
            while x < c.W + c.px(90) {
                ctx.setFillColor(accent); ctx.fillEllipse(in: CGRect(x: x, y: c.px(21), width: c.px(24), height: c.px(24)))
                ctx.setFillColor(TitleRasterizer.color("#2A1E15")); ctx.fill(CGRect(x: x + c.px(4), y: c.px(31), width: c.px(16), height: c.px(4)))
                x += c.px(90)
            }
            Draw.text(ctx, m.string("label").uppercased(), c.font("mono", 22), c.cg("accent"), x: c.px(70), centreY: c.px(90), tracking: c.px(4))
        }
        layers.append(c.place(belt, at: (c.W / 2, beltY + c.px(25)), opacity: Anim.p(c.t, 0.2, 0.3)))
        for k in 0..<4 {
            let start = 1.0 + 0.6 * Double(k)
            guard c.t > start else { continue }
            let x = -c.px(80) + (c.t - start) * c.px(260)
            let card = c.sprite("out|\(k)|\(x > c.W * 0.45)", c.px(120), c.px(150)) { ctx in
                Draw.roundedRect(ctx, CGRect(x: c.px(10), y: c.px(10), width: c.px(100), height: c.px(130)), radius: c.px(12), fill: TitleRasterizer.color("#F6F0E2"))
                Draw.roundedRect(ctx, CGRect(x: c.px(22), y: c.px(24), width: c.px(76), height: c.px(56)), radius: c.px(6), fill: c.cg(["accent", "primary", "ink", "success"][k % 4], 0.8))
                if x > c.W * 0.45 {
                    ctx.setFillColor(TitleRasterizer.color("#2BD48A")); ctx.fillEllipse(in: CGRect(x: c.px(70), y: c.px(96), width: c.px(32), height: c.px(32)))
                    Draw.check(ctx, in: CGRect(x: c.px(70), y: c.px(96), width: c.px(32), height: c.px(32)), color: TitleRasterizer.color("#0E1A12"), width: c.px(3.5))
                }
            }
            layers.append(c.place(card, at: (x, beltY - c.px(52))))
        }
        return MotionCanvas.fade(MotionCanvas.stack(layers), env).composited(over: shot)
    }

    static func drawGear(_ ctx: CGContext, centre p: CGPoint, radius r: Double, teeth n: Int, color: CGColor) {
        let path = CGMutablePath()
        let inner = r * 0.8
        for i in 0..<(n * 4) {
            let a = Double(i) / Double(n * 4) * 2 * .pi
            let rr = (i % 4 == 1 || i % 4 == 2) ? r : inner
            let pt = CGPoint(x: p.x + rr * cos(a), y: p.y + rr * sin(a))
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: p.x - r * 0.28, y: p.y - r * 0.28, width: r * 0.56, height: r * 0.56))
        ctx.addPath(path); ctx.setFillColor(color); ctx.fillPath(using: .evenOdd)
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        for k in 0..<5 {
            let a = Double(k) / 5 * 2 * .pi
            ctx.fillEllipse(in: CGRect(x: p.x + r * 0.52 * cos(a) - r * 0.09, y: p.y + r * 0.52 * sin(a) - r * 0.09, width: r * 0.18, height: r * 0.18))
        }
    }
}
