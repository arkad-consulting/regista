import AppKit
import SwiftUI

/// "00:00:12:07" at 30 fps.
func timecode(frames seconds: Double, fps: Double = 30) -> String {
    let f = max(0, Int((seconds * fps).rounded()))
    let fpsI = Int(fps.rounded())
    let s = f / fpsI
    return String(format: "%02d:%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60, f % fpsI)
}

/// "0:49.0"
func shortTime(_ seconds: Double) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
}

/// Lays out children left to right, wrapping (transcript words).
struct FlowLayout: Layout {
    var spacing: CGFloat = 3
    var lineSpacing: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
        return CGSize(width: width, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += lineH + lineSpacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineH = max(lineH, size.height)
        }
    }
}

/// SwiftUI host for a `FrameView`.
struct MonitorView: NSViewRepresentable {
    let source: FrameSource
    var aspect: CGFloat

    func makeNSView(context: Context) -> FrameView {
        let v = FrameView()
        v.source = source
        v.aspect = aspect
        source.attach(v)
        return v
    }

    func updateNSView(_ v: FrameView, context: Context) {
        if v.source !== source { v.source = source; source.attach(v) }
        if v.aspect != aspect { v.aspect = aspect; v.needsDisplay = true }
    }
}
