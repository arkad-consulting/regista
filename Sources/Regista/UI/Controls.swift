import AppKit
import RegistaCore
import SwiftUI

// The control set of the main window (D0 #46, #2): one implementation of each control, built on the tokens of
// Tokens.swift. Views compose these; they do not draw their own copy of a button, a field or a row. The check
// (Tests/RegistaAppTests/DesignSystemTests.swift) fails when a view outside Settings uses a native control, a literal
// colour or a literal type size. Every control takes keyboard focus where it can (visible ring) and arrow keys.
//
// Values
//   RSlider        value + range, gradient track, bubble while dragging/hovering/focused, onCommit at release
//   RSegmented     2–6 options in a bar, the selection slides
//   IntensityBar   0…1 in steps, rising bars between two words ("poco" / "tanto")
//   RToggle        capsule switch with label (RSwitch: the switch alone, SwitchKnob: its drawing)
//   RSwitchRow     a row with icon, name, current choice and its own switch; the row itself opens its choices
//   RChips         a few options as chips: a grid, a wrapping row (flow) or tall tiles (stacked); selection may be none
//   RChoiceList    a list of choices with a check (devices, screens, windows)
// Text
//   RTextField     the one single-line field (search fields: a leading glyph and a clear button)
//   RTextEditor    the one multi-line editor (grows with its text, or scrolls inside a fixed height)
//   InspectorValueField  a value that becomes a field on click (numbers, timecodes)
// Rows, cards, states
//   SideRow        a one-line row of a side list: glyph, title, a dim detail on the right
//   PickRow        a row to pick from: a leading thumbnail / glyph / radio, title, one dim line or the reason it is
//                  greyed (amber), a mark on the right, an optional link under it (Installa…, Usa di nuovo)
//   RowGlyph, RowThumb, RadioMark   the leading parts of a row
//   RTag           a small word beside a title ("Prossimo", "a pagamento")
//   StateGlyph     a step's state as a glyph (number to do, check done, spinner running, lock, warning…)
//   ReasonNote     why something cannot run now, in words, with the way on (a button or a link)
//   StateCard      a panel's state: a glyph, a title, what it means, the actions
//   .rCard()       an inline card (raised: forms, jobs, approvals; well: summaries and notes)
// Structure
//   SectionLabel   a section's small title (shell A: SF 11 semibold, spaced capitals); RSection = label + content
//   PanelHeader, TabStrip, EmptyHint
// Buttons
//   EdButton       text button: secondary (default), primary (`prominent`: the one main action of a panel),
//                  quiet (no frame until hovered), destructive; `large` for a screen's main action
//   AccentLinkButton   a quiet link in the accent ("Importa…", "Installa…")
//   IconButton     a square icon button; `chrome` is the title row's / toolbar's size (the panel toggles)
// Colour
//   ColorSwatch    a colour by role; click = system colour panel
//   Accent         the editor accent: Arkad gold, or the active brand kit's (optional, contrast-checked)
//
// Selected states: a chosen value (a chip, a row, a segment) is the soft accent with an accent edge; where you are (the
// open step, the activity, the tab) is a raised grey with the accent marker. The solid accent is kept for the one primary
// action of a panel.
//
// Every text a control takes is a lookup key (Words.swift): the control calls `loc` itself, so a key built anywhere is
// drawn in the user's language. Data (file names, the user's words) passes through unchanged, as no key matches it.

// MARK: - Accent

/// The editor's accent colour. Arkad gold by default; with "accent follows the kit" on, the active kit's most
/// readable brand colour (contrast ≥ 4.5 on the panels, lightened if none is).
enum Accent {
    static let defaultHex = "#F4BD56"
    static let panelHex = "#131315"
    nonisolated(unsafe) private(set) static var hex = defaultHex
    static var color: Color { Color(hexString: hex) }
    /// Text/icons on the accent.
    static var on: Color { BrandKit.contrast(hex, "#000000") >= BrandKit.contrast(hex, "#FFFFFF") ? Color.black.opacity(0.86) : .white }

    static let followKey = "accentFollowsKit"

    static func resolve(kit: BrandKit?, follow: Bool) -> String {
        guard follow, let kit else { return defaultHex }
        let candidates = ["primary", "highlight", "accent", "success"].compactMap { kit.colors[$0] }
        if let good = candidates.first(where: { BrandKit.contrast($0, panelHex) >= 4.5 }) { return good.uppercased() }
        guard var c = candidates.first else { return defaultHex }
        for _ in 0..<12 where BrandKit.contrast(c, panelHex) < 4.5 { c = mix(c, "#FFFFFF", 0.15) }
        return c
    }

    static func set(_ h: String) { hex = h }

    static func mix(_ a: String, _ b: String, _ t: Double) -> String {
        let x = BrandKit.rgb(a), y = BrandKit.rgb(b)
        let m = zip(x, y).map { Int(($0 + ($1 - $0) * t).rounded()) }
        return String(format: "#%02X%02X%02X", m[0], m[1], m[2])
    }
}

extension Color {
    /// "#RRGGBB" (invalid → grey).
    init(hexString: String) {
        let v = UInt32(hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x808080
        self.init(hex: v)
    }

    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }
}

/// A focus ring in the accent, drawn outside the control (keyboard users see where they are).
private struct FocusRing: ViewModifier {
    var focused: Bool
    var radius: CGFloat
    func body(content: Content) -> some View {
        content.overlay(
            RoundedRectangle(cornerRadius: radius + 3).strokeBorder(Ed.gold.opacity(focused ? 0.9 : 0), lineWidth: 2).padding(-3)
        )
    }
}

extension View {
    func rFocusRing(_ focused: Bool, radius: CGFloat = 6) -> some View { modifier(FocusRing(focused: focused, radius: radius)) }
}

// MARK: - Slider

/// A thin track that fills with a gradient of the accent up to the value, a round thumb, and a value bubble above
/// the thumb while dragging, hovering or focused. Arrow keys step (⇧ = ×10). `onCommit` fires when a drag ends or
/// after a key press: commands run then, not on every pixel.
struct RSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0
    var label: String? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var onCommit: (Double) -> Void = { _ in }

    @State private var dragging = false
    @State private var hover = false
    @FocusState private var focused: Bool

    private var fraction: Double { range.upperBound > range.lowerBound ? (value - range.lowerBound) / (range.upperBound - range.lowerBound) : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label {
                HStack {
                    Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2)
                    Spacer()
                    Text(verbatim: format(value)).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(dragging || focused ? Ed.gold : Ed.text3)
                }
            }
            GeometryReader { geo in
                let w = geo.size.width, x = CGFloat(fraction) * w
                ZStack(alignment: .leading) {
                    Capsule().fill(Ed.well).frame(height: 4)
                        .overlay(Capsule().strokeBorder(Ed.line2, lineWidth: 0.5))
                    Capsule()
                        .fill(LinearGradient(colors: [Ed.gold.opacity(0.35), Ed.gold], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(x, 4), height: 4)
                    Circle()
                        .fill(Ed.text)
                        .frame(width: dragging ? 16 : 13, height: dragging ? 16 : 13)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .overlay(Circle().strokeBorder(Ed.gold.opacity(dragging || focused ? 1 : 0), lineWidth: 2))
                        .offset(x: x - (dragging ? 8 : 6.5))
                    if dragging || (hover && label == nil) || (focused && label == nil) {
                        Text(verbatim: format(value))
                            .font(Ed.mono(Ed.TypeSize.caption, .medium))
                            .foregroundStyle(Accent.on)
                            .padding(.horizontal, 6).padding(.vertical, Ed.Space.xxs)
                            .background(Capsule().fill(Ed.gold))
                            .fixedSize()
                            .offset(x: min(max(x - 18, -4), w - 30), y: -20)
                            .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)))
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 18)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if !dragging { withAnimation(.easeOut(duration: 0.12)) { dragging = true } }
                        set(Double(g.location.x / max(w, 1)))
                    }
                    .onEnded { _ in
                        withAnimation(.easeOut(duration: 0.18)) { dragging = false }
                        onCommit(value)
                    })
            }
            .frame(height: 18)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .rFocusRing(focused, radius: 4)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onKeyPress(keys: [.leftArrow, .rightArrow, .downArrow, .upArrow]) { press in
            let unit = step > 0 ? step : (range.upperBound - range.lowerBound) / 100
            let dir: Double = press.key == .leftArrow || press.key == .downArrow ? -1 : 1
            value = min(max(value + dir * unit * (press.modifiers.contains(.shift) ? 10 : 1), range.lowerBound), range.upperBound)
            onCommit(value)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(loc(label ?? ""))
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { d in
            let unit = step > 0 ? step : (range.upperBound - range.lowerBound) / 100
            value = min(max(value + (d == .increment ? unit : -unit), range.lowerBound), range.upperBound)
            onCommit(value)
        }
    }

    private func set(_ f: Double) {
        var v = range.lowerBound + min(max(f, 0), 1) * (range.upperBound - range.lowerBound)
        if step > 0 { v = (v / step).rounded() * step }
        value = min(max(v, range.lowerBound), range.upperBound)
    }
}

// MARK: - Segmented bar

/// The one segmented control (shell A's look: a grey track, the chosen segment raised; the weight never changes, so
/// nothing moves). `fill` stretches the segments to the width available; `tips` / `shortcuts` give each segment a
/// tooltip; `disabled` greys some out. ← → move when focused. Titles are lookup keys (`loc`).
struct RSegmented<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T
    var symbols: [T: String] = [:]
    var height: CGFloat = Ed.Height.control
    var fill = true
    var tips: [T: String] = [:]
    var shortcuts: [T: String] = [:]
    var disabled: Set<T> = []

    @Namespace private var ns
    @FocusState private var focused: Bool

    var body: some View {
        // Each segment keeps its whole word (the free width is shared, a long word gets more of it); only when the words
        // cannot fit at all do they shrink.
        ViewThatFits(in: .horizontal) {
            segments(whole: true)
            segments(whole: false)
        }
        .padding(Ed.Space.xxs)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(Ed.control))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .rFocusRing(focused, radius: Ed.Radius.l)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let i = items.firstIndex(where: { $0.0 == selection }) else { return .ignored }
            let j = min(max(i + (press.key == .leftArrow ? -1 : 1), 0), items.count - 1)
            guard !disabled.contains(items[j].0) else { return .handled }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selection = items[j].0 }
            return .handled
        }
    }

    private func segments(whole: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                let on = item.0 == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selection = item.0 }
                } label: {
                    HStack(spacing: 5) {
                        if let s = symbols[item.0] { Image(systemName: s).font(Ed.icon(Ed.TypeSize.caption, .semibold)) }
                        if !item.1.isEmpty {
                            if whole { label(item.1).fixedSize() } else { label(item.1).minimumScaleFactor(0.7) }
                        }
                    }
                    .foregroundStyle(on ? Ed.text : Ed.text3)
                    .padding(.horizontal, fill ? (whole ? 4 : 2) : 12)
                    .frame(maxWidth: fill ? .infinity : nil, minHeight: height - 4, maxHeight: height - 4)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: Ed.Radius.m, style: .continuous)
                                .fill(Ed.controlOn)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .disabled(disabled.contains(item.0))
                .opacity(disabled.contains(item.0) ? 0.4 : 1)
                .tip(tips[item.0] ?? "", shortcut: shortcuts[item.0])
                .accessibilityLabel(loc(item.1))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private func label(_ title: String) -> some View {
        Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.body, .medium)).lineLimit(1)
    }
}

// MARK: - Intensity bar

/// "How much": `steps` bars rising left to right between two words; tap or drag to set, ← → step.
struct IntensityBar: View {
    @Binding var value: Double
    var steps = 7
    var low = "poco"
    var high = "tanto"
    var label: String? = nil
    var onCommit: (Double) -> Void = { _ in }

    @FocusState private var focused: Bool
    @State private var dragging = false

    private var level: Int { Int((value * Double(steps)).rounded()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let label { Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2) }
            HStack(spacing: 10) {
                Text(verbatim: loc(low)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                GeometryReader { geo in
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(0..<steps, id: \.self) { i in
                            let on = i < level
                            RoundedRectangle(cornerRadius: Ed.Radius.xs)
                                .fill(on ? AnyShapeStyle(LinearGradient(colors: [Ed.gold.opacity(0.55), Ed.gold], startPoint: .bottom, endPoint: .top))
                                         : AnyShapeStyle(Ed.raised))
                                .frame(height: 6 + CGFloat(i) / CGFloat(max(steps - 1, 1)) * 14)
                                .scaleEffect(y: dragging && i == level - 1 ? 1.12 : 1, anchor: .bottom)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let f = min(max(g.location.x / max(geo.size.width, 1), 0), 1)
                            withAnimation(.easeOut(duration: 0.1)) { value = (f * Double(steps)).rounded(.up) / Double(steps) }
                        }
                        .onEnded { _ in dragging = false; onCommit(value) })
                }
                .frame(height: 22)
                Text(verbatim: loc(high)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .rFocusRing(focused, radius: 4)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let l = min(max(level + (press.key == .leftArrow ? -1 : 1), 0), steps)
            withAnimation(.easeOut(duration: 0.1)) { value = Double(l) / Double(steps) }
            onCommit(value)
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(loc(label ?? "") + (label == nil ? "\(loc(low)) – \(loc(high))" : ""))
        .accessibilityValue("\(level) / \(steps)")
    }
}

// MARK: - Toggle

/// The capsule switch drawn by every toggle (RToggle, RSwitchRow, RSwitch).
struct SwitchKnob: View {
    let isOn: Bool
    var focused = false

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? AnyShapeStyle(LinearGradient(colors: [Ed.gold.opacity(0.75), Ed.gold], startPoint: .leading, endPoint: .trailing))
                                : AnyShapeStyle(Ed.raised))
                .overlay(Capsule().strokeBorder(isOn ? .clear : Ed.line2))
            Circle().fill(isOn ? Accent.on : Ed.text2).frame(width: 14, height: 14).padding(Ed.Space.xxs)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
        }
        .frame(width: 34, height: 18)
        .rFocusRing(focused, radius: 9)
    }
}

/// The switch alone (rows draw their own label); Space toggles when focused.
struct RSwitch: View {
    @Binding var isOn: Bool
    var label: String = ""

    @FocusState private var focused: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } } label: {
            SwitchKnob(isOn: isOn, focused: focused).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .accessibilityLabel(loc(label))
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "1" : "0")
    }
}

/// A capsule switch with its label on the left; Space toggles when focused.
struct RToggle: View {
    let title: String
    @Binding var isOn: Bool
    var subtitle: String? = nil

    @FocusState private var focused: Bool

    var body: some View {
        Button { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text)
                    if let subtitle { Text(verbatim: loc(subtitle)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: Ed.Space.s)
                SwitchKnob(isOn: isOn, focused: focused)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "1" : "0")
    }
}

// MARK: - Switch row

/// One source or option with its own switch: an icon tile, the name, the current choice underneath (a warning in
/// amber), an optional accessory under it (a level meter) and trailing content before the switch (an action).
/// Clicking the row — not the switch — calls `onOpen` (its choices open below); a row without choices toggles.
struct RSwitchRow<Accessory: View, Trailing: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var enabled = true
    var warning = false
    /// nil: the row has no choices.
    var expanded: Bool? = nil
    var onOpen: () -> Void = {}
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var trailing: Trailing

    @State private var hover = false

    var body: some View {
        HStack(spacing: Ed.Space.m) {
            Button(action: { expanded == nil ? toggle() : onOpen() }) {
                HStack(spacing: Ed.Space.m) {
                    Image(systemName: symbol)
                        .font(Ed.icon(Ed.TypeSize.label, .medium))
                        .foregroundStyle(isOn && enabled ? Ed.gold : Ed.text3)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(isOn && enabled ? Ed.goldSoft : Ed.well))
                        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(isOn && enabled ? Ed.gold.opacity(0.25) : Ed.line))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.label, .medium)).foregroundStyle(enabled ? Ed.text : Ed.text3)
                            if let expanded {
                                Image(systemName: "chevron.right")
                                    .font(Ed.icon(Ed.TypeSize.tiny, .semibold))
                                    .foregroundStyle(hover || expanded ? Ed.text2 : Ed.text3)
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                        }
                        Text(verbatim: loc(detail))
                            .font(Ed.ui(Ed.TypeSize.small))
                            .foregroundStyle(warning ? Ed.warn : Ed.text3)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        accessory
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled && expanded == nil)
            trailing
            RSwitch(isOn: $isOn, label: title)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        }
        .padding(.horizontal, Ed.Space.m)
        .padding(.vertical, 10)
        .background(expanded == true ? Ed.raised.opacity(0.55) : (hover ? Ed.hover.opacity(0.35) : .clear))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityElement(children: .contain)
    }

    private func toggle() {
        guard enabled else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() }
    }
}

extension RSwitchRow where Accessory == EmptyView, Trailing == EmptyView {
    init(symbol: String, title: String, detail: String, isOn: Binding<Bool>, enabled: Bool = true, warning: Bool = false,
         expanded: Bool? = nil, onOpen: @escaping () -> Void = {}) {
        self.init(symbol: symbol, title: title, detail: detail, isOn: isOn, enabled: enabled, warning: warning, expanded: expanded,
                  onOpen: onOpen, accessory: { EmptyView() }, trailing: { EmptyView() })
    }
}

// MARK: - Chips

/// A few options as chips. `columns` lays them out in that many equal columns (all in one row when nil); `flow` wraps
/// them at their own width (filters, sections); `stacked` draws the symbol above the title in a tall tile (the kinds of a
/// panel). The selection may be nil (no chip lit: a custom combination of switches, a search across every section).
/// `add` ends the chips with a dashed "+ …" chip that adds another option elsewhere (+ Lingua, + Tono).
struct RChips<T: Hashable>: View {
    struct Item {
        let id: T
        let title: String
        var symbol: String? = nil
        var tip: String? = nil
    }

    /// The dashed chip after the options: its title (a lookup key), its tooltip and what it opens.
    struct Add {
        let title: String
        var tip: String = ""
        let action: () -> Void
    }

    let items: [Item]
    let selection: T?
    var columns: Int? = nil
    var flow = false
    var stacked = false
    var height: CGFloat = Ed.Height.control
    var add: Add? = nil
    let onSelect: (T) -> Void

    var body: some View {
        if flow {
            FlowLayout(spacing: Ed.Space.xs, lineSpacing: Ed.Space.xs) {
                ForEach(items, id: \.id) { item in chip(item).fixedSize() }
                if let add { AddChip(add: add, height: height, flow: true).fixedSize() }
            }
        } else {
            let n = max(columns ?? items.count, 1)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: n), spacing: 6) {
                ForEach(items, id: \.id) { chip($0) }
                if let add { AddChip(add: add, height: height, flow: false) }
            }
        }
    }

    /// "+ title" on a dashed outline, no fill: it opens something, it is not an option.
    private struct AddChip: View {
        let add: Add
        let height: CGFloat
        let flow: Bool
        @State private var hover = false

        var body: some View {
            Button(action: add.action) {
                HStack(spacing: Ed.Space.xs) {
                    Image(systemName: "plus").font(Ed.icon(Ed.TypeSize.caption, .semibold))
                    Text(verbatim: loc(add.title)).font(Ed.ui(Ed.TypeSize.body, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(hover ? Ed.text : Ed.text2)
                .padding(.horizontal, flow ? 10 : 2)
                .frame(maxWidth: flow ? nil : .infinity, minHeight: height, maxHeight: height)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(hover ? Ed.hover : .clear))
                .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(Ed.text4, style: .rDashed))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .tip(add.tip)
        }
    }

    private func chip(_ item: Item) -> some View {
        Chip(item: item, on: item.id == selection, height: stacked ? 50 : height, stacked: stacked, flow: flow) { onSelect(item.id) }
            .groupTip(item.tip ?? "")
    }

    private struct Chip: View {
        let item: Item
        let on: Bool
        let height: CGFloat
        let stacked: Bool
        let flow: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { action() } }) {
                Group {
                    if stacked {
                        VStack(spacing: Ed.Space.xs) {
                            if let s = item.symbol { Image(systemName: s).font(Ed.icon(Ed.TypeSize.title)).foregroundStyle(on ? Ed.gold : Ed.text2) }
                            title
                        }
                    } else {
                        HStack(spacing: 6) {
                            if let s = item.symbol { Image(systemName: s).font(Ed.icon(Ed.TypeSize.caption, .medium)).foregroundStyle(on ? Ed.gold : Ed.text3) }
                            title
                        }
                    }
                }
                .foregroundStyle(on || hover ? Ed.text : Ed.text2)
                .padding(.horizontal, flow ? 10 : 2)
                .frame(maxWidth: flow ? nil : .infinity, minHeight: height, maxHeight: height)
                .background(RoundedRectangle(cornerRadius: stacked ? Ed.Radius.l : Ed.Radius.m).fill(on ? Ed.goldSoft : (hover ? Ed.hover : Ed.well)))
                .overlay(RoundedRectangle(cornerRadius: stacked ? Ed.Radius.l : Ed.Radius.m).strokeBorder(on ? Ed.gold.opacity(0.6) : Ed.line2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityAddTraits(on ? .isSelected : [])
        }

        private var title: some View {
            Text(verbatim: loc(item.title)).font(Ed.ui(stacked ? Ed.TypeSize.small : Ed.TypeSize.body, .medium)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

extension StrokeStyle {
    /// The dashed outline of something still to add (RChips' add chip, a tone not recorded yet).
    static let rDashed = StrokeStyle(lineWidth: 1, dash: [4, 3])
}

// MARK: - Choice list

/// Choices in a list, the current one checked (devices, screens, windows): the content of a row's disclosure.
struct RChoiceList<T: Hashable>: View {
    struct Item {
        let id: T
        let title: String
        var subtitle: String? = nil
        var symbol: String? = nil
    }

    let items: [Item]
    let selection: T?
    var empty: String = ""
    let onSelect: (T) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if items.isEmpty, !empty.isEmpty {
                Text(verbatim: loc(empty)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).padding(.vertical, 6).padding(.horizontal, Ed.Space.s)
            }
            ForEach(items, id: \.id) { item in
                let on = item.id == selection
                PickRow(title: item.title, detail: item.subtitle, selected: on, compact: true) {
                    if let s = item.symbol { RowGlyph(symbol: s, on: on) }
                } action: { onSelect(item.id) }
            }
        }
    }
}

// MARK: - Text field and editor

/// The one single-line field, on a recessed well, its border in the accent while it has the focus. A search field gives
/// it a leading `symbol` (magnifyingglass) and `clearable` (an × that empties it).
struct RTextField: View {
    var placeholder: String = ""
    @Binding var text: String
    var symbol: String? = nil
    var clearable = false
    var mono = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.text3) }
            ZStack(alignment: .leading) {
                if text.isEmpty, !placeholder.isEmpty {
                    Text(verbatim: loc(placeholder)).font(font).foregroundStyle(Ed.text3).lineLimit(1).allowsHitTesting(false)
                }
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(Ed.text)
                    .focused($focused)
                    .accessibilityLabel(loc(placeholder))
            }
            if clearable, !text.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: "Cancella la ricerca", size: 18) { text = "" }
            }
        }
        .padding(.horizontal, Ed.Space.s)
        .frame(height: Ed.Height.control)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.well))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(focused ? Ed.gold.opacity(0.7) : Ed.line2))
    }

    private var font: Font { mono ? Ed.mono(Ed.TypeSize.body) : Ed.ui(Ed.TypeSize.body) }
}

/// The one multi-line editor, on the same well as the field. `.grows(lines)` grows with the text between those line
/// counts (Invio runs `onSubmit` when given, ⌥Invio adds a line); `.scrolls(min, max)` keeps a height and scrolls a long
/// text inside (a script, a voice-over), optionally reporting the selection. `editing` keeps the accent border on (a
/// text edited in place); `focusOnAppear` puts the cursor in it when it appears; `mono` writes in SF Mono (a Markdown
/// file); `onBlur` runs when the cursor leaves it (a text saved on leaving).
struct RTextEditor: View {
    enum Kind { case grows(ClosedRange<Int>), scrolls(min: CGFloat, max: CGFloat) }

    var placeholder: String = ""
    @Binding var text: String
    var kind: Kind = .grows(3...6)
    var size: CGFloat = Ed.TypeSize.body
    var selection: Binding<TextSelection?>? = nil
    var editing = false
    var focusOnAppear = false
    var mono = false
    var onSubmit: (() -> Void)? = nil
    var onExit: (() -> Void)? = nil
    var onBlur: (() -> Void)? = nil

    @FocusState private var focused: Bool

    private var font: Font { mono ? Ed.mono(size) : Ed.ui(size) }

    var body: some View {
        content
            .focused($focused)
            .onChange(of: focused) { if !focused { onBlur?() } }
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.well))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(focused || editing ? Ed.gold.opacity(0.7) : Ed.line2))
            .onExitCommand { onExit?(); focused = false }
            .onAppear { if focusOnAppear { focused = true } }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .grows(let lines):
            ZStack(alignment: .topLeading) {
                if text.isEmpty, !placeholder.isEmpty { placeholderText }
                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).font(font).foregroundStyle(Ed.text)
                    .lineLimit(lines)
                    .onSubmit { onSubmit?() }
                    .accessibilityLabel(loc(placeholder))
            }
            .padding(Ed.Space.s)
        case .scrolls(let minH, let maxH):
            ZStack(alignment: .topLeading) {
                Group {
                    if let selection { TextEditor(text: $text, selection: selection) } else { TextEditor(text: $text) }
                }
                .font(font).foregroundStyle(Ed.text)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 3).padding(.vertical, Ed.Space.s)
                .accessibilityLabel(loc(placeholder))
                if text.isEmpty, !placeholder.isEmpty { placeholderText.padding(Ed.Space.s) }
            }
            .frame(minHeight: minH, maxHeight: maxH)
        }
    }

    private var placeholderText: some View {
        Text(verbatim: loc(placeholder)).font(font).foregroundStyle(Ed.text3)
            .fixedSize(horizontal: false, vertical: true).allowsHitTesting(false)
    }
}

/// A value in mono that becomes a field on click; Invio commits, Esc gives up (the Ispettore's numbers and timecodes).
struct InspectorValueField: View {
    let text: String
    var width: CGFloat = 78
    var alignment: TextAlignment = .trailing
    let onCommit: (String) -> Void
    @State private var draft = ""
    @State private var editing = false
    @State private var hover = false
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Ed.mono(Ed.TypeSize.body))
                    .multilineTextAlignment(alignment)
                    .foregroundStyle(Ed.text)
                    .focused($focused)
                    .onSubmit { editing = false; onCommit(draft) }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { if !focused { editing = false } }
                    .onAppear { focused = true }
            } else {
                Text(verbatim: text).font(Ed.mono(Ed.TypeSize.body)).foregroundStyle(hover ? Ed.text : Ed.text2)
                    .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { draft = text; editing = true }
            }
        }
        .padding(.horizontal, 5)
        .frame(width: width, height: 20)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(editing ? Ed.well : (hover ? Ed.control : .clear)))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(editing ? Ed.gold.opacity(0.7) : .clear))
        .onHover { hover = $0 }
        .tip("Clicca per scrivere il valore")
        // The tooltip is its name; what it shows is its value (VoiceOver reads both).
        .accessibilityValue(Text(verbatim: editing ? draft : text))
    }
}

// MARK: - Level meter

/// A level in segments, 0…1: calm up to −12 dB, the accent to −3 dB, red above (a voice should peak in the accent).
struct RLevelMeter: View {
    let value: Double
    var segments = 24
    var height: CGFloat = 5
    var spacing: CGFloat = 2

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<segments, id: \.self) { i in
                let at = Double(i + 1) / Double(segments)
                RoundedRectangle(cornerRadius: min(height / 2, 1.5))
                    .fill(at <= value ? color(at) : Ed.raised)
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.06), value: value)
        .accessibilityElement()
        .accessibilityValue(String(format: "%.0f dB", value * 60 - 60))
    }

    private func color(_ at: Double) -> Color {
        if at > 0.95 { return Ed.danger }
        if at > 0.8 { return Ed.gold }
        return Ed.ok.opacity(0.85)
    }
}

// MARK: - Colour swatch

/// A colour by role: a round swatch with the role underneath. Click (or Space) opens the system colour panel,
/// which edits this colour until another swatch takes it.
struct ColorSwatch: View {
    let role: String
    @Binding var hex: String
    var size: CGFloat = 34
    var caption: String? = nil

    @FocusState private var focused: Bool
    @State private var hover = false

    var body: some View {
        Button { ColorPanelBridge.shared.edit(hex: hex) { hex = $0 } } label: {
            VStack(spacing: 5) {
                Circle()
                    .fill(Color(hexString: hex))
                    .frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
                    .overlay(Circle().strokeBorder(Ed.gold.opacity(focused ? 1 : 0), lineWidth: 2).padding(-4))
                    .shadow(color: Color(hexString: hex).opacity(hover ? 0.55 : 0.25), radius: hover ? 6 : 3, y: 1)
                    .scaleEffect(hover ? 1.06 : 1)
                Text(verbatim: loc(caption ?? role)).font(Ed.ui(Ed.TypeSize.micro, .medium)).foregroundStyle(Ed.text2).lineLimit(1)
                Text(verbatim: hex.uppercased()).font(Ed.mono(Ed.TypeSize.tiny)).foregroundStyle(Ed.text3)
            }
            .frame(width: size + 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel("\(loc(caption ?? role)) \(hex)")
        .tip(loc("Cambia %@", loc(caption ?? role)))
    }
}

/// The shared NSColorPanel, pointed at one swatch at a time.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((String) -> Void)?

    func edit(hex: String, onChange: @escaping (String) -> Void) {
        self.onChange = nil
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = NSColor(Color(hexString: hex))
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()),
                         Int((c.blueComponent * 255).rounded())))
    }
}

// MARK: - A column that continues

/// A scrolling column of the left panel with a fixed footer or a fixed edge says that it continues (#54): while content is
/// hidden below, a short fade of the panel's colour over the last 16 pt above the edge; gone once the column is scrolled
/// to its end. The fade never takes a click: a control under it still answers. (Accessible as "Altro sotto", so a test
/// and VoiceOver can tell it is there.)
struct ContinuesCue: ViewModifier {
    var color: Color
    @State private var below = false
    static let height: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { g in g.visibleRect.maxY < g.contentSize.height - 1 } action: { _, now in below = now }
            .overlay(alignment: .bottom) {
                if below {
                    LinearGradient(colors: [color.opacity(0), color], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.height)
                        .allowsHitTesting(false)
                        .accessibilityElement()
                        .accessibilityLabel(loc("Altro sotto"))
                }
            }
    }
}

extension View {
    /// The cue of a column that continues below a fixed footer or edge (`ContinuesCue`), in the panel's colour.
    func continuesCue(_ color: Color = Ed.side) -> some View { modifier(ContinuesCue(color: color)) }
}

// MARK: - Sections, tags, cards

/// A section's small title: spaced capitals in the tertiary grey (shell A's "MEDIA", "INQUADRATURA").
struct SectionLabel: View {
    let title: String
    var tint: Color = Ed.text3
    init(_ title: String, tint: Color = Ed.text3) { self.title = title; self.tint = tint }
    var body: some View {
        Text(verbatim: loc(title).uppercased(with: Locale.current)).font(Ed.ui(Ed.TypeSize.small, .semibold)).tracking(0.6).foregroundStyle(tint).lineLimit(1)
    }
}

/// A section of a panel: its label (none when the title is empty), then the content — controls 10 pt apart, or `rows`
/// (a list: rows 2 pt apart, 6 pt under the label).
struct RSection<Content: View>: View {
    let title: String
    var rows = false
    @ViewBuilder var content: Content

    init(_ title: String, rows: Bool = false, @ViewBuilder content: () -> Content) {
        self.title = title
        self.rows = rows
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: rows ? Ed.Space.xxs : 10) {
            if !title.isEmpty { SectionLabel(title).padding(.bottom, rows ? Ed.Space.xs : 0) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small word beside a title ("Prossimo", "a pagamento", "facoltativo").
struct RTag: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(verbatim: loc(text)).font(Ed.ui(Ed.TypeSize.micro, .semibold)).foregroundStyle(Ed.text2).lineLimit(1).fixedSize()
            .padding(.horizontal, 5).frame(height: 15)
            .background(Capsule().fill(Ed.control))
    }
}

/// An inline card's surface: `raised` for forms, jobs and approvals, `well` (recessed) for summaries and notes.
enum CardTone { case raised, well }

extension View {
    /// An inline card: the tone's fill, a hairline edge (`border` replaces its colour: a running job, a paid approval),
    /// the card radius and `padding` inside.
    func rCard(_ tone: CardTone = .raised, border: Color? = nil, padding: CGFloat = Ed.Space.m) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(tone == .raised ? Ed.header : Ed.well))
            .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).strokeBorder(border ?? (tone == .raised ? Ed.line2 : Ed.line)))
    }
}

/// A step's state as a glyph: a number to do, a check done, a dash not needed, a warning unavailable, a turning arrow out
/// of date, a spinner running, a dim number blocked (Semplice and Testi e sottotitoli › Passi).
struct StateGlyph: View {
    /// The states of SimpleState and StepState share these names (their raw values): `StateGlyph(status.rawValue, …)`.
    enum Kind: String { case todo, done, running, blocked, stale, notNeeded, unavailable }
    let state: Kind
    let number: Int
    var size: CGFloat = 22

    init(_ status: String, number: Int, size: CGFloat = 22) {
        self.state = Kind(rawValue: status) ?? .todo
        self.number = number
        self.size = size
    }

    var body: some View {
        ZStack {
            switch state {
            case .done:
                Circle().fill(Ed.ok.opacity(0.18))
                mark("checkmark", Ed.ok)
            case .notNeeded:
                Circle().strokeBorder(Ed.line2, lineWidth: 1)
                mark("minus", Ed.text3)
            case .unavailable:
                Circle().strokeBorder(Ed.warn.opacity(0.7), lineWidth: 1.2)
                mark("exclamationmark", Ed.warn)
            case .stale:
                Circle().strokeBorder(Ed.warn, lineWidth: 1.2)
                mark("arrow.clockwise", Ed.warn)
            case .running:
                Circle().strokeBorder(Ed.line2, lineWidth: 1.2)
                Spinner()
                Circle().fill(Ed.gold).frame(width: 5, height: 5)
            case .blocked:
                Circle().strokeBorder(Ed.line2, lineWidth: 1)
                Text(verbatim: "\(number)").font(Ed.mono(Ed.TypeSize.caption, .medium)).foregroundStyle(Ed.text4)
            case .todo:
                Circle().strokeBorder(Ed.text3, lineWidth: 1.2)
                Text(verbatim: "\(number)").font(Ed.mono(Ed.TypeSize.caption, .semibold)).foregroundStyle(Ed.text2)
            }
        }
        .frame(width: size, height: size)
    }

    private func mark(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.micro, .bold)).foregroundStyle(tint)
    }

    /// A short arc in the accent that turns.
    private struct Spinner: View {
        @State private var turn = false
        var body: some View {
            Circle().trim(from: 0, to: 0.3).stroke(Ed.gold, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).padding(0.8)
                .rotationEffect(.degrees(turn ? 270 : -90))
                .onAppear { withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { turn = true } }
        }
    }
}

/// Why something cannot run now, in words (a lock, or a warning in amber when an engine or a setting is missing), and the
/// way on under it: a button to the step before, Importa…, Installa….
struct ReasonNote<Actions: View>: View {
    let text: String
    var warning = false
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: warning ? "exclamationmark.triangle" : "lock").font(Ed.icon(Ed.TypeSize.caption))
                    .foregroundStyle(warning ? Ed.warn : Ed.text3)
                Text(verbatim: loc(text)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
            }
            actions
        }
        .rCard(.well)
    }
}

/// A state of a panel: an icon, a title, what it means and what to do, then the actions.
struct StateCard<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.m) {
            Image(systemName: symbol)
                .font(Ed.icon(Ed.TypeSize.title, .light))
                .foregroundStyle(Ed.gold)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Ed.goldSoft))
                .overlay(Circle().strokeBorder(Ed.gold.opacity(0.25)))
            Text(verbatim: loc(title)).font(Ed.display(Ed.TypeSize.heading, .medium)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
            Text(verbatim: loc(text)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            actions
        }
        .rCard(.raised, padding: Ed.Space.l)
    }
}

extension StateCard where Actions == EmptyView {
    init(symbol: String, title: String, text: String) {
        self.init(symbol: symbol, title: title, text: text) { EmptyView() }
    }
}

// MARK: - Rows

/// One row of a side list: symbol, title, a dim detail on the right (a shortcut, a duration); `on` marks the open one.
struct SideRow: View {
    let symbol: String
    let title: String
    var detail: String? = nil
    var on = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Ed.Space.s) {
                RowGlyph(symbol: symbol, on: on)
                Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.control)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: Ed.Space.xs)
                if let detail { Text(verbatim: detail).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text4).fixedSize() }
            }
            .padding(.horizontal, Ed.Space.s)
            .frame(height: Ed.Height.row)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m, style: .continuous).fill(on ? Ed.control : (hover ? Ed.control.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// A row to pick from (a catalog item, a provider, a still, a device): the leading part (RowThumb, RowGlyph or
/// RadioMark), the title (with an optional tag), one dim line — or, greyed and disabled, the reason in amber — and a mark
/// on the right. `link` adds an action under the text (Installa…, Usa di nuovo), outside the row's own click.
struct PickRow<Leading: View>: View {
    /// What the right edge shows: a check when selected; a + (applies) or a chevron (opens a form) on hover; nothing.
    enum Mark { case check, add, opens, none }

    let title: String
    var detail: String? = nil
    var reason: String? = nil
    var tag: String? = nil
    var selected = false
    var mark: Mark = .check
    /// One line for the title, the detail on up to two: lists of devices and windows.
    var compact = false
    var link: RowLink? = nil
    @ViewBuilder var leading: Leading
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let enabled = reason == nil
        VStack(alignment: .leading, spacing: Ed.Space.xxs) {
            Button(action: action) {
                HStack(alignment: .center, spacing: 10) {
                    leading.opacity(enabled ? 1 : 0.5)
                    VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                        HStack(spacing: 6) {
                            Text(verbatim: loc(title)).font(Ed.ui(compact ? Ed.TypeSize.body : Ed.TypeSize.control, .medium))
                                .foregroundStyle(enabled ? Ed.text : Ed.text3).lineLimit(compact ? 1 : 2).truncationMode(.middle)
                            if let tag { RTag(tag) }
                        }
                        if let line = reason ?? detail {
                            Text(verbatim: loc(line)).font(Ed.ui(compact ? Ed.TypeSize.caption : Ed.TypeSize.small))
                                .foregroundStyle(enabled ? Ed.text3 : Ed.warn)
                                .lineLimit(compact ? 1 : 3).truncationMode(.middle).fixedSize(horizontal: false, vertical: !compact)
                        }
                    }
                    Spacer(minLength: Ed.Space.xs)
                    markView(enabled: enabled)
                }
                .padding(.horizontal, Ed.Space.s).padding(.vertical, compact ? 4 : 6)
                .frame(minHeight: Ed.Height.row)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(selected ? Ed.goldSoft : (hover && enabled ? Ed.hover.opacity(0.6) : .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .onHover { hover = $0 }
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let link {
                HStack(spacing: 10) {
                    leading.hidden().frame(height: 1)
                    AccentLinkButton(title: link.title, tip: link.tip, action: link.action)
                }
                .padding(.horizontal, Ed.Space.s).padding(.bottom, Ed.Space.xs)
            }
        }
    }

    @ViewBuilder private func markView(enabled: Bool) -> some View {
        switch mark {
        case .none: EmptyView()
        case .check:
            Image(systemName: "checkmark").font(Ed.icon(Ed.TypeSize.caption, .semibold)).foregroundStyle(Ed.gold).opacity(selected ? 1 : 0)
        case .add, .opens:
            Image(systemName: selected ? "checkmark" : (mark == .opens ? "chevron.down" : "plus"))
                .font(Ed.icon(Ed.TypeSize.caption, .semibold))
                .foregroundStyle(selected ? Ed.gold : Ed.text3)
                .opacity(selected || (hover && enabled) ? 1 : 0)
        }
    }
}

extension PickRow where Leading == EmptyView {
    init(title: String, detail: String? = nil, reason: String? = nil, tag: String? = nil, selected: Bool = false, mark: Mark = .check,
         compact: Bool = false, link: RowLink? = nil, action: @escaping () -> Void) {
        self.init(title: title, detail: detail, reason: reason, tag: tag, selected: selected, mark: mark, compact: compact, link: link,
                  leading: { EmptyView() }, action: action)
    }
}

/// An action under a row's text, outside the row's own click (Installa…, Usa di nuovo, Trova il volto).
struct RowLink {
    let title: String
    var tip: String = ""
    let action: () -> Void
}

/// A row's leading symbol, in the accent when the row is the chosen one.
struct RowGlyph: View {
    let symbol: String
    var on = false
    var body: some View {
        Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.body)).foregroundStyle(on ? Ed.gold : Ed.text3).frame(width: 18)
    }
}

/// A row's thumbnail: the content on a recessed well, clipped, with an accent edge when the row is the chosen one.
struct RowThumb<Content: View>: View {
    var width: CGFloat = 36
    var height: CGFloat = 36
    var selected = false
    @ViewBuilder var content: Content

    var body: some View {
        ZStack { Ed.well; content }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(selected ? Ed.gold : Ed.line2, lineWidth: selected ? 1.5 : 1))
    }
}

/// A radio mark: one of several, the chosen one filled in the accent.
struct RadioMark: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Ed.gold : Ed.text4, lineWidth: 1.2).frame(width: 14, height: 14)
            if on { Circle().fill(Ed.gold).frame(width: 7, height: 7) }
        }
        .frame(width: 16)
    }
}

// MARK: - Panels and tabs

/// A panel title strip with optional trailing content.
struct PanelHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Shown in place of the title (a monitor's Sorgente / Programma switch, #49).
    var lead: AnyView? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Ed.Space.s) {
            // The title and the trailing controls stay whole; the subtitle shortens first.
            if let lead { lead } else {
                Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text).lineLimit(1).fixedSize()
            }
            if let subtitle {
                Text(verbatim: loc(subtitle)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Ed.Space.xs)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: Ed.Height.row)
        .background(Ed.header)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, lead: AnyView? = nil) {
        self.init(title: title, subtitle: subtitle, lead: lead) { EmptyView() }
    }
}

/// Underlined text tabs (panel tab bars).
struct TabStrip<T: Hashable>: View {
    let items: [(T, String)]
    @Binding var selection: T

    var body: some View {
        // A narrow panel tightens the tabs, then scrolls them sideways, rather than truncate the names.
        ViewThatFits(in: .horizontal) {
            tabs(spacing: 14).padding(.horizontal, 10)
            tabs(spacing: 9).padding(.horizontal, 10)
            ScrollView(.horizontal, showsIndicators: false) { tabs(spacing: 9).padding(.horizontal, 10) }
        }
        .frame(height: Ed.Height.row)
        .background(Ed.header)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }

    private func tabs(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            ForEach(items, id: \.0) { item in
                Button { selection = item.0 } label: {
                    Text(verbatim: loc(item.1))
                        .font(Ed.ui(Ed.TypeSize.small, .medium))
                        .foregroundStyle(selection == item.0 ? Ed.text : Ed.text3)
                        .fixedSize()
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selection == item.0 ? Ed.gold : .clear).frame(height: 1.5)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Centered hint for empty panels.
struct EmptyHint: View {
    let symbol: String
    let text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.large, .light)).foregroundStyle(Ed.text3)
            Text(verbatim: loc(text)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).multilineTextAlignment(.center).frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Buttons

/// The text buttons' look, for EdButton and for the few labels that are not a plain Button (a SettingsLink, a menu):
/// secondary (raised, a hairline edge), primary (the accent: a panel's one main action), quiet (no frame until hovered),
/// destructive (red: record, delete). Pressed darkens a step; disabled fades to 40 %.
struct EdButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet, destructive }
    var kind: Kind = .secondary
    var large = false
    var fill = false
    /// The symbol above the title, which may take two lines (a narrow column: the Semplice level's compact rail).
    var stacked = false

    func makeBody(configuration: Configuration) -> some View {
        Look(configuration: configuration, kind: kind, large: large, fill: fill, stacked: stacked)
    }

    private struct Look: View {
        let configuration: Configuration
        let kind: Kind
        let large: Bool
        let fill: Bool
        let stacked: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hover = false

        var body: some View {
            let radius = large ? Ed.Radius.l : Ed.Radius.m
            configuration.label
                .font(stacked ? Ed.ui(Ed.TypeSize.caption, .semibold) : Ed.ui(large ? Ed.TypeSize.control : Ed.TypeSize.body, large ? .semibold : .medium))
                .foregroundStyle(kind == .destructive ? .white : (kind == .primary ? Accent.on : (kind == .quiet && !hover ? Ed.text2 : Ed.text)))
                .padding(.horizontal, stacked ? Ed.Space.xs : (large ? Ed.Space.l : 10))
                .padding(.vertical, stacked ? 6 : 0)
                .frame(maxWidth: fill ? .infinity : nil)
                .frame(minHeight: stacked ? Ed.Height.large : nil)
                .frame(height: stacked ? nil : (large ? Ed.Height.large : Ed.Height.control))
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fillColor))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(kind == .secondary ? Ed.line2 : .clear))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover = $0 && enabled }
        }

        private var fillColor: Color {
            let pressed = configuration.isPressed
            switch kind {
            case .destructive: return Ed.danger.opacity(pressed ? 0.75 : (hover ? 1 : 0.9))
            case .primary: return Ed.gold.opacity(pressed ? 0.78 : (hover ? 1 : 0.92))
            case .secondary: return pressed ? Ed.controlOn : (hover ? Ed.hover : Ed.raised)
            case .quiet: return pressed ? Ed.controlOn : (hover ? Ed.control : .clear)
            }
        }
    }
}

/// A text button (EdButtonStyle): secondary by default, `prominent` for the one primary action of a panel, `quiet` for a
/// frameless one (Annulla beside a primary, a toolbar text), `destructive` in red. `large` is the size of a screen's main
/// action; `fill` stretches it to the available width; `stacked` puts the symbol above a title of up to two lines (a
/// narrow column).
struct EdButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var destructive = false
    var quiet = false
    var large = false
    var fill = false
    var disabled = false
    var stacked = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if stacked {
                VStack(spacing: 3) {
                    if let symbol { Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.body, .semibold)) }
                    Text(verbatim: loc(title)).multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: large ? Ed.Space.s : 6) {
                    if let symbol { Image(systemName: symbol).font(Ed.icon(large ? Ed.TypeSize.body : Ed.TypeSize.caption, .semibold)) }
                    Text(verbatim: loc(title)).lineLimit(1).minimumScaleFactor(0.75)
                }
            }
        }
        .buttonStyle(EdButtonStyle(kind: destructive ? .destructive : (prominent ? .primary : (quiet ? .quiet : .secondary)), large: large, fill: fill,
                                   stacked: stacked))
        .disabled(disabled)
    }
}

/// A quiet link in the accent ("Importa…", "Installa…", "Altri filtri in Pro").
struct AccentLinkButton: View {
    let title: String
    var tip: String = ""
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.gold.opacity(hover ? 1 : 0.85))
                .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip(tip, shortcut: shortcut)
    }
}

/// A square icon button with a fast tooltip (`tip`) naming the function and its shortcut. `active` lights it in the
/// accent (a mode that is on); `chrome` is the title row's and the toolbar's size (the panel toggles, undo / redo), where
/// `dimmed` says the panel it toggles is hidden.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var shortcut: String? = nil
    var active = false
    var size: CGFloat = Ed.Height.icon
    var tint: Color? = nil
    var chrome = false
    var dimmed = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let lit = hover && enabled
        Button(action: action) {
            Image(systemName: symbol)
                .font(Ed.icon(chrome ? Ed.TypeSize.title : size * 0.5, chrome ? .regular : .medium))
                .foregroundStyle(tint ?? (active ? Ed.gold : (lit ? Ed.text : (dimmed ? Ed.text3 : Ed.text2))))
                .frame(width: chrome ? 28 : size, height: chrome ? 24 : size)
                .background(RoundedRectangle(cornerRadius: chrome ? Ed.Radius.m : Ed.Radius.s, style: .continuous)
                    .fill(active ? Ed.goldSoft : (lit ? (chrome ? Ed.control : Ed.hover) : .clear)))
                .contentShape(Rectangle())
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip(help, shortcut: shortcut)
        .accessibilityLabel(Text(verbatim: loc(help)))
    }
}
