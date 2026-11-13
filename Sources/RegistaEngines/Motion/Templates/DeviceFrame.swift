import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// The picture under it zooms out into an iPhone (rounded screen, bezel, dynamic island) on a brand-colour backdrop,
/// then back to full frame. Uses the shared inset mechanism (`Inset`), which other frame styles can reuse.
enum DeviceFrame: MotionTemplate {
    static let spec = MotionSpec(
        id: "device-frame", label: "Cornice iPhone", symbol: "iphone",
        guide: CatalogGuide("The whole shot smoothly zooms out into an iPhone: the picture becomes the phone's rounded screen, with a thin black bezel and a dynamic island, floating with a soft shadow on a plain brand-colour backdrop; at the end it zooms back to full frame. The video keeps playing inside the phone.",
                            useWhen: "The line talks about phones, apps, Instagram/TikTok, \"what your client sees on mobile\", or to frame the reel itself as a phone screen for a beat (2–4 s), e.g. the reveal of a mobile site or an app demo recorded vertically.",
                            avoid: "Long stretches (the speaker gets small), footage with important detail at the left/right edges (the screen crops the sides a little), stacking it with other full-frame graphics, or screen recordings in 16:9."),
        fields: [
            .init("background", "color", "paper", "Backdrop colour around the phone."),
            .init("bezel", "color", "#111111", "Bezel colour."),
            .init("size", "number", 0.8, "Phone width as a fraction of the frame width at full zoom-out."),
            .init("zoomBack", "boolean", true, "Zoom back to full frame at the end."),
            .init("transition", "number", 0.65, "Seconds of the zoom out (and back)."),
        ],
        form: ["background", "size", "zoomBack"], duration: 3, band: nil, consumesBelow: true, coversFrame: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        guard let below = c.below else { return nil }
        let m = c.m
        let tr = max(m.number("transition", 0.65), 0.1)
        var p = Anim.ease(Anim.p(c.t, 0, tr), .easeInOut)
        if m.bool("zoomBack", true) { p = min(p, Anim.ease(Anim.p(c.d - c.t, 0, tr), .easeInOut)) }
        let sw = c.W * min(max(m.number("size", 0.8), 0.4), 0.98), sh = min(sw * 2.06, c.H * 0.9)
        let screen = Inset.lerp(c.canvas, CGRect(x: (c.W - sw) / 2, y: (c.H - sh) / 2 - c.px(10), width: sw, height: sh), p)
        let radius = c.px(66) * p
        var layers = [CIImage(color: c.ci(m.string("background", "paper"))).cropped(to: c.canvas)]
        // Shadow and bezel grow in with the zoom.
        let bezel = c.px(13) * p
        let body = screen.insetBy(dx: -bezel, dy: -bezel)
        if p > 0.01 {
            let shape = c.sprite("body|\(Int(body.width))x\(Int(body.height))|\(m.string("bezel"))|\(Int(radius))", body.width + c.px(160), body.height + c.px(160)) { ctx in
                let r = CGRect(x: c.px(80), y: c.px(80), width: body.width, height: body.height)
                Draw.card(ctx, r, radius: radius + bezel, fill: c.cg(m.string("bezel", "#111111")), shadow: 0.32, blur: c.px(60), dy: c.px(24))
                // Side buttons.
                ctx.setFillColor(c.cg(m.string("bezel", "#111111")))
                ctx.fill(CGRect(x: r.maxX - 1, y: r.minY + r.height * 0.24, width: c.px(5), height: r.height * 0.1))
                ctx.fill(CGRect(x: r.minX - c.px(4), y: r.minY + r.height * 0.2, width: c.px(5), height: r.height * 0.06))
                ctx.fill(CGRect(x: r.minX - c.px(4), y: r.minY + r.height * 0.29, width: c.px(5), height: r.height * 0.06))
            }
            layers.append(c.place(shape, at: (body.midX, body.midY), opacity: min(p * 2, 1)))
        }
        layers.append(Inset.picture(below, canvas: c.canvas, into: screen, radius: radius, height: c.H))
        if p > 0.3 {
            let iw = c.px(118) * p, ih = c.px(34) * p
            let island = c.sprite("island|\(Int(iw))", iw, ih) { ctx in
                Draw.roundedRect(ctx, CGRect(x: 0, y: 0, width: iw, height: ih), radius: ih / 2, fill: TitleRasterizer.color("#000000"))
            }
            layers.append(c.place(island, at: (screen.midX, screen.minY + c.px(30) * p), opacity: Anim.p(p, 0.3, 0.5)))
        }
        return MotionCanvas.stack(layers)
    }
}

/// The shared inset mechanism: the frame drawn so far, scaled (aspect fill) into a rounded rectangle of the frame.
/// Device frames, inset cards and picture-in-picture styles build on it.
public enum Inset {
    /// Linear blend of two rects.
    public static func lerp(_ a: CGRect, _ b: CGRect, _ f: Double) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * f, y: a.minY + (b.minY - a.minY) * f, width: a.width + (b.width - a.width) * f,
               height: a.height + (b.height - a.height) * f)
    }

    /// `picture` (a full-canvas image) aspect-filled into `rect` (top-left origin pixels), corners rounded by `radius`.
    public static func picture(_ picture: CIImage, canvas: CGRect, into rect: CGRect, radius: Double, height H: Double) -> CIImage {
        let s = max(rect.width / canvas.width, rect.height / canvas.height)
        let ciRect = CGRect(x: rect.minX, y: H - rect.maxY, width: rect.width, height: rect.height)
        let scaled = picture.cropped(to: canvas)
            .transformed(by: CGAffineTransform(translationX: -canvas.midX, y: -canvas.midY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
            .transformed(by: CGAffineTransform(translationX: ciRect.midX, y: ciRect.midY))
            .cropped(to: ciRect)
        return MotionCanvas.round(scaled, radius: radius)
    }
}
