import Foundation
@testable import RegistaCore
import Testing
@testable import Regista

// R2 #51 (#42 #43 #44), #79: the inspector's Schermo controls map to the right command parameters, each change is one
// undo step that undo takes back, and a clip with linked sound fades picture and sound in one command.

/// ffprobe's answers for a session folder: a 1920×1080 screen, a 1080×1920 camera, a mono mic.
private struct Prober: MediaProber {
    func probe(_ url: URL) throws -> ProbedMedia {
        switch url.lastPathComponent {
        case "screen.mov": ProbedMedia(duration: MediaTime(seconds: 12), video: VideoInfo(width: 1920, height: 1080, frameRate: Rational(60), codec: "h264"))
        case "camera.mov": ProbedMedia(duration: MediaTime(seconds: 11.75), video: VideoInfo(width: 1080, height: 1920, frameRate: Rational(30), codec: "h264"))
        default: ProbedMedia(duration: MediaTime(seconds: 11.8), audio: AudioInfo(sampleRate: 48000, channels: 1, codec: "pcm_s16le"))
        }
    }
}

/// A session folder (empty media files, a session.json with three clicks, one key and the cursor path), imported into
/// a 16:9 project. `cursorInVideo` false: the compositor draws the cursor.
private func engine(keys: Bool = true) throws -> Engine {
    let dir = TemporaryFolder.url.appendingPathComponent("regista-screenlook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let sources = [RecordingSession.Source(id: "screen", file: "screen.mov", offset: 0), RecordingSession.Source(id: "camera", file: "camera.mov", offset: 0.25),
                   RecordingSession.Source(id: "mic", file: "mic.wav", offset: 0.18)]
    for s in sources { FileManager.default.createFile(atPath: dir.appendingPathComponent(s.file).path, contents: Data()) }
    var s = RecordingSession(app: "test", created: "2026-11-12T10:00:00Z", duration: 12, sources: sources)
    s.events = [RecordingSession.Event(kind: "click", t: 2.6, x: 300, y: 240), RecordingSession.Event(kind: "click", t: 4.0, x: 600, y: 450),
                RecordingSession.Event(kind: "click", t: 9.2, x: 1380, y: 760)]
    if keys { s.events.append(RecordingSession.Event(kind: "key", t: 5, key: "cmd+s")) }
    s.cursor = stride(from: 0.0, through: 12, by: 1.0 / 30).map { RecordingSession.CursorSample(t: $0, x: 200 + 100 * $0, y: 540) }
    s.cursorInVideo = false
    try s.write(to: dir.appendingPathComponent(RecordingSession.fileName))
    let e = Engine(prober: Prober())
    try e.execute("project.new", params: ["name": "schermo", "width": 1920, "height": 1080])
    try e.execute("recording.import", params: ["path": .string(dir.path)])
    return e
}

private func whole(_ e: Engine) throws -> ScreenLookTarget {
    try #require(ScreenLook.target(InspectorTarget.resolve(InspectorSelection(), in: e.project), in: e.project!))
}

/// Runs a command, checks it is one undo step and that undo restores the project, then redoes it.
private func runOnce(_ cmd: InspectorCommand, on e: Engine, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let before = e.project, n = e.context.history.undoStack.count
    try e.execute(cmd.id, params: cmd.params)
    #expect(e.context.history.undoStack.count == n + 1, "\(cmd.id) \(cmd.params)", sourceLocation: sourceLocation)
    let after = e.project
    try e.execute("history.undo")
    #expect(e.project == before, "undo of \(cmd.id)", sourceLocation: sourceLocation)
    try e.execute("history.redo")
    #expect(e.project == after, sourceLocation: sourceLocation)
}

@Test func theSchermoSectionShowsForAScreenRecordingOnly() throws {
    let e = try engine()
    let p = try #require(e.project)
    #expect(InspectorTarget.resolve(InspectorSelection(), in: p).sections(in: p) == [.project, .screen])
    let screenClip = p.tracks[0].clips[0].id
    let clip = InspectorTarget.resolve(InspectorSelection(clips: [screenClip]), in: p)
    #expect(clip.sections(in: p) == [.timing, .screen, .transform, .crop, .color, .speed, .fades])
    // The whole recording, its layout and its id.
    let t = try whole(e)
    #expect(t.from == nil && t.to == nil && t.layout.kind == .bubble && t.hasCamera && t.cursorDrawn && t.layoutCount == 1)
    // A clip of part of the recording edits only its range.
    try e.execute("timeline.cut", params: ["at": 5])
    let part = try #require(ScreenLook.target(InspectorTarget.resolve(InspectorSelection(clips: [e.project!.tracks[0].clips[1].id]), in: e.project), in: e.project!))
    #expect(part.from?.seconds == 5 && part.to != nil)
    #expect(ScreenLook.layout(LayoutSpec(kind: .face), part).params["from"] == 5)
    // A project without recordings has no Schermo section.
    let plain = Engine(prober: Prober())
    try plain.execute("project.new", params: ["name": "x"])
    #expect(InspectorTarget.resolve(InspectorSelection(), in: plain.project).sections(in: plain.project) == [.project])
}

@Test func faceLayoutAndFrameControlsMapToLayoutApply() throws {
    let e = try engine()
    let t = try whole(e)
    let r = JSONValue.string(t.link.id)
    #expect(ScreenLook.layout(LayoutSpec(kind: .split, side: "left"), t)
            == InspectorCommand(id: "layout.apply", params: ["preset": "split", "side": "left", "recordingId": r]))
    #expect(ScreenLook.layout(LayoutSpec(kind: .bubble, corner: "topLeft", shape: "rounded", size: "L"), t)
            == InspectorCommand(id: "layout.apply", params: ["preset": "bubble", "corner": "topLeft", "shape": "rounded", "size": "L", "frame": false, "recordingId": r]))
    // Options that do not belong to the layout are dropped: a frame on the face layout, a top corner on the cut-out, a split side on the stack.
    #expect(ScreenLook.layout(LayoutSpec(kind: .face, frame: ScreenFrame()), t) == InspectorCommand(id: "layout.apply", params: ["preset": "face", "recordingId": r]))
    #expect(ScreenLook.layout(LayoutSpec(kind: .cutout, corner: "topLeft"), t).params["corner"] == "bottomRight")
    #expect(ScreenLook.layout(LayoutSpec(kind: .stack, side: "left"), t).params["side"] == nil)
    // The frame: on, a background, padding / radius / shadow — every call carries the whole frame.
    #expect(ScreenLook.framed(true, t) == InspectorCommand(id: "layout.apply", params: ["preset": "bubble", "corner": "bottomRight", "shape": "circle", "size": "M",
                                                                                      "frame": true, "recordingId": r]))
    try runOnce(ScreenLook.framed(true, t), on: e)
    var f = try whole(e)
    #expect(f.layout.frame != nil && ScreenLook.background(f.layout.frame) == .brand)
    #expect(ScreenLook.background(.preset("dusk"), f).params["background"] == "dusk")
    try runOnce(ScreenLook.background(.preset("dusk"), f), on: e)
    f = try whole(e)
    #expect(ScreenLook.background(f.layout.frame) == .preset("dusk") && e.project!.settings.backdrop?.preset == "dusk")
    let pad = ScreenLook.frame(.padding, 0.1, f)
    #expect(pad.params["padding"] == 0.1 && pad.params["background"] == "dusk" && pad.params["frame"] == true)
    try runOnce(pad, on: e)
    try runOnce(ScreenLook.frame(.shadow, 0.2, try whole(e)), on: e)
    f = try whole(e)
    #expect(f.layout.frame?.padding == 0.1 && f.layout.frame?.shadow == 0.2 && f.layout.frame?.background?.preset == "dusk")
    #expect(ScreenLook.background(.color("#112233"), f).params["background"] == "#112233")
    try runOnce(ScreenLook.layout(LayoutSpec(kind: .split, side: "left"), f), on: e)
    #expect(try whole(e).layout == LayoutSpec(kind: .split, side: "left"))
}

@Test func cursorKeysZoomAndFormatControlsMapToTheirCommands() throws {
    let e = try engine()
    let t = try whole(e)
    let r = JSONValue.string(t.link.id)
    #expect(ScreenLook.cursor("scale", 2.5, t) == InspectorCommand(id: "cursor.style", params: ["scale": 2.5, "recordingId": r]))
    for (k, v) in [("scale", JSONValue.number(2.5)), ("smoothing", 0.9), ("visible", false), ("hideWhenIdle", false), ("clickRipple", false)] {
        try runOnce(ScreenLook.cursor(k, v, try whole(e)), on: e)
    }
    #expect(try whole(e).cursor.scale == 2.5 && !(try whole(e).cursor.clickRipple))

    let p = e.project!
    var keys = ScreenLook.keysState(t, in: p)
    #expect(!keys.on && keys.position == "bottom" && !keys.allKeys)
    keys.on = true
    #expect(ScreenLook.keys(keys, t) == InspectorCommand(id: "keys.overlay", params: ["allKeys": false, "position": "bottom", "recordingId": r]))
    try runOnce(ScreenLook.keys(keys, t), on: e)
    var now = try whole(e)
    keys = ScreenLook.keysState(now, in: e.project!)
    #expect(keys.on)
    keys.position = "top"; keys.allKeys = true
    try runOnce(ScreenLook.keys(keys, now), on: e)
    now = try whole(e)
    #expect(ScreenLook.keysState(now, in: e.project!) == ScreenLook.KeysState(on: true, allKeys: true, position: "top"))
    keys.on = false
    #expect(ScreenLook.keys(keys, now) == InspectorCommand(id: "keys.overlay", params: ["clear": true, "recordingId": r]))
    try runOnce(ScreenLook.keys(keys, now), on: e)

    var zoom = ScreenLook.zoomState(try whole(e), in: e.project!)
    #expect(!zoom.on && zoom.zoom == 1.8 && !zoom.follow)
    zoom.on = true; zoom.zoom = 2.2; zoom.follow = true
    #expect(ScreenLook.zoom(zoom, t) == InspectorCommand(id: "edit.autoZoom", params: ["zoom": 2.2, "follow": true, "recordingId": r]))
    try runOnce(ScreenLook.zoom(zoom, try whole(e)), on: e)
    #expect(ScreenLook.zoomState(try whole(e), in: e.project!) == ScreenLook.ZoomState(on: true, zoom: 2.2, follow: true))
    // A new intensity is a re-run with the kept options.
    zoom.zoom = 1.5
    try runOnce(ScreenLook.zoom(zoom, try whole(e)), on: e)
    zoom.on = false
    #expect(ScreenLook.zoom(zoom, t) == InspectorCommand(id: "edit.autoZoom", params: ["clear": true, "recordingId": r]))
    try runOnce(ScreenLook.zoom(zoom, try whole(e)), on: e)

    #expect(ScreenLook.formatID(e.project!) == "16:9")
    #expect(ScreenLook.format("4:5") == InspectorCommand(id: "project.format", params: ["preset": "4:5"]))
    try runOnce(ScreenLook.format("4:5"), on: e)
    #expect(ScreenLook.formatID(e.project!) == "4:5")
}

@MainActor
@Test func theSessionSaysWhatTheTakeLogged() throws {
    let with = try whole(try engine()), without = try whole(try engine(keys: false))
    #expect(ScreenLook.sessionInfo(with.link) == ScreenSessionInfo(clicks: 3, keys: 1, readable: true))
    #expect(ScreenLook.sessionInfo(without.link).keys == 0)
    var gone = with.link
    gone.session = "/nonexistent/session.json"
    #expect(!ScreenLook.sessionInfo(gone).readable)
}

@Test func linkedFadesSetPictureAndSoundInOneStep() throws {
    let e = try engine()
    let p = e.project!
    // The camera clip and its linked mic.
    let cam = p.tracks.first { $0.role == "camera" }!.clips[0]
    let target = InspectorTarget.resolve(InspectorSelection(clips: [cam.id]), in: p)
    let mic = InspectorEdits.linkedAudio(of: cam, in: p).map(\.id)
    #expect(!mic.isEmpty)
    let cmd = try #require(InspectorEdits.linkedFade(in: true, 0.5, target, in: p))
    #expect(cmd == InspectorCommand(id: "clip.set", params: ["clipIds": .array(([cam.id] + mic).map { .string($0) }), "pictureFadeIn": 0.5, "fadeIn": 0.5]))
    try runOnce(cmd, on: e)
    let q = e.project!
    #expect(q.tracks.first { $0.role == "camera" }!.clips[0].pictureFadeIn?.seconds == 0.5)
    #expect(q.tracks.first { $0.role == "mic" }!.clips[0].fadeIn?.seconds == 0.5)
    // Apart: the picture alone.
    #expect(InspectorEdits.command(.pictureFadeOut, 0.4, target, in: q) == InspectorCommand(id: "clip.set", params: ["clipIds": [.string(cam.id)], "pictureFadeOut": 0.4]))
}
