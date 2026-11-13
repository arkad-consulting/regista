import Foundation
import Testing
@testable import RegistaCore

/// A 1080×1920 face track: a mother's face top-left and a baby's lower right, drifting 1 px per frame.
private func twoFaces(frames: Int = 90, baby: Bool = true) -> FaceTrack {
    let fs = (0..<frames).map { i -> FaceTrack.Frame in
        let d = Double(i)
        let mother = [250 + d, 420, 360, 420.0]
        let child = [640 + d * 0.5, 1050, 260, 280.0]
        return FaceTrack.Frame(t: Double(i) / 30, raw: mother, smooth: mother, others: baby ? [child] : nil)
    }
    return FaceTrack(video: "v", engine: "test", width: 1080, height: 1920, fps: 30, minCutoff: 0.3, beta: 0.01, cuts: [], frames: fs)
}

@Test func faceAwareCropKeepsEveryHeadInFrame() throws {
    let track = twoFaces()
    let aspect = 1080.0 / 1920
    // Asked for a tight punch (0.6 of the frame): the two heads need more, the crop grows to hold them.
    let path = try #require(FaceFraming.cropPath(track, from: 0, to: 3, frame: (1080, 1920), aspect: aspect,
                                                 options: FaceFraming.Options(zoom: 0.6)))
    #expect(path.fits && path.faces == 2)
    let first = path.points[0].crop
    #expect(abs(first[0] / first[1] - aspect) < 0.01)
    #expect(first[1] > 0.6 * 1920)   // grown beyond the zoom asked for
    // Every frame: both heads (hair to chin) inside, with headroom above the mother's hair.
    for f in track.frames {
        let c = cropAt(f.t, path)
        #expect(FaceFraming.cutHeads(f.all, crop: c, frame: (1080, 1920), headroom: 0.02).isEmpty, "frame \(f.t)")
        let head = FaceFraming.head(f.raw!)
        #expect(head[1] - c[3] >= 0.02 * c[1])
    }
    // One face: the zoom asked for is honoured and the face sits in the upper part of the crop.
    let single = try #require(FaceFraming.cropPath(twoFaces(baby: false), from: 0, to: 3, frame: (1080, 1920), aspect: aspect,
                                                   options: FaceFraming.Options(zoom: 0.7)))
    let s = single.points[0].crop
    #expect(abs(s[1] - 0.7 * 1920) < 1 && single.faces == 1)
    let faceCentre = 420 + 210 - s[3]
    #expect(faceCentre / s[1] < 0.45)
    // A stray detection (3 frames out of 90) is not a face to keep.
    var noisy = twoFaces(baby: false)
    for k in 40..<43 { noisy.frames[k].others = [[900, 1600, 120, 120]] }
    let n = try #require(FaceFraming.cropPath(noisy, from: 0, to: 3, frame: (1080, 1920), aspect: aspect, options: FaceFraming.Options(zoom: 0.7)))
    #expect(n.faces == 1 && abs(n.points[0].crop[1] - 0.7 * 1920) < 1)
}

/// The crop a path shows at clip time t (linear between keyframes).
private func cropAt(_ t: Double, _ path: FaceFraming.Path) -> [Double] {
    guard path.points.count > 1 else { return path.points[0].crop }
    guard let k = path.points.lastIndex(where: { $0.time <= t + 1e-9 }), k + 1 < path.points.count else { return path.points.last!.crop }
    let a = path.points[k], b = path.points[k + 1], f = (t - a.time) / (b.time - a.time)
    return zip(a.crop, b.crop).map { $0 + ($1 - $0) * f }
}

@Test func punchInsDefaultToFaceAwareCrops() throws {
    var fakes = FakeServices()
    fakes.faceTrack = twoFaces(frames: 300)
    let e = try analysisEngine(fakes)
    try e.execute("faces.track", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 5, "sourceOut": 9])
    let r = try e.checkUndoRedo("edit.punchIns", [:])
    #expect(r["mode"] == "auto" && r["allFit"] == true)
    #expect(r["clips"]?.arrayValue?.map { $0["faces"]?.doubleValue ?? 0 } == [2, 2])
    let check = try e.execute("faces.checkFraming", params: ["every": 1])
    #expect(check["pass"] == true && (check["framesChecked"]?.doubleValue ?? 0) > 100)
    // The approved fixed crops are a named preset now.
    let fixed = try e.execute("edit.punchIns", params: ["preset": "wesites-selfie"])
    #expect(fixed["mode"] == "alternate")
    #expect(e.clips(0)[0].transform?.cropRect(sourceWidth: 1080, sourceHeight: 1920) == [864, 1536, 152, 384])
    // ... and with the fixed crops the baby's head is cut: the check says so.
    #expect(try e.execute("faces.checkFraming", params: ["every": 1])["pass"] == false)
    #expect(throws: CommandError.self) { try e.execute("edit.punchIns", params: ["mode": "alternate"]) }
}

@Test func captionsMoveOffEveryFace() throws {
    // A face right in the caption band (a small child held in the arms), on the whole timeline.
    var style = CaptionStyle.talkingHeadV1
    style.language = "fr"
    func w(_ s: String, _ a: Double) -> CaptionWord { CaptionWord(text: s, start: t(a), end: t(a + 0.3), keyword: false) }
    let chunks = [CaptionChunk(words: [w("BONJOUR", 0)], end: t(0.5), closed: true),
                  CaptionChunk(words: [w("JE", 0.5), w("SUIS", 0.8), w("PÂTISSIÈRE", 1.1)], end: t(1.6)),
                  CaptionChunk(words: [w("D'ANNIVERSAIRE", 2)], end: t(2.5))]
    var captions = Captions(style: style, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "", chunks: chunks)
    let baby = FaceFraming.captionZone([420, 1180, 260, 280])   // landmark box 420–680 × 1180–1460
    let ink = { (cs: [CaptionChunk]) in CaptionPlacement.estimatedInk(cs, style: style) }
    let report = CaptionPlacement.place(&captions, ink: ink, frame: MediaTime.frameDuration(at: Rational(30)),
                                        isStop: LanguageProfile.french.isStopWord) { _ in [baby] }
    #expect(report.overlapping.isEmpty && report.moved + report.shifted >= 3)
    // Every word of every chunk clear of the face zone at its band and shift.
    let boxes = ink(captions.chunks)
    for (ci, ch) in captions.chunks.enumerated() {
        let y = ch.bandY ?? style.bandY, dx = ch.offsetX ?? 0
        for b in boxes[ci] {
            let r = [b[0] + dx, y + b[1], b[2], b[3]]
            #expect(!FaceFraming.intersects(r, baby), "\(ch.text) at \(y) \(dx)")
            // Inside the Instagram safe zone (a centred line may be as wide as the style allows; a shifted one stays off the right edge).
            #expect(r[0] >= 23 && (dx == 0 || r[0] + r[2] <= 1080 - 119) && r[1] + r[3] <= 1540 && r[1] >= 110, "\(ch.text) \(r)")
        }
    }
    // No face: nothing moves.
    var plain = Captions(style: style, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "", chunks: chunks)
    let none = CaptionPlacement.place(&plain, ink: ink, frame: MediaTime.frameDuration(at: Rational(30))) { _ in [] }
    #expect(none.moved == 0 && plain.chunks.allSatisfy { $0.bandY == nil && $0.offsetX == nil })
    // Word-by-word reveal: a face where "PÂTISSIÈRE" will be drawn, gone before the word appears, moves nothing;
    // the same face still there when it appears moves the chunk.
    let under = [600.0, 1250, 200, 200]
    var early = Captions(style: style, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "", chunks: [chunks[1]])
    _ = CaptionPlacement.place(&early, ink: ink, frame: MediaTime.frameDuration(at: Rational(30))) { t in t < MediaTime(seconds: 1.0) ? [under] : [] }
    #expect(early.chunks[0].bandY == nil && early.chunks[0].offsetX == nil)
    var late = Captions(style: style, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "", chunks: [chunks[1]])
    _ = CaptionPlacement.place(&late, ink: ink, frame: MediaTime.frameDuration(at: Rational(30))) { t in t < MediaTime(seconds: 1.3) ? [under] : [] }
    #expect(late.chunks[0].bandY != nil || late.chunks[0].offsetX != nil)
}

@Test func captionsCheckFacesThroughTheEngine() throws {
    var fakes = FakeServices()
    fakes.faceTrack = twoFaces(frames: 300)
    fakes.words = [Word("bonjour", 0.2, 0.6), Word("je", 0.7, 0.8), Word("suis", 0.8, 1.0), Word("pâtissière.", 1.0, 1.6),
                   Word("chaque", 2.0, 2.3), Word("année.", 2.3, 2.8)]
    let e = try analysisEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1", "language": "fr"])
    try e.execute("faces.track", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 3])
    try e.execute("edit.punchIns", params: [:])
    // Without avoidance the fixed band lands on the baby (y 1050–1330 → zone to ~1470): the check fails.
    try e.execute("captions.generate", params: ["avoidFaces": false])
    #expect(try e.execute("captions.checkFaces")["pass"] == false)
    let r = try e.checkUndoRedo("captions.generate", ["avoidFaces": true])
    #expect(r.value(at: "placement.faces") == true && r["stopWordEnds"]?.arrayValue?.isEmpty == true)
    let ok = try e.execute("captions.checkFaces")
    #expect(ok["pass"] == true && (ok["framesWithFaces"]?.doubleValue ?? 0) > 50)
}

@Test func chunkPlacedByHandWinsOverFaceAvoidance() throws {
    var fakes = FakeServices()
    fakes.faceTrack = twoFaces(frames: 300)
    fakes.words = [Word("bonjour", 0.2, 0.6), Word("je", 0.7, 0.8), Word("suis", 0.8, 1.0), Word("pâtissière.", 1.0, 1.6),
                   Word("chaque", 2.0, 2.3), Word("année.", 2.3, 2.8)]
    let e = try analysisEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1", "language": "fr"])
    try e.execute("faces.track", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 3])
    try e.execute("edit.punchIns", params: [:])
    try e.execute("captions.generate", params: ["avoidFaces": true])
    let auto = try #require(e.project!.tracks.first { $0.captions != nil }?.captions)
    let moved = try #require(auto.chunks.firstIndex { $0.bandY != nil || $0.offsetX != nil })
    // Put that chunk back on the baby's face by hand: it stays there (no band, no shift, not split), the others keep
    // their automatic placement, and checkFaces passes with a warning instead of failing.
    let r = try e.checkUndoRedo("captions.place", ["chunk": .number(Double(moved)), "y": 1344])
    #expect(r["scope"] == "chunks")
    let c = try #require(e.project!.tracks.first { $0.captions != nil }?.captions)
    #expect(c.chunks.count == auto.chunks.count && c.chunks[moved].place?.y == 1344 && c.chunks[moved].bandY == nil && c.chunks[moved].offsetX == nil)
    #expect(c.isPinned(chunk: moved) && !c.isPinned(chunk: moved == 0 ? 1 : 0))
    for i in c.chunks.indices where i != moved { #expect(c.chunks[i].bandY == auto.chunks[i].bandY && c.chunks[i].offsetX == auto.chunks[i].offsetX) }
    let check = try e.execute("captions.checkFaces")
    #expect(check["pass"] == true && check["placedOverFaces"] == 1 && (check["warnings"]?.arrayValue?.count ?? 0) == 1)
    // Regenerating keeps the hand placement (same first word), and reset goes back to automatic.
    try e.execute("captions.generate")
    #expect(e.project!.tracks.first { $0.captions != nil }?.captions?.chunks[moved].place?.y == 1344)
    try e.execute("captions.place", params: ["chunk": .number(Double(moved)), "reset": true])
    let back = try #require(e.project!.tracks.first { $0.captions != nil }?.captions)
    #expect(back.chunks[moved].place == nil && back.chunks == auto.chunks)
}
