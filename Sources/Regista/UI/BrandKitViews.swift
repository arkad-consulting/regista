import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI
import UniformTypeIdentifiers

// Brand kits in the app (issue #17, E4 #3): the kits on disk with their live 9:16 previews (drawn by the real
// compositor), the pieces that show a kit (palette, bubble, preview), the Marca picker — the one place in the editor
// that picks the project's kit — and the logo placement controls of the Grafica panel. Kits are created and edited in
// Settings › Brand kit (BrandKitSettings.swift), through the brandkit.* commands only.

/// Kits on disk and their rendered previews (the brandkit.preview renderer on a queue of its own, so previews
/// never wait behind the agent's commands; cached by kit content).
@MainActor
final class BrandKitLibrary: ObservableObject {
    static let shared = BrandKitLibrary()

    @Published private(set) var kits: [BrandKit] = []
    @Published private(set) var previews: [String: NSImage] = [:]
    @Published private(set) var rendering: Set<String> = []
    private var keys: [String: String] = [:]
    private let queue = DispatchQueue(label: "regista.brandkit.preview", qos: .userInitiated) // l10n-ignore
    nonisolated(unsafe) private static let services = EngineServices.live()

    init() { reload() }

    func reload() {
        let all = BrandKit.all()
        let order = BrandKit.builtIn.map(\.id)
        kits = all.values.sorted { a, b in
            let ia = order.firstIndex(of: a.id) ?? Int.max, ib = order.firstIndex(of: b.id) ?? Int.max
            return ia != ib ? ia < ib : a.name.localizedCompare(b.name) == .orderedAscending
        }
    }

    func kit(_ id: String?) -> BrandKit? { kits.first { $0.id == id } }

    /// A project's copy of its kit against the kit as it is now (#98): the project keeps its copy (a video comes out
    /// tomorrow as it does today), and the window says when the two differ or the kit is gone.
    enum CopyStatus { case same, changed, deleted }

    /// Compares what a person can see — colours, fonts, logo files, the logo's corner and size — never timestamps: a kit
    /// changed and put back is the same.
    func status(of copy: BrandKit) -> CopyStatus {
        guard let current = kit(copy.id)?.absolutized() else { return .deleted }
        let a = copy.absolutized()
        func codes(_ k: BrandKit) -> [String: String] { k.colors.mapValues { $0.uppercased() } }
        let same = codes(a) == codes(current) && a.fonts == current.fonts && a.logo == current.logo && (a.logos ?? [:]) == (current.logos ?? [:])
            && a.logoPlacement?.corner == current.logoPlacement?.corner && a.logoPlacement?.width == current.logoPlacement?.width
        return same ? .same : .changed
    }

    /// The kit as the window names it (the Marca tab, Esporta): its name, and whether the project's copy differs from the
    /// kit or the kit was deleted.
    func label(_ copy: BrandKit) -> String {
        switch status(of: copy) {
        case .same: copy.name
        case .changed: String(format: loc("%@ · copia del progetto"), copy.name)
        case .deleted: String(format: loc("%@ · kit eliminato"), copy.name)
        }
    }

    static func isUserKit(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: BrandKitStore().folder(id).appendingPathComponent("kit.json").path)
    }

    /// The cache key: the kit's content (absolute paths) and what the backdrop shows.
    static func key(_ kit: BrandKit, backdrop: String) -> String {
        let json = (try? JSONEncoder().encode(kit.absolutized())).map { String(decoding: $0, as: UTF8.self) } ?? kit.id
        return json + "|" + backdrop
    }

    /// Renders (once per content) the 9:16 preview of `kit` over the open project's footage.
    func preview(_ kit: BrandKit, slot: String? = nil, store: EditorStore, width: Int = 360) {
        let slot = slot ?? kit.id
        let backdrop = store.project.map { p in p.tracks.filter { $0.kind == .video }.flatMap(\.clips).map(\.id).joined(separator: ",") + p.name } ?? ""
        let key = Self.key(kit, backdrop: backdrop)
        guard keys[slot] != key else { return }
        keys[slot] = key
        rendering.insert(slot)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("regista-kit-preview-\(slot)-\(UUID().uuidString.prefix(6)).png")
        let project = store.project
        queue.async {
            let ok = (try? BrandKitPreview.render(kit, project: project, services: Self.services, prober: FFProbe(), width: width, to: out)) != nil
            let img = ok ? NSImage(contentsOf: out) : nil
            try? FileManager.default.removeItem(at: out)
            DispatchQueue.main.async { [self] in
                guard keys[slot] == key else { return }   // a newer edit took over
                rendering.remove(slot)
                if let img { previews[slot] = img }
            }
        }
    }
}

// MARK: - Shared pieces

/// The kit's colours as a row of overlapping dots.
struct PaletteDots: View {
    let kit: BrandKit
    var size: CGFloat = 12
    var roles = ["primary", "highlight", "accent", "ink", "paper"]
    var body: some View {
        HStack(spacing: -size * 0.3) {
            ForEach(roles.filter { kit.colors[$0] != nil }, id: \.self) { r in
                Circle().fill(Color(hexString: kit.colors[r]!)).frame(width: size, height: size)
                    .overlay(Circle().strokeBorder(Ed.panel, lineWidth: 1.5))
            }
        }
    }
}

/// A kit as a round "story" bubble: its palette as a ring of sectors, the initial in the display colour.
struct KitBubble: View {
    let kit: BrandKit
    var selected = false
    var size: CGFloat = 46
    var body: some View {
        let colors = ["primary", "highlight", "accent", "paper"].compactMap { kit.colors[$0] }.map { Color(hexString: $0) }
        ZStack {
            Circle().fill(AngularGradient(colors: colors + colors.prefix(1), center: .center))
            Circle().fill(Color(hexString: kit.colors["ink"] ?? "#141414")).padding(size * 0.12)
            Text(verbatim: Self.initials(kit.name)).font(Ed.display(size * (Self.initials(kit.name).count > 1 ? 0.32 : 0.42), .medium))
                .foregroundStyle(Color(hexString: kit.colors["paper"] ?? "#FFFFFF"))
        }
        .frame(width: size, height: size)
        .overlay(Circle().strokeBorder(Ed.gold, lineWidth: selected ? 2 : 0).padding(-4))
        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }

    /// "Café Atelier" → "CA", "WeSites" → "W".
    static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

/// A 9:16 preview frame: the rendered image, or a placeholder while it draws.
struct KitPreviewImage: View {
    let image: NSImage?
    var busy = false
    var radius: CGFloat = 14
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius).fill(Ed.well)
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(9 / 16, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
                    .transition(.opacity)
            }
            if busy && image == nil { ProgressView().controlSize(.small) }
        }
        .aspectRatio(9 / 16, contentMode: .fit)
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.white.opacity(0.07)))
        .animation(.easeOut(duration: 0.25), value: image != nil)
    }
}

// MARK: - Marca picker

/// The one place in the editor that picks the project's brand kit (E4 #3): the toolbar's "Marca: <kit>" popover
/// (⇧⌘B). Each kit is a row — its bubble, name and palette — and a click runs brandkit.apply. Kits are made and
/// edited in Settings › Brand kit.
struct BrandPicker: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var library = BrandKitLibrary.shared
    var onPick: () -> Void = {}

    static let width: CGFloat = 300
    /// `notice`: the project's copy differs from its kit, or the kit was deleted (#98): one more block on top.
    static func height(kits: Int, notice: BrandKitLibrary.CopyStatus = .same) -> CGFloat {
        CGFloat(118 + 40 * max(kits, 1) + (notice == .changed ? 96 : notice == .deleted ? 64 : 0))
    }

    var body: some View {
        let active = store.project?.brand?.id
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: loc("Marca del progetto")).font(Ed.ui(Ed.TypeSize.control, .semibold)).foregroundStyle(Ed.text)
                Text(verbatim: loc(store.project == nil ? "Apri un progetto per scegliere la sua marca." : "Sottotitoli, titoli e logo prendono i colori del kit."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.top, Ed.Space.m).padding(.bottom, Ed.Space.s)
            if let copy = store.project?.brand { copyNotice(copy) }
            ScrollView {
                VStack(spacing: Ed.Space.xxs) {
                    ForEach(library.kits, id: \.id) { kit in
                        KitRow(kit: kit, on: kit.id == active, enabled: store.project != nil) {
                            store.run("brandkit.apply", ["kit": .string(kit.id)])
                            onPick()
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            Ed.rule2.frame(height: 1).padding(.top, 6)
            AccentLinkButton(title: loc("Crea e modifica i kit in Impostazioni…"), tip: "Impostazioni › Brand kit") {
                onPick()
                SettingsRoute.open(.brand, with: openSettings)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .onAppear { library.reload() }
    }

    /// The project's copy against its kit (#98): changed → one line and «Aggiorna dal kit» (brandkit.apply again: one
    /// command, one undo step); deleted → the project keeps its copy, nothing to update.
    @ViewBuilder
    private func copyNotice(_ copy: BrandKit) -> some View {
        switch library.status(of: copy) {
        case .same: EmptyView()
        case .changed:
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                Text(verbatim: loc("Il kit è cambiato dopo che l'hai applicato a questo progetto."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                EdButton(title: "Aggiorna dal kit", symbol: "arrow.triangle.2.circlepath") {
                    store.run("brandkit.apply", ["kit": .string(copy.id)])
                }
            }
            .padding(.horizontal, 14).padding(.bottom, Ed.Space.s)
        case .deleted:
            Text(verbatim: String(format: loc("Il kit «%@» è stato eliminato: il progetto tiene la sua copia e il video non cambia."), copy.name))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, Ed.Space.s)
        }
    }

    private struct KitRow: View {
        let kit: BrandKit
        let on: Bool
        let enabled: Bool
        let action: () -> Void
        @State private var hover = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 10) {
                    KitBubble(kit: kit, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: kit.name).font(Ed.ui(Ed.TypeSize.control)).foregroundStyle(Ed.text).lineLimit(1)
                        Text(verbatim: loc(BrandKitLibrary.isUserKit(kit.id) ? "tuo" : "integrato")).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                    }
                    Spacer(minLength: Ed.Space.xs)
                    PaletteDots(kit: kit, size: 10)
                    Image(systemName: "checkmark").font(Ed.icon(Ed.TypeSize.caption, .bold)).foregroundStyle(on ? Ed.gold : .clear).frame(width: 14)
                }
                .padding(.horizontal, Ed.Space.s).frame(height: 38)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(on ? Ed.goldSoft : (hover && enabled ? Ed.hover : .clear)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
            .onHover { hover = $0 }
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }
}

extension BrandKit {
    /// The file of a logo variant when the kit sets one (no fallback to other variants).
    func logoPathIfSet(_ variant: String) -> String? {
        if let p = logos?[variant] { return assetPath(p) }
        return variant == "onDark" ? logo.map(assetPath) : nil
    }
}

/// Corner, size, entrance and presence of the logo in the video (Grafica › Logo).
struct LogoPlacementControls: View {
    @Binding var placement: LogoPlacement
    var onCommit: () -> Void = {}

    static let corners: [(String, String)] = [("topLeft", ""), ("topCenter", ""), ("topRight", ""), ("bottomLeft", ""), ("bottomRight", "")]
    static let symbols = ["topLeft": "arrow.up.left", "topCenter": "arrow.up", "topRight": "arrow.up.right",
                          "bottomLeft": "arrow.down.left", "bottomRight": "arrow.down.right"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            RSegmented(items: Self.corners, selection: Binding(get: { placement.corner }, set: { placement.corner = $0; onCommit() }),
                       symbols: Self.symbols, height: 28)
                .frame(maxWidth: 300)
            RSlider(value: Binding(get: { placement.width }, set: { placement.width = $0 }), range: 60...480, step: 10, label: "Grandezza",
                    format: { String(Int($0)) + " px" }, onCommit: { _ in onCommit() })
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: loc("Animazione")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2)
                RSegmented(items: [("fade", "Dissolve"), ("pop", "Pop"), ("pulse", "Respiro"), ("orbit", "Orbita")],
                           selection: Binding(get: { placement.animation ?? "fade" }, set: { placement.animation = $0; onCommit() }), height: 24)
            }
            IntensityBar(value: Binding(get: { placement.opacity ?? 1 }, set: { placement.opacity = $0 }), steps: 8, low: "discreto", high: "pieno",
                         label: "Presenza", onCommit: { _ in onCommit() })
        }
    }
}
