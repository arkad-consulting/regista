import SwiftUI

/// Panel sizes the user dragged, persisted per user (`@AppStorage`). 0 = automatic: the workspace computes
/// the size from the window, as before splitters existed. Double-clicking a splitter stores 0 again.
enum SplitSize {
    static let automatic = 0.0

    /// A range that is never empty: when the window is too small for both bounds, the minimum wins.
    static func range(_ lower: CGFloat, _ upper: CGFloat) -> ClosedRange<CGFloat> { lower...max(lower, upper) }

    static func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The size to show: the stored one (when the user dragged) or the automatic one, kept inside `range`.
    static func resolve(_ stored: Double, automatic: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        clamp(stored > 0 ? CGFloat(stored) : automatic, range)
    }

    /// The value to store after a drag of `delta` points from `base` (the size when the drag started).
    static func dragged(from base: CGFloat, by delta: CGFloat, in range: ClosedRange<CGFloat>) -> Double {
        Double(clamp(base + delta, range).rounded())
    }
}

/// The Pro workspace's two resizable sizes (the Program monitor's width, the timeline's height), from the editor's
/// size and what the user stored.
struct ProLayout: Equatable {
    var program: CGFloat, lower: CGFloat
    var programRange: ClosedRange<CGFloat>, lowerRange: ClosedRange<CGFloat>

    static let gutter: CGFloat = 2
    static let minSource: CGFloat = 250
    static let minUpper: CGFloat = 260

    /// `aspect`: width / height of the project's frame (the Program picture's format).
    static func compute(_ size: CGSize, program: Double = 0, lower: Double = 0, aspect: CGFloat = 9.0 / 16) -> ProLayout {
        let g = gutter
        let lowerRange = SplitSize.range(180, size.height - g - minUpper)
        let lowerH = SplitSize.resolve(lower, automatic: min(max(size.height * 0.41, 290), 400), in: lowerRange)
        let upper = size.height - lowerH - g
        // Automatic: the picture in the project's format fills the monitor's height (header 28 + transport 58 + padding 20).
        let programRange = SplitSize.range(190, size.width - g - minSource)
        let programW = SplitSize.resolve(program, automatic: max((upper - 28 - 58 - 20) * aspect + 20, 230), in: programRange)
        return ProLayout(program: programW, lower: lowerH, programRange: programRange, lowerRange: lowerRange)
    }
}

/// A draggable divider between two panels (Premiere / Final Cut style): it sits in the 2 pt gutter, takes the
/// mouse over a wider band, shows the resize cursor and a thin accent line while hovered or dragged, and resets
/// to automatic on double-click.
struct Splitter: View {
    enum Orientation {
        /// Between side-by-side panels: drags left and right.
        case vertical
        /// Between stacked panels: drags up and down.
        case horizontal
    }

    let orientation: Orientation
    /// The stored size of the panel this splitter resizes (0 = automatic).
    @Binding var stored: Double
    /// The size shown now (the drag starts from it).
    let current: CGFloat
    let range: ClosedRange<CGFloat>
    /// +1 when dragging right / down grows the panel (it is before the splitter), −1 when it shrinks it.
    var direction: CGFloat = 1
    var thickness: CGFloat = ProLayout.gutter

    @State private var hover = false
    @State private var base: CGFloat?

    private var vertical: Bool { orientation == .vertical }

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: vertical ? thickness : nil, height: vertical ? nil : thickness)
            .overlay {
                // The visible line: hairline on hover, a touch stronger while dragging.
                Rectangle()
                    .fill(Ed.gold.opacity(base != nil ? 0.85 : 0.5))
                    .frame(width: vertical ? (base != nil ? 2 : 1.5) : nil, height: vertical ? nil : (base != nil ? 2 : 1.5))
                    .opacity(hover || base != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: hover)
                    .animation(.easeOut(duration: 0.12), value: base != nil)
                    .allowsHitTesting(false)
            }
            .overlay {
                // The grab band, wider than the gutter.
                Color.clear
                    .frame(width: vertical ? 9 : nil, height: vertical ? nil : 9)
                    .contentShape(Rectangle())
                    .pointerStyle(vertical ? .columnResize : .rowResize)
                    .onHover { hover = $0 }
                    .gesture(drag)
                    .onTapGesture(count: 2) { stored = SplitSize.automatic }
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Divisore")
            .accessibilityHint("Trascina per ridimensionare, doppio clic per la misura automatica")
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { v in
                let start = base ?? current
                if base == nil { base = start }
                let delta = (vertical ? v.translation.width : v.translation.height) * direction
                stored = SplitSize.dragged(from: start, by: delta, in: range)
            }
            .onEnded { _ in base = nil }
    }
}
