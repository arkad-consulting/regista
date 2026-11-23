import RegistaCore
import SwiftUI

/// The output formats as one compact menu (the toolbar's format label, Registra's «Formato del video»): the label as it
/// reads, a small chevron; a click opens the short list, the current one checked, and a choice calls `pick` and closes
/// it. Chosen about once per video: it stays a label, with no panel of its own.
struct FormatMenu: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        var detail: String? = nil
        var symbol: String = "rectangle"
    }

    /// The label's text ("Formato 9:16 · 1080×1920 · 30 fps").
    let label: String
    let items: [Item]
    let selected: String?
    let tip: String
    /// The whole label (false: cut to the width left, the toolbar's narrow fallback).
    var whole = true
    var font: Font = Ed.ui(Ed.TypeSize.body)
    /// A symbol before the label (Registra's menu, where no word says «format»).
    var symbol: String? = nil
    /// The label's height (the toolbar's controls: 24; a line of text: 18).
    var height: CGFloat = 24
    /// The text drawn when it is not the label itself ("": the symbol alone); the label stays the control's value.
    var display: String? = nil
    let pick: (String) -> Void
    @Environment(\.navOverride) private var navOverride
    @State private var open = false
    @State private var hover = false

    /// The four presets of `ExportPreset`, with their size and the drawing of their shape.
    static func presets() -> [Item] {
        ExportPreset.all.map { p in
            Item(id: p.id, title: p.id, detail: "\(p.width)×\(p.height)", symbol: symbol(p.id))
        }
    }

    static func symbol(_ id: String) -> String {
        switch id {
        case "9:16", "4:5": "rectangle.portrait"
        case "1:1": "square"
        default: "rectangle"
        }
    }

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(hover || open ? Ed.text2 : Ed.text3) }
                if display != "" { Text(verbatim: display ?? label).font(font).foregroundStyle(hover || open ? Ed.text : Ed.text3).lineLimit(1)
                    .fixedSize(horizontal: whole, vertical: false) }
                Image(systemName: "chevron.down").font(Ed.icon(Ed.TypeSize.tiny, .semibold)).foregroundStyle(hover || open ? Ed.text2 : Ed.text4)
            }
            .padding(.horizontal, Ed.Space.s)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m, style: .continuous).fill(hover || open ? Ed.control : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip(tip)
        .accessibilityValue(Text(verbatim: label))
        // Only the live window opens it: an offscreen render has no popover.
        .popover(isPresented: Binding(get: { navOverride == nil && open }, set: { open = $0 }), arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    PickRow(title: item.title, detail: item.detail, selected: item.id == selected, compact: true, leading: {
                        RowGlyph(symbol: item.symbol, on: item.id == selected)
                    }) {
                        open = false
                        if item.id != selected { pick(item.id) }
                    }
                }
            }
            .padding(Ed.Space.s)
            .frame(width: 230)
            .background(Ed.side)
            .environment(\.colorScheme, .dark)
        }
    }
}
