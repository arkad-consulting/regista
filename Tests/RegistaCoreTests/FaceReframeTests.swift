import Foundation
import Testing
@testable import RegistaCore

// A change of aspect keeps the face in frame (#150): a usual talking-head take — a 16:9 camera take, the speaker sitting
// right of centre — made vertical. A centred 9:16 crop cuts the head; project.format and a 9:16 export preset frame on
// the face track instead (FaceFraming, the rules of edit.punchIns).

/// A 1920×1080 take: a face right of centre (landmark box 230×290 at x 1330), drifting a little, for `seconds`; after
/// that, no face (B-roll).
private func rightOfCentre(seconds: Double = 5) -> FaceTrack {
    let n = Int(seconds * 30)
    let frames = (0..<n).map { i -> FaceTrack.Frame in
        let box = [1330 + 20 * sin(Double(i) / 25), 330 + 6 * sin(Double(i) / 17), 230, 290.0]
        return FaceTrack.Frame(t: Double(i) / 30, raw: box, smooth: box)
    }
    return FaceTrack(video: "take", engine: "test", width: 1920, height: 1080, fps: 30, minCutoff: 0.3, beta: 0.01, cuts: [], frames: frames)
}

/// A landscape camera take (1920×1080, no rotation) on V1: 0–4 s with the face, 6–9 s without (B-roll).
private func landscapeTake() throws -> Engine {
    var fakes = FakeServices()
    fakes.faceTrack = rightOfCentre()
    var prober = FakeProber()
    prober.media.video = VideoInfo(width: 1920, height: 1080, frameRate: Rational(30), codec: "h264", rotation: 0)
    let e = Engine(prober: prober, services: fakes.make())
    try e.execute("project.new", params: ["name": "take", "directory": .string(tempDir().path), "width": 1920, "height": 1080])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 6, "sourceOut": 9])
    return e
}

/// The frames of the track whose heads a crop cuts.
private func cutFrames(_ track: FaceTrack, crop: (Double) -> [Double]) -> Int {
    track.frames.filter { !FaceFraming.cutHeads($0.all, crop: crop($0.t), frame: (1920, 1080), headroom: 0.02).isEmpty }.count
}

@Test func aCentredVerticalCropCutsTheSpeakersHeadAndTheFormatChangeFramesIt() throws {
    let track = rightOfCentre()
    // The old way: the largest 9:16 rectangle around the centre of the frame. The head is outside it.
    let centred = RenderJob.fit([1920, 1080, 0, 0], aspect: 1080.0 / 1920, within: (1920, 1080))
    #expect(cutFrames(track, crop: { _ in centred }) == track.frames.count, "a centred crop keeps the head on some frames")

    let e = try landscapeTake()
    #expect(e.project?.assets[0].analysis?.faces == nil)
    let r = try e.checkUndoRedo("project.format", ["preset": "9:16"])
    // No face track yet: the format change tracked the faces first and says so.
    #expect(r["tracked"]?.arrayValue?.compactMap(\.stringValue) == ["a1"])
    #expect(e.project?.assets[0].analysis?.faces != nil)
    #expect(e.project?.settings.width == 1080 && e.project?.settings.height == 1920)
    // The clip with the face is framed on it; the B-roll has no face and keeps the centred crop.
    let rows = try #require(r["reframed"]?.arrayValue)
    #expect(rows.count == 1 && rows[0]["clipId"]?.stringValue == e.clips(0)[0].id && rows[0]["fits"] == true && rows[0]["faces"] == 1)
    #expect(e.clips(0)[1].transform == nil)
    let crop = try #require(e.clips(0)[0].transform?.cropRect(sourceWidth: 1920, sourceHeight: 1080))
    #expect(abs(crop[0] / crop[1] - 1080.0 / 1920) < 0.01 && abs(crop[1] - 1080) < 1, "the whole height, at 9:16: \(crop)")
    #expect(crop[2] > centred[2] + 200, "the crop moved right, to the face: \(crop)")
    // faces.checkFraming passes on every frame with a face.
    let check = try e.execute("faces.checkFraming", params: ["every": 1])
    #expect(check["pass"] == true && check["framesCut"] == 0 && (check["framesWithFaces"]?.doubleValue ?? 0) >= 115, "\(check)")
    // Back to 16:9: the whole frame again holds the face (the crop goes on the face at the clip's zoom, the full height).
    try e.execute("project.format", params: ["preset": "16:9"])
    #expect(try e.execute("faces.checkFraming", params: ["every": 1])["pass"] == true)
}

@Test func anExportPresetOfAnotherAspectFramesTheFaceToo() throws {
    let e = try landscapeTake()
    try e.execute("faces.track", params: ["assetId": "a1"])
    let project = try #require(e.project)
    // The project stays 16:9; the 9:16 preset of export.render / frame.render / frame.contactSheet draws it framed.
    let job = RenderJob(project: project, preset: .vertical)
    var track = rightOfCentre()
    track.frames = track.frames.filter { $0.t < 4 - 0.5 / 30 }   // the clip's range
    let clip = e.clips(0)[0]
    let cut = cutFrames(track) { t in
        job.layers(at: clip.start + MediaTime(seconds: t)).first { $0.clipID == clip.id }?.crop ?? [0, 0, 0, 0]
    }
    #expect(cut == 0, "the 9:16 preset cuts the head on \(cut) frames")
    // The edit itself is untouched, and the project's own preset draws the whole frame.
    #expect(e.project == project && project.tracks[0].clips[0].transform == nil)
    #expect(RenderJob(project: project, preset: ExportPreset.named(nil, project: project)).project == project)
}

// #154: a camera clip that joins a project of another format through import (media.import, then timeline.place with
// frameOnFace, as the app places an imported video) is framed on the face in the placement's undo step.
@Test func aLandscapeClipPlacedInAVerticalProjectIsFramedOnTheFaceInOneStep() throws {
    var fakes = FakeServices()
    fakes.faceTrack = rightOfCentre()
    var prober = FakeProber()
    prober.media.video = VideoInfo(width: 1920, height: 1080, frameRate: Rational(30), codec: "h264", rotation: 0)
    let e = Engine(prober: prober, services: fakes.make())
    try e.execute("project.new", params: ["name": "reel", "directory": .string(tempDir().path), "width": 1080, "height": 1920])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    // Without frameOnFace the clip keeps the centred crop (an agent placing a B-roll where it wants it).
    let plain = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4])
    #expect(plain["tracked"] == nil && e.clips(0)[0].transform == nil && e.project?.assets[0].analysis?.faces == nil)
    try e.execute("history.undo")

    let undo = e.context.history.undoStack.count
    let r = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4, "frameOnFace": true])
    #expect(e.context.history.undoStack.count == undo + 1, "the placement and the framing are not one undo step")
    #expect(r["tracked"]?.arrayValue?.compactMap(\.stringValue) == ["a1"], "the result does not name the asset tracked: \(r)")
    #expect(r["reframed"]?.arrayValue?.first?["clipId"]?.stringValue == e.clips(0)[0].id, "\(r)")
    #expect(e.project?.settings.width == 1080 && e.project?.settings.height == 1920, "the project's format changed")
    let crop = try #require(e.clips(0)[0].transform?.cropRect(sourceWidth: 1920, sourceHeight: 1080), "the clip is cut around its centre")
    let centred = RenderJob.fit([1920, 1080, 0, 0], aspect: 1080.0 / 1920, within: (1920, 1080))
    #expect(abs(crop[0] / crop[1] - 1080.0 / 1920) < 0.01 && crop[2] > centred[2] + 200, "the crop is not on the face: \(crop)")
    let check = try e.execute("faces.checkFraming", params: ["every": 1])
    #expect(check["pass"] == true && check["framesCut"] == 0, "\(check)")
    // One undo takes the clip and its face track away together.
    try e.execute("history.undo")
    #expect(e.clips(0).isEmpty && e.project?.assets[0].analysis?.faces == nil)
    // A clip of the project's own aspect has nothing to frame: no tracking.
    try e.execute("project.format", params: ["preset": "16:9"])
    let same = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4, "frameOnFace": true])
    #expect(same["tracked"] == nil && e.clips(0)[0].transform == nil, "\(same)")
}
