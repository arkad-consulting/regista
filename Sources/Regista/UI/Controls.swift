import AppKit
import RegistaCore
import SwiftUI

// Regista controls (issue #17): a small design system that replaces the stock macOS widgets in the editor,
// after the ease of Apple's and Instagram's edit tools — a thin gradient track with a value bubble, sliding
// segmented bars, an intensity bar (poco ↔ tanto), a capsule toggle, colour swatches backed by the system colour
// panel, and timeline clip colours by type. All of them take keyboard focus (visible ring) and arrow keys.
//
//   RSlider        value + range, gradient track, bubble while dragging/hovering/focused, onCommit at release
//   RSegmented     2–6 options in a bar, the selection slides
//   IntensityBar   0…1 in steps, rising bars between two words ("poco" / "tanto")
//   RToggle        capsule switch with label (RSwitch: the switch alone)
//   RSwitchRow     a row with icon, name, current choice and its own switch; the row itself opens its choices
//   RChips         a few options as chips in a grid; the selection may be none (a custom combination)
//   RChoiceList    a list of choices with a check (devices, screens, windows)
//   RTextField     a one-line field
//   RLevelMeter    a segmented level (microphone)
//   ColorSwatch    a colour by role; click = system colour panel
//   Accent         the editor accent: Arkad gold, or the active brand kit's (optional, contrast-checked)
//   SectionLabel   a section's small title (shell A: SF 11 semibold, spaced capitals); InspectorSection = label + content
//   PanelHeader, TabStrip, IconButton, EdButton, AccentLinkButton, EmptyHint: panels, tabs and the one button family
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
    var height: CGFloat = 26
    var fill = true
    var tips: [T: String] = [:]
    var shortcuts: [T: String] = [:]
    var disabled: Set<T> = []

    @Namespace private var ns
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items, id: \.0) { item in
                let on = item.0 == selection
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selection = item.0 }
                } label: {
                    HStack(spacing: 5) {
                        if let s = symbols[item.0] { Image(systemName: s).font(Ed.icon(Ed.TypeSize.caption, .semibold)) }
                        if !item.1.isEmpty { Text(verbatim: loc(item.1)).font(Ed.ui(Ed.TypeSize.body, .medium)).lineLimit(1).minimumScaleFactor(0.7) }
                    }
                    .foregroundStyle(on ? Ed.text : Ed.text3)
                    .padding(.horizontal, fill ? 2 : 12)
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
        .padding(Ed.Space.xxs)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(Ed.control))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .rFocusRing(focused, radius: 7)
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            guard let i = items.firstIndex(where: { $0.0 == selection }) else { return .ignored }
            let j = min(max(i + (press.key == .leftArrow ? -1 : 1), 0), items.count - 1)
            guard !disabled.contains(items[j].0) else { return .handled }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { selection = items[j].0 }
            return .handled
        }
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

/// A few options as chips laid out in `columns` equal columns. The selection may be nil (no chip lit: e.g. a custom
/// combination of switches that matches no preset).
struct RChips<T: Hashable>: View {
    struct Item {
        let id: T
        let title: String
        var symbol: String? = nil
    }

    let items: [Item]
    let selection: T?
    var columns: Int? = nil
    var height: CGFloat = 30
    let onSelect: (T) -> Void

    var body: some View {
        let n = max(columns ?? items.count, 1)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: n), spacing: 6) {
            ForEach(items, id: \.id) { item in Chip(item: item, on: item.id == selection, height: height) { onSelect(item.id) } }
        }
    }

    private struct Chip: View {
        let item: Item
        let on: Bool
        let height: CGFloat
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: { withAnimation(.easeOut(duration: 0.15)) { action() } }) {
                HStack(spacing: 6) {
                    if let s = item.symbol { Image(systemName: s).font(Ed.icon(Ed.TypeSize.caption, .medium)).foregroundStyle(on ? Ed.gold : Ed.text3) }
                    Text(verbatim: loc(item.title)).font(Ed.ui(Ed.TypeSize.small, .medium)).lineLimit(1).minimumScaleFactor(0.8)
                }
                .foregroundStyle(on ? Ed.text : (hover ? Ed.text : Ed.text2))
                .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(on ? Ed.goldSoft : (hover ? Ed.hover : Ed.well)))
                .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(on ? Ed.gold.opacity(0.6) : Ed.line2))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
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
            ForEach(items, id: \.id) { item in Row(item: item, on: item.id == selection) { onSelect(item.id) } }
        }
    }

    private struct Row: View {
        let item: Item
        let on: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: Ed.Space.s) {
                    if let s = item.symbol {
                        Image(systemName: s).font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(on ? Ed.gold : Ed.text3).frame(width: 16)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: loc(item.title)).font(Ed.ui(Ed.TypeSize.small + 0.5)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
                        if let sub = item.subtitle {
                            Text(verbatim: loc(sub)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: Ed.Space.xs)
                    Image(systemName: "checkmark").font(Ed.icon(Ed.TypeSize.micro, .bold)).foregroundStyle(on ? Ed.gold : .clear)
                }
                .padding(.horizontal, Ed.Space.s)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.s + 1).fill(hover ? Ed.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

// MARK: - Text field

/// A one-line text field on a recessed well.
struct RTextField: View {
    var placeholder: String = ""
    @Binding var text: String
    var mono = false

    @FocusState private var focused: Bool

    var body: some View {
        TextField(loc(placeholder), text: $text)
            .textFieldStyle(.plain)
            .font(mono ? Ed.mono(Ed.TypeSize.small) : Ed.ui(Ed.TypeSize.body))
            .foregroundStyle(Ed.text)
            .focused($focused)
            .padding(.horizontal, Ed.Space.s)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.well))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.m).strokeBorder(focused ? Ed.gold.opacity(0.7) : Ed.line2))
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

// MARK: - Small pieces

/// A section's small title: spaced capitals in the tertiary grey (shell A's "MEDIA", "INQUADRATURA").
struct SectionLabel: View {
    let title: String
    var tint: Color = Ed.text3
    init(_ title: String, tint: Color = Ed.text3) { self.title = title; self.tint = tint }
    var body: some View {
        Text(verbatim: loc(title).uppercased(with: Locale.current)).font(Ed.ui(Ed.TypeSize.small, .semibold)).tracking(0.6).foregroundStyle(tint).lineLimit(1)
    }
}

/// A section in the inspectors and panels: its label, then the content.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title)
            content
        }
    }
}

// MARK: - Panels, tabs and buttons

/// A panel title strip with optional trailing content.
struct PanelHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Ed.Space.s) {
            Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text)
            if let subtitle {
                Text(verbatim: loc(subtitle)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: Ed.Space.xs)
            trailing
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Ed.header)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }
}

extension PanelHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
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
        .frame(height: 28)
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

/// Small square icon button, with a fast tooltip (`tip`) naming the function and its shortcut.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var shortcut: String? = nil
    var active = false
    var size: CGFloat = 22
    var tint: Color? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Ed.icon(size * 0.5, .medium))
                .foregroundStyle(tint ?? (active ? Ed.gold : (hover ? Ed.text : Ed.text2)))
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(active ? Ed.goldSoft : (hover ? Ed.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip(help, shortcut: shortcut)
    }
}

/// Text button in the editor style: plain, `prominent` (the accent: the screen's main action) or `destructive` (red:
/// record, delete). `large` is the size of a screen's main action; `fill` stretches it to the available width.
struct EdButton: View {
    let title: String
    var symbol: String? = nil
    var prominent = false
    var destructive = false
    var large = false
    var fill = false
    var disabled = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: large ? 8 : 6) {
                if let symbol { Image(systemName: symbol).font(Ed.icon(large ? 12 : 10, .semibold)) }
                Text(verbatim: loc(title)).font(Ed.ui(large ? Ed.TypeSize.label : Ed.TypeSize.small, large ? .semibold : .medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(destructive ? .white : (prominent ? Accent.on : Ed.text))
            .padding(.horizontal, large ? Ed.Space.l : 10)
            .frame(maxWidth: fill ? .infinity : nil)
            .frame(height: large ? 34 : 24)
            .background(RoundedRectangle(cornerRadius: large ? Ed.Radius.l : 5).fill(fillColor))
            .overlay(RoundedRectangle(cornerRadius: large ? Ed.Radius.l : 5).strokeBorder(prominent || destructive ? .clear : Ed.line2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hover = $0 }
    }

    private var fillColor: Color {
        if destructive { return Ed.danger.opacity(hover ? 1 : 0.9) }
        if prominent { return Ed.gold.opacity(hover ? 1 : 0.92) }
        return hover ? Ed.hover : Ed.raised
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

/// A text button in the accent ("Importa…").
struct AccentLinkButton: View {
    let title: String
    var tip: String = ""
    var shortcut: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.gold.opacity(hover ? 1 : 0.85))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip(tip, shortcut: shortcut)
    }
}
