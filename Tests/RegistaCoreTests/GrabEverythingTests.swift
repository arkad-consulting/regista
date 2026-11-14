import Foundation
import Testing
@testable import RegistaCore

// Every element on the frame can be grabbed (#30): clip.place on a full-frame picture, a full-frame insert, a callout
// and a box of a recording layout — the command a drag on the preview runs and the agent runs.

/// A 3.7 s edit: the camera (c1) fills the frame on t1.
private func cameraEngine() throws -> Engine {
    let e = Engine(prober: FakeProber(), services: FakeServices().make())
    try e.execute("project.new", params: ["name": "grab", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0.9, "sourceOut": 4.6])
    return e
}

private func clip(_ e: Engine, _ id: String) -> Clip { e.project!.tracks.flatMap(\.clips).first { $0.id == id }! }
private func element(_ e: Engine, _ id: String, at s: Double = 1) -> CanvasElement? {
    CanvasLayout.elements(e.project!, at: t(s), renderer: nil).first { $0.clipID == id }
}
private func layer(_ e: Engine, _ id: String, at s: Double) -> VideoLayer {
    RenderJob(project: e.project!, preset: .vertical).layers(at: t(s)).first { $0.clipID == id }!
}

@Test func aFullFramePictureIsMovedResizedAndResetThroughClipPlace() throws {
    let e = try cameraEngine()
    let before = clip(e, "c1")
    let start = try #require(element(e, "c1"))
    #expect(start.kind == .picture && start.movable && start.needsSelection && !start.rotatable && start.scale == 1)
    #expect(start.box == [0, 0, 1080, 1920])
    let crop = layer(e, "c1", at: 1).crop
    // A move: the picture becomes a box as large as the frame, then moves; the same part of the picture shows.
    let r = try e.checkUndoRedo("clip.place", ["clipId": "c1", "dx": 100, "dy": -50])
    let moved = clip(e, "c1")
    #expect(moved.placement?.fit == .box && moved.placement?.width == 1 && moved.placement?.height == 1)
    #expect(moved.placeOrigin?.placement == nil && moved.isFullFramePicture && r["kind"] == "picture")
    #expect(layer(e, "c1", at: 1).crop == crop)
    let m = try #require(element(e, "c1"))
    #expect(m.kind == .picture && m.manual && abs(m.center[0] - 640) < 1e-6 && abs(m.center[1] - 910) < 1e-6 && m.size == [1080, 1920])
    // Half the size: the background shows around it; the crop is still the same.
    try e.checkUndoRedo("clip.place", ["clipId": "c1", "scale": 0.5])
    let half = try #require(element(e, "c1"))
    #expect(half.size == [540, 960] && abs(half.scale - 0.5) < 1e-9 && abs(half.center[0] - 640) < 1e-6)
    #expect(layer(e, "c1", at: 1).crop == crop)
    // Far out: the centre stays inside the frame.
    let out = try e.execute("clip.place", params: ["clipId": "c1", "x": 5000])
    #expect(out["clamped"] == true && abs((element(e, "c1")?.center[0] ?? 0) - 1080) < 0.5)
    // Reset: exactly as it was, filling the frame again (one undo step).
    try e.checkUndoRedo("clip.place", ["clipId": "c1", "reset": true])
    #expect(clip(e, "c1") == before && element(e, "c1")?.box == [0, 0, 1080, 1920])
}

@Test func aFullFrameInsertIsAPictureToo() throws {
    let e = try cameraEngine()
    let added = try e.execute("overlay.add", params: ["path": .string(fakeMedia("card.png")), "start": 0.5, "duration": 2, "fit": "fill"])
    let id = try #require(added.value(at: "clip.id")?.stringValue)
    let before = clip(e, id)
    let els = CanvasLayout.elements(e.project!, at: t(1), renderer: nil)
    // Two pictures: the insert over the camera is the one hit.
    #expect(els.map(\.kind) == [.picture, .picture] && CanvasLayout.hit(els, at: (540, 960))?.clipID == id)
    try e.checkUndoRedo("clip.place", ["clipId": .string(id), "dy": 300, "scale": 0.6])
    let m = try #require(element(e, id))
    #expect(abs(m.center[1] - 1260) < 1e-6 && abs(m.size[0] - 648) < 1e-6)
    // Where it no longer covers the frame, the camera under it is hit.
    let now = CanvasLayout.elements(e.project!, at: t(1), renderer: nil)
    #expect(CanvasLayout.hit(now, at: (540, 100))?.clipID == "c1" && CanvasLayout.hit(now, at: (540, 1260))?.clipID == id)
    try e.checkUndoRedo("clip.place", ["clipId": .string(id), "reset": true])
    #expect(clip(e, id) == before)
}

@Test func aCalloutMovesAndGrowsItsOwnRectangle() throws {
    let e = try cameraEngine()
    let added = try e.execute("callout.add", params: ["kind": "box", "start": 0.5, "rect": [100, 200, 300, 150], "drawOn": 0])
    let id = try #require(added.value(at: "clip.id")?.stringValue)
    let before = clip(e, id)
    let el = try #require(element(e, id))
    #expect(el.kind == .callout && el.movable && !el.rotatable && abs(el.center[0] - 250) < 1e-6 && abs(el.center[1] - 275) < 1e-6)
    #expect(el.size[0] > 300 && el.size[0] < 320)   // the rectangle and its stroke
    // Over the camera, the callout is hit.
    #expect(CanvasLayout.hit(CanvasLayout.elements(e.project!, at: t(1), renderer: nil), at: (250, 275))?.clipID == id)
    try e.checkUndoRedo("clip.place", ["clipId": .string(id), "dx": 50, "dy": 60])
    var r = clip(e, id).shape!.rect
    #expect(abs(r[0] * 1080 - 150) < 1e-6 && abs(r[1] * 1920 - 260) < 1e-6 && abs(r[2] * 1080 - 300) < 1e-6)
    #expect(clip(e, id).keyframes == before.keyframes && clip(e, id).placeOrigin?.rect == before.shape!.rect)
    // Twice as large, around its centre.
    try e.checkUndoRedo("clip.place", ["clipId": .string(id), "scale": 2])
    r = clip(e, id).shape!.rect
    #expect(abs(r[2] * 1080 - 600) < 1e-6 && abs(r[3] * 1920 - 300) < 1e-6 && abs((r[0] + r[2] / 2) * 1080 - 300) < 1e-6)
    #expect(abs((element(e, id)?.scale ?? 0) - 2) < 1e-9)
    #expect(throws: CommandError.self) { try e.execute("clip.place", params: ["clipId": .string(id), "rotation": 10]) }
    // Past the edge: kept inside.
    let edge = try e.execute("clip.place", params: ["clipId": .string(id), "x": 0])
    #expect(edge["clamped"] == true && clip(e, id).shape!.rect[0] == 0)
    try e.checkUndoRedo("clip.place", ["clipId": .string(id), "reset": true])
    #expect(clip(e, id) == before)
}

@Test func aLayoutBoxIsPlacedByHandUntilTheLayoutIsAppliedAgain() throws {
    let (e, _) = try recordingEngine(width: 1080, height: 1920)
    let p = e.project!
    let screen = p.tracks[0].clips[0], camera = p.tracks[1].clips[0]
    let els = CanvasLayout.elements(p, at: t(5), renderer: nil)
    let bubble = try #require(els.first { $0.clipID == camera.id })
    #expect(bubble.kind == .layoutBox && bubble.movable && bubble.scale == 1)
    #expect(els.first { $0.clipID == screen.id }?.kind == (screen.placement?.fit == .box ? .layoutBox : .picture))
    // Moved and twice as large: a box of its own, the crop and the mask unchanged.
    let r = try e.checkUndoRedo("clip.place", ["clipId": .string(camera.id), "dx": -200, "dy": -300, "scale": 2])
    let moved = clip(e, camera.id)
    #expect(r["kind"] == "layout box" && moved.placeOrigin?.placement == camera.placement && moved.mask == camera.mask)
    #expect(abs(moved.placement!.width! - camera.placement!.width! * 2) < 1e-9 && moved.transform == camera.transform)
    let m = try #require(CanvasLayout.elements(e.project!, at: t(5), renderer: nil).first { $0.clipID == camera.id })
    #expect(abs(m.center[0] - (bubble.center[0] - 200)) < 1 && abs(m.center[1] - (bubble.center[1] - 300)) < 1 && abs(m.scale - 2) < 1e-9)
    // layout.apply again: the preset's boxes replace the one placed by hand.
    try e.execute("layout.apply", params: ["preset": "bubble"])
    let again = e.project!.tracks[1].clips.first { $0.start == camera.start }!
    #expect(again.placeOrigin == nil && again.placement == camera.placement)
}

@Test func punchInsKeepZoomingOnTheSamePointAfterAMoveAndAReset() throws {
    let e = try cameraEngine()
    // A punch-in: the crop narrows over the clip (a zoom on the upper middle of the picture).
    try e.execute("clip.keyframe", params: ["clipId": "c1", "keyframes": [
        ["time": 0, "crop": [1080, 1920, 0, 0]], ["time": 2, "crop": [540, 960, 270, 300]]]])
    let before = clip(e, "c1")
    let times = [0.0, 1.0, 2.5]
    let crops = times.map { layer(e, "c1", at: $0).crop }
    try e.execute("clip.place", params: ["clipId": "c1", "dx": -120, "dy": 80])
    try e.execute("clip.place", params: ["clipId": "c1", "scale": 0.7])
    for (s, c) in zip(times, crops) {
        let l = layer(e, "c1", at: s)
        // The same part of the picture, drawn where the element is and at its size.
        #expect(l.crop == c, "the punch-in shows another part of the picture at \(s) s")
        let el = try #require(element(e, "c1", at: s))
        #expect(abs(el.center[0] - 420) < 1e-6 && abs(el.center[1] - 1040) < 1e-6 && abs(el.size[0] - 756) < 1e-6)
    }
    try e.execute("clip.place", params: ["clipId": "c1", "reset": true])
    #expect(clip(e, "c1") == before && zip(times, crops).allSatisfy { layer(e, "c1", at: $0.0).crop == $0.1 })
}

@Test func whatCannotBePlacedIsStillListedAndSaysWhy() throws {
    let e = try cameraEngine()
    var p = e.project!
    // A motion template over the whole frame and a halo following an object, on overlay tracks.
    var o = Track(id: "t9", kind: .overlay, name: "O9")
    var m = Clip(id: "m1", assetID: "", sourceIn: .zero, sourceOut: t(2), start: .zero)
    m.motion = MotionLayer(template: "counter", fields: [:], style: MotionStyle.from(nil), layering: .front)
    o.clips = [m]
    var h = Track(id: "t8", kind: .overlay, name: "O8")
    var halo = Clip(id: "h1", assetID: "", sourceIn: .zero, sourceOut: t(2), start: .zero)
    halo.shape = ShapeLayer(kind: .halo, rect: [0.4, 0.4, 0.2, 0.05], color: "#FFB066")
    h.clips = [halo]
    p.tracks += [h, o]
    let s = Engine(scratch: p, services: FakeServices().make())
    let els = CanvasLayout.elements(s.project!, at: t(1), renderer: nil)
    #expect(els.map(\.kind) == [.picture, .halo, .motion] && els.filter(\.movable).map(\.kind) == [.picture])
    // The template is drawn over the whole frame: the camera under it is still the one hit, the halo where it is.
    #expect(CanvasLayout.hit(els, at: (100, 100))?.clipID == "c1" && CanvasLayout.hit(els, at: (540, 800))?.clipID == "h1")
    #expect(CanvasLayout.hit(Array(els.dropFirst()), at: (100, 100))?.clipID == "m1")
    let listed = try s.execute("frame.elements", params: ["time": 1])
    #expect(listed["elements"]?.arrayValue?.map { $0["kind"]?.stringValue ?? "" } == ["picture", "halo", "motion"])
    #expect(listed.value(at: "elements.2.movable") == false)
    for id in ["m1", "h1"] { #expect(throws: CommandError.self) { try s.execute("clip.place", params: ["clipId": .string(id), "x": 10]) } }
}
