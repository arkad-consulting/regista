import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #39: a finished recording goes somewhere visible. Registra says before recording where the take will go ("Nuovo
// progetto" / "Questo progetto"); a camera take and a screen session follow the same rule (Workbench.recordingTarget),
// and a notice under the tabs says where it went. The recorder never captures here: the workbench gets the recorder's
// callbacks directly, as the app wires them (recordingStarted / recordingStopped / recordingFinished), with synthetic
// takes. Projects are saved in the test process's scratch Regista folder (rigFolder, REGISTA_FOLDER).

private func scratchDefaults() -> UserDefaults {
    let name = "regista-destination-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// A workbench without the engine socket, its projects folder in the scratch Regista folder.
@MainActor private func bench() -> Workbench {
    _ = NSApplication.shared
    _ = rigFolder
    return Workbench(defaults: scratchDefaults(), seedFolders: [], socketPath: nil)
}

@MainActor private func waitFor(_ done: () -> Bool) async throws {
    for _ in 0..<300 where !done() { try await Task.sleep(for: .milliseconds(100)) }
}

/// A camera take named as the recorder names it (540×960 with sound), in a scratch folder.
private func cameraTake() throws -> URL {
    let url = rigTempDir("take").appendingPathComponent("Registrazione 2026-11-15 10.\(Int.random(in: 10...59)).\(Int.random(in: 10...59)).mov")
    try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: url)
    return url
}

/// A screen-only session as Registra writes it (session.json + screen.mov in "Sessione <date>").
@MainActor private func screenSession(_ tab: EditorStore) async throws -> URL {
    let dir = rigTempDir("session").appendingPathComponent("Sessione 2026-11-15 10.00.00")
    try await tab.perform("recording.synthesize", ["directory": .string(dir.path), "sources": ["screen"], "duration": 4, "screenSize": [1280, 720]])
    return dir.appendingPathComponent(RecordingSession.fileName)
}

/// A project with the take in Media and on the timeline (an edit in progress).
@MainActor private func editedProject(_ tab: EditorStore, _ name: String) async throws {
    try await tab.perform("project.new", ["name": .string(name), "directory": .string(rigTempDir("projects").path)])
    let id = try await tab.perform("media.import", ["path": .string(try cameraTake().path)]).value(at: "asset.id")?.stringValue ?? ""
    try await tab.placeOnTimeline(id)
    try await waitFor { tab.project?.duration ?? .zero > .zero }
}

private func same(_ a: URL?, _ b: URL) -> Bool { a?.resolvingSymlinksInPath().standardizedFileURL == b.resolvingSymlinksInPath().standardizedFileURL }

@MainActor
@Test func aTakeFromAnEditedProjectBecomesANewProjectInANewTab() async throws {
    let b = bench()
    let one = b.newTab()
    b.select(one.tabID)
    try await editedProject(one, "montaggio")
    #expect(one.recordingDestination == .newProject, "an edited project: a new project by default")
    b.recordingStarted()
    b.recordingStopped()
    let file = try cameraTake()
    let tab = b.recordingFinished(file, session: false)
    try await waitFor { b.notice != nil }
    #expect(tab !== one && b.tabs.count == 2 && b.activeID == tab.tabID, "the new project's tab is not the selected new tab")
    let p = try #require(tab.project)
    #expect(p.name.hasPrefix(file.deletingPathExtension().lastPathComponent), "named \(p.name)")
    // Saved in the projects folder (the scratch one here), listed in the recent projects.
    #expect(same(tab.projectURL?.deletingLastPathComponent(), EditorStore.projectsFolder) && EditorStore.projectsFolder.path.hasPrefix(rigFolder.path))
    #expect(tab.projectURL.map { FileManager.default.fileExists(atPath: $0.path) } == true && !tab.dirty)
    #expect(b.recents.paths.contains { $0.hasSuffix("/\(p.name).regista") }, "not in the recent projects: \(b.recents.paths)")
    // The take on its timeline, in the take's own format, shown in Media and the Pro editor.
    #expect(p.settings.width == 540 && p.settings.height == 960, "format \(p.settings.width)×\(p.settings.height)")
    #expect(p.tracks.flatMap(\.clips).count == 2 && tab.sourceAssetID == p.assets.first?.id)
    #expect(b.nav.activity == .media && b.nav.level == .pro)
    #expect(b.notice == Workbench.Notice(text: "Registrazione salvata in «\(p.name)»", file: file))
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
    #expect(tab === one && b.tabs.count == 2 && b.activeID == one.tabID && one.projectURL != nil)
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
    // Media imported while recording: the default would now be a new project, the take still goes where Registra said.
    try await one.perform("media.import", ["path": .string(try cameraTake().path)])
    try await waitFor { one.project?.assets.count == 1 }
    #expect(one.recordingDestination == .newProject)
    b.recordingStopped()
    let file = try cameraTake()
    let tab = b.recordingFinished(file, session: false)
    try await waitFor { b.notice != nil }
    let p = try #require(one.project)
    #expect(tab === one && b.tabs.count == 1 && p.name == "vuoto")
    // In Media, selected there, and on the timeline (it was empty).
    #expect(p.assets.count == 2 && one.sourceAssetID == p.assets[1].id && p.tracks.flatMap(\.clips).map(\.assetID) == [p.assets[1].id, p.assets[1].id])
    #expect(b.notice == Workbench.Notice(text: "Registrazione salvata in «vuoto»", file: file))
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
    #expect(tab === one && b.activeID == one.tabID && b.tabs.count == 2)
    #expect(p.assets.count == 2 && one.sourceAssetID == p.assets[1].id && p.tracks.flatMap(\.clips).map(\.id) == clips,
            "the take must join Media only: \(p.assets.count) assets")
    // A screen session chosen into the same project joins Media too, the timeline untouched.
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
    #expect(tab !== one && tab !== two && b.tabs.count == 2 && b.activeID == tab.tabID && tab.projectURL != nil)
}

@MainActor
@Test func aScreenSessionFollowsTheSameRule() async throws {
    let b = bench()
    let one = b.newTab()
    b.select(one.tabID)
    try await editedProject(one, "montaggio")
    let session = try await screenSession(one)
    b.recordingStarted()
    b.recordingStopped()
    let tab = b.recordingFinished(session, session: true)
    try await waitFor { b.notice != nil }
    let p = try #require(tab.project)
    #expect(tab !== one && b.activeID == tab.tabID && p.name.hasPrefix("Registrazione "), "named \(p.name)")
    #expect(p.settings.width == 1920 && p.settings.height == 1080 && p.recordings?.count == 1 && !p.tracks.flatMap(\.clips).isEmpty)
    #expect(same(tab.projectURL?.deletingLastPathComponent(), EditorStore.projectsFolder))
    #expect(b.notice?.file == session.deletingLastPathComponent() && b.notice?.text == "Registrazione salvata in «\(p.name)»")
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct RecordDestinationMouseTests {
    private func hostRecord(_ app: AppRig, size: CGSize = CGSize(width: 1440, height: 900), language: String? = nil) {
        let recorder = app.recorder
        app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: size, language: language) {
            AnyView($0.environment(\.recordDemo, RecordDemo(sources: recorder.sources)))
        }
    }

    /// On a tab with an edited project: "Nuovo progetto" is chosen; a click on "Questo progetto" chooses it, once, and
    /// the line under it names the project; a click on "Nuovo progetto" goes back.
    @Test func theChoiceOnRecordAnswersTheMouse() async throws {
        let app = try await AppRig()
        defer { app.close() }
        hostRecord(app)
        await app.settle()
        let new = try #require(app.rig.element("Nuovo progetto"), "no Nuovo progetto on Registra")
        #expect(new.selected && WindowPart.side.contains(new.centre))
        #expect(!app.rig.elements(containing: "Diventa un nuovo progetto in una nuova scheda").isEmpty)
        let record = try #require(app.rig.elements(containing: "Avvia / Ferma registrazione").first, "no Record button")
        #expect(new.frame.maxY <= record.frame.minY, "the choice is not right above the Record button")
        let n = app.store.activity.count
        app.rig.click(try #require(app.rig.element("Questo progetto")).centre)
        await app.settle()
        #expect(app.store.recordingChoice == .thisProject && app.store.recordingDestination == .thisProject)
        #expect(app.rig.element("Questo progetto")?.selected == true, "Questo progetto is not shown chosen")
        #expect(!app.rig.elements(containing: "Va nei Media di «clicks»").isEmpty, "the line does not name the project")
        #expect(app.commands(since: n).isEmpty, "the choice ran a command")
        app.rig.click(try #require(app.rig.element("Nuovo progetto")).centre)
        await app.settle()
        #expect(app.store.recordingChoice == .newProject && app.rig.element("Nuovo progetto")?.selected == true)
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

    /// After a take: the new project's tab is on screen with one line saying where the take went; "Mostra nel Finder"
    /// shows the file, × closes the notice.
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
        let line = try #require(app.rig.elements(containing: "Registrazione salvata in «\(name)»").first, "no notice on screen")
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
        #expect(bench.notice == nil && app.rig.elements(containing: "Registrazione salvata in").isEmpty, "× did not close the notice")
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
        let text = loc("Registrazione salvata in «%@»", name)
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
