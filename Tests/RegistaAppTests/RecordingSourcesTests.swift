import CoreGraphics
import Foundation
import RegistaCore
import Testing
@testable import Regista

// R1 (#50): the Registra screen's sources as a pure value — presets ↔ switches, the at-least-one rule, device memory,
// persistence and the screen fallback.

private func scratchDefaults() -> UserDefaults {
    let name = "regista-sources-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

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
