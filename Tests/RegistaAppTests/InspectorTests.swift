import AppKit
import Foundation
@testable import RegistaCore
import Testing
@testable import Regista

// E1 #53: the clip inspector's fields run the right commands, a slider drag and a multi-selection edit are one undo
// step each, the context menu's actions are commands, and media dropped on the timeline lands where it should.

/// ffprobe's answers without ffprobe: a 1080×1920 video with stereo sound, a 800×600 PNG.
private struct Prober: MediaProber {
    func probe(_ url: URL) throws -> ProbedMedia {
        if url.pathExtension == "png" {
            return ProbedMedia(duration: ImageSource.stillDuration, video: VideoInfo(width: 800, height: 600, frameRate: Rational(25), codec: "png"))
        }
        return ProbedMedia(duration: MediaTime(seconds: 20), video: VideoInfo(width: 1080, height: 1920, frameRate: Rational(30), codec: "h264"),
                           audio: AudioInfo(sampleRate: 48000, channels: 2, codec: "aac"))
    }
}

private func file(_ name: String) -> String {
    let dir = TemporaryFolder.url.appendingPathComponent("regista-inspector-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data())
    return url.path
}

/// V1 (t1): c1 0–4 s, c3 4–8 s; A1 (t2): c2 0–4 s linked to c1; a title on its own track.
private func engine() throws -> (Engine, title: String) {
    let e = Engine(prober: Prober())
    try e.execute("project.new", params: ["name": "inspector"])
    try e.execute("media.import", params: ["path": .string(file("take.mov"))])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 4])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceOut": 4, "linkTo": "c1"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 4, "sourceOut": 8])
    let title = try e.execute("title.add", params: ["text": "Ciao", "start": 1]).value(at: "clip.id")?.stringValue ?? ""
    return (e, title)
}

private func target(_ ids: Set<String>, _ e: Engine) -> InspectorTarget { InspectorTarget.resolve(InspectorSelection(clips: ids), in: e.project) }

private func run(_ cmd: InspectorCommand?, on e: Engine) throws {
    let c = try #require(cmd)
    try e.execute(c.id, params: c.params)
}

@Test func inspectorFieldsMapToTheirCommands() throws {
    let (e, title) = try engine()
    let p = try #require(e.project)
    let video = target(["c1"], e), audio = target(["c2"], e), text = target([title], e)
    #expect(video.kind == .video && audio.kind == .audio && text.kind == .title)
    #expect(video.sections(in: p) == [.timing, .transform, .crop, .color, .speed, .fades])

    func cmd(_ f: InspectorField, _ v: Double, _ t: InspectorTarget) -> InspectorCommand? { InspectorEdits.command(f, v, t, in: p) }
    #expect(cmd(.opacity, 0.5, video) == InspectorCommand(id: "clip.set", params: ["clipIds": ["c1"], "opacity": 0.5]))
    #expect(cmd(.x, 108, video) == InspectorCommand(id: "clip.set", params: ["clipIds": ["c1"], "x": 0.1]))
    #expect(cmd(.scale, 1.2, video) == InspectorCommand(id: "clip.set", params: ["clipIds": ["c1"], "scale": 1.2]))
    #expect(cmd(.brightness, 0.05, video) == InspectorCommand(id: "clip.set", params: ["clipIds": ["c1"], "brightness": 0.05]))
    #expect(cmd(.cropLeft, 0.1, video) == InspectorCommand(id: "clip.set", params: ["clipId": "c1", "crop": [972, 1920, 108, 0]]))
    #expect(cmd(.start, 10, video) == InspectorCommand(id: "timeline.move", params: ["clipId": "c1", "start": 10]))
    #expect(cmd(.end, 3, video) == InspectorCommand(id: "timeline.trim", params: ["clipId": "c1", "edge": "end", "to": 3]))
    #expect(cmd(.duration, 2.5, video) == InspectorCommand(id: "timeline.trim", params: ["clipId": "c1", "edge": "end", "to": 2.5]))
    #expect(cmd(.speed, 2, video) == InspectorCommand(id: "clip.speed", params: ["clipId": "c1", "rate": 2]))
    // A picture clip's fades are its sound's.
    #expect(cmd(.fadeIn, 0.3, video) == InspectorCommand(id: "clip.set", params: ["clipIds": ["c2"], "fadeIn": 0.3]))
    #expect(cmd(.gain, -6, audio) == InspectorCommand(id: "clip.set", params: ["clipIds": ["c2"], "gain": -6]))
    // A title sits where it was placed: position, size and rotation go through clip.place, in frame pixels.
    #expect(cmd(.x, 300, text) == InspectorCommand(id: "clip.place", params: ["clipId": .string(title), "x": 300]))
    #expect(cmd(.rotation, 10, text) == InspectorCommand(id: "clip.place", params: ["clipId": .string(title), "rotation": 10]))
    #expect(cmd(.opacity, 0.8, text) == InspectorCommand(id: "clip.set", params: ["clipIds": [.string(title)], "opacity": 0.8]))

    // Each of them runs and is one undo step.
    for (f, v, t) in [(InspectorField.opacity, 0.5, video), (.x, 108, video), (.cropLeft, 0.1, video), (.speed, 2, video),
                      (.fadeIn, 0.3, video), (.gain, -6, audio), (.x, 300, text), (.rotation, 10, text)] {
        let fresh = InspectorTarget.resolve(InspectorSelection(clips: Set(t.clipIDs)), in: e.project)
        let n = e.context.history.undoStack.count
        try run(InspectorEdits.command(f, v, fresh, in: e.project!), on: e)
        #expect(e.context.history.undoStack.count == n + 1, "\(f)")
        let now = InspectorTarget.resolve(InspectorSelection(clips: Set(t.clipIDs)), in: e.project)
        if f != .fadeIn { #expect(abs(InspectorEdits.value(f, now.items[0], in: e.project!) - v) < 0.01, "\(f)") }
    }
    #expect(e.project?.tracks[1].clips[0].fadeIn?.seconds == 0.3)
}

@Test func aSliderDragIsOneUndoStep() throws {
    let (e, _) = try engine()
    let before = e.project
    var drafts = InspectorDrafts()
    let t = target(["c1"], e)
    for k in 0..<30 { drafts.drag(.opacity, 1 - Double(k) / 60) }   // the drag: nothing runs
    #expect(e.project == before)
    #expect(drafts.value(.opacity, else: 1) == 1 - 29.0 / 60)
    let n = e.context.history.undoStack.count
    try run(InspectorEdits.command(.opacity, try #require(drafts.release(.opacity)), t, in: e.project!), on: e)
    #expect(e.context.history.undoStack.count == n + 1)
    try e.execute("history.undo")
    #expect(e.project == before)
    drafts.clear()
    #expect(drafts.value(.opacity, else: 1) == 1)
}

@Test func aMultiSelectionEditIsOneUndoStep() throws {
    let (e, _) = try engine()
    let before = e.project
    let t = target(["c1", "c3"], e)
    #expect(t.kind == .multi)
    #expect(t.sections(in: e.project) == [.multi, .opacity, .color])
    let cmd = try #require(InspectorEdits.command(.saturation, 1.3, t, in: e.project!))
    #expect(cmd == InspectorCommand(id: "clip.set", params: ["clipIds": ["c1", "c3"], "saturation": 1.3]))
    let n = e.context.history.undoStack.count
    try e.execute(cmd.id, params: cmd.params)
    #expect(e.context.history.undoStack.count == n + 1)
    #expect(e.clips(0).allSatisfy { $0.color?.saturation == 1.3 })
    try e.execute("history.undo")
    #expect(e.project == before)
}

@MainActor
@Test func contextMenuActionsRunTheirCommands() throws {
    let (e, _) = try engine()
    let p = try #require(e.project)
    let c1 = p.tracks[0].clips[0]
    func cmd(_ a: ClipAction, _ sel: Set<String> = ["c1"]) -> InspectorCommand? { ClipAction.command(a, clip: c1, selection: sel, playhead: 1.5, in: p) }
    #expect(cmd(.cutAtPlayhead) == InspectorCommand(id: "timeline.cut", params: ["at": 1.5]))
    #expect(cmd(.splitHere(2)) == InspectorCommand(id: "timeline.cut", params: ["at": 2, "clipId": "c1"]))
    #expect(cmd(.delete, ["c1", "c3"]) == InspectorCommand(id: "timeline.delete", params: ["clipIds": ["c1", "c3"], "ripple": false]))
    #expect(cmd(.rippleDelete) == InspectorCommand(id: "timeline.delete", params: ["clipIds": ["c1"], "ripple": true]))
    #expect(cmd(.duplicate) == InspectorCommand(id: "timeline.duplicate", params: ["clipIds": ["c1"]]))
    #expect(cmd(.unlink) == InspectorCommand(id: "timeline.link", params: ["clipIds": ["c1", "c2"], "unlink": true]))
    #expect(cmd(.speed(0.5)) == InspectorCommand(id: "clip.speed", params: ["clipId": "c1", "rate": 0.5]))
    #expect(cmd(.showInInspector) == nil && cmd(.revealInMedia) == nil && cmd(.showInFinder) == nil)
    // A clip right-clicked outside the selection acts alone.
    #expect(cmd(.delete, ["c3"]) == InspectorCommand(id: "timeline.delete", params: ["clipIds": ["c1"], "ripple": false]))

    let items = ClipMenu.items(clip: c1, track: p.tracks[0], project: p, selection: ["c1"], at: 2)
    let actions = items.compactMap(\.action)
    #expect(actions.contains(.unlink) && actions.contains(.duplicate) && actions.contains(.splitHere(2)) && actions.contains(.revealInMedia))
    #expect(items.first { $0.action == .splitHere(2) }?.enabled == true)
    #expect(items.first { !$0.submenu.isEmpty }?.submenu.compactMap(\.action) == ClipMenu.speeds.map { .speed($0) })

    // They run: split, duplicate (with its sound), unlink, ripple delete.
    for a in [ClipAction.splitHere(2), .duplicate] { try run(cmd(a), on: e) }
    #expect(e.clips(0).count == 4 && e.clips(1).count == 3)
    try run(cmd(.unlink), on: e)
    #expect(e.project?.tracks[0].clips.first { $0.id == "c1" }?.link == nil)
    try run(cmd(.rippleDelete), on: e)
    #expect(e.clips(0).first?.start.seconds == 0 && e.clips(0).first?.id != "c1")
}

@Test func mediaDroppedOnATrackPlacesLinkedPictureAndSoundAtTheDropTime() async throws {
    let e = Engine(prober: Prober())
    try e.execute("project.new", params: ["name": "drop"])
    try e.execute("media.import", params: ["path": .string(file("take.mov"))])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    let placed = try await MediaDrop.place("a1", at: 3, on: .track("t1"), project: e.project!,
                                           run: { try e.execute($0, params: $1) }, latest: { e.project })
    #expect(placed.count == 2)
    let v = try #require(e.project?.tracks[0].clips.first), a = try #require(e.project?.tracks[1].clips.first)
    #expect(v.start.seconds == 3 && a.start.seconds == 3)
    #expect(v.link != nil && v.link == a.link)
    // Under the tracks: a new video and a new audio track, the clips linked there.
    let more = try await MediaDrop.place("a1", at: 0, on: .below, project: e.project!, run: { try e.execute($0, params: $1) }, latest: { e.project })
    #expect(more.count == 2 && e.project?.tracks.count == 4)
    // Snapping: to the playhead and to clip edges within the tolerance, then to the frame grid.
    #expect(MediaDrop.snap(22.97, project: e.project!, playhead: 10, tolerance: 0.1) == 23)
    #expect(MediaDrop.snap(10.04, project: e.project!, playhead: 10, tolerance: 0.1) == 10)
    #expect(MediaDrop.snap(15.51, project: e.project!, playhead: 10, tolerance: 0.1) == 15.5)
}

@Test func anImageDroppedOnTheTimelineIsAFiveSecondOverlay() async throws {
    let e = Engine(prober: Prober())
    try e.execute("project.new", params: ["name": "image"])
    let png = file("card.png")
    let id = try #require(try e.execute("media.import", params: ["path": .string(png)]).value(at: "asset.id")?.stringValue)
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "overlay"])
    let placed = try await MediaDrop.place(id, at: 2, on: .track("t2"), project: e.project!, run: { try e.execute($0, params: $1) }, latest: { e.project })
    let clip = try #require(e.project?.tracks[1].clips.first)
    #expect(placed == [clip.id])
    #expect(clip.start.seconds == 2 && clip.duration.seconds == 5 && clip.assetID == id)
    #expect(clip.placement?.fit == .contain)
    #expect(e.project?.assets.count == 1)
    // On empty space: overlay.add makes its own overlay track.
    try await MediaDrop.place(id, at: 10, on: .below, project: e.project!, run: { try e.execute($0, params: $1) }, latest: { e.project })
    #expect(e.project?.tracks.filter { $0.kind == .overlay }.flatMap(\.clips).count == 2)
}

@Test func timecodesParse() {
    #expect(Fmt.parseTimecode("00:00:01:15", fps: 30) == 1.5)
    #expect(Fmt.parseTimecode("2:15", fps: 30) == 2.5)
    #expect(Fmt.parseTimecode("3,25", fps: 30) == 3.25)
    #expect(Fmt.parseTimecode("x", fps: 30) == nil)
}

private extension Engine {
    func clips(_ track: Int) -> [Clip] { project!.tracks[track].clips }
}
