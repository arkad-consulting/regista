import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// The shot framed as a video player on a clean canvas: a rounded card with a shadow, a scrubber that moves, the
/// time, a file name and a small caption above it.
enum VideoCard: MotionTemplate {
    static let spec = MotionSpec(
        id: "video-card", label: "Lettore video", symbol: "play.rectangle",
        guide: CatalogGuide("The shot shrinks into a video-player card on a clean white (or paper, or dark) canvas: rounded corners, a soft shadow, a thin scrubber whose progress moves with the clip, play/volume icons and the time on the left, a file name in mono on the right, and a small spaced caption above the card (\"JUN 2026 · MY FIRST AI EDIT\"). The video keeps playing inside.",
                            useWhen: "Presenting a clip as a piece of work: \"my first AI edit\", a client's video, a before/after reveal, a case study; often followed by a prompt-bar under it. 2–4 s.",
                            avoid: "Long stretches of talking (the face gets small), stacking with other frame-wide templates, wide crops of vertical footage that cut the speaker's head."),
        fields: [
            .init("caption", "text", "JUN 2026 · MY FIRST AI EDIT", "Small spaced caption above the card (\"\" = none)."),
            .init("filename", "text", "intro_v1.mp4", "File name in the player bar."),
            .init("aspect", "choice", "4:5", "Card picture shape.", choices: ["16:9", "4:5", "9:16"]),
            .init("background", "choice", "white", "Canvas.", choices: ["white", "paper", "dark"]),
            .init("length", "number", 6, "Clip length shown in the time label, seconds."),
        ],
        form: ["caption", "filename", "aspect"], duration: 3.5, band: nil, consumesBelow: true, coversFrame: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        guard let below = c.below else { return nil }
        let m = c.m
        let p = Anim.ease(Anim.p(c.t, 0, 0.55), .easeInOut) * (1 - Anim.ease(Anim.p(c.t, c.d - 0.45, 0.45), .easeInOut))
        let aspect: Double = switch m.string("aspect", "4:5") { case "16:9": 9.0 / 16; case "9:16": 16.0 / 9; default: 5.0 / 4 }
        var w = c.W * 0.86, h = w * aspect
        if h > c.H * 0.62 { h = c.H * 0.62; w = h / aspect }
        let target = CGRect(x: (c.W - w) / 2, y: c.H * 0.4 - h / 2, width: w, height: h)
        let rect = Inset.lerp(c.canvas, target, p)
        let bg: CIColor = switch m.string("background", "white") {
        case "paper": c.ci("paper")
        case "dark": CIColor(red: 0.05, green: 0.05, blue: 0.06)
        default: CIColor(red: 0.985, green: 0.982, blue: 0.975)
        }
        let dark = m.string("background") == "dark"
        let radius = c.px(22) * p
        var layers = [CIImage(color: bg).cropped(to: c.canvas)]
        let shadow = c.sprite("vc-shadow|\(Int(rect.width))x\(Int(rect.height))|\(Int(radius))", rect.width + c.px(140), rect.height + c.px(140)) { ctx in
            Draw.card(ctx, CGRect(x: c.px(70), y: c.px(70), width: rect.width, height: rect.height), radius: radius, fill: TitleRasterizer.color("#000000"),
                      shadow: 0.35, blur: c.px(50), dy: c.px(22))
        }
        layers.append(c.place(shadow, at: (rect.midX, rect.midY), opacity: p))
        layers.append(Inset.picture(below, canvas: c.canvas, into: rect, radius: radius, height: c.H))
        if p > 0.6 {
            let a = Anim.p(p, 0.6, 0.4)
            // Player bar over the bottom of the picture.
            let len = max(m.number("length", 6), 1)
            let prog = min(c.t / c.d, 1)
            let barH = c.px(60)
            let bar = c.sprite("vc-bar|\(Int(w))|\(Int(prog * 200))|\(m.string("filename"))", w, barH) { ctx in
                let g = CGGradient(colorsSpace: TitleRasterizer.space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.55)] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: barH), options: [])
                let y = c.px(16)
                ctx.setFillColor(TitleRasterizer.color("#FFFFFF", alpha: 0.35)); ctx.fill(CGRect(x: c.px(16), y: y, width: w - c.px(32), height: c.px(3)))
                ctx.setFillColor(c.cg("accent")); ctx.fill(CGRect(x: c.px(16), y: y, width: (w - c.px(32)) * prog, height: c.px(3)))
                ctx.fillEllipse(in: CGRect(x: c.px(16) + (w - c.px(32)) * prog - c.px(6), y: y - c.px(4.5), width: c.px(12), height: c.px(12)))
                Draw.symbol(ctx, "play.fill", in: CGRect(x: c.px(16), y: c.px(30), width: c.px(16), height: c.px(16)), color: TitleRasterizer.color("#FFFFFF"))
                Draw.symbol(ctx, "speaker.wave.2.fill", in: CGRect(x: c.px(42), y: c.px(30), width: c.px(20), height: c.px(16)), color: TitleRasterizer.color("#FFFFFF"))
                let now = Int(prog * len)
                Draw.text(ctx, String(format: "%d:%02d / %d:%02d", now / 60, now % 60, Int(len) / 60, Int(len) % 60), c.font("mono", 15), TitleRasterizer.color("#FFFFFF"), x: c.px(74), centreY: c.px(38))
                Draw.text(ctx, m.string("filename"), c.font("mono", 15), TitleRasterizer.color("#FFFFFF", alpha: 0.85), x: w - c.px(16), centreY: c.px(38), align: 1)
            }
            layers.append(MotionCanvas.round(c.place(bar, at: (rect.midX, rect.maxY - barH / 2), opacity: a), radius: 0))
            let cap = m.string("caption")
            if !cap.isEmpty {
                let f = c.font("mono", 18)
                let cw = Draw.width(cap.uppercased(), f, tracking: c.px(4)) + c.px(10)
                let s = c.sprite("vc-cap|\(cap)|\(dark)", cw, c.px(30)) { ctx in
                    Draw.text(ctx, cap.uppercased(), f, TitleRasterizer.color(dark ? "#FFFFFF" : "#111111", alpha: 0.55), x: 0, centreY: c.px(15), tracking: c.px(4))
                }
                layers.append(c.place(s, at: (rect.minX + cw / 2, rect.minY - c.px(26)), opacity: a))
            }
        }
        return MotionCanvas.stack(layers)
    }
}
