import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

/// Impostazioni › Brand kit (E4 #3): where kits are created and edited. The kits on the left (new, duplicate, import,
/// delete), the selected kit on the right: name, colours by role, fonts, logos, logo placement, export. Every change
/// is a brandkit.* command (logged like the others, one undo step each: ⌘Z puts the kit back); nothing here writes kit
/// files itself. The project's kit is picked in the editor (Marca), not here.
struct BrandKitSettings: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var library = BrandKitLibrary.shared
    /// A render: shows the kits, writes nothing.
    var demo = false
    @State private var selected: String?
    @State private var problem: String?

    static let roleNames: [(String, String)] = [("primary", "Principale"), ("accent", "Accento"), ("highlight", "Evidenza"),
                                                 ("onHighlight", "Su evidenza"), ("ink", "Inchiostro"), ("paper", "Carta"),
                                                 ("surface", "Superficie"), ("success", "Conferma")]
    static let fontNames: [(String, String)] = [("display", "Titoli"), ("text", "Testo"), ("textBold", "Testo forte"), ("mono", "Etichette")]
    static let logoNames: [(String, String)] = [("onDark", "Su video scuro"), ("onLight", "Su chiaro"), ("mark", "Simbolo")]

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(library.kits, id: \.id) { kit in
                        HStack(spacing: 8) {
                            KitBubble(kit: kit, size: 20)
                            Text(verbatim: kit.name).lineLimit(1)
                        }
                        .tag(kit.id)
                    }
                }
                .listStyle(.sidebar)
                Divider()
                HStack(spacing: 2) {
                    Button { create() } label: { Image(systemName: "plus").frame(width: 22, height: 20) }
                        .help(loc("Nuovo kit")).accessibilityLabel(Text(verbatim: loc("Nuovo kit")))
                    Button { if let k = current { delete(k) } } label: { Image(systemName: "minus").frame(width: 22, height: 20) }
                        .help(loc(current.map { BrandKit.builtInIDs.contains($0.id) ? "Ripristina l'originale" : "Elimina" } ?? "Elimina"))
                        .disabled(current.map { !BrandKitLibrary.isUserKit($0.id) } ?? true)
                    Spacer()
                    Button("Importa…") { importKit() }
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8).frame(height: 30)
                .disabled(demo)
            }
            .frame(width: 200)
            Divider()
            if let kit = current {
                KitForm(kit: kit, demo: demo, problem: $problem,
                        onDuplicate: { duplicate(kit) }, onExport: { export(kit) })
                    .id(kit.id)
            } else {
                Text(verbatim: loc("Scegli un kit a sinistra.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            library.reload()
            if selected == nil { selected = store.project?.brand?.id ?? library.kits.first?.id }
        }
    }

    private var current: BrandKit? { library.kit(selected) }

    // MARK: Actions (each one command)

    private func run(_ id: String, _ params: JSONValue, then: @escaping (JSONValue) -> Void = { _ in }) {
        guard !demo else { return }
        Task {
            do {
                let r = try await store.perform(id, params)
                problem = nil
                library.reload()
                then(r)
            } catch {
                problem = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
        }
    }

    private func uniqueID(_ base: String) -> String {
        var id = BrandKitStore.slug(base), n = 2
        while library.kit(id) != nil { id = "\(BrandKitStore.slug(base))-\(n)"; n += 1 }
        return id
    }

    private func create() {
        let id = uniqueID("nuovo-kit")
        run("brandkit.create", ["name": .string(loc("Nuovo kit")), "id": .string(id), "from": "arkad"]) { _ in selected = id }
    }

    private func duplicate(_ kit: BrandKit) {
        let id = uniqueID(kit.id + "-copia")
        run("brandkit.create", ["name": .string(loc("%@ (copia)", kit.name)), "id": .string(id), "from": .string(kit.id)]) { _ in selected = id }
    }

    private func delete(_ kit: BrandKit) {
        run("brandkit.delete", ["kit": .string(kit.id)]) { _ in selected = library.kit(kit.id)?.id ?? library.kits.first?.id }
    }

    private func importKit() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: BrandKitStore.fileExtension) ?? .zip, .json, .folder]
        panel.message = loc("Scegli un file .registakit ricevuto da un partner")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("brandkit.import", ["path": .string(url.path)]) { r in selected = r["kit"]?["id"]?.stringValue ?? selected }
    }

    private func export(_ kit: BrandKit) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(kit.id).\(BrandKitStore.fileExtension)"
        panel.message = loc("Un file solo con colori, caratteri e logo: mandalo ai partner")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("brandkit.export", ["kit": .string(kit.id), "path": .string(url.path)])
    }
}

/// One kit, edited field by field: each change is a brandkit.update / setLogo / setFont (colours wait for a pause
/// in the colour panel, so dragging a colour is one undo step).
private struct KitForm: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var library = BrandKitLibrary.shared
    let kit: BrandKit
    let demo: Bool
    @Binding var problem: String?
    let onDuplicate: () -> Void
    let onExport: () -> Void
    @State private var name = ""
    @State private var colors: [String: String] = [:]
    @State private var colorTask: Task<Void, Never>?
    @State private var width: Double = 0
    @State private var opacity: Double = 1

    private var placement: LogoPlacement { kit.logoPlacement ?? LogoPlacement() }
    private var builtInOnly: Bool { BrandKit.builtInIDs.contains(kit.id) && !BrandKitLibrary.isUserKit(kit.id) }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    KitPreviewImage(image: library.previews["settings"], busy: library.rendering.contains("settings"), radius: 8)
                        .frame(width: 96)
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Nome del kit", text: $name)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.title3)
                            .onSubmit { commitName() }
                        Text(verbatim: loc(BrandKitLibrary.isUserKit(kit.id) ? "tuo" : "integrato")).font(.caption).foregroundStyle(.secondary)
                        if builtInOnly {
                            Text("Le modifiche creano la tua copia di questo kit").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Duplica") { onDuplicate() }
                            Button("Esporta…") { onExport() }
                        }
                        .disabled(demo)
                    }
                }
            }
            Section("Colori") {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 2), alignment: .leading, spacing: 8) {
                    ForEach(BrandKitSettings.roleNames, id: \.0) { role, label in
                        ColorPicker(selection: colorBinding(role), supportsOpacity: false) { Text(verbatim: loc(label)) }
                    }
                }
            }
            Section("Caratteri") {
                ForEach(BrandKitSettings.fontNames, id: \.0) { role, label in
                    LabeledContent {
                        HStack(spacing: 8) {
                            let fallback = kit.fontReport().first { $0.role == role }?.fallback ?? false
                            Text(verbatim: URL(fileURLWithPath: kit.fonts[role] ?? "—").lastPathComponent)
                                .foregroundStyle(fallback ? Color.red : .secondary).lineLimit(1).truncationMode(.middle)
                                .help(fallback ? loc("File mancante: uso %@", kit.font(role)) : (kit.fonts[role] ?? ""))
                            Button("Scegli…") { chooseFont(role) }.disabled(demo)
                        }
                    } label: { Text(verbatim: loc(label)) }
                }
            }
            Section("Logo") {
                ForEach(BrandKitSettings.logoNames, id: \.0) { variant, label in
                    LabeledContent {
                        HStack(spacing: 8) {
                            if let path = kit.logoPathIfSet(variant), let img = NSImage(contentsOfFile: path) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: 64, height: 26)
                                    .padding(3)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(variant == "onLight" ? Color.white : Color.black.opacity(0.85)))
                            } else {
                                Text("Nessun logo").foregroundStyle(.secondary)
                            }
                            Button("Scegli…") { chooseLogo(variant) }.disabled(demo)
                        }
                    } label: { Text(verbatim: loc(label)) }
                }
            }
            Section("Posizione del logo") {
                Picker("Angolo", selection: Binding(get: { placement.corner }, set: { updatePlacement(["corner": .string($0)]) })) {
                    ForEach(LogoPlacement.corners, id: \.self) { c in Text(verbatim: loc(Self.cornerName(c))).tag(c) }
                }
                LabeledContent {
                    Slider(value: $width, in: 60...480, step: 10) { editing in
                        if !editing { updatePlacement(["width": .number(width)]) }
                    }
                } label: { Text(verbatim: loc("Grandezza") + " · " + String(Int(width)) + " px") }
                Picker("Animazione", selection: Binding(get: { placement.animation ?? "fade" }, set: { updatePlacement(["animation": .string($0)]) })) {
                    ForEach([("fade", "Dissolve"), ("pop", "Pop"), ("pulse", "Respiro"), ("orbit", "Orbita")], id: \.0) { id, label in
                        Text(verbatim: loc(label)).tag(id)
                    }
                }
                LabeledContent {
                    Slider(value: $opacity, in: 0.2...1) { editing in
                        if !editing { updatePlacement(["opacity": .number((opacity * 100).rounded() / 100)]) }
                    }
                } label: { Text(verbatim: loc("Presenza") + " · " + String(Int((opacity * 100).rounded())) + "%") }
            }
            Section {
                HStack {
                    Text("Ogni modifica è un passo annullabile (⌘Z). La marca del progetto si sceglie in Monta, dal pulsante Marca.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(loc("menu.undo")) { store.undo() }
                        .disabled(demo || !(store.undoNames.last?.hasPrefix("brandkit.") ?? false))
                }
                if let problem { Text(verbatim: problem).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { sync() }
        .onChange(of: kit) { _, _ in sync() }
    }

    static func cornerName(_ c: String) -> String {
        switch c {
        case "topLeft": "In alto a sinistra"
        case "topCenter": "In alto al centro"
        case "topRight": "In alto a destra"
        case "bottomLeft": "In basso a sinistra"
        default: "In basso a destra"
        }
    }

    private func sync() {
        name = kit.name
        colors = kit.colors
        width = placement.width
        opacity = placement.opacity ?? 1
        library.preview(kit, slot: "settings", store: store, width: 360)
    }

    private func perform(_ id: String, _ params: JSONValue) {
        guard !demo else { return }
        Task {
            do {
                try await store.perform(id, params)
                problem = nil
            } catch {
                problem = StepError.readable(error, fallback: "Il motore ha risposto: %@")
            }
            library.reload()
        }
    }

    private func commitName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != kit.name else { name = kit.name; return }
        perform("brandkit.update", ["kit": .string(kit.id), "name": .string(n)])
    }

    private func colorBinding(_ role: String) -> Binding<Color> {
        Binding(get: { Color(hexString: colors[role] ?? kit.colors[role] ?? "#808080") }, set: { c in
            guard let hex = Self.hex(c), hex != colors[role] else { return }
            colors[role] = hex
            // One command once the colour panel rests, not one per pixel of a drag.
            colorTask?.cancel()
            colorTask = Task {
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                let changed = colors.filter { kit.colors[$0.key] != $0.value }
                guard !changed.isEmpty else { return }
                perform("brandkit.update", ["kit": .string(kit.id), "colors": .object(changed.mapValues { .string($0) })])
            }
        })
    }

    static func hex(_ c: Color) -> String? {
        guard let n = NSColor(c).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02X%02X%02X", Int((n.redComponent * 255).rounded()), Int((n.greenComponent * 255).rounded()), Int((n.blueComponent * 255).rounded()))
    }

    private func updatePlacement(_ patch: [String: JSONValue]) {
        perform("brandkit.update", ["kit": .string(kit.id), "logoPlacement": .object(patch)])
    }

    private func chooseFont(_ role: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["ttf", "otf", "woff2"].compactMap { UTType(filenameExtension: $0) }
        panel.message = loc("Scegli il file del carattere (TTF, OTF o WOFF2)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("brandkit.setFont", ["kit": .string(kit.id), "path": .string(url.path), "role": .string(role)])
    }

    private func chooseLogo(_ variant: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.svg, .png]
        panel.message = loc("SVG (nitido a ogni misura) o PNG trasparente")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("brandkit.setLogo", ["kit": .string(kit.id), "path": .string(url.path), "variant": .string(variant)])
    }
}
