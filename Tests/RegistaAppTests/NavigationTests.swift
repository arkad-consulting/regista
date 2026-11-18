import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// S1 (#75): the activities of the window shell, the editor's level, the Graphics panel's sections (E4 #3) and the
// right panel's tab; N0 (#49): the recent projects.

private func appTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-app-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A `.regista` folder with a project.json written at `date`.
@discardableResult
private func makeProject(_ name: String, in dir: URL, date: Date) throws -> URL {
    let folder = dir.appendingPathComponent("\(name).regista")
    try ProjectStore.save(Project(name: name, settings: ProjectSettings()), to: folder)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: folder.appendingPathComponent(ProjectStore.fileName).path)
    return folder
}

private func scratchDefaults() -> UserDefaults {
    let name = "regista-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

@Test func activitiesFollowTheBarAndTheEditorReturnsToTheLastLevel() {
    var nav = Navigation()
    #expect(nav.activity == .home && nav.workspace == .home && !nav.inEditor)
    nav.select(.texts)
    #expect(nav.workspace == .pro && nav.inEditor)            // nothing used yet: Pro
    nav.show(.simple)                                         // Semplice: the side panel stays on Testi
    #expect(nav.activity == .texts && nav.workspace == .simple)
    nav.select(.export)
    #expect(nav.workspace == .export && !nav.inEditor)
    nav.showEditor()                                         // the project tab: back to Testi, at Semplice
    #expect(nav.activity == .texts && nav.workspace == .simple)
    nav.select(.record)
    nav.show(.pro)                                           // a recording opened in Pro goes to the last library activity
    #expect(nav.activity == .texts && nav.level == .pro)
    nav.select(.audio)
    #expect(nav.workspace == .pro && nav.level == .pro)
}

@Test func shortcutsFollowTheActivityBarOrder() {
    #expect(Navigation.Activity.allCases == [.home, .record, .media, .texts, .audio, .voice, .graphics, .generate, .export])
    #expect(Navigation.Activity.allCases.map(\.shortcut) == (1...9).map { "⌘\($0)" })
    #expect(Navigation.Activity.allCases.filter(\.isLibrary) == [.media, .texts, .audio, .voice, .graphics, .generate])
    // D1's stored screens come back as the editor on Media.
    #expect(Navigation.Activity(stored: "pro") == .media && Navigation.Activity(stored: "quick") == .media)
    #expect(Navigation.Activity(stored: "export") == .export && Navigation.Activity(stored: "bogus") == nil)
}

/// E4 (#3): no Studio sub-screen any more — effects, looks, styles and motion templates are sections of the Graphics
/// panel in the side panel, and every category of the effects catalog belongs to exactly one section.
@MainActor
@Test func graphicsSectionsOpenInTheSidePanelWithTheEditorInTheMainArea() {
    var nav = Navigation(activity: .export, level: .simple)
    nav.showGraphics(.styles)
    #expect(nav.activity == .graphics && nav.graphicsSection == .styles && nav.workspace == .simple && nav.inEditor)
    nav.show(.pro)
    #expect(nav.activity == .graphics && nav.graphicsSection == .styles && nav.workspace == .pro)
    let all = Navigation.GraphicsSection.allCases.flatMap(\.categories)
    #expect(all.count == Set(all).count && Set(all) == Set(EffectsCatalog.Category.allCases))
    #expect(AppUIHost.navigation(for: "graphics-motion", current: Navigation()).graphicsSection == .motion)
    #expect(AppUIHost.navigation(for: "graphics-motion", current: Navigation()).activity == .graphics)
}

@Test func launchRestoresTheLastActivityAndTheRightPanelTab() {
    let export = Navigation.restored(activity: "export", level: "quick", rightTab: "claude", hasRecents: true)
    #expect(export.activity == .export && export.level == .simple && export.rightTab == .claude)
    let voice = Navigation.restored(activity: "voice", level: "quick", rightTab: "inspector", hasRecents: true)
    #expect(voice.activity == .voice && voice.workspace == .simple && voice.rightTab == .inspector)
    // D1's remembered Monta comes back as the editor at the remembered level.
    let monta = Navigation.restored(activity: "pro", level: "quick", rightTab: nil, hasRecents: true)
    #expect(monta.activity == .media && monta.workspace == .simple && monta.rightTab == .prompter)
    // Nothing to come back to, or nothing remembered: Inizio (the level and the tab are still remembered).
    let empty = Navigation.restored(activity: "export", level: "quick", rightTab: "claude", hasRecents: false)
    #expect(empty.activity == .home && empty.level == .simple && empty.rightTab == .claude)
    #expect(Navigation.restored(activity: nil, level: nil, rightTab: nil, hasRecents: true).activity == .home)
    let bogus = Navigation.restored(activity: "bogus", level: "export", rightTab: "bogus", hasRecents: true)
    #expect(bogus.level == .pro && bogus.rightTab == .prompter && bogus.activity == .home)
}

/// The store remembers the activity, the level and the right panel's tab in the user defaults; a new store (the next
/// launch) starts there.
@MainActor
@Test func storeRemembersActivityLevelAndRightTabAcrossLaunches() throws {
    _ = NSApplication.shared
    setenv("REGISTA_ENGINE_SOCKET", appTempDir().appendingPathComponent("e.sock").path, 1)
    let defaults = scratchDefaults(), seeds = appTempDir()
    try makeProject("recente", in: seeds, date: Date())
    let store = EditorStore(defaults: defaults, seedFolders: [seeds])
    store.select(.graphics)
    store.workspace = .simple
    store.nav.rightTab = .claude
    #expect(defaults.string(forKey: Navigation.activityKey) == "graphics")
    let next = EditorStore(defaults: defaults, seedFolders: [seeds])
    #expect(next.nav.activity == .graphics && next.workspace == .simple && next.nav.rightTab == .claude)
    // D1's key alone (an older install) opens the editor on Media.
    let old = scratchDefaults()
    old.set("pro", forKey: Navigation.legacyWorkspaceKey)
    #expect(EditorStore(defaults: old, seedFolders: [seeds]).nav.activity == .media)
}

@Test func recentListOrdersCapsAndPrunes() {
    var list: [String] = []
    for i in 1...25 { list = RecentList.adding("/tmp/p\(i).regista", to: list) }
    #expect(list.count == RecentList.cap)
    #expect(list.first == "/tmp/p25.regista" && list.last == "/tmp/p6.regista")
    // Opening one again moves it to the front without duplicating it; project.json paths count as the folder.
    list = RecentList.adding("/tmp/p10.regista/project.json", to: list)
    #expect(list.first == "/tmp/p10.regista" && list.filter { $0 == "/tmp/p10.regista" }.count == 1 && list.count == RecentList.cap)
    // Pruning keeps the order of what still exists.
    let kept = RecentList.pruned(list) { $0.hasSuffix("0.regista") }
    #expect(kept == ["/tmp/p10.regista", "/tmp/p20.regista"])
}

@MainActor
@Test func recentListIsSeededOnceFromTheMediaRootNewestFirst() throws {
    let root = appTempDir(), sub = root.appendingPathComponent("Progetti")
    let now = Date()
    let old = try makeProject("old", in: root, date: now.addingTimeInterval(-3600 * 24))
    let new = try makeProject("new", in: sub, date: now.addingTimeInterval(-60))
    let mid = try makeProject("mid", in: root, date: now.addingTimeInterval(-3600))
    // A folder without project.json is not a project.
    try FileManager.default.createDirectory(at: root.appendingPathComponent("broken.regista/media"), withIntermediateDirectories: true)
    let found = RecentList.projectFolders(in: [root, sub])
    #expect(found.map(\.path) == [new, mid, old].map { $0.standardizedFileURL.path })

    let defaults = scratchDefaults()
    let recents = RecentProjects(defaults: defaults, seedFolders: [root, sub])
    #expect(recents.paths == [new, mid, old].map { $0.standardizedFileURL.path })
    #expect(defaults.stringArray(forKey: RecentProjects.key) == recents.paths)
    // Seeded once: a project created later in the media root is not added by the next launch…
    let later = try makeProject("later", in: root, date: now)
    #expect(!RecentProjects(defaults: defaults, seedFolders: [root, sub]).paths.contains(later.standardizedFileURL.path))
    // …only opening or saving it adds it, at the front.
    recents.note(later)
    #expect(recents.paths.first == later.standardizedFileURL.path)
    // A project whose folder is gone is skipped and pruned, also from the stored list.
    try FileManager.default.removeItem(at: mid)
    recents.prune()
    #expect(!recents.paths.contains(mid.standardizedFileURL.path))
    #expect(RecentProjects(defaults: defaults, seedFolders: []).paths == recents.paths)
}

/// #24: the private render copy of scripts/ui-shots.sh starts with REGISTA_NO_RECENT_SEED=1: its first launch seeds the
/// recent list from no folder, so a render never shows the person's projects.
@MainActor
@Test func theRenderCopySeedsNoRecentProject() throws {
    let root = appTempDir()
    _ = try makeProject("sample", in: root, date: Date())
    let defaults = scratchDefaults()
    #expect(RecentProjects(defaults: defaults, seedFolders: [root], environment: ["REGISTA_NO_RECENT_SEED": "1"]).paths.isEmpty)
    #expect(RecentProjects(defaults: scratchDefaults(), seedFolders: [root], environment: [:]).paths.count == 1)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let shots = try String(contentsOf: repo.appendingPathComponent("scripts/ui-shots.sh"), encoding: .utf8)
    #expect(shots.contains("REGISTA_NO_RECENT_SEED=1 REGISTA_ENGINE_SOCKET=\"$SOCK\" \"$PRIV/Regista.app/Contents/MacOS/Regista\""))
}

@Test func recentRowsReadNameDateAndDuration() async throws {
    let dir = appTempDir()
    let date = Date(timeIntervalSince1970: 1_800_000_000)
    let folder = try makeProject("Reel di prova", in: dir, date: date)
    try FileManager.default.moveItem(at: folder, to: dir.appendingPathComponent("Reel di prova v2.regista"))
    let infos = await RecentProjects.load([dir.appendingPathComponent("Reel di prova v2.regista").path, dir.appendingPathComponent("missing.regista").path])
    #expect(infos.count == 1)
    #expect(infos.first?.name == "Reel di prova v2" && infos.first?.modified == date && infos.first?.duration == 0)
    #expect(infos.first?.thumbnail == nil)   // no video clip: the neutral tile
}

@Test func freeNameAvoidsExistingProjects() throws {
    let dir = appTempDir()
    #expect(EditorStore.freeName("Video senza volto", in: dir) == "Video senza volto")
    try makeProject("Video senza volto", in: dir, date: Date())
    try makeProject("Video senza volto 2", in: dir, date: Date())
    #expect(EditorStore.freeName("Video senza volto", in: dir) == "Video senza volto 3")
}

@Test func engineSummaryCountsTheEnginesReady() throws {
    let status = try JSONValue.parse(#"{"tier": "pro", "memoryGB": 48, "engines": [{"id": "ffmpeg", "enabled": true}, {"id": "blender", "enabled": false}, {"id": "vision", "enabled": true}]}"#)
    #expect(EngineSummary(status: status) == EngineSummary(memoryGB: 48, tier: "pro", ready: 2, total: 3))
    #expect(EngineSummary(status: ["ok": true]) == nil)
}

// MARK: - Window shell

/// RGBA of one pixel, as a single number.
private func pixel(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> UInt32 {
    let p = rep.bitmapData! + y * rep.bytesPerRow + x * 4
    return UInt32(p[0]) << 24 | UInt32(p[1]) << 16 | UInt32(p[2]) << 8 | UInt32(p[3])
}

/// The whole window rendered for every activity (and the editor's two levels, and each Graphics section): the right panel is drawn
/// at the same place with the same width everywhere — its left edge on the same column, its pixels identical — and the
/// title row does not change.
@MainActor
@Test func rightPanelIsTheSameOnEveryActivity() async throws {
    _ = NSApplication.shared
    setenv("REGISTA_ENGINE_SOCKET", appTempDir().appendingPathComponent("e.sock").path, 1)
    let defaults = scratchDefaults()
    let store = EditorStore(defaults: defaults, seedFolders: [])
    let recorder = Recorder(defaults: defaults)
    let meter = LoudnessMeter()
    // An open project: its tab (unsaved dot, name, ×) is drawn on top of the main area.
    try await store.perform("project.new", ["name": "take-3437"])
    // Until the store publishes it (up to 20 s: a fixed pause failed on a busy Mac, #80).
    for _ in 0..<200 where !(store.project?.name == "take-3437" && store.dirty) { try await Task.sleep(for: .milliseconds(100)) }
    #expect(store.project?.name == "take-3437" && store.dirty)
    let width = 1440, height = 900
    func render(_ nav: Navigation) throws -> NSBitmapImageRep {
        let root = EditorRoot(live: false)
            .environmentObject(store).environmentObject(store.preview).environmentObject(store.preview.playhead)
            .environmentObject(store.media).environmentObject(meter).environmentObject(recorder)
            .environment(\.navOverride, nav)
            .environment(\.recordDemo, RecordDemo(sources: recorder.sources))
            .environment(\.voiceDemo, VoiceDemo.model("ready", tier: nil))
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: rep)
        w.contentView = nil
        return rep
    }
    var states: [(String, Navigation)] = []
    for a in Navigation.Activity.allCases {
        var n = Navigation(activity: a, rightTab: .inspector)   // a static tab: the Gobbo checks the speech engine
        n.select(a)
        states.append((a.rawValue, n))
    }
    var semplice = Navigation(activity: .media, level: .simple, rightTab: .inspector)
    semplice.show(.simple)
    states.append(("edit-semplice", semplice))
    for section in Navigation.GraphicsSection.allCases {
        var g = Navigation(activity: .graphics, rightTab: .inspector)
        g.showGraphics(section)
        states.append(("graphics-\(section.rawValue)", g))
    }
    let shots = try states.map { try render($0.1) }
    if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
        for (s, rep) in zip(states, shots) {
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("shell-\(s.0).png"))
        }
    }
    let left = width - Int(Chrome.rightWidth)
    /// Whether the pixel is about this sRGB colour (the bitmap is device RGB).
    func near(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, _ hex: UInt32) -> Bool {
        let v = pixel(rep, x, y)
        let got = [Int(v >> 24 & 0xFF), Int(v >> 16 & 0xFF), Int(v >> 8 & 0xFF)], want = [Int(hex >> 16 & 0xFF), Int(hex >> 8 & 0xFF), Int(hex & 0xFF)]
        return zip(got, want).allSatisfy { abs($0 - $1) <= 4 }
    }
    for (i, rep) in shots.enumerated() {
        // The panel's left hairline (Chrome.line) is the column x = width − 320, its background (Chrome.side) right after.
        #expect(near(rep, left, height - 60, 0x2F2F31) && near(rep, left + 1, height - 60, 0x202022),
                "\(states[i].0): the right panel does not start at x = \(left)")
        var differing = 0, titleDiffering = 0
        for y in 0..<height {
            for x in left..<width where pixel(rep, x, y) != pixel(shots[0], x, y) { differing += 1 }
        }
        for y in 0..<Int(Chrome.titleHeight) {
            for x in 0..<width where pixel(rep, x, y) != pixel(shots[0], x, y) { titleDiffering += 1 }
        }
        #expect(differing == 0, "\(states[i].0) vs \(states[0].0): \(differing) pixels of the right panel differ")
        #expect(titleDiffering == 0, "\(states[i].0) vs \(states[0].0): \(titleDiffering) pixels of the title row differ")
    }
    // And the comparison is not comparing blanks: the main areas differ.
    let mid = (Int(Chrome.activityWidth) + left) / 2
    #expect((0..<height).contains { y in pixel(shots[0], mid, y) != pixel(shots[2], mid, y) })
}

@Test func everyCommandHasAHumanTitle() {
    let missing = RegistaCore.Commands.all.map { $0.id }.filter { !CommandTitles.has($0) }
    #expect(missing.isEmpty, "commands without a title: \(missing)")
}

/// The Claude tab (owner's report, 2026-11-12): looks (read-only commands) do not get rows of their own; consecutive
/// looks by the same source collapse into one quiet row; steps that change something, failed looks and looks by
/// another source break the run.
@MainActor
@Test func claudeLogCollapsesConsecutiveLooks() {
    func a(_ id: String, _ kind: CommandKind, source: String = "Claude", failed: Bool = false) -> EditorStore.Activity {
        var x = EditorStore.Activity(source: source, isAgent: source == "Claude", command: id, params: "",
                                     readOnly: ActivityFeed.isLook(id, kind: kind))
        x.status = failed ? .failed : .ok
        return x
    }
    #expect(ActivityFeed.isLook("ui.screenshot", kind: .query) && ActivityFeed.isLook("project.state", kind: .query))
    #expect(!ActivityFeed.isLook("export.render", kind: .query) && !ActivityFeed.isLook("captions.generate", kind: .edit))
    let items = (0..<17).map { _ in a("ui.screenshot", .query) }
        + [a("captions.generate", .edit), a("project.state", .query), a("frame.render", .query),
           a("frame.render", .query, failed: true), a("ui.screenshot", .query), a("ui.screenshot", .query, source: "Tu"),
           a("export.render", .query)]
    let rows = ActivityFeed.rows(items)
    func kind(_ r: ActivityFeed.Row) -> String {
        switch r {
        case .step(let x): "step \(x.command)"
        case .looks(let l): "looks \(l.count)"
        }
    }
    #expect(rows.map(kind) == ["looks 17", "step captions.generate", "looks 2", "step frame.render", "looks 1", "looks 1", "step export.render"])
    if case .looks(let l) = rows[0] { #expect(ActivityFeed.summary(l) == "Claude · Guarda la finestra · 17 volte") }
    if case .looks(let l) = rows[2] { #expect(ActivityFeed.summary(l) == "Claude · 2 controlli") }
}

/// The traffic lights are placed by macOS, never moved by hand: with the shell's title bar (an empty unified compact
/// toolbar) the three buttons share one centre, on the middle of the title bar macOS lays out.
@MainActor
@Test func trafficLightsShareOneCentreOnTheNativeTitleBar() {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    WindowChrome.configure(w)
    w.layoutIfNeeded()
    let f = WindowChrome.trafficLightFrames(w)
    #expect(f.count == 3)
    #expect(Set(f.map(\.midY)).count == 1, "the three buttons are not on one line: \(f)")
    let bar = WindowChrome.titleBarHeight(w)
    #expect(bar >= 28 && abs((f.first?.midY ?? 0) - bar / 2) <= 1)
    #expect(f.count == 3 && abs((f[1].minX - f[0].minX) - (f[2].minX - f[1].minX)) < 0.5)   // even spacing
}

/// One top band (owner feedback, build 827da88: "the space above is much bigger than in other Mac apps"): the title row's
/// controls are an item of the native toolbar, inside its band, and the SwiftUI content starts right under that band:
/// its first row's top edge equals the toolbar height, with no second band.
@MainActor
@Test func contentStartsRightUnderTheToolbarBand() {
    _ = NSApplication.shared
    final class Top { var y: CGFloat? }
    let top = Top()
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    let items = NSHostingView(rootView: Color.red.frame(width: 140, height: 24))
    WindowChrome.configure(w, items: items)
    let host = NSHostingView(rootView: VStack(spacing: 0) {
        Color.blue.onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top.y = $0 }
    })
    w.contentView = host
    w.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let bar = WindowChrome.titleBarHeight(w)
    #expect(bar >= 28 && bar <= 52, "toolbar band \(bar) pt")
    #expect(abs((top.y ?? -1) - bar) <= 0.5, "content starts at \(top.y ?? -1) pt, the toolbar band is \(bar) pt")
    // The controls are in the band, on the traffic lights' line.
    #expect(WindowChrome.titleItems(w) === items)
    let r = items.convert(items.bounds, to: nil)
    let midY = w.frame.height - r.midY
    #expect(abs(midY - (WindowChrome.trafficLightFrames(w).first?.midY ?? 0)) <= 1, "controls centred at \(midY) pt")
}

/// The Claude tab names who looked in words: "Claude" for any agent (a socket client that called itself "client" or
/// "regista-mcp"), "Tu" for the user; never the client's name.
@MainActor
@Test func claudeLogNamesWhoLookedInWords() {
    let raw = EditorStore.Activity(source: "client", isAgent: true, command: "ui.screenshot", params: "", readOnly: true)
    let mcp = EditorStore.Activity(source: "regista-mcp", isAgent: true, command: "ui.screenshot", params: "", readOnly: true)
    let user = EditorStore.Activity(source: "Tu", isAgent: false, command: "project.state", params: "", readOnly: true)
    #expect(ActivityFeed.summary(Array(repeating: raw, count: 4)) == "Claude · Guarda la finestra · 4 volte")
    #expect(ActivityFeed.summary([mcp]) == "Claude · Guarda la finestra")
    #expect(ActivityFeed.summary([user]) == "Tu · Leggi il progetto")
    #expect(ActivityFeed.summary([raw, user]).hasPrefix("Claude · "))
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct FacelessVideoKindTests {
    /// Inizio › «Video senza volto», clicked: a project of the voice-over video's kind, its rules and not a talking-head
    /// reel's (#93).
    @Test func theFacelessCardMakesAVoiceOverVideo() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.hostEditor(Navigation(activity: .home, rightTab: .inspector))
        await app.settle()
        let card = try #require(app.rig.controls().first { $0.label.hasPrefix(loc("Video senza volto")) }, "no «Video senza volto» card")
        app.rig.click(card.centre)
        for _ in 0..<100 where app.store.bench.active.project == nil { await app.idle(0.05) }
        await app.settle()
        let store = app.store.bench.active
        #expect(store.project?.kind == "voice-over-video", "the card made a project of kind \(store.project?.kind ?? "none")")
        #expect(store.nav.activity == .voice, "the card did not open the Voce panel")
    }
}
}
