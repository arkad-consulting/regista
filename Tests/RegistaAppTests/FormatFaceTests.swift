import AppKit
@testable import RegistaCore
import RegistaEngines
import SwiftUI
import Testing
@testable import Regista

// The format everywhere, and the face always in frame (#150, #153): a take of another format joins a project, or a take
// becomes a project of a format chosen on Registra; its clip is framed on the face, never cut around the centre. The
// takes are synthetic 1920×1080 movies; the faces come from a stand-in tracker (a face right of centre, where a person
// sitting beside the camera usually is), so no test depends on what Vision sees in a drawing.

/// A face right of centre in a 1920×1080 take, for 6 s: what faces.track gets instead of Vision.
struct RightOfCentreFaces: FaceTracker {
    static let width = 1920, height = 1080

    func track(_ video: URL, options: FaceTrackOptions) throws -> FaceTrack {
        let frames = (0..<180).map { i -> FaceTrack.Frame in
            let box = [1330 + 20 * sin(Double(i) / 25), 330 + 6 * sin(Double(i) / 17), 230, 290.0]
            return FaceTrack.Frame(t: Double(i) / 30, raw: box, smooth: box)
        }
        return FaceTrack(video: video.path, engine: "stand-in", width: Self.width, height: Self.height, fps: 30,
                         minCutoff: options.minCutoff, beta: options.beta, cuts: [], frames: frames)
    }
}

/// A 6 s 1920×1080 camera take (a synthetic talking head, no sound), in a scratch folder.
func landscapeTake(_ name: String = "Registrazione 2026-11-22 \(UUID().uuidString.prefix(8)).mov") throws -> URL {
    let dir = rigTempDir("landscape-take")
    var head = SyntheticTalkingHead(frames: 180, output: dir.appendingPathComponent(name), matteDirectory: dir.appendingPathComponent("matte"))
    head.width = RightOfCentreFaces.width
    head.height = RightOfCentreFaces.height
    try CGScreenSynthesizer().writeTalkingHead(head)
    return head.output
}

/// A workbench on the rig's services with the face stand-in, without the engine socket.
@MainActor func faceBench(_ tag: String) -> Workbench {
    _ = NSApplication.shared
    _ = rigFolder
    return Workbench(defaults: TestDefaults.make(tag), seedFolders: [], socketPath: nil, services: {
        var s = RigServices.make(in: rigTempDir("face-services"))
        s.faces = RightOfCentreFaces()
        return s
    })
}

@MainActor func untilFramed(_ seconds: Double = 30, _ done: () -> Bool) async throws {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
}

/// The crop of the first clip of V1, and whether faces.checkFraming passes on the edit.
@MainActor func framing(_ tab: EditorStore) async throws -> (crop: [Double]?, pass: Bool) {
    let p = try #require(tab.project)
    let clip = try #require(p.tracks.first { $0.kind == .video }?.clips.first)
    let v = try #require(p.asset(clip.assetID)?.video)
    let check = try await tab.silent("faces.checkFraming", ["every": 1])
    return (clip.transform?.cropRect(sourceWidth: v.width, sourceHeight: v.height), check["pass"] == true)
}

@MainActor
@Test func aLandscapeTakeJoiningAVerticalProjectIsFramedOnTheFace() async throws {
    let b = faceBench("format-face-join")
    let tab = b.newTab()
    b.select(tab.tabID)
    try await tab.perform("project.new", ["name": "verticale", "directory": .string(rigTempDir("projects").path), "width": 1080, "height": 1920])
    tab.recordingChoice = .thisProject
    tab.importRecording(try landscapeTake(), session: false, newProject: false)
    try await untilFramed { b.notice != nil }
    let p = try #require(tab.project)
    #expect(p.settings.width == 1080 && p.settings.height == 1920, "the take changed the project's format")
    #expect(p.assets.first?.analysis?.faces != nil, "the faces were not tracked")
    let (crop, pass) = try await framing(tab)
    let c = try #require(crop, "the clip was not framed: it is cut around its centre")
    #expect(abs(c[0] / c[1] - 1080.0 / 1920) < 0.01 && c[2] > 900, "the crop is not on the face: \(c)")
    #expect(pass, "faces.checkFraming fails after the take joined")
    // The centred crop the take had before would cut the head (the bug).
    let centred = RenderJob.fit([1920, 1080, 0, 0], aspect: 1080.0 / 1920, within: (1920, 1080))
    let face = try RightOfCentreFaces().track(URL(fileURLWithPath: "/"), options: FaceTrackOptions()).frames[0].all
    #expect(!FaceFraming.cutHeads(face, crop: centred, frame: (1920, 1080), headroom: 0.02).isEmpty)
}

// #153: Registra chooses the video's format before recording.

@Test func theTakeFormatFollowsTheChoiceAndTheSources() {
    var s = RecordingSources()
    s.apply(.face)
    #expect(s.takeFormat == nil && s.formatChoice == RecordingSources.cameraFormat && s.guideAspect == nil)
    s.videoFormat = "9:16"
    #expect(s.takeFormat == "9:16" && s.formatChoice == "9:16" && abs((s.guideAspect ?? 0) - 1080.0 / 1920) < 1e-9)
    s.videoFormat = "16:9"
    #expect(s.guideAspect == nil, "the camera's own aspect needs no guide")
    s.videoFormat = nil
    s.apply(.screenFace)
    #expect(s.takeFormat == "16:9" && s.formatChoice == "16:9" && s.guideAspect == nil)
    s.videoFormat = "9:16"
    #expect(s.takeFormat == "9:16" && s.guideAspect == nil, "a screen session has no camera preview guide")
}

@MainActor
@Test func aNineSixteenChoiceGivesAVerticalProjectWithTheFaceInFrame() async throws {
    let b = faceBench("format-face-new")
    let tab = b.newTab()
    b.select(tab.tabID)
    tab.importRecording(try landscapeTake(), session: false, newProject: true, format: "9:16")
    try await untilFramed { b.notice != nil }
    let p = try #require(tab.project)
    #expect(p.settings.width == 1080 && p.settings.height == 1920, "the 9:16 choice gave \(p.settings.width)×\(p.settings.height)")
    let (crop, pass) = try await framing(tab)
    let c = try #require(crop, "the clip was not framed on the face")
    #expect(abs(c[0] / c[1] - 1080.0 / 1920) < 0.01 && c[2] > 900, "\(c)")
    #expect(pass, "faces.checkFraming fails on the 9:16 project")
    // «Come la camera»: the take's own format, nothing cropped.
    b.notice = nil
    let other = b.newTab()
    b.select(other.tabID)
    other.importRecording(try landscapeTake(), session: false, newProject: true, format: nil)
    try await untilFramed { b.notice != nil }
    let q = try #require(other.project)
    #expect(q.settings.width == 1920 && q.settings.height == 1080)
    #expect(q.tracks.first { $0.kind == .video }?.clips.first?.transform == nil)
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct RegistraFormatTests {
    private func menu(_ app: AppRig) -> RigElement? {
        let names = [loc("Come la camera"), "9:16", "16:9", "4:5", "1:1"]
        return app.rig.elements().first { $0.isControl && $0.visible && names.contains($0.value) && $0.frame.minX < 400 }
    }

    private func guide(_ app: AppRig, _ id: String) -> Bool {
        !app.rig.elements().filter { $0.label == String(format: loc("Cornice del video %@"), id) }.isEmpty
    }

    private func choose(_ app: AppRig, _ title: String) async throws {
        app.rig.takeKey()
        let m = try #require(menu(app), "no format menu on Registra")
        app.rig.click(m.centre)
        let pop = try #require(await openedPopover(app), "the menu did not open: \(m)")
        let row = try #require(pop.elements().first { $0.isControl && $0.visible && $0.name.hasPrefix(title) }, "no «\(title)»")
        pop.click(row.centre)
        await app.settle()
    }

    @Test func theVideoFormatIsChosenOnRegistraAndTheGuideShowsIt() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.recorder.sources.apply(.face)
        app.recorder.sources.videoFormat = nil
        app.hostEditor(Navigation(activity: .record, rightTab: .claude))
        await app.settle()
        #expect(menu(app)?.value == loc("Come la camera"), "\(String(describing: menu(app)))")
        #expect(!guide(app, "9:16"))
        // Its list: as the camera, then the four formats.
        let m = try #require(menu(app))
        app.rig.click(m.centre)
        let pop = try #require(await openedPopover(app), "no popover after a click on \(m)")
        #expect(pop.elements().filter { $0.isControl && $0.visible }.count == 5)
        // A second click on the label closes it, choosing nothing.
        app.rig.takeKey()
        app.rig.click(m.centre)
        _ = await app.until(3) { !pop.window.isVisible }
        app.rig.hold(0.4)
        #expect(app.recorder.sources.videoFormat == nil)
        try await choose(app, "9:16")
        #expect(app.recorder.sources.videoFormat == "9:16" && menu(app)?.value == "9:16")
        #expect(guide(app, "9:16"), "no guide frame on the camera preview")
        #expect(RecordingSources.load(from: app.defaults).videoFormat == "9:16", "the choice is not remembered")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            // The stand-in camera draws no picture: the renders show the camera's place (the face drawing) under the guide.
            for lang in ["it", "fr"] {
                let demo = RecordDemo(sources: app.recorder.sources, open: nil, grantPermissions: true)
                app.rig?.close()   // a rig in another language resets the words only when it closes
                app.hostEditor(Navigation(activity: .record, rightTab: .claude), language: lang) { AnyView($0.environment(\.recordDemo, demo)) }
                await app.settle()
                #expect(guide(app, "9:16"), "no guide in the \(lang) render")
                try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("registra-guide-\(lang).png"))
            }
            app.rig.close()
            app.hostEditor(Navigation(activity: .record, rightTab: .claude))
            await app.settle()
        }
        try await choose(app, loc("Come la camera"))
        #expect(app.recorder.sources.videoFormat == nil && !guide(app, "9:16"))
        // A screen session: 16:9 by default, no «as the camera».
        app.recorder.sources.apply(.screenFace)
        await app.settle()
        #expect(menu(app)?.value == "16:9")
        try await choose(app, "9:16")
        #expect(app.recorder.sources.takeFormat == "9:16")
        app.recorder.sources.videoFormat = nil
        app.recorder.sources.apply(.face)
    }
}
}
