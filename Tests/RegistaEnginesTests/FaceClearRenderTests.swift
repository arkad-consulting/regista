import Foundation
import Testing
@testable import RegistaCore
@testable import RegistaEngines

// #16: a motion template added without a position, and layout.speaker's bubble over the speaker, stay off the face —
// the captions' face test on the real compositor's boxes. Footage: the synthetic talking head with its exact face track,
// cropped so the face sits on the left third for 3 s, then on the right third.

/// The scratch folder of this file's tests (REGISTA_UI_SNAPSHOTS keeps the frames for a look).
private func scratch() throws -> URL {
    let d = TemporaryFolder.url.appendingPathComponent("regista-faceclear-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

/// A project with the synthetic head (with or without its face track) in two clips: face on the left third (0–3 s),
/// then on the right third (3–6 s), both at the height of the top card band (output y ≈ 540).
private func twoSides(_ dir: URL, faces: Bool = true) throws -> Engine {
    let e = Engine(services: .live())
    try e.execute("project.new", params: ["name": "face-sides", "directory": .string(dir.path)])
    let head = try e.execute("media.synthesize", params: ["path": .string(dir.appendingPathComponent("head.mov").path), "duration": 6, "faces": .bool(faces)])
    let asset = try #require(head.value(at: "asset.id")?.stringValue)
    let v = try #require(try e.execute("track.add", params: ["kind": "video"]).value(at: "track.id")?.stringValue)
    try e.execute("timeline.place", params: ["assetId": .string(asset), "trackId": .string(v), "sourceIn": 0, "sourceOut": 6])
    try e.execute("timeline.cut", params: ["at": 3, "trackId": .string(v)])
    let clips = e.project!.tracks.first { $0.id == v }!.clips
    // A 1.5× crop (720×1280): the head (x 540 in the source) lands at x 360 (left third), then at x 720 (right third).
    try e.execute("clip.set", params: ["clipId": .string(clips[0].id), "crop": [720, 1280, 300, 466]])
    try e.execute("clip.set", params: ["clipId": .string(clips[1].id), "crop": [720, 1280, 60, 466]])
    return e
}

private func render(_ e: Engine, at t: Double, _ dir: URL, _ name: String) throws {
    let out = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) } ?? dir
    let r = try e.execute("frame.render", params: ["times": [.number(t)], "path": .string(out.appendingPathComponent("\(name).png").path), "inline": false])
    #expect(r.value(at: "frames.0.path")?.stringValue != nil)
}

/// The template clip's box on the frame (the compositor's ink) and whether the face meets it.
private func faceMeets(_ e: Engine, clip id: String) throws -> Bool {
    let p = e.project!
    let clip = try #require(p.tracks.flatMap(\.clips).first { $0.id == id })
    let job = RenderJob(project: p, preset: ExportPreset.named(nil, project: p))
    let box = MotionPlacement.box(clip, in: p, job: job, renderer: AVRenderer())
    var faces = OutputFaces(job: job)
    return faces.firstOverlap(box, from: clip.start, to: clip.end) != nil
}

@Test func aMotionTemplateWithoutAPositionLandsOnTheFreeSide() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let e = try twoSides(dir)
    // stat-card sits on the right by default ([790, 540]): free while the face is on the left, mirrored while it is on the right.
    let left = try e.execute("motion.add", params: ["template": "stat-card", "start": 0.5, "duration": 2])
    #expect(left["place"] == "position [790, 540]" && left["faceCheck"] == "checked: the face stays clear", "\(left)")
    #expect(left.value(at: "fields.position") == [790, 540] && left["warnings"]?.arrayValue?.isEmpty == true)
    let right = try e.execute("motion.add", params: ["template": "stat-card", "start": 3.5, "duration": 2])
    #expect(right["place"] == "position [290, 540]" && right["faceCheck"] == "checked: the face stays clear", "\(right)")
    #expect(right.value(at: "fields.position") == [290, 540] && right["warnings"]?.arrayValue?.isEmpty == true)
    for r in [left, right] { #expect(try !faceMeets(e, clip: try #require(r.value(at: "clip.id")?.stringValue))) }
    // A band template: the top band is the face's, so it goes to the first free band.
    let band = try e.execute("motion.add", params: ["template": "checklist", "start": 3.5, "duration": 2])
    #expect(band["place"] != "band top" && band["faceCheck"] == "checked: the face stays clear", "\(band)")
    try render(e, at: 1.5, dir, "faceclear-left")
    try render(e, at: 4.5, dir, "faceclear-right")
}

@Test func aPositionGivenStaysAndWarnsWhenItCoversTheFace() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let e = try twoSides(dir)
    // The face is on the right third from 3 s: a card put there by hand stays, with the captions' wording.
    let r = try e.execute("motion.add", params: ["template": "stat-card", "start": 3.5, "duration": 2, "fields": ["position": [790, 540]]])
    #expect(r.value(at: "fields.position") == [790, 540] && r["faceCheck"] == "checked: it covers the face (see warnings)", "\(r)")
    let w = r["warnings"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(w.contains { $0.hasPrefix("motion template \"stat-card\" was placed by hand over a face at 3.") }, "\(w)")
    // A band given is kept too.
    let b = try e.execute("motion.add", params: ["template": "checklist", "start": 0.5, "duration": 2, "band": "top"])
    #expect(b.value(at: "fields.band") == "top" && (b["warnings"]?.arrayValue ?? []).contains { $0.stringValue?.contains("placed by hand over a face") == true }, "\(b)")
    try render(e, at: 4.5, dir, "faceclear-given")
}

@Test func withoutAFaceTrackNothingMovesAndTheResultSaysSoOnce() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let e = try twoSides(dir, faces: false)
    let r = try e.execute("motion.add", params: ["template": "stat-card", "start": 3.5, "duration": 2])
    #expect(r.value(at: "fields.position") == [790, 540] && r["warnings"]?.arrayValue?.isEmpty == true)
    let note = r["faceCheck"]?.stringValue ?? ""
    #expect(note.hasPrefix("not checked") && note.contains("faces.track {assetId: \"a1\"}"), "\(r)")
}

@Test func theSpeakersBubbleTakesTheFirstCornerThatLeavesTheFaceFree() throws {
    let dir = try scratch()
    defer { try? FileManager.default.removeItem(at: dir) }
    let e = Engine(services: .live())
    try e.execute("project.new", params: ["name": "bubble", "directory": .string(dir.path)])
    let head = try e.execute("media.synthesize", params: ["path": .string(dir.appendingPathComponent("head.mov").path), "duration": 4, "faces": true])
    let asset = try #require(head.value(at: "asset.id")?.stringValue)
    let v = try #require(try e.execute("track.add", params: ["kind": "video"]).value(at: "track.id")?.stringValue)
    try e.execute("timeline.place", params: ["assetId": .string(asset), "trackId": .string(v), "sourceIn": 0, "sourceOut": 4])
    // The face low on the right (output ≈ 720, 1040): where the default bubble (bottom right) would sit.
    let clip = try #require(e.project?.tracks.first { $0.id == v }?.clips.first?.id)
    try e.execute("clip.set", params: ["clipId": .string(clip), "crop": [720, 1280, 60, 133]])
    let r = try e.execute("layout.speaker", params: ["preset": "pip-bubble"])
    #expect(r["corner"] == "bottomLeft" && r["faceCheck"] == "checked: the face stays clear", "\(r)")
    try render(e, at: 2, dir, "faceclear-bubble")
    try e.execute("history.undo")
    // A corner given stays, with the warning.
    let given = try e.execute("layout.speaker", params: ["preset": "pip-bubble", "corner": "bottomRight"])
    #expect(given["corner"] == "bottomRight", "\(given)")
    #expect((given["warnings"]?.arrayValue ?? []).contains { $0.stringValue?.hasPrefix("the pip-bubble was placed by hand over a face at") == true }, "\(given)")
}
