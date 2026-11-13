import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI
import UniformTypeIdentifiers

// Brand kits in the app (issue #17): the gallery (cards with a live 9:16 preview drawn by the real compositor),
// the editor (swatches by role, fonts, logo drop zones, logo placement), and the Brand inspector tab.
// Instagram/Apple-simple: pick a card, tap "Applica"; everything else is one level down.

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

// MARK: - Sheet

/// The gallery, and the editor one level down.
struct BrandKitSheet: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var library = BrandKitLibrary.shared
    /// Starts on the editor of this kit (ui.screenshot "brandkit-editor").
    var startEditing: String? = nil
    var onClose: () -> Void = {}

    @State private var editing: BrandKit?
    @State private var selected: String?

    var body: some View {
        ZStack {
            if let kit = editing {
                BrandKitEditor(kit: kit, onDone: { saved in
                    library.reload()
                    if let saved { selected = saved.id }
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { editing = nil }
                })
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                BrandKitGallery(selected: $selected, onEdit: { k in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) { editing = k }
                }, onClose: onClose)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(width: 1040, height: 700)
        .background(Ed.panel)
        .environment(\.colorScheme, .dark)
        .onAppear {
            library.reload()
            selected = store.project?.brand?.id ?? library.kits.first?.id
            if let id = startEditing { editing = library.kit(id) ?? library.kits.first }
        }
    }
}

// MARK: - Gallery

struct BrandKitGallery: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var library = BrandKitLibrary.shared
    @Binding var selected: String?
    var onEdit: (BrandKit) -> Void
    var onClose: () -> Void
    @State private var message: String?

    private var active: String? { store.project?.brand?.id }
    private var current: BrandKit? { library.kit(selected) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 0)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(library.kits, id: \.id) { kit in
                        KitCard(kit: kit, image: library.previews[kit.id], busy: library.rendering.contains(kit.id),
                                selected: kit.id == selected, active: kit.id == active)
                            .onTapGesture { withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = kit.id } }
                            .onTapGesture(count: 2) { onEdit(kit) }
                            .contextMenu {
                                Button("Modifica") { onEdit(kit) }
                                Button("Duplica") { duplicate(kit) }
                                Button("Esporta…") { export(kit) }
                                if BrandKitLibrary.isUserKit(kit.id) {
                                    Divider()
                                    Button(loc(BrandKit.builtInIDs.contains(kit.id) ? "Ripristina l'originale" : "Elimina"), role: .destructive) { delete(kit) }
                                }
                            }
                            .onAppear { library.preview(kit, store: store) }
                    }
                    NewKitCard { create() }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 22)
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            footer
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: loc("Brand kit")).font(Ed.display(26, .medium)).foregroundStyle(Ed.text)
                Text(verbatim: loc("Colori, caratteri e logo di ogni cliente. Scegli un kit e applicalo al montaggio con un clic."))
                    .font(Ed.ui(12)).foregroundStyle(Ed.text3)
            }
            Spacer()
            EdButton(title: "Importa…", symbol: "square.and.arrow.down") { importKit() }
            EdButton(title: "Esporta…", symbol: "square.and.arrow.up", disabled: current == nil) { if let k = current { export(k) } }
            EdButton(title: "button.done") { onClose() }
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            if let k = current {
                KitBubble(kit: k, size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: k.name).font(Ed.ui(13, .semibold)).foregroundStyle(Ed.text)
                        Text(verbatim: BrandKitLibrary.isUserKit(k.id) ? loc("tuo") : loc("integrato")).font(Ed.mono(9.5)).foregroundStyle(Ed.text3)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().strokeBorder(Ed.line2))
                    }
                    Text(verbatim: message ?? k.notes ?? "").font(Ed.ui(11)).foregroundStyle(message == nil ? Ed.text3 : Ed.gold).lineLimit(2)
                        .frame(maxWidth: 520, alignment: .leading)
                }
                Spacer()
                EdButton(title: "Modifica", symbol: "slider.horizontal.3") { onEdit(k) }
                EdButton(title: "Duplica", symbol: "plus.square.on.square") { duplicate(k) }
                EdButton(title: k.id == active ? "Applica di nuovo" : "Applica al progetto", symbol: "wand.and.stars", prominent: true,
                         disabled: store.project == nil) {
                    store.run("brandkit.apply", ["kit": .string(k.id)])
                    message = loc("%@ applicato: sottotitoli, titoli e logo aggiornati.", k.name)
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 72)
        .background(Ed.header)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    // MARK: Actions

    private func create() {
        var k = BrandKit.arkad
        k.name = loc("Nuovo kit")
        k.id = uniqueID("nuovo-kit")
        k.notes = nil
        onEdit(k)
    }

    private func duplicate(_ kit: BrandKit) {
        var k = kit
        k.id = uniqueID(kit.id + "-copia")
        k.name = loc("%@ (copia)", kit.name)
        if let saved = try? BrandKitStore().save(k) {
            library.reload()
            selected = saved.id
            message = loc("Copia creata: %@.", saved.name)
        }
    }

    private func delete(_ kit: BrandKit) {
        try? BrandKitStore().delete(kit.id)
        library.reload()
        selected = library.kit(kit.id)?.id ?? library.kits.first?.id
    }

    private func uniqueID(_ base: String) -> String {
        var id = BrandKitStore.slug(base), n = 2
        while library.kit(id) != nil { id = "\(BrandKitStore.slug(base))-\(n)"; n += 1 }
        return id
    }

    private func importKit() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: BrandKitStore.fileExtension) ?? .zip, .json, .folder]
        panel.message = loc("Scegli un file .registakit ricevuto da un partner")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let kit = try BrandKitStore().importKit(from: url)
            library.reload()
            selected = kit.id
            message = loc("Importato: %@.", kit.name)
        } catch { store.errorMessage = loc("Il kit non si è potuto importare: %@", "\(error)") }
    }

    private func export(_ kit: BrandKit) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(kit.id).\(BrandKitStore.fileExtension)"
        panel.message = loc("Un file solo con colori, caratteri e logo: mandalo ai partner")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try BrandKitStore().export(kit, to: url)
            message = loc("Esportato in %@.", file.lastPathComponent)
        } catch { store.errorMessage = loc("Il kit non si è potuto esportare: %@", "\(error)") }
    }
}

struct KitCard: View {
    let kit: BrandKit
    let image: NSImage?
    var busy = false
    var selected = false
    var active = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KitPreviewImage(image: image, busy: busy)
                .frame(width: 214)
                .overlay(alignment: .topTrailing) {
                    if active {
                        Text(verbatim: loc("In uso")).font(Ed.ui(10, .semibold)).foregroundStyle(Accent.on)
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Ed.gold)).padding(8)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Ed.gold, lineWidth: selected ? 2.5 : 0).padding(-5))
                .shadow(color: .black.opacity(selected || hover ? 0.5 : 0.25), radius: selected || hover ? 14 : 6, y: selected ? 8 : 3)
            HStack(spacing: 8) {
                Text(verbatim: kit.name).font(Ed.display(15, .medium)).foregroundStyle(selected ? Ed.text : Ed.text2).lineLimit(1)
                Spacer(minLength: 4)
                PaletteDots(kit: kit, size: 11)
            }
            .frame(width: 214)
        }
        .scaleEffect(selected ? 1.02 : hover ? 1.01 : 1, anchor: .bottom)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(active ? loc("Kit %@, in uso", kit.name) : loc("Kit %@", kit.name))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct NewKitCard: View {
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 5]))
                        .foregroundStyle(hover ? Ed.gold : Ed.line2)
                    VStack(spacing: 8) {
                        Image(systemName: "plus").font(Ed.icon(22, .light)).foregroundStyle(hover ? Ed.gold : Ed.text2)
                        Text(verbatim: loc("Nuovo kit")).font(Ed.ui(12, .medium)).foregroundStyle(Ed.text2)
                        Text(verbatim: loc("per un cliente")).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
                    }
                }
                .aspectRatio(9 / 16, contentMode: .fit)
                .frame(width: 150)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Editor

struct BrandKitEditor: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var library = BrandKitLibrary.shared
    @State var kit: BrandKit
    var onDone: (BrandKit?) -> Void
    @State private var problem: String?

    static let roleNames: [(String, String)] = [("primary", "Principale"), ("accent", "Accento"), ("highlight", "Evidenza"),
                                                 ("onHighlight", "Su evidenza"), ("ink", "Inchiostro"), ("paper", "Carta"),
                                                 ("surface", "Superficie"), ("success", "Conferma")]
    static let fontNames: [(String, String)] = [("display", "Titoli"), ("text", "Testo"), ("textBold", "Testo forte"), ("mono", "Etichette")]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { onDone(nil) } label: {
                    HStack(spacing: 4) { Image(systemName: "chevron.left"); Text(verbatim: loc("Brand kit")) }.font(Ed.ui(12, .medium)).foregroundStyle(Ed.text2)
                }
                .buttonStyle(.plain)
                Spacer()
                if BrandKit.builtInIDs.contains(kit.id) && !BrandKitLibrary.isUserKit(kit.id) {
                    Text(verbatim: loc("Le modifiche creano la tua copia di questo kit")).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
                }
                EdButton(title: "Annulla") { onDone(nil) }
                EdButton(title: "Salva") { if let s = save() { onDone(s) } }
                EdButton(title: "Salva e applica", symbol: "wand.and.stars", prominent: true, disabled: store.project == nil) {
                    if let s = save() { store.run("brandkit.apply", ["kit": .string(s.id)]); onDone(s) }
                }
            }
            .padding(.horizontal, 24)
            .frame(height: 52)
            .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 10) {
                    KitPreviewImage(image: library.previews["editor"], busy: library.rendering.contains("editor"), radius: 18)
                        .frame(width: 300)
                        .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
                    HStack(spacing: 6) {
                        Circle().fill(library.rendering.contains("editor") ? Ed.gold : Ed.ok).frame(width: 6, height: 6)
                        Text(verbatim: library.rendering.contains("editor") ? loc("Aggiorno l'anteprima…") : loc("Anteprima dal vivo, stesso motore dell'export"))
                            .font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
                    }
                }
                .padding(.top, 22)
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        TextField(loc("Nome del kit"), text: $kit.name)
                            .textFieldStyle(.plain)
                            .font(Ed.display(28, .medium))
                            .foregroundStyle(Ed.text)
                        InspectorSection(title: "Colori") {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 8), count: 8), alignment: .leading, spacing: 10) {
                                ForEach(Self.roleNames, id: \.0) { role, name in
                                    ColorSwatch(role: role, hex: colorBinding(role), caption: name)
                                }
                            }
                            captionSample
                        }
                        HStack(alignment: .top, spacing: 28) {
                            InspectorSection(title: "Logo") {
                                HStack(spacing: 10) {
                                    LogoDropZone(title: "Su video scuro", path: kit.logoPathIfSet("onDark"), dark: true) { setLogo($0, "onDark") }
                                    LogoDropZone(title: "Su chiaro", path: kit.logoPathIfSet("onLight"), dark: false) { setLogo($0, "onLight") }
                                    LogoDropZone(title: "Simbolo", path: kit.logoPathIfSet("mark"), dark: true) { setLogo($0, "mark") }
                                }
                                Text(verbatim: loc("SVG (nitido a ogni misura) o PNG trasparente:\ntrascinalo su un riquadro o fai clic."))
                                    .font(Ed.ui(10.5)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                            }
                            InspectorSection(title: "Posizione del logo") {
                                LogoPlacementControls(placement: placementBinding, watermark: Binding(get: { kit.watermark ?? false }, set: { kit.watermark = $0 }))
                            }
                            .frame(width: 250)
                        }
                        InspectorSection(title: "Caratteri") {
                            VStack(spacing: 6) { ForEach(Self.fontNames, id: \.0) { role, name in fontRow(role, name) } }
                        }
                        if let problem { Text(verbatim: problem).font(Ed.ui(11)).foregroundStyle(Ed.danger) }
                    }
                    .padding(.vertical, 22)
                    .padding(.trailing, 24)
                }
            }
            .padding(.leading, 28)
        }
        .onAppear { library.preview(kit, slot: "editor", store: store, width: 480) }
        .onChange(of: kit) { _, k in
            // Debounced: the preview follows the edit a beat later.
            Task { try? await Task.sleep(for: .milliseconds(250)); if k == kit { library.preview(kit, slot: "editor", store: store, width: 480) } }
        }
    }

    private var captionSample: some View {
        let box = kit.colors["highlight"] ?? "#FF2D6F"
        let text = kit.captionOverrides()["keywordTextColor"]?.stringValue ?? "#FFFFFF"
        return HStack(spacing: 10) {
            Text(verbatim: loc("Sottotitoli")).font(Ed.ui(10.5)).foregroundStyle(Ed.text3).lineLimit(2).minimumScaleFactor(0.8)
                .frame(width: 76, alignment: .leading)
            HStack(spacing: 6) {
                Text(verbatim: loc("IL TUO")).font(Ed.captionSample(17)).foregroundStyle(.white).shadow(color: .black, radius: 0.5)
                Text(verbatim: loc("BRAND")).font(Ed.captionSample(17)).foregroundStyle(Color(hexString: text))
                    .padding(.horizontal, 6).padding(.vertical, 2).background(Color(hexString: box))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Ed.captionBackdrop))
            Text(verbatim: loc("La parola chiave prende il colore Evidenza")).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
        }
    }

    private func fontRow(_ role: String, _ name: String) -> some View {
        let spec = kit.fonts[role] ?? "—"
        let resolved = kit.font(role)
        let fallback = kit.fontReport().first { $0.role == role }?.fallback ?? false
        return HStack(spacing: 12) {
            Text(verbatim: loc(name)).font(Ed.ui(11)).foregroundStyle(Ed.text2).lineLimit(2).minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .leading)
            Text(verbatim: loc("Aa Il tuo titolo")).font(Self.font(resolved, size: role == "display" ? 20 : 15)).foregroundStyle(Ed.text).lineLimit(1)
                .frame(width: 200, alignment: .leading)
            Text(verbatim: URL(fileURLWithPath: spec).lastPathComponent).font(Ed.mono(10)).foregroundStyle(fallback ? Ed.danger : Ed.text3).lineLimit(1)
                .tip(fallback ? loc("File mancante: uso %@", resolved) : spec)
            if fallback { Text(verbatim: loc("sostituito")).font(Ed.ui(10)).foregroundStyle(Ed.danger) }
            Spacer()
            EdButton(title: "Importa…", symbol: "textformat") { importFont(role) }
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ed.well))
    }

    /// A SwiftUI font for a kit font (a file is registered for the process first).
    static func font(_ spec: String, size: CGFloat) -> Font { Ed.kitFont(spec, size: size) }

    private func colorBinding(_ role: String) -> Binding<String> {
        Binding(get: { kit.colors[role] ?? "#808080" }, set: { kit.colors[role] = $0 })
    }

    private var placementBinding: Binding<LogoPlacement> {
        Binding(get: { kit.logoPlacement ?? LogoPlacement() }, set: { kit.logoPlacement = $0 })
    }

    @discardableResult
    private func save() -> BrandKit? {
        do {
            let saved = try BrandKitStore().save(kit)
            kit = saved
            library.reload()
            return saved
        } catch { problem = loc("Il kit non si è potuto salvare: %@", "\(error)"); return nil }
    }

    private func setLogo(_ url: URL, _ variant: String) {
        do { kit = try BrandKitStore().setLogo(kit, file: url, variant: variant); library.reload(); problem = nil }
        catch { problem = loc("Il logo non si è potuto usare: %@", "\(error)") }
    }

    private func importFont(_ role: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ttf", "otf", "woff2"].compactMap { UTType(filenameExtension: $0) }
        panel.message = loc("Scegli il file del carattere (TTF, OTF o WOFF2)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { kit = try BrandKitStore().setFont(kit, file: url, role: role); library.reload(); problem = nil }
        catch { problem = loc("Il carattere non si è potuto usare: %@", "\(error)") }
    }
}

extension BrandKit {
    /// The file of a logo variant when the kit sets one (no fallback to other variants).
    func logoPathIfSet(_ variant: String) -> String? {
        if let p = logos?[variant] { return assetPath(p) }
        return variant == "onDark" ? logo.map(assetPath) : nil
    }
}

/// A logo tile: shows the logo on a dark or light ground; drop an SVG/PNG on it or click to choose one.
struct LogoDropZone: View {
    let title: String
    let path: String?
    var dark = true
    let onFile: (URL) -> Void
    @State private var targeted = false

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(dark ? Ed.logoOnDark : Ed.logoOnLight)
                    if let path, let img = NSImage(contentsOfFile: path) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(14)
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: "arrow.down.doc").font(Ed.icon(16, .light))
                            Text(verbatim: loc("SVG o PNG")).font(Ed.ui(10))
                        }
                        .foregroundStyle(dark ? Ed.text3 : Color.black.opacity(0.4))
                    }
                }
                .frame(width: 112, height: 70)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? Ed.gold : Ed.line2,
                                                                         style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: path == nil ? [4, 4] : [])))
                Text(verbatim: loc(title)).font(Ed.ui(10.5)).foregroundStyle(Ed.text2)
            }
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url, ["svg", "png"].contains(url.pathExtension.lowercased()) else { return }
                DispatchQueue.main.async { onFile(url) }
            }
            return true
        }
        .tip("Trascina qui il logo (SVG o PNG)")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, .png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onFile(url)
    }
}

/// Corner, size, opacity of the logo, and the kit's watermark switch (only where it is stored: the kit editor).
struct LogoPlacementControls: View {
    @Binding var placement: LogoPlacement
    var watermark: Binding<Bool>? = nil
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
                Text(verbatim: loc("Animazione")).font(Ed.ui(11)).foregroundStyle(Ed.text2)
                RSegmented(items: [("fade", "Dissolve"), ("pop", "Pop"), ("pulse", "Respiro"), ("orbit", "Orbita")],
                           selection: Binding(get: { placement.animation ?? "fade" }, set: { placement.animation = $0; onCommit() }), height: 24)
            }
            IntensityBar(value: Binding(get: { placement.opacity ?? 1 }, set: { placement.opacity = $0 }), steps: 8, low: "discreto", high: "pieno",
                         label: "Presenza", onCommit: { _ in onCommit() })
            if let watermark {
                RToggle(title: "Logo su tutto il video", isOn: Binding(get: { watermark.wrappedValue }, set: { watermark.wrappedValue = $0; onCommit() }),
                        subtitle: "Applicando il kit, resta in un angolo per tutto il reel")
            }
        }
    }
}

// MARK: - Inspector tab

/// Library tab "Brand": the active kit, one-tap kit switch, logo on/off and placement, app accent.
struct BrandTab: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var library = BrandKitLibrary.shared
    @AppStorage(Accent.followKey) private var accentFollows = false
    @State private var placement = LogoPlacement()

    private var active: BrandKit? { store.project?.brand }
    private var logoClips: [String] { store.project?.tracks.filter { $0.role == "logo" }.flatMap(\.clips).map(\.id) ?? [] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 12) {
                    KitPreviewImage(image: active.flatMap { library.previews[$0.id] }, busy: active.map { library.rendering.contains($0.id) } ?? false, radius: 8)
                        .frame(width: 72)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: active?.name ?? loc("Nessun kit")).font(Ed.display(17, .medium)).foregroundStyle(active == nil ? Ed.text3 : Ed.text)
                        if let a = active { PaletteDots(kit: a, size: 12) }
                        Text(verbatim: active == nil ? loc("Scegli un kit: sottotitoli, titoli e logo prendono i suoi colori.") : loc("Applicato al progetto"))
                            .font(Ed.ui(10.5)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                        EdButton(title: "Tutti i kit…", symbol: "square.grid.2x2") { store.showBrandKits = true }
                    }
                }
                InspectorSection(title: "Kit") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 14) {
                            ForEach(library.kits, id: \.id) { kit in
                                Button { store.run("brandkit.apply", ["kit": .string(kit.id)]) } label: {
                                    VStack(spacing: 5) {
                                        KitBubble(kit: kit, selected: kit.id == active?.id, size: 44)
                                        Text(verbatim: kit.name).font(Ed.ui(9.5)).foregroundStyle(kit.id == active?.id ? Ed.text : Ed.text3).lineLimit(1).frame(width: 60)
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(store.project == nil)
                                .tip(loc("Applica %@", kit.name))
                            }
                        }
                        .padding(4)
                    }
                }
                InspectorSection(title: "Logo") {
                    RToggle(title: "Logo nel video", isOn: Binding(get: { !logoClips.isEmpty }, set: { on in on ? addLogo() : removeLogo() }),
                            subtitle: active?.logoPath() == nil ? "Questo kit non ha ancora un logo" : nil)
                        .disabled(active?.logoPath() == nil)
                    LogoPlacementControls(placement: $placement, onCommit: { if !logoClips.isEmpty { addLogo() } })
                        .disabled(active == nil)
                        .opacity(active == nil ? 0.45 : 1)
                }
                InspectorSection(title: "Aspetto") {
                    RToggle(title: "Colore dell'app dal kit", isOn: $accentFollows, subtitle: "Evidenziazioni e pulsanti nel colore del brand")
                }
            }
            .padding(14)
        }
        .onAppear { sync() }
        .onChange(of: active?.id) { _, _ in sync() }
    }

    private func sync() {
        library.reload()
        placement = active?.logoPlacement ?? LogoPlacement()
        if let a = active { library.preview(a, store: store) }
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
