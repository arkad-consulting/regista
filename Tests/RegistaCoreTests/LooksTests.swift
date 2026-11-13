import Foundation
import Testing
@testable import RegistaCore

// Issue #22 rounds 2–3 ("looks"): caption styles, speaker layouts, following, HUD shapes, the console theme.

private func threeClips() throws -> Engine {
    let e = try editingEngine()
    for s in [10.0, 20.0, 30.0] {
        let v = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": .number(s), "sourceOut": .number(s + 2)])
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": .number(s), "sourceOut": .number(s + 2),
                                                 "linkTo": v.value(at: "clip.id") ?? .null])
    }
    return e
}

@Test func captionStylePresetsAndOptionalFields() throws {
    #expect(CaptionStyle.all.map(\.id) == ["talking-head-v1", "elegant-serif", "bold-keyword", "ghost-karaoke"])
    #expect(CaptionStyle.presets.count == 4)
    #expect(!CaptionStyle.talkingHeadV1.showsWholeChunk && CaptionStyle.ghostKaraoke.showsWholeChunk && CaptionStyle.elegantSerif.showsWholeChunk)
    #expect(CaptionStyle.boldKeyword.keywordColorOnly && !CaptionStyle.talkingHeadV1.keywordColorOnly)
    // Old projects (no new fields) still decode, and the new fields round-trip.
    let legacy = try JSONValue.from(CaptionStyle.talkingHeadV1)
    #expect(legacy["upcomingOpacity"] == nil)
    let back = try JSONDecoder().decode(CaptionStyle.self, from: JSONValue.from(CaptionStyle.ghostKaraoke).data())
    #expect(back == CaptionStyle.ghostKaraoke)
}

@Test func keywordsMatchAnyCase() {
    let words = ["un", "sito", "sicuro"].enumerated().map { i, w in (text: w, start: t(Double(i) * 0.3), end: t(Double(i) * 0.3 + 0.25)) }
    let chunks = CaptionBuilder.build(words: words, style: .boldKeyword, keywords: ["SITO"], fixes: [:], language: "it")
    #expect(chunks.flatMap(\.words).filter(\.keyword).map(\.text) == ["sito"])
}

@Test func speakerLayoutGeometry() {
    let face = [440.0, 600, 200, 240]
    let lb = SpeakerLayout.letterboxHeadline.geometry(width: 1080, height: 1920, source: (1080, 1920), face: face, options: .init())
    #expect(lb.placement?.fit == .box && abs((lb.placement!.height ?? 0) * 1920 - 607.5) < 1)
    #expect(lb.background == "#000000" && lb.headline != nil)
    #expect(abs(lb.crop![0] / lb.crop![1] - 16.0 / 9) < 0.01)
    let pip = SpeakerLayout.pipBubble.geometry(width: 1080, height: 1920, source: (1080, 1920), face: face, options: .init())
    let d = (pip.placement!.width ?? 0) * 1080
    let right = pip.placement!.x * 1080 + d / 2, bottom = pip.placement!.y * 1920 + d / 2
    // Clear of the Instagram rail and above the caption band.
    #expect(right <= 1080 - SafeZones.rightMargin && bottom <= SafeZones.caption.0)
    #expect(pip.mask?.shape == .circle)
    var o = SpeakerLayout.Options()
    o.frame = "neon"
    let inset = SpeakerLayout.insetFrame.geometry(width: 1080, height: 1920, source: (1080, 1920), face: nil, options: o)
    #expect(inset.mask?.frame == "neon" && inset.mask?.label == nil && inset.crop == nil)
    // The card keeps the frame's aspect (exact zoom from full frame).
    let w = (inset.placement!.width ?? 0) * 1080, h = (inset.placement!.height ?? 0) * 1920
    #expect(abs(w / h - 1080.0 / 1920) < 0.01)
    let split = SpeakerLayout.splitCard.geometry(width: 1080, height: 1920, source: (1080, 1920), face: face, options: .init(side: "right"))
    #expect(split.placement!.x > 0.5 && split.free![0] < 540)
}

@Test func layoutSpeakerWritesBoxesInOneStep() throws {
    let e = try threeClips()
    // Inset frame over the middle of the first two clips: cut at the edges, box + card + zoom keyframes.
    let r = try e.checkUndoRedo("layout.speaker", ["preset": "inset-frame", "from": 1, "to": 3, "frame": "neon", "badge": "9:16"])
    #expect(r["clips"]?.arrayValue?.count == 2)
    let boxed = e.clips(0).filter { $0.placement?.fit == .box }
    #expect(boxed.count == 2 && boxed.allSatisfy { $0.mask?.frame == "neon" && $0.mask?.label == "PREVIEW" && $0.mask?.badge == "9:16" })
    #expect(boxed.first?.keyframes?.first?.transform.scale ?? 1 > 1.5)
    #expect(e.project!.settings.background == "#0C0C0E")
    // Picture-in-picture: the speaker stays full frame, a copy goes into the bubble on a new top track.
    let tracks = e.project!.tracks.count
    let p = try e.checkUndoRedo("layout.speaker", ["preset": "pip-bubble", "from": 4, "to": 6])
    #expect(e.project!.tracks.count == tracks + 1 && e.project!.tracks.last!.clips.allSatisfy { $0.mask?.shape == .circle })
    #expect(p["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("speaker shows twice") == true } == true)
    // Full removes the layout from its range.
    try e.execute("layout.speaker", params: ["preset": "full", "from": 1, "to": 3])
    #expect(e.clips(0).filter { $0.start >= t(1) && $0.end <= t(3) }.allSatisfy { $0.placement == nil && $0.mask == nil })
}

@Test func blurTransitionDefocusesAroundTheCut() throws {
    let e = try threeClips()
    let r = try e.checkUndoRedo("transition.add", ["kind": "blur", "at": 2])
    #expect(r.value(at: "transition.duration") == 0.6)
    let job = RenderJob(project: e.project!, preset: .vertical, captions: false)
    #expect(job.frameFX(at: t(2)).defocus > 40 && job.frameFX(at: t(1.5)).defocus == 0)
    #expect(job.frameFX(at: t(1.85)).defocus > 0 && job.frameFX(at: t(1.85)).defocus < job.frameFX(at: t(2)).defocus)
}

@Test func statusRowChaptersAndConsoleTheme() throws {
    let e = try threeClips()
    let r = try e.checkUndoRedo("status.add", ["chapters": [["at": 2, "label": "EFFECTS"], ["at": 0, "label": "LIVE"]], "timerRate": 8])
    #expect(r.value(at: "chapters.0.label") == "LIVE" && r.value(at: "chapters.1.number") == "02")
    let bar = e.project!.tracks.flatMap(\.clips).first { $0.shape?.kind == .statusBar }!
    #expect(bar.shape!.isLive && bar.shape!.progress(at: t(3), duration: bar.duration) == 3)
    try e.execute("history.undo")
    let undo = e.context.history.undoStack.count
    let c = try e.execute("style.apply", params: ["style": "console", "chapters": [["at": 0, "label": "LIVE"]]])
    #expect(e.context.history.undoStack.count == undo + 1)
    // Card, dark backdrop, status row (+ the background-scene grid when the engines registered the motion templates).
    #expect((c["applied"]?.arrayValue?.count ?? 0) >= 3)
    #expect(e.project!.tracks.first { $0.kind == .video }!.clips.allSatisfy { $0.mask?.frame == "neon" })
}

@Test func followPathMapsThroughBoxesAndHoldsGaps() {
    var layer = VideoLayer(trackID: "t1", clipID: "c1", assetID: "a1", sourceTime: .zero, sourceWidth: 1080, sourceHeight: 1920,
                           crop: [1080, 1920, 0, 0], scale: 1, x: 0, y: 0, rotation: 0, opacity: 1)
    // Full frame: identity.
    let full = FollowPath.toOutput([540, 960], layer: layer, width: 1080, height: 1920)!
    #expect(abs(full.0 - 540) < 1e-6 && abs(full.1 - 960) < 1e-6)
    // Half-size box in the top-left quarter: the source centre lands on the box centre.
    var p = Placement(fit: .box, x: 0.25, y: 0.25)
    p.width = 0.5; p.height = 0.5
    layer.placement = p
    let boxed = FollowPath.toOutput([540, 960], layer: layer, width: 1080, height: 1920)!
    #expect(abs(boxed.0 - 270) < 1e-6 && abs(boxed.1 - 480) < 1e-6)
    // Short gaps keep the last point, long ones drop it.
    var samples = (0..<30).map { i in FollowPath.Sample(t: t(Double(i) / 30), point: i < 10 ? (100.0, 200.0) : nil, size: 50) }
    samples = FollowPath.smooth(samples, rate: 30)
    #expect(samples[12].point != nil && samples[25].point == nil)
}

@Test func handPickPrefersTheOpenHand() {
    let fist = HandTrack.Hand(chirality: "left", palm: [100, 100], wrist: [100, 140], index: [100, 60], box: [80, 50, 40, 90], open: 0.1, confidence: 0.9)
    let open = HandTrack.Hand(chirality: "right", palm: [400, 300], wrist: [400, 360], index: [400, 200], box: [350, 180, 100, 180], open: 0.9, confidence: 0.7)
    #expect(HandTrack.pick([fist, open], chirality: nil, minOpen: 0)?.chirality == "right")
    #expect(HandTrack.pick([fist, open], chirality: "left", minOpen: 0.45) == nil)
    #expect(open.point("index") == [400, 200] && open.point("palm") == [400, 300])
}
