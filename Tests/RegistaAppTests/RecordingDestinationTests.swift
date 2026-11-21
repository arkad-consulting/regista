import AppKit
@testable import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #39: a finished recording goes somewhere visible. Registra says before recording where the take will go ("Nuovo
// progetto" / "Questo progetto"); a camera take and a screen session follow the same rule (Workbench.recordingTarget),
// and a notice under the tabs says where it went. The recorder never captures here: the workbench gets the recorder's
// callbacks directly, as the app wires them (recordingStarted / recordingStopped / recordingFinished), with synthetic
// takes. Projects are saved in the test process's scratch Regista folder (rigFolder, REGISTA_FOLDER).

private func scratchDefaults() -> UserDefaults { TestDefaults.make("destination-tests") }

/// The recordings folder of these tests: a scratch one, never Regista's (IsolationTests watches that one while they run).
let rigRecordings = rigTempDir("recordings")

/// A workbench without the engine socket, its projects folder in the scratch Regista folder, its takes in
/// `rigRecordings`.
@MainActor private func bench() -> Workbench {
    _ = NSApplication.shared
    _ = rigFolder
    let b = Workbench(defaults: scratchDefaults(), seedFolders: [], socketPath: nil)
    b.recordingsFolder = rigRecordings
    return b
}

@MainActor private func waitFor(_ done: () -> Bool) async throws {
    for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(100)) }
}

/// A camera take named as the recorder names it (540×960 with sound), in the workbench's recordings folder
/// (`rigRecordings`: a take there counts as one of the project's takes, #140).
func cameraTake() throws -> URL {
    let url = rigRecordings.appendingPathComponent("Registrazione 2026-11-15 \(UUID().uuidString.prefix(8)).mov")
    try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: url)
    return url
}

/// A screen-only session as Registra writes it (session.json + screen.mov in "Sessione <date>").
@MainActor private func screenSession(_ tab: EditorStore) async throws -> URL {
    let dir = rigRecordings.appendingPathComponent("Sessione 2026-11-15 \(UUID().uuidString.prefix(8))")
    try await tab.perform("recording.synthesize", ["directory": .string(dir.path), "sources": ["screen"], "duration": 4, "screenSize": [1280, 720]])
    return dir.appendingPathComponent(RecordingSession.fileName)
}

/// A project with a clip in Media and on the timeline (an edit in progress), the clip not one of Regista's takes.
@MainActor private func editedProject(_ tab: EditorStore, _ name: String) async throws {
    try await tab.perform("project.new", ["name": .string(name), "directory": .string(rigTempDir("projects").path)])
    let clip = rigTempDir("clip").appendingPathComponent("clip.mov")
    try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: clip)
    let id = try await tab.perform("media.import", ["path": .string(clip.path)]).value(at: "asset.id")?.stringValue ?? ""
    try await tab.placeOnTimeline(id)
    try await waitFor { tab.project?.duration ?? .zero > .zero }
}

private func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL }

/// The notice's line after a take (#140).
private func saved(_ name: String, takes: Int) -> String {
    loc("Ripresa salvata in «%@» · %@", name, Plural.text(takes, "1 ripresa", "%d riprese"))
}

@MainActor
@Test func aTakeFromAnEditedProjectWithNuovoProgettoBecomesANewProjectInANewTab() async throws {
    let b = bench()
    let one = b.newTab()
    b.select(one.tabID)
    try await editedProject(one, "montaggio")
    #expect(one.recordingDestination == .thisProject, "a tab with a project: this project by default (#140)")
    one.recordingChoice = .newProject
    b.nav.select(.record)
    b.recordingStarted()
    b.recordingStopped()
    let file = try cameraTake()
    let tab = b.recordingFinished(file, session: false)
    try await waitFor { b.notice != nil }
    #expect(tab !== one && b.tabs.count == 2 && b.activeID == one.tabID, "the new project's tab is not a new tab left unselected")
    let p = try #require(tab.project)
    #expect(p.name.hasPrefix(file.deletingPathExtension().lastPathComponent), "named \(p.name)")
    // Saved in the projects folder (the scratch one here), listed in the recent projects.
    #expect(same(tab.projectURL?.deletingLastPathComponent(), EditorStore.projectsFolder) && EditorStore.projectsFolder.path.hasPrefix(rigFolder.path))
    #expect(tab.projectURL.map { FileManager.default.fileExists(atPath: $0.path) } == true && !tab.dirty)
    #expect(b.recents.paths.contains { $0.hasSuffix("/\(p.name).regista") }, "not in the recent projects: \(b.recents.paths)")
    // The take on its timeline, in the take's own format, shown in Media and the Pro editor.
    #expect(p.settings.width == 540 && p.settings.height == 960, "format \(p.settings.width)×\(p.settings.height)")
    #expect(p.tracks.flatMap(\.clips).count == 2 && tab.sourceAssetID == p.assets.first?.id)
    #expect(b.nav.activity == .record, "the window left Registra")
    #expect(b.notice == Workbench.Notice(text: saved(p.name, takes: 1), file: file, take: .init(tabID: tab.tabID, assetID: p.assets[0].id)))
    #expect(one.project?.assets.count == 1, "the project being edited changed")
    // The agent sees the new tab.
    let list = try await Task.detached { try b.agentExecute("project.list", [:], client: "claude-code") }.value
    #expect(list["tabs"]?.arrayValue?.count == 2)
}

@MainActor
@Test func aTakeFromAnEmptyTabBecomesTheProjectOfThatTab() async throws {
    let b = bench()
    let one = b.newTab(), two = b.newTab()
    try await editedProject(two, "altro")
    b.select(one.tabID)
    #expect(one.recordingDestination == .newProject)
    b.recordingStarted()
    b.select(two.tabID)   // the user went to another tab while recording
    b.recordingStopped()
    let tab = b.recordingFinished(try cameraTake(), session: false)
    try await waitFor { b.notice != nil }
    #expect(tab === one && b.tabs.count == 2 && b.activeID == two.tabID && one.projectURL != nil, "the take's tab was selected")
    #expect(one.project?.tracks.flatMap(\.clips).count == 2)
}

@MainActor
@Test func aTakeGoesIntoTheTabsProjectWhileItIsEmpty() async throws {
    let b = bench()
    let one = b.newTab()
    b.select(one.tabID)
    try await one.perform("project.new", ["name": "vuoto", "directory": .string(rigTempDir("projects").path)])
    try await waitFor { one.project != nil }
    #expect(one.recordingDestination == .thisProject, "an empty project: this project by default")
    b.recordingStarted()
    // Media imported while recording: the take still goes where Registra said.
    try await one.perform("media.import", ["path": .string(try cameraTake().path)])
    try await waitFor { one.project?.assets.count == 1 }
    #expect(one.recordingDestination == .thisProject)
    b.recordingStopped()
    let file = try cameraTake()
    let tab = b.recordingFinished(file, session: false)
    try await waitFor { b.notice != nil }
    let p = try #require(one.project)
    #expect(tab === one && b.tabs.count == 1 && p.name == "vuoto")
    // In Media, selected there, and on the timeline (it was empty).
    #expect(p.assets.count == 2 && one.sourceAssetID == p.assets[1].id && p.tracks.flatMap(\.clips).map(\.assetID) == [p.assets[1].id, p.assets[1].id])
    #expect(b.notice == Workbench.Notice(text: saved("vuoto", takes: 2), file: file, take: .init(tabID: one.tabID, assetID: p.assets[1].id)))
}

@MainActor
@Test func thisProjectChosenKeepsTheTimelineAndTheChoiceStaysWithTheTab() async throws {
    let b = bench()
    let one = b.newTab(), two = b.newTab()
    b.select(one.tabID)
    try await editedProject(one, "montaggio")
    one.recordingChoice = .thisProject
    b.select(two.tabID)
    b.select(one.tabID)
    #expect(one.recordingDestination == .thisProject && two.recordingDestination == .newProject, "the choice is per tab")
    let clips = one.project?.tracks.flatMap(\.clips).map(\.id)
    b.recordingStarted()
    b.select(two.tabID)
    b.recordingStopped()
    let tab = b.recordingFinished(try cameraTake(), session: false)
    try await waitFor { b.notice != nil }
    let p = try #require(one.project)
    #expect(tab === one && b.activeID == two.tabID && b.tabs.count == 2)
    #expect(p.assets.count == 2 && one.sourceAssetID == p.assets[1].id && p.tracks.flatMap(\.clips).map(\.id) == clips,
            "the take must join Media only: \(p.assets.count) assets")
    // A screen session chosen into the same project joins Media too, the timeline untouched.
    b.select(one.tabID)
    b.recordingStarted()
    b.recordingStopped()
    _ = b.recordingFinished(try await screenSession(one), session: true)
    try await waitFor { one.project?.assets.count == 3 }
    #expect(one.project?.assets.count == 3 && one.project?.tracks.flatMap(\.clips).map(\.id) == clips && b.tabs.count == 2)
}

@MainActor
@Test func aTabClosedWhileRecordingSendsTheTakeToANewTab() async throws {
    let b = bench()
    let one = b.newTab(), two = b.newTab()
    try await one.perform("project.new", ["name": "vuoto", "directory": .string(rigTempDir("projects").path)])
    try await waitFor { one.project != nil }
    b.select(one.tabID)
    b.recordingStarted()
    b.remove(one)   // what closing the tab does once the recorder stopped
    b.recordingStopped()
    let tab = b.recordingFinished(try cameraTake(), session: false)
    try await waitFor { b.notice != nil }
    #expect(tab !== one && tab !== two && b.tabs.count == 2 && b.activeID != tab.tabID && tab.projectURL != nil)
}

@MainActor
@Test func aScreenSessionFollowsTheSameRule() async throws {
    let b = bench()
    let one = b.newTab()
    b.select(one.tabID)
    try await editedProject(one, "montaggio")
    one.recordingChoice = .newProject
    let session = try await screenSession(one)
    b.recordingStarted()
    b.recordingStopped()
    let tab = b.recordingFinished(session, session: true)
    try await waitFor { b.notice != nil }
    let p = try #require(tab.project)
    #expect(tab !== one && b.activeID == one.tabID && p.name.hasPrefix("Registrazione "), "named \(p.name)")
    #expect(p.settings.width == 1920 && p.settings.height == 1080 && p.recordings?.count == 1 && !p.tracks.flatMap(\.clips).isEmpty)
    #expect(same(tab.projectURL?.deletingLastPathComponent(), EditorStore.projectsFolder))
    #expect(b.notice?.file == session.deletingLastPathComponent() && b.notice?.text == saved(p.name, takes: 1))
}

/// #140: takes in a row from an empty tab on Registra make one project, in that tab: the first on the timeline, the
/// next only in Media, selected there; Registra stays on screen and the notice counts the project's takes. A third take
/// with «Nuovo progetto» chosen makes a new project, in a new tab that is not selected.
@MainActor
@Test func takesInARowJoinOneProjectAndRegistraStays() async throws {
    let b = bench()
    let one = b.newTab()
    b.select(one.tabID)
    b.nav.select(.record)
    func take() throws -> URL {
        b.recordingStarted()
        b.recordingStopped()
        let file = try cameraTake()
        b.recordingFinished(file, session: false)
        return file
    }
    let first = try take()
    try await waitFor { b.notice != nil }
    #expect(one.project != nil && b.notice?.text == saved(one.project?.name ?? "", takes: 1), "\(String(describing: b.notice))")
    let second = try take()
    try await waitFor { b.notice != nil }
    let p = try #require(one.project)
    #expect(b.tabs.count == 1 && b.activeID == one.tabID, "\(b.tabs.count) tabs")
    #expect(b.nav.activity == .record, "the window left Registra: \(b.nav.activity)")
    #expect(p.assets.map(\.path) == [first.path, second.path], "assets \(p.assets.map(\.name))")
    let clips = p.tracks.flatMap(\.clips)
    #expect(clips.count == 2 && clips.allSatisfy { $0.assetID == p.assets[0].id }, "only the first take goes on the timeline")
    #expect(one.sourceAssetID == p.assets[1].id, "the second take is not selected in Media")
    #expect(b.notice == Workbench.Notice(text: saved(p.name, takes: 2), file: second, take: .init(tabID: one.tabID, assetID: p.assets[1].id)))
    // «Nuovo progetto», chosen on Registra: a new project, in a new tab left where it is.
    one.recordingChoice = .newProject
    _ = try take()
    try await waitFor { b.notice != nil }
    #expect(b.tabs.count == 2 && b.activeID == one.tabID && b.nav.activity == .record)
    let other = try #require(b.tabs.last?.project)
    #expect(other.name != p.name && other.assets.count == 1 && one.project?.assets.count == 2)
    #expect(b.notice?.text == saved(other.name, takes: 1) && b.notice?.take?.tabID == b.tabs.last?.tabID)
}

/// #140: the automatic edit after a take is off unless the person turned it on (the registered default; a stored
/// choice is not touched by the registration).
@Test func theAutomaticEditAfterATakeIsOffByDefault() {
    Prefs.registerDefaults()
    let registered = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
    #expect(registered[Prefs.autoEditKey] as? Bool == false)
}

/// The takes a project holds: its files in the recordings folder, a session's files once; a file from elsewhere is none.
@Test func theTakesOfAProjectAreItsRecordings() {
    let rec = URL(fileURLWithPath: "/tmp/r/Registrazioni")
    var p = Project(name: "p")
    func add(_ path: String) { p.assets.append(MediaAsset(id: "a\(p.assets.count)", name: "x", path: path, duration: .zero)) }
    add(rec.appendingPathComponent("Registrazione 1.mov").path)
    add(rec.appendingPathComponent("Sessione 1/screen.mov").path)
    add(rec.appendingPathComponent("Sessione 1/camera.mov").path)
    add("/tmp/elsewhere/clip.mov")
    #expect(EditorStore.takeCount(p, recordings: rec) == 2)
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct RecordDestinationMouseTests {
    private func hostRecord(_ app: AppRig, size: CGSize = CGSize(width: 1440, height: 900), language: String? = nil) {
        let recorder = app.recorder
        app.store.bench.recordingsFolder = rigRecordings
        app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: size, language: language) {
            AnyView($0.environment(\.recordDemo, RecordDemo(sources: recorder.sources)))
        }
    }

    /// On a tab with an edited project: "Questo progetto" is chosen (#140) and the line under it names the project; a
    /// click on "Nuovo progetto" chooses it, once, and the line says a new tab; a click on "Questo progetto" goes back.
    @Test func theChoiceOnRecordAnswersTheMouse() async throws {
        let app = try await AppRig()
        defer { app.close() }
        hostRecord(app)
        await app.settle()
        let this = try #require(app.rig.element("Questo progetto"), "no Questo progetto on Registra")
        #expect(this.selected && WindowPart.side.contains(this.centre), "Questo progetto is not the default")
        #expect(!app.rig.elements(containing: "Va nei Media di «clicks»").isEmpty, "the line does not name the project")
        let record = try #require(app.rig.elements(containing: "Avvia / Ferma registrazione").first, "no Record button")
        #expect(this.frame.maxY <= record.frame.minY, "the choice is not right above the Record button")
        let n = app.store.activity.count
        app.rig.click(try #require(app.rig.element("Nuovo progetto")).centre)
        await app.settle()
        #expect(app.store.recordingChoice == .newProject && app.store.recordingDestination == .newProject)
        #expect(app.rig.element("Nuovo progetto")?.selected == true, "Nuovo progetto is not shown chosen")
        #expect(!app.rig.elements(containing: "Diventa un nuovo progetto in una nuova scheda").isEmpty)
        #expect(app.commands(since: n).isEmpty, "the choice ran a command")
        app.rig.click(try #require(app.rig.element("Questo progetto")).centre)
        await app.settle()
        #expect(app.store.recordingChoice == .thisProject && app.rig.element("Questo progetto")?.selected == true)
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("record-destination.png")) }
    }

    /// The defaults: an empty project chooses "Questo progetto"; a tab without a project has no choice, only the line.
    @Test func theChoiceDefaultsFollowTheTab() async throws {
        let empty = try await AppRig(project: "empty")
        hostRecord(empty)
        await empty.settle()
        #expect(empty.rig.element("Questo progetto")?.selected == true, "an empty project does not default to Questo progetto")
        empty.close()
        let none = try await AppRig(project: nil)
        defer { none.close() }
        hostRecord(none)
        await none.settle()
        #expect(none.rig.element("Questo progetto") == nil && none.rig.element("Nuovo progetto") == nil)
        #expect(!none.rig.elements(containing: "Diventa un nuovo progetto in questa scheda").isEmpty)
    }

    /// After a take: Registra stays on screen with one line saying where the take went and how many takes the project
    /// holds (#140); "Mostra nel Finder" shows the file, × closes the notice.
    @Test func theNoticeAfterATakeAndItsButtons() async throws {
        let app = try await AppRig()
        defer { app.close() }
        hostRecord(app)
        await app.settle()
        let bench = app.store.bench
        bench.recordingStarted()
        bench.recordingStopped()
        let file = try cameraTake()
        let tab = bench.recordingFinished(file, session: false)
        try await waitFor { bench.notice != nil }
        await app.settle()
        await app.idle(0.3)
        let name = try #require(tab.project?.name)
        #expect(tab === app.store && bench.nav.activity == .record, "the take left Registra")
        let line = try #require(app.rig.elements(containing: saved(name, takes: 1)).first, "no notice on screen")
        #expect(WindowPart.main.contains(line.centre) && line.frame.minY < 120, "the notice is not under the tabs: \(line.frame)")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("recording-notice.png")) }
        let events = RigGuard.events.count
        // The button reads as its tooltip.
        let finder = "Mostra il file della registrazione nel Finder"
        #expect(app.rig.click(finder))
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .finder && $0.detail == file.lastPathComponent },
                "Mostra nel Finder did not show the take: \(RigGuard.events.dropFirst(events))")
        #expect(bench.notice != nil && app.rig.element(finder) != nil, "the notice went away after Mostra nel Finder")
        #expect(app.rig.click("Chiudi l'avviso"))
        await app.settle()
        #expect(bench.notice == nil && app.rig.elements(containing: "Ripresa salvata in").isEmpty, "× did not close the notice")
    }

    /// «Vai al montaggio» on the notice: the editor on Media, Pro, with the take in Source, after one click; the notice
    /// goes; the take's tab comes forward when another one was on screen.
    @Test func goToEditingOpensTheTakeInTheEditor() async throws {
        let app = try await AppRig()
        defer { app.close() }
        hostRecord(app)
        await app.settle()
        let bench = app.store.bench
        let home = app.store
        bench.recordingStarted()
        bench.recordingStopped()
        let tab = bench.recordingFinished(try cameraTake(), session: false)
        try await waitFor { bench.notice != nil }
        let take = try #require(bench.notice?.take)
        // Another asset in Source meanwhile, and a second tab on screen: the button brings both back.
        home.sourceAssetID = home.project?.assets.first?.id
        bench.openNewTab()
        bench.nav.select(.record)
        await app.settle()
        await app.idle(0.3)
        #expect(bench.activeID != tab.tabID)
        let n = app.store.activity.count
        #expect(app.rig.click("Apri il montaggio con questa ripresa in Sorgente"), "no Vai al montaggio on the notice")
        await app.settle()
        #expect(bench.activeID == tab.tabID && bench.nav.activity == .media && bench.nav.level == .pro, "\(bench.nav)")
        #expect(tab.sourceAssetID == take.assetID, "the take is not in Source")
        #expect(bench.notice == nil, "the notice stayed")
        #expect(home.activity.dropFirst(n).isEmpty, "the button ran a command")
    }

    /// The automatic edit turned on: the take's tab and the editor come forward and the edit starts (as before #140).
    @Test func theAutomaticEditOnOpensTheEditorAndRunsTheEdit() async throws {
        let app = try await AppRig(project: nil)
        let stored = UserDefaults.standard.object(forKey: Prefs.autoEditKey)
        defer {
            app.store.jobs.cancelAll()
            UserDefaults.standard.set(stored, forKey: Prefs.autoEditKey)
            app.close()
        }
        UserDefaults.standard.set(true, forKey: Prefs.autoEditKey)
        app.followRecorder()
        hostRecord(app)
        await app.settle()
        let bench = app.store.bench
        bench.recordingStarted()
        bench.recordingStopped()
        app.recorder.onFinished?(try cameraTake())
        #expect(await app.until(20) { app.store.project != nil && bench.nav.activity == .media && bench.nav.level == .pro },
                "the editor did not open: \(bench.nav)")
        #expect(await app.until(20) { app.store.jobs.latest(TextStep.allJobKind) != nil }, "the automatic edit did not start")
    }

    /// The notice in a narrow main area (the minimum window, both side panels, French: the long language): the line is
    /// drawn whole (on two lines if it must), «Afficher dans le Finder» gives way to its icon, which shows the file; × still closes it (#80).
    @Test func theNoticeIsReadInANarrowMainArea() async throws {
        let app = try await AppRig()
        defer { app.close() }
        hostRecord(app, size: RigWindowSize.minimum.size, language: "fr")
        await app.settle()
        let bench = app.store.bench
        bench.recordingStarted()
        bench.recordingStopped()
        let file = try cameraTake()
        let tab = bench.recordingFinished(file, session: false)
        try await waitFor { bench.notice != nil }
        await app.settle()
        await app.idle(0.3)
        let name = try #require(tab.project?.name)
        let text = saved(name, takes: 1)
        let line = try #require(app.rig.elements().first { $0.visible && $0.role == "AXStaticText" && $0.value == text }, "no notice on screen")
        let natural = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: Ed.TypeSize.body, weight: .medium)]).width
        // Whole: on one line, or on as many lines as its words need in the room it has.
        let lineHeight = NSFont.systemFont(ofSize: Ed.TypeSize.body, weight: .medium).boundingRectForFont.height
        let lines = max(1, (line.frame.height / (lineHeight * 0.95)).rounded(.down))
        #expect(line.frame.width * lines >= natural * 1.05 || line.frame.width >= natural - 1,
                "the notice is cut: \(line.frame.width)×\(line.frame.height) pt for \(natural) pt on one line")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("recording-notice-narrow-fr.png")) }
        let events = RigGuard.events.count
        let finder = loc("Mostra il file della registrazione nel Finder")
        let button = try #require(app.rig.controls().first { $0.label == finder }, "no Finder button: \(app.rig.controls().map(\.description))")
        #expect(button.frame.width < 40, "the Finder button did not give way to its icon: \(button.frame)")
        app.rig.click(button.centre)
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .finder && $0.detail == file.lastPathComponent },
                "the icon did not show the take: \(RigGuard.events.dropFirst(events))")
        #expect(app.rig.click(loc("Chiudi l'avviso")))
        await app.settle()
        #expect(bench.notice == nil, "× did not close the notice")
    }
}
}
