import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A "new message" console window: a header with generic icons and a status dot, a message typing itself, the real
/// clip attached as a video card with its duration, and a footer status ("analysing…") with a send button.
enum ChatWindow: MotionTemplate {
    static let spec = MotionSpec(
        id: "chat-window", label: "Messaggio", symbol: "bubble.left.and.text.bubble.right",
        guide: CatalogGuide("A dark console window (glowing accent border) on the grid backdrop: a header \"NEW MESSAGE\" with two generic tool icons and a green \"AI\" status dot, a message typing itself in mono with a caret, the real clip attached as a rounded video card (still playing, a RAW tag) next to a RAW VIDEO chip and a big DURATION read-out, and a footer that reads \"analysing…\" with an accent send button.",
                            useWhen: "The moment the speaker hands the footage to an AI or a tool (\"I just send it the raw take\"), in behind-the-scenes or tutorial reels about the editing workflow. 2–4 s.",
                            avoid: "Third-party assistant names or logos (keep the generic icons), long messages, reels that are not about the process."),
        fields: [
            .init("header", "text", "NEW MESSAGE", "Header title."),
            .init("message", "text", "edit this video for me", "The message that types itself."),
            .init("attachment", "text", "RAW VIDEO", "Chip over the attachment (default: the clip's file name)."),
            .init("attachmentLength", "text", "1:42", "Duration shown (default: the raw take's length)."),
            .init("status", "text", "ANALYSING THE RAW TAKE", "Footer text."),
        ],
        form: ["message", "status"], duration: 3.5, band: nil, consumesBelow: true, coversFrame: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let shot = c.below ?? CIImage(color: c.ci("ink")).cropped(to: c.canvas)
        let env = Anim.envelope(c.t, c.d, in: 0.35, out: 0.3)
        let stage = BackgroundScene.draw(MotionCanvas(m: MotionLayer(template: "background-scene", fields: ["style": "dark-grid", "color": .string(m.style.color("accent"))], style: m.style),
                                                      t: 1, d: 10, part: .whole, W: c.W, H: c.H, store: c.store, below: nil)) ?? .empty()
        let w = c.px(900), h = c.px(1080), pad = c.px(40)
        let x0 = (c.W - w) / 2, y0 = c.H * 0.47 - h / 2
        let msg = m.string("message")
        let typed = String(msg.prefix(Int(max(c.t - 0.4, 0) * 18)))
        let caret = typed.count < msg.count || Int(c.t * 2.2) % 2 == 0
        let dots = String(repeating: ".", count: Int(c.t * 3) % 4)
        let accent = c.cg("accent")
        let attach = m.string("attachment")
        let window = c.sprite("chat|\(typed)|\(caret)|\(dots)|\(attach)|\(m.string("attachmentLength"))|\(m.string("header"))", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.console(ctx, r, radius: c.px(30), accent: accent, glow: c.px(24))
            for (i, sym) in ["sparkle", "wand.and.stars"].enumerated() {
                let b = CGRect(x: r.minX + c.px(24) + Double(i) * c.px(56), y: r.minY + c.px(22), width: c.px(46), height: c.px(46))
                Draw.roundedRect(ctx, b, radius: c.px(10), fill: TitleRasterizer.color("#FFFFFF", alpha: 0.92))
                Draw.symbol(ctx, sym, in: b.insetBy(dx: c.px(11), dy: c.px(11)), color: accent)
            }
            Draw.text(ctx, m.string("header").uppercased(), c.font("mono", 24), c.cg("#FFFFFF", 0.8), x: r.minX + c.px(150), centreY: r.minY + c.px(45), tracking: c.px(4))
            ctx.setFillColor(TitleRasterizer.color("#2BD48A")); ctx.fillEllipse(in: CGRect(x: r.maxX - c.px(80), y: r.minY + c.px(38), width: c.px(14), height: c.px(14)))
            Draw.text(ctx, "AI", c.font("mono", 22), c.cg("#FFFFFF", 0.8), x: r.maxX - c.px(56), centreY: r.minY + c.px(45))
            // Message box.
            let box = CGRect(x: r.minX + c.px(24), y: r.minY + c.px(90), width: w - c.px(48), height: h - c.px(210))
            Draw.roundedRect(ctx, box, radius: c.px(20), fill: TitleRasterizer.color("#FFFFFF", alpha: 0.03), stroke: accent.copy(alpha: 0.6), lineWidth: c.px(2))
            let tw = Draw.text(ctx, typed, c.font("mono", 34), TitleRasterizer.color("#FFFFFF"), x: box.minX + c.px(24), centreY: box.minY + c.px(50))
            if caret { ctx.setFillColor(accent); ctx.fill(CGRect(x: box.minX + c.px(28) + tw, y: box.minY + c.px(30), width: c.px(4), height: c.px(42))) }
            // Side panel next to the attachment.
            let side = CGRect(x: box.minX + box.width * 0.6, y: box.minY + c.px(100), width: box.width * 0.4 - c.px(20), height: box.height - c.px(120))
            Draw.roundedRect(ctx, CGRect(x: side.minX, y: side.minY, width: side.width, height: c.px(60)), radius: c.px(12), fill: accent)
            Draw.symbol(ctx, "paperclip", in: CGRect(x: side.minX + c.px(16), y: side.minY + c.px(16), width: c.px(26), height: c.px(28)), color: TitleRasterizer.color("#1A0F08"))
            let chip = attach.count > 16 ? String(attach.prefix(15)) + "…" : attach
            Draw.text(ctx, chip.uppercased(), c.font("mono", 20), TitleRasterizer.color("#1A0F08"), x: side.minX + c.px(52), centreY: side.minY + c.px(30), tracking: c.px(1))
            let dur = CGRect(x: side.minX, y: side.minY + c.px(80), width: side.width, height: c.px(190))
            Draw.roundedRect(ctx, dur, radius: c.px(14), fill: TitleRasterizer.color("#000000", alpha: 0.4), stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.1), lineWidth: 1)
            Draw.text(ctx, "DURATION", c.font("mono", 18), c.cg("#FFFFFF", 0.6), x: dur.midX, centreY: dur.minY + c.px(36), align: 0.5, tracking: c.px(3))
            Draw.text(ctx, m.string("attachmentLength"), c.font("textBold", 80), TitleRasterizer.color("#FFFFFF"), x: dur.midX, centreY: dur.minY + c.px(118), align: 0.5)
            // Footer.
            let foot = CGRect(x: r.minX + c.px(24), y: r.maxY - c.px(100), width: w - c.px(140), height: c.px(76))
            Draw.roundedRect(ctx, foot, radius: c.px(38), fill: TitleRasterizer.color("#FFFFFF", alpha: 0.04), stroke: TitleRasterizer.color("#FFFFFF", alpha: 0.12), lineWidth: 1)
            Draw.text(ctx, m.string("status").uppercased() + dots, c.font("mono", 22), c.cg("accent"), x: foot.minX + c.px(28), centreY: foot.midY, tracking: c.px(3))
            let send = CGRect(x: r.maxX - c.px(100), y: r.maxY - c.px(100), width: c.px(76), height: c.px(76))
            ctx.setFillColor(accent); ctx.fillEllipse(in: send)
            Draw.symbol(ctx, "paperplane.fill", in: send.insetBy(dx: c.px(20), dy: c.px(20)), color: TitleRasterizer.color("#1A0F08"))
        }
        let pop = Anim.spring(c.t, 0, length: 0.5)
        var layers = [MotionCanvas.fade(stage, env), c.place(window, at: (c.W / 2, y0 + h / 2 + c.px(30) * (1 - pop)), scale: 0.95 + 0.05 * pop, opacity: env)]
        // The attached clip, playing.
        let box = CGRect(x: x0 + c.px(24), y: y0 + c.px(90) + c.px(100) + c.px(30) * (1 - pop), width: (w - c.px(48)) * 0.6 - c.px(16), height: h - c.px(210) - c.px(120))
        var clip = Inset.picture(shot, canvas: c.canvas, into: box, radius: c.px(16), height: c.H)
        let ring = c.sprite("chat-clipring|\(Int(box.width))", box.width + c.px(20), box.height + c.px(20)) { ctx in
            Draw.roundedRect(ctx, CGRect(x: c.px(10), y: c.px(10), width: box.width, height: box.height), radius: c.px(16), fill: nil, stroke: accent, lineWidth: c.px(3))
        }
        clip = c.place(ring, at: (box.midX, box.midY)).composited(over: clip)
        let tag = c.sprite("chat-raw", c.px(120), c.px(44)) { ctx in
            Draw.roundedRect(ctx, CGRect(x: 0, y: 0, width: c.px(120), height: c.px(44)), radius: c.px(10), fill: TitleRasterizer.color("#16110D", alpha: 0.85), stroke: accent, lineWidth: c.px(1.5))
            ctx.setFillColor(TitleRasterizer.color("#E5484D")); ctx.fillEllipse(in: CGRect(x: c.px(14), y: c.px(17), width: c.px(10), height: c.px(10)))
            Draw.text(ctx, "RAW", c.font("mono", 20), TitleRasterizer.color("#FFFFFF"), x: c.px(34), centreY: c.px(22), tracking: c.px(2))
        }
        clip = c.place(tag, at: (box.minX + c.px(80), box.minY + c.px(40))).composited(over: clip)
        layers.append(MotionCanvas.fade(clip, env * Anim.p(c.t, 0.2, 0.3)))
        return MotionCanvas.stack(layers).composited(over: shot)
    }
}
