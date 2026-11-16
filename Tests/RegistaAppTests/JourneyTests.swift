import AppKit
import AVFoundation
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// Three whole journeys driven by clicks, from an empty app to an exported file, the way a person does the work: the
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
    let app: AppRig
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

    /// The window at the default size on `nav`, the keyboard going to it as in the app.
    func open(_ nav: Navigation) async {
        app.hostEditor(nav, language: "it")
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
        try await j.tap("Il logo della marca nel video e le sue animazioni")
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
        let tab = try #require(j.rig.elements().first { $0.isControl && $0.label.hasPrefix("Montaggio") && $0.frame.minY < 90 }, "no tab: \(j.screen())")
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
        let tab2 = try #require(j.rig.elements().first { $0.isControl && $0.label.hasPrefix("Montaggio") && $0.frame.minY < 90 }, "no tab: \(j.screen())")
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
        withKnownIssue("#52: at the default window size the face layout's tiles are below the fold of Registra's column", isIntermittent: true) {
            #expect(j.control("Bolla") != nil, "the face layout's tiles are not in view")
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
}
}
