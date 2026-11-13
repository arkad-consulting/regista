import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// One generated editor panel, animated (moving playhead and timecode, sliders sliding, the curve drawing, the
/// waveform playing), in a dark glass window: usable alone, or zoomed / panned with clip keyframes.
enum MockUI: MotionTemplate {
    static let spec = MotionSpec(
        id: "mock-ui", label: "Pannello app", symbol: "slider.horizontal.below.rectangle",
        guide: CatalogGuide("A single dark-glass app window (traffic-light buttons, a title) with a generated, animated editor panel: a timeline with coloured clips and a moving playhead with a timecode bubble, colour wheels, a keyframe curve drawing itself, an audio waveform playing, an effects grid lighting up, sliders sliding, or a big-number stats panel. Pops in and animates for the whole clip.",
                            useWhen: "Illustrating a step of a workflow (\"it cuts the timeline\", \"it grades the colours\", \"it adds keyframes\") in a tech or tutorial reel when there is no real screen recording; one panel per beat, in the top band.",
                            avoid: "Pretending it is a real product UI (it is generic), non-tech topics, more than ~3 panels in a reel (use card-stack for a group), or over a face."),
        fields: [
            .init("kind", "choice", "timeline", "Panel.", choices: MockPanels.kinds),
            .init("title", "text", "", "Window title (default: the panel name)."),
            .init("width", "number", 820, "Window width, px."),
            .init("tilt", "number", 0, "Lean back in perspective, degrees (0 = flat)."),
        ],
        form: ["kind", "title", "tilt"], duration: 3, band: "top")

    static func draw(_ c: MotionCanvas) -> CIImage? {
        let m = c.m
        let w = c.px(m.number("width", 820)), h = w * 0.52
        let kind = m.string("kind", "timeline")
        let title = m.string("title")
        let panel = MockPanels.panel(c, kind: kind, w: w, h: h, phase: Anim.p(c.t, 0.25, max(c.d - 0.6, 0.5)), label: title.isEmpty ? nil : title)
        let pop = Anim.spring(c.t, 0, length: 0.45), leave = Anim.exit(c.t, c.d, 0.25)
        let (cx, cy) = c.centre
        return c.place(panel, at: (cx, cy + c.px(30) * (1 - pop)), scale: 0.9 + 0.1 * pop, opacity: min(pop * 1.5, 1) * (1 - leave),
                       rotationX: m.number("tilt", 0), perspective: 1800)
    }
}
