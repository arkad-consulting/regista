import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// An animated mouse pointer gliding along a path of points with a click ripple at each stop — to point at a graphic
/// or a UI mock.
enum Cursor: MotionTemplate {
    static let spec = MotionSpec(
        id: "cursor", label: "Puntatore", symbol: "cursorarrow.click",
        guide: CatalogGuide("A white macOS-style arrow pointer with a dark outline and a soft shadow glides smoothly from point to point (eased, slightly curved), pressing at each stop with a small accent ripple — as if someone were clicking through the frame.",
                            useWhen: "Pointing at a button of a mock-ui or a screenshot, simulating a click on a prompt-bar's send button, guiding the eye through a card during a tutorial; with real UI positions.",
                            avoid: "Real screen recordings (they have their own cursor and click data: use edit.autoZoom), pointing at the speaker, wandering paths with many stops."),
        fields: [
            .init("path", "numbers", [300, 1100, 640, 820, 860, 1020], "Stops as x, y pairs on a 1080×1920 frame (the first one is where it enters)."),
            .init("clicks", "boolean", true, "Click (press + ripple) at every stop after the first."),
            .init("size", "number", 2.4, "Pointer size factor (2.4 reads well on a phone)."),
        ],
        form: ["path", "clicks"], duration: 3, band: nil)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let flat = m.numbers("path")
        var pts: [(Double, Double)] = stride(from: 0, to: flat.count - 1, by: 2).map { (c.px(flat[$0]), flat[$0 + 1] / SafeZones.referenceHeight * c.H) }
        if pts.isEmpty { pts = [(c.W / 2, c.H / 2)] }
        let legs = max(pts.count - 1, 1)
        let span = max(c.d - 0.6, 0.5) / Double(legs)
        var pos = pts[0], press = 0.0
        var layers: [CIImage] = []
        for i in 0..<legs where pts.count > 1 {
            let t0 = 0.3 + span * Double(i)
            let f = Anim.ease(Anim.p(c.t, t0, span * 0.7), .easeInOut)
            let a = pts[i], b = pts[i + 1]
            if c.t >= t0 {
                // A gentle arc: offset perpendicular to the leg, largest mid-way.
                let bow = sin(f * .pi) * 0.12
                pos = (a.0 + (b.0 - a.0) * f - (b.1 - a.1) * bow, a.1 + (b.1 - a.1) * f + (b.0 - a.0) * bow)
            }
            if m.bool("clicks", true) {
                let tc = t0 + span * 0.72
                let dt = c.t - tc
                if dt >= 0 && dt < 0.5 {
                    press = max(press, dt < 0.12 ? dt / 0.12 : max(0, 1 - (dt - 0.12) / 0.15))
                    let d = c.px(40 + 140 * Anim.ease(dt / 0.5, .easeOut))
                    let ring = c.sprite("ripple|\(Int(d))", d + 8, d + 8) { ctx in
                        ctx.setStrokeColor(c.cg("accent")); ctx.setLineWidth(c.px(4)); ctx.strokeEllipse(in: CGRect(x: 4, y: 4, width: d, height: d))
                    }
                    layers.append(c.place(ring, at: b, opacity: 1 - dt / 0.5))
                }
            }
        }
        let k = m.number("size", 2.4) * c.k
        let arrow = c.sprite("arrow|\(Int(k * 100))", 40 * k, 50 * k) { ctx in
            let path = CGScreenSynthesizer.Scene.cursorPath(at: CGPoint(x: 6 * k, y: 4 * k), scale: k)
            // A shadow offset ignores the flipped context: negative falls below.
            ctx.setShadow(offset: CGSize(width: 0, height: -3 * k), blur: 6 * k, color: CGColor(gray: 0, alpha: 0.4))
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.addPath(path); ctx.setStrokeColor(CGColor(gray: 0, alpha: 1)); ctx.setLineWidth(1.6 * k); ctx.setLineJoin(.round); ctx.strokePath()
        }
        let env = Anim.envelope(c.t, c.d, in: 0.25, out: 0.25)
        // The tip (top-left of the arrow) sits on the point.
        layers.append(c.place(arrow, at: (pos.0 + arrow.extent.width / 2 - 6 * k, pos.1 + arrow.extent.height / 2 - 4 * k), scale: 1 - 0.12 * press, opacity: env,
                              anchor: (6 * k / arrow.extent.width, 4 * k / arrow.extent.height)))
        return MotionCanvas.stack(layers)
    }
}
