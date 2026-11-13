import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI

// The one Graphics panel (E4 #3), in the side panel of the Grafica activity: looks, adjustments, effects, one-click
// styles, motion templates and the logo, browsed from the effects catalog (`effects.catalog` is the source of what
// exists) with a preview where the compositor can draw one, and applied to the selected clip or at the playhead.
// Every click is one ordinary command (undo, the activity log, MCP parity); what is applied is listed and removable.

/// Shared state of the panel (the tile intensity, the search, the scope of looks, the open form).
@MainActor
final class GraphicsState: ObservableObject {
    static let shared = GraphicsState()
    @Published var intensity = 0.5
    @Published var query = ""
    /// Looks and adjustments on the selected clip only (else the whole video).
    @Published var clipScope = false
    /// The motion template whose form is open.
    @Published var motionItem: String?
    /// The text item whose form is open (Titolo, Etichetta): the words are typed before the title is added.
    @Published var textItem: String?
    /// The applied item picked on the strip or in the "Qui" list (AppliedItem.id).
    @Published var appliedSelection: String?
}

/// What the panel lists and what a click on each item does, read from the effects catalog. Pure, so a test can walk
/// the catalog against it: a new catalog entry shows up in its category's section by itself.
enum GraphicsCatalog {
    typealias Section = Navigation.GraphicsSection

    /// What a click on an item does: apply it at once, or open the small form whose Applica / Aggiungi applies it.
    enum Action: Equatable { case apply, titleForm, motionForm }

    static func section(of category: EffectsCatalog.Category) -> Section? {
        Section.allCases.first { $0.categories.contains(category) }
    }

    /// The section's items by category, in the section's category order and the catalog's item order.
    static func groups(in section: Section) -> [(category: EffectsCatalog.Category, items: [EffectsCatalog.Item])] {
        let all = EffectsCatalog.items
        return section.categories.compactMap { c in
            let items = all.filter { $0.category == c }
            return items.isEmpty ? nil : (c, items)
        }
    }

    static func items(in section: Section) -> [EffectsCatalog.Item] { groups(in: section).flatMap(\.items) }

    static func action(_ item: EffectsCatalog.Item) -> Action {
        if item.command == "motion.add" { return .motionForm }
        if item.command == "title.add" { return .titleForm }
        return .apply
    }

    /// Items whose name, one-line description or category matches `query` (in the interface's language or Italian).
    static func search(_ query: String) -> [EffectsCatalog.Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return Section.allCases.flatMap { items(in: $0) }.filter {
            loc($0.label).lowercased().contains(q) || $0.label.lowercased().contains(q) || loc(CatalogLines.line($0)).lowercased().contains(q)
                || loc($0.category.label).lowercased().contains(q)
        }
    }

    /// Why `item` cannot be applied now, in words (a lookup key); nil when it can. Nothing is hidden: the row stays,
    /// disabled, with this reason.
    static func unavailable(_ item: EffectsCatalog.Item, project: Project?, blender: Bool) -> String? {
        guard let p = project, p.duration > .zero else { return "Importa un video: gli effetti si provano sul fotogramma vero." }
        if item.engine == "blender", !blender { return "Serve Blender: si installa da Impostazioni › Motori." }
        if item.category == .captions, !p.tracks.contains(where: { $0.captions != nil }) {
            return "Prima genera i sottotitoli (Testi e sottotitoli)."
        }
        if item.command == "logo.animate", p.brand?.logoPath() == nil { return "Scegli una marca con un logo (Marca, nella barra del montaggio)." }
        return nil
    }

    static func title(_ s: Section) -> String {
        switch s {
        case .filters: "Filtri"
        case .adjust: "Regola"
        case .effects: "Effetti"
        case .styles: "Stili"
        case .motion: "Motion"
        case .logo: "Logo"
        }
    }

    static func tip(_ s: Section) -> String {
        switch s {
        case .filters: "Un look di colore per tutto il video o per una clip"
        case .adjust: "Luce, colore e nitidezza, come in Foto"
        case .effects: "Zoom, movimento, testi, sticker, transizioni, velocità, sottotitoli e layout"
        case .styles: "Tanti passi in un clic, nei colori della marca"
        case .motion: "Schede animate, liste, contatori, grafici e cornici"
        case .logo: "Il logo della marca nel video e le sue animazioni"
        }
    }
}

/// Applying a catalog item from the panel, the timeline or the strip: the selected clip, else the main clip under the
/// moment; stickers and titles go where nothing is drawn yet.
enum GraphicsActions {
    /// The command and params a click on `itemID` runs on `project` at `time` (nil: no such item).
    static func command(_ itemID: String, project: Project, selection: Set<String> = [], at time: Double, intensity: Double = 0.5,
                        clipID: String? = nil, overrides: [String: JSONValue] = [:]) -> (command: String, params: JSONValue)? {
        guard let item = EffectsCatalog.named(itemID) else { return nil }
        var t = MediaTime(seconds: time).snapped(to: project.settings.frameRate)
        var clip = clipID
        if clip == nil, item.needs != .picture {
            // The clip under the playhead wins; a selected clip elsewhere is used from its start (the playhead may
            // sit past it, e.g. at the end of the reel); at the very end, the last clip.
            let main = project.tracks.first { $0.kind == .video && !$0.clips.isEmpty }
            if let sel = selection.first, project.locate(clip: sel) != nil { clip = sel }
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
        var (command, params) = EffectsCatalog.resolve(item, target: target, intensity: intensity, project: project)
        if case .object(var o) = params {
            for (k, v) in overrides { o[k] = v }
            if o["position"] == nil, o["band"] == nil, command == "sticker.add" || command == "title.add" {
                let size: [Double] = command == "sticker.add" ? Array(repeating: (o["size"]?.doubleValue ?? 160) * 1.2, count: 2)
                                                              : ((o["size"]?.doubleValue ?? 84) < 50 ? [300, 80] : [640, 170])
                let spot = FreeSpot.centre(in: project, at: t, size: size,
                                           candidates: command == "sticker.add" ? FreeSpot.stickerSpots : FreeSpot.titleSpots, renderer: AVRenderer())
                o["position"] = .array(spot.map { .number($0) })
            }
            params = .object(o)
        }
        return (command, params)
    }

    /// Runs the item's command; a graphic on a moment then plays once around it, so it is seen (a 0.2 s flash or a
    /// pop-in is invisible on a paused frame).
    @MainActor
    static func apply(_ itemID: String, store: EditorStore, at time: Double, clipID: String? = nil, overrides: [String: JSONValue] = [:]) {
        guard let project = store.project, let item = EffectsCatalog.named(itemID),
              let (command, params) = command(itemID, project: project, selection: store.selection, at: time,
                                              intensity: GraphicsState.shared.intensity, clipID: clipID, overrides: overrides) else { return }
        store.run(command, params)
        if item.needs != .picture { playAround(store, at: params["at"]?.doubleValue ?? params["start"]?.doubleValue ?? time) }
    }

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
}

// MARK: - Panel

struct GraphicsPanel: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = GraphicsState.shared
    let section: Navigation.GraphicsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                searchField
                FlowLayout(spacing: 4, lineSpacing: 5) {
                    ForEach(Navigation.GraphicsSection.allCases, id: \.self) { s in
                        let on = state.query.isEmpty && s == section
                        Button { store.nav.graphicsSection = s; state.query = "" } label: {
                            Text(verbatim: loc(GraphicsCatalog.title(s))).font(Ed.ui(12, on ? .semibold : .regular))
                                .foregroundStyle(on ? Accent.on : Ed.text2)
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(Capsule().fill(on ? Ed.gold : Ed.raised))
                        }
                        .buttonStyle(.plain)
                        .tip(GraphicsCatalog.tip(s))
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 10)
            Ed.rule2.frame(height: 1)
            if store.project?.duration ?? .zero > .zero {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !state.query.trimmingCharacters(in: .whitespaces).isEmpty { SearchResults(query: state.query) }
                        else { content }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(verbatim: loc("Clic: si applica alla clip selezionata o alla testina. Si può anche trascinare sulla timeline."))
                    .font(Ed.ui(10.5)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .top) { Ed.rule2.frame(height: 1) }
            } else {
                EmptyHint(symbol: "sparkles.rectangle.stack", text: "Importa un video: gli effetti si provano sul fotogramma vero.")
            }
        }
        .onAppear { store.previews.refresh(at: playhead.time) }
        .onChange(of: playhead.time) { store.previews.refresh(at: playhead.time) }
        .onChange(of: store.project) { store.previews.refresh(at: playhead.time) }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(Ed.icon(11)).foregroundStyle(Ed.text3)
            ZStack(alignment: .leading) {
                if state.query.isEmpty {
                    Text(verbatim: loc("Cerca un effetto")).font(Ed.ui(12)).foregroundStyle(Ed.text3).allowsHitTesting(false)
                }
                TextField("", text: $state.query).textFieldStyle(.plain).font(Ed.ui(12)).foregroundStyle(Ed.text)
            }
            if !state.query.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: "Cancella la ricerca", size: 18) { state.query = "" }
            }
        }
        .padding(.horizontal, 9).frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(Ed.well))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ed.line))
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .filters: FiltersSection()
        case .adjust: AdjustSection()
        case .effects: EffectsSection()
        case .styles: StylesSection()
        case .motion: CatalogList(section: .motion, showsApplied: true)
        case .logo: LogoSection()
        }
    }
}

/// The clip a clip-scoped look goes to: the selected picture clip, else the main clip under the playhead.
@MainActor
func graphicsTargetClip(_ store: EditorStore, at time: Double) -> Clip? {
    guard let p = store.project else { return nil }
    if let id = store.selection.first, let loc = p.locate(clip: id) {
        let c = p.tracks[loc.track].clips[loc.clip]
        if !c.isGenerated, p.asset(c.assetID)?.video != nil { return c }
    }
    return EffectsCatalog.mainClip(at: MediaTime(seconds: time), in: p)
}

/// "Tutto il video | Questa clip": where looks and adjustments go.
struct ScopePicker: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = GraphicsState.shared

    var body: some View {
        let available = graphicsTargetClip(store, at: playhead.time) != nil
        RSegmented(items: [(false, "Tutto il video"), (true, "Questa clip")], selection: $state.clipScope, disabled: available ? [] : [true])
    }
}

/// Search results across every section, under each section's name.
private struct SearchResults: View {
    let query: String

    var body: some View {
        let found = GraphicsCatalog.search(query)
        if found.isEmpty {
            Text(verbatim: loc("Nessun effetto con questo nome.")).font(Ed.ui(12)).foregroundStyle(Ed.text3)
        }
        ForEach(Navigation.GraphicsSection.allCases, id: \.self) { s in
            let items = found.filter { GraphicsCatalog.section(of: $0.category) == s }
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(GraphicsCatalog.title(s)).padding(.bottom, 4)
                    ForEach(items, id: \.id) { CatalogRowItem(item: $0) }
                }
            }
        }
    }
}

// MARK: - Sections

/// The catalog items of a section, by category, each a row (click to apply, or to open its form).
struct CatalogList: View {
    let section: Navigation.GraphicsSection
    var showsApplied = false

    var body: some View {
        if showsApplied { AppliedHere() }
        let groups = GraphicsCatalog.groups(in: section)
        ForEach(groups, id: \.category) { g in
            VStack(alignment: .leading, spacing: 2) {
                if groups.count > 1 { SectionLabel(g.category.label).padding(.bottom, 4) }
                ForEach(g.items, id: \.id) { CatalogRowItem(item: $0) }
            }
        }
    }
}

/// Looks: the real frame through each look, the intensity of the one applied, and what the picture carries.
private struct FiltersSection: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = GraphicsState.shared
    @State private var amount: Double?

    var body: some View {
        let target = state.clipScope ? graphicsTargetClip(store, at: playhead.time) : nil
        let grade = target.map { $0.grade } ?? store.project?.grade
        VStack(alignment: .leading, spacing: 14) {
            ScopePicker()
            if let look = grade?.look, let l = Look.named(look) {
                RSlider(value: Binding(get: { amount ?? grade?.amount ?? 1 }, set: { amount = $0 }), range: 0...1,
                        label: loc("Intensità di %@", loc(l.label)), format: { String(Int(($0 * 100).rounded())) + "%" }) { v in
                    var params: [String: JSONValue] = ["look": .string(look), "amount": .number((v * 100).rounded() / 100)]
                    if let c = target { params["clipId"] = .string(c.id) }
                    store.run("look.apply", .object(params))
                    amount = nil
                }
            }
            AppliedSummary(target: target)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(GraphicsCatalog.items(in: .filters), id: \.id) { item in
                    CatalogRowItem(item: item, selected: LookItems.lookID(item) == (grade?.look ?? "none")) { tapLook(item, grade: grade, target: target) }
                }
            }
        }
    }

    /// A look keeps the intensity already chosen (70 % the first time); the look on the picture comes off with a second
    /// click, like Photos and Instagram.
    private func tapLook(_ item: EffectsCatalog.Item, grade: Grade?, target: Clip?) {
        let id = LookItems.lookID(item)
        let current = grade?.look ?? "none"
        var params: [String: JSONValue] = ["look": .string(id == current ? "none" : id)]
        if id != current, id != "none" { params["amount"] = .number(grade?.look == nil ? 0.7 : (grade?.amount ?? 0.7)) }
        if let c = target { params["clipId"] = .string(c.id) }
        store.run("look.apply", .object(params))
    }
}

/// Adjustments: the quick ones of the catalog, then one slider per tool (Photos-style), and what the picture carries.
private struct AdjustSection: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = GraphicsState.shared
    @State private var drafts: [String: Double] = [:]

    var body: some View {
        let target = state.clipScope ? graphicsTargetClip(store, at: playhead.time) : nil
        let values = (target.map { $0.grade } ?? store.project?.grade)?.adjust ?? Adjustments()
        VStack(alignment: .leading, spacing: 14) {
            ScopePicker()
            AppliedSummary(target: target)
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("Regolazioni rapide").padding(.bottom, 4)
                ForEach(GraphicsCatalog.items(in: .adjust), id: \.id) { item in
                    CatalogRowItem(item: item) {
                        GraphicsActions.apply(item.id, store: store, at: playhead.time, clipID: target?.id)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Regolazioni")
                ForEach(Adjustments.properties, id: \.name) { p in
                    RSlider(value: Binding(get: { drafts[p.name] ?? values[p.name] }, set: { drafts[p.name] = $0 }), range: p.range,
                            label: p.label, format: { v in
                                let n = Int((v * 100).rounded())
                                return n > 0 && p.range.lowerBound < 0 ? "+\(n)" : "\(n)"
                            }) { v in
                        var params: [String: JSONValue] = [p.name: .number((v * 100).rounded() / 100)]
                        if let c = target { params["clipId"] = .string(c.id) }
                        store.run("adjust.set", .object(params))
                        drafts[p.name] = nil
                    }
                }
                if !values.isIdentity {
                    EdButton(title: "Azzera le regolazioni", symbol: "arrow.counterclockwise") {
                        var params: [String: JSONValue] = ["reset": true]
                        if let c = target { params["clipId"] = .string(c.id) }
                        store.run("adjust.set", .object(params))
                    }
                }
            }
        }
    }
}

/// Effects: what is on the reel at the playhead, the one intensity, then each category's items.
private struct EffectsSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            IntensityRow()
            CatalogList(section: .effects, showsApplied: true)
        }
    }
}

/// "Intensità  poco ——— tanto": how strong a tile is when applied.
struct IntensityRow: View {
    @ObservedObject private var state = GraphicsState.shared

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: loc("Intensità")).font(Ed.ui(12)).foregroundStyle(Ed.text2)
            Text(verbatim: loc("poco")).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
            RSlider(value: $state.intensity, range: 0...1, format: { String(Int(($0 * 100).rounded())) + "%" })
            Text(verbatim: loc("tanto")).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
        }
    }
}

/// One-click styles: a card per style of the catalog, what it does, Applica.
private struct StylesSection: View {
    @EnvironmentObject private var store: EditorStore

    /// What each style does, step by step (lookup keys), by catalog id.
    static let moves: [String: [String]] = [
        "style-energico": ["colori vividi", "punch-in a ogni frase", "whoosh su pochi tagli", "sottotitoli parola per parola"],
        "style-pulito": ["luce morbida", "contrasto delicato", "sottotitoli a frase intera", "nessun effetto sonoro"],
        "style-tutorial": ["zoom sui clic", "un cerchio su ogni clic", "barra di avanzamento", "immagine nitida"],
        "style-console": ["riquadro neon con PREVIEW", "sfondo scuro", "barra REC con timer e capitoli", "sottotitoli bold con parola chiave"],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: store.project?.brand.map { loc("Un clic, tanti passi, nei colori del kit %@. Si annulla tutto in una volta (⌘Z).", $0.name) }
                 ?? loc("Un clic, tanti passi, nei colori del kit del progetto. Si annulla tutto in una volta (⌘Z)."))
                .font(Ed.ui(11.5)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            IntensityRow()
            ForEach(GraphicsCatalog.items(in: .styles), id: \.id) { card($0) }
        }
    }

    private func card(_ item: EffectsCatalog.Item) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: loc(item.label)).font(Ed.ui(13, .semibold)).foregroundStyle(Ed.text)
                Spacer(minLength: 8)
                EdButton(title: "Applica", symbol: "wand.and.stars") {
                    GraphicsActions.apply(item.id, store: store, at: 0)
                }
            }
            Text(verbatim: loc(CatalogLines.line(item))).font(Ed.ui(11.5)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
            if let moves = Self.moves[item.id] {
                Text(verbatim: moves.map { loc($0) }.joined(separator: " · ")).font(Ed.ui(11)).foregroundStyle(Ed.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.raised.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.line))
    }
}

/// The logo in the video (a Grafica element: on / off, corner, size, entrance, presence) and the logo animations.
private struct LogoSection: View {
    @EnvironmentObject private var store: EditorStore
    @State private var placement = LogoPlacement()

    private var kit: BrandKit? { store.project?.brand }
    private var logoClips: [String] { store.project?.tracks.filter { $0.role == "logo" }.flatMap(\.clips).map(\.id) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                RToggle(title: "Logo nel video", isOn: Binding(get: { !logoClips.isEmpty }, set: { on in on ? addLogo() : removeLogo() }),
                        subtitle: kit == nil ? "Scegli prima una marca (Marca, nella barra del montaggio)."
                            : kit?.logoPath() == nil ? "Questo kit non ha ancora un logo" : nil)
                    .disabled(kit?.logoPath() == nil)
                LogoPlacementControls(placement: $placement, onCommit: { if !logoClips.isEmpty { addLogo() } })
                    .disabled(kit == nil)
                    .opacity(kit == nil ? 0.45 : 1)
            }
            CatalogList(section: .logo)
        }
        .onAppear { placement = kit?.logoPlacement ?? LogoPlacement() }
        .onChange(of: kit?.id) { _, _ in placement = kit?.logoPlacement ?? LogoPlacement() }
    }

    private func addLogo() {
        store.run("logo.add", ["replace": true, "corner": .string(placement.corner), "width": .number(placement.width),
                               "opacity": .number(placement.opacity ?? 1), "animation": .string(placement.animation ?? "fade")])
    }

    private func removeLogo() {
        guard !logoClips.isEmpty else { return }
        store.run("timeline.delete", ["clipIds": .array(logoClips.map { .string($0) })])
    }
}

// MARK: - Rows

/// A catalog item as a row: its preview (the real frame through it, or its symbol), its plain name and one line of
/// what it does. A click applies it (or opens its form, shown under the row); disabled with the reason when it
/// cannot be applied now. Drag it onto the timeline or the strip to apply it there.
struct CatalogRowItem: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = GraphicsState.shared
    let item: EffectsCatalog.Item
    var selected = false
    /// Replaces the default click (looks keep their intensity, adjustments follow the scope).
    var onTap: (() -> Void)? = nil

    private var blender: Bool {
        FileManager.default.isExecutableFile(atPath: EngineConfig.expand(store.engine.context.services.config.blender))
    }

    var body: some View {
        let reason = GraphicsCatalog.unavailable(item, project: store.project, blender: blender)
        let action = GraphicsCatalog.action(item)
        let open = action == .motionForm ? state.motionItem == item.id : action == .titleForm ? state.textItem == item.id : false
        VStack(alignment: .leading, spacing: 6) {
            PreviewedRow(previews: store.previews, item: item, selected: selected || open, reason: reason, opens: action != .apply) {
                tap(action)
            }
            .onAppear { if item.command != "look.apply", item.engine == nil, reason == nil { store.previews.requestTile(item, time: playhead.time) } }
            .onDrag { NSItemProvider(object: item.id as NSString) }
            if open, action == .motionForm, let spec = MotionRegistry.spec(item.id) { MotionForm(spec: spec) }
            if open, action == .titleForm { TitleForm(item: item) }
        }
    }

    private func tap(_ action: GraphicsCatalog.Action) {
        switch action {
        case .motionForm: state.motionItem = state.motionItem == item.id ? nil : item.id
        case .titleForm: state.textItem = state.textItem == item.id ? nil : item.id
        case .apply:
            if let onTap { onTap() } else { GraphicsActions.apply(item.id, store: store, at: playhead.time) }
        }
    }
}

/// A row that follows the rendered previews (they are published by `EffectPreviews`, not by the store).
private struct PreviewedRow: View {
    @ObservedObject var previews: EffectPreviews
    let item: EffectsCatalog.Item
    let selected: Bool
    let reason: String?
    let opens: Bool
    let action: () -> Void

    var body: some View {
        CatalogRow(item: item, frames: previews.tiles[item.id],
                   lookThumb: item.command == "look.apply" ? previews.lookThumbs[LookItems.lookID(item)] : nil,
                   selected: selected, reason: reason, opens: opens, action: action)
    }
}

/// The look id of a look item ("look-golden" → "golden", "look-none" → "none").
enum LookItems {
    static func lookID(_ item: EffectsCatalog.Item) -> String { item.id == "look-none" ? "none" : String(item.id.dropFirst(5)) }
}

struct CatalogRow: View {
    let item: EffectsCatalog.Item
    let frames: [CGImage]?
    var lookThumb: CGImage?
    var selected = false
    var reason: String?
    /// The click opens a form (a chevron instead of the +).
    var opens = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let enabled = reason == nil
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                thumb
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: loc(item.label)).font(Ed.ui(13, .medium)).foregroundStyle(enabled ? Ed.text : Ed.text3).lineLimit(1)
                    Text(verbatim: loc(reason ?? CatalogLines.line(item))).font(Ed.ui(11)).foregroundStyle(reason == nil ? Ed.text3 : Ed.warn)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: selected ? "checkmark" : opens ? "chevron.down" : "plus")
                    .font(Ed.icon(10, .semibold))
                    .foregroundStyle(selected ? Ed.gold : Ed.text3)
                    .opacity(selected || (hover && enabled) ? 1 : 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(selected ? Ed.goldSoft : (hover && enabled ? Ed.hover.opacity(0.6) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var thumb: some View {
        ZStack {
            Ed.well
            if let lookThumb {
                Image(decorative: lookThumb, scale: 1).resizable().aspectRatio(9 / 16, contentMode: .fill)
            } else if let frames, !frames.isEmpty {
                if hover {
                    // The tile's animation plays while the pointer is on it; at rest the row shows its poster frame.
                    TimelineView(.periodic(from: .now, by: 1.0 / 7)) { ctx in
                        let k = Int(ctx.date.timeIntervalSinceReferenceDate * 7) % frames.count
                        Image(decorative: frames[k], scale: 1).resizable().aspectRatio(9 / 16, contentMode: .fill)
                    }
                } else {
                    Image(decorative: frames[0], scale: 1).resizable().aspectRatio(9 / 16, contentMode: .fill)
                }
            } else {
                Image(systemName: item.symbol).font(Ed.icon(14, .light)).foregroundStyle(Ed.text3)
            }
        }
        .frame(width: 36, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.s))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(selected ? Ed.gold : Color.white.opacity(0.07), lineWidth: selected ? 1.5 : 1))
        .opacity(reason == nil ? 1 : 0.5)
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
                Text(verbatim: loc("Niente: il video è com'è stato girato.")).font(Ed.ui(11.5)).foregroundStyle(Ed.text3)
            } else {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(chips, id: \.0) { key, label in
                        Button { remove(key) } label: {
                            HStack(spacing: 5) {
                                Text(verbatim: label).font(Ed.ui(11.5, .medium)).foregroundStyle(Ed.text)
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
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ed.well))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ed.line))
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

/// Titolo / Etichetta: the words (prefilled, so a click on Aggiungi is enough) and how long they stay, then Aggiungi
/// (title.add at the playhead, in a free spot of the frame). The title then plays once so it is seen.
struct TitleForm: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = GraphicsState.shared
    let item: EffectsCatalog.Item
    @State private var text = ""
    @State private var seconds = 2.5
    @FocusState private var focused: Bool

    /// The words a new title starts with (a lookup key).
    static func placeholder(_ item: EffectsCatalog.Item) -> String { item.id == "text-kicker" ? "Novità" : "Il tuo titolo" }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(loc("Scrivi il testo"), text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(Ed.ui(13)).lineLimit(1...3)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Ed.well))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ed.gold.opacity(0.7)))
                .focused($focused)
                .onSubmit { add() }
            RSlider(value: $seconds, range: 1...8, step: 0.5, label: "Durata", format: { String(format: "%.1f s", $0) })
            HStack {
                Text(verbatim: loc("Alla testina, %@", shortTime(playhead.time))).font(Ed.ui(11)).foregroundStyle(Ed.text3)
                Spacer()
                EdButton(title: "Annulla") { state.textItem = nil }
                EdButton(title: "Aggiungi", symbol: "plus", prominent: true,
                         disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { add() }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.raised.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.line))
        .onAppear { text = loc(Self.placeholder(item)); focused = true }
        .onChange(of: item.id) { text = loc(Self.placeholder(item)); focused = true }
    }

    private func add() {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        GraphicsActions.apply(item.id, store: store, at: playhead.time, overrides: ["text": .string(words), "duration": .number(seconds)])
        state.textItem = nil
    }
}
