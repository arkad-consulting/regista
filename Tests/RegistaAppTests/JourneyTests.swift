import AppKit
import AVFoundation
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// Four whole journeys driven by clicks, from an empty app to an exported file, the way a person does the work: the
// whole window on the rig's services (AppRig), at the default window size, in Italian, with real mouse and keyboard
// events. Every control and every screen is clicked on its own by the click audits; the defects a person keeps meeting
// sit in the passages between screens (a recording that went nowhere visible, a result that is not shown, a default
// that surprises). Each step asserts what a person would see after it, writes a snapshot of the window
// ($REGISTA_UI_SNAPSHOTS/journeys, else a scratch folder) and a line for the report. The capture stand-in hands the
// recorder a synthetic take on Stop (RigCapture.take / .screen); RigGuard answers the open and save panels with the
// paths a test gives (RigGuard.panelAnswer); exports run the real renderer on a few seconds of synthetic media, into
// a scratch folder. The journeys run before a push, with the click audits (they take about a minute each).

/// A step could not be done: the journey stops there (the issue says why).
struct JourneyStop: Error {}

/// One journey: its window, a snapshot after each step, a line per step.
@MainActor
final class Journey {
    private(set) var app: AppRig
    let name: String
    private(set) var lines: [String] = []
    private var count = 0
    private let started = Date()
    /// Scratch folder of the journey (exports, saved projects).
    let scratch = rigTempDir("journey")

    static let folder: URL = {
        let base = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("regista-journeys-\(ProcessInfo.processInfo.processIdentifier)")
        let url = base.appendingPathComponent("journeys", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    init(_ name: String, project: String?) async throws {
        self.name = name
        app = try await AppRig(project: project)
    }

    var rig: MouseRig { app.rig }
    var store: EditorStore { app.store.bench.active }

    /// The app launched again on the same defaults and support folder (AppRig.init(relaunching:)); its window opened on
    /// the navigation the app restores.
    func relaunch() async throws {
        app = try await AppRig(relaunching: app)
        await open(app.store.bench.nav)
    }

    /// The window on `nav` (at the default size, else `size`), the keyboard going to it as in the app.
    func open(_ nav: Navigation, size: CGSize = CGSize(width: 1440, height: 900)) async {
        app.hostEditor(nav, size: size, language: "it")
        app.store.bench.window = rig.window
        KeyMonitor.install(app.store.bench)
        await app.settle()
    }

    func close() {
        // What a journey left open (the teleprompter a take opened, a popover) goes away inside loops of ours: the end of
        // a closing animation stops the running run loop, which must never be the test runner's (#40).
        if TeleprompterController.shared.isVisible { TeleprompterController.shared.hide() }
        for tab in app.store.bench.tabs { tab.showBrandKits = false }
        rig.hold(0.8)
        app.store.bench.window = nil
        app.close()
        rig.hold(0.8)
        FileHandle.standardError.write(Data(("journey \(name): \(String(format: "%.1f", Date().timeIntervalSince(started))) s\n"
            + lines.joined(separator: "\n") + "\n").utf8))
    }

    /// One step done: what the person did and what they see now (the assertions before this call), with the snapshot.
    @discardableResult
    func step(_ did: String, sees: String) -> URL {
        count += 1
        let url = Self.folder.appendingPathComponent(String(format: "%@-%02d.png", name, count))
        try? app.snapshot(to: url)
        lines.append("| \(count) | \(did) | \(sees) | \(url.lastPathComponent) |")
        return url
    }

    // MARK: What a person sees

    /// The visible control named `text`: its label, title or value is `text`, or its label starts with it (a row's
    /// name and detail: "Trascrivi, 10 parole"; a tooltip with its shortcut: "Avvia / Ferma registrazione (⇧⌘R)"), or
    /// one of the parts of its label ("JK, Journey Kit, tuo").
    func control(_ text: String, in r: MouseRig? = nil) -> RigElement? {
        let all = (r ?? rig).elements().filter { $0.isControl && $0.visible }
        return all.first { $0.label == text || $0.title == text || $0.value == text }
            ?? all.first { $0.label.hasPrefix(text + ",") || $0.label.hasPrefix(text + " (") || $0.label.hasPrefix(text + "\n") }
            ?? all.first { $0.label.components(separatedBy: ", ").contains(text) }
    }

    /// Something on screen reads `text`.
    func shows(_ text: String) -> Bool { !rig.elements(containing: text).isEmpty }

    /// What the window shows, for a failure message.
    func screen(_ r: MouseRig? = nil) -> String {
        (r ?? rig).elements().filter { $0.visible && ($0.isControl || $0.role == "AXStaticText") && !$0.name.isEmpty }
            .map { "\($0)\($0.enabled ? "" : " (off)")\($0.selected ? " ✓" : "")" }.joined(separator: "; ")
            .unicodeScalars.filter { $0.isASCII ? $0.value >= 32 : $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// A row of a list whose name is `text` (its label is the name, a comma, the detail): "Sottotitoli, 5 blocchi".
    func row(_ text: String) -> RigElement? {
        rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix(text + ", ") }
    }

    /// Clicks the control named `text` (fails, with what the window shows, when there is none) and waits for its commands.
    func tap(_ text: String, in r: MouseRig? = nil, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let found = control(text, in: r)
        guard let e = found else {
            FileHandle.standardError.write(Data("journey: no «\(text)» on screen: \(screen(r))\n".utf8))
            Issue.record("no «\(text)» on screen: \(screen(r))", sourceLocation: sourceLocation)
            throw JourneyStop()
        }
        #expect(e.enabled, "«\(text)» is disabled", sourceLocation: sourceLocation)
        (r ?? rig).click(e.centre)
        await app.settle()
    }

    /// Scrolls the list under `at` (as the wheel would) until the control named `text` is in view; returns it.
    func reveal(_ text: String, at: CGPoint) async -> RigElement? {
        for _ in 0..<40 {
            if let e = control(text), e.frame.maxY < Double(rig.size.height) - 40 { return e }
            guard rig.scrollContent(at: at, by: 120) else { return control(text) }
            await app.idle(0.05)
        }
        return control(text)
    }

    /// Waits (loops of ours) until `condition` holds, at most `seconds`; returns whether it did.
    func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            await app.idle(0.05)
        }
        return true
    }

    /// The popover the last click opened (the brand picker…), driven like the window.
    func popover() async -> MouseRig? {
        var found: NSWindow?
        _ = await until(3) {
            found = NSApp.windows.first { $0 !== rig.window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            return found != nil
        }
        guard let w = found else { return nil }
        await app.idle(0.3)
        return MouseRig(adopting: w)
    }


    // MARK: The Program picture and the timeline

    /// The Program monitor's picture in the window (top-left origin), from the view that draws it.
    var picture: CGRect? {
        func find(_ v: NSView) -> NSView? {
            if let f = v as? FrameView, f.source === store.preview.program { return f }
            for s in v.subviews { if let hit = find(s) { return hit } }
            return nil
        }
        guard let v = find(rig.host) else { return nil }
        let r = v.convert(v.bounds, to: nil)
        return CGRect(x: r.minX, y: rig.size.height - r.maxY, width: r.width, height: r.height)
    }

    /// A point of the project's frame (pixels) on the Program picture.
    func onPicture(_ x: Double, _ y: Double) -> CGPoint? {
        guard let r = picture, let s = store.project?.settings else { return nil }
        return CGPoint(x: r.minX + x / Double(s.width) * r.width, y: r.minY + y / Double(s.height) * r.height)
    }

    /// What the picture draws at the playhead (captions, titles, pictures, layout boxes) with their frame boxes.
    var drawn: [CanvasElement] {
        guard let p = store.project else { return [] }
        return CanvasLayout.elements(p, at: MediaTime(seconds: store.preview.playhead.time), renderer: nil)
    }

    /// The timeline's lanes: where time `t` is, and the middle of a lane by its header ("V1", "A1", "T1").
    func timelineX(_ t: Double) -> CGFloat? {
        guard let header = rig.elements().first(where: { $0.role == "AXStaticText" && $0.value == "V1" }) else { return nil }
        return header.frame.minX - 14 + TimelinePanel.headerWidth + TimelinePanel.originX + CGFloat(t * store.pxPerSec)
    }
    func laneY(_ label: String) -> CGFloat? {
        rig.elements().first { $0.role == "AXStaticText" && $0.value == label }?.centre.y
    }
    /// The ruler's middle: the line of the timeline's timecode, left of it.
    var rulerY: CGFloat? {
        guard let v1 = laneY("V1") else { return nil }
        return rig.elements().filter { $0.role == "AXStaticText" && $0.value.hasPrefix("00:00:") && $0.centre.y < v1 && $0.frame.minX < (timelineX(0) ?? 0) }
            .map(\.centre.y).max()
    }

    // MARK: Media

    /// A copy of the fixture take (540×960, 6 s, speech) under a new name.
    func take(_ name: String = "take.mov") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: url)
        return url
    }

    /// A user brand kit with a logo, in the test process's kit folder (a person made it in Impostazioni › Brand kit).
    func brandKit(_ name: String) async throws -> String {
        let id = BrandKitStore.slug(name)
        _ = try? await app.store.silent("brandkit.delete", ["kit": .string(id)])
        _ = try await app.store.silent("brandkit.create", ["name": .string(name), "id": .string(id)])
        let logo = try RigProject.media.get().appendingPathComponent("card.png")
        _ = try await app.store.silent("brandkit.setLogo", ["kit": .string(id), "path": .string(logo.path)])
        BrandKitLibrary.shared.reload()
        return id
    }

    /// The exported movie: its picture size and length.
    nonisolated static func probe(_ url: URL) async throws -> (width: Int, height: Int, seconds: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first, "no picture in \(url.lastPathComponent)")
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        return (Int(size.width.rounded()), Int(size.height.rounded()), duration.seconds)
    }
}

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct JourneyTests {
    /// 1. A camera take becomes a reel: an empty app → Registra → Record, Stop → the new project on screen with the take
    /// and the notice → captions from Testi e sottotitoli → an opening title and the closing logo from Grafica (a scratch
    /// brand kit with a logo, picked from Marca) → Esporta: the rules card lists what is wrong → «Sistema tutto ed
    /// esporta» → the file exists, in the project's format and length, and the check passes.
    @Test func aCameraTakeBecomesAReel() async throws {
        let j = try await Journey("1-camera-reel", project: nil)
        let autoEdit = UserDefaults.standard.object(forKey: Prefs.autoEditKey)
        defer {
            UserDefaults.standard.set(autoEdit, forKey: Prefs.autoEditKey)
            j.close()
        }
        let kit = try await j.brandKit("Journey Kit")
        j.app.capture.take = try j.take()
        j.app.followRecorder()
        let bench = j.app.store.bench
        await j.open(Navigation(activity: .home, rightTab: .inspector))
        #expect(j.shows("Cosa vuoi fare?") && j.store.project == nil)
        j.step("Opens the app", sees: "Inizio, an empty tab")

        // Registra: the camera alone, the take becomes a new project in this tab.
        try await j.tap("Registra")
        #expect(j.store.nav.activity == .record, "Registra did not open")
        #expect(await j.until { j.app.recorder.isReady && j.control("Avvia / Ferma registrazione")?.enabled == true },
                "the Record button is not ready: \(j.app.recorder.blockReason ?? "") — \(j.screen())")
        #expect(j.control("Solo volto")?.selected == true, "the camera alone is not the default")
        #expect(j.shows("Diventa un nuovo progetto in questa scheda"), "the line does not say where the take goes")
        j.step("Clicks Registra in the activity bar", sees: "Solo volto chosen, «Diventa un nuovo progetto in questa scheda» over Record")
        if j.control("Montaggio automatico a fine registrazione")?.value == "1" {
            try await j.tap("Montaggio automatico a fine registrazione")
        }
        #expect(j.control("Montaggio automatico a fine registrazione")?.value == "0")

        // Record, then Stop.
        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until { j.app.recorder.isRecording }, "Record did not start: \(j.app.recorder.errorMessage ?? "")")
        // The button's words and the tab's «sta registrando» are drawn, not in the accessibility tree: the status bar's
        // clock and the tab's name are (the snapshot shows the rest).
        #expect(await j.until(2) { j.shows("Registrazione 0:0") }, "the status bar does not show the take's clock: \(j.screen())")
        #expect(j.shows("Nuova registrazione"), "the tab does not show the recording")
        j.step("Clicks Registra (the red button)", sees: "«Ferma · 0:00», the tab «sta registrando»")
        await j.app.idle(1.2)
        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until(20) { bench.notice != nil && j.store.project?.tracks.flatMap(\.clips).count == 2 },
                "the take went nowhere visible: notice \(String(describing: bench.notice)), \(j.screen())")
        await j.app.settle()
        let project = try #require(j.store.project)
        #expect(project.settings.width == 540 && project.settings.height == 960, "format \(project.settings.width)×\(project.settings.height)")
        #expect(j.store.nav.activity == .media && j.store.nav.level == .pro)
        #expect(j.shows("Registrazione salvata in «\(project.name)»"), "no notice: \(j.screen())")
        #expect(j.shows("Formato 9:16 · 540×960"), "the toolbar does not show the take's format")
        #expect(j.store.projectURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "the new project is not saved")
        j.step("Clicks Ferma", sees: "the new project in its tab, the take in Media and on the timeline, «Registrazione salvata in «\(project.name)»»")

        // Captions from Testi e sottotitoli › Passi.
        try await j.tap("Testi e sottotitoli")
        #expect(j.store.nav.activity == .texts)
        j.step("Clicks Testi e sottotitoli", sees: "the steps from the take to captions")
        j.rig.click(try #require(j.row("Sottotitoli"), "no Sottotitoli step: \(j.screen())").centre)
        await j.app.settle()
        // Captions need the words first: the step says so and offers the way there.
        #expect(j.shows("Prima serve la trascrizione."), "the captions step does not say what it needs: \(j.screen())")
        try await j.tap("Vai a «Trascrivi»")
        try await j.tap("Trascrivi")
        #expect(await j.until(20) { j.store.project?.assets.first?.analysis?.transcript != nil }, "the take was not transcribed: \(j.screen())")
        await j.app.settle()
        j.step("Clicks the Sottotitoli step, «Vai a «Trascrivi»», Trascrivi", sees: "«Prima serve la trascrizione.», then the words transcribed")
        if j.control("Genera i sottotitoli") == nil {
            j.rig.click(try #require(j.row("Sottotitoli"), "no Sottotitoli step: \(j.screen())").centre)
            await j.app.settle()
        }
        try await j.tap("Genera i sottotitoli")
        #expect(await j.until(20) { j.store.project?.tracks.contains { $0.kind == .caption && $0.captions != nil } == true },
                "no captions: \(j.screen())")
        await j.app.settle()
        #expect(j.shows("Rigenera i sottotitoli") || j.shows("Sottotitoli, "), "the step does not show the captions done: \(j.screen())")
        j.step("Opens Sottotitoli, clicks Genera i sottotitoli", sees: "a captions track on the timeline, the step done")

        // The brand kit, from Marca.
        try await j.tap("Marca del progetto: il brand kit di sottotitoli, titoli e logo")
        let picker = try #require(await j.popover(), "Marca opened no picker")
        try await j.tap("Journey Kit", in: picker)
        #expect(await j.until { j.store.project?.brand?.id == kit }, "the kit was not applied")
        // The Marca button reads as its tooltip; the Inspector's project card names the kit (the snapshot shows the button).
        #expect(await j.until { j.shows("Journey Kit") }, "the window does not name the kit: \(j.screen())")
        j.step("Clicks Marca, picks «Journey Kit»", sees: "«Marca: Journey Kit» in the toolbar")

        // An opening title from Grafica › Effetti.
        // The Program monitor's (the Source monitor has the same button, left of it).
        j.rig.click(try #require(j.rig.elements().filter { $0.label == "Vai all'inizio" && $0.visible }.max { $0.frame.minX < $1.frame.minX }).centre)
        await j.app.settle()
        #expect(j.store.preview.playhead.time < 0.05, "Vai all'inizio did not bring the playhead to 0")
        try await j.tap("Grafica")
        #expect(j.store.nav.activity == .graphics)
        let titleFound = await j.reveal("Titolo", at: CGPoint(x: 200, y: 600))
        guard let titleRow = titleFound else { Issue.record("no Titolo in Grafica › Effetti: \(j.screen())"); return }
        j.rig.click(titleRow.centre)
        await j.app.settle()
        await j.app.idle(0.4)
        j.step("Grafica › Effetti, scrolls to Titolo, clicks it", sees: "the title form under the row, whole, its words selected")
        // The form opens with its words selected and the cursor in them: typing replaces them.
        #expect(j.rig.isTyping, "the title form does not take the keyboard")
        j.rig.type("REGISTA")
        // The whole form is in view: the panel brought it up (it used to open under the panel's edge, Aggiungi out of sight).
        let add = try #require(j.control("Aggiungi"), "the title form's Aggiungi is out of sight: \(j.screen())")
        #expect(add.frame.maxY < Double(j.rig.size.height) - 24)
        j.rig.click(add.centre)
        await j.app.settle()
        #expect(await j.until { j.store.project?.tracks.flatMap(\.clips).contains { $0.title?.text.contains("REGISTA") == true } == true }, "no title: \(j.screen())")
        let title = try #require(j.store.project?.tracks.flatMap(\.clips).first { $0.title?.text.contains("REGISTA") == true })
        #expect(title.start.seconds < 0.05, "the title is not at the opening (\(title.start.seconds) s)")
        j.step("Grafica › Effetti › Titolo, types REGISTA, Aggiungi", sees: "the title at 0:00 on the timeline and the picture")

        // The closing logo from Grafica › Logo.
        try await j.tap("Logo")   // the section chip, by its title (its tooltip is a hint, #32)
        let stingFound = await j.reveal("Sting finale", at: CGPoint(x: 200, y: 600))
        guard let sting = stingFound else { Issue.record("no Sting finale: \(j.screen())"); return }
        #expect(sting.enabled, "Sting finale is disabled with a kit that has a logo: \(sting.label)")
        j.rig.click(sting.centre)
        await j.app.settle()
        #expect(await j.until { j.store.project?.tracks.contains { $0.role == "logo" && !$0.clips.isEmpty } == true
                    || j.store.project?.tracks.flatMap(\.clips).contains { ($0.effects ?? []).contains { $0.id.hasPrefix("logo-") } } == true },
                "no closing logo: \(j.screen())")
        j.step("Grafica › Logo › Sting finale", sees: "the logo at the end of the reel")

        // Esporta: what breaks the rules, then fix all and export.
        try await j.tap("Esporta")
        #expect(j.store.nav.activity == .export)
        #expect(await j.until(6) { j.shows("da sistemare") }, "the rules card lists nothing to fix: \(j.screen())")
        let failing = try await j.store.silent("rules.check")["violations"]?.arrayValue?.filter { $0["severity"] == "fail" } ?? []
        #expect(failing.contains { $0["check"] == "title-captions" }, "captions over the opening title are not reported: \(failing)")
        let count = j.rig.elements(containing: "da sistemare").first { $0.role == "AXStaticText" }
        #expect((count?.frame.height ?? 99) < 24, "the rules card's count does not fit on its line: \(String(describing: count?.frame))")
        j.step("Clicks Esporta", sees: "the rules card: \(failing.count) da sistemare (\(failing.compactMap { $0["check"]?.stringValue }.joined(separator: ", ")))")
        let out = j.scratch.appendingPathComponent("reel.mp4")
        RigGuard.panelAnswer = [out]
        // The way on is in view at the default window size, right under what fails.
        let fixAll = try #require(j.control("Sistema tutto ed esporta"), "«Sistema tutto ed esporta» is out of sight: \(j.screen())")
        #expect(fixAll.frame.maxY < Double(j.rig.size.height) - 24 && fixAll.enabled)
        j.rig.click(fixAll.centre)
        await j.app.settle()
        #expect(await j.until(60) { FileManager.default.fileExists(atPath: out.path) && j.store.jobs.latest("export")?.isRunning == false },
                "no exported file: \(j.screen())")
        await j.app.settle()
        let p = try #require(j.store.project)
        let movie = try await Journey.probe(out)
        #expect(abs(Double(movie.width) / Double(movie.height) - Double(p.settings.width) / Double(p.settings.height)) < 0.01,
                "exported \(movie.width)×\(movie.height) for a \(p.settings.width)×\(p.settings.height) project")
        #expect(abs(movie.seconds - p.duration.seconds) < 0.1, "exported \(movie.seconds) s of a \(p.duration.seconds) s project")
        #expect(try await j.store.silent("rules.check")["pass"] == true, "the rules still fail after fix all")
        j.step("Clicks Sistema tutto ed esporta, Salva", sees: "the file \(movie.width)×\(movie.height), \(String(format: "%.1f", movie.seconds)) s; the card: controlli rispettati")
    }
    /// 2. A video is imported and edited by hand: an empty app → Nuovo progetto… → Media › Importa… a video (it goes on the
    /// empty timeline) → cut at the playhead twice and delete the piece between → a title → on the Program picture: the
    /// title dragged, the full-frame picture made smaller from a corner → undo twice, redo twice → save → export → the
    /// file exists; the saved project reopens with the same timeline.
    @Test func aVideoIsImportedAndEditedByHand() async throws {
        let j = try await Journey("2-edit-by-hand", project: nil)
        defer { j.close() }
        let video = try j.take("intervista.mov")
        await j.open(Navigation(activity: .home, rightTab: .inspector))
        j.step("Opens the app", sees: "Inizio, an empty tab")

        // Nuovo progetto…: the save panel names it and picks its folder.
        RigGuard.panelAnswer = [j.scratch.appendingPathComponent("Montaggio")]
        try await j.tap("Nuovo progetto…")
        #expect(await j.until { j.store.project?.name == "Montaggio" }, "no new project: \(j.screen())")
        await j.app.settle()
        #expect(j.store.nav.inEditor && j.store.nav.level == .pro, "the new project does not open in the editor")
        #expect(j.shows("Montaggio"), "the tab does not name the project")
        #expect(j.shows("La timeline è vuota"), "the empty timeline does not say what to do")
        j.step("Clicks Nuovo progetto…, names it Montaggio", sees: "the editor on the new project, «La timeline è vuota. Importa un video…»")

        // Media › Importa…: the video joins Media and, the timeline being empty, goes on it.
        try await j.tap("Media")
        RigGuard.panelAnswer = [video]
        try await j.tap("Importa video, audio o immagini nel progetto")
        #expect(await j.until(10) { j.store.project?.tracks.flatMap(\.clips).count == 2 }, "the video is not on the timeline: \(j.screen())")
        await j.app.settle()
        #expect(j.shows("intervista.mov"), "Media does not show the video")
        #expect(j.shows("1 clip"), "the timeline does not count the clip: \(j.screen())")
        j.step("Media › Importa…, picks intervista.mov", sees: "the tile in Media, picture on V1 and sound on A1")

        // Cut at 2 s and 4 s (a click on the ruler, ⌘K), then the piece between selected and deleted.
        guard let ruler = j.rulerY, let at2 = j.timelineX(2), let at4 = j.timelineX(4), let at3 = j.timelineX(3), let v1 = j.laneY("V1") else {
            Issue.record("no timeline on screen: \(j.screen())"); return
        }
        j.rig.click(CGPoint(x: at2, y: ruler))
        await j.app.settle()
        #expect(abs(j.store.preview.playhead.time - 2) < 0.1, "a click on the ruler did not move the playhead to 2 s (\(j.store.preview.playhead.time))")
        j.rig.key("k", keyCode: 40, modifiers: .command)
        await j.app.settle()
        j.rig.click(CGPoint(x: at4, y: ruler))
        await j.app.settle()
        j.rig.key("k", keyCode: 40, modifiers: .command)
        await j.app.settle()
        let pictures = { j.store.project?.tracks.first { $0.kind == .video }?.clips ?? [] }
        #expect(pictures().count == 3, "two cuts did not make three pieces: \(pictures().map { ($0.start.seconds, $0.end.seconds) })")
        j.step("Clicks the ruler at 0:02, ⌘K, at 0:04, ⌘K", sees: "the clip in three pieces")
        j.rig.click(CGPoint(x: at3, y: v1))
        await j.app.settle()
        #expect(j.store.selection.contains { id in pictures().contains { $0.id == id && abs($0.start.seconds - 2) < 0.05 } }, "the middle piece is not selected")
        j.rig.key(.delete)
        await j.app.settle()
        #expect(pictures().count == 2 && !pictures().contains { $0.start.seconds < 3 && $0.end.seconds > 3 },
                "the middle piece is still there: \(pictures().map { ($0.start.seconds, $0.end.seconds) })")
        j.step("Clicks the middle piece, ⌫", sees: "a gap from 0:02 to 0:04")

        // A title at the start, from Grafica.
        // The Program monitor's (the Source monitor has the same button, left of it).
        j.rig.click(try #require(j.rig.elements().filter { $0.label == "Vai all'inizio" && $0.visible }.max { $0.frame.minX < $1.frame.minX }).centre)
        await j.app.settle()
        #expect(j.store.preview.playhead.time < 0.05, "Vai all'inizio did not bring the playhead to 0")
        try await j.tap("Grafica")
        let titleFound = await j.reveal("Titolo", at: CGPoint(x: 200, y: 600))
        guard let titleRow = titleFound else { Issue.record("no Titolo in Grafica: \(j.screen())"); return }
        j.rig.click(titleRow.centre)
        await j.app.settle()
        await j.app.idle(0.4)
        j.step("Grafica › Effetti, scrolls to Titolo, clicks it", sees: "the title form, whole, its words selected")
        j.rig.type("CIAO")
        try await j.tap("Aggiungi")
        let titleClip = { j.store.project?.tracks.flatMap(\.clips).first { $0.title?.text.contains("CIAO") == true } }
        #expect(await j.until { titleClip() != nil }, "no title: \(j.screen())")
        j.step("Grafica › Titolo, types CIAO, Aggiungi", sees: "the title on the timeline and the picture")

        // On the Program picture: the title selected and dragged, the full-frame picture made smaller from a corner.
        let title = try #require(titleClip())
        let footage = try #require(pictures().first)
        j.store.preview.seek(title.start.seconds + 1)
        await j.app.idle(0.3)
        guard let t = j.drawn.first(where: { $0.clipID == title.id }), let from = j.onPicture(t.center[0], t.center[1]), let pic = j.picture else {
            Issue.record("the title (\(title.start.seconds)–\(title.end.seconds) s, track \(String(describing: j.store.project?.locate(clip: title.id)))) is not on the picture at \(j.store.preview.playhead.time): \(j.drawn.map(\.clipID)), picture \(String(describing: j.picture))"); return
        }
        j.rig.click(from)
        await j.app.settle()
        #expect(j.store.canvasSelection == title.id, "a click on the title did not select it")
        j.rig.drag(from: from, by: CGSize(width: 0, height: 40))
        await j.app.settle()
        let moved = titleClip()
        #expect(moved?.placement != title.placement, "the drag did not move the title")
        j.step("On the Program picture: clicks the title, drags it down", sees: "the title selected with its handles, lower on the picture")
        let empty = try #require(j.onPicture(270, 1500), "no picture")
        j.rig.click(empty)
        await j.app.settle()
        #expect(j.store.canvasSelection == footage.id, "a click where only the video is did not select it (\(String(describing: j.store.canvasSelection)))")
        // The bottom-right handle of a full-frame picture sits 7 pt inside the picture's corner.
        j.rig.drag(from: CGPoint(x: pic.maxX - 7, y: pic.maxY - 7), by: CGSize(width: -40, height: -70))
        await j.app.settle()
        let small = pictures().first { $0.id == footage.id }
        let shrunk = j.drawn.first { $0.clipID == footage.id }?.scale ?? 1
        #expect(shrunk < 0.95, "the corner did not make the picture smaller (scale \(shrunk))")
        // The Inspector follows the picture placed by hand (#53: it read Scala 100 % beside a video drawn at 60 %).
        let shownScale = inspectorValue(j, "Scala")
        #expect(inspectorNumber(shownScale).map { abs($0 - shrunk * 100) <= 1 } == true,
                "the Inspector's Scala reads \(shownScale ?? "nothing") for a video drawn at \(Int((shrunk * 100).rounded())) %")
        j.step("Clicks the video on the picture, drags its corner in", sees: "the video smaller, the frame showing around it, the Inspector's Scala \(shownScale ?? "?")")

        // Undo twice, redo twice (the toolbar's arrows).
        try await j.tap("Annulla l'ultima modifica")
        try await j.tap("Annulla l'ultima modifica")
        #expect(pictures().first { $0.id == footage.id } == footage && titleClip()?.placement == title.placement,
                "two undos did not take back the corner and the drag")
        j.step("Clicks Annulla twice", sees: "the video full-frame again, the title where it was")
        try await j.tap("Ripeti l'ultima modifica")
        try await j.tap("Ripeti l'ultima modifica")
        #expect(titleClip()?.placement == moved?.placement && pictures().first { $0.id == footage.id } == small,
                "two redos did not put them back")
        // The picture is drawn small again: just outside its edge the monitor is black.
        if let e = j.drawn.first(where: { $0.clipID == footage.id }), let outside = j.onPicture(e.center[0] + e.size[0] / 2 + 40, e.center[1]) {
            #expect(await j.until(3) { brightness(j, at: outside) < 0.1 }, "the redone size is not drawn (\(brightness(j, at: outside)) beside its edge)")
        }
        j.step("Clicks Ripeti twice", sees: "the title moved and the video smaller again")

        // Save: the tab's menu (a native menu: its item is run as the menu would).
        let timeline = j.store.project?.tracks.map { $0.clips.map { [$0.id, "\($0.start.seconds)", "\($0.end.seconds)"] } }
        let tab = try #require(j.rig.elements().first { $0.role == "AXStaticText" && $0.name == "Montaggio" && $0.frame.minY < 90 }, "no tab: \(j.screen())")
        RigGuard.lastMenu = nil
        j.rig.rightClick(tab.centre)
        let menu = try #require(RigGuard.lastMenu, "the tab has no menu")
        let save = try #require(menu.items.firstIndex { $0.title == "Salva" }, "no Salva in \(menu.items.map(\.title))")
        menu.performActionForItem(at: save)
        #expect(await j.until { j.store.dirty == false }, "the project was not saved")
        #expect(await j.until { j.shows("Salvato") }, "the status bar does not say saved")
        j.step("Right-clicks the tab, Salva", sees: "«Salvato» in the status bar, the tab's dot empty")

        // Export.
        try await j.tap("Esporta")
        let out = j.scratch.appendingPathComponent("montaggio.mp4")
        RigGuard.panelAnswer = [out]
        #expect(await j.until(6) { j.control("Esporta video…") != nil }, "no Esporta video…: \(j.screen())")
        try await j.tap("Esporta video…")
        #expect(await j.until(60) { FileManager.default.fileExists(atPath: out.path) && j.store.jobs.latest("export")?.isRunning == false },
                "no exported file: \(j.screen())")
        let movie = try await Journey.probe(out)
        #expect(abs(movie.seconds - (j.store.project?.duration.seconds ?? 0)) < 0.1)
        j.step("Esporta › Esporta video…, Salva", sees: "the file \(movie.width)×\(movie.height), \(String(format: "%.1f", movie.seconds)) s")

        // Close the tab (its menu's Chiudi, as its ×), then reopen the project from Inizio's recent projects.
        let tab2 = try #require(j.rig.elements().first { $0.role == "AXStaticText" && $0.name == "Montaggio" && $0.frame.minY < 90 }, "no tab: \(j.screen())")
        RigGuard.lastMenu = nil
        j.rig.rightClick(tab2.centre)
        let menu2 = try #require(RigGuard.lastMenu, "the tab has no menu")
        let close = try #require(menu2.items.firstIndex { $0.title == "Chiudi" }, "no Chiudi in \(menu2.items.map(\.title))")
        menu2.performActionForItem(at: close)
        #expect(await j.until { j.store.project == nil }, "the tab did not close: \(j.screen())")
        j.step("Right-clicks the tab, Chiudi", sees: "Inizio, «Montaggio» among the recent projects")
        let recent = try #require(j.control("Montaggio"), "Montaggio is not among the recent projects: \(j.screen())")
        j.rig.click(recent.centre)
        #expect(await j.until(10) { j.store.project?.name == "Montaggio" }, "the project did not reopen")
        await j.app.settle()
        #expect(j.store.project?.tracks.map { $0.clips.map { [$0.id, "\($0.start.seconds)", "\($0.end.seconds)"] } } == timeline,
                "the reopened timeline is not the saved one")
        #expect(j.store.nav.inEditor, "the reopened project is not in the editor")
        j.step("Clicks Montaggio in Recenti", sees: "the project in its tab, the same timeline")
    }

    /// 3. A screen recording with the camera: an empty app → Registra › Schermo + volto → Record, Stop → the session's
    /// project opens (16:9) with its layout → another layout from the Inspector → the camera's box moved on the picture
    /// → export → the file exists in 16:9.
    @Test func aScreenRecordingWithTheCamera() async throws {
        let j = try await Journey("3-screen-recording", project: nil)
        defer { j.close() }
        j.app.capture.take = try j.take()
        j.app.capture.screen = true
        j.app.followRecorder()
        let bench = j.app.store.bench
        await j.open(Navigation(activity: .home, rightTab: .inspector))
        j.step("Opens the app", sees: "Inizio, an empty tab")
        try await j.tap("Registra")
        try await j.tap("Schermo + volto")
        #expect(j.control("Schermo + volto")?.selected == true)
        #expect(await j.until { j.control("Avvia / Ferma registrazione")?.enabled == true && j.app.capture.sessions.last != nil },
                "the Record button is not ready: \(j.app.recorder.blockReason ?? j.app.recorder.errorMessage ?? "") — \(j.screen())")
        #expect(j.shows("VOLTO NEL VIDEO"), "the face layout is not offered: \(j.screen())")
        // Every layout tile is in view at the default window size, without scrolling (#52: they were below the fold).
        for (_, name) in FaceLayoutControls.names {
            let tile = j.control(name)
            #expect(tile.map { $0.clip.contains($0.frame) && $0.frame.maxY < Double(j.rig.size.height) } == true,
                    "the face layout's «\(name)» is not in view: \(String(describing: tile?.frame)) in \(String(describing: tile?.clip))")
        }
        j.step("Registra › Schermo + volto", sees: "screen, camera and microphone on, the face layout, Record ready")

        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until { j.app.recorder.isRecording }, "Record did not start: \(j.app.recorder.errorMessage ?? "")")
        j.step("Clicks Registra (the red button)", sees: "the take running")
        await j.app.idle(1)
        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until(40) { bench.notice != nil && j.store.project?.recordings?.isEmpty == false }, "the session went nowhere visible: \(j.screen())")
        await j.app.settle()
        let p = try #require(j.store.project)
        #expect(p.settings.width == 1920 && p.settings.height == 1080, "format \(p.settings.width)×\(p.settings.height)")
        #expect(j.shows("Formato 16:9"), "the toolbar does not say 16:9: \(j.screen())")
        #expect(j.drawn.contains { $0.kind == .layoutBox } || j.store.project?.tracks.contains { $0.role == "camera" } == true, "no camera on the picture")
        j.step("Clicks Ferma", sees: "the session's project in 16:9, screen and camera with the layout, the notice")

        // Another layout: the screen clip selected, the Inspector's face layout.
        guard let x = j.timelineX(1), let v1 = j.laneY("V1") else { Issue.record("no timeline: \(j.screen())"); return }
        j.rig.click(CGPoint(x: x, y: v1))
        await j.app.settle()
        let current = j.store.project?.recordings?.first?.layouts?.last?.layout.kind
        let other = current == .cutout ? "Bolla" : "Ritaglio"
        try await j.tap(other)
        #expect(await j.until { j.store.project?.recordings?.first?.layouts?.last?.layout.kind != current }, "the layout did not change from \(String(describing: current))")
        j.step("Clicks the screen clip, then «\(other)» in the Inspector", sees: "the camera in the new layout")

        // The camera's box moved on the picture.
        j.store.preview.seek(1)
        await j.app.idle(0.3)
        guard let box = j.drawn.first(where: { $0.kind == .layoutBox }), let from = j.onPicture(box.center[0], box.center[1]) else {
            Issue.record("no camera box on the picture: \(j.drawn.map(\.kind))"); return
        }
        j.rig.click(from)
        await j.app.settle()
        j.rig.drag(from: from, by: CGSize(width: -60, height: -30))
        await j.app.settle()
        let after = j.drawn.first { $0.clipID == box.clipID }
        #expect(after.map { abs($0.center[0] - box.center[0]) > 20 } == true, "the camera box did not move")
        j.step("Drags the camera's box on the picture", sees: "the camera box where it was dropped")

        // Export in 16:9.
        try await j.tap("Esporta")
        // Esporta opens on the project's format (it used to keep Reel 9:16 and export a 16:9 recording as a 1080×1920 reel).
        #expect(await j.until { j.control("Orizzontale")?.selected == true }, "Esporta does not open on the project's 16:9: \(j.screen())")
        // The rules card's line is read whole beside or under the kind (it was broken letter by letter beside «Tutorial
        // dello schermo»).
        #expect(await j.until(6) { j.shows("controlli rispettati") })
        let passed = j.rig.elements(containing: "controlli rispettati").first { $0.role == "AXStaticText" }
        #expect((passed?.frame.height ?? 99) < 24, "«controlli rispettati» does not fit on its line: \(String(describing: passed?.frame))")
        let out = j.scratch.appendingPathComponent("tutorial.mp4")
        RigGuard.panelAnswer = [out]
        #expect(await j.until(6) { j.control("Esporta video…") != nil }, "no Esporta video…: \(j.screen())")
        try await j.tap("Esporta video…")
        #expect(await j.until(90) { FileManager.default.fileExists(atPath: out.path) && j.store.jobs.latest("export")?.isRunning == false },
                "no exported file: \(j.screen())")
        let movie = try await Journey.probe(out)
        let ratio: Double = Double(movie.width) / Double(movie.height)
        #expect(abs(ratio - 16.0 / 9) < 0.01, "exported \(movie.width)×\(movie.height), not 16:9")
        j.step("Esporta › Esporta video…, Salva", sees: "the file \(movie.width)×\(movie.height), \(String(format: "%.1f", movie.seconds)) s")
    }

    /// 4. A camera-only take with pauses, to the exported file — what a person does first: an empty app → Registra ›
    /// «Solo volto» → the teleprompter on, a short script typed in Gobbo, scrolling at its own speed → Record, Pausa,
    /// Riprendi, Pausa, Riprendi, Ferma (the clock stands still while paused) → the take becomes a new project in this tab,
    /// the notice says where it went → the automatic edit runs → Testi e sottotitoli › Trascrizione shows the words →
    /// another caption style → Esporta writes a file as long as the edit.
    @Test func aCameraTakeWithPausesToTheExportedFile() async throws {
        let j = try await Journey("4-camera-pauses", project: nil)
        let prompter = TeleprompterController.shared
        // The teleprompter is the app's one (its text and mode are saved in the test process's defaults): put back after.
        let d = UserDefaults.standard
        let saved = (text: prompter.text, mode: prompter.mode, autoEdit: d.object(forKey: Prefs.autoEditKey),
                     storedText: d.object(forKey: "prompterText"), storedMode: d.object(forKey: "prompterMode"))
        defer {
            prompter.text = saved.text
            prompter.mode = saved.mode
            d.set(saved.storedText, forKey: "prompterText")
            d.set(saved.storedMode, forKey: "prompterMode")
            d.set(saved.autoEdit, forKey: Prefs.autoEditKey)
            j.close()
        }
        UserDefaults.standard.set(true, forKey: Prefs.autoEditKey)
        j.app.capture.take = try j.take()
        j.app.followRecorder()
        let bench = j.app.store.bench
        await j.open(Navigation(activity: .home, rightTab: .inspector))
        #expect(j.shows("Cosa vuoi fare?") && j.store.project == nil)
        j.step("Opens the app", sees: "Inizio, an empty tab")

        // Registra › «Solo volto».
        try await j.tap("Registra")
        #expect(j.store.nav.activity == .record, "Registra did not open")
        try await j.tap("Solo volto")
        #expect(j.control("Solo volto")?.selected == true && !j.app.recorder.sources.screen && j.app.recorder.sources.camera)
        #expect(j.shows("Diventa un nuovo progetto in questa scheda"), "the line does not say where the take goes")
        #expect(j.control("Montaggio automatico a fine registrazione")?.value == "1", "the automatic edit is not on")
        j.step("Registra › Solo volto", sees: "camera and microphone on, «Diventa un nuovo progetto in questa scheda», the automatic edit on")

        // The teleprompter: the script typed in the right panel's Gobbo, its own speed, then its switch on Registra.
        let width = Double(j.rig.size.width)
        let gobboTab = try #require(j.rig.elements().first { $0.isControl && $0.visible && $0.name == "Gobbo" && $0.frame.minX > width - 340 },
                                    "no Gobbo tab in the right panel: \(j.screen())")
        j.rig.click(gobboTab.centre)
        await j.app.settle()
        #expect(j.store.nav.rightTab == .prompter, "the Gobbo tab did not open")
        let editor = try #require(j.rig.elements().first { $0.role == "AXTextArea" && $0.visible && $0.frame.minX > width - 340 },
                                  "no script editor in Gobbo: \(j.screen())")
        j.rig.click(editor.centre)
        await j.app.settle()
        // ⌘A is the Edit menu's Select All, and a hosted window has no menu bar: the action the menu item sends to the
        // window's first responder (the script's text view the click focused).
        let typing = try #require(j.rig.window.firstResponder as? NSTextView, "the click did not put the cursor in the script")
        typing.selectAll(nil)
        let script = "Oggi Regista monta il reel. Le pause spariscono da sole."
        j.rig.type(script)
        await j.app.settle()
        #expect(prompter.text == script, "the script typed in Gobbo is «\(prompter.text)»")
        // One line of ten words, counted in the singular where it is one (#63: it read «1 frasi»), a line being a take
        // (#66: two sentences on one line read «1 frase»).
        #expect(j.shows("1 ripresa · 10 parole"), "Gobbo does not count the script: \(j.screen())")
        try await j.tap("Velocità")
        #expect(prompter.mode == .speed, "Velocità is not the teleprompter's mode")
        let gobboSwitch = { j.rig.elements().first { $0.isControl && $0.visible && $0.label == "Gobbo" && $0.frame.maxX < width - 340 && ["0", "1"].contains($0.value) } }
        let toggle = try #require(gobboSwitch(), "no Gobbo switch on Registra: \(j.screen())")
        if toggle.value == "0" {
            j.rig.click(toggle.centre)
            await j.app.settle()
        }
        #expect(j.app.recorder.sources.prompter && gobboSwitch()?.value == "1", "the teleprompter is not on for the take")
        #expect(await j.until { j.app.recorder.isReady && j.control("Avvia / Ferma registrazione")?.enabled == true },
                "the Record button is not ready: \(j.app.recorder.blockReason ?? "") — \(j.screen())")
        j.step("Gobbo: types the script, Velocità; Registra: the Gobbo switch on", sees: "«1 ripresa · 10 parole · circa 1 min», the Gobbo row on, Record ready")

        // Record.
        /// The status bar's clock: «Registrazione 0:03», or «In pausa · 0:03» while the take is paused (#65).
        func clock() -> String? {
            let bar = Double(j.rig.size.height) - Double(Chrome.statusHeight)
            return j.rig.elements().first { $0.role == "AXStaticText" && $0.visible && $0.frame.minY >= bar - 1
                && ($0.name.hasPrefix("Registrazione 0:") || $0.name.hasPrefix("In pausa · 0:")) }?.name
        }
        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until { j.app.recorder.isRecording }, "Record did not start: \(j.app.recorder.errorMessage ?? "")")
        #expect(await j.until(2) { clock() != nil }, "the status bar does not show the take's clock: \(j.screen())")
        #expect(await j.until(2) { prompter.isVisible && prompter.isPlaying }, "the teleprompter did not open and scroll with the take")
        j.step("Clicks Registra (the red button)", sees: "«Ferma · 0:00», the clock in the status bar, the teleprompter scrolling")

        // Pausa, Riprendi, twice: the clock stands still while paused and the preview says so.
        for k in 1...2 {
            await j.app.idle(1.1)
            try await j.tap("Pausa / Riprendi")
            #expect(await j.until { j.app.recorder.isPaused }, "pause \(k) did not pause")
            #expect(await j.until(2) { j.shows("In pausa") }, "pause \(k): the window does not say the take is paused: \(j.screen())")
            #expect(!prompter.isPlaying, "the teleprompter scrolls during pause \(k)")
            // The tab says so too (#62: it read «sta registrando» beside a paused take).
            let tabLine = { j.rig.elements().first { $0.role == "AXStaticText" && $0.frame.minY < 90 && ($0.name.hasPrefix("in pausa") || $0.name.hasPrefix("sta registrando")) }?.name ?? "" }
            #expect(await j.until(2) { tabLine().hasPrefix("in pausa") }, "pause \(k): the tab reads «\(tabLine())»")
            // The status bar's item says the take is paused too (#65: it kept «● Registrazione 0:04»).
            #expect(await j.until(2) { clock()?.hasPrefix("In pausa · 0:") == true }, "pause \(k): the status bar reads «\(clock() ?? "nothing")»")
            let still = clock()
            await j.app.idle(1.2)
            #expect(clock() == still && still != nil, "pause \(k): the clock moved while paused (\(still ?? "none") → \(clock() ?? "none"))")
            j.step("Clicks Pausa (\(k))", sees: "«Riprendi», «In pausa · …», the tab «in pausa», the clock standing at \(still ?? "?")")
            try await j.tap("Pausa / Riprendi")
            #expect(await j.until { !j.app.recorder.isPaused }, "resume \(k) did not resume")
            // «Registrazione» again, and its time moves on from the one that stood still.
            let time = { (s: String?) in s?.components(separatedBy: " ").last }
            #expect(await j.until(2) { clock()?.hasPrefix("Registrazione 0:") == true && time(clock()) != time(still) },
                    "resume \(k): the clock does not run again (\(still ?? "none") → \(clock() ?? "none"))")
            #expect(prompter.isPlaying, "the teleprompter did not go on after pause \(k)")
            #expect(await j.until(2) { tabLine().hasPrefix("sta registrando") }, "resume \(k): the tab reads «\(tabLine())»")
            j.step("Clicks Riprendi (\(k))", sees: "«Pausa» again, the clock running from \(still ?? "?")")
        }
        await j.app.idle(1.1)

        // Ferma: the take becomes a new project in this tab, saved in the projects folder, the notice says where.
        let tabID = j.store.tabID
        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until(20) { bench.notice != nil && j.store.project?.tracks.flatMap(\.clips).count == 2 },
                "the take went nowhere visible: notice \(String(describing: bench.notice)), \(j.screen())")
        await j.app.settle()
        #expect(!j.app.recorder.isRecording && j.app.capture.log.filter { $0 == "pauseMovie" }.count == 2, "\(j.app.capture.log)")
        let project = try #require(j.store.project)
        #expect(bench.active.tabID == tabID && bench.tabs.count == 1, "the take did not land in this tab")
        #expect(j.rig.elements().contains { $0.role == "AXStaticText" && $0.name == project.name && $0.frame.minY < 90 },
                "the tab is not named after the take's project «\(project.name)»: \(j.screen())")
        #expect(j.shows("Registrazione salvata in «\(project.name)»"), "the notice does not say where the take went: \(j.screen())")
        let take = try #require(project.assets.first?.path, "no take in Media")
        #expect(take.hasPrefix(rigFolder.path) && FileManager.default.fileExists(atPath: take), "the take is not in the scratch recordings folder: \(take)")
        #expect(j.store.projectURL.map { $0.path.hasPrefix(EditorStore.projectsFolder.path) && FileManager.default.fileExists(atPath: $0.path) } == true,
                "the new project is not saved in the projects folder")
        j.step("Clicks Ferma", sees: "the new project «\(project.name)» in this tab, the take on V1/A1, «Registrazione salvata in «\(project.name)»»")

        // The automatic edit runs on its own (Fai tutto: transcript, script, takes, cut, voice, captions).
        #expect(await j.until(5) { j.store.jobs.latest(TextStep.allJobKind) != nil }, "the automatic edit did not start: \(j.screen())")
        #expect(await j.until(90) { j.store.jobs.latest(TextStep.allJobKind)?.isRunning == false }, "the automatic edit did not finish: \(j.screen())")
        await j.app.settle()
        let job = try #require(j.store.jobs.latest(TextStep.allJobKind))
        #expect(job.state == .done, "the automatic edit ended \(job.state): \(job.detail)")
        let edited = try #require(j.store.project)
        #expect(edited.tracks.contains { $0.kind == .caption && $0.captions != nil }, "the automatic edit made no captions")
        #expect(edited.script != nil, "the teleprompter's script did not become the project's script")
        #expect(edited.tracks.first { $0.kind == .video }?.clips.isEmpty == false, "no clip on the timeline after the edit")
        j.step("Waits for the automatic edit", sees: "the job done, the edit on the timeline with its captions (\(String(format: "%.1f", edited.duration.seconds)) s)")

        // Testi e sottotitoli › Trascrizione: the words.
        try await j.tap("Testi e sottotitoli")
        #expect(j.store.nav.activity == .texts)
        try await j.tap("Trascrizione")
        #expect(j.store.nav.textsTab == .transcript)
        #expect(await j.until { j.shows("Regista") && j.shows("pause") }, "the transcript panel shows no words: \(j.screen())")
        j.step("Testi e sottotitoli › Trascrizione", sees: "the take's words, paragraph by paragraph")

        // Another caption style (Testi e sottotitoli › Sottotitoli).
        try await j.tap("Sottotitoli")
        let before = try #require(edited.tracks.first { $0.captions != nil }?.captions?.style.id)
        let other = try #require(CaptionStyle.all.first { !(before == $0.id || before.hasPrefix($0.id + "+")) })
        let name = captionStyleName(other.id)
        try await j.tap(name)
        #expect(await j.until { j.store.project?.tracks.first { $0.captions != nil }?.captions?.style.id.hasPrefix(other.id) == true },
                "the captions are not in «\(name)»: \(String(describing: j.store.project?.tracks.first { $0.captions != nil }?.captions?.style.id))")
        #expect(j.control(name)?.selected == true, "«\(name)» is not shown as chosen")
        j.step("Testi e sottotitoli › Sottotitoli, clicks «\(name)»", sees: "the captions in «\(name)» on the picture, the chip chosen")

        // Esporta: the file, as long as the edit.
        try await j.tap("Esporta")
        #expect(j.store.nav.activity == .export)
        let out = j.scratch.appendingPathComponent("prima-ripresa.mp4")
        RigGuard.panelAnswer = [out]
        #expect(await j.until(6) { j.control("Esporta video…") != nil }, "no Esporta video…: \(j.screen())")
        j.step("Clicks Esporta", sees: "the export screen, the rules card")
        try await j.tap("Esporta video…")
        #expect(await j.until(90) { FileManager.default.fileExists(atPath: out.path) && j.store.jobs.latest("export")?.isRunning == false },
                "no exported file: \(j.screen())")
        await j.app.settle()
        let p = try #require(j.store.project)
        let movie = try await Journey.probe(out)
        #expect(abs(movie.seconds - p.duration.seconds) < 0.1, "exported \(movie.seconds) s of a \(p.duration.seconds) s edit")
        #expect(out.path.hasPrefix(j.scratch.path))
        j.step("Esporta › Esporta video…, Salva", sees: "the file \(movie.width)×\(movie.height), \(String(format: "%.1f", movie.seconds)) s, in the scratch folder")
    }

    /// 5. Monta › Semplice, the guided steps: an empty app → Nuovo progetto… → Media › Importa… a take with speech →
    /// «Semplice» in the editor's toolbar → each step by its own button, in its order: Taglio e riprese («Taglia il
    /// video»), Sottotitoli (the switch), Aspetto (the light and a colour), Musica e suoni (a music, the whoosh on the
    /// cuts), Voce («Pulisci la voce»), Grafica (a title) → a step back and forward again, Pro and back: nothing lost →
    /// «Esporta il reel» → the file. After each step: which step is open, what its button did (the timeline, the
    /// transcript, the captions on the picture), that the next step is offered only when it can run, and that the step's
    /// main control is in view or its column says it continues.
    @Test func theGuidedStepsOfSemplice() async throws {
        let j = try await Journey("5-semplice", project: nil)
        defer { j.close() }
        try await j.semplice(size: CGSize(width: 1440, height: 900), export: true)
    }

    /// 5b. Journey 5 at the window's minimum size (1024×640, the steps' rail compact): every step's main control is in
    /// view, or its column says it continues; the steps act as at the default size.
    @Test func theGuidedStepsOfSempliceAtTheMinimumWindow() async throws {
        let j = try await Journey("5-semplice-min", project: nil)
        defer { j.close() }
        try await j.semplice(size: RigWindowSize.minimum.size, export: false)
    }

    /// 6. A reel finished by hand, from a cut take (the first journey's start and the automatic edit, not proven again):
    /// Marca › a neutral built-in kit → a title at the opening → a call to action at the end → the logo → Audio › a music
    /// with ducking under the voice → a sound effect on a cut → a look → Esporta: the rules card says what passes and
    /// what fails, a failing rule fixed with its own «Sistema», the file written. After each step: the element on the
    /// timeline and on the Program picture, the Inspector's values; each element on the picture is clicked and changed in
    /// the Inspector.
    @Test func aReelIsFinishedByHand() async throws {
        let j = try await Journey("6-finish-reel", project: nil)
        let autoEdit = UserDefaults.standard.object(forKey: Prefs.autoEditKey)
        defer {
            UserDefaults.standard.set(autoEdit, forKey: Prefs.autoEditKey)
            j.close()
        }
        let cuts = try await j.recordAndCut()
        try await j.finishByHand(cuts: cuts)
    }

    /// 7. A project saved, closed and found again: journey 6's finished reel (its steps reused, not proven again) → the
    /// tab says it has unsaved changes → saved with the menu's Salva (the command table) and with ⌘S (a key event) →
    /// a change, the tab's ×: Annulla keeps the tab, Non salvare drops the change, Salva writes it → Inizio lists the
    /// project with its name and length, a click reopens it: everything as it was → the history, undo and redo → undo
    /// right after reopening → export again: the same length, the same picture → the app launched again.
    @Test func aProjectIsSavedClosedAndFoundAgain() async throws {
        let j = try await Journey("7-found-again", project: nil)
        let autoEdit = UserDefaults.standard.object(forKey: Prefs.autoEditKey)
        defer {
            UserDefaults.standard.set(autoEdit, forKey: Prefs.autoEditKey)
            j.close()
        }
        try await j.foundAgain()
    }
}
}

// MARK: - Journey 6's start: a take recorded and cut

extension Journey {
    /// The start of the first journey: a camera take recorded, cut by the automatic edit. Returns where the pieces of V1
    /// join.
    func recordAndCut() async throws -> [Double] {
        let j = self
        UserDefaults.standard.set(true, forKey: Prefs.autoEditKey)
        j.app.capture.take = try j.take()
        j.app.followRecorder()
        await j.open(Navigation(activity: .home, rightTab: .inspector))
        try await j.tap("Registra")
        #expect(await j.until { j.app.recorder.isReady && j.control("Avvia / Ferma registrazione")?.enabled == true }, "Record is not ready: \(j.screen())")
        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until { j.app.recorder.isRecording })
        await j.app.idle(1.2)
        try await j.tap("Avvia / Ferma registrazione")
        #expect(await j.until(20) { j.store.project != nil && j.store.jobs.latest(TextStep.allJobKind) != nil }, "the take went nowhere: \(j.screen())")
        #expect(await j.until(90) { j.store.jobs.latest(TextStep.allJobKind)?.isRunning == false }, "the automatic edit did not finish")
        await j.app.settle()
        let cut = try #require(j.store.project)
        // A take recorded without the teleprompter is cut from its own words: both sentences stay (#71: it was cut
        // against the teleprompter's sample text and lost the second).
        #expect(cut.script?.lines.contains { $0.contains("Incolla qui il tuo testo") } != true, "the teleprompter's sample became the take's script: \(String(describing: cut.script?.lines))")
        let said = cut.tracks.first { $0.captions != nil }?.captions?.chunks.flatMap(\.words).map(\.text).joined(separator: " ").lowercased() ?? ""
        #expect(said.contains("regista") && said.contains("spariscono"), "the edit lost words of the take: captions «\(said)»")
        let cuts = (cut.tracks.first { $0.kind == .video }?.clips ?? []).dropFirst().map(\.start.seconds)
        j.step("Records a take, the automatic edit cuts it", sees: "the cut take (\(String(format: "%.1f", cut.duration.seconds)) s, \(cuts.count + 1) pieces) with its captions")
        return Array(cuts)
    }
}

// MARK: - Journey 5: Monta › Semplice

extension Journey {
    /// The rail's row of `step` (its title, then its state in words).
    func stepRow(_ step: SimpleStep) -> RigElement? {
        // In the rail's column, under «Fai tutto» (the activity bar has a «Voce» too, the step panel's footer names the
        // next step).
        let title = step.title()
        let all = rig.elements()
        guard let doAll = all.first(where: { $0.isControl && $0.label.hasPrefix("Taglia, sceglie le riprese") }) else { return nil }
        return all.first { $0.role == "AXButton" && $0.frame.minX >= doAll.frame.minX - 4 && $0.frame.maxX <= doAll.frame.maxX + 4
            && ($0.label == title || $0.label.components(separatedBy: ", ").contains(title)) }
    }

    /// Clicks the rail's row of `step`, scrolling the rail (as the wheel would) when it is below the fold.
    func openRow(_ step: SimpleStep, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        var row = try #require(stepRow(step), "no «\(step.title())» on the rail: \(screen())", sourceLocation: sourceLocation)
        for _ in 0..<10 where !(row.visible && row.clip.insetBy(dx: -1, dy: -1).contains(row.frame)) {
            guard rig.scrollContent(at: CGPoint(x: row.centre.x, y: min(row.centre.y, row.clip.maxY - 30)), by: 80) else { break }
            await app.idle(0.05)
            row = try #require(stepRow(step), sourceLocation: sourceLocation)
        }
        rig.click(row.centre)
        await app.settle()
        #expect(openStep == step, "a click on «\(step.title())» opened \(String(describing: openStep))", sourceLocation: sourceLocation)
        // The step opens at its top, its name in view, whatever the step before was scrolled to.
        #expect(headerInView(step), "«\(step.title())» opened without its name in view: \(screen())", sourceLocation: sourceLocation)
    }

    /// The step open: its row on the rail is the chosen one.
    var openStep: SimpleStep? { SimpleStep.allCases.first { stepRow($0)?.selected == true } }

    /// The step panel's header names `step`, in view (right of the rail).
    func headerInView(_ step: SimpleStep) -> Bool {
        let rail = stepRow(.cut)?.frame.maxX ?? 0
        return rig.elements().contains { $0.role == "AXStaticText" && $0.visible && $0.value == step.title() && $0.frame.minX > rail
            && $0.clip.insetBy(dx: -1, dy: -1).contains($0.frame) }
    }

    /// Clicks the step panel's «Prossimo passo» button: it opens `next` at its top.
    func goNext(_ next: SimpleStep, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let b = try #require(nextButton, "no «Prossimo passo»: \(screen())", sourceLocation: sourceLocation)
        #expect(b.label == next.title(), "«Prossimo passo» offers \(b.label), not \(next.title())", sourceLocation: sourceLocation)
        rig.click(b.centre)
        await app.settle()
        #expect(openStep == next, "«Prossimo passo: \(b.label)» opened \(String(describing: openStep)): rail \(SimpleStep.allCases.map { "\($0.rawValue)=\(stepRow($0).map { "\($0) \($0.selected)" } ?? "-")" })", sourceLocation: sourceLocation)
        #expect(headerInView(next), "«\(next.title())» opened without its name in view: \(screen())", sourceLocation: sourceLocation)
    }

    /// The step panel's footer button that opens the next step to do (named by its title), nil when none is offered.
    var nextButton: RigElement? {
        let rail = stepRow(.cut)?.frame.maxX ?? 0
        return rig.elements().first { e in e.role == "AXButton" && e.visible && e.frame.minX > rail && SimpleStep.allCases.contains { $0.title() == e.label } }
    }

    /// `e` is whole in view, above the status bar, or the scrolling column it lies in says it continues («Altro sotto»).
    func inViewOrCued(_ e: RigElement?) -> Bool {
        guard let e else { return false }
        if e.visible && e.clip.insetBy(dx: -1, dy: -1).contains(e.frame) && e.frame.maxY <= Double(rig.size.height) - Double(Chrome.statusHeight) { return true }
        return rig.elements().contains { $0.name == "Altro sotto" && $0.frame.minX <= e.centre.x && $0.frame.maxX >= e.centre.x }
    }

    /// A step's main control (named `name`, in view or not) is in view, or its column says it continues; then it is
    /// scrolled into view as a person would, under the cue. Returns the line for the audit table.
    @discardableResult
    func mainControl(_ name: String, sourceLocation: SourceLocation = #_sourceLocation) async -> String {
        let find = { self.rig.elements().first { $0.isControl && ($0.label == name || $0.title == name || $0.label.hasPrefix(name + ",")) } }
        var e = find()
        // Far below the fold a control is not in the accessibility tree at all: what a person does is scroll the
        // column that says it continues, the step panel (right of the rail) first.
        var cueSeen = false
        if e == nil {
            let rail = stepRow(.cut)?.frame.maxX ?? 0
            let cues = rig.elements().filter { $0.name == "Altro sotto" }.sorted { ($0.frame.minX > rail ? 0 : 1) < ($1.frame.minX > rail ? 0 : 1) }
            cueSeen = !cues.isEmpty
            for cue in cues where e == nil {
                for _ in 0..<12 where e == nil {
                    guard rig.scrollContent(at: CGPoint(x: cue.centre.x, y: cue.frame.minY - 40), by: 80) else { break }
                    await app.idle(0.05)
                    e = find()
                }
            }
        }
        #expect(e != nil, "no «\(name)» in the step: \(screen())", sourceLocation: sourceLocation)
        #expect(cueSeen || inViewOrCued(e), "«\(name)» is below the fold at \(Int(rig.size.width))×\(Int(rig.size.height)) and nothing says the column continues: \(String(describing: e?.frame)) in \(String(describing: e?.clip)); cues \(rig.elements().filter { $0.name.contains("Altro") }.map { "\($0) \($0.frame)" })",
                sourceLocation: sourceLocation)
        guard var shown = e else { return "«\(name)» missing" }
        let line = !cueSeen && shown.clip.insetBy(dx: -1, dy: -1).contains(shown.frame) ? "«\(name)» in view" : "«\(name)» below the fold under «Altro sotto»"
        for _ in 0..<10 where !(shown.visible && shown.clip.insetBy(dx: -1, dy: -1).contains(shown.frame)) {
            guard rig.scrollContent(at: CGPoint(x: shown.centre.x, y: shown.clip.midY), by: 80), let again = find() else { break }
            await app.idle(0.05)
            shown = again
        }
        #expect(shown.visible && shown.clip.insetBy(dx: -1, dy: -1).contains(shown.frame), "«\(name)» could not be scrolled into view", sourceLocation: sourceLocation)
        return line
    }

    /// The project as a person would notice a loss: every clip's place, the captions, the look, the music's ducking.
    var simpleSignature: String {
        guard let p = store.project else { return "" }
        let clips = p.tracks.map { t in "\(t.kind.rawValue)/\(t.role ?? "")[\(t.clips.map { "\($0.id)@\($0.start.seconds)-\($0.end.seconds)" }.joined(separator: ","))]\(t.ducking.map { "d\($0.depth)" } ?? "")" }
        return clips.joined(separator: " ") + " look:\(p.grade?.look ?? "-") captions:\(p.tracks.first { $0.captions != nil }?.captions?.style.id ?? "-")"
    }

    /// A music file of `seconds` (two soft tones, gently pulsing), as a person would pick from their folder.
    func music(_ name: String = "musica.wav", seconds: Double = 12) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for c in 0..<2 {
            let samples = try #require(buffer.floatChannelData?[c])
            for i in 0..<Int(frames) {
                let t = Double(i) / rate
                samples[i] = Float(0.12 * (sin(2 * .pi * 220 * t) + 0.6 * sin(2 * .pi * 277.18 * t)) * (0.7 + 0.3 * sin(2 * .pi * 2 * t)))
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }

    /// Journey 5 (JourneyTests.theGuidedStepsOfSemplice) in a window of `size`; `export`: then «Esporta il reel» to the file.
    func semplice(size: CGSize, export: Bool) async throws {
        let at = "\(Int(size.width))×\(Int(size.height))"
        let video = try take("parlato.mov")
        await open(Navigation(activity: .home, rightTab: .inspector), size: size)
        step("Opens the app at \(at)", sees: "Inizio, an empty tab")

        // Nuovo progetto…, Media › Importa… the take: it goes on the empty timeline.
        RigGuard.panelAnswer = [scratch.appendingPathComponent("Semplice")]
        try await tap("Nuovo progetto…")
        #expect(await until { store.project?.name == "Semplice" }, "no new project: \(screen())")
        await app.settle()
        try await tap("Media")
        RigGuard.panelAnswer = [video]
        try await tap("Importa video, audio o immagini nel progetto")
        #expect(await until(10) { store.project?.tracks.flatMap(\.clips).count == 2 }, "the take is not on the timeline: \(screen())")
        await app.settle()
        step("Nuovo progetto… «Semplice», Media › Importa… parlato.mov", sees: "the take on V1 and A1, the Pro level")

        // Monta › Semplice: the six steps, Taglio e riprese open and next.
        try await tap("Semplice")
        #expect(await until { store.nav.level == .simple && stepRow(.cut) != nil }, "«Semplice» did not show the steps (level \(store.nav.level)): \(screen())")
        await app.settle()
        // Every step is on the rail, in view or below a column that says it continues.
        for s in SimpleStep.allCases { #expect(inViewOrCued(stepRow(s)), "the step «\(s.title())» is not on the rail, or below the fold with no cue: \(String(describing: stepRow(s)?.frame))") }
        #expect(openStep == .cut, "the open step is \(String(describing: openStep)), not Taglio e riprese")
        #expect(nextButton == nil, "a next step is offered before the first one is done: \(String(describing: nextButton))")
        let cutButton = await mainControl("Taglia il video")
        step("Clicks «Semplice» in the editor's toolbar", sees: "the six steps, Taglio e riprese open and «Prossimo», \(cutButton)")

        // Another step opened from the rail before the cut: the take is already on the timeline, so its controls act;
        // the footer offers the step still to do first, which can run.
        try await openRow(.look)
        #expect(openStep == .look, "a click on Aspetto opened \(String(describing: openStep))")
        let lookChip = SimpleLooks.title("film")
        await mainControl(lookChip)
        #expect(control(lookChip)?.enabled == true, "Aspetto's colours are off with the take on the timeline")
        #expect(nextButton?.label == SimpleStep.cut.title() && store.simpleSnapshot[.cut].canAct,
                "the step offered next is \(nextButton?.label ?? "none") (the cut can act: \(store.simpleSnapshot[.cut].canAct))")
        step("Clicks Aspetto on the rail before the cut", sees: "Aspetto's light and colours, «Prossimo passo: Taglio e riprese»")
        try await goNext(.cut)

        // 1. Taglio e riprese: «Taglia il video» transcribes, finds the takes, cuts the pauses.
        await mainControl("Taglia il video")
        try await tap("Taglia il video")
        #expect(await until(60) { store.simpleSnapshot[.cut].status == .done && store.simpleSnapshot.busy == nil }, "the cut did not finish: \(screen())")
        await app.settle()
        let cut = try #require(store.project)
        #expect(cut.assets.first?.analysis?.transcript != nil, "the take was not transcribed")
        #expect(cut.takes != nil, "no takes were found")
        #expect(cut.duration.seconds < 5.9, "the pauses are still there: \(cut.duration.seconds) s of a 6 s take")
        #expect(openStep == .cut && rig.elements().contains { $0.value == "RIPRESE" }, "the cut's panel does not show the takes: \(screen())")
        #expect(nextButton?.label == SimpleStep.captions.title(), "after the cut the next step offered is \(nextButton?.label ?? "none")")
        step("Taglio e riprese › Taglia il video", sees: "the edit \(String(format: "%.1f", cut.duration.seconds)) s on the timeline, «RIPRESE», «Prossimo passo: Sottotitoli»")

        // 2. Sottotitoli: the switch makes them from the words; they are on the picture.
        try await goNext(.captions)
        let captionsSwitch = await mainControl("Sottotitoli nel video")
        try await tap("Sottotitoli nel video")
        #expect(await until(30) { store.simpleSnapshot.captionsTrack != nil && store.simpleSnapshot.busy == nil }, "no captions: \(screen())")
        await app.settle()
        store.preview.seek(0.6)
        await app.idle(0.3)
        #expect(drawn.contains { $0.kind == .caption }, "no caption on the picture at 0.6 s: \(drawn.map(\.kind))")
        #expect(control("Sottotitoli nel video")?.value == "1", "the switch does not read on")
        #expect(nextButton?.label == SimpleStep.look.title(), "after the captions the next step offered is \(nextButton?.label ?? "none")")
        step("Prossimo passo › Sottotitoli, the switch on (\(captionsSwitch))", sees: "the captions on the picture, the step done, «Prossimo passo: Aspetto»")

        // 3. Aspetto: the light and a colour.
        try await goNext(.look)
        let light = await mainControl("Luce leggera")
        try await tap("Luce leggera")
        #expect(await until { store.simpleSnapshot.light }, "the light grade is not on")
        await mainControl(lookChip)
        try await tap(lookChip)
        #expect(await until { store.project?.grade?.look == "film" }, "the colour is not on: \(String(describing: store.project?.grade))")
        #expect(control(lookChip)?.selected == true, "«\(lookChip)» is not shown as chosen")
        #expect(store.simpleSnapshot[.look].status == .done)
        step("Prossimo passo › Aspetto, Luce leggera, «\(lookChip)» (\(light))", sees: "the picture warmer and lighter, the step done")

        // 4. Musica e suoni: optional, so it is opened from the rail; a music, then the whoosh on the cuts.
        let offered = nextButton?.label
        #expect(offered != SimpleStep.sound.title(), "the optional step is offered as the next one to do")
        try await openRow(.sound)
        #expect(openStep == .sound)
        let pick = await mainControl("Scegli una musica…")
        RigGuard.panelAnswer = [try music()]
        try await tap("Scegli una musica…")
        #expect(await until(30) { store.simpleSnapshot.music != nil && store.jobs.latest(AudioCalls.musicJob)?.isRunning == false }, "no music: \(screen())")
        await app.settle()
        #expect(store.simpleSnapshot.music?.ducking == true, "the music does not go down under the voice")
        await mainControl("Si abbassa quando parli")
        #expect(shows("musica.wav") && control("Si abbassa quando parli")?.value == "1", "the step does not show the music and its ducking: \(screen())")
        await mainControl("Un whoosh sui tagli")
        let whoosh = control("Un whoosh sui tagli")
        if whoosh?.enabled == true {
            try await tap("Un whoosh sui tagli")
            #expect(await until { store.simpleSnapshot.effects > 0 }, "no sound on the cuts")
        } else {
            Issue.record("«Un whoosh sui tagli» is off after the cut (\(store.project.flatMap(SimpleSnapshot.mainVideo)?.clips.count ?? 0) clips): \(screen())")
        }
        step("Musica e suoni (from the rail), Scegli una musica… musica.wav, Un whoosh sui tagli (\(pick))",
             sees: "the music under the voice with its ducking, \(store.simpleSnapshot.effects) sounds on the cuts")

        // 5. Voce: the cleaning, when this Mac has its engine; else the way to install it.
        try await openRow(.voice)
        #expect(openStep == .voice)
        if store.simpleSnapshot[.voice].status == .unavailable {
            #expect(control("Installa…") != nil, "Voce cannot run and does not offer the install: \(screen())")
            step("Voce", sees: "the cleaner is not installed on this Mac: «Installa…»")
        } else {
            let clean = await mainControl("Pulisci la voce")
            try await tap("Pulisci la voce")
            #expect(await until(90) { store.simpleSnapshot.cleaned && store.simpleSnapshot.busy == nil }, "the voice was not cleaned: \(screen())")
            await app.settle()
            #expect(control("Pulisci la voce")?.value == "1")
            step("Voce › Pulisci la voce (\(clean))", sees: "the voice cleaned at −15 LUFS, the step done")
        }

        // 6. Grafica: a title at the playhead.
        store.preview.seek(0)
        try await openRow(.graphics)
        #expect(openStep == .graphics)
        let titleLine = await mainControl("Titolo")
        rig.click(try #require(control("Titolo")).centre)
        await app.settle()
        await app.idle(0.4)
        #expect(rig.isTyping, "the title form does not take the keyboard")
        rig.type("SEMPLICE")
        await mainControl("Aggiungi")
        rig.click(try #require(control("Aggiungi"), "the title form's Aggiungi cannot be reached: \(screen())").centre)
        await app.settle()
        let titleClip = { self.store.project?.tracks.flatMap(\.clips).first { $0.title?.text.contains("SEMPLICE") == true } }
        #expect(await until { titleClip() != nil }, "no title: \(screen())")
        if let t = titleClip() {
            store.preview.seek(t.start.seconds + 0.5)
            await app.idle(0.3)
            #expect(drawn.contains { $0.clipID == t.id }, "the title is not on the picture")
        }
        #expect(store.simpleSnapshot[.graphics].status == .done)
        step("Grafica › Titolo, types SEMPLICE, Aggiungi (\(titleLine))", sees: "the title on the picture, the step done")

        // A step back and forward again: nothing lost.
        let kept = simpleSignature
        let states = SimpleStep.allCases.map { store.simpleSnapshot[$0].status }
        try await openRow(.voice)
        #expect(openStep == .voice && simpleSignature == kept, "going back to Voce changed the project")
        try await openRow(.graphics)
        #expect(openStep == .graphics && simpleSignature == kept && store.simpleSnapshot[.graphics].status == .done, "forward to Grafica again: \(screen())")
        step("Clicks Voce on the rail, then Grafica", sees: "each step as it was left")

        // Pro and back: the same project, the same steps.
        try await tap("Pro")
        #expect(await until { store.nav.level == .pro && laneY("V1") != nil }, "«Pro» did not show the timeline: \(screen())")
        #expect(simpleSignature == kept, "Pro changed the project")
        step("Clicks «Pro»", sees: "the timeline with the edit, captions, music, sounds and title")
        try await tap("Semplice")
        #expect(await until { store.nav.level == .simple && stepRow(.cut) != nil }, "back to Semplice: \(screen())")
        #expect(simpleSignature == kept, "back to Semplice changed the project")
        #expect(SimpleStep.allCases.map { store.simpleSnapshot[$0].status } == states, "the steps' states changed through Pro")
        #expect(openStep == .graphics, "back from Pro the open step is \(String(describing: openStep)), not Grafica where the person left")
        step("Clicks «Semplice» again", sees: "the six steps as they were, \(openStep?.title() ?? "no step") open")

        guard export else { return }
        // «Esporta il reel»: Esporta on Reel 9:16, then the file.
        let exportButton = try #require(rig.controls().first { $0.name.hasPrefix("Apre Esporta con il formato Reel 9:16") }, "no «Esporta il reel»: \(screen())")
        rig.click(exportButton.centre)
        await app.settle()
        #expect(store.nav.activity == .export && ExportOptions.shared.preset == "9:16", "«Esporta il reel» did not open Esporta on 9:16")
        #expect(await until(6) { shows("da sistemare") || shows("controlli rispettati") || shows("controllo rispettato") }, "no rules card: \(screen())")
        step("Clicks «Esporta il reel»", sees: "Esporta on Reel 9:16, the rules card")
        let out = scratch.appendingPathComponent("semplice.mp4")
        RigGuard.panelAnswer = [out]
        if let fixAll = control("Sistema tutto ed esporta") { rig.click(fixAll.centre) } else { try await tap("Esporta video…") }
        await app.settle()
        #expect(await until(90) { FileManager.default.fileExists(atPath: out.path) && store.jobs.latest("export")?.isRunning == false }, "no exported file: \(screen())")
        let movie = try await Journey.probe(out)
        #expect(movie.width * 16 == movie.height * 9, "exported \(movie.width)×\(movie.height), not 9:16")
        #expect(abs(movie.seconds - (store.project?.duration.seconds ?? 0)) < 0.1)
        step("Esporta video…, Salva", sees: "the file \(movie.width)×\(movie.height), \(String(format: "%.1f", movie.seconds)) s")
    }
}

// MARK: - Journey 6: a reel finished by hand

extension Journey {
    /// The Program monitor's «Vai all'inizio» (the Source monitor has the same button, left of it).
    func toStart() async throws {
        rig.click(try #require(rig.elements().filter { $0.label == "Vai all'inizio" && $0.visible }.max { $0.frame.minX < $1.frame.minX }).centre)
        await app.settle()
    }

    /// The Grafica row named `name` (scrolled into view) clicked; for a title the form opens with its words selected:
    /// `text` replaces them and «Aggiungi» puts it at the playhead. Returns the new clip.
    func addTitle(_ row: String, _ text: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Clip {
        let found = await reveal(row, at: CGPoint(x: 200, y: 600))
        let r = try #require(found, "no «\(row)» in Grafica: \(screen())", sourceLocation: sourceLocation)
        rig.click(r.centre)
        await app.settle()
        await app.idle(0.4)
        #expect(rig.isTyping, "the «\(row)» form does not take the keyboard", sourceLocation: sourceLocation)
        rig.type(text)
        let add = try #require(control("Aggiungi"), "the «\(row)» form's Aggiungi is out of sight: \(screen())", sourceLocation: sourceLocation)
        rig.click(add.centre)
        await app.settle()
        let clip = { self.store.project?.tracks.flatMap(\.clips).first { $0.title?.text.contains(text) == true } }
        #expect(await until { clip() != nil }, "no «\(text)»: \(screen())", sourceLocation: sourceLocation)
        return try #require(clip(), sourceLocation: sourceLocation)
    }

    /// Clicks `clipID` on the Program picture at `time` and types `scale` (per cent) in the Inspector's Scala: it is
    /// selected, the Inspector shows its size, and the new size is drawn. Returns the line for the audit table.
    func pickAndScale(_ clipID: String, at time: Double, to scale: Int, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async throws -> String {
        // A graphic just added plays once around itself (GraphicsActions.playAround): the person waits for it to stop.
        _ = await until(4) { !store.preview.isPlaying }
        store.preview.seek(time)
        await app.idle(0.4)
        guard let e = drawn.first(where: { $0.clipID == clipID }), let p = onPicture(e.center[0], e.center[1]) else {
            Issue.record("\(what) is not on the picture at \(time) s: \(drawn.map { "\($0.kind) \($0.clipID ?? "-")" })", sourceLocation: sourceLocation)
            return "\(what) not on the picture"
        }
        rig.click(p)
        await app.settle()
        #expect(store.canvasSelection == clipID, "a click on \(what) selected \(String(describing: store.canvasSelection))", sourceLocation: sourceLocation)
        let before = inspectorValue(self, "Scala")
        #expect(inspectorNumber(before).map { abs($0 - e.scale * 100) <= 1 } == true,
                "the Inspector's Scala reads \(before ?? "nothing") for \(what) drawn at \(e.scale)", sourceLocation: sourceLocation)
        guard let field = rig.elements().first(where: { $0.role == "AXStaticText" && $0.value == before && $0.frame.minX > rig.size.width - Chrome.rightWidth }) else {
            Issue.record("no Scala value to click for \(what): \(screen())", sourceLocation: sourceLocation)
            return "\(what): no Scala"
        }
        let n = store.activity.count
        rig.click(field.centre)
        rig.pump(0.1)
        #expect(rig.isTyping, "a click on \(what)'s Scala did not make a field", sourceLocation: sourceLocation)
        rig.key("a", keyCode: 0, modifiers: .command)
        rig.type("\(scale)")
        rig.key(.returnKey)
        await app.settle()
        #expect(app.commands(since: n) == ["clip.place"], "\(what): the Inspector's Scala ran \(app.commands(since: n))", sourceLocation: sourceLocation)
        let after = drawn.first { $0.clipID == clipID }
        #expect(after.map { abs($0.scale - Double(scale) / 100) < 0.01 } == true, "\(what) drawn at \(String(describing: after?.scale)) after Scala \(scale) %",
                sourceLocation: sourceLocation)
        return "clicked on the picture, Scala \(before ?? "?") → \(inspectorValue(self, "Scala") ?? "?")"
    }

    /// Journey 6 from a cut take (`cuts`: where the pieces of V1 join).
    func finishByHand(cuts: [Double]) async throws {
        // Marca › Café Atelier (a built-in kit of no real business, its placeholder logo).
        try await tap("Marca del progetto: il brand kit di sottotitoli, titoli e logo")
        let picker = try #require(await popover(), "Marca opened no picker")
        try await tap("Café Atelier", in: picker)
        #expect(await until { store.project?.brand?.id == "cafe-atelier" }, "the kit was not applied")
        #expect(await until { shows("Café Atelier") }, "the window does not name the kit: \(screen())")
        step("Marca › Café Atelier", sees: "«Café Atelier» named, its captions on the picture")

        // A title at the opening, in the kit's style.
        try await toStart()
        try await tap("Grafica")
        let title = try await addTitle("Titolo", "IL REEL")
        #expect(title.start.seconds < 0.05, "the title is not at the opening (\(title.start.seconds) s)")
        let titleLine = try await pickAndScale(title.id, at: title.start.seconds + min(1, (title.end.seconds - title.start.seconds) / 2), to: 80, "the title")
        step("Grafica › Titolo «IL REEL» at 0:00; on the picture, Scala 80 in the Inspector", sees: "the title on the timeline and the picture; \(titleLine)")

        // The call to action at the end: a label over the last second and a half.
        let duration = try #require(store.project?.duration.seconds)
        store.preview.seek(max(0, duration - 1.5))
        await app.idle(0.3)
        let cta = try await addTitle("Etichetta", "SEGUICI")
        let after = try #require(store.project?.duration.seconds)
        // A title added without a length of its own ends with the video: the reel keeps its length (#72).
        #expect(abs(after - duration) < 0.05, "the call to action made the reel \(after) s long (it was \(duration) s): \(cta.start.seconds)–\(cta.end.seconds)")
        #expect(cta.end.seconds <= duration + 0.05, "the call to action runs past the end (\(cta.end.seconds) s of \(duration) s)")
        #expect(abs(cta.start.seconds - (duration - 1.5)) < 0.05, "the call to action does not start at the playhead (\(cta.start.seconds) s)")
        let ctaLine = try await pickAndScale(cta.id, at: (cta.start.seconds + min(cta.end.seconds, duration)) / 2, to: 120, "the call to action")
        // The Inspector names its track as the lane does (#75: «Titles 2»).
        #expect(shows(" · Titoli") && !shows("Titles"), "the Inspector does not name the call to action's track «Titoli»: \(screen())")
        step("Playhead 1.5 s before the end, Grafica › Etichetta «SEGUICI»", sees: "the label \(String(format: "%.1f–%.1f", cta.start.seconds, cta.end.seconds)) s; \(ctaLine)")

        // The logo, from Grafica › Logo.
        try await tap("Logo")
        try await tap("Logo nel video")
        #expect(await until { store.project?.tracks.contains { $0.role == "logo" && !$0.clips.isEmpty } == true }, "no logo: \(screen())")
        let logo = try #require(store.project?.tracks.first { $0.role == "logo" }?.clips.first)
        // The reel's rules want the logo only at the end: the switch puts it in the closing 2 s and says so (#74).
        let videoEnd = store.project?.videoEnd?.seconds ?? 0
        #expect(abs(logo.end.seconds - videoEnd) < 0.05 && abs(logo.start.seconds - max(0, videoEnd - 2)) < 0.05,
                "the logo is \(logo.start.seconds)–\(logo.end.seconds) s, not the closing 2 s of a \(videoEnd) s video")
        #expect(shows("Alla fine del video, come vuole la regola del reel."), "the switch's caption does not say the logo goes at the end: \(screen())")
        let logoLine = try await pickAndScale(logo.id, at: min(logo.end.seconds - 0.6, max(logo.start.seconds + 1, duration / 2)), to: 60, "the logo")
        step("Grafica › Logo › Logo nel video", sees: "«Alla fine del video, come vuole la regola del reel.»; the kit's logo in its corner \(String(format: "%.1f–%.1f", logo.start.seconds, logo.end.seconds)) s; \(logoLine)")

        // Audio › a music, under the voice.
        try await tap("Audio")
        #expect(store.nav.activity == .audio)
        RigGuard.panelAnswer = [try music()]
        try await tap("Aggiungi musica…")
        #expect(await until(30) { store.project.flatMap(AudioCalls.musicTrack) != nil && store.jobs.latest(AudioCalls.musicJob)?.isRunning == false }, "no music: \(screen())")
        await app.settle()
        let musicTrack = try #require(store.project.flatMap(AudioCalls.musicTrack))
        #expect(musicTrack.ducking != nil, "the music does not go down under the voice")
        #expect(control("Abbassa sotto la voce")?.value == "1" && shows("Quanto scende"), "the panel does not show the ducking: \(screen())")
        let length = store.project?.duration.seconds ?? 0
        #expect(abs(musicTrack.end.seconds - length) < 0.1, "the music lasts \(musicTrack.end.seconds) s of a \(length) s reel")
        let level = rig.elements().first { $0.role == "AXStaticText" && $0.value == "LUFS" }.flatMap { unit in
            rig.elements().filter { $0.role == "AXStaticText" && abs($0.centre.y - unit.centre.y) < 8 && $0.frame.maxX <= unit.frame.minX + 1 }.max { $0.frame.minX < $1.frame.minX }?.value
        }
        // The music's job checks it under the voice on its own; «Controlla sotto la voce» is offered when it did not.
        if store.musicCheck == nil {
            try await tap("Controlla sotto la voce")
            #expect(await until(60) { store.jobs.latest("audio.checkDucking")?.isRunning == false && store.musicCheck != nil }, "the check under the voice did not end: \(screen())")
            await app.settle()
        }
        #expect(store.musicCheck.map { shows($0.line) } == true, "the panel does not show the check under the voice: \(screen())")
        let check = store.musicCheck
        step("Audio › Aggiungi musica… musica.wav, Controlla sotto la voce",
             sees: "the music on its track, «Abbassa sotto la voce» on; the level meter \(level ?? "not drawn") LUFS; the check: \(check?.line ?? "none")")

        // A sound effect on a cut: the playhead on the join, Effetti sonori › + on a whoosh.
        let at = cuts.first ?? 1
        if cuts.isEmpty { Issue.record("the automatic edit left one piece: the sound goes at 1 s, not on a cut") }
        store.preview.seek(at)
        await app.idle(0.2)
        try await tap("Effetti sonori")
        // The first sound of the group on screen: its row plays it, its + (at the row's right end) adds it at the playhead.
        await app.idle(0.5)   // the list lays out its rows
        let titles = SoundLibrary.all(store.engine.context.services.config).map(SoundNames.title)
        let row = try #require(rig.controls().first { c in c.role == "AXButton" && titles.contains { c.label.hasPrefix($0 + ",") } }, "no sound's row: \(screen())")
        // The + is offered to assistive clients as the row's named action (#73).
        let named = ((row.ref as? NSObject)?.value(forKey: "accessibilityCustomActions") as? [NSAccessibilityCustomAction])?.map(\.name) ?? []
        #expect(named.contains("Aggiungi al cursore (pista Effetti)"), "the sound's row offers no add action: \(named)")
        // The + sits at the row's right end (22 pt, 10 pt in).
        rig.click(CGPoint(x: row.frame.maxX - 10 - 11, y: row.centre.y))
        await app.idle(0.3)
        await app.settle()
        let sfx = store.project?.tracks.filter { $0.role == "sfx" }.flatMap(\.clips) ?? []
        #expect(sfx.count == 1 && abs((sfx.first?.start.seconds ?? -9) - at) < 0.05, "the sound is not on the cut at \(at) s: \(sfx.map(\.start.seconds))")
        step("Playhead on the cut at \(String(format: "%.2f", at)) s, Audio › Effetti sonori › + on the first whoosh", sees: "the sound on the Effetti track at the cut")

        // A look: Grafica › Filtri › Pellicola.
        try await tap("Grafica")
        try await tap("Filtri")
        let film = SimpleLooks.title("film")
        let filmRow = await reveal(film, at: CGPoint(x: 200, y: 600))
        rig.click(try #require(filmRow, "no «\(film)» in Grafica › Filtri: \(screen())").centre)
        await app.settle()
        #expect(await until { store.project?.grade?.look == "film" }, "the look is not on: \(String(describing: store.project?.grade))")
        step("Grafica › Filtri › \(film)", sees: "the whole picture in the look")

        // Esporta: the rules card, a failing rule fixed with its own button, the file.
        try await tap("Esporta")
        #expect(store.nav.activity == .export)
        #expect(await until(6) { shows("da sistemare") || shows("controlli rispettati") }, "no rules card: \(screen())")
        let report = try await store.silent("rules.check")
        let failing = report["violations"]?.arrayValue?.filter { $0["severity"] == "fail" } ?? []
        let loudness = rig.elements().first { $0.role == "AXStaticText" && ($0.value.hasSuffix(" LUFS") || $0.value == "–") && $0.frame.minX > 300 }?.value
        step("Clicks Esporta", sees: "the rules card: \(failing.count) da sistemare (\(failing.compactMap { $0["check"]?.stringValue }.joined(separator: ", "))); Loudness «\(loudness ?? "?")» (the rig has no meter running)")
        if let fix = control("Sistema") {
            let before = failing.count
            rig.click(fix.centre)
            await app.settle()
            let now = try await store.silent("rules.check")["violations"]?.arrayValue?.filter { $0["severity"] == "fail" }.count ?? 0
            #expect(now < before, "«Sistema» fixed nothing (\(before) → \(now) failing)")
            // The card follows the fix before the next click (its buttons change with what is left).
            #expect(await until(6) { now == 0 ? shows("controlli rispettati") : shows("\(now) da sistemare") }, "the rules card does not show the fix: \(screen())")
            await app.settle()
            step("Clicks «Sistema» under the first failing rule", sees: "\(before) → \(now) da sistemare")
        } else if !failing.isEmpty {
            Issue.record("a failing rule has no «Sistema» of its own: \(failing)")
        }
        let out = scratch.appendingPathComponent("reel-finito.mp4")
        RigGuard.panelAnswer = [out]
        let left = try await store.silent("rules.check")["violations"]?.arrayValue?.filter { $0["severity"] == "fail" }.compactMap { $0["check"]?.stringValue } ?? []
        if let fixAll = control("Sistema tutto ed esporta") {
            rig.click(fixAll.centre)
        } else if let plain = control("Esporta video…") {
            rig.click(plain.centre)
        } else {
            // Every rule left has its fix (#74: the logo's rule used to have none): «Esporta lo stesso» is never the way on.
            Issue.record("neither «Sistema tutto ed esporta» nor «Esporta video…» (left: \(left)): \(screen())")
            try await tap("Esporta lo stesso")
            step("No way on but «Esporta lo stesso»", sees: "left: \(left.joined(separator: ", "))")
        }
        await app.settle()
        #expect(await until(180) { FileManager.default.fileExists(atPath: out.path) && store.jobs.latest("export")?.isRunning == false },
                "no exported file (export job: \(String(describing: store.jobs.latest("export").map { "\($0.state) \($0.detail)" }))): \(screen())")
        await app.settle()
        let p = try #require(store.project)
        let movie = try await Journey.probe(out)
        #expect(abs(movie.seconds - p.duration.seconds) < 0.1, "exported \(movie.seconds) s of a \(p.duration.seconds) s reel")
        let failingAfter = try await store.silent("rules.check")["violations"]?.arrayValue?.filter { $0["severity"] == "fail" }.compactMap { $0["check"]?.stringValue } ?? []
        #expect(failingAfter.isEmpty, "rules still fail after the export: \(failingAfter)")
        // #77 (open, a decision to take): with the speech to the last frame, the fix of «A clean pause before the logo»
        // moves the logo past the end of the video, and the reel gets longer with the logo over black.
        let videoLength = p.videoEnd?.seconds ?? 0
        withKnownIssue("#77: the logo-pause fix moves the logo past the end of the video") {
            #expect(movie.seconds <= videoLength + 0.1, "the exported reel is \(movie.seconds) s for \(videoLength) s of video")
        }
        #expect(await until(6) { shows("controlli rispettati") }, "the rules card does not show every rule respected: \(screen())")
        step("Esporta video…, Salva", sees: "the file \(movie.width)×\(movie.height), \(String(format: "%.1f", movie.seconds)) s; still failing: \(failingAfter.isEmpty ? "nothing" : failingAfter.joined(separator: ", "))")
    }
}

// MARK: - Journey 7: a project saved, closed and found again

/// A menu item's action (the rig's stand-in for the menu bar: an NSMenu drawn from the command table).
final class MenuAction: NSObject {
    let run: @MainActor () -> Void
    init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    @objc func fire() { MainActor.assumeIsolated { run() } }
}

extension Journey {
    /// The command table of the menu bar on this window (MenuCommands.all, as EditorCommands draws it).
    var menuContext: MenuContext {
        MenuContext(bench: app.store.bench, recents: app.store.bench.recents, recorder: app.recorder,
                    openGuide: { _ in }, openShortcuts: {}, showAbout: {})
    }

    /// The menu item `id` run as the menu runs it.
    func menu(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let item = try #require(MenuCommands.all(menuContext).first { $0.id == id }, "no menu item \(id)", sourceLocation: sourceLocation)
        #expect(item.enabled, "the menu's \(item.title) is disabled", sourceLocation: sourceLocation)
        item.run()
    }

    /// The application's main menu drawn from the command table with its keys, so that a key event finds its item the
    /// way AppKit finds it in the app's menu bar. Returns what to put back.
    func installMenuBar() -> (previous: NSMenu?, actions: [MenuAction]) {
        let previous = NSApp.mainMenu
        let bar = NSMenu(), top = NSMenuItem(), menu = NSMenu(title: "Regista")
        var actions: [MenuAction] = []
        for c in MenuCommands.all(menuContext) {
            let action = MenuAction(c.run)
            actions.append(action)
            let item = NSMenuItem(title: c.title, action: #selector(MenuAction.fire), keyEquivalent: c.shortcut.map { String($0.key.character).lowercased() } ?? "")
            item.target = action
            if let m = c.shortcut?.modifiers {
                var flags: NSEvent.ModifierFlags = []
                if m.contains(.command) { flags.insert(.command) }
                if m.contains(.shift) { flags.insert(.shift) }
                if m.contains(.option) { flags.insert(.option) }
                if m.contains(.control) { flags.insert(.control) }
                item.keyEquivalentModifierMask = flags
            }
            item.isEnabled = c.enabled
            menu.addItem(item)
        }
        top.submenu = menu
        bar.addItem(top)
        NSApp.mainMenu = bar
        return (previous, actions)
    }

    /// The project as a person would notice a loss: every clip on every track with its times, a title's words and size,
    /// a clip's level and size, the tracks' ducking, the captions' style, the look, the brand, the format.
    var savedSignature: String {
        guard let p = store.project else { return "no project" }
        let tracks = p.tracks.map { t in
            "\(t.kind.rawValue)/\(t.role ?? "")/\(t.name)\(t.muted ? " muted" : "")[" + t.clips.map { c in
                "\(c.id)@\(String(format: "%.3f-%.3f", c.start.seconds, c.end.seconds))"
                    + (c.title.map { " «\($0.text)» \($0.size)" } ?? "") + (c.gain.map { " gain \($0)" } ?? "")
                    + (c.transform.map { " scale \($0.scale)" } ?? "")
            }.joined(separator: ", ") + "]" + (t.ducking.map { " ducking \($0.depth)" } ?? "")
        }
        let captions = p.tracks.first { $0.captions != nil }?.captions
        return tracks.joined(separator: " ")
            + " captions:\(captions?.style.id ?? "-") \(captions?.style.fontSize ?? 0) \(captions?.chunks.count ?? 0) chunks"
            + " look:\(p.grade?.look ?? "-") \(p.grade?.amount ?? 0) brand:\(p.brand?.id ?? "-")"
            + " format:\(p.settings.width)×\(p.settings.height)@\(p.settings.frameRate.num)/\(p.settings.frameRate.den)"
    }

    /// The tab's × (its tooltip reads «Chiudi la scheda»).
    func closeTab(answer: NSApplication.ModalResponse, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let alerts = RigGuard.events.filter { $0.kind == .alert }.count
        RigGuard.alertAnswer = answer
        defer { RigGuard.alertAnswer = .alertSecondButtonReturn }
        try await tap("Chiudi la scheda", sourceLocation: sourceLocation)
        await app.idle(0.3)
        await app.settle()
        #expect(RigGuard.events.filter { $0.kind == .alert }.count == alerts + 1, "the × did not ask about the unsaved changes",
                sourceLocation: sourceLocation)
    }

    /// Grafica › Filtri › the look `id` clicked; the project is in it.
    func pickLook(_ id: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try await tap("Grafica", sourceLocation: sourceLocation)
        try await tap("Filtri", sourceLocation: sourceLocation)
        let name = SimpleLooks.title(id)
        let row = await reveal(name, at: CGPoint(x: 200, y: 600))
        rig.click(try #require(row, "no «\(name)» in Grafica › Filtri: \(screen())", sourceLocation: sourceLocation).centre)
        await app.settle()
        #expect(await until { store.project?.grade?.look == id }, "the look is not «\(name)»: \(String(describing: store.project?.grade))",
                sourceLocation: sourceLocation)
    }

    /// Frames of a movie at `times` (seconds).
    nonisolated static func frames(_ url: URL, at times: [Double]) async throws -> [CGImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var out: [CGImage] = []
        for t in times { out.append(try await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image) }
        return out
    }

    /// Mean difference of two pictures, 0…1 per channel (both drawn at 90×160).
    nonisolated static func difference(_ a: CGImage, _ b: CGImage) -> Double {
        func pixels(_ i: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: 90 * 160 * 4)
            let ctx = CGContext(data: &data, width: 90, height: 160, bitsPerComponent: 8, bytesPerRow: 90 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(i, in: CGRect(x: 0, y: 0, width: 90, height: 160))
            return data
        }
        let (x, y) = (pixels(a), pixels(b))
        return zip(x, y).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(x.count) / 255
    }

    /// Journey 7 (JourneyTests.aProjectIsSavedClosedAndFoundAgain).
    func foundAgain() async throws {
        let cuts = try await recordAndCut()
        try await finishByHand(cuts: cuts)
        let name = try #require(store.project?.name)
        let projectURL = try #require(store.projectURL, "the reel has no folder")

        // The tab says it has unsaved changes.
        #expect(store.dirty, "the finished reel reads as saved")
        #expect(shows("Modifiche non salvate"), "the status bar does not say the changes are unsaved: \(screen())")
        step("Journey 6's reel, finished and exported", sees: "the tab's dot, «Modifiche non salvate» in the status bar")

        // Salva, from the menu's command table.
        try menu("save")
        await app.settle()
        #expect(await until { !store.dirty }, "the menu's Salva did not save")
        #expect(await until { shows("Salvato") }, "the status bar does not say saved: \(screen())")
        step("File › Salva (the menu's command)", sees: "«Salvato» in the status bar, the tab's dot gone")

        // A change, then ⌘S as a key event through the menu bar's keys.
        try await pickLook("golden")
        #expect(store.dirty && shows("Modifiche non salvate"), "a change does not read as unsaved")
        let bar = installMenuBar()
        defer { NSApp.mainMenu = bar.previous }
        rig.key("s", keyCode: 1, modifiers: .command)
        await app.settle()
        #expect(await until { !store.dirty }, "⌘S did not save")
        #expect(await until { shows("Salvato") }, "the status bar does not say saved after ⌘S: \(screen())")
        let saved = try ProjectStore.load(from: projectURL)
        #expect(saved.grade?.look == "golden", "⌘S did not write the change: \(String(describing: saved.grade))")
        step("Grafica › Filtri › \(SimpleLooks.title("golden")), then ⌘S", sees: "the dot while unsaved, then «Salvato»")

        // The history: the steps are listed; one back and forward again gives the same project.
        let before = store.project
        let clock = try #require(rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix("Cronologia") }, "no history button: \(screen())")
        rig.click(clock.centre)
        let history = try #require(await popover(), "the history button opened nothing")
        let listed = history.elements().filter { $0.role == "AXStaticText" && $0.visible }.map(\.name)
        #expect(listed.contains(CommandTitles.title("look.apply")) && listed.contains(CommandTitles.title("title.add")),
                "the history does not list the edits: \(listed)")
        step("Clicks the history button (the clock)", sees: "the edits, newest first: \(listed.prefix(4).joined(separator: ", "))…")
        try await tap(loc("menu.undo"), in: history)
        #expect(await until { store.project?.grade?.look == "film" }, "one step back is not the look before: \(String(describing: store.project?.grade))")
        try await tap(loc("menu.redo"), in: history)
        #expect(await until { store.project == before }, "back and forward again is not the same project")
        step("In the history: Annulla, Ripeti", sees: "the look before, then the same project again")
        history.window.orderOut(nil)
        await app.settle()
        if store.dirty { try menu("save"); await app.settle() }

        // A change, the tab's ×: Annulla keeps the tab and the change.
        try await pickLook("airy")
        try await closeTab(answer: .alertSecondButtonReturn)
        #expect(store.project?.grade?.look == "airy" && store.dirty, "Annulla did not keep the tab and its change")
        step("Grafica › Filtri › \(SimpleLooks.title("airy")), the tab's ×, Annulla", sees: "«Salvare le modifiche a «\(name)»?»; the tab stays, unsaved")

        // Non salvare: the tab closes, the change is dropped.
        try await closeTab(answer: .alertThirdButtonReturn)
        #expect(await until { store.project == nil }, "Non salvare did not close the tab: \(screen())")
        #expect(try ProjectStore.load(from: projectURL).grade?.look == "golden", "Non salvare wrote the change")
        // Inizio lists it with its name and its length.
        // Inizio's list of recent projects (the side panel) reads «name, m:ss».
        let seconds = Int(saved.duration.seconds.rounded())
        let length = String(format: "%d:%02d", seconds / 60, seconds % 60)
        let recent = try #require(control(name), "«\(name)» is not among the recent projects: \(screen())")
        #expect(rig.elements().contains { $0.isControl && $0.visible && $0.label == "\(name), \(length)" }, "the recent project does not show its length \(length): \(screen())")
        step("The tab's ×, Non salvare", sees: "Inizio, «\(name)» among the recent projects with its length \(length)")
        rig.click(recent.centre)
        #expect(await until(10) { store.project?.name == name }, "the project did not reopen")
        await app.settle()
        #expect(store.project?.grade?.look == "golden" && !store.dirty, "the reopened project is not the saved one: \(String(describing: store.project?.grade))")
        step("Clicks «\(name)» in Recenti", sees: "the project in its tab, in \(SimpleLooks.title("golden")) (the dropped change is gone)")

        // Salva: a change written by the ×.
        try await pickLook("vivid")
        let expected = savedSignature
        let expectedProject = store.project
        let rules = try await store.silent("rules.check")
        let reference = scratch.appendingPathComponent("prima.mp4")
        _ = try await store.silent("export.render", ["path": .string(reference.path), "preset": "9:16"])
        try await closeTab(answer: .alertFirstButtonReturn)
        #expect(await until { store.project == nil }, "Salva did not close the tab: \(screen())")
        #expect(try ProjectStore.load(from: projectURL).grade?.look == "vivid", "Salva did not write the change")
        step("Grafica › Filtri › \(SimpleLooks.title("vivid")), the tab's ×, Salva", sees: "Inizio; the change written")

        // Found again: everything as it was.
        rig.click(try #require(control(name), "«\(name)» is not among the recent projects: \(screen())").centre)
        #expect(await until(10) { store.project?.name == name }, "the project did not reopen")
        await app.settle()
        #expect(savedSignature == expected, "the reopened project differs:\n\(savedSignature)\nsaved:\n\(expected)")
        #expect(store.project == expectedProject, "the reopened project is not equal to the saved one (beyond what the signature reads)")
        #expect(shows(name) && shows("Marca: Café Atelier") || shows("Café Atelier"), "the window does not show the project and its kit: \(screen())")
        let again = try await store.silent("rules.check")
        #expect(again["pass"] == rules["pass"] && again["failures"] == rules["failures"], "the rules read otherwise: \(again) for \(rules)")
        step("Clicks «\(name)» in Recenti", sees: "every clip on every track at its times, the titles, the captions' style, \(SimpleLooks.title("vivid")), the kit, the music's level and ducking, the format")

        // Undo right after reopening: nothing to take back, nothing harmful.
        #expect(control("Annulla l'ultima modifica")?.enabled == false, "Annulla is offered right after reopening")
        let opened = store.project
        rig.click(try #require(rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix("Annulla l'ultima modifica") }).centre)
        await app.settle()
        rig.key("z", keyCode: 6, modifiers: .command)
        await app.settle()
        #expect(store.project == opened, "an undo right after reopening changed the project")
        rig.click(try #require(rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix("Cronologia") }).centre)
        let empty = try #require(await popover(), "the history button opened nothing")
        #expect(empty.elements().contains { $0.name.contains("passo annullabile") }, "the history after reopening is not empty")
        step("Right after reopening: Annulla, ⌘Z, the history", sees: "nothing to take back: Annulla off, the history says every change is a step to undo")
        empty.window.orderOut(nil)
        await app.settle()

        // Export again: the same length and the same picture as before the save.
        try await tap("Esporta")
        let out = scratch.appendingPathComponent("dopo.mp4")
        RigGuard.panelAnswer = [out]
        #expect(await until(6) { control("Esporta video…") != nil || control("Sistema tutto ed esporta") != nil }, "no way to export: \(screen())")
        try await tap(control("Esporta video…") != nil ? "Esporta video…" : "Sistema tutto ed esporta")
        #expect(await until(120) { FileManager.default.fileExists(atPath: out.path) && store.jobs.latest("export")?.isRunning == false },
                "no exported file: \(screen())")
        let first = try await Journey.probe(reference), second = try await Journey.probe(out)
        #expect(abs(first.seconds - second.seconds) < 0.05 && first.width == second.width, "exported \(second) after reopening, \(first) before")
        let times = [0.4, second.seconds / 2, max(0, second.seconds - 0.4)]
        let a = try await Journey.frames(reference, at: times), b = try await Journey.frames(out, at: times)
        let differences = zip(a, b).map { Journey.difference($0, $1) }
        #expect(differences.allSatisfy { $0 < 0.02 }, "the picture differs after reopening at \(times): \(differences)")
        step("Esporta › \(control("Esporta video…") != nil ? "Esporta video…" : "Sistema tutto ed esporta")", sees: "the file \(second.width)×\(second.height), \(String(format: "%.2f", second.seconds)) s as before; the frames at \(times.map { String(format: "%.1f", $0) }.joined(separator: ", ")) s differ by \(differences.map { String(format: "%.3f", $0) }.joined(separator: ", "))")

        // The app launched again on the same defaults and support folder.
        try await relaunch()
        let same = { (u: URL?) in u.map { RecentList.normalized($0.path) == RecentList.normalized(projectURL.path) } == true }
        let restored = app.store.bench.tabs.first { same($0.projectURL) || same($0.pendingPath) }
        if let tab = restored {
            #expect(await until(10) { tab.project != nil }, "the remembered tab did not open its project")
            app.store.bench.select(tab.tabID)
            await open(app.store.bench.nav)
            #expect(savedSignature == expected, "the relaunched project differs:\n\(savedSignature)\nsaved:\n\(expected)")
            #expect(rig.elements().contains { $0.role == "AXStaticText" && $0.name == name && $0.frame.minY < 90 }, "the tab does not name «\(name)»: \(screen())")
            step("The app launched again", sees: "the project reopened in its tab (as it was open at quit), \(store.nav.workspace) on screen")
        } else {
            #expect(control(name) != nil, "after a relaunch the project is neither reopened nor offered: \(screen())")
            step("The app launched again", sees: "Inizio, «\(name)» offered among the recent projects (not reopened)")
        }
    }
}
