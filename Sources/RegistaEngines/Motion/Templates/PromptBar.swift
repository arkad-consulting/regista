import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// A chat input pill whose text types itself letter by letter with a blinking caret; the send button lights up when
/// the sentence is complete.
enum PromptBar: MotionTemplate {
    static let spec = MotionSpec(
        id: "prompt-bar", label: "Prompt", symbol: "text.cursor",
        guide: CatalogGuide("A rounded chat input bar (dark or light) where a prompt types itself letter by letter with a blinking caret, like someone writing to an AI assistant; the round send button on the right lights up in the accent colour when the sentence is complete and pulses once.",
                            useWhen: "Showing the instruction given to an AI or a tool (\"edit this vid!\", \"make it shorter\"), a search query, a message — the moment of asking. Under a video-card, or in the lower band over the speaker.",
                            avoid: "Long prompts (> ~45 characters: the bar gets too small to read), real third-party brand names or logos in the bar, or when the speaker is reading the same words aloud as captions at that moment."),
        fields: [
            .init("text", "text", "edit this video!", "The prompt (≤ 45 characters)."),
            .init("theme", "choice", "dark", "Bar style.", choices: ["dark", "light"]),
            .init("speed", "number", 16, "Characters per second."),
            .init("width", "number", 760, "Bar width, px."),
        ],
        form: ["text", "theme", "speed"], duration: 3, band: "lower")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let text = m.string("text", "edit this video!")
        let dark = m.string("theme", "dark") == "dark"
        let speed = max(m.number("speed", 16), 1)
        let typed = Int(max(c.t - 0.35, 0) * speed)
        let shown = String(text.prefix(typed))
        let complete = typed >= text.count
        let caret = !complete || Int(c.t * 2.2) % 2 == 0
        let w = c.px(m.number("width", 760)), h = c.px(86), pad = c.px(30)
        let f = c.font("textBold", 32)
        let sendOn = complete ? min((c.t - 0.35 - Double(text.count) / speed) / 0.2, 1) : 0
        let bar = c.sprite("prompt|\(shown)|\(caret)|\(dark)|\(Int(sendOn * 10))", w + 2 * pad, h + 2 * pad) { ctx in
            let r = CGRect(x: pad, y: pad, width: w, height: h)
            Draw.card(ctx, r, radius: h / 2, fill: dark ? TitleRasterizer.color("#151517") : TitleRasterizer.color("#FFFFFF"), shadow: 0.25, blur: c.px(24), dy: c.px(8),
                      stroke: dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.12) : TitleRasterizer.color("#000000", alpha: 0.08))
            let ink = dark ? TitleRasterizer.color("#FFFFFF") : TitleRasterizer.color("#111111")
            let tw = Draw.text(ctx, shown, f, ink, x: r.minX + c.px(34), centreY: r.midY)
            if caret {
                ctx.setFillColor(c.cg("accent")); ctx.fill(CGRect(x: r.minX + c.px(38) + tw, y: r.midY - c.px(20), width: c.px(3), height: c.px(40)))
            }
            let d = c.px(54)
            let btn = CGRect(x: r.maxX - d - c.px(16), y: r.midY - d / 2, width: d, height: d)
            ctx.setFillColor(sendOn > 0 ? c.cg("accent", 0.35 + 0.65 * sendOn) : (dark ? TitleRasterizer.color("#FFFFFF", alpha: 0.15) : TitleRasterizer.color("#000000", alpha: 0.1)))
            ctx.fillEllipse(in: btn)
            Draw.symbol(ctx, "arrow.up", in: btn.insetBy(dx: d * 0.28, dy: d * 0.26), color: TitleRasterizer.color("#FFFFFF"), weight: .bold)
        }
        let pop = Anim.spring(c.t, 0, length: 0.4), leave = Anim.exit(c.t, c.d, 0.25)
        let pulse = complete ? 1 + 0.03 * sin(min(max(c.t - 0.35 - Double(text.count) / speed, 0), 0.3) / 0.3 * .pi) : 1
        let (cx, cy) = c.centre
        return c.place(bar, at: (cx, cy + c.px(20) * (1 - pop)), scale: (0.9 + 0.1 * pop) * pulse, opacity: min(pop * 1.5, 1) * (1 - leave))
    }
}
