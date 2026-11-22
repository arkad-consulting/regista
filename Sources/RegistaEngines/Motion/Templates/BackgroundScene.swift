import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Full-frame backdrops for text interstitials: a dark radial glow over a perspective grid floor, a clean white
/// canvas, the brand paper or a brand gradient. Put templates (kicker-headline, bento-grid…) on top of it.
enum BackgroundScene: MotionTemplate {
    static let spec = MotionSpec(
        id: "background-scene", label: "Sfondo", symbol: "square.stack.3d.down.forward",
        guide: CatalogGuide("A full-frame backdrop that replaces the shot for an interstitial: \"dark-grid\" = near-black with a soft radial glow in the accent colour and a thin perspective grid floor slowly gliding towards the viewer; \"white\" = a clean warm-white canvas with a faint vignette; \"paper\" = the brand paper colour; \"gradient\" = a soft diagonal gradient between two brand colours. Fades in and out.",
                            useWhen: "A text or diagram interstitial between talking parts — under a kicker-headline, a bento-grid, a card-row, a timeline — when the graphic needs a calm clean stage instead of the room. 1.5–4 s. In a faceless reel (the prompt-to-reel recipe), the stage of a scene that contrasts with the kit's own colour, two of them overlapping by 0.5 s.",
                            avoid: "Covering the speaker for long (the face carries the reel), stacking two scenes, or using it when the graphic reads fine over the video."),
        fields: [
            .init("style", "choice", "dark-grid", "Backdrop.", choices: ["dark-grid", "white", "paper", "gradient"]),
            .init("color", "color", "accent", "Glow / gradient colour."),
            .init("color2", "color", "primary", "Second gradient colour."),
        ],
        form: ["style", "color"], duration: 3, band: nil, coversFrame: true)

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let style = m.string("style", "dark-grid")
        let env = Anim.envelope(c.t, c.d, in: 0.3, out: 0.3)
        let accent = m.color("color", "accent")
        var img: CIImage
        switch style {
        case "white":
            img = CIImage(color: CIColor(red: 0.985, green: 0.982, blue: 0.975)).cropped(to: c.canvas)
            img = img.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: c.W / 2, y: c.H / 2), kCIInputRadiusKey: c.H * 0.7,
                                                                     kCIInputIntensityKey: 0.12, "inputFalloff": 0.6]).cropped(to: c.canvas)
        case "paper":
            img = CIImage(color: c.ci("paper")).cropped(to: c.canvas)
        case "gradient":
            img = CIFilter(name: "CILinearGradient", parameters: ["inputPoint0": CIVector(x: 0, y: c.H), "inputPoint1": CIVector(x: c.W, y: 0),
                                                                  "inputColor0": c.ci(accent), "inputColor1": c.ci(m.color("color2", "primary"))])!.outputImage!.cropped(to: c.canvas)
        default:
            let glow = CIFilter(name: "CIRadialGradient", parameters: [kCIInputCenterKey: CIVector(x: c.W / 2, y: c.H * 0.55), "inputRadius0": 0, "inputRadius1": c.H * 0.5,
                                                                      "inputColor0": c.ci(accent, 0.5), "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)])!.outputImage!
            img = glow.composited(over: CIImage(color: CIColor(red: 0.035, green: 0.03, blue: 0.03)).cropped(to: c.canvas)).cropped(to: c.canvas)
            // Perspective grid floor in the lower half, gliding towards the viewer.
            let phase = (c.t * 0.35).truncatingRemainder(dividingBy: 1)
            let grid = c.sprite("grid|\(accent)|\(Int(phase * 60))", c.W, c.H * 0.5) { ctx in
                let w = c.W, h = c.H * 0.5, horizon = 0.0, vx = w / 2
                ctx.setStrokeColor(TitleRasterizer.color(accent, alpha: 0.28)); ctx.setLineWidth(max(c.px(1.4), 1))
                for i in -12...12 {
                    let x = vx + Double(i) * w / 7
                    ctx.move(to: CGPoint(x: vx + (x - vx) * 0.25, y: horizon)); ctx.addLine(to: CGPoint(x: vx + (x - vx) * 2.2, y: h)); ctx.strokePath()
                }
                for k in 0..<14 {
                    let z = (Double(k) + phase) / 14
                    let y = horizon + h * pow(z, 2.2)
                    ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); ctx.strokePath()
                }
                // Fade the floor into the distance (erase the lines near the horizon).
                ctx.setBlendMode(.destinationOut)
                let g = CGGradient(colorsSpace: TitleRasterizer.space, colors: [CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray, locations: [0, 1])!
                ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: h * 0.45), options: [])
            }
            img = grid.composited(over: img).cropped(to: c.canvas)
        }
        return MotionCanvas.fade(img, env)
    }
}
