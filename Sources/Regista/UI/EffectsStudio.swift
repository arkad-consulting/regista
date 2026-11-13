import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI
import UniformTypeIdentifiers

/// The effects studio (issue #16): editing a reel's look as easily as a photo. A big preview (press and hold it to
/// see the original), and under it one deck at a time — Filtri (a strip of the actual frame through each look; tap
/// again for its intensity), Regola (Photos-style tools, one scrubbable ruler each; double-click resets), Effetti
/// (the gallery: animated tiles, categories, search, one Intensità control; drag a tile onto the picture or the strip
/// of the edit) and Stili (one-click styles). Every change is one ordinary command: undo, agent log, MCP parity.
enum StudioMode: String, CaseIterable, Identifiable {
    case filters, adjust, effects, styles
    var id: String { rawValue }
    var label: String {
        switch self {
        case .filters: "Filtri"
        case .adjust: "Regola"
        case .effects: "Effetti"
        case .styles: "Stili"
        }
    }
}

/// Copy kept in one place: lookup keys (drawn through `loc`).
enum StudioText {
    static let title = "Studio"
    static let done = "button.done"
    static let wholeVideo = "Tutto il video"
    static let thisClip = "Questa clip"
    static let holdHint = "Tieni premuto sull'immagine per vedere l'originale"
    static let original = "ORIGINALE"
    static let intensity = "Intensità"
    static let little = "poco"
    static let lot = "tanto"
    static let search = "Cerca un effetto"
    static let empty = "Importa un video: gli effetti si provano sul fotogramma vero."
    static let dragHint = "Clic per applicare al punto della testina · trascina sull'immagine o sulla striscia"
    static let apply = "Applica"
    static let reset = "Doppio clic per azzerare"
}

/// Shared state of the studio deck (the tile intensity, the scope).
@MainActor
final class StudioState: ObservableObject {
    static let shared = StudioState()
    @Published var intensity = 0.5
    @Published var category: EffectsCatalog.Category = .motion
    @Published var query = ""
    /// Adjust tool in the ruler.
    @Published var tool = "exposure"
    /// While a slider moves: the value being dialled (committed on release).
    @Published var dialling: (name: String, value: Double)?
    /// The look whose intensity slider is open.
    @Published var lookOpen: String?
    @Published var flash: String?
    @Published var clipScope = false
    /// The motion template whose form is open (category templates).
    @Published var motionItem: String?
    /// The text tile whose form is open (Titolo, Etichetta): the words are typed before the title is added.
    @Published var textItem: String?
    /// The applied effect picked on the strip or in the "Qui" list (AppliedItem.id).
    @Published var appliedSelection: String?
}

struct EffectsStudio: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = StudioState.shared
    let mode: StudioMode
    @State private var holding = false
    /// Width of the tools column the user dragged (0 = automatic).
    @AppStorage("layout.studio.deck") private var deckWidth = SplitSize.automatic

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { g in
                let range = SplitSize.range(400, min(760, g.size.width - 380))
                let column = SplitSize.resolve(deckWidth, automatic: min(max(g.size.width * 0.36, 420), 560), in: range)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        picture.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Filmstrip().frame(height: 150)
                    }
                    Splitter(orientation: .vertical, stored: $deckWidth, current: column, range: range, direction: -1, thickness: 0)
                    deck.frame(width: column).frame(maxHeight: .infinity, alignment: .top)
                        .background(Ed.panel)
                        .overlay(alignment: .leading) { Ed.line.frame(width: 1) }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
        }
        .background(Ed.bg)
        .onAppear { store.previews.refresh(at: playhead.time) }
        .onChange(of: playhead.time) { store.previews.refresh(at: playhead.time) }
        .onChange(of: store.project) { store.previews.refresh(at: playhead.time) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 18) {
            Text(verbatim: loc(StudioText.title)).font(Ed.display(22, .medium)).foregroundStyle(Ed.text)
            HStack(spacing: 2) {
                ForEach(StudioMode.allCases) { m in
                    Button { store.studio = m } label: {
                        VStack(spacing: 5) {
                            SectionLabel(m.label, tint: m == mode ? Ed.text : Ed.text3)
                            Capsule().fill(m == mode ? Ed.gold : .clear).frame(width: 18, height: 2)
                        }
                        .frame(minWidth: 84).frame(height: 34)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            if mode == .filters || mode == .adjust {
                ScopePicker(clipScope: $state.clipScope, clipAvailable: targetClip != nil)
            }
            EdButton(title: StudioText.done, symbol: "checkmark", prominent: true) { store.studio = nil }
        }
        .padding(.horizontal, 18)
        .frame(height: 50)
        .background(Ed.panel)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }

    // MARK: Picture

    private var picture: some View {
        GeometryReader { geo in
            let aspect = MonitorFit.aspect(store.project)
            let fitted = MonitorFit.size(aspect: aspect, in: CGSize(width: geo.size.width - 48, height: geo.size.height - 44))
            let w = fitted.width, ph = fitted.height
            ZStack {
                Ed.well
                if store.project?.duration ?? .zero > .zero {
                    ZStack {
                        MonitorView(source: store.preview.program, aspect: aspect)
                        if let still = holding ? store.previews.base : store.previews.live {
                            Image(decorative: still, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        }
                        if holding {
                            SectionLabel(StudioText.original, tint: Ed.text)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .frame(maxHeight: .infinity, alignment: .top).padding(.top, 14)
                        }
                        if let name = state.flash {
                            Text(verbatim: loc(name)).font(Ed.display(min(w * 0.13, 44), .regular)).italic().foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 12)
                                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                        }
                    }
                    .frame(width: w, height: ph)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .offset(y: -8)
                    .shadow(color: .black.opacity(0.55), radius: 30, y: 10)
                    .onLongPressGesture(minimumDuration: 0.12, maximumDistance: 30, perform: {}, onPressingChanged: { holding = $0 })
                    .onDrop(of: [.text], isTargeted: nil) { providers in dropTile(providers, at: nil) }
                    Text(verbatim: loc(StudioText.holdHint)).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
                        .frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 6)
                } else {
                    EmptyHint(symbol: "camera.filters", text: StudioText.empty)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Deck

    @ViewBuilder private var deck: some View {
        switch mode {
        case .filters: FilterStrip(target: scopeClip)
        case .adjust: AdjustDeck(target: scopeClip)
        case .effects: GalleryDeck(layout: .grid, studio: true)
        case .styles: StylesDeck()
        }
    }

    /// The clip a clip-scoped look goes to: the selected picture clip, else the main clip under the playhead.
    private var targetClip: Clip? {
        guard let p = store.project else { return nil }
        if let id = store.selection.first, let loc = p.locate(clip: id) {
            let c = p.tracks[loc.track].clips[loc.clip]
            if !c.isGenerated, p.asset(c.assetID)?.video != nil { return c }
        }
        return EffectsCatalog.mainClip(at: MediaTime(seconds: playhead.time), in: p)
    }

    private var scopeClip: Clip? { state.clipScope ? targetClip : nil }

    private func dropTile(_ providers: [NSItemProvider], at time: Double?) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let id = s as? String else { return }
            DispatchQueue.main.async { Gallery.apply(id, store: store, at: time ?? store.preview.time) }
        }
        return true
    }
}

/// "Tutto il video | Questa clip".
struct ScopePicker: View {
    @Binding var clipScope: Bool
    var clipAvailable: Bool

    var body: some View {
        RSegmented(items: [(false, StudioText.wholeVideo), (true, StudioText.thisClip)], selection: $clipScope, fill: false,
                   disabled: clipAvailable ? [] : [true])
    }
}

// MARK: - Deck pieces

/// Title of a deck: the mode in the display face, one line of help.
struct DeckTitle: View {
    let title: String
    let line: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: loc(title)).font(Ed.display(26)).italic().foregroundStyle(Ed.text)
            Text(verbatim: loc(line)).font(Ed.ui(11)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// What the picture carries now (look, adjustments), each removable with one click.
struct AppliedSummary: View {
    @EnvironmentObject private var store: EditorStore
    let target: Clip?

    var body: some View {
        let g = target.map { $0.grade } ?? store.project?.grade
        let chips = Self.chips(g)
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(target == nil ? "Applicato a tutto il video" : "Applicato alla clip")
            if chips.isEmpty {
                Text(verbatim: loc("Niente: il video è com'è stato girato.")).font(Ed.ui(11)).foregroundStyle(Ed.text3)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(chips, id: \.0) { key, label in
                        Button { remove(key) } label: {
                            HStack(spacing: 5) {
                                Text(verbatim: label).font(Ed.ui(11, .medium)).foregroundStyle(Ed.text)
                                Image(systemName: "xmark").font(Ed.icon(8, .bold)).foregroundStyle(Ed.text3)
                            }
                            .padding(.horizontal, 9).frame(height: 24)
                            .background(Capsule().fill(Ed.raised))
                            .overlay(Capsule().strokeBorder(Ed.line2))
                        }
                        .buttonStyle(.plain)
                        .tip("Togli")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func chips(_ g: Grade?) -> [(String, String)] {
        var out: [(String, String)] = []
        if let l = g?.look, let look = Look.named(l) { out.append(("look", loc(look.label) + " " + String(Int(((g?.amount ?? 1) * 100).rounded())))) }
        if let a = g?.adjust {
            for p in Adjustments.properties where a[p.name] != 0 {
                let n = Int((a[p.name] * 100).rounded())
                out.append((p.name, loc(p.label) + " " + (n > 0 && p.range.lowerBound < 0 ? "+" : "") + String(n)))
            }
        }
        return out
    }

    private func remove(_ key: String) {
        var params: [String: JSONValue] = key == "look" ? ["look": "none"] : [key: 0]
        if let c = target { params["clipId"] = .string(c.id) }
        store.run(key == "look" ? "look.apply" : "adjust.set", .object(params))
    }
}

// MARK: - Filters

struct FilterStrip: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var state = StudioState.shared
    let target: Clip?

    private var grade: Grade? { target.map { $0.grade } ?? store.project?.grade }
    private var current: String { grade?.look ?? "none" }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            DeckTitle(title: "Filtri", line: "Il fotogramma vero, in ogni stile. Clic per applicare, clic di nuovo per l'intensità.")
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        thumb("none", label: "Originale").id("none")
                        ForEach(Look.all, id: \.id) { l in thumb(l.id, label: l.label).id(l.id) }
                    }
                    .padding(.vertical, 2)
                }
                .onAppear { reader.scrollTo(current, anchor: .center) }
                .onChange(of: current) { withAnimation(.easeOut(duration: 0.25)) { reader.scrollTo(current, anchor: .center) } }
            }
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.96), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
            if current != "none", state.lookOpen == current {
                intensityRow(current)
            } else if current != "none" {
                Text(verbatim: loc(Look.named(current)?.label ?? "") + " · " + loc(Look.named(current)?.line ?? "")).font(Ed.ui(11)).foregroundStyle(Ed.text2).frame(height: 44, alignment: .leading)
            } else {
                Spacer().frame(height: 44)
            }
            Ed.line.frame(height: 1)
            AppliedSummary(target: target)
            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private func thumb(_ id: String, label: String) -> some View {
        let on = id == current
        return Button { tap(id) } label: {
            VStack(spacing: 8) {
                ZStack {
                    Ed.well
                    if let img = store.previews.lookThumbs[id] {
                        Image(decorative: img, scale: 1).resizable().interpolation(.medium).aspectRatio(9 / 16, contentMode: .fill)
                    }
                }
                .frame(width: 78, height: 139)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Ed.gold : Color.white.opacity(0.07), lineWidth: on ? 2 : 1))
                .shadow(color: .black.opacity(on ? 0.5 : 0), radius: 8, y: 3)
                Text(verbatim: loc(label).uppercased(with: Locale.current)).font(Ed.ui(9.5, on ? .semibold : .regular)).tracking(0.5)
                    .foregroundStyle(on ? Ed.gold : Ed.text2).lineLimit(1).minimumScaleFactor(0.75)
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
        .tip(loc(Look.named(id)?.line ?? "Nessun filtro"))
    }

    private func tap(_ id: String) {
        if id == current {
            state.lookOpen = state.lookOpen == id ? nil : id
            return
        }
        state.lookOpen = nil
        var params: [String: JSONValue] = ["look": .string(id)]
        if id != "none" { params["amount"] = .number(grade?.look == nil ? 0.7 : (grade?.amount ?? 0.7)) }
        if let c = target { params["clipId"] = .string(c.id) }
        store.run("look.apply", .object(params))
        Gallery.flash(id == "none" ? loc("Originale") : loc(Look.named(id)?.label ?? id))
    }

    private func intensityRow(_ look: String) -> some View {
        let value = state.dialling?.name == "amount" ? state.dialling!.value : (grade?.amount ?? 1)
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(loc("Intensità di %@", loc(Look.named(look)?.label ?? look)))
            ScrubRuler(value: value, range: 0...1, center: 0, onChange: { v in
                state.dialling = ("amount", v)
                store.previews.showLive(Gallery.resolvedGrade(grade, amount: v))
            }, onCommit: { v in
                var params: [String: JSONValue] = ["look": .string(look), "amount": .number((v * 100).rounded() / 100)]
                if let c = target { params["clipId"] = .string(c.id) }
                store.run("look.apply", .object(params))
                Gallery.endDial(store)
            }, onReset: {
                var params: [String: JSONValue] = ["look": .string(look), "amount": 1]
                if let c = target { params["clipId"] = .string(c.id) }
                store.run("look.apply", .object(params))
            }, format: { String(Int(($0 * 100).rounded())) })
            .frame(height: 30)
            .tip(StudioText.reset)
        }
        .frame(height: 44)
    }
}

// MARK: - Adjust

struct AdjustDeck: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var state = StudioState.shared
    let target: Clip?

    static let symbols: [String: String] = [
        "exposure": "plusminus.circle", "brilliance": "sparkle", "highlights": "sun.max", "shadows": "moon",
        "contrast": "circle.lefthalf.filled", "saturation": "drop", "warmth": "thermometer.medium", "tint": "eyedropper.halffull",
        "sharpness": "triangle", "vignette": "circle.dashed",
    ]

    private var grade: Grade? { target.map { $0.grade } ?? store.project?.grade }
    private var values: Adjustments { grade?.adjust ?? Adjustments() }

    var body: some View {
        let prop = Adjustments.properties.first { $0.name == state.tool } ?? Adjustments.properties[0]
        let shown = state.dialling?.name == prop.name ? state.dialling!.value : values[prop.name]
        VStack(alignment: .leading, spacing: 22) {
            DeckTitle(title: "Regola", line: "Scegli uno strumento e trascina il righello. Doppio clic per azzerare.")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 16) {
                ForEach(Adjustments.properties, id: \.name) { p in
                    ToolRing(symbol: Self.symbols[p.name] ?? "slider.horizontal.3", label: p.label,
                             value: state.dialling?.name == p.name ? state.dialling!.value : values[p.name],
                             range: p.range, selected: p.name == state.tool,
                             onTap: { state.tool = p.name }, onReset: { commit(p.name, 0) })
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: loc(prop.label)).font(Ed.display(17)).italic().foregroundStyle(Ed.text)
                    Spacer()
                    let n = Int((shown * 100).rounded())
                    Text(verbatim: n > 0 && prop.range.lowerBound < 0 ? "+\(n)" : "\(n)").font(Ed.mono(20, .medium))
                        .foregroundStyle(n == 0 ? Ed.text3 : Ed.gold)
                }
                ScrubRuler(value: shown, range: prop.range, center: 0, onChange: { v in
                    state.dialling = (prop.name, v)
                    var a = values
                    a[prop.name] = v
                    store.previews.showLive(Gallery.resolvedGrade(grade, adjust: a))
                }, onCommit: { v in
                    commit(prop.name, v)
                    Gallery.endDial(store)
                }, onReset: { commit(prop.name, 0) }, format: { v in
                    let n = Int((v * 100).rounded())
                    return n > 0 && prop.range.lowerBound < 0 ? "+\(n)" : "\(n)"
                })
                .frame(height: 34)
                .tip(StudioText.reset)
            }
            Ed.line.frame(height: 1)
            AppliedSummary(target: target)
            if !values.isIdentity {
                EdButton(title: "Azzera le regolazioni", symbol: "arrow.counterclockwise") {
                    var params: [String: JSONValue] = ["reset": true]
                    if let c = target { params["clipId"] = .string(c.id) }
                    store.run("adjust.set", .object(params))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private func commit(_ name: String, _ v: Double) {
        var params: [String: JSONValue] = [name: .number((v * 100).rounded() / 100)]
        if let c = target { params["clipId"] = .string(c.id) }
        store.run("adjust.set", .object(params))
    }
}

/// A round tool button whose ring shows the value (clockwise positive, counter-clockwise negative).
struct ToolRing: View {
    let symbol: String
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let selected: Bool
    let onTap: () -> Void
    let onReset: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle().fill(selected ? Ed.raised : (hover ? Ed.hover.opacity(0.6) : Color.clear))
                Circle().strokeBorder(Ed.line2, lineWidth: 1.5)
                let f = min(abs(value) / max(range.upperBound, 0.001), 1)
                Circle().trim(from: 0, to: f)
                    .stroke(Ed.gold, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .scaleEffect(x: value < 0 ? -1 : 1, y: 1)
                    .padding(1)
                Image(systemName: symbol).font(Ed.icon(15, .regular))
                    .foregroundStyle(selected ? Ed.gold : (value != 0 ? Ed.text : Ed.text2))
            }
            .frame(width: 46, height: 46)
            Text(verbatim: loc(label)).font(Ed.ui(10, selected ? .semibold : .regular)).foregroundStyle(selected ? Ed.text : Ed.text3)
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(width: 70)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { onReset() }
        .onTapGesture { onTap() }
        .tip(loc(label) + " · " + loc(StudioText.reset))
    }
}

/// A horizontal ruler scrubbed by dragging (Photos-style): ticks slide under a fixed centre needle.
struct ScrubRuler: View {
    let value: Double
    let range: ClosedRange<Double>
    var center: Double = 0
    let onChange: (Double) -> Void
    let onCommit: (Double) -> Void
    let onReset: () -> Void
    let format: (Double) -> String
    @State private var dragStart: Double?
    @State private var dragValue: Double?

    var body: some View {
        let v = dragValue ?? value
        GeometryReader { g in
            let W = g.size.width, span = range.upperBound - range.lowerBound
            let pxPerUnit = W * 0.9 / span
            ZStack {
                Canvas { ctx, size in
                    let mid = size.width / 2
                    // Ticks every 1/40 of the range, a long one every 1/8 and at the neutral value.
                    let step = span / 40
                    var u = range.lowerBound
                    while u <= range.upperBound + 1e-9 {
                        let x = mid + (u - v) * pxPerUnit
                        if x > -2 && x < size.width + 2 {
                            let major = abs((u - range.lowerBound) / (span / 8) - ((u - range.lowerBound) / (span / 8)).rounded()) < 1e-6
                            let neutral = abs(u - center) < step / 2
                            let h: CGFloat = neutral ? 16 : (major ? 11 : 6)
                            let edge = 1 - min(abs(x - mid) / mid, 1)
                            ctx.fill(Path(CGRect(x: x - 0.5, y: (size.height - h) / 2 + 6, width: neutral ? 1.5 : 1, height: h)),
                                     with: .color((neutral ? Ed.gold : Ed.text).opacity(0.15 + 0.55 * edge)))
                        }
                        u += step
                    }
                }
                Rectangle().fill(Ed.text).frame(width: 2, height: 22).offset(y: 6)
                Text(verbatim: format(v)).font(Ed.mono(11, .medium)).foregroundStyle(abs(v - center) > 1e-6 ? Ed.gold : Ed.text2)
                    .offset(y: -13)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { d in
                    let start = dragStart ?? value
                    if dragStart == nil { dragStart = value }
                    let nv = min(max(start - d.translation.width / pxPerUnit, range.lowerBound), range.upperBound)
                    dragValue = nv
                    onChange(nv)
                }
                .onEnded { _ in
                    if let nv = dragValue { onCommit(nv) }
                    dragStart = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dragValue = nil }
                })
            .onTapGesture(count: 2) { onReset() }
        }
    }
}

// MARK: - Gallery

enum Gallery {
    /// Applies a tile at a moment: to the selected clip, else the main clip under that moment.
    @MainActor
    static func apply(_ itemID: String, store: EditorStore, at time: Double, clipID: String? = nil, overrides: [String: JSONValue] = [:]) {
        guard let item = EffectsCatalog.named(itemID), let project = store.project else { return }
        var t = MediaTime(seconds: time).snapped(to: project.settings.frameRate)
        var clip = clipID
        if clip == nil, item.needs != .picture {
            // The clip under the playhead wins; a selected clip elsewhere is used from its start (the playhead may
            // sit past it, e.g. at the end of the reel); at the very end, the last clip.
            let main = project.tracks.first { $0.kind == .video && !$0.clips.isEmpty }
            if let sel = store.selection.first, project.locate(clip: sel) != nil { clip = sel }
            else { clip = EffectsCatalog.mainClip(at: t, in: project)?.id ?? main?.clips.last(where: { $0.start <= t })?.id }
        }
        if let cid = clip, let (ti, ci) = project.locate(clip: cid) {
            let c = project.tracks[ti].clips[ci]
            if !(c.start <= t && t < c.end) { t = c.start }
        } else if clip == nil, item.needs == .moment, t > project.duration - MediaTime(seconds: 2.5) {
            // A moment at the very end would put the graphic after the last frame: keep it inside the reel.
            t = max(.zero, project.duration - MediaTime(seconds: 2.5)).snapped(to: project.settings.frameRate)
        }
        let target = EffectTarget(clipID: clip, start: t, end: nil)
        var (command, params) = EffectsCatalog.resolve(item, target: target, intensity: StudioState.shared.intensity, project: project)
        if case .object(var o) = params {
            for (k, v) in overrides { o[k] = v }
            // Stickers and titles go where nothing is drawn yet (captions, other graphics, faces), not on top of each other.
            if o["position"] == nil, o["band"] == nil, command == "sticker.add" || command == "title.add" {
                let size: [Double] = command == "sticker.add" ? Array(repeating: (o["size"]?.doubleValue ?? 160) * 1.2, count: 2)
                                                              : ((o["size"]?.doubleValue ?? 84) < 50 ? [300, 80] : [640, 170])
                let spot = FreeSpot.centre(in: project, at: t, size: size,
                                           candidates: command == "sticker.add" ? FreeSpot.stickerSpots : FreeSpot.titleSpots, renderer: AVRenderer())
                o["position"] = .array(spot.map { .number($0) })
            }
            params = .object(o)
        }
        store.run(command, params)
        flash(loc(item.label))
        if item.needs != .picture { playAround(store, at: params["at"]?.doubleValue ?? t.seconds) }
    }

    /// After a tile lands on a moment, play the two seconds around it once and stop just after it, so the effect is seen
    /// (a 0.2 s flash or a pop-in is invisible on a paused frame).
    @MainActor
    static func playAround(_ store: EditorStore, at t: Double) {
        let p = store.preview
        p.whenCurrent {
            p.seek(max(0, t - 0.5))
            if !p.isPlaying { p.togglePlay() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                MainActor.assumeIsolated { if p.isPlaying { p.togglePlay() } }
            }
        }
    }

    @MainActor
    static func flash(_ name: String) {
        withAnimation(.easeOut(duration: 0.18)) { StudioState.shared.flash = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            MainActor.assumeIsolated {
                if StudioState.shared.flash == name { withAnimation(.easeIn(duration: 0.35)) { StudioState.shared.flash = nil } }
            }
        }
    }

    @MainActor
    static func endDial(_ store: EditorStore) {
        // Keep the dialled still until the player shows the committed grade.
        store.preview.whenCurrent {
            StudioState.shared.dialling = nil
            store.previews.showLive(nil)
        }
    }

    static func resolvedGrade(_ g: Grade?, amount: Double? = nil, adjust: Adjustments? = nil) -> ResolvedGrade {
        ResolvedGrade(look: g?.look, amount: amount ?? g?.amount ?? 1, adjust: adjust ?? g?.adjust ?? Adjustments())
    }
}

/// The gallery: category chips, search, animated tiles and the one Intensità control. `strip` lays the tiles in one
/// horizontal row (the studio deck), `grid` in columns (the Grafica panel).
struct GalleryDeck: View {
    enum Layout { case strip, grid }
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = StudioState.shared
    let layout: Layout
    /// The studio column shows a title and roomier tiles; the Grafica panel is compact.
    var studio = false

    private var items: [EffectsCatalog.Item] {
        let q = state.query.trimmingCharacters(in: .whitespaces).lowercased()
        let available = EffectsCatalog.items.filter { ($0.engine != "blender" || blender) && $0.category != .styles }
        if !q.isEmpty {
            return available.filter {
                loc($0.label).lowercased().contains(q) || loc($0.category.label).lowercased().contains(q) || $0.summary.lowercased().contains(q)
                    || $0.label.lowercased().contains(q)
            }
        }
        return available.filter { $0.category == state.category }
    }

    /// Blender tiles only when Blender is installed (graphics.blenderTitle runs it as a separate process).
    private var blender: Bool {
        let c = store.engine.context.services.config
        return FileManager.default.isExecutableFile(atPath: EngineConfig.expand(c.blender))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: studio ? 14 : 10) {
            if studio {
                DeckTitle(title: "Effetti", line: "Si provano sul tuo video. Clic: al punto della testina. Trascina un riquadro sull'immagine o sulla striscia.")
                    .padding(.horizontal, 22).padding(.top, 10)
            }
            if studio { AppliedHere().padding(.horizontal, 22) }
            controls
            // The Grafica panel has no studio monitor: say what is on the picture now (and let it be removed).
            if !studio, layout == .grid, state.query.isEmpty, state.category == .filters || state.category == .adjust {
                AppliedSummary(target: nil).padding(.horizontal, 10)
            }
            if layout == .strip {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) { ForEach(items, id: \.id) { tile($0) } }
                        .padding(.horizontal, 18)
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: studio ? 92 : 74, maximum: studio ? 110 : 100), spacing: 8)], spacing: 14) {
                        ForEach(items, id: \.id) { tile($0) }
                    }
                    .padding(.horizontal, studio ? 22 : 10)
                }
            }
            if state.category == .templates, state.query.isEmpty, let id = state.motionItem, let spec = MotionRegistry.spec(id) {
                MotionForm(spec: spec).padding(.horizontal, layout == .strip ? 18 : studio ? 22 : 10)
            }
            if let id = state.textItem, let item = EffectsCatalog.named(id), items.contains(where: { $0.id == id }) {
                TitleForm(item: item).padding(.horizontal, layout == .strip ? 18 : studio ? 22 : 10)
            }
            if !studio { Text(verbatim: loc(StudioText.dragHint)).font(Ed.ui(10)).foregroundStyle(Ed.text3).padding(.horizontal, 10) }
        }
        .padding(.vertical, 12)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(Ed.icon(11)).foregroundStyle(Ed.text3)
                    TextField(loc(StudioText.search), text: $state.query).textFieldStyle(.plain).font(Ed.ui(11.5))
                }
                .padding(.horizontal, 9).frame(width: layout == .strip ? 210 : nil, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(Ed.well))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ed.line))
                if layout == .strip { Spacer(); intensity.frame(width: 300) }
            }
            if layout == .grid { intensity }
            FlowLayout(spacing: 4, lineSpacing: 5) {
                ForEach(EffectsCatalog.Category.gallery, id: \.self) { c in
                    let on = state.query.isEmpty && c == state.category
                    Button { state.category = c; state.query = "" } label: {
                        Text(verbatim: loc(c.label)).font(Ed.ui(11, on ? .semibold : .regular)).foregroundStyle(on ? Color.black.opacity(0.85) : Ed.text2)
                            .padding(.horizontal, 10).frame(height: 24)
                            .background(Capsule().fill(on ? Ed.gold : Ed.raised))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, layout == .strip ? 18 : studio ? 22 : 10)
    }

    private var intensity: some View {
        HStack(spacing: 8) {
            SectionLabel(StudioText.intensity)
            Text(verbatim: loc(StudioText.little)).font(Ed.ui(10)).foregroundStyle(Ed.text3)
            RSlider(value: $state.intensity, range: 0...1, format: { String(Int(($0 * 100).rounded())) + "%" })
                .onTapGesture(count: 2) { state.intensity = 0.5 }
            Text(verbatim: loc(StudioText.lot)).font(Ed.ui(10)).foregroundStyle(Ed.text3)
        }
    }

    private func tile(_ item: EffectsCatalog.Item) -> some View {
        EffectTile(item: item, frames: frames(item), lookThumb: item.command == "look.apply" ? store.previews.lookThumbs[lookID(item)] : nil, big: studio,
                   selected: item.category == .templates ? state.motionItem == item.id
                             : item.command == "title.add" ? state.textItem == item.id : isCurrentLook(item))
            .onAppear { if item.command != "look.apply" && item.engine == nil { store.previews.requestTile(item, time: playhead.time) } }
            .onTapGesture {
                // Motion templates open their form (Applica there); every other tile applies at once.
                // The look already on the picture comes off with a second click, like Photos and Instagram.
                if item.category == .templates { state.motionItem = item.id }
                else if item.command == "title.add" { state.textItem = item.id }
                else if isCurrentLook(item), item.id != "look-none" { Gallery.apply("look-none", store: store, at: playhead.time) }
                else { Gallery.apply(item.id, store: store, at: playhead.time) }
            }
            .onDrag { NSItemProvider(object: item.id as NSString) }
            .tip(item.label)
    }

    private func frames(_ item: EffectsCatalog.Item) -> [CGImage]? { store.previews.tiles[item.id] }
    /// The whole-picture look tile that is applied now ("Originale" when there is none).
    private func isCurrentLook(_ item: EffectsCatalog.Item) -> Bool {
        item.command == "look.apply" && lookID(item) == (store.project?.grade?.look ?? "none")
    }
    private func lookID(_ item: EffectsCatalog.Item) -> String { item.id == "look-none" ? "none" : String(item.id.dropFirst(5)) }
}

/// A gallery tile: its animated preview (8 frames on a loop) or, until it arrives, its symbol.
struct EffectTile: View {
    let item: EffectsCatalog.Item
    let frames: [CGImage]?
    var lookThumb: CGImage?
    var big = false
    var selected = false
    @State private var hover = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Ed.well
                if let lookThumb {
                    Image(decorative: lookThumb, scale: 1).resizable().aspectRatio(9 / 16, contentMode: .fill)
                } else if let frames, !frames.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1.0 / 7)) { ctx in
                        let k = Int(ctx.date.timeIntervalSinceReferenceDate * 7) % frames.count
                        Image(decorative: frames[k], scale: 1).resizable().aspectRatio(9 / 16, contentMode: .fill)
                    }
                } else {
                    Image(systemName: item.symbol).font(Ed.icon(20, .light)).foregroundStyle(Ed.text3)
                }
            }
            .frame(width: big ? 84 : 70, height: big ? 149 : 108)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Ed.gold : hover ? Ed.gold.opacity(0.8) : Color.white.opacity(0.06),
                                                                    lineWidth: selected ? 2 : hover ? 1.5 : 1))
            .scaleEffect(hover ? 1.03 : 1)
            .animation(.easeOut(duration: 0.15), value: hover)
            Text(verbatim: loc(item.label)).font(Ed.ui(10.5, hover ? .semibold : .regular)).foregroundStyle(hover ? Ed.text : Ed.text2)
                .lineLimit(2).multilineTextAlignment(.center).frame(width: big ? 88 : 74, height: 26, alignment: .top)
        }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }
}

// MARK: - Styles

struct StylesDeck: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var state = StudioState.shared

    static let styles: [(id: String, name: String, line: String, moves: [String])] = [
        ("energico", "Reel energico", "Per catturare nei primi secondi.", ["colori vividi", "punch-in a ogni frase", "whoosh su pochi tagli", "sottotitoli parola per parola"]),
        ("pulito", "Pulito", "Sobrio, luminoso, niente fronzoli.", ["luce morbida", "contrasto delicato", "sottotitoli a frase intera", "nessun effetto sonoro"]),
        ("tutorial", "Tutorial", "Per spiegare uno schermo.", ["zoom sui clic", "un cerchio su ogni clic", "barra di avanzamento", "immagine nitida"]),
        ("console", "Console", "Il montaggio in diretta, al neon.", ["riquadro neon con PREVIEW", "sfondo scuro", "barra REC con timer e capitoli", "sottotitoli bold con parola chiave"]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            DeckTitle(title: "Stili", line: store.project?.brand.map { loc("Un clic, tanti passi, nei colori del kit %@. Si annulla tutto in una volta (⌘Z).", $0.name) }
                      ?? loc("Un clic, tanti passi, nei colori del kit del progetto. Si annulla tutto in una volta (⌘Z)."))
            HStack(spacing: 8) {
                SectionLabel(StudioText.intensity)
                Text(verbatim: loc(StudioText.little)).font(Ed.ui(10)).foregroundStyle(Ed.text3)
                RSlider(value: $state.intensity, range: 0...1, format: { String(Int(($0 * 100).rounded())) + "%" })
                Text(verbatim: loc(StudioText.lot)).font(Ed.ui(10)).foregroundStyle(Ed.text3)
            }
            ForEach(Self.styles, id: \.id) { s in card(s) }
            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private func card(_ s: (id: String, name: String, line: String, moves: [String])) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: loc(s.name)).font(Ed.display(20, .medium)).foregroundStyle(Ed.text)
                Text(verbatim: loc(s.line)).font(Ed.ui(11)).foregroundStyle(Ed.text2)
                Text(verbatim: s.moves.map { loc($0) }.joined(separator: " · ")).font(Ed.ui(10.5)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            EdButton(title: StudioText.apply, symbol: "wand.and.stars") {
                store.run("style.apply", ["style": .string(s.id), "intensity": .number((state.intensity * 100).rounded() / 100)])
                Gallery.flash(loc(s.name))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ed.raised.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ed.line))
    }
}

/// Titolo / Etichetta: type the words and pick how long they stay, then Aggiungi (title.add at the playhead, in a free
/// spot of the frame). The title then plays once so it is seen.
struct TitleForm: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = StudioState.shared
    let item: EffectsCatalog.Item
    @State private var text = ""
    @State private var seconds = 2.5
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: loc(item.label)).font(Ed.display(17, .medium)).foregroundStyle(Ed.text)
            TextField(loc("Scrivi il testo"), text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Ed.ui(13)).lineLimit(1...3)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Ed.well))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ed.gold.opacity(0.7)))
                .focused($focused)
                .onSubmit { add() }
            RSlider(value: $seconds, range: 1...8, step: 0.5, label: "Durata", format: { String(format: "%.1f s", $0) })
            HStack {
                Text(verbatim: loc("Alla testina, %@", shortTime(playhead.time))).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
                Spacer()
                EdButton(title: "Annulla") { state.textItem = nil }
                EdButton(title: "Aggiungi", symbol: "plus", prominent: true,
                         disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { add() }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Ed.raised.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ed.line))
        .onAppear { focused = true }
        .onChange(of: item.id) { text = ""; focused = true }
    }

    private func add() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        Gallery.apply(item.id, store: store, at: playhead.time, overrides: ["text": .string(words), "duration": .number(seconds)])
        text = ""
        state.textItem = nil
    }
}
