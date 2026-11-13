import AppKit
import RegistaCore
import SwiftUI

/// The Settings window's tabs (M2 #59).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, engines, voice, claude, shortcuts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: loc("Generale")
        case .engines: loc("Motori")
        case .voice: loc("Profilo e voce")
        case .claude: loc("Claude")
        case .shortcuts: loc("Scorciatoie")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .engines: "cpu"
        case .voice: "person.wave.2"
        case .claude: "sparkles"
        case .shortcuts: "keyboard"
        }
    }

    /// The `ui.screenshot` workspace that renders this tab.
    var screenshotName: String { "settings-\(self == .voice ? "voice" : self == .general ? "general" : rawValue)" }  // l10n-ignore — an id
}

/// Which tab the Settings window shows and which engine row it scrolls to: the activity bar's Motori button, Inizio's
/// engine line and the "Installa" links of disabled features set them before opening Settings.
enum SettingsRoute {
    static let tabKey = "settings.tab"
    static let engineKey = "settings.engine"

    /// Selects the tab (and the engine row) the next time Settings shows, then opens it.
    @MainActor static func open(_ tab: SettingsTab, engine: String? = nil, with openSettings: OpenSettingsAction) {
        UserDefaults.standard.set(tab.rawValue, forKey: tabKey)
        if let engine { UserDefaults.standard.set(engine, forKey: engineKey) } else { UserDefaults.standard.removeObject(forKey: engineKey) }
        openSettings()
        NSApp.activate()
    }
}

/// Impostazioni › Generale.
enum GeneralPrefs {
    static let folderKey = "general.folder"
    static let formatKey = "general.format"
    static let autoSaveKey = "general.autosave"
    /// The language the transcription step starts from (the steps panel's own choice, `StepSettings.languageKey`).
    static let spokenLanguageKey = StepSettings.languageKey

    /// The formats a new project can start in: id, label, pixel size.
    static let formats: [(id: String, width: Int, height: Int)] = [("9:16", 1080, 1920), ("4:5", 1080, 1350), ("1:1", 1080, 1080), ("16:9", 1920, 1080)]

    static func formatName(_ id: String) -> String {
        switch id {
        case "9:16": loc("Verticale 9:16 · Reel, TikTok")
        case "4:5": loc("Feed 4:5")
        case "1:1": loc("Quadrato 1:1")
        default: loc("Orizzontale 16:9 · YouTube")
        }
    }

    /// project.new parameters for a new project made from the app (Inizio, File › Nuovo, a first import): the default
    /// format's size. A screen recording keeps its own 16:9.
    static func newProject(name: String, directory: URL, _ d: UserDefaults = .standard) -> JSONValue {
        let f = formats.first { $0.id == d.string(forKey: formatKey) } ?? formats[0]
        return ["name": .string(name), "directory": .string(directory.path), "width": .number(Double(f.width)), "height": .number(Double(f.height))]
    }

    // MARK: Interface language

    /// "" = follow macOS; else the language Regista uses from its next launch (the app's own AppleLanguages).
    static let interfaceLanguages = ["", "it", "en", "fr", "pt"]

    static func interfaceLanguageName(_ code: String) -> String {
        code.isEmpty ? loc("Come macOS") : VoiceLanguages.name(code)
    }

    /// The app's own choice (not the system list every app inherits).
    static var interfaceLanguage: String {
        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.arkad.regista")
        return (domain?["AppleLanguages"] as? [String])?.first.map { String($0.prefix(2)) } ?? ""
    }

    static func setInterfaceLanguage(_ code: String) {
        if code.isEmpty { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }
}

/// Saves every open project that has a folder and unsaved changes, once a minute, when Impostazioni › Generale ›
/// Salvataggio automatico is on (off by default). Untitled projects are never saved behind the user's back.
@MainActor
enum AutoSave {
    private static var timer: Timer?

    static func start(_ bench: Workbench) {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak bench] _ in
            Task { @MainActor in
                guard UserDefaults.standard.bool(forKey: GeneralPrefs.autoSaveKey), let bench else { return }
                for tab in due(bench.tabs.map { ($0.project != nil, $0.dirty, $0.projectURL != nil) }) { bench.tabs[tab].run("project.save") }
            }
        }
    }

    /// The tabs to save: a project, unsaved changes, a folder.
    nonisolated static func due(_ tabs: [(hasProject: Bool, dirty: Bool, hasFolder: Bool)]) -> [Int] {
        tabs.indices.filter { tabs[$0].hasProject && tabs[$0].dirty && tabs[$0].hasFolder }
    }
}

/// Redraws its content when a tab's jobs change (an install's progress).
struct ObservingJobs<Content: View>: View {
    @ObservedObject var jobs: JobCenter
    @ViewBuilder let content: (JobCenter) -> Content
    var body: some View { content(jobs) }
}

/// Redraws its content when the window's agent state changes.
struct ObservingBench<Content: View>: View {
    @ObservedObject var bench: Workbench
    @ViewBuilder let content: (Workbench) -> Content
    var body: some View { content(bench) }
}
