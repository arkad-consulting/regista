import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A camera viewfinder over the shot: four corner brackets, mono labels top and bottom on hairlines, a running
/// timecode and a frame counter.
enum HUDFrame: MotionTemplate {
    static let spec = MotionSpec(
        id: "hud-frame", label: "Mirino HUD", symbol: "viewfinder",
        guide: CatalogGuide("A thin camera-viewfinder overlay: four L-shaped corner brackets slide in from the edges, small monospaced labels type themselves on at the top and bottom over hairlines, a timecode runs at the top right and a frame counter at the bottom right. Technical, editorial, very light on the picture.",
                            useWhen: "Behind-the-scenes, \"how it's made\", tech/AI/production topics, a section intro or a \"recording\" moment; it frames the whole shot for 2–6 s, or a full-screen interstitial.",
                            avoid: "Together with other frame-wide graphics (device frame, counter dim), emotional or intimate moments, very bright busy footage where thin white lines vanish (set color to ink)."),
        fields: [
            .init("topLeft", "text", "REGISTA / MOTION", "Label top left."),
            .init("topRight", "text", "", "Label top right (\"\" = running timecode)."),
            .init("bottomLeft", "text", "ECHO × 10 · 3D", "Label bottom left."),
            .init("bottomRight", "text", "", "Label bottom right (\"\" = frame counter)."),
            .init("color", "color", "#FFFFFF", "Lines and labels colour (#FFFFFF over video, ink over light backgrounds)."),
            .init("timecodeStart", "number", 11, "Timecode at the clip start, seconds."),
        ],
        form: ["topLeft", "bottomLeft", "color"], duration: 4, band: nil, coversFrame: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let color = m.color("color", "#FFFFFF")
        let enter = Anim.ease(Anim.p(c.t, 0, 0.5), .expoOut), fade = 1 - Anim.exit(c.t, c.d, 0.3)
        let x0 = c.px(70), x1 = c.W - c.px(90), y0 = c.H * 170 / 1920, y1 = c.H * 1500 / 1920
        let arm = c.px(54), lw = max(c.px(2.4), 1)
        var layers: [CIImage] = []
        // Corners: each slides in 30 px from outside.
        let off = c.px(30) * (1 - enter)
        for (cx, cy, sx, sy) in [(x0, y0, 1.0, 1.0), (x1, y0, -1.0, 1.0), (x0, y1, 1.0, -1.0), (x1, y1, -1.0, -1.0)] {
            let s = c.sprite("corner|\(color)|\(sx)|\(sy)", arm + 8, arm + 8) { ctx in
                ctx.setStrokeColor(TitleRasterizer.color(color)); ctx.setLineWidth(lw); ctx.setLineCap(.square)
                let ox = sx > 0 ? 4 : arm + 4, oy = sy > 0 ? 4 : arm + 4
                ctx.move(to: CGPoint(x: ox + sx * arm, y: oy)); ctx.addLine(to: CGPoint(x: ox, y: oy)); ctx.addLine(to: CGPoint(x: ox, y: oy + sy * arm))
                ctx.strokePath()
            }
            layers.append(c.place(s, at: (cx + sx * (arm / 2) - sx * off, cy + sy * (arm / 2) - sy * off), opacity: enter * fade))
        }
        // Labels and hairlines.
        let fps = 30.0
        let tc = m.number("timecodeStart", 11) + c.t
        let timecode = String(format: "00:%02d:%02d:%02d", Int(tc) / 60 % 60, Int(tc) % 60, Int((tc - floor(tc)) * fps))
        let frame = String(format: "FRAME %04d", Int(tc * fps))
        let f = c.font("mono", 22)
        let type = Anim.p(c.t, 0.2, 0.7)
        func label(_ s: String, x: Double, y: Double, align: Double) {
            let shown = String(s.prefix(Int((Double(s.count) * type).rounded(.up))))
            guard !shown.isEmpty else { return }
            let w = Draw.width(s, f, tracking: c.px(2)) + c.px(8)
            let sp = c.sprite("lbl|\(shown)|\(color)", w, c.px(36)) { ctx in
                ctx.setShadow(offset: .zero, blur: c.px(6), color: CGColor(gray: 0, alpha: color == "#FFFFFF" ? 0.35 : 0))
                Draw.text(ctx, shown, f, TitleRasterizer.color(color), x: align * w + (align == 0 ? c.px(4) : -c.px(4)), centreY: c.px(18), align: align, tracking: c.px(2))
            }
            layers.append(c.place(sp, at: (x + (0.5 - align) * w, y), opacity: fade))
        }
        let topY = y0 + c.px(44), botY = y1 - c.px(44)
        label(m.string("topLeft", "REGISTA / MOTION").uppercased(), x: x0 + c.px(28), y: topY, align: 0)
        label(m.string("topRight").isEmpty ? timecode : m.string("topRight").uppercased(), x: x1 - c.px(28), y: topY, align: 1)
        label(m.string("bottomLeft", "ECHO × 10 · 3D").uppercased(), x: x0 + c.px(28), y: botY, align: 0)
        label(m.string("bottomRight").isEmpty ? frame : m.string("bottomRight").uppercased(), x: x1 - c.px(28), y: botY, align: 1)
        let lineW = (x1 - x0 - c.px(56)) * enter
        let hair = c.sprite("hair|\(color)|\(Int(lineW))", max(lineW, 1), max(c.px(1.5), 1)) { ctx in
            ctx.setFillColor(TitleRasterizer.color(color, alpha: 0.6)); ctx.fill(CGRect(x: 0, y: 0, width: lineW, height: c.px(1.5)))
        }
        layers.append(c.place(hair, at: (c.W / 2 - c.px(10), topY + c.px(26)), opacity: fade))
        layers.append(c.place(hair, at: (c.W / 2 - c.px(10), botY - c.px(26)), opacity: fade))
        return MotionCanvas.stack(layers)
    }
}
