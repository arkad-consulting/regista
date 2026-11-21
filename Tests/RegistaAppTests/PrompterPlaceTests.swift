import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #141: the teleprompter is used only while recording, so it lives on Registra. The right panel's Gobbo tab exists
// there only; everywhere else the panel is Claude · Ispettore, and a stored Gobbo tab opens on the Ispettore. The
// teleprompter's floating window closes when the person leaves Registra, unless a take is running.

@Test func theGobboTabIsRegistrasOnly() {
    for a in Navigation.Activity.allCases {
        #expect(Navigation.tabs(on: a) == (a == .record ? [.prompter, .claude, .inspector] : [.claude, .inspector]), "\(a)")
    }
    var nav = Navigation(activity: .record, rightTab: .prompter)
    nav.select(.media)
    #expect(nav.rightTab == .inspector, "leaving Registra kept the Gobbo tab")
    nav.rightTab = .prompter
    #expect(nav.rightTab == .inspector, "the Gobbo tab came back in the editor")
    nav.select(.record)
    #expect(nav.rightTab == .prompter, "back on Registra the Gobbo tab is not selected")
    nav.show(.simple)
    #expect(nav.workspace == .simple && nav.rightTab == .inspector)
    nav.rightTab = .claude
    nav.select(.export)
    #expect(nav.rightTab == .claude, "a tab chosen in the editor did not stay")
    // At launch: the stored Gobbo tab opens the editor (and Inizio) on the Ispettore, Registra on the Gobbo.
    #expect(Navigation.restored(activity: "media", level: "pro", rightTab: "prompter", hasRecents: true).rightTab == .inspector)
    #expect(Navigation.restored(activity: "export", level: "quick", rightTab: "prompter", hasRecents: true).rightTab == .inspector)
    #expect(Navigation.restored(activity: "media", level: "pro", rightTab: "prompter", hasRecents: false).rightTab == .inspector)
    #expect(Navigation.restored(activity: "record", level: "pro", rightTab: "claude", hasRecents: true).rightTab == .claude)
    #expect(Navigation(activity: .record).rightTab == .prompter && Navigation(activity: .media).rightTab == .inspector)
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct PrompterPlaceMouseTests {
    /// The tab buttons of the right panel, left to right.
    private func tabs(_ app: AppRig) -> [RigElement] {
        let right = RenderParts.right(app.rig.size)
        return app.rig.elements().filter { $0.role == "AXButton" && $0.visible && right.contains($0.centre) && abs($0.frame.minY - right.minY) <= 1
            && abs($0.frame.height - Chrome.headerHeight) <= 1 }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// A click on an activity of the bar.
    private func open(_ a: Navigation.Activity, _ app: AppRig) async throws {
        let title = ActivityInfo.of(a).title
        let item = try #require(app.rig.elements().first { $0.isControl && $0.visible && $0.frame.maxX <= Chrome.activityWidth + 1 && $0.name == title },
                                "no «\(title)» in the activity bar")
        app.rig.click(item.centre)
        await app.settle()
        #expect(app.store.nav.activity == a, "«\(title)» did not open")
    }

    /// Every activity clicked from Registra on its Gobbo tab: Gobbo · Claude · Ispettore on Registra only, Claude ·
    /// Ispettore with the Ispettore chosen everywhere else (the Semplice level too); back on Registra the Gobbo is chosen.
    @Test func theRightPanelsTabsFollowTheActivity() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .record, rightTab: .prompter))
        await app.settle()
        #expect(tabs(app).map(\.name) == ["Gobbo", "Claude", "Ispettore"] && tabs(app).first?.selected == true, "\(tabs(app).map(\.name))")
        for a in Navigation.Activity.allCases where a != .record {
            try await open(.record, app)
            #expect(tabs(app).first { $0.name == "Gobbo" }?.selected == true, "back on Registra the Gobbo is not chosen")
            try await open(a, app)
            let names = tabs(app)
            #expect(names.map(\.name) == ["Claude", "Ispettore"], "\(a): \(names.map(\.name))")
            #expect(names.last?.selected == true && app.store.nav.rightTab == .inspector, "\(a): the Ispettore is not chosen")
        }
        // The Semplice level.
        try await open(.media, app)
        let simple = try #require(app.rig.elements().first { $0.name == "Semplice" && $0.role == "AXButton" }, "no Semplice switch")
        app.rig.click(simple.centre)
        await app.settle()
        #expect(app.store.nav.workspace == .simple && tabs(app).map(\.name) == ["Claude", "Ispettore"], "Semplice: \(tabs(app).map(\.name))")
        // A click on Claude there stays, and Registra opens on its Gobbo again.
        app.rig.click(try #require(tabs(app).first).centre)
        await app.settle()
        #expect(app.store.nav.rightTab == .claude && tabs(app).first?.selected == true)
        try await open(.record, app)
        #expect(tabs(app).map(\.name) == ["Gobbo", "Claude", "Ispettore"] && app.store.nav.rightTab == .prompter)
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try await open(.media, app)
            try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("right-panel-editor.png"))
        }
    }

    /// The stored Gobbo tab (`nav.rightTab = prompter`) opens the editor on the Ispettore.
    @Test func theStoredGobboTabOpensTheEditorOnTheInspector() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation.restored(activity: "media", level: "pro", rightTab: "prompter", hasRecents: true))
        await app.settle()
        #expect(app.store.nav.activity == .media && app.store.nav.rightTab == .inspector)
        #expect(tabs(app).map(\.name) == ["Claude", "Ispettore"] && tabs(app).last?.selected == true, "\(tabs(app).map(\.name))")
    }

    /// The floating window: shown from Registra's Gobbo, it closes when the person leaves Registra and does not come
    /// back by itself; while a take runs it stays, and it closes when the take ends away from Registra.
    @Test func theTeleprompterWindowClosesWhenLeavingRegistra() async throws {
        let app = try await AppRig()
        let p = TeleprompterController.shared
        defer {
            p.hide()
            app.close()
        }
        app.hostEditor(Navigation(activity: .record, rightTab: .prompter))
        await app.settle()
        #expect(app.rig.click("Mostra il gobbo"), "no Mostra il gobbo on Registra")
        await app.settle()
        #expect(p.isVisible, "Mostra il gobbo did not show the window")
        try await open(.media, app)
        #expect(!p.isVisible, "the window stayed after leaving Registra")
        try await open(.record, app)
        #expect(!p.isVisible, "the window came back by itself")
        // A take running: the window stays in the editor, and goes when the take ends there.
        #expect(app.rig.click("Mostra il gobbo"))
        await app.settle()
        let bench = app.store.bench
        bench.recordingStarted()
        try await open(.texts, app)
        #expect(p.isVisible, "the window closed while a take runs")
        bench.recordingStopped()
        #expect(!p.isVisible, "the window stayed after the take ended in the editor")
    }
}
}
