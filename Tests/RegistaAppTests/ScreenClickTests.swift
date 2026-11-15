import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// Every screen of the main window clicked through (#29): the click audit (ClickAudit.swift) finds the controls of each
// screen in its accessibility tree and clicks each one on a fresh copy of the screen. Every control must do something —
// a command, a navigation, a state, a window or panel, a change on screen — or be disabled, or be a no-op named here with
// its reason; nothing may be covered by another control or vanish under the pointer. The window's chrome (title row,
// activity bar, project tabs, toolbar, monitors, timeline, status bar) is audited whole once (`shell`); the other screens
// audit the part of the window that is theirs. The Record screen and the voice panel are drawn from sample values
// (RecordDemo, VoiceDemo), never the live capture or the owner's voice.

/// The parts of the 1440×900 window (title row 40 pt, activity bar 52 pt, side panel 300 pt, right panel 320 pt).
enum WindowPart {
    static let side = CGRect(x: 52, y: 40, width: 296, height: 836)
    static let content = CGRect(x: 52, y: 40, width: 1068, height: 836)
    static let main = CGRect(x: 352, y: 40, width: 768, height: 836)
    static let right = CGRect(x: 1120, y: 40, width: 320, height: 836)
}

/// The no-ops every screen shares: the choice a click names is already the current one.
private let alreadyCurrent = "already the current choice: selecting it again changes nothing"

@MainActor
private func audit(_ screen: String, _ nav: Navigation, project: String? = "rich", area: CGRect? = nil,
                   skip: [String: String] = [:], noOps: [String: String] = [:],
                   skipContaining: [String: String] = [:], restore: @escaping (AppRig) -> Void = { _ in },
                   setup: (AppRig) async throws -> Void = { _ in },
                   extra: (AppRig) -> [(name: String, at: CGPoint)] = { _ in [] }) async throws -> [ClickAudit.Row] {
    let app = try await AppRig(project: project)
    defer { app.close() }
    let recorder = app.recorder
    app.hostEditor(nav) { v in
        AnyView(v.environment(\.recordDemo, RecordDemo(sources: recorder.sources)).environment(\.voiceDemo, VoiceDemo.model("ready", tier: nil)))
    }
    // The playhead mid-way and the timeline zoomed by hand: the transport and the zoom have somewhere to go.
    if app.store.project != nil {
        app.store.preview.seek(2)
        app.store.pxPerSec = 40
        app.store.autoFit = false
    }
    try await setup(app)
    await app.settle()
    let shared = ["Divisore": "a splitter: a click without a drag moves nothing (its drag is tested in ControlMouseTests)"]
    let rows = await ClickAudit(app: app, screen: screen, skip: skip, noOps: shared.merging(noOps) { $1 }, restore: { restore(app) },
                                skipContaining: skipContaining, area: area, extra: extra(app)).run()
    ClickAudit.check(rows, screen: screen)
    return rows
}

extension MouseSuites {
@Suite(.serialized, .enabled(if: clickAuditEnabled, "skipped in the commit hook, run by the push hook")) @MainActor struct ScreenClickTests {
    /// The whole window on the Pro editor: title row, activity bar, project tab, toolbar, both monitors and their
    /// transports, tool rail, timeline headers and zoom bar, right panel tabs, status bar; the Media panel's tiles.
    @Test func shell() async throws {
        _ = try await audit("shell", Navigation(activity: .media, rightTab: .inspector), noOps: [
            "Divisore": "a splitter: a click without a drag moves nothing (its drag is tested in ControlMouseTests)",
            "Ispettore": alreadyCurrent, "Media": alreadyCurrent, "Pro": alreadyCurrent, "Selezione": alreadyCurrent,
            "Impostazioni": "opens the Settings scene with SwiftUI's openSettings, which a hosted view has no scene for (Settings is clicked through in SettingsClickTests)",
            "Media tile 1": "the take, already the clip shown in the Source monitor",
        ], extra: { app in
            // The Media tiles: a tap gesture, not a button (the tree shows their picture and two lines).
            app.rig.elements().filter { $0.role == "AXImage" && WindowPart.side.contains($0.centre) && $0.frame.minY < 200 }
                .enumerated().map { (name: "Media tile \($0.offset + 1)", at: $0.element.centre) }
        })
    }

    @Test func home() async throws {
        _ = try await audit("home", Navigation(activity: .home, rightTab: .inspector), area: WindowPart.content, noOps: [:])
    }

    @Test func record() async throws {
        _ = try await audit("record", Navigation(activity: .record, rightTab: .inspector), area: WindowPart.content, skip: [
            "Avvia / Ferma registrazione": "the Record button starts a capture of the screen, camera and microphone of the machine running the tests",
        ], noOps: [
            "Solo volto": "the preset already chosen (the recorder's default sources: the camera alone)",
            "Nuovo progetto": "where the take goes, already chosen (the default for a project with an edit, #39)",
        ], restore: { app in app.store.recordingChoice = nil })
    }

    @Test(arguments: Navigation.TextsTab.allCases)
    func texts(_ tab: Navigation.TextsTab) async throws {
        var nav = Navigation(activity: .texts, rightTab: .inspector)
        nav.textsTab = tab
        let names: [Navigation.TextsTab: String] = [.steps: "Passi", .captions: "Sottotitoli", .transcript: "Trascrizione", .takes: "Riprese"]
        _ = try await audit("texts-\(tab.rawValue)", nav, area: WindowPart.side, noOps: [names[tab]!: alreadyCurrent])
    }

    @Test(arguments: Navigation.SoundTab.allCases)
    func audio(_ tab: Navigation.SoundTab) async throws {
        var nav = Navigation(activity: .audio, rightTab: .inspector)
        nav.soundTab = tab
        _ = try await audit("audio-\(tab.rawValue)", nav, area: WindowPart.side, noOps: [
            tab == .mix ? "Mix" : "Effetti sonori": alreadyCurrent, "Whoosh e passaggi": "the sound group already shown",
        ], skipContaining: ["Aggiungi al cursore (pista Effetti)": "a sound row: a click previews the sound on the speakers of the machine running the tests (its + is clicked in audioSoundRowAddsAtThePlayhead)"])
    }

    @Test func voice() async throws {
        // The panel on the sample model (VoiceDemo): it draws the panel and runs nothing (no store, no command, never the
        // owner's voice). What its entries do with the live model is in `voiceEntriesOpenTheVoiceWindow`.
        let sample = "the sample model has no store and runs no command by design (VoiceDemo); the live model is clicked in voiceEntriesOpenTheVoiceWindow"
        _ = try await audit("voice", Navigation(activity: .voice, rightTab: .inspector), area: WindowPart.side, noOps: [
            "Testo": alreadyCurrent, "Français": alreadyCurrent, "Neutro": alreadyCurrent, "Dopo l'ultima voce": alreadyCurrent,
            "Le tue voci": sample, "Clona la tua voce": sample, "Registra un altro tono": sample, "Ascolta la selezione": sample,
            "Ogni paragrafo diventa una clip": sample,
        ])
    }

    /// The Voce panel on the live model: its entries open the "Le tue voci" window (the sheet of the main window).
    @Test func voiceEntriesOpenTheVoiceWindow() async throws {
        let app = try await AppRig()
        defer { app.close() }
        let recorder = app.recorder
        app.hostEditor(Navigation(activity: .voice, rightTab: .inspector)) { AnyView($0.environment(\.recordDemo, RecordDemo(sources: recorder.sources))) }
        await app.settle()
        let entry = try #require(app.rig.elements(containing: "Le tue voci").first { $0.isControl }, "no Le tue voci entry on the live panel")
        app.rig.click(entry.centre)
        await app.settle()
        #expect(app.store.showVoiceSetup, "Le tue voci did not open the voice window")
    }

    @Test(arguments: Navigation.GraphicsSection.allCases)
    func graphics(_ section: Navigation.GraphicsSection) async throws {
        var nav = Navigation(activity: .graphics, rightTab: .inspector)
        nav.showGraphics(section)
        let tips: [Navigation.GraphicsSection: String] = [
            .filters: "Un look di colore", .adjust: "Luce, colore e nitidezza", .effects: "Zoom, movimento, testi",
            .styles: "Tanti passi in un clic", .motion: "Schede animate", .logo: "Il logo della marca"]
        _ = try await audit("graphics-\(section.rawValue)", nav, area: WindowPart.side, noOps: [
            tips[section]!: "the section already shown (the section chips are named by their tooltips, #32)", "Tutto il video": alreadyCurrent,
        ])
    }

    @Test func generate() async throws {
        _ = try await audit("generate", Navigation(activity: .generate, rightTab: .inspector), area: WindowPart.side, skip: [
            "Genera": "starts a generation (the local ComfyUI of the machine running the tests, or a paid estimate)",
            "Approva e spendi": "approves a paid generation",
            "ComfyUI": "the generator already chosen; its row's line follows the format chosen just before, so it is not found again by name on a fresh screen",
        ], noOps: [
            "Immagine": alreadyCurrent, "9:16": "the format already chosen (the project's)",
        ], restore: { app in
            // The Generate panel's form lives in the store (one per tab): back to how the screen started.
            let g = app.store.generation
            g.kind = .still
            g.prompts = [:]
            g.chosen = [:]
            g.formats = [:]
            g.durations = [:]
            g.startAsset = nil
            g.upscaleAsset = nil
            g.problem = nil
        })
    }

    @Test func export() async throws {
        _ = try await audit("export", Navigation(activity: .export, rightTab: .inspector), area: WindowPart.content, noOps: [
            "Reel 9:16": "the export format already chosen (the project's own)",
            "Bit rate": "a slider of the export form's own state, which the audit does not read (its accessibility value reads empty); RSlider's click, drag and single commit are proven in ControlMouseTests",
        ])
    }

    @Test func simple() async throws {
        var nav = Navigation(activity: .media, rightTab: .inspector)
        nav.show(.simple)
        _ = try await audit("simple", nav, area: WindowPart.content, skip: [
            "Semplice": "#34 (open): the level is wider than the main area and this segment lies partly under the side panel's splitter; it is the current level",
        ], noOps: [
            "1, Taglio e riprese": "the step already open", "Medio": alreadyCurrent,
        ])
    }

    @Test(arguments: Navigation.RightTab.allCases)
    func rightPanel(_ tab: Navigation.RightTab) async throws {
        _ = try await audit("right-\(tab.rawValue)", Navigation(activity: .media, rightTab: tab), area: WindowPart.right, skip: [
            "Ascolta e segui": "starts listening to the microphone with speech recognition: a permission prompt on the machine running the tests",
        ], noOps: [
            "Gobbo": alreadyCurrent, "Claude": alreadyCurrent, "Ispettore": alreadyCurrent, "Français": alreadyCurrent,
            "Ricomincia": "scrolls the teleprompter's own window back to the top: that window is hidden here (Mostra il gobbo is clicked on its own)",
        ])
    }
}
}

extension MouseSuites {
@Suite(.serialized, .enabled(if: clickAuditEnabled, "skipped in the commit hook, run by the push hook")) @MainActor struct MoreScreenClickTests {
    /// The side panel answers the mouse on the Semplice level (#33): the level's content, wider than the main area,
    /// overflowed it and took the clicks on the right of the side panel.
    @Test func theSidePanelAnswersOnTheSimpleLevel() async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .media, rightTab: .inspector)
        nav.show(.simple)
        app.hostEditor(nav)
        await app.settle()
        let events = RigGuard.events.count
        #expect(app.rig.click("Importa video, audio o immagini nel progetto (⌘I)"))
        await app.settle()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .panel }, "Importa… in the side panel did not answer on the Semplice level")
        // The media tiles at the right of the panel too: a click on the picture shows it in the Source monitor.
        let tiles = app.rig.elements().filter { $0.role == "AXImage" && WindowPart.side.contains($0.centre) && $0.frame.minY < 200 }
            .sorted { $0.frame.minX < $1.frame.minX }
        let last = try #require(tiles.last)
        app.rig.click(last.centre)
        await app.idle(NSEvent.doubleClickInterval + 0.1)
        await app.settle()
        #expect(app.store.sourceAssetID != "a1", "the media tile at the right of the panel did not answer on the Semplice level")
    }

    /// The Semplice level fits the main area at the default window size (#34): its toolbar starts inside it.
    @Test func theSimpleLevelFitsTheMainArea() async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .media, rightTab: .inspector)
        nav.show(.simple)
        app.hostEditor(nav)
        await app.settle()
        let segment = try #require(app.rig.elements().first { $0.name == "Semplice" && $0.role == "AXButton" })
        withKnownIssue("#34: the Semplice level is wider than the main area at 1440 pt with both panels") {
            #expect(segment.frame.minX >= WindowPart.main.minX, "the toolbar starts at \(segment.frame.minX), left of the main area (\(WindowPart.main.minX))")
        }
    }

    /// A sound row of the Audio panel's browser: its + adds the sound at the playhead (sfx.add).
    @Test func audioSoundRowAddsAtThePlayhead() async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .audio, rightTab: .inspector)
        nav.soundTab = .sfx
        app.hostEditor(nav)
        app.store.preview.seek(2)
        await app.settle()
        await app.idle(0.5)   // the list lays out its rows
        var row = app.rig.elements(containing: "Aggiungi al cursore (pista Effetti)").first { WindowPart.side.contains($0.centre) }
        for _ in 0..<20 where row == nil {
            await app.idle(0.1)
            row = app.rig.elements(containing: "Aggiungi al cursore (pista Effetti)").first { WindowPart.side.contains($0.centre) }
        }
        let r = try #require(row, "no sound row on screen")
        let n = app.store.activity.count
        // The + sits at the row's right end (22 pt, 10 pt in).
        app.rig.click(CGPoint(x: r.frame.maxX - 10 - 11, y: r.centre.y))
        await app.idle(0.3)
        await app.settle()
        #expect(app.commands(since: n).contains("sfx.add"), "the row's + did not add the sound (\(app.commands(since: n)))")
    }

    /// The Ispettore with the take selected: its sections for a clip.
    @Test func inspectorOnAClip() async throws {
        _ = try await audit("right-inspector-clip", Navigation(activity: .media, rightTab: .inspector), area: WindowPart.right,
                            noOps: ["Ispettore": alreadyCurrent], setup: { app in
            app.store.selection = [app.clips.first { $0.assetID == "a1" }?.id ?? ""]
        })
    }

    /// The "Le tue voci" window (the voice sheet) on a language's overview, from the sample model.
    @Test func voiceWindow() async throws {
        let app = try await AppRig()
        defer { app.close() }
        let demo = VoiceDemo.model("overview", tier: nil)
        app.host(VoiceSetupSheet().environment(\.voiceDemo, demo), size: VoiceSetupView.size)
        await app.settle()
        let sample = "the sample model has no store and runs no command by design (VoiceDemo)"
        let setup = demo.setup, language = demo.language, pane = demo.pane
        let rows = await ClickAudit(app: app, screen: "voice-window", noOps: [
            "Français": alreadyCurrent, "Neutro": alreadyCurrent,
            "Registra": sample, "Allena": sample, "Chiudi": sample, "Fatto": sample, "Annulla": sample, "Ascolta": sample, "Prova": sample,
        ], restore: {
            // The sample model is one object for the whole audit: its page back to the start.
            demo.setup = setup
            demo.language = language
            demo.pane = pane
        }).run()
        ClickAudit.check(rows, screen: "voice-window")
    }
}
}
