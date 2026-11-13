import Foundation
import Testing
@testable import RegistaCore

// R2 #51 (#42 #43 #44) and #79: what the inspector's Schermo section and picture fades need from the commands —
// edit.autoZoom kept on the recording, re-run in place and cleared; keys.overlay kept; a new layout or output format
// recomputing zoom and badges in the same undo step; picture fades on clip.set, split and drawn by the render plan.

private func screenKeyframes(_ e: Engine) -> [[Keyframe]?] { e.project!.tracks[0].clips.map(\.keyframes) }

@Test func autoZoomKeepsItsOptionsReplacesItsKeyframesAndClears() throws {
    let (e, _) = try recordingEngine()
    try e.execute("edit.autoZoom", params: ["zoom": 1.8])
    let first = screenKeyframes(e)
    #expect(e.project!.recordings![0].autoZoom == ["zoom": 1.8])
    // A new intensity is one undo step that replaces the zoom's own keyframes (never adds to them).
    let n = e.context.history.undoStack.count
    try e.execute("edit.autoZoom", params: ["zoom": 2.4, "follow": false])
    #expect(e.context.history.undoStack.count == n + 1)
    let again = screenKeyframes(e)
    #expect(again.map { $0?.count } == first.map { $0?.count } && again != first)
    let (fresh, _) = try recordingEngine()
    try fresh.execute("edit.autoZoom", params: ["zoom": 2.4, "follow": false])
    #expect(again == screenKeyframes(fresh))
    try e.execute("history.undo")
    #expect(screenKeyframes(e) == first && e.project!.recordings![0].autoZoom == ["zoom": 1.8])
    // Off: keyframes and blur gone, the options forgotten; undo brings them back.
    let r = try e.checkUndoRedo("edit.autoZoom", ["clear": true])
    #expect(r["cleared"]?.arrayValue?.isEmpty == false)
    #expect(e.project!.tracks[0].clips.allSatisfy { $0.keyframes == nil && $0.motionBlur == nil })
    #expect(e.project!.recordings![0].autoZoom == nil)
}

@Test func keyBadgeOptionsAreKeptAndClearedWithTheTrack() throws {
    let (e, _) = try recordingEngine()
    try e.checkUndoRedo("keys.overlay", ["position": "top", "allKeys": true])
    #expect(e.project!.recordings![0].keys == ["position": "top", "allKeys": true])
    try e.execute("keys.overlay", params: ["clear": true])
    #expect(e.project!.recordings![0].keys == nil && !e.project!.tracks.contains { $0.role == Recording.keysTrackRole })
}

@Test func aNewLayoutRecomputesTheZoomAndTheBadgesInOneUndoStep() throws {
    let (e, _) = try recordingEngine()
    try e.execute("edit.autoZoom", params: ["zoom": 2])
    try e.execute("keys.overlay", params: ["position": "top"])
    let badge = { e.project!.tracks.first { $0.role == Recording.keysTrackRole }!.clips[0].placement! }
    let (zoomBefore, badgeBefore) = (screenKeyframes(e), badge())
    let n = e.context.history.undoStack.count
    try e.execute("layout.apply", params: ["preset": "stack", "side": "top"])
    #expect(e.context.history.undoStack.count == n + 1)
    // The zoom fits the stack's wide screen box (the same as running it fresh on that layout), the badge sits in the new box.
    let (fresh, _) = try recordingEngine()
    try fresh.execute("layout.apply", params: ["preset": "stack", "side": "top"])
    try fresh.execute("edit.autoZoom", params: ["zoom": 2])
    #expect(screenKeyframes(e) == screenKeyframes(fresh) && screenKeyframes(e) != zoomBefore)
    #expect(badge() != badgeBefore)
    try e.execute("history.undo")
    #expect(screenKeyframes(e) == zoomBefore && badge() == badgeBefore)
}

@Test func projectFormatLaysTheRecordingOutAgainForTheNewFrame() throws {
    let (e, _) = try recordingEngine()
    try e.execute("layout.apply", params: ["preset": "split", "side": "left", "from": 6])
    try e.execute("edit.autoZoom", params: ["zoom": 1.6])
    let before = e.project!
    let r = try e.checkUndoRedo("project.format", ["preset": "9:16"])
    let p = e.project!
    #expect(p.settings.width == 1080 && p.settings.height == 1920)
    // The side-by-side needs width: in a portrait frame it becomes the stack, face on top for a face on the left.
    #expect(p.recordings![0].layouts!.map(\.layout.kind) == [.bubble, .stack])
    #expect(p.recordings![0].layouts!.last?.layout.side == "top")
    #expect(r["layouts"]?.arrayValue?.count == 2)
    // The bubble is laid out again at the new size (a circle of 30 % of the shorter side), the zoom recomputed.
    let job = RenderJob(project: p, preset: .vertical, captions: false)
    let face = job.layers(at: t(2)).first { $0.assetID == p.recordings![0].camera }!
    let box = face.box(width: 1080, height: 1920)
    #expect(abs(box[2] - 324) < 2 && abs(box[3] - 324) < 2)
    #expect(screenKeyframes(e) != before.tracks[0].clips.map(\.keyframes))
    // And back to 16:9: the stack becomes the split again.
    try e.execute("project.format", params: ["preset": "16:9"])
    #expect(e.project!.recordings![0].layouts!.map(\.layout.kind) == [.bubble, .split])
    #expect(throws: CommandError.self) { try e.execute("project.format", params: [:]) }
}

@Test func pictureFadesGoToPictureClipsAndAudioFadesToTheirSound() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 10])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceOut": 10, "linkTo": "c1"])
    let p0 = e.project!
    let video = p0.tracks[0].clips[0], sound = p0.tracks[1].clips[0]
    try e.checkUndoRedo("clip.set", ["clipIds": [.string(video.id), .string(sound.id)], "pictureFadeIn": 0.5, "fadeIn": 0.5])
    let v = e.project!.tracks[0].clips[0], a = e.project!.tracks[1].clips[0]
    #expect(v.pictureFadeIn == t(0.5) && v.fadeIn == nil)
    #expect(a.fadeIn == t(0.5) && a.pictureFadeIn == nil)
    // Alone, a picture fade is for pictures only; an audio fade on a picture clip still works as before.
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": .string(sound.id), "pictureFadeOut": 1]) }
    try e.execute("clip.set", params: ["clipId": .string(video.id), "pictureFadeOut": 0.4, "pictureFadeIn": 0])
    #expect(e.project!.tracks[0].clips[0].pictureFadeIn == nil && e.project!.tracks[0].clips[0].pictureFadeOut == t(0.4))
    // A cut keeps each fade on its outer edge.
    try e.execute("clip.set", params: ["clipId": .string(video.id), "pictureFadeIn": 0.3])
    try e.execute("timeline.cut", params: ["at": .number(video.duration.seconds / 2)])
    let halves = e.project!.tracks[0].clips
    #expect(halves[0].pictureFadeIn == t(0.3) && halves[0].pictureFadeOut == nil)
    #expect(halves[1].pictureFadeIn == nil && halves[1].pictureFadeOut == t(0.4))
}

@Test func thePictureFadeDarkensAFullFrameClipAndThinsAnOverlay() throws {
    var c = Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: t(4), start: .zero)
    c.pictureFadeIn = t(1)
    c.pictureFadeOut = t(0.5)
    #expect(c.pictureVisibility(at: .zero) == 0 && abs(c.pictureVisibility(at: t(0.5)) - 0.5) < 1e-9)
    #expect(c.pictureVisibility(at: t(2)) == 1 && abs(c.pictureVisibility(at: t(3.75)) - 0.5) < 1e-9)
    var p = Project(name: "fade")
    p.assets = [MediaAsset(id: "a1", name: "take", path: "/x.mov", duration: t(4), video: VideoInfo(width: 1080, height: 1920, frameRate: Rational(30), codec: "h264"))]
    var v = Track(id: "t1", kind: .video, name: "V1"), o = Track(id: "t2", kind: .overlay, name: "O1")
    v.clips = [c]
    c.id = "c2"
    o.clips = [c]
    p.tracks = [v, o]
    let job = RenderJob(project: p, preset: .vertical, captions: false)
    let start = job.layers(at: t(0.25)), middle = job.layers(at: t(2))
    #expect(abs(start[0].dim - 0.75) < 1e-6 && start[0].opacity == 1)       // video track: towards black
    #expect(start[1].dim == 0 && abs(start[1].opacity - 0.25) < 1e-6)       // overlay track: towards transparent
    #expect(middle.allSatisfy { $0.dim == 0 && $0.opacity == 1 })
}
