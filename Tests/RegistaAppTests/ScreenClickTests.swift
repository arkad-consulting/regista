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
// audit the part of the window that is theirs. Every screen is the live one: what a click reaches outside the test is
// the rig's stand-in (#35, RigIsolation.swift), never the capture, the voice, the generators or the files of the person
// running the tests — so nothing is skipped because of where it reaches.

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
private func audit(_ screen: String, _ nav: Navigation, project: String? = "rich", size: CGSize = CGSize(width: 1440, height: 900), area: CGRect? = nil,
                   skip: [String: String] = [:], noOps: [String: String] = [:],
                   skipContaining: [String: String] = [:], restore: @escaping (AppRig) -> Void = { _ in },
                   setup: (AppRig) async throws -> Void = { _ in }, afterReset: @escaping (AppRig) async -> Void = { _ in },
                   extra: (AppRig) -> [(name: String, at: CGPoint)] = { _ in [] }) async throws -> [ClickAudit.Row] {
    let app = try await AppRig(project: project)
    defer { app.close() }
    app.hostEditor(nav, size: size)
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
                                afterReset: { await afterReset(app) }, skipContaining: skipContaining, area: area, extra: extra(app)).run()
    ClickAudit.check(rows, screen: screen)
    return rows
}

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct ScreenClickTests {
    /// The whole window on the Pro editor: title row, activity bar, project tab, toolbar, both monitors and their
    /// transports, tool rail, timeline headers and zoom bar, right panel tabs, status bar; the Media panel's tiles.
    @Test func shell() async throws {
        _ = try await audit("shell", Navigation(activity: .media, rightTab: .inspector), skip: [
            "Media tile dragged to the timeline": "not driven: a drag session would use the session's pasteboard and draw on the screen; the drop is tested at TimelinePanel.drop (TimelineDropTests), which also checks that «Metti in timeline al cursore» gives the same clip",
        ], noOps: [
            "Divisore": "a splitter: a click without a drag moves nothing (its drag is tested in ControlMouseTests)",
            "Ispettore": alreadyCurrent, "Media": alreadyCurrent, "Pro": alreadyCurrent, "Selezione": alreadyCurrent,
            "9:16": "the Inspector's project format, " + alreadyCurrent + " (the fixture project is 9:16; the other formats run project.format)",
            "Impostazioni": "opens the Settings scene with SwiftUI's openSettings, which a hosted view has no scene for (Settings is clicked through in SettingsClickTests)",
            "Media tile 1": "the take, already the clip shown in the Source monitor",
        ], extra: { app in
            // The Media tiles: a tap gesture, not a button (the tree shows their picture and two lines).
            app.rig.elements().filter { $0.role == "AXImage" && WindowPart.side.contains($0.centre) && $0.frame.minY < 200 }
                .enumerated().map { (name: "Media tile \($0.offset + 1)", at: $0.element.centre) }
                + [(name: "Media tile dragged to the timeline", at: .zero)]
        })
    }

    @Test func home() async throws {
        _ = try await audit("home", Navigation(activity: .home, rightTab: .inspector), area: WindowPart.content, noOps: [:])
    }

    @Test func record() async throws {
        // The live screen on the capture stand-in: the Record button starts a take that opens no device and writes nothing.
        _ = try await audit("record", Navigation(activity: .record, rightTab: .inspector), area: WindowPart.content, noOps: [
            "Solo volto": "the preset already chosen (the recorder's default sources: the camera alone)",
            "Questo progetto": "where the take goes, already chosen (the default once the tab has a project, #140)",
            "9:16": "the take's format above the preview, already chosen: the take joins the fixture project, which is 9:16 (#160)",
        ], restore: { app in
            app.store.recordingChoice = nil
            app.store.recordingFormat = nil
        })
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
        // The panel on the live model with the rig's voice services (#36): a scratch profiles folder, the stand-in VoxCPM.
        _ = try await audit("voice", Navigation(activity: .voice, rightTab: .inspector), area: WindowPart.side, noOps: [
            "Testo": alreadyCurrent, "Français": alreadyCurrent, "Neutro": alreadyCurrent, "Dopo l'ultima voce": alreadyCurrent,
        ])
    }

    /// The Voce panel on the live model: its entry opens the "Le tue voci" window (the sheet of the main window); with no
    /// profile yet (the rig's scratch profiles) the entry is «Inizia a clonare la tua voce».
    @Test func voiceEntriesOpenTheVoiceWindow() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .voice, rightTab: .inspector))
        await app.settle()
        let entry = try #require(app.rig.elements(containing: "Inizia a clonare la tua voce").first { $0.isControl }, "no entry to the voice window on the live panel")
        app.rig.click(entry.centre)
        await app.settle()
        #expect(app.store.showVoiceSetup, "the entry did not open the voice window")
    }

    @Test(arguments: Navigation.GraphicsSection.allCases)
    func graphics(_ section: Navigation.GraphicsSection) async throws {
        var nav = Navigation(activity: .graphics, rightTab: .inspector)
        nav.showGraphics(section)
        // The section chips read as their titles; their tooltips are hints (#32).
        _ = try await audit("graphics-\(section.rawValue)", nav, area: WindowPart.side, noOps: [
            GraphicsCatalog.title(section): "the section already shown", "Tutto il video": alreadyCurrent,
        ])
    }

    @Test func generate() async throws {
        // A described image: «Genera» asks the stand-in providers (ComfyUI is not ready in the rig: no runner, no server;
        // the paid stand-in prices it, no CLI, and shows its approval card).
        let prompt = "Una sedia rossa in una stanza bianca"
        _ = try await audit("generate", Navigation(activity: .generate, rightTab: .inspector), area: WindowPart.side, skip: [
            "ComfyUI": "its row's line follows the format chosen just before, so it is not found again by name on a fresh screen",
        ], noOps: [
            "Immagine": alreadyCurrent, "9:16": "the format already chosen (the project's)",
            "Higgsfield": "the generator already chosen (ComfyUI is not ready in the rig: no runner, no server)",
        ], restore: { app in
            // The Generate panel's form lives in the store (one per tab): back to how the screen started.
            let g = app.store.generation
            g.kind = .still
            g.prompts = [.still: prompt]
            g.chosen = [:]
            g.formats = [:]
            g.durations = [:]
            g.startAsset = nil
            g.upscaleAsset = nil
            g.problem = nil
            // A paid estimate «Genera…» asked for stays on its card while the request is the same (#43): declined, so
            // the next screen starts without the card.
            g.decline()
        }, setup: { app in
            app.store.generation.prompts = [.still: prompt]
        })
    }

    /// The approval card of a paid estimate (the stand-in Higgsfield, a fixed price, no CLI): «Approva e spendi» starts
    /// the run as a job, which the stand-in fails before anything is spent outside the scratch budget; «Rifiuta» declines.
    @Test func generateApproval() async throws {
        func form(_ g: GenerateState) {
            g.kind = .still
            g.prompts = [.still: "Una sedia rossa in una stanza bianca"]
            g.chosen = [.still: "higgsfield"]
            g.formats = [:]
            g.durations = [:]
            g.problem = nil
        }
        /// A paid estimate of the stand-in, waiting on its card.
        func price(_ app: AppRig) async {
            let g = app.store.generation
            guard g.pending == nil else { return }
            form(g)
            await app.settle()
            g.generate()
            for _ in 0..<100 where g.pending == nil { await app.idle(0.05) }
            await app.settle()
        }
        // A taller window: the card sits under the form, past the bottom of a 900 pt window.
        _ = try await audit("generate-approval", Navigation(activity: .generate, rightTab: .inspector), size: CGSize(width: 1440, height: 1300),
                            area: CGRect(x: 52, y: 40, width: 296, height: 1236), skip: [
            "ComfyUI": "the free generator: choosing it declines the estimate and rewrites its row's line, so it is not found again by name on a fresh screen",
        ], noOps: [
            "Immagine": alreadyCurrent, "9:16": "the format already chosen (the project's)",
            "Higgsfield": "the generator already chosen: the request is the same, so the waiting estimate stays (#43)",
        ], restore: { app in
            form(app.store.generation)
        }, setup: { app in
            await app.idle(0.5)   // the panel's own first reading
            await price(app)
            #expect(app.store.generation.pending != nil, "no approval card: \(app.store.generation.problem ?? "")")
        }, afterReset: { app in
            // The rebuilt panel reads its providers again; a waiting estimate stays (#43), one declined by a click is
            // asked for again.
            await app.idle(0.5)
            await price(app)
        })
    }

    @Test func export() async throws {
        // The bit rate slider reads its value as an assistive client does (#36): its click shows in the table.
        let bitrate = ExportOptions.shared.bitrate
        defer { ExportOptions.shared.bitrate = bitrate }
        _ = try await audit("export", Navigation(activity: .export, rightTab: .inspector), area: WindowPart.content, noOps: [
            "Reel 9:16": "the export format already chosen (the project's own)",
        ], restore: { _ in ExportOptions.shared.bitrate = bitrate })
    }

    /// Esporta on a reel that breaks the editing rules (#31): the card's «go to» and «fix» links, the kind button, the link
    /// to Settings › Regole, «fix all and export» and «export anyway» (the save panel is answered Cancel by the rig).
    @Test func exportRules() async throws {
        // The link writes the sheet Settings › Regole opens on: put back after each click and at the end.
        let sheet = UserDefaults.standard.object(forKey: SettingsRoute.rulesKey)
        let bitrate = ExportOptions.shared.bitrate
        defer { UserDefaults.standard.set(sheet, forKey: SettingsRoute.rulesKey); ExportOptions.shared.bitrate = bitrate }
        // A taller window: the panel's export buttons sit under the card, past the bottom of a 900 pt window.
        _ = try await audit("export-rules", Navigation(activity: .export, rightTab: .inspector), size: CGSize(width: 1440, height: 1300),
                            area: CGRect(x: 52, y: 40, width: 1068, height: 1236), noOps: [
            "Reel 9:16": "the export format already chosen (the project's own)",
        ], restore: { _ in
            UserDefaults.standard.set(sheet, forKey: SettingsRoute.rulesKey)
            ExportOptions.shared.bitrate = bitrate
        }, setup: { app in
            try await breakTheRules(app)
            await app.idle(0.8)   // the card checks the project
        }, afterReset: { app in
            await app.idle(0.8)   // the rebuilt card checks the project again
        })
    }

    /// The Semplice level at the default size (its rail compact, #34) and at the window's minimum size (the preview under
    /// the step panel): every control of the side panel and the level answers.
    @Test(arguments: [RigWindowSize.standard, .minimum])
    func simple(_ window: RigWindowSize) async throws {
        var nav = Navigation(activity: .media, rightTab: .inspector)
        nav.show(.simple)
        _ = try await audit(window.width == RigWindowSize.standard.width ? "simple" : "simple-\(window.testDescription)", nav, size: window.size,
                            area: RenderParts.content(window.size), noOps: [
            "1, Taglio e riprese": "the step already open", "Taglio e riprese": "the step already open", "Medio": alreadyCurrent,
            "Semplice": alreadyCurrent,
        ])
    }

    /// The right panel's tabs at the default and the minimum window size (#41: the tab scrolls inside the panel there):
    /// the Gobbo from Registra, the only activity that has it (#141), the other two from the editor.
    @Test(arguments: Navigation.RightTab.allCases, [RigWindowSize.standard, .minimum])
    func rightPanel(_ tab: Navigation.RightTab, _ window: RigWindowSize) async throws {
        // "Ascolta e segui" listens through the capture stand-in: no microphone, no speech recognition.
        let name = "right-\(tab.rawValue)" + (window.width == RigWindowSize.standard.width ? "" : "-\(window.testDescription)")
        let nav = Navigation(activity: tab == .prompter ? .record : .media, rightTab: tab)
        _ = try await audit(name, nav, size: window.size, area: RenderParts.right(window.size), noOps: [
            "Gobbo": alreadyCurrent, "Claude": alreadyCurrent, "Ispettore": alreadyCurrent, "Français": alreadyCurrent,
            "9:16": "the Inspector's project format, " + alreadyCurrent + " (the fixture project is 9:16)",
            // The Gobbo's scrolling mode, clicked since the audit finds controls again inside its area (#48): Voce is the
            // teleprompter's default mode.
            "Voce": alreadyCurrent,
            "Ricomincia": "scrolls the teleprompter's own window back to the top: that window is hidden here (Mostra il gobbo is clicked on its own)",
        ], setup: { _ in
            // From the default mode, whatever the test process kept: a run stopped in the middle of this audit left
            // «Velocità» chosen, and its click then changed nothing in every later run.
            TeleprompterController.shared.mode = .voice
            // French, the language the list above names as current (#137): the language is kept there too, and a run that
            // left «Português» chosen made its click change nothing.
            TeleprompterController.shared.language = "fr"
        })
    }
}
}

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct MoreScreenClickTests {
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
        #expect(segment.frame.minX >= WindowPart.main.minX, "the toolbar starts at \(segment.frame.minX), left of the main area (\(WindowPart.main.minX))")
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

    /// The Ispettore with the take selected: its sections for a clip, at the default and the minimum window size (#41).
    @Test(arguments: [RigWindowSize.standard, .minimum])
    func inspectorOnAClip(_ window: RigWindowSize) async throws {
        let name = "right-inspector-clip" + (window.width == RigWindowSize.standard.width ? "" : "-\(window.testDescription)")
        _ = try await audit(name, Navigation(activity: .media, rightTab: .inspector), size: window.size, area: RenderParts.right(window.size),
                            noOps: ["Ispettore": alreadyCurrent], setup: { app in
            app.store.selection = [app.clips.first { $0.assetID == "a1" }?.id ?? ""]
        })
    }

    /// The "Le tue voci" window (the voice sheet) on the live model with the rig's voice services (#36).
    @Test func voiceWindow() async throws {
        let app = try await AppRig()
        defer { app.close() }
        // A profile of the rig's scratch folder: the window shows its languages to record and train.
        try await app.store.perform("profile.create", ["name": "Prova"])
        let model = app.store.voice
        await model.refresh()
        app.host(VoiceSetupSheet(), size: VoiceSetupView.size)
        await app.settle()
        let setup = model.setup, language = model.language, pane = model.pane
        let rows = await ClickAudit(app: app, screen: "voice-window", noOps: [
            "Français": alreadyCurrent, "Neutro": alreadyCurrent,
            "Chiudi": "closes the main window's sheet: the window is hosted on its own here, so there is no sheet to close",
        ], restore: {
            // The model is one object for the whole audit: its page back to the start.
            model.setup = setup
            model.language = language
            model.pane = pane
        }).run()
        ClickAudit.check(rows, screen: "voice-window")
    }
}
}
