import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The app's other windows and the project tabs, clicked through (#29): Settings (every tab, through its own tab bar),
// the Help window, the Marca picker (the brand kit gallery of the toolbar), and the project tab strip with two tabs
// (select, close, "+"). Engines, voice profiles and Claude are the live tabs on the rig's stand-ins (#35): engines.json,
// the engines folder and the installer, the profiles folder, the Claude clients' home and the pasteboard are scratch
// ones, so every control is clicked, and so is every button of the confirmations they open.

/// The defaults the Settings window writes (the test process's own domain): put back after each Settings audit.
private let settingsKeys = [SettingsRoute.tabKey, SettingsRoute.engineKey, GeneralPrefs.folderKey, GeneralPrefs.formatKey,
                            GeneralPrefs.autoSaveKey, GeneralPrefs.spokenLanguageKey, Accent.followKey, SettingsRoute.rulesKey]

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct WindowsClickTests {
    @Test(arguments: SettingsTab.allCases)
    func settings(_ tab: SettingsTab) async throws {
        let saved = settingsKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        // Lingua dell'interfaccia writes AppleLanguages in the test process's own domain: put back as it was there.
        let domain = Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName
        let languages = UserDefaults.standard.persistentDomain(forName: domain)?["AppleLanguages"]
        func restoreLanguages() {
            if let languages { UserDefaults.standard.set(languages, forKey: "AppleLanguages") } else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) }; restoreLanguages() }
        UserDefaults.standard.set(tab.rawValue, forKey: SettingsRoute.tabKey)
        let app = try await AppRig()
        defer { app.close() }
        let status = try await app.store.silent("engines.status")
        // General: the window itself (a hosted TabView shows its first tab). Brand kit: the tab's own view, live. The other
        // tabs: their content under the drawn tab strip (`pinned`; the tab items belong to the Settings window's toolbar,
        // which a hosted view does not have), live, Motori and Claude drawn whole.
        let restoreOutside = try prepareOutside(tab, app: app, status: status)
        let root: AnyView
        var size = SettingsView.size
        switch tab {
        case .general: root = AnyView(SettingsView(engines: EnginesDemo(status: status, tier: nil), voiceProfiles: VoiceDemo.profiles))
        case .brand: root = AnyView(BrandKitSettings(demo: false).frame(width: SettingsView.size.width, height: SettingsView.size.height))
        case .engines, .claude:
            size.height = tab == .engines ? CGFloat(SettingsView.enginesRenderHeight) : 1000
            root = AnyView(SettingsView(pinned: tab, height: size.height))
        default: root = AnyView(SettingsView(pinned: tab))
        }
        app.host(root.environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)), size: size)
        await app.settle()
        await app.idle(0.5)   // the live tabs read engines.status and the profiles
        await app.settle()
        // The system form's own AppKit controls (pop-ups, check boxes, bordered buttons, text fields) are driven through
        // their accessibility actions (#36): press, pick an item, set a value. Synthetic events did not drive them
        // reliably (the same control answered in one run and not in the next).
        let rows = await ClickAudit(app: app, screen: "settings-\(tab.rawValue)", noOps: [
            SettingsTab.allCases.first { $0 == tab }!.title: "the tab already shown",
            "For every video": "Regole: the sheet already shown (the tab opens on it)",
        ], restore: {
            for (k, v) in saved where k != SettingsRoute.tabKey { UserDefaults.standard.set(v, forKey: k) }
            UserDefaults.standard.set(tab.rawValue, forKey: SettingsRoute.tabKey)
            restoreLanguages()
            restoreOutside()
        }, skipRoles: [
            "AXColorWell": "a native colour well (the kit form keeps the system ColorPicker): a press starts AppKit's colour drag, tracked in a loop until the real mouse moves; the design system's ColorSwatch is clicked in ControlMouseTests",
        ], nativeByAccessibility: true).run()
        ClickAudit.check(rows, screen: "settings-\(tab.rawValue)")
        if tab == .claude {
            // The copy landed on the rig's pasteboard (the general one is refused by RigGuard and checked by the proof).
            #expect(rigPasteboard.string(forType: .string) == StartPrompt.text, "Copia le istruzioni did not reach the rig's pasteboard")
        }
    }

    /// The scratch state a live Settings tab starts from, and how to put it back after each click: engine files to remove
    /// (Motori), voice profiles (Profilo e voce), the Claude clients' home (Claude). Everything lives in the rig's scratch
    /// folders (RigIsolation.swift).
    private func prepareOutside(_ tab: SettingsTab, app: AppRig, status: JSONValue) throws -> () -> Void {
        let fm = FileManager.default
        switch tab {
        case .engines:
            // An installed engine's files in the scratch engines folder: its row offers Rimuovi.
            let catalog = EngineCatalog(status: status, enginesDirectory: URL(fileURLWithPath: "/nonexistent"))
            let installed = catalog.rows.filter { $0.state == .installed && ["installer", "homebrew"].contains($0.method) }
            let files = installed.compactMap { r in EngineManifest.shared.entry(r.id)?.files.first }
            let engines = try Data(contentsOf: rigOutside.enginesFile)
            let seed = {
                for f in files {
                    let url = rigOutside.enginesFolder.appendingPathComponent(f)
                    try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: Data("rig".utf8)) }
                }
                try? engines.write(to: rigOutside.enginesFile)
            }
            seed()
            return seed
        case .voice:
            // Three profiles: the active one, another of this Mac, one made on another Mac (locked).
            let profiles = app.store.engine.context.services.profiles
            let e = Engine(services: app.store.engine.context.services)
            _ = try e.execute("profile.create", params: ["name": "Prima"])
            _ = try e.execute("profile.create", params: ["name": "Seconda"])
            let other = ProfileStore(directory: profiles.directory, machine: "another-mac")
            _ = try other.create(name: "Altro Mac")
            let pristine = rigTempDir("profiles-pristine").appendingPathComponent("profiles")
            try fm.copyItem(at: profiles.directory, to: pristine)
            return {
                try? fm.removeItem(at: profiles.directory)
                try? fm.copyItem(at: pristine, to: profiles.directory)
            }
        case .claude:
            let config = rigOutside.desktopConfig
            return { try? fm.removeItem(at: config) }
        case .rules:
            // «For every video» edited (Ripristina il predefinito has something to put back) in the rig's scratch rules
            // folder, put back after each click.
            UserDefaults.standard.removeObject(forKey: SettingsRoute.rulesKey)
            let e = Engine(services: app.store.engine.context.services)
            _ = try e.execute("rules.set", params: ["kind": "every-video", "checks": ["text-size": false]])
            let folder = app.store.engine.context.services.rules.directory
            let pristine = rigTempDir("rules-pristine").appendingPathComponent("rules")
            try fm.copyItem(at: folder, to: pristine)
            return {
                try? fm.removeItem(at: folder)
                try? fm.copyItem(at: pristine, to: folder)
                UserDefaults.standard.removeObject(forKey: SettingsRoute.rulesKey)   // the screen starts on «for every video»
            }
        default:
            return {}
        }
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
        // The tabs' × buttons, left to right, in the strip above the main area (each reads «Chiudi la scheda», #32).
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
