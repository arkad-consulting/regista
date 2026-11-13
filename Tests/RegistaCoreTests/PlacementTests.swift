import Foundation
import Testing
@testable import RegistaCore

// Direct manipulation (issue #21): moving captions and graphics by hand.

/// A 3.7 s edit with captions (4 words: UNO DUE / TRE QUATTRO, or one chunk per word with maxWords 1), a sticker and a title.
private func placingEngine(maxWords: Int = 2) throws -> Engine {
    let e = Engine(prober: FakeProber(), services: FakeServices().make())
    try e.execute("project.new", params: ["name": "place", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0.9, "sourceOut": 4.6])
    try e.execute("captions.generate")
    try e.execute("captions.setStyle", params: ["overrides": ["maxWords": .number(Double(maxWords))]])
    return e
}

private func captions(_ e: Engine) -> Captions { e.project!.tracks.first { $0.captions != nil }!.captions! }

@Test func previewMappingRoundTripsAtEverySize() {
    // A tall monitor: the picture fills the width; a wide one: the height, centred.
    let tall = PreviewMapping(viewWidth: 270, viewHeight: 600, frameWidth: 1080, frameHeight: 1920)
    #expect(tall.picture == [0, 60, 270, 480] && tall.scale == 0.25)
    #expect(tall.toFrame((135, 300)) == (540, 960))
    let wide = PreviewMapping(viewWidth: 900, viewHeight: 480, frameWidth: 1080, frameHeight: 1920)
    #expect(wide.picture == [315, 0, 270, 480])
    #expect(wide.toView((1080, 1920)) == (585, 480) && wide.toFrame((315, 0)) == (0, 0))
    #expect(wide.toView(box: [540, 960, 108, 192]) == [450, 240, 27, 48])
    for (vw, vh) in [(320.0, 569.0), (1440, 900), (412.5, 733.3), (2000, 300)] {
        let m = PreviewMapping(viewWidth: vw, viewHeight: vh, frameWidth: 1080, frameHeight: 1920)
        for p in [(0.0, 0.0), (1080, 1920), (123.4, 1500.5)] {
            let back = m.toFrame(m.toView(p))
            #expect(abs(back.x - p.0) < 1e-9 && abs(back.y - p.1) < 1e-9)
        }
        // The picture keeps 9:16 and fits inside the view.
        #expect(abs(m.picture[2] / m.picture[3] - 9.0 / 16) < 1e-9 && m.picture[2] <= vw + 1e-9 && m.picture[3] <= vh + 1e-9)
    }
}

@Test func snapGuidesPullToCentreThirdsAndOtherElements() {
    let guides = Snapper.targets(width: 1080, height: 1920, others: [[100, 300, 200, 80]])
    // A box whose centre is 5 px right of the frame's centre line snaps onto it.
    let a = Snapper.snap([395, 1000, 300, 100], to: guides, threshold: 8)
    #expect(a.dx == -5 && a.dy == 0 && a.guides.contains { $0.vertical && $0.position == 540 && $0.kind == .center })
    // Its top 6 px under the other element's bottom edge (380): pulled up; and onto the lower third (1280) on y.
    let b = Snapper.snap([700, 386, 100, 50], to: guides, threshold: 8)
    #expect(b.dy == -6 && b.guides.contains { !$0.vertical && $0.position == 380 && $0.kind == .element })
    let c = Snapper.snap([700, 1255, 100, 50], to: guides, threshold: 8)
    #expect(c.dy == 0 && c.guides.contains { !$0.vertical && $0.position == 1280 && $0.kind == .third })   // centre on the third
    // Out of reach: nothing moves.
    let d = Snapper.snap([10, 10, 50, 50], to: guides, threshold: 8)
    #expect(d.dx == 0 && d.dy == 0 && d.guides.isEmpty)
}

@Test func manualCaptionGeometryAnchorsScalesAndClamps() {
    var c = Captions(style: .talkingHeadV1, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "",
                     chunks: [CaptionChunk(words: [CaptionWord(text: "CIAO", start: .zero, end: t(1), keyword: false)], end: t(1))])
    let p = Project(name: "x")
    var job = RenderJob(project: p, preset: .vertical)
    job.captions = c
    let line = [440.0, 40, 200, 120]   // centred in a 1080×200 band
    // Automatic: exactly the style's band, no shift.
    #expect(job.captionBandOrigin(chunk: 0, line: line) == (0, 1244, false))
    // Left-aligned at x 60, centre y 300: band left = 60 − 440, top = 300 − 100.
    c.place = CaptionPlace(x: 60, y: 300, align: .left)
    job.captions = c
    #expect(job.captionBandOrigin(chunk: 0, line: line) == (-380, 200, false))
    // The chunk's own fields win over the track's; scale 1.5 doubles nothing but the band (300 high) around the centre.
    c.chunks[0].place = CaptionPlace(y: 1500, scale: 1.5)
    job.captions = c
    #expect(job.captionBandSize(chunk: 0) == (1620, 300))
    let big = [660.0, 60, 300, 180]
    #expect(job.captionBandOrigin(chunk: 0, line: big) == (-600, 1350, false))
    // Past the frame: clamped so the line stays inside.
    c.place = CaptionPlace(x: -400, y: 1900, align: .left)
    c.chunks[0].place = nil
    job.captions = c
    let o = job.captionBandOrigin(chunk: 0, line: line)
    #expect(o.x == -440 && o.y + 40 + 120 == 1920 && o.clamped)
}

@Test func captionsPlaceMovesTheTrackOrOneChunkInOneUndoStep() throws {
    let e = try placingEngine()
    #expect(captions(e).chunks.count == 2)
    // The whole track: top-left, left-aligned.
    let r = try e.checkUndoRedo("captions.place", ["x": 60, "y": 300, "align": "left"])
    #expect(r["scope"] == "track" && captions(e).place == CaptionPlace(x: 60, y: 300, align: .left))
    var job = RenderJob(project: e.project!, preset: .vertical)
    let lines = CaptionPlacement.wordBoxes(job, renderer: nil).map { FaceFraming.union($0)! }
    for l in lines { #expect(abs(l[0] - 60) < 1 && abs(l[1] + l[3] / 2 - 300) < 1) }
    // One chunk (the one showing at 2.2 s) lower and bigger: its own placement over the track's.
    let one = try e.checkUndoRedo("captions.place", ["time": 2.2, "y": 1400, "scale": 1.4])
    let ci = try #require(one.value(at: "chunks.0.chunk")?.doubleValue).rounded()
    #expect(one["scope"] == "chunks" && Int(ci) == 1 && captions(e).chunks[1].place == CaptionPlace(y: 1400, scale: 1.4))
    #expect(captions(e).manualPlace(chunk: 1) == CaptionPlace(x: 60, y: 1400, scale: 1.4, align: .left))
    job = RenderJob(project: e.project!, preset: .vertical)
    let after = CaptionPlacement.wordBoxes(job, renderer: nil).map { FaceFraming.union($0)! }
    #expect(after[0] == lines[0] && abs(after[1][1] + after[1][3] / 2 - 1400) < 1 && after[1][3] > lines[1][3] * 1.3)
    // dy moves from where it is; frame.elements reports it where it is drawn.
    try e.execute("captions.place", params: ["chunk": 1, "dy": -100])
    #expect(captions(e).chunks[1].place?.y == 1300)
    let els = try e.execute("frame.elements", params: ["time": 2.2])
    let cap = try #require(els["elements"]?.arrayValue?.first { $0["kind"] == "caption" })
    #expect(cap["chunk"] == 1 && cap["manual"] == true && abs((cap.value(at: "center.1")?.doubleValue ?? 0) - 1300) < 1)
    // Past the left edge: kept inside, reported.
    let edge = try e.execute("captions.place", params: ["x": -300])
    #expect((edge["clamped"]?.doubleValue ?? 0) > 0)
    // Reset of the track: every chunk automatic again.
    try e.checkUndoRedo("captions.place", ["reset": true])
    #expect(captions(e).place == nil && captions(e).chunks.allSatisfy { $0.place == nil })
    #expect(throws: CommandError.self) { try e.execute("captions.place", params: ["chunk": 9, "y": 100]) }
    #expect(throws: CommandError.self) { try e.execute("captions.place", params: ["scale": 9]) }
    #expect(throws: CommandError.self) { try e.execute("captions.place", params: [:]) }
}

@Test func chunkPlacementSurvivesARebuild() throws {
    let e = try placingEngine(maxWords: 1)
    #expect(captions(e).chunks.count == 4)
    try e.execute("captions.place", params: ["chunk": 2, "x": 200, "y": 400])
    // A fix rebuilds the chunks: the placement follows the chunk that starts at the same time.
    try e.execute("captions.setKeywords", params: ["keywords": ["TRE"]])
    try e.execute("captions.setStyle", params: ["overrides": ["hold": 0.5]])
    let c = captions(e)
    #expect(c.chunks[2].text == "TRE" && c.chunks[2].place == CaptionPlace(x: 200, y: 400) && c.chunks.filter { $0.place != nil }.count == 1)
}

@Test func clipPlaceMovesScalesRotatesWithTheAnimationAndResets() throws {
    let e = try placingEngine()
    try e.execute("sticker.add", params: ["sticker": "fire", "start": 1])
    let sid = try #require(e.project!.tracks.flatMap(\.clips).first { $0.sticker != nil }?.id)
    let before = e.project!.tracks.flatMap(\.clips).first { $0.id == sid }!
    let r = try e.checkUndoRedo("clip.place", ["clipId": .string(sid), "x": 300, "y": 800, "scale": 2, "rotation": 15])
    let clip = e.project!.tracks.flatMap(\.clips).first { $0.id == sid }!
    #expect(abs(clip.placement!.x * 1080 - 300) < 1e-6 && abs(clip.placement!.y * 1920 - 800) < 1e-6)
    #expect(clip.transform?.scale == 2 && clip.transform?.rotation == 15 && clip.placeOrigin?.placement == before.placement)
    // The pop keyframes follow: every scale doubled, every rotation +15.
    for (k, k0) in zip(clip.keyframes!, before.keyframes!) {
        #expect(abs(k.transform.scale - k0.transform.scale * 2) < 1e-9 && abs(k.transform.rotation - k0.transform.rotation - 15) < 1e-9)
    }
    #expect(abs((r.value(at: "center.0")?.doubleValue ?? 0) - 300) < 1 && r["clamped"] == false)
    // Into the Instagram buttons: warned. Past the bottom: kept inside.
    let low = try e.execute("clip.place", params: ["clipId": .string(sid), "y": 1700, "rotation": 0])
    #expect(low["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("Instagram") == true } == true)
    let out = try e.execute("clip.place", params: ["clipId": .string(sid), "y": 5000])
    let box = (out["box"]?.arrayValue ?? []).compactMap { $0.doubleValue }
    #expect(out["clamped"] == true && abs(box[1] + box[3] - 1920) < 0.5)
    // Reset: exactly as added (one undo step).
    try e.checkUndoRedo("clip.place", ["clipId": .string(sid), "reset": true])
    #expect(e.project!.tracks.flatMap(\.clips).first { $0.id == sid } == before)
    // The camera fills the frame: not placeable by hand.
    #expect(throws: CommandError.self) { try e.execute("clip.place", params: ["clipId": "c1", "x": 10]) }
}

@Test func canvasElementsAndHitTesting() throws {
    let e = try placingEngine()
    try e.execute("sticker.add", params: ["sticker": "fire", "start": 1, "position": [540, 400]])
    try e.execute("title.add", params: ["text": "CIAO", "start": 1, "duration": 2, "position": [540, 900]])
    let els = CanvasLayout.elements(e.project!, at: t(1.2), renderer: nil)
    #expect(els.map(\.kind) == [.sticker, .title, .caption])
    let sticker = els[0], caption = els[2]
    #expect(abs(sticker.center[0] - 540) < 1e-6 && abs(sticker.center[1] - 400) < 1e-6 && sticker.rotatable && !caption.rotatable)
    #expect(CanvasLayout.hit(els, at: (540, 400))?.kind == .sticker)
    #expect(CanvasLayout.hit(els, at: (caption.center[0], caption.center[1]))?.kind == .caption)
    #expect(CanvasLayout.hit(els, at: (5, 5)) == nil)
    // A rotated element is hit in its own frame: a corner of the unrotated box is outside once rotated 45°.
    try e.execute("clip.place", params: ["clipId": .string(sticker.clipID!), "rotation": 45])
    let rotated = CanvasLayout.elements(e.project!, at: t(1.2), renderer: nil)[0]
    let corner = (rotated.center[0] + rotated.size[0] / 2 - 2, rotated.center[1] + rotated.size[1] / 2 - 2)
    #expect(!rotated.contains(corner) && rotated.contains((rotated.center[0], rotated.center[1])))
}

@Test func shotcutExportKeepsAnOverlayPlacedByHand() throws {
    var services = FakeServices().make()
    services.renderer = FakeRenderer()
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "mlt", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 3])
    let still = fakeMedia("logo.png")
    let added = try e.execute("overlay.add", params: ["path": .string(still), "start": 0, "duration": 3, "scale": 0.2, "animIn": "none"])
    let cid = try #require(added.value(at: "clip.id")?.stringValue)
    try e.execute("clip.place", params: ["clipId": .string(cid), "x": 300, "y": 500, "rotation": 30])
    let url = tempDir().appendingPathComponent("p.mlt")
    let r = try e.execute("export.mlt", params: ["path": .string(url.path)])
    let xml = try String(contentsOf: url, encoding: .utf8)
    // The unrotated rectangle centred on (300, 500), 0.2 × 1080×1920, and the rotation: nothing to warn about.
    #expect(xml.contains("<property name=\"transition.rect\">192.0 308.0 216.0 384.0 1.000</property>"))
    #expect(xml.contains("<property name=\"transition.fix_rotate_x\">30.00</property>"))
    #expect(r["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("rotation") == true } != true)
}

@Test func recipeTellsTheAgentHowToMoveCaptions() throws {
    let text = Recipes.talkingHeadReel.text()
    for needle in ["sposta i sottotitoli più in alto a sinistra", "captions_place {align: \"left\", x: 60, y: 300}",
                   "solo quello a 0:12 più in basso", "captions_place {time: 12, dy: 150}", "clip_place {clipId", "reset: true"] {
        #expect(text.contains(needle), "recipe misses \(needle)")
    }
    // The recipe's own example does what it says: on a captioned edit, the whole track goes top-left.
    let e = try placingEngine()
    let r = try e.execute("captions.place", params: ["align": "left", "x": 60, "y": 300])
    #expect(abs((r.value(at: "chunks.0.line.0")?.doubleValue ?? 0) - 60) < 1)
    try e.execute("captions.place", params: ["time": 2.2, "dy": 150])
    #expect(captions(e).chunks[1].place?.y == 450)
}
