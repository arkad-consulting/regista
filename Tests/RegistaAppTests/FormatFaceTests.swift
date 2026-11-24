import AppKit
import Combine
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

/// Waits for an import to land: up to 90 s, as the full suite runs it beside hundreds of other tests (30 s was not always
/// enough there for an import, a face track and project.format; alone it takes a few seconds).
@MainActor func untilFramed(_ seconds: Double = 90, _ done: () -> Bool) async throws {
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

/// #154: a landscape video imported into a vertical project (Media › Importa…, Inizio › Monta un video) goes on the
/// timeline framed on the face, in the placement's undo step: never cut around its centre.
@MainActor
@Test func aLandscapeVideoImportedIntoAVerticalProjectIsFramedOnTheFace() async throws {
    let b = faceBench("format-face-import")
    let tab = b.newTab()
    b.select(tab.tabID)
    try await tab.perform("project.new", ["name": "verticale", "directory": .string(rigTempDir("projects").path), "width": 1080, "height": 1920])
    let n = tab.activity.count
    tab.importMedia([try landscapeTake("intervista.mov")])
    try await untilFramed { tab.project?.tracks.first { $0.kind == .video }?.clips.first?.transform != nil || tab.activity.dropFirst(n).contains { $0.status == .failed } }
    let p = try #require(tab.project)
    #expect(p.settings.width == 1080 && p.settings.height == 1920, "the import changed the project's format")
    #expect(p.assets.first?.analysis?.faces != nil, "the faces were not tracked")
    let place = try #require(tab.activity.dropFirst(n).first { $0.command == "timeline.place" && $0.params.contains("frameOnFace") }, "no framed placement")
    #expect(place.result.contains(loc("inquadrata sul volto")), "the placement's line does not say it was framed: «\(place.result)»")
    #expect(!tab.activity.dropFirst(n).contains { $0.command == "project.format" }, "the framing took a step of its own")
    let (crop, pass) = try await framing(tab)
    let c = try #require(crop, "the clip was not framed: it is cut around its centre")
    #expect(abs(c[0] / c[1] - 1080.0 / 1920) < 0.01 && c[2] > 900, "the crop is not on the face: \(c)")
    #expect(pass, "faces.checkFraming fails after the import")
}

// #153: Registra chooses the video's format before recording.

@Test func theTakeFormatFollowsTheChoiceTheSourcesAndTheDestination() {
    var s = RecordingSources()
    s.apply(.face)
    var o = s.output(project: nil, forProject: nil)
    #expect(s.takeFormat == nil && o == TakeOutput(id: RecordingSources.cameraFormat, aspect: nil) && s.guideAspect(o) == nil)
    s.videoFormat = "9:16"
    o = s.output(project: nil, forProject: nil)
    #expect(s.takeFormat == "9:16" && o.id == "9:16" && abs((s.guideAspect(o) ?? 0) - 1080.0 / 1920) < 1e-9)
    s.videoFormat = "16:9"
    #expect(s.guideAspect(s.output(project: nil, forProject: nil)) == nil, "the camera's own aspect needs no guide")
    s.videoFormat = nil
    s.apply(.screenFace)
    o = s.output(project: nil, forProject: nil)
    #expect(s.takeFormat == "16:9" && o.id == "16:9" && s.guideAspect(o) == nil && abs(o.frameAspect - 16.0 / 9) < 1e-9)
    s.videoFormat = "9:16"
    o = s.output(project: nil, forProject: nil)
    // #160: with the screen the preview draws the composition in the format's frame (no camera guide).
    #expect(s.takeFormat == "9:16" && s.guideAspect(o) == nil && abs(o.frameAspect - 1080.0 / 1920) < 1e-9)
    // «Questo progetto»: the project's format, or the one chosen for it; the sources' choice does not count.
    o = s.output(project: (1920, 1080), forProject: nil)
    #expect(o.id == "16:9" && abs(o.frameAspect - 16.0 / 9) < 1e-9, "\(o)")
    o = s.output(project: (1920, 1080), forProject: "4:5")
    #expect(o.id == "4:5" && abs(o.frameAspect - 0.8) < 1e-9)
    o = s.output(project: (1280, 800), forProject: nil)
    #expect(o.id == "1280×800" && abs(o.frameAspect - 1.6) < 1e-9)
    #expect(RecordingSources.formatChoices(camera: true) == [RecordingSources.cameraFormat, "9:16", "16:9", "4:5", "1:1"])
    #expect(RecordingSources.formatChoices(camera: false) == ["9:16", "16:9", "4:5", "1:1"])
}

/// #160: the layouts a format lays out, with the rule project.format uses.
@Test func aPortraitFrameStacksTheFaceAndALandscapeOnePutsItBeside() {
    let split = LayoutSpec(kind: .split, side: "left"), stack = LayoutSpec(kind: .stack, side: "top")
    #expect(split.fitted(aspect: 1080.0 / 1920) == LayoutSpec(kind: .stack, side: "top"))
    #expect(stack.fitted(aspect: 16.0 / 9) == LayoutSpec(kind: .split, side: "left"))
    #expect(split.fitted(aspect: 1) == split && stack.fitted(aspect: 1) == stack, "a square frame keeps both")
    #expect(LayoutSpec(kind: .bubble).fitted(aspect: 0.8) == LayoutSpec(kind: .bubble))
    #expect(FaceLayoutControls.unavailable(aspect: 1080.0 / 1920).keys.sorted { $0.rawValue < $1.rawValue } == [.split])
    #expect(FaceLayoutControls.unavailable(aspect: 0.8).keys.sorted { $0.rawValue < $1.rawValue } == [.split])
    #expect(FaceLayoutControls.unavailable(aspect: 16.0 / 9).keys.sorted { $0.rawValue < $1.rawValue } == [.stack])
    #expect(FaceLayoutControls.unavailable(aspect: 1).isEmpty)
}

@MainActor
@Test func anotherFormatForThisProjectChangesItWhenTheTakeLands() async throws {
    let b = faceBench("format-this-project")
    let tab = b.newTab()
    b.select(tab.tabID)
    try await tab.perform("project.new", ["name": "orizzontale", "directory": .string(rigTempDir("projects").path), "width": 1920, "height": 1080])
    tab.recordingChoice = .thisProject
    tab.recordingFormat = "9:16"
    b.recordingStarted()
    b.recordingStopped()
    let undo = tab.undoNames.count
    b.recordingFinished(try landscapeTake(), session: false)
    try await untilFramed { b.notice != nil && tab.project?.settings.width == 1080 }
    let p = try #require(tab.project)
    #expect(p.settings.width == 1080 && p.settings.height == 1920, "the project stayed \(p.settings.width)×\(p.settings.height)")
    #expect(tab.recordingFormat == nil, "the choice outlived the take")
    let (crop, pass) = try await framing(tab)
    let c = try #require(crop, "the clip was not framed on the face")
    #expect(abs(c[0] / c[1] - 1080.0 / 1920) < 0.01 && c[2] > 900, "\(c)")
    #expect(pass, "faces.checkFraming fails after the project changed format")
    #expect(tab.undoNames.dropFirst(undo).filter { $0 == "project.format" }.count == 1,
            "the format change is not one undo step: \(tab.undoNames.dropFirst(undo))")
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
    /// The names of the format control's segments.
    private static let names = [loc("Come la camera"), "9:16", "16:9", "4:5", "1:1"]

    /// The format control's segment `name` (#160: on the bar above the preview, no longer in the side panel).
    private func segment(_ app: AppRig, _ name: String) -> RigElement? {
        app.rig.elements().first { $0.isControl && $0.visible && $0.name == name }
    }

    /// The segments shown, left to right.
    private func segments(_ app: AppRig) -> [RigElement] {
        app.rig.elements().filter { $0.isControl && $0.visible && Self.names.contains($0.name) }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// The frame of the take's format on the preview: the camera's guide, or the screen modes' composition.
    private func frame(_ app: AppRig, _ id: String) -> RigElement? {
        app.rig.elements().first { $0.label == String(format: loc("Cornice del video %@"), id) }
    }

    /// Clicks a segment; returns how many times the sources changed meanwhile.
    @discardableResult
    private func click(_ app: AppRig, _ name: String) async throws -> Int {
        app.rig.takeKey()
        let s = try #require(segment(app, name), "no «\(name)» on the format bar: \(segments(app).map(\.name))")
        var changes = 0
        let sink = app.recorder.$sources.dropFirst().sink { _ in changes += 1 }
        app.rig.click(s.centre)
        await app.settle()
        sink.cancel()
        #expect(segment(app, name) != nil, "«\(name)» went away after its click")
        return changes
    }

    /// Centred above the preview: the bar's middle at the preview's middle, its bottom above the preview's top.
    private func checkPlace(_ app: AppRig, preview: RigElement, sourceLocation: SourceLocation = #_sourceLocation) {
        let all = segments(app)
        guard let first = all.first, let last = all.last else { Issue.record("no format bar", sourceLocation: sourceLocation); return }
        let mid = (first.frame.minX + last.frame.maxX) / 2
        #expect(abs(mid - preview.frame.midX) < 3, "the bar is not centred over the preview: \(mid) vs \(preview.frame.midX)", sourceLocation: sourceLocation)
        #expect(first.frame.maxY <= preview.frame.minY + 1, "the bar is not above the preview: \(first.frame) / \(preview.frame)", sourceLocation: sourceLocation)
    }

    @Test func theFormatIsChosenAboveThePreviewAndTheGuideShowsIt() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.recorder.sources.apply(.face)
        app.recorder.sources.videoFormat = nil
        app.hostEditor(Navigation(activity: .record, rightTab: .claude))
        await app.settle()
        // As the camera (an icon, named by its tooltip), then the four formats; the chip of the side panel is gone.
        #expect(segments(app).map(\.name) == Self.names, "\(segments(app).map(\.name))")
        #expect(segment(app, loc("Come la camera"))?.selected == true)
        #expect(!app.rig.elements().contains { $0.role == "AXButton" && $0.value == "9:16" }, "the old format chip is still there")
        #expect(frame(app, "9:16") == nil)
        #expect(try await click(app, "9:16") == 1, "a click on 9:16 did not change the format once")
        #expect(app.recorder.sources.videoFormat == "9:16" && segment(app, "9:16")?.selected == true)
        let guide = try #require(frame(app, "9:16"), "no guide frame on the camera preview")
        checkPlace(app, preview: guide)
        #expect(RecordingSources.load(from: app.defaults).videoFormat == "9:16", "the choice is not remembered")
        // A second click on the chosen one changes nothing.
        #expect(try await click(app, "9:16") == 0)
        #expect(try await click(app, loc("Come la camera")) == 1)
        #expect(app.recorder.sources.videoFormat == nil && frame(app, "9:16") == nil)
        // Not shown while recording; the caption keeps naming the format.
        app.recorder.sources.videoFormat = "4:5"
        app.recorder.sources.prompter = false
        app.recorder.start()
        await app.settle()
        #expect(app.recorder.isRecording && segments(app).isEmpty, "the format bar is shown while recording: \(segments(app).map(\.name))")
        #expect(app.rig.elements().contains { $0.name == "4:5" && !$0.isControl }, "the caption does not say 4:5 while recording")
        app.recorder.stop()
        await app.settle()
        app.recorder.sources.videoFormat = nil
    }

    @Test func withTheScreenThePreviewIsTheCompositionOfTheFormat() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.capture.screen = true
        app.recorder.sources.apply(.screenFace)
        app.recorder.sources.videoFormat = nil
        app.recorder.sources.layout = LayoutSpec(kind: .split)
        app.hostEditor(Navigation(activity: .record, rightTab: .claude))
        await app.settle()
        // A screen session: no «as the camera», 16:9 chosen, the composition 16:9.
        #expect(segments(app).map(\.name) == ["9:16", "16:9", "4:5", "1:1"], "\(segments(app).map(\.name))")
        #expect(segment(app, "16:9")?.selected == true)
        let wide = try #require(frame(app, "16:9"), "no 16:9 frame on the preview")
        #expect(abs(wide.frame.width / wide.frame.height - 16.0 / 9) < 0.02, "\(wide.frame)")
        checkPlace(app, preview: wide)
        // At 16:9 the vertical stack does not apply: dimmed, a click on it changes nothing.
        let stack = try #require(app.rig.element(loc("Verticale")), "no «Verticale» tile")
        #expect(!stack.enabled, "«Verticale» is offered in a 16:9 frame")
        app.rig.click(stack.centre)
        await app.settle()
        #expect(app.recorder.sources.layout.kind == .split, "the click on a disabled tile changed the layout")
        // 9:16: the frame is portrait, side by side becomes the vertical stack (as the import lays it out), the face under
        // the screen across the whole width.
        #expect(try await click(app, "9:16") >= 1)
        #expect(app.recorder.sources.takeFormat == "9:16")
        let tall = try #require(frame(app, "9:16"), "no 9:16 frame on the preview")
        #expect(abs(tall.frame.width / tall.frame.height - 1080.0 / 1920) < 0.02, "\(tall.frame)")
        checkPlace(app, preview: tall)
        #expect(app.recorder.sources.layout.kind == .stack, "side by side stayed in a portrait frame: \(app.recorder.sources.layout.label)")
        let face = try #require(app.rig.elements().first { $0.label == loc("Volto nel video") && tall.frame.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) },
                                "no face on the preview")
        #expect(face.frame.minY >= tall.frame.midY - 2 && abs(face.frame.width - tall.frame.width) < 3, "the face is not under the screen: \(face.frame) in \(tall.frame)")
        #expect(app.rig.element(loc("Affiancati"))?.enabled == false && app.rig.element(loc("Verticale"))?.enabled == true)
        #expect(app.rig.element(loc("Verticale"))?.selected == true, "the stack is not the chosen tile")
        // A layout that applies stays chosen: the bubble, from 9:16 to 1:1 and back to 16:9.
        app.rig.click(try #require(app.rig.element(loc("Bolla"))).centre)
        await app.settle()
        try await click(app, "1:1")
        #expect(app.recorder.sources.layout.kind == .bubble && app.rig.element(loc("Bolla"))?.selected == true)
        try await click(app, "16:9")
        #expect(app.recorder.sources.videoFormat == nil && app.recorder.sources.layout.kind == .bubble)
        app.recorder.sources.apply(.face)
        app.recorder.sources.layout = LayoutSpec(kind: .bubble)
    }

    @Test func questoProgettoShowsTheProjectsFormatAndSaysWhenItChanges() async throws {
        let app = try await AppRig(project: "empty")
        defer { app.close() }
        let p = try #require(app.store.project)
        let own = try #require(ScreenLook.formatID(p))
        let other = own == "16:9" ? "9:16" : "16:9"
        app.recorder.sources.apply(.face)
        app.recorder.sources.videoFormat = nil
        app.hostEditor(Navigation(activity: .record, rightTab: .claude))
        await app.settle()
        #expect(app.store.recordingDestination == .thisProject)
        // The project's format, chosen; no «as the camera»: the take joins a project of a given format.
        #expect(segments(app).map(\.name) == ["9:16", "16:9", "4:5", "1:1"], "\(segments(app).map(\.name))")
        #expect(segment(app, own)?.selected == true, "the project's \(own) is not the chosen format")
        let note = String(format: loc("Il progetto passa a %@ quando aggiungi la ripresa"), other)
        #expect(app.rig.element(note) == nil)
        #expect(try await click(app, other) == 0, "a choice for this project changed the sources")
        #expect(app.store.recordingFormat == other && segment(app, other)?.selected == true)
        #expect(app.rig.element(note) != nil, "no line says the project changes: \(app.rig.elements().map(\.name).filter { !$0.isEmpty }.suffix(12))")
        #expect(app.recorder.sources.videoFormat == nil, "the new project's choice changed")
        // Its own format again: nothing to change, the line goes.
        try await click(app, own)
        #expect(app.store.recordingFormat == nil && app.rig.element(note) == nil)
        // «Nuovo progetto»: the sources' choice again (as the camera).
        app.store.recordingChoice = .newProject
        await app.settle()
        #expect(segment(app, loc("Come la camera"))?.selected == true)
        app.store.recordingChoice = nil
    }

    /// The snapshots of #160, at the default window size and the minimum one, in every state of the side column: a tab
    /// without a project (the camera alone in 9:16, screen + face in 9:16 and 16:9) and a tab with one («Nuovo progetto»,
    /// «Questo progetto» with and without the line about another format, the camera alone joining it). #52 / #163: at the
    /// default size every face-layout tile is whole inside the column's scroll area and clear of its fade, in it / en / fr
    /// / pt; at the minimum size the column may scroll, but no tile shows under the footer and a tile cut at the edge comes
    /// with the cue that the column continues. Snapshots in Italian and French.
    @Test func snapshotsOfTheFormatOnTop() async throws {
        let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        struct State {
            let name: String; let preset: RecordingSources.Preset; let format: String?; let project: Bool
            var destination: RecordingDestination? = nil; var otherFormat = false
        }
        let states = [State(name: "camera-9x16", preset: .face, format: "9:16", project: false),
                      State(name: "screen-face-9x16", preset: .screenFace, format: "9:16", project: false),
                      State(name: "screen-face-16x9", preset: .screenFace, format: nil, project: false),
                      State(name: "new-project", preset: .screenFace, format: nil, project: true, destination: .newProject),
                      State(name: "this-project", preset: .screenFace, format: nil, project: true, destination: .thisProject),
                      State(name: "this-project-other", preset: .screenFace, format: nil, project: true, destination: .thisProject, otherFormat: true),
                      State(name: "camera-this-project-other", preset: .face, format: nil, project: true, destination: .thisProject, otherFormat: true)]
        for state in states {
            let app = try await AppRig(project: state.project ? "empty" : nil)
            defer { app.close() }
            app.capture.screen = true
            var sources = app.recorder.sources
            sources.apply(state.preset)
            sources.videoFormat = state.format
            sources.layout = LayoutSpec(kind: .bubble)
            app.recorder.sources = sources
            if let d = state.destination { app.store.recordingChoice = d }
            if state.otherFormat, let p = app.store.project {
                app.store.recordingFormat = ScreenLook.formatID(p) == "16:9" ? "9:16" : "16:9"
            }
            for size in [CGSize(width: 1440, height: 900), CGSize(width: 1024, height: 640)] {
                for lang in ["it", "en", "fr", "pt"] {
                    let demo = RecordDemo(sources: sources, open: nil, grantPermissions: true)
                    app.rig?.close()
                    app.hostEditor(Navigation(activity: .record, rightTab: .claude), size: size, language: lang) { AnyView($0.environment(\.recordDemo, demo)) }
                    await app.settle()
                    await app.idle(0.2)
                    let tag = "\(state.name) \(lang) \(Int(size.width))"
                    #expect(segments(app).count >= 4, "\(tag): no format bar")
                    if state.destination != nil {
                        let note = String(format: loc("Il progetto passa a %@ quando aggiungi la ripresa"), app.store.recordingFormat ?? "?")
                        #expect((app.rig.element(note) != nil) == state.otherFormat, "\(tag): the line about the format is \(state.otherFormat ? "missing" : "shown")")
                    }
                    if let dir, lang == "it" || lang == "fr" {
                        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try app.snapshot(to: dir.appendingPathComponent("registra-\(state.name)-\(Int(size.width))-\(lang).png"))
                    }
                    await checkTiles(app, state.preset == .screenFace, atDefault: size.width == 1440, tag)
                }
            }
        }
    }

    /// The face-layout tiles against the side column's scroll area and its footer (its first line: the automatic edit's
    /// switch, else the destination, else the Record button). `atDefault` (the default window size): every tile inside the
    /// area and above the fade the area draws while it continues below. Otherwise (the minimum size): while a tile is not
    /// whole in view the cue says the column continues; scrolled to its end, every tile is whole in view, above the footer.
    private func checkTiles(_ app: AppRig, _ shown: Bool, atDefault: Bool, _ tag: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        func look() -> (footer: RigElement?, section: RigElement?, tiles: [RigElement], cue: Bool) {
            // The side column's elements (the right panel's history may name «Nuovo progetto» too).
            let all = app.rig.elements().filter { $0.frame.minX < Chrome.activityWidth + Chrome.sideDefault }
            let firsts = ["Montaggio automatico a fine registrazione", "Nuovo progetto", "Questo progetto", "Diventa un nuovo progetto in questa scheda",
                          "Avvia / Ferma registrazione"].map { loc($0) }
            let footer = all.filter { e in e.visible && firsts.contains { e.label.hasPrefix($0) || e.title == $0 } }.min { $0.frame.minY < $1.frame.minY }
            // The tiles, clipped ones too: under the section's title («Solo schermo» is a preset above as well). A lazy grid
            // far out of view may not lay them out at all.
            let section = all.first { $0.name.caseInsensitiveCompare(loc("Volto nel video")) == .orderedSame }
            let tiles = section.map { section in
                FaceLayoutControls.names.compactMap { _, key in all.first { $0.isControl && $0.name == loc(key) && $0.frame.minY > section.frame.maxY } }
            } ?? []
            return (footer, section, tiles, all.contains { $0.name == loc("Altro sotto") && $0.visible })
        }
        func inView(_ t: RigElement, _ footer: RigElement, margin: Double) -> Bool {
            t.clip.contains(t.frame) && t.clip.maxY - t.frame.maxY >= margin && t.frame.maxY <= footer.frame.minY
        }
        let seen = look()
        guard let footer = seen.footer else { Issue.record("\(tag): no footer", sourceLocation: sourceLocation); return }
        guard shown else {
            #expect(seen.tiles.isEmpty, "\(tag): face-layout tiles with the camera alone", sourceLocation: sourceLocation)
            return
        }
        guard let section = seen.section else { Issue.record("\(tag): no «Volto nel video» section", sourceLocation: sourceLocation); return }
        for tile in seen.tiles {
            FileHandle.standardError.write(Data("tiles \(tag) «\(tile.name)»: bottom \(Int(tile.frame.maxY)), area ends \(Int(tile.clip.maxY)), footer at \(Int(footer.frame.minY)), room \(Int(tile.clip.maxY - tile.frame.maxY))\n".utf8))
            // Whatever shows of a tile is above the footer.
            #expect(min(tile.frame.maxY, tile.clip.maxY) <= footer.frame.minY, "\(tag): «\(tile.name)» shows under the footer: \(tile.frame), footer at \(footer.frame.minY)",
                    sourceLocation: sourceLocation)
        }
        let whole = seen.tiles.count == FaceLayoutControls.names.count && seen.tiles.allSatisfy { inView($0, footer, margin: ContinuesCue.height) }
        if atDefault || whole {
            #expect(whole, "\(tag): the tiles are not whole in view: \(seen.tiles.map { "\($0.name) \($0.frame) in \($0.clip)" })", sourceLocation: sourceLocation)
            return
        }
        // The cue comes with the scroll area's first geometry: give the accessibility tree a moment, as #54 does.
        var cue = seen.cue
        for _ in 0..<40 where !cue {
            await app.idle(0.1)
            cue = look().cue
        }
        #expect(cue, "\(tag): tiles out of view and nothing says the column continues", sourceLocation: sourceLocation)
        // Scrolled to its end: every tile whole in view, above the footer.
        _ = app.rig.scrollContent(at: CGPoint(x: section.clip.midX, y: section.clip.midY), by: 2000)
        await app.settle()
        let end = look()
        #expect(end.tiles.count == FaceLayoutControls.names.count && end.tiles.allSatisfy { inView($0, footer, margin: 0) },
                "\(tag): scrolled to the end, the tiles are not whole above the footer: \(end.tiles.map { "\($0.name) \($0.frame) in \($0.clip)" })",
                sourceLocation: sourceLocation)
    }
}
}
