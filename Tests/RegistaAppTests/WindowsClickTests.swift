import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The app's other windows and the project tabs, clicked through (#29): Settings (every tab, through its own tab bar),
// the Help window, the Marca picker (the brand kit gallery of the toolbar), and the project tab strip with two tabs
// (select, close, "+"). Controls that would write the owner's data are not clicked and say why: the voice profiles
// and the forced tier live in the owner's Application Support, the Claude clients' configuration in the home folder,
// the engines' installers download and install.

/// The defaults the Settings window writes (the test process's own domain): put back after each Settings audit.
private let settingsKeys = [SettingsRoute.tabKey, SettingsRoute.engineKey, GeneralPrefs.folderKey, GeneralPrefs.formatKey,
                            GeneralPrefs.autoSaveKey, GeneralPrefs.spokenLanguageKey, Accent.followKey]

extension MouseSuites {
@Suite(.serialized) @MainActor struct WindowsClickTests {
    @Test(arguments: SettingsTab.allCases)
    func settings(_ tab: SettingsTab) async throws {
        let saved = settingsKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsRoute.tabKey)
        let app = try await AppRig()
        defer { app.close() }
        let status = try await app.store.silent("engines.status")
        // General: the window itself (a hosted TabView shows its first tab). Brand kit: the tab's own view, live. The other
        // tabs: their content under the drawn tab strip (`pinned`; the tab items belong to the Settings window's toolbar,
        // which a hosted view does not have). The voice tab draws the sample profiles and voice.
        let engines = EnginesDemo(status: status, tier: nil)
        let root: AnyView
        switch tab {
        case .general: root = AnyView(SettingsView(engines: engines, voiceProfiles: VoiceDemo.profiles))
        case .brand: root = AnyView(BrandKitSettings(demo: false).frame(width: SettingsView.size.width, height: SettingsView.size.height))
        default: root = AnyView(SettingsView(pinned: tab, engines: engines, voiceProfiles: VoiceDemo.profiles))
        }
        app.host(root.environment(\.voiceDemo, VoiceDemo.model("ready", tier: nil)).environment(\.colorScheme, .dark)
            .background(Color(nsColor: .windowBackgroundColor)), size: SettingsView.size)
        await app.settle()
        let notDriven = "NOT VERIFIED: a native AppKit control of the system form, which the rig's synthetic events do not drive reliably"
        let owner = "writes the voice profiles of the person running the tests (Application Support), never touched by a test"
        let rows = await ClickAudit(app: app, screen: "settings-\(tab.rawValue)", skip: [
            "Crea profilo": owner, "È mio": owner, "Usa questo profilo": owner, "Elimina": owner, "Sposta nel Cestino": owner,
            "Installa": "runs the engine's installer (downloads and installs on the machine running the tests)",
            "Accetto la licenza": "runs the engine's installer", "Rimuovi": "removes an installed engine from the machine running the tests",
            "Forza livello": "writes engines.json in the owner's Application Support",
            "Collega": "writes the Claude clients' configuration in the home folder",
            "Copia le istruzioni": "replaces the clipboard of the person running the tests",
        ], noOps: [
            SettingsTab.allCases.first { $0 == tab }!.title: "the tab already shown",
            "Gestisci voci": "the sample voice model runs nothing (VoiceDemo); the live model's window entry is clicked in ScreenClickTests.voiceEntriesOpenTheVoiceWindow",
            // NOT VERIFIED by a click: the system form's own AppKit controls (bordered buttons, check boxes, fields) do not
            // take the rig's synthetic events reliably — the same control answered in one run and not in the next.
            "Nuovo kit": notDriven, "Importa…": notDriven, "Nome del kit": notDriven, "0": notDriven, "1": notDriven,
        ], restore: {
            for (k, v) in saved where k != SettingsRoute.tabKey { UserDefaults.standard.set(v, forKey: k) }
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsRoute.tabKey)
        }, skipRoles: [
            "AXTextField": "NOT VERIFIED: a native text field of the system form, which the rig's synthetic events do not drive reliably",
            "AXColorWell": "a native colour well (the kit form keeps the system ColorPicker): a press starts AppKit's colour drag, tracked in a loop until the real mouse moves; the design system's ColorSwatch is clicked in ControlMouseTests",
            "AXPopUpButton": "a native pop-up (Settings keeps the system form): AppKit tracks its menu in a modal loop until a real click picks an item; its menu opening was seen with a click, a choice in it is not driven",
        ]).run()
        ClickAudit.check(rows, screen: "settings-\(tab.rawValue)")
    }

    @Test func help() async throws {
        let app = try await AppRig()
        defer { app.close() }
        let center = HelpCenter()
        app.host(HelpView(center: center), size: HelpView.size)
        await app.settle()
        let rows = await ClickAudit(app: app, screen: "help", noOps: [
            HelpGuide.userGuide.title: "the guide already shown",
            "Scorciatoie da tastiera": "opens Settings with SwiftUI's openSettings, which a hosted view has no scene for (the route it writes is checked here)",
        ], restore: { center.guide = .userGuide }).run()
        ClickAudit.check(rows, screen: "help")
        #expect(rows.contains { $0.control.contains("Segnala un problema") && $0.effect.contains("url:") }, "Segnala un problema opened no page")
    }

    /// The Marca picker (the toolbar's popover): every kit applies itself to the project.
    @Test func brandPicker() async throws {
        let app = try await AppRig()
        defer { app.close() }
        BrandKitLibrary.shared.reload()
        app.host(BrandPicker().frame(width: BrandPicker.width, height: BrandPicker.height(kits: BrandKitLibrary.shared.kits.count))
            .background(Ed.side).environment(\.colorScheme, .dark),
                 size: CGSize(width: BrandPicker.width, height: BrandPicker.height(kits: BrandKitLibrary.shared.kits.count)))
        await app.settle()
        let rows = await ClickAudit(app: app, screen: "brand-picker", noOps: [
            "Gestisci": "opens Settings › Brand kit with SwiftUI's openSettings, which a hosted view has no scene for",
        ]).run()
        ClickAudit.check(rows, screen: "brand-picker")
    }

    /// Two project tabs: a click on the other tab selects it, its × closes it, "+" opens an empty tab on Inizio.
    @Test func projectTabs() async throws {
        let app = try await AppRig()
        defer { app.close() }
        let other = app.store.bench.newTab()
        try await other.perform("project.new", ["name": "seconda"])
        for _ in 0..<100 where other.project == nil { try await Task.sleep(for: .milliseconds(50)) }
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector))
        await app.settle()
        let bench = app.store.bench
        let first = bench.activeID
        // The tabs' × buttons, left to right, in the strip above the main area (their names are the tabs' tooltips).
        func closes() -> [RigElement] {
            app.rig.elements().filter { $0.role == "AXButton" && $0.frame.minY < 80 && $0.frame.width <= 20 && $0.frame.minX > 352 && $0.visible }
                .sorted { $0.frame.minX < $1.frame.minX }
        }
        let second = try #require(closes()[safe: 1], "the second tab is not on screen")
        app.rig.click(CGPoint(x: second.frame.minX - 50, y: second.centre.y))
        await app.settle()
        #expect(bench.activeID == other.tabID, "a click on a tab did not select it")
        // Its ×: the new project is not saved, so it asks; Non salvare.
        RigGuard.alertAnswer = .alertThirdButtonReturn
        app.rig.click(try #require(closes()[safe: 1]).centre)
        await app.idle(0.3)
        await app.settle()
        RigGuard.alertAnswer = .alertSecondButtonReturn
        #expect(bench.tabs.count == 1 && bench.activeID == first, "the × did not close the tab (\(bench.tabs.count) tabs)")
        #expect(app.rig.click("Nuova scheda"))
        await app.settle()
        #expect(bench.tabs.count == 2 && bench.active.isEmpty && bench.nav.activity == .home, "+ did not open an empty tab on Inizio")
    }

    /// The track header's right-click menu (a SwiftUI context menu) and its Blocca la pista.
    @Test func trackHeaderMenu() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector))
        await app.settle()
        let v1 = try #require(app.rig.elements().first { $0.role == "AXStaticText" && $0.value == "V1" })
        RigGuard.lastMenu = nil
        let events = RigGuard.events.count
        app.rig.rightClick(CGPoint(x: v1.frame.maxX + 40, y: v1.centre.y))
        guard let menu = RigGuard.lastMenu else {
            withKnownIssue("a synthetic right click did not reach the track header on this run (see the timeline's)", isIntermittent: true) {
                Issue.record("no menu: \(RigGuard.events.dropFirst(events))")
            }
            return
        }
        let i = try #require(menu.items.firstIndex { $0.title == "Blocca la pista" }, "items: \(menu.items.map(\.title))")
        let n = app.store.activity.count
        menu.performActionForItem(at: i)
        await app.settle()
        #expect(app.commands(since: n) == ["track.set"])
    }
}
}
