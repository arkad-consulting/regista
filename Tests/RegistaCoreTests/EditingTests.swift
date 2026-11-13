import Foundation
import Testing
@testable import RegistaCore

/// Engine with the whole asset linked on V1 (c1) and A1 (c2).
private func linkedEngine() throws -> Engine {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 30])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceOut": 30, "linkTo": "c1"])
    return e
}

@Test func linkedClipsCutMoveTrimAndDeleteTogether() throws {
    let e = try linkedEngine()
    #expect(e.clips(0)[0].link == "l1" && e.clips(1)[0].link == "l1")
    // A cut of one clip cuts its sound too; the right halves get their own link.
    let cut = try e.checkUndoRedo("timeline.cut", ["at": 10, "clipId": "c1"])
    #expect(cut["cuts"]?.arrayValue?.count == 2)
    #expect(e.clips(0).map(\.link) == ["l1", "l2"] && e.clips(1).map(\.link) == ["l1", "l2"])
    // Trim the picture's end: the sound's end (same time) follows.
    try e.checkUndoRedo("timeline.trim", ["clipId": "c3", "edge": "end", "to": 25])
    #expect(e.clips(0)[1].end == t(25) && e.clips(1)[1].end == t(25))
    // Move the right picture: its sound moves by the same amount.
    try e.checkUndoRedo("timeline.move", ["clipId": "c3", "start": 12])
    #expect(e.clips(0)[1].start == t(12) && e.clips(1)[1].start == t(12))
    // Unlinked move leaves the sound.
    try e.execute("timeline.move", params: ["clipId": "c3", "start": 13, "linked": false])
    #expect(e.clips(0)[1].start == t(13) && e.clips(1)[1].start == t(12))
    try e.execute("history.undo")
    // Ripple delete of the left picture removes its sound and closes both gaps.
    let del = try e.checkUndoRedo("timeline.delete", ["clipId": "c1", "ripple": true])
    #expect(del["deleted"] == ["c1", "c2"])
    #expect(e.clips(0).map(\.start) == [t(2)] && e.clips(1).map(\.start) == [t(2)])
    // Unlink, then a delete only takes the named clip.
    try e.checkUndoRedo("timeline.link", ["clipIds": ["c3"], "unlink": true])
    try e.execute("timeline.delete", params: ["clipId": "c3"])
    #expect(e.clips(0).isEmpty && e.clips(1).count == 1)
    try e.execute("timeline.link", params: ["clipIds": ["c4"], "unlink": true])
    #expect(throws: CommandError.self) { try e.execute("timeline.link", params: ["clipIds": ["c4"]]) }
}

@Test func clipSetCropsAnimatesGradesAndFades() throws {
    let e = try linkedEngine()
    try e.checkUndoRedo("clip.set", ["clipId": "c1", "crop": [864, 1536, 152, 384], "brightness": 0.02, "contrast": 1.06, "saturation": 1.08])
    let c = e.clips(0)[0]
    #expect(c.transform?.cropRect(sourceWidth: 1080, sourceHeight: 1920).map { ($0 * 1000).rounded() / 1000 } == [864, 1536, 152, 384])
    #expect(c.color == ColorAdjust(brightness: 0.02, contrast: 1.06, saturation: 1.08))
    // Keyframes start from the clip transform and interpolate linearly, held outside.
    try e.execute("clip.set", params: ["clipId": "c1", "keyframes": [["time": 1, "crop": [864, 1536, 100, 384]], ["time": 3, "crop": [864, 1536, 200, 384]]]])
    let k = e.clips(0)[0]
    func x(_ s: Double) -> Double { (k.transform(at: t(s)).cropRect(sourceWidth: 1080, sourceHeight: 1920)[2] * 1000).rounded() / 1000 }
    #expect(x(0) == 100 && x(2) == 150 && x(3) == 200 && x(10) == 200)
    try e.execute("clip.set", params: ["clipId": "c1", "clearKeyframes": true])
    #expect(e.clips(0)[0].keyframes == nil && x(0) == 100)
    // Fades on every clip of a track; 0 removes them.
    try e.checkUndoRedo("clip.set", ["trackId": "t2", "fadeIn": 0.015, "fadeOut": 0.015])
    #expect(e.clips(1)[0].fadeIn == t(0.015) && e.clips(1)[0].fadeOut == t(0.015))
    try e.execute("clip.set", params: ["trackId": "t2", "fadeIn": 0])
    #expect(e.clips(1)[0].fadeIn == nil && e.clips(1)[0].fadeOut == t(0.015))
    // Bad crops and picture-less clips are refused.
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": "c1", "crop": [900, 1536, 300, 0]]) }
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": "c1", "keyframes": [["crop": [10, 10, 0, 0]]]]) }
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: [:]) }
}

@Test func punchInsAlternateByClipOrByLine() throws {
    let e = try takesEngine()
    try e.execute("takes.list")
    try e.execute("edit.autoCut")
    let base: JSONValue = [864, 1536, 152, 384], punch: JSONValue = [760, 1351, 204, 487]
    let r = try e.checkUndoRedo("edit.punchIns", ["base": base, "punch": punch])
    #expect(r["clips"]?.arrayValue?.map { $0["framing"]?.stringValue ?? "" } == ["base", "punch", "base", "punch"])
    #expect(r["commands"]?.arrayValue?.allSatisfy { $0["command"] == "clip.set" } == true)
    func xs() -> [Double] { e.clips(0).map { ($0.transform!.cropRect(sourceWidth: 1080, sourceHeight: 1920)[2]).rounded() } }
    #expect(xs() == [152, 204, 152, 204])
    // By line: the two clips of one script line keep the same framing.
    let lines = e.clips(0).map { Takes.line(of: $0, in: e.project!.takes!) }
    let byLine = try e.execute("edit.punchIns", params: ["base": base, "punch": punch, "by": "line"])
    var expected: [String] = [], parity = 0
    for (k, l) in lines.enumerated() { if k > 0, l != lines[k - 1] { parity ^= 1 }; expected.append(parity == 0 ? "base" : "punch") }
    #expect(Set(lines.map { $0 ?? 0 }).count < lines.count)   // the fixture has a line cut in two
    #expect(byLine["clips"]?.arrayValue?.map { $0["framing"]?.stringValue ?? "" } == expected)
}

@Test func punchInsFollowTheFace() throws {
    let e = try analysisEngine()
    try e.execute("faces.track", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 1.5])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 2, "sourceOut": 3])
    try e.checkUndoRedo("edit.punchIns", ["base": [864, 1536, 0, 0], "punch": [760, 1351, 0, 0], "mode": "face"])
    let c = e.clips(0)
    // The fake face drifts right 1 px per frame: the first clip gets keyframes that follow it.
    let k = try #require(c[0].keyframes)
    #expect(k.count > 5)
    let first = k.first!.transform.cropRect(sourceWidth: 1080, sourceHeight: 1920), last = k.last!.transform.cropRect(sourceWidth: 1080, sourceHeight: 1920)
    #expect(abs(first[0] - 864) < 0.01 && last[2] > first[2] + 20)
    // Centred on the face (box 300×400 at x≈400 → centre ≈ 550); raised by the hair padding the crop hits the top edge and is clamped.
    #expect(abs(first[2] + 432 - 550) < 15 && first[3] == 0)
    let p = c[1].keyframes?.first?.transform.cropRect(sourceWidth: 1080, sourceHeight: 1920) ?? c[1].transform!.cropRect(sourceWidth: 1080, sourceHeight: 1920)
    #expect(abs(p[0] - 760) < 0.01)
}

/// Fake words: uno 1.0–1.4, due 1.5–2.0, tre 3.0–3.5, quattro 3.6–4.5; V/A linked over 0.9–4.6.
private func wordsEngine() throws -> Engine {
    let e = try analysisEngine()
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0.9, "sourceOut": 4.6])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": 0.9, "sourceOut": 4.6, "linkTo": "c1"])
    return e
}

/// A screen recording or a voice-over: the picture track says nothing, the words are on an audio track.
@Test func theWordsTrackIsFoundUnderASilentPicture() throws {
    let e = try analysisEngine()
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("media.import", params: ["path": .string(fakeMedia()), "name": "picture"])   // a2: never transcribed
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a2", "trackId": "t1", "sourceIn": 0, "sourceOut": 4.6])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": 0.9, "sourceOut": 4.6])
    let tl = try e.execute("transcript.timeline")
    #expect(tl["trackId"] == "t2" && tl["text"] == "uno due tre quattro")
    #expect(try e.execute("captions.generate")["chunks"]?.doubleValue ?? 0 > 0)
    // A track that is named still wins, also when it has no words.
    #expect(try e.execute("transcript.timeline", params: ["trackId": "t1"])["count"] == 0)
}

@Test func deleteWordsCutsTheTimelineInOneStep() throws {
    let e = try wordsEngine()
    let tl = try e.execute("transcript.timeline")
    #expect(tl["text"] == "uno due tre quattro")
    #expect(tl.value(at: "words.2.start") == 2.1)
    #expect(throws: CommandError.self) { try e.execute("transcript.deleteWords", params: ["from": 1, "expect": "tre"]) }
    let r = try e.checkUndoRedo("transcript.deleteWords", ["from": 1, "expect": "due"])
    #expect(r["from"] == 0.6 && r["to"] == 2.1)
    #expect(r["commands"]?.arrayValue?.map { $0["command"]?.stringValue ?? "" } == ["timeline.cut", "timeline.cut", "timeline.cut", "timeline.cut", "timeline.delete"])
    let after = try e.execute("transcript.timeline")
    #expect(after["text"] == "uno tre quattro")
    #expect(after.value(at: "words.1.start") == 0.6)
    #expect(e.clips(0).map(\.start) == e.clips(1).map(\.start) && e.project!.duration == t(2.2))
    // The last word of a clip takes the clip's tail with it.
    try e.execute("transcript.deleteWords", params: ["from": 2])
    #expect(e.project!.duration == t(1.2))
}

@Test func editTextChangesOnlyTheWords() throws {
    let e = try wordsEngine()
    #expect(throws: CommandError.self) { try e.execute("transcript.editText", params: ["from": 1, "text": "Arkad", "expect": "tre"]) }
    let r = try e.checkUndoRedo("transcript.editText", ["from": 1, "to": 2, "text": "Arkad Consulting", "expect": "due tre"])
    #expect(r["old"] == "due tre" && r["new"] == "Arkad Consulting")
    let after = try e.execute("transcript.timeline")
    #expect(after["text"] == "uno Arkad Consulting quattro")
    // The new words share the old span (1.5–3.5 in the source → 0.6–2.6 on the timeline) by length; nothing was cut.
    #expect(after.value(at: "words.1.start") == 0.6 && after.value(at: "words.2.end") == 2.6)
    #expect(e.project!.duration == t(3.7))
}

@Test func editTextAcrossACutKeepsEveryWord() throws {
    let e = try wordsEngine()
    try e.execute("transcript.deleteWords", params: ["from": 2, "expect": "tre"])
    // "due quattro" now straddles the cut where "tre" was: three new words must all stay on the timeline.
    try e.execute("transcript.editText", params: ["from": 1, "to": 2, "text": "intelligence artificielle ok", "expect": "due quattro"])
    let after = try e.execute("transcript.timeline")
    #expect(after["text"] == "uno intelligence artificielle ok")
}

@Test func trackDeleteRefusesClipsUnlessForced() throws {
    let e = try wordsEngine()
    #expect(throws: CommandError.self) { try e.execute("track.delete", params: ["trackId": "t2"]) }
    try e.execute("track.add", params: ["kind": "audio"])
    try e.checkUndoRedo("track.delete", ["trackId": "t3"])
    try e.execute("track.delete", params: ["trackId": "t2", "force": true])
    #expect(e.project!.tracks.count == 1 && e.clips(0).allSatisfy { $0.link == nil })
}

@Test func captionBuilderMatchesCaptionsPy() {
    let style = CaptionStyle.talkingHeadV1
    func w(_ s: String, _ a: Double, _ b: Double) -> (text: String, start: MediaTime, end: MediaTime) { (s, t(a), t(b)) }
    let words = [w("Ti", 0.1, 0.3), w("hanno", 0.3, 0.6), w("detto", 0.6, 0.9), w("che", 0.9, 1.0), w("un", 1.0, 1.1),
                 w("sito", 1.1, 1.4), w("è", 1.4, 1.5), w("sicuro.", 1.5, 2.0),
                 w("le", 3.0, 3.1), w("chiedi", 3.1, 3.4), w("al", 3.4, 3.5), w("IA,", 3.5, 3.8), w("e", 3.9, 4.0),
                 w("d'", 4.0, 4.1), w("urgenza", 4.1, 4.6)]
    let chunks = CaptionBuilder.build(words: words, style: style, keywords: ["SICURO", "ALL'IA"], fixes: ["AL": "ALL'IA", "IA": ""])
    // 3 words max; "CHE UN" would end on a stop word so it moves to the next chunk; punctuation ends a chunk.
    #expect(chunks.map(\.text) == ["TI HANNO DETTO", "CHE UN SITO", "È SICURO", "LE CHIEDI ALL'IA", "E D'URGENZA"])
    // "IA" removed by a fix: its break and end time pass to "ALL'IA".
    #expect(chunks[3].words[2].end == t(3.8) && chunks[3].words[2].keyword && chunks[2].words[1].keyword)
    // A chunk ends at the next chunk's start or 0.4 s after its last word.
    #expect(chunks[0].end == t(0.9) && chunks[2].end == t(2.4) && chunks[4].end == t(5.0))
    let captions = Captions(style: style, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "", chunks: chunks)
    #expect(captions.state(at: t(0.35)) == Captions.State(chunk: 0, count: 2, start: t(0.3), end: t(0.6)))
    #expect(captions.state(at: t(2.5)) == nil && captions.state(at: t(2.39))?.count == 2)
    let reveals = captions.revealFrames(rate: Rational(30))
    #expect(reveals.count == 13 && reveals[0].frame == 3 && reveals[1].frame == 9)
    #expect(CaptionBuilder.srt(captions).hasPrefix("1\n00:00:00,100 --> 00:00:00,900\nTI HANNO DETTO\n\n2\n"))
    // Spoken numbers come back as digits; small standalone ones stay words.
    let nums = CaptionBuilder.build(words: [w("due", 0, 0.2), w("falle", 0.2, 0.5), w("da", 0.5, 0.6), w("nove", 0.6, 0.8), w("virgola", 0.8, 1.0),
                                            w("due", 1.0, 1.2), w("su", 1.3, 1.4), w("dieci.", 1.4, 1.7), w("Nel", 2, 2.1), w("duemilaventicinque", 2.1, 2.8),
                                            w("più", 3, 3.1), w("di", 3.1, 3.2), w("undicimila", 3.2, 3.9)],
                                    style: style, keywords: ["9,2", "11.000"], fixes: [:])
    #expect(nums.map(\.text) == ["DUE FALLE", "DA 9,2 SU 10", "NEL 2025", "PIÙ DI 11.000"])
    #expect(nums[1].words[1].start == t(0.6) && nums[1].words[1].end == t(1.2) && nums[1].words[1].keyword && nums[3].words[2].keyword)
    #expect(TextNorm.number("undicimila") == 11000 && TextNorm.number("sito") == nil)
    // Max 17 characters: a long word starts a new chunk.
    let long = CaptionBuilder.build(words: [w("più", 0, 0.2), w("vulnerabilità", 0.2, 0.9), w("nove", 1, 1.2)], style: style, keywords: [], fixes: [:])
    #expect(long.map(\.text) == ["PIÙ VULNERABILITÀ", "NOVE"])
}

@Test func captionsFollowTheEditedTimeline() throws {
    let e = try wordsEngine()
    let dir = tempDir()
    let kw = dir.appendingPathComponent("keywords.json")
    try Data(#"{"keywords": ["TRE"], "fixes": {"QUATTRO": "4"}}"#.utf8).write(to: kw)
    let r = try e.checkUndoRedo("captions.generate", ["keywordsPath": .string(kw.path)])
    #expect(r["chunks"] == 2 && r["stale"] == false && r["keywordsShown"] == 1)
    let got = try e.execute("captions.get")
    // The 1 s pause after "due" (no punctuation there) ends a caption sentence.
    #expect(got.value(at: "list.0.text") == "UNO DUE" && got.value(at: "list.1.text") == "TRE 4")
    #expect(got.value(at: "list.1.words.0.start") == 2.1 && got.value(at: "list.1.words.0.keyword") == true)
    // Text edit: captions are regenerated in the same undo step, with remapped times.
    try e.execute("transcript.deleteWords", params: ["from": 1])
    #expect(try e.execute("captions.get").value(at: "list.0.text") == "UNO")
    #expect(try e.execute("captions.get").value(at: "list.1.words.0.start") == 0.6)
    try e.execute("history.undo")
    #expect(try e.execute("captions.get").value(at: "list.0.text") == "UNO DUE")
    // Moving a clip by hand makes them stale until regenerated.
    try e.execute("timeline.move", params: ["clipId": "c1", "start": 1])
    #expect(try e.execute("captions.get")["stale"] == true)
    try e.checkUndoRedo("captions.setKeywords", ["add": ["UNO"], "remove": ["TRE"]])
    #expect(try e.execute("captions.get").value(at: "list.0.words.0.keyword") == true)
    let s = try e.checkUndoRedo("captions.setStyle", ["overrides": ["maxWords": 2, "bandY": 1200]])
    #expect(s["rechunked"] == true && s["style"] == "talking-head-v1+custom")
    #expect(throws: CommandError.self) { try e.execute("captions.setStyle", params: ["overrides": ["nope": 1]]) }
    #expect(throws: CommandError.self) { try e.execute("captions.setStyle", params: ["overrides": ["maxWords": "x"]]) }
    let srt = dir.appendingPathComponent("out.srt")
    #expect(try e.execute("export.srt", params: ["path": .string(srt.path)])["cues"] == 2)
    #expect(try String(contentsOf: srt, encoding: .utf8).contains("UNO DUE"))
}

@Test func freeSpotAvoidsAGraphicAlreadyThere() throws {
    let e = try wordsEngine()
    try e.execute("title.add", params: ["text": "Primo titolo", "start": 1.0, "duration": 2, "position": [540, 375]])
    let spot = FreeSpot.centre(in: e.project!, at: t(1.5), size: [640, 170], candidates: FreeSpot.titleSpots, renderer: nil)
    #expect(spot != [540, 375])
    // Nothing on screen at 0.2 s: the first choice.
    #expect(FreeSpot.centre(in: e.project!, at: t(0.2), size: [640, 170], candidates: FreeSpot.titleSpots, renderer: nil) == [540, 375])
}
