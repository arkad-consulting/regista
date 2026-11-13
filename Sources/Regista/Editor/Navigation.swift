import AVFoundation
import AppKit
import RegistaCore

/// What the window shows (S1 #75, window shell A): the activity chosen in the activity bar (Inizio, Registra, the
/// library activities Media … Genera, Esporta), the level the editor returns to (Semplice = the Quick workspace, or
/// Pro), the right panel's tab and the sub-tabs (sections) of three side panels. Pure UI state (no command); the activity, the level and the right panel's
/// tab survive a relaunch.
struct Navigation: Equatable {
    /// The activity bar, top to bottom: ⌘1…⌘9 follow this order.
    enum Activity: String, CaseIterable, Identifiable {
        case home, record, media, texts, audio, voice, graphics, generate, export
        var id: String { rawValue }

        /// Media … Genera keep the editor in the main area and change the side panel.
        var isLibrary: Bool { ![.home, .record, .export].contains(self) }

        /// ⌘1…⌘9.
        var shortcut: String { "⌘" + String((Self.allCases.firstIndex(of: self) ?? 0) + 1) }

        /// A stored value; the D1 screens ("pro", "quick", "edit") come back as the editor on Media.
        init?(stored: String) {
            if let a = Activity(rawValue: stored) { self = a; return }
            switch stored {
            case "pro", "quick", "edit": self = .media
            default: return nil
            }
        }
    }

    /// The right panel's three tabs, the same on every activity.
    enum RightTab: String, CaseIterable, Identifiable {
        case prompter, claude, inspector
        var id: String { rawValue }
    }

    /// Testi e sottotitoli: the steps from a clip to captions (E2 #54), the captions and script, the transcript, the takes.
    enum TextsTab: String, CaseIterable { case steps, captions, transcript, takes }
    /// Grafica (E4 #3): the sections of the one Graphics panel — looks, adjustments, effects, one-click styles, motion
    /// templates, the logo. Every category of the effects catalog belongs to exactly one (`categories`).
    enum GraphicsSection: String, CaseIterable {
        case filters, adjust, effects, styles, motion, logo

        var categories: [EffectsCatalog.Category] {
            switch self {
            case .filters: [.filters]
            case .adjust: [.adjust]
            case .effects: [.zoom, .motion, .text, .stickers, .transitions, .speed, .captions, .layouts]
            case .styles: [.styles]
            case .motion: [.templates]
            case .logo: [.logo]
            }
        }
    }
    /// Audio: the mix (level, music, voice, tracks), the sound-effect browser (E3 #55).
    enum SoundTab: String, CaseIterable { case mix, sfx }

    private(set) var activity: Activity
    /// The last editor level used (.pro or .quick).
    private(set) var level: EditorStore.Workspace
    /// The library activity the editor comes back to from Inizio, Registra or Esporta.
    private(set) var library: Activity = .media
    var rightTab: RightTab
    var textsTab: TextsTab = .steps
    var graphicsSection: GraphicsSection = .effects
    var soundTab: SoundTab = .mix

    init(activity: Activity = .home, level: EditorStore.Workspace = .pro, rightTab: RightTab = .prompter) {
        self.activity = activity
        self.level = Self.isMonta(level) ? level : .pro
        self.rightTab = rightTab
        if activity.isLibrary { library = activity }
    }

    static func isMonta(_ ws: EditorStore.Workspace) -> Bool { ws == .pro || ws == .quick }

    /// What the main area shows: Inizio, Registra, Esporta, or the editor at its level.
    var workspace: EditorStore.Workspace {
        switch activity {
        case .home: .home
        case .record: .record
        case .export: .export
        default: level
        }
    }

    /// The editor (a library activity) is on screen.
    var inEditor: Bool { activity.isLibrary }

    /// An activity of the bar (or ⌘1…⌘9).
    mutating func select(_ a: Activity) {
        activity = a
        if a.isLibrary { library = a }
    }

    /// A workspace by name (the D1 API many callers keep): Inizio, Registra, Esporta, or the editor at that level, on
    /// the current library activity (the last one used when coming from elsewhere).
    mutating func show(_ ws: EditorStore.Workspace) {
        switch ws {
        case .home: select(.home)
        case .record: select(.record)
        case .export: select(.export)
        case .pro, .quick:
            level = ws
            if !activity.isLibrary { activity = library }
        }
    }

    /// The editor at the level used last.
    mutating func showEditor() { show(level) }

    /// The Graphics panel on one of its sections (the editor stays at its level).
    mutating func showGraphics(_ section: GraphicsSection) {
        if !inEditor { showEditor() }
        select(.graphics)
        graphicsSection = section
    }

    /// The window at launch: the activity used last (Inizio when there is nothing to come back to, no recent project, or
    /// nothing remembered), the editor level and the right panel's tab.
    static func restored(activity: String?, level: String?, rightTab: String?, hasRecents: Bool) -> Navigation {
        let lvl = level.flatMap(EditorStore.Workspace.init(rawValue:)).flatMap { isMonta($0) ? $0 : nil } ?? .pro
        let tab = rightTab.flatMap(RightTab.init(rawValue:)) ?? .prompter
        guard hasRecents, let saved = activity.flatMap(Activity.init(stored:)) else {
            return Navigation(activity: .home, level: lvl, rightTab: tab)
        }
        return Navigation(activity: saved, level: lvl, rightTab: tab)
    }

    static let activityKey = "nav.activity", levelKey = "nav.montaLevel", rightTabKey = "nav.rightTab"
    /// D1's key, read once when the new one is missing.
    static let legacyWorkspaceKey = "nav.workspace"
}

// MARK: - Recent projects

/// The recent projects list as data: standardized `.regista` folder paths, most recent first, capped.
enum RecentList {
    static let cap = 20

    static func normalized(_ path: String) -> String {
        ProjectStore.folder(for: path).standardizedFileURL.path
    }

    /// `path` moved (or added) to the front.
    static func adding(_ path: String, to list: [String], cap: Int = cap) -> [String] {
        let p = normalized(path)
        return Array(([p] + list.filter { $0 != p }).prefix(cap))
    }

    /// Entries whose project still exists.
    static func pruned(_ list: [String], exists: (String) -> Bool = projectExists) -> [String] {
        list.filter(exists)
    }

    static func projectExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(ProjectStore.fileName).path)
    }

    /// The `.regista` folders (with a project.json) directly inside `folders`, newest project.json first.
    static func projectFolders(in folders: [URL]) -> [(path: String, modified: Date)] {
        let fm = FileManager.default
        var found: [(path: String, modified: Date)] = []
        for dir in folders {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for item in items where item.pathExtension == ProjectStore.fileExtension {
                let file = item.appendingPathComponent(ProjectStore.fileName)
                guard let attrs = try? fm.attributesOfItem(atPath: file.path), let date = attrs[.modificationDate] as? Date else { continue }
                found.append((normalized(item.path), date))
            }
        }
        return found.sorted { $0.modified > $1.modified }
    }

    /// The list after a first seeding: what it held, then the found projects (newest first) not already in it.
    static func seeded(_ list: [String], with found: [(path: String, modified: Date)], cap: Int = cap) -> [String] {
        let seeds = found.sorted { $0.modified > $1.modified }.map(\.path)
        var out = list
        for s in seeds where !out.contains(s) { out.append(s) }
        return Array(out.prefix(cap))
    }
}

/// File › Apri recente and the Inizio screen: the projects opened or saved last (by hand or by an agent through MCP),
/// stored in the user defaults. Seeded once from the media root so existing projects show up.
@MainActor
final class RecentProjects: ObservableObject {
    /// What a recent project row shows: `name` is the folder's; `thumbnail` a frame of the project's first video clip.
    struct Info: Identifiable, @unchecked Sendable {
        var id: String { path }
        let path: String
        let name: String
        let modified: Date
        let duration: Double
        let size: CGSize
        var thumbnail: CGImage?
    }

    @Published private(set) var paths: [String]
    @Published private(set) var infos: [Info] = []
    private let defaults: UserDefaults
    private var loading: Task<Void, Never>?
    /// Thumbnails already drawn, by path and project.json date.
    private var thumbs: [String: CGImage] = [:]
    static let key = "recentProjects", seededKey = "recentProjects.seeded"

    /// `seedFolders`: where to look for existing projects the first time (the media root and its Progetti folder).
    init(defaults: UserDefaults = .standard, seedFolders: [URL]? = nil) {
        self.defaults = defaults
        var list = defaults.stringArray(forKey: Self.key) ?? []
        if !defaults.bool(forKey: Self.seededKey) {
            let folders = seedFolders ?? [Paths.root, Paths.root.appendingPathComponent("Progetti", isDirectory: true)]
            list = RecentList.seeded(list, with: RecentList.projectFolders(in: folders))
            defaults.set(true, forKey: Self.seededKey)
        }
        paths = RecentList.pruned(list)
        save()
    }

    var urls: [URL] { paths.map { URL(fileURLWithPath: $0, isDirectory: true) } }

    /// A project was opened or saved (Save As included).
    func note(_ url: URL) {
        paths = RecentList.adding(url.path, to: paths)
        save()
        refresh()
    }

    /// Drops the projects that no longer exist.
    func prune() {
        let kept = RecentList.pruned(paths)
        guard kept != paths else { return }
        paths = kept
        save()
    }

    func clear() {
        paths = []
        infos = []
        save()
    }

    private func save() { defaults.set(paths, forKey: Self.key) }

    /// Reloads the rows (name, date, duration, thumbnail) off the main thread.
    func refresh() {
        prune()
        let list = paths
        loading?.cancel()
        let cached = thumbs
        loading = Task {
            let loaded = await Task.detached(priority: .utility) { await Self.load(list, cached: cached) }.value
            guard !Task.isCancelled else { return }
            self.infos = loaded
            for i in loaded { if let t = i.thumbnail { self.thumbs[Self.thumbKey(i.path, i.modified)] = t } }
        }
    }

    nonisolated static func thumbKey(_ path: String, _ date: Date) -> String { "\(path)|\(date.timeIntervalSince1970)" }

    nonisolated static func load(_ paths: [String], cached: [String: CGImage] = [:]) async -> [Info] {
        var out: [Info] = []
        for path in paths {
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            guard let project = try? ProjectStore.load(from: folder) else { continue }
            let file = folder.appendingPathComponent(ProjectStore.fileName)
            let modified = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date) ?? .distantPast
            var thumb = cached[thumbKey(path, modified)]
            if thumb == nil { thumb = await thumbnail(project) }
            // The folder's name, as File › Apri recente shows it (copies often keep the project name inside).
            out.append(Info(path: path, name: folder.deletingPathExtension().lastPathComponent, modified: modified, duration: project.duration.seconds,
                            size: CGSize(width: project.settings.width, height: project.settings.height), thumbnail: thumb))
        }
        return out
    }

    /// A small frame of the first video clip of the first video track (nil when there is none or it cannot be read).
    nonisolated static func thumbnail(_ project: Project) async -> CGImage? {
        guard let clip = project.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty })?.clips.first,
              let asset = project.asset(clip.assetID), asset.video != nil,
              FileManager.default.fileExists(atPath: asset.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: asset.path)))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        let at = CMTime(seconds: clip.sourceIn.seconds + 0.5, preferredTimescale: 600)
        return try? await generator.image(at: at).image
    }
}

/// The one line about this Mac on Inizio, from engines.status: RAM, tier, engines ready.
struct EngineSummary: Equatable {
    var memoryGB: Int
    var tier: String
    var ready: Int
    var total: Int

    init(memoryGB: Int, tier: String, ready: Int, total: Int) {
        self.memoryGB = memoryGB
        self.tier = tier
        self.ready = ready
        self.total = total
    }

    /// "Ready" = available and allowed by the tier (engines.status `enabled`).
    init?(status: JSONValue) {
        guard let tier = status["tier"]?.stringValue, let engines = status["engines"]?.arrayValue else { return nil }
        self.init(memoryGB: Int(status["memoryGB"]?.doubleValue ?? 0), tier: tier,
                  ready: engines.filter { $0["enabled"] == true }.count, total: engines.count)
    }
}
