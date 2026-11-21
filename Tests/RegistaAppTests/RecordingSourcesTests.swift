import AppKit
import Combine
import CoreGraphics
import Foundation
import RegistaCore
import Testing
@testable import Regista

// R1 (#50): the Registra screen's sources as a pure value — presets ↔ switches, the at-least-one rule, device memory,
// persistence and the screen fallback.

private func scratchDefaults() -> UserDefaults { TestDefaults.make("sources-tests") }

@Test func presetsSetTheSwitchesAndTheMatchingPresetShowsAsSelected() {
    var s = RecordingSources()
    for p in RecordingSources.Preset.allCases {
        s.apply(p)
        #expect(s.preset == p)
    }
    s.apply(.screenOnly)
    #expect(s.screen && !s.camera && !s.microphone)
    s.apply(.voice)
    #expect(!s.screen && !s.camera && s.microphone)
    // Screen + microphone, no camera: a custom combination, no preset lit.
    s.apply(.screenFace)
    s.camera = false
    #expect(s.preset == nil)
    // A preset touches only screen, camera and microphone.
    s.systemAudio = true
    s.prompter = false
    s.apply(.face)
    #expect(s.systemAudio && !s.prompter && s.preset == .face)
}

@Test func atLeastOneOfScreenCameraOrMicrophoneMustBeOn() {
    var s = RecordingSources()
    s.switches = .init(screen: false, camera: false, microphone: false)
    s.systemAudio = true
    s.prompter = true
    #expect(!s.hasSomethingToRecord)
    #expect(s.blockReason(RecordingEnvironment()) == "Accendi almeno lo schermo, la camera o il microfono")
    s.microphone = true
    #expect(s.blockReason(RecordingEnvironment()) == nil)
    // A source that is on but not allowed by macOS blocks the take, with the reason.
    var env = RecordingEnvironment()
    env.microphone = .denied
    #expect(s.blockReason(env)?.hasPrefix("Microfono") == true)
    #expect(s.rows(env).first { $0.source == .microphone }?.blocked == true)
    // Off, the same denied source no longer matters.
    s.apply(.screenOnly)
    #expect(s.blockReason(env) == nil)
}

@Test func systemAudioNeedsTheScreenAndTheFaceLayoutNeedsScreenAndCamera() {
    var s = RecordingSources()
    s.apply(.face)
    s.systemAudio = true
    let row = s.rows(RecordingEnvironment()).first { $0.source == .systemAudio }!
    #expect(!row.enabled && row.disabledReason != nil && !s.recordsSystemAudio)
    #expect(!s.showsFaceLayout)
    s.apply(.screenFace)
    #expect(s.recordsSystemAudio && s.showsFaceLayout)
    #expect(s.rows(RecordingEnvironment()).first { $0.source == .systemAudio }!.enabled)
    // Without the camera the screen fills the frame whatever layout was picked; the pick is kept for later.
    s.layout = LayoutSpec(kind: .split)
    s.camera = false
    #expect(s.effectiveLayout.kind == .screen && s.layout.kind == .split)
    #expect(s.rows(RecordingEnvironment()).map(\.source) == [.screen, .camera, .microphone, .systemAudio, .prompter])
}

@Test func turningASourceOffNeverForgetsItsDevice() {
    var s = RecordingSources()
    s.cameraID = "cam-B"
    s.microphoneID = "mic-B"
    s.camera = false
    s.microphone = false
    #expect(s.cameraID == "cam-B" && s.microphoneID == "mic-B")
    s.camera = true
    let available = ["cam-A", "cam-B"]
    #expect(RecordingSources.device(remembered: s.cameraID, available: available, systemDefault: "cam-A") == "cam-B")
    // Unplugged: the default is used, the remembered choice stays and wins again once the device is back.
    #expect(RecordingSources.device(remembered: s.cameraID, available: ["cam-A"], systemDefault: "cam-A") == "cam-A")
    #expect(s.cameraID == "cam-B")
    #expect(RecordingSources.device(remembered: nil, available: ["x", "y"], systemDefault: nil) == "x")
    #expect(RecordingSources.device(remembered: nil, available: [], systemDefault: "x") == nil)
    // The row says "off" for a source that is off, the device name when on.
    var env = RecordingEnvironment()
    env.cameraName = "FaceTime HD"
    s.camera = false
    #expect(s.rows(env)[1].detail == "spento")
    s.camera = true
    #expect(s.rows(env)[1].detail == "FaceTime HD")
}

@Test func everyChoiceSurvivesARelaunch() {
    let d = scratchDefaults()
    var s = RecordingSources()
    s.switches = .init(screen: true, camera: false, microphone: true)
    s.systemAudio = true
    s.prompter = false
    s.cameraID = "cam-B"
    s.microphoneID = "mic-C"
    s.target = .area(7, CGRect(x: 10, y: 20, width: 800, height: 600))
    s.hideCursor = false
    s.layout = LayoutSpec(kind: .bubble, corner: "topLeft", shape: "rounded", size: "L")
    s.save(to: d)
    let back = RecordingSources.load(from: d)
    #expect(back == s)
    #expect(back.preset == nil)
}

@Test func theFirstLaunchCarriesTheOldRegistraSettings() {
    let d = scratchDefaults()
    d.set("none", forKey: "recorder.cameraID")
    d.set("mic-X", forKey: "recorder.microphoneID")
    d.set(false, forKey: "recorder.hideCursor")
    d.set(false, forKey: Prefs.startPrompterKey)
    let s = RecordingSources.load(from: d)
    #expect(!s.camera && s.cameraID == nil)
    #expect(s.microphone && s.microphoneID == "mic-X")
    #expect(!s.hideCursor && !s.prompter && !s.screen)
    // Nothing stored at all: camera and microphone on, the teleprompter with the recording, the cursor drawn later.
    let fresh = RecordingSources.load(from: scratchDefaults())
    #expect(fresh.preset == .face && fresh.prompter && fresh.hideCursor)
}

@Test func aStoredScreenThatIsGoneFallsBackToTheMainDisplay() {
    let displays: [CGDirectDisplayID] = [1, 2]
    #expect(RecordingSources.resolve(.display(2), displays: displays, windows: [], main: 1) == .display(2))
    #expect(RecordingSources.resolve(.display(9), displays: displays, windows: [], main: 1) == .display(1))
    #expect(RecordingSources.resolve(.window(40), displays: displays, windows: [40], main: 1) == .window(40))
    #expect(RecordingSources.resolve(.window(41), displays: displays, windows: [40], main: 2) == .display(2))
    let area = ScreenTarget.area(2, CGRect(x: 0, y: 0, width: 640, height: 480))
    #expect(RecordingSources.resolve(area, displays: displays, windows: [], main: 1) == area)
    #expect(RecordingSources.resolve(.area(5, .zero), displays: displays, windows: [], main: 1) == .display(1))
    #expect(RecordingSources.resolve(nil, displays: displays, windows: [], main: 7) == .display(1))
    #expect(RecordingSources.resolve(nil, displays: [], windows: [], main: 7) == nil)
}

// #67: the automatic paths ask macOS for the screen once per code signature, then guide; "Riprova" (a click) asks again.
@Test func screenPermissionIsAskedOncePerSignatureThenGuided() {
    for asked in [false, true] {
        for clicked in [false, true] {
            #expect(ScreenAccess.decide(preflight: true, askedForThisSignature: asked, userClicked: clicked) == .proceed)
        }
    }
    #expect(ScreenAccess.decide(preflight: false, askedForThisSignature: false, userClicked: false) == .ask)
    #expect(ScreenAccess.decide(preflight: false, askedForThisSignature: true, userClicked: false) == .guide)
    #expect(ScreenAccess.decide(preflight: false, askedForThisSignature: true, userClicked: true) == .ask)
    #expect(ScreenAccess.decide(preflight: false, askedForThisSignature: false, userClicked: true) == .ask)
    #expect(ScreenAccess.guidance().contains("riapri Regista"))
    #expect(ScreenAccess.guidance(promptShown: true).contains("«Riapri Regista»"))
    #expect(ScreenAccess.relaunchBlock(recording: true, unsaved: true) != nil)
    #expect(ScreenAccess.relaunchBlock(recording: false, unsaved: true)?.contains("Salva") == true)
    #expect(ScreenAccess.relaunchBlock(recording: false, unsaved: false) == nil)
}

// #67: the old boolean "asked" (no signature) counts as never asked and is removed.
@Test func theOldAskedFlagCountsAsNeverAskedAndIsRemoved() {
    let d = scratchDefaults()
    d.set(true, forKey: ScreenAskMemory.legacyKey)
    let memory = ScreenAskMemory(defaults: d, signature: CodeSignature.fingerprint(requirement: "identifier \"com.arkad.regista\""))
    memory.migrate()
    #expect(d.object(forKey: ScreenAskMemory.legacyKey) == nil)
    #expect(!memory.askedForThisSignature)
    memory.remember()
    #expect(memory.askedForThisSignature)
}

// #67: a new signature (new certificate, ad-hoc or unsigned build) asks again; the same one does not.
@Test func aChangedSignatureAsksForTheScreenAgain() {
    let d = scratchDefaults()
    let a = CodeSignature.fingerprint(requirement: "identifier \"com.arkad.regista\" and certificate leaf = H\"aaaa\"")
    let b = CodeSignature.fingerprint(requirement: "identifier \"com.arkad.regista\" and certificate leaf = H\"bbbb\"")
    #expect(a != b && a.count == 64)
    #expect(a == CodeSignature.fingerprint(requirement: "identifier \"com.arkad.regista\" and certificate leaf = H\"aaaa\""))
    #expect(CodeSignature.fingerprint(requirement: nil) == "none" && CodeSignature.fingerprint(requirement: "") == "none")
    ScreenAskMemory(defaults: d, signature: a).remember()
    #expect(ScreenAskMemory(defaults: d, signature: a).askedForThisSignature)
    #expect(!ScreenAskMemory(defaults: d, signature: b).askedForThisSignature)
    #expect(!ScreenAskMemory(defaults: d, signature: "none").askedForThisSignature)
    // The running test binary reads its own signature without failing (a hash, or "none" when unsigned).
    #expect(CodeSignature.current == "none" || CodeSignature.current.count == 64)
}

// #50: with several displays the picker draws them in their macOS arrangement; a very wide setup falls back to a grid.
@Test func displayTilesKeepTheMacOSArrangement() {
    let d = DisplayInfo.samples
    let tiles = DisplayInfo.arrangement(d, width: 304, maxHeight: 140, minTile: CGSize(width: 64, height: 40))!
    #expect(tiles.count == 4 && tiles.allSatisfy { $0.minX >= -0.5 && $0.maxX <= 304.5 })
    // Laptop (main) under the Studio Display, the DELL on the left, the LG on the right.
    #expect(tiles[1].maxY <= tiles[0].minY + 0.5)
    #expect(tiles[2].maxX <= tiles[0].minX && tiles[3].minX >= tiles[0].maxX)
    #expect(tiles[1].width > tiles[2].width)
    let wide = (0..<6).map { DisplayInfo(id: CGDirectDisplayID($0 + 1), name: "D\($0)", frame: CGRect(x: $0 * 1920, y: 0, width: 1920, height: 1080), main: $0 == 0) }
    #expect(DisplayInfo.arrangement(wide, width: 304, maxHeight: 140, minTile: CGSize(width: 64, height: 40)) == nil)
    #expect(DisplayInfo.selected(.display(3), main: 1) == 3)
    #expect(DisplayInfo.selected(.area(4, CGRect(x: 0, y: 0, width: 640, height: 480)), main: 1) == 4)
    #expect(DisplayInfo.selected(.window(9), main: 1) == nil)
    #expect(DisplayInfo.selected(nil, main: 1) == 1)
}

// #52: the Schermo row behaves like its sibling rows. Once a target is chosen it is closed and its line names it; the
// map of displays (with the window and the area) opens from the row's chevron and closes after a choice; with one
// display there is no map. So at the default window size, with «Schermo + volto», the face layout is in view. Real
// clicks on the whole window, the rig's capture giving 1 and 4 displays (no display is outlined on the screen), in
// Italian and French.
extension MouseSuites {
@Suite(.serialized) @MainActor struct ScreenRowMouseTests {
    @Test(arguments: ["it", "fr"], [1, 4])
    func theFaceLayoutIsInViewAndTheDisplaysOpenFromTheRow(_ language: String, _ count: Int) async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.capture.screen = true
        app.capture.displays = Array(DisplayInfo.samples.prefix(count))
        let table = MouseRig.table(language)
        func w(_ key: String) -> String { table.localizedString(forKey: key, value: key, table: nil) }
        app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: CGSize(width: 1440, height: 900), language: language)
        await app.settle()
        let tag = "\(language), \(count) display\(count == 1 ? "" : "s")"
        func control(_ name: String) -> RigElement? {
            app.rig.elements().first { $0.isControl && $0.visible && ($0.label == name || $0.title == name || $0.label.hasPrefix(name + ",")) }
        }
        func until(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        func screen() -> String { app.rig.elements().filter { $0.visible && !$0.name.isEmpty }.map(\.name).joined(separator: "; ") }
        let tileTip = w("Registra questo schermo; lo evidenzia per un attimo")
        var tiles: [RigElement] { app.rig.elements().filter { $0.isControl && $0.visible && $0.label == tileTip } }
        let rowName = w("Schermo")
        var row: RigElement? { app.rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix(rowName + ",") } }

        // «Schermo + volto»: screen, camera and microphone on, a display chosen.
        app.rig.click(try #require(control(w("Schermo + volto")), "\(tag): no «Schermo + volto»: \(screen())").centre)
        await app.settle()
        #expect(await until { app.recorder.sources.screen && app.recorder.sources.camera && app.recorder.sources.target != nil },
                "\(tag): the preset did not turn the screen and the camera on with a target")
        await app.settle()
        let main = try #require(DisplayInfo.samples.first)
        #expect(app.recorder.sources.target == .display(main.id), "\(tag): the target is \(String(describing: app.recorder.sources.target))")

        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("record-screen-face-\(language)-\(count).png"))
        }
        // Every tile of the face layout in view, without scrolling.
        for (_, key) in FaceLayoutControls.names {
            let tile = control(w(key))
            #expect(tile.map { $0.clip.insetBy(dx: -1, dy: -1).contains($0.frame) } == true,
                    "\(tag): «\(w(key))» is not in view: \(String(describing: tile?.frame)) in \(String(describing: tile?.clip))")
        }
        // The row is closed and names the display.
        #expect(tiles.isEmpty, "\(tag): the map of displays is open while a display is chosen")
        let line = "\(main.name) · 1512×982 · \(w("schermo principale"))".replacingOccurrences(of: " ", with: "\u{00A0}")
            .replacingOccurrences(of: "\u{00A0}·\u{00A0}", with: " · ")
        #expect(row?.label.contains(line) == true, "\(tag): the row does not name the display: \(row?.label ?? "no row")")

        // The chevron opens the row.
        app.rig.click(try #require(row, "\(tag): no Schermo row: \(screen())").centre)
        await app.settle()
        #expect(control(w("Scegli un'area…")) != nil, "\(tag): the row's choices did not open")
        if count == 1 {
            #expect(tiles.isEmpty, "\(tag): a map for one display")
            app.rig.click(try #require(row).centre)
            await app.settle()
            #expect(control(w("Scegli un'area…")) == nil, "\(tag): the chevron did not close the row")
            return
        }
        #expect(tiles.count == count, "\(tag): \(tiles.count) display tiles in the map")
        // A click on another display chooses it, once; the row closes and names it.
        var changes = 0
        let watch = app.recorder.$sources.map(\.target).removeDuplicates().dropFirst().sink { _ in changes += 1 }
        defer { watch.cancel() }
        let other = try #require(tiles.first { !$0.selected }, "\(tag): every tile reads as chosen")
        app.rig.click(other.centre)
        await app.settle()
        let target = app.recorder.sources.target
        let chosen = DisplayInfo.samples.first { ScreenTarget.display($0.id) == target }
        #expect(chosen != nil && chosen?.id != main.id && changes == 1, "\(tag): the target is \(String(describing: target)) after \(changes) changes")
        #expect(app.capture.log.contains("outline \(chosen?.id ?? 0)"), "\(tag): the chosen display was not outlined (stand-in)")
        #expect(await until { tiles.isEmpty }, "\(tag): the row did not close after the choice")
        #expect(row?.label.contains((chosen?.name ?? "?").replacingOccurrences(of: " ", with: "\u{00A0}")) == true && row?.label.contains(w("schermo principale")) == false,
                "\(tag): the row does not name the new display: \(row?.label ?? "no row")")
    }
}
}

// #54: a column that continues says so. At 1440×900 with «Schermo + volto» and a display whose line takes three lines,
// the bubble's Angolo / Misura / Forma rows are below the fold: the cue (a fade of the panel's colour above the fixed
// footer) is drawn; a control under it still answers a click; once the column is scrolled to its end the cue is gone.
extension MouseSuites {
@Suite(.serialized) @MainActor struct ContinuesCueMouseTests {
    @Test func registraSaysItsColumnContinues() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.capture.screen = true
        app.capture.displays = Array(DisplayInfo.samples.prefix(1))   // "Built-in Retina Display · 1512×982 · schermo principale"
        app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: CGSize(width: 1440, height: 900))
        await app.settle()
        func control(_ name: String) -> RigElement? {
            app.rig.elements().first { $0.isControl && $0.visible && ($0.label == name || $0.title == name || $0.label.hasPrefix(name + ",")) }
        }
        func text(_ name: String) -> RigElement? { app.rig.elements().first { $0.role == "AXStaticText" && $0.name == name } }
        func inView(_ e: RigElement?) -> Bool { e.map { $0.visible && $0.clip.insetBy(dx: -1, dy: -1).contains($0.frame) } ?? false }
        var cue: RigElement? { app.rig.elements().first { $0.name == "Altro sotto" && $0.visible } }
        func until(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        app.rig.click(try #require(control("Schermo + volto"), "no «Schermo + volto»").centre)
        await app.settle()
        #expect(await until { app.recorder.sources.screen && app.recorder.sources.camera && app.recorder.sources.target != nil })
        if app.recorder.sources.layout.kind != .bubble {
            app.rig.click(try #require(control("Bolla"), "no «Bolla» tile").centre)
            await app.settle()
        }
        #expect(app.recorder.sources.layout.kind == .bubble)
        await app.settle()
        // Rows below the fold, and the cue says so.
        #expect(!inView(text("Forma")), "«Forma» is in view: nothing to cue")
        #expect(await until { cue != nil }, "no cue while «Angolo» / «Misura» / «Forma» are below")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("record-continues-cue-it.png"))
        }
        let band = try #require(cue).frame
        #expect(band.height <= ContinuesCue.height + 1, "the cue is \(band.height) pt tall")

        // A control under the cue still answers: scroll until one of the bubble's choices lies under the fade, click it.
        let column = CGPoint(x: band.midX, y: band.minY - 60)
        let choices = ["S", "M", "L", "Cerchio", "Quadrato"]
        var under: RigElement?
        for _ in 0..<40 where under == nil {
            under = app.rig.elements().first { $0.isControl && $0.visible && choices.contains($0.name) && band.contains($0.centre) && !$0.selected }
            if under == nil { app.rig.scrollContent(at: column, by: 6); await app.settle() }
        }
        let target = try #require(under, "no choice of the bubble ever lay under the cue")
        #expect(cue != nil, "the cue went before the end of the column")
        let before = app.recorder.sources.layout
        var changes = 0
        let watch = app.recorder.$sources.map(\.layout).removeDuplicates().dropFirst().sink { _ in changes += 1 }
        defer { watch.cancel() }
        app.rig.click(target.centre)
        await app.settle()
        let after = app.recorder.sources.layout
        let expected = ["S", "M", "L"].contains(target.name) ? after.size == target.name : after.shape == (target.name == "Cerchio" ? "circle" : "rounded")
        #expect(expected && after != before && changes == 1, "a click on «\(target.name)» under the cue gave \(after) after \(changes) changes")

        // Scrolled to its end: every row in view, the cue gone.
        app.rig.scrollContent(at: column, by: 2000)
        await app.settle()
        #expect(inView(text("Forma")), "«Forma» is not in view at the end of the column")
        #expect(await until { cue == nil }, "the cue is still drawn at the end of the column")
        // With REGISTA_UI_SNAPSHOTS: the column's top in French, the cue drawn.
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("record-continues-end-it.png"))
            app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: CGSize(width: 1440, height: 900), language: "fr")
            await app.settle()
            try? app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("record-continues-cue-fr.png"))
        }
    }
}
}
