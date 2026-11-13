import RegistaCore
import SwiftUI

/// Impostazioni (M2 #59): Generale, Motori, Profilo e voce, Claude, Scorciatoie. The tab follows `SettingsRoute` (the
/// activity bar's Motori button and the "Installa" links open it on Motori); a render pins one tab and draws it from
/// injected data.
struct SettingsView: View {
    @AppStorage(SettingsRoute.tabKey) private var stored = SettingsTab.general.rawValue
    /// A render: this tab, never the stored one (nothing is written), under a drawn copy of the window's tab bar (an
    /// offscreen TabView draws its toolbar tabs blank).
    var pinned: SettingsTab? = nil
    var engines: EnginesDemo? = nil
    var voiceProfiles: [ProfileSettings.ProfileRow]? = nil
    /// A render's height (a long Motori list drawn whole); nil: the window's.
    var height: CGFloat? = nil

    static let size = CGSize(width: 720, height: 600)
    /// The height a render of Motori needs to show every engine.
    static let enginesRenderHeight = 2560

    var body: some View {
        if let pinned {
            VStack(spacing: 0) {
                SettingsTabStrip(selected: pinned)
                Divider()
                content(pinned).frame(maxHeight: .infinity)
            }
            .frame(width: Self.size.width, height: height ?? Self.size.height)
        } else {
            TabView(selection: $stored) {
                ForEach(SettingsTab.allCases) { t in
                    content(t).tabItem { Label(t.title, systemImage: t.symbol) }.tag(t.rawValue)
                }
            }
            .frame(width: Self.size.width, height: Self.size.height)
        }
    }

    @ViewBuilder private func content(_ t: SettingsTab) -> some View {
        switch t {
        case .general: GeneralSettings(demo: pinned != nil)
        case .engines: EnginesSettings(demo: engines)
        case .voice: ProfileSettings(demoProfiles: voiceProfiles)
        case .claude: ClaudeSettings()
        case .shortcuts: ShortcutsSettings()
        }
    }
}

/// The Settings window's toolbar tabs as macOS draws them (icon over title, the selected one on a soft plate).
private struct SettingsTabStrip: View {
    let selected: SettingsTab

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { t in
                VStack(spacing: 3) {
                    Image(systemName: t.symbol).font(Ed.icon(17)).frame(height: 20)
                    Text(verbatim: t.title).font(Ed.icon(11))
                }
                .foregroundStyle(t == selected ? Color.accentColor : .secondary)
                .frame(minWidth: 76).padding(.horizontal, 6).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(t == selected ? Color.primary.opacity(0.08) : .clear))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(.bar)
    }
}

/// Impostazioni › Generale: languages, Regista's folder, the format of new projects, automatic saving.
private struct GeneralSettings: View {
    /// A render: shows the values, writes nothing.
    var demo = false
    @AppStorage(GeneralPrefs.spokenLanguageKey) private var spoken = StepSettings.appLanguage
    @AppStorage(GeneralPrefs.formatKey) private var format = GeneralPrefs.formats[0].id
    @AppStorage(GeneralPrefs.autoSaveKey) private var autoSave = false
    @AppStorage(GeneralPrefs.folderKey) private var folder = ""
    @State private var interface = GeneralPrefs.interfaceLanguage
    @State private var changedInterface = false

    var body: some View {
        Form {
            Section {
                Picker("Lingua dell'interfaccia", selection: Binding(get: { interface }, set: { v in
                    interface = v
                    guard !demo else { return }
                    GeneralPrefs.setInterfaceLanguage(v)
                    changedInterface = true
                })) {
                    ForEach(GeneralPrefs.interfaceLanguages, id: \.self) { code in Text(verbatim: languageLabel(code)).tag(code) }
                }
                Picker("Lingua del parlato", selection: demo ? .constant(spoken) : $spoken) {
                    ForEach(StepSettings.languages, id: \.self) { code in Text(verbatim: StepSettings.languageName(code)).tag(code) }
                }
            } header: { Text("Lingue") } footer: {
                Text(verbatim: changedInterface ? loc("La nuova lingua dell'interfaccia vale dalla prossima apertura di Regista.")
                     : loc("La lingua del parlato è quella da cui parte la trascrizione di un video nuovo: si cambia anche nei passi di Testi e sottotitoli."))
            }
            Section {
                LabeledContent("Cartella di Regista") {
                    HStack(spacing: 8) {
                        Text(verbatim: (Paths.root.path as NSString).abbreviatingWithTildeInPath).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Scegli…") { choose() }.disabled(demo)
                        if !folder.isEmpty { Button("Predefinita") { folder = "" }.disabled(demo) }
                    }
                }
                Picker("Formato dei progetti nuovi", selection: demo ? .constant(format) : $format) {
                    ForEach(GeneralPrefs.formats, id: \.id) { f in Text(verbatim: GeneralPrefs.formatName(f.id)).tag(f.id) }
                }
                Toggle("Salvataggio automatico", isOn: demo ? .constant(autoSave) : $autoSave)
            } header: { Text("Progetti") } footer: {
                Text("I progetti, le registrazioni e gli export vanno nella cartella di Regista. Con il salvataggio automatico, ogni minuto Regista salva i progetti aperti che hanno già una cartella; quelli mai salvati li salvi tu con ⌘S. Una registrazione dello schermo resta sempre in 16:9.")
            }
        }
        .formStyle(.grouped)
    }

    private func languageLabel(_ code: String) -> String { GeneralPrefs.interfaceLanguageName(code) }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = Paths.root
        p.message = loc("La cartella dove Regista mette progetti, registrazioni ed export")
        guard p.runModal() == .OK, let url = p.url else { return }
        folder = url.path
    }
}

/// Impostazioni › Scorciatoie: the app's shortcut catalog (the one the menus use), searchable.
private struct ShortcutsSettings: View {
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            TextField("Cerca un comando o un tasto", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 4)
            Form {
                let groups = AppShortcuts.search(query)
                if groups.isEmpty { Text("Nessuna scorciatoia trovata").foregroundStyle(.secondary) }
                ForEach(groups, id: \.group) { g in
                    Section(g.group.title) {
                        ForEach(g.items) { s in
                            LabeledContent { KeyCaps(text: s.display) } label: { Text(verbatim: loc(s.title)) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// "⇧⌘R" drawn as a key cap.
private struct KeyCaps: View {
    let text: String
    var body: some View {
        Text(verbatim: text).font(Ed.icon(12, .medium)).monospacedDigit()
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

/// The person this Regista belongs to and their cloned voice (#41, V1 #61). Switching, adopting and deleting a profile
/// happen only here (human-only commands): an agent can never pick someone else's voice. Every action is a command
/// (profile.*), logged like the others; recording and training open the guided flow in the main window.
struct ProfileSettings: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.voiceDemo) private var demo
    /// A demo render's profiles (name, locked, active).
    var demoProfiles: [ProfileRow]? = nil

    struct ProfileRow: Equatable, Identifiable {
        var id: String
        var name: String
        var active: Bool
        var locked: Bool
    }

    var body: some View {
        ProfileSettingsForm(model: demo ?? store.voice, demoProfiles: demoProfiles)
    }
}

private struct ProfileSettingsForm: View {
    @ObservedObject var model: VoiceModel
    var demoProfiles: [ProfileSettings.ProfileRow]?
    @EnvironmentObject private var store: EditorStore
    @State private var profiles: [ProfileSettings.ProfileRow] = []
    @State private var newName = ""
    @State private var error: String?
    @State private var deleting: ProfileSettings.ProfileRow?

    private var rows: [ProfileSettings.ProfileRow] { demoProfiles ?? profiles }

    var body: some View {
        Form {
            Section {
                if let name = model.snapshot.profile, !model.snapshot.profileLocked {
                    LabeledContent("Profilo attivo") { Text(verbatim: name) }
                    if model.snapshot.languages.isEmpty {
                        Text("Nessuna voce ancora: registra il blocco neutro del copione (circa 10 minuti) e Regista parlerà con la tua voce.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.snapshot.languages) { l in
                        LabeledContent { Text(verbatim: VoiceSummary.line(l)).foregroundStyle(.secondary) } label: {
                            Text(verbatim: VoiceLanguages.name(l.code))
                        }
                    }
                    HStack {
                        Spacer()
                        Button(model.snapshot.languages.isEmpty ? loc("Registra la tua voce…") : loc("Registra o allena la voce…")) { openFlow() }
                            .keyboardShortcut(.defaultAction)
                    }
                    if !model.snapshot.engineAvailable {
                        Text(verbatim: VoicePanelState.engineReason(model.snapshot, lookup: loc)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nessun profilo su questo Mac: crea il tuo per registrare e clonare la tua voce.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    TextField("Il tuo nome", text: $newName)
                    Button("Crea profilo") { act(VoiceCalls.createProfile(newName)) { newName = "" } }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: { Text("La tua voce") } footer: {
                Text("La voce resta su questo Mac, nel tuo profilo: non è mai nel pacchetto che condividi. Chi installa Regista parte senza profilo e clona la propria voce.")
            }
            if rows.count > 1 || rows.contains(where: \.locked) {
                Section("Profili su questo Mac") {
                    ForEach(rows) { e in
                        HStack {
                            Text(verbatim: e.name)
                            if e.locked { Text("creato su un altro Mac").foregroundStyle(.secondary) }
                            Spacer()
                            if e.locked {
                                Button("È mio: usalo qui") { act(.init(id: "profile.adopt", params: ["id": .string(e.id)])) }
                            } else if !e.active {
                                Button("Usa questo profilo") { act(.init(id: "profile.switch", params: ["id": .string(e.id)])) }
                            }
                            Button("Elimina…", role: .destructive) { deleting = e }
                        }
                    }
                }
            } else if let a = rows.first {
                Section {
                    Button("Elimina il mio profilo e la mia voce…", role: .destructive) { deleting = a }
                }
            }
            if let error { Text(verbatim: error).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .task { await reload() }
        .confirmationDialog("Eliminare il profilo e la sua voce?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Sposta nel Cestino", role: .destructive) {
                if let d = deleting { act(.init(id: "profile.delete", params: ["id": .string(d.id)])) }
                deleting = nil
            }
        } message: {
            Text("Registrazioni, clip e modelli della voce vanno nel Cestino.")
        }
    }

    private func reload() async {
        guard demoProfiles == nil, !model.demo else { return }
        if let r = try? await store.silent(VoiceCalls.profile.id) {
            profiles = (r["profiles"]?.arrayValue ?? []).compactMap { p in
                guard let id = p["id"]?.stringValue, let name = p["name"]?.stringValue else { return nil }
                return .init(id: id, name: name, active: p["active"]?.boolValue ?? false, locked: p["locked"] != nil)
            }
        }
        await model.refresh()
    }

    private func act(_ c: VoiceCall, then: @escaping () -> Void = {}) {
        guard demoProfiles == nil, !model.demo else { return }
        Task {
            do {
                try await store.perform(c.id, c.params)
                error = nil
                then()
            } catch {
                self.error = VoiceErrors.readable(error)
            }
            await reload()
        }
    }

    /// The guided flow lives in the main window (it records with the app's microphone).
    private func openFlow() {
        guard !model.demo else { return }
        model.openSetup()
        if let w = store.ui.window { w.makeKeyAndOrderFront(nil) }
        NSApp.activate()
    }
}
