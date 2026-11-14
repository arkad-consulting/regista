import Foundation
import Testing
@testable import RegistaCore

/// Words of `text` from `start`, 0.25 s each; `pauseAfter` inserts silence after that word index.
func spoken(_ text: String, at start: Double, pauseAfter: [Int: Double] = [:]) -> [Word] {
    var t = start
    return text.split(separator: " ").enumerated().map { i, w in
        defer { t += 0.25 + (pauseAfter[i] ?? 0) }
        return Word(String(w), t, t + 0.25)
    }
}

let fixtureScript = Script(lines: ["Ti hanno detto che un sito è sicuro.",
                                   "Mercoledì scorso erano al sicuro quelli che non avevano niente.",
                                   "Due falle da 9,2 su 10."])
/// Line 1 once; line 2 restarted after three words, then read fully with a 1 s pause; line 3 with digits.
let fixtureWords = spoken("Ti hanno detto che un sito è sicuro.", at: 1.0)
    + spoken("Mercoledì scorso erano", at: 4.0)
    + spoken("Mercoledì scorso erano al sicuro quelli che non avevano niente.", at: 6.0, pauseAfter: [5: 1.0])
    + spoken("Due falle da 9,2 su 10.", at: 10.5)
/// Where the fixture's voice is loud.
let fixtureSpeech = [(1.0, 3.0), (4.0, 4.75), (6.0, 7.5), (8.5, 9.5), (10.5, 12.0)]

@Test func takeFinderFindsRestartsAndPicksTheLastCompleteTake() {
    let set = TakeFinder.find(script: fixtureScript, words: fixtureWords, envelope: nil, assetID: "a1")
    #expect(set.lines.map(\.takes.count) == [1, 2, 1])
    let l2 = set.lines[1]
    #expect(l2.takes[0].complete == false && l2.takes[0].toEnd == false && l2.takes[0].fromStart)
    #expect(l2.takes[1].complete && l2.takes[1].wer == 0 && l2.takes[1].coverage == 1)
    #expect(l2.auto == 1 && l2.chosen == 1)
    // The 1 s pause is cut out: two parts, padded 0.12 s on each side of the pause.
    let parts = l2.takes[1].parts
    #expect(parts.count == 2)
    #expect(parts[0].start == MediaTime(seconds: 5.9) && parts[0].end == MediaTime(seconds: 7.62))
    #expect(parts[1].start == MediaTime(seconds: 8.38) && parts[1].end == MediaTime(seconds: 9.7))
    #expect(parts[1].note == "pause 1.00s removed")
    #expect(l2.takes[1].longPauses == [[7.5, 8.5]])
    // "9,2" is one word but three script tokens (nove virgola due).
    #expect(set.lines[2].takes[0].complete && set.lines[2].takes[0].wer == 0)
    #expect(set.segments().map(\.line) == [1, 2, 2, 3])
}

@Test func takeFinderFallsBackToTheBestCoveredTake() {
    let words = spoken("Ti hanno detto", at: 1) + spoken("Ti hanno detto che un sito", at: 3)
    let set = TakeFinder.find(script: fixtureScript, words: words, envelope: nil, assetID: "a1")
    #expect(set.lines[0].takes.count == 2)
    #expect(set.lines[0].takes.allSatisfy { !$0.complete })
    #expect(set.lines[0].auto == 1)
    #expect(set.lines[1].auto == nil && set.lines[2].takes.isEmpty)
}

@Test func takeCutsSnapToSpeechOnTheEnvelope() {
    let env = Envelope(samples: syntheticSpeech([(0.9, 3.05)], duration: 4).samples, sampleRate: 16000)
    let set = TakeFinder.find(script: Script(lines: [fixtureScript.lines[0]]), words: spoken("Ti hanno detto che un sito è sicuro.", at: 1.0),
                              envelope: env, assetID: "a1")
    let part = set.lines[0].takes[0].parts[0]
    #expect(abs(part.start.seconds - 0.8) < 0.011)   // onset 0.90 − 0.10
    #expect(abs(part.end.seconds - 3.25) < 0.011)    // offset 3.05 + 0.20
}

@Test func segmentsNeverRunIntoTheNextSpeech() {
    let r = { (a: Double, b: Double) in CutRange(start: MediaTime(seconds: a), end: MediaTime(seconds: b), note: "") }
    let take = { (parts: [CutRange]) in
        Take(start: parts[0].start, end: parts.last!.end, text: "", coverage: 1, wer: 0, substitutions: 0, insertions: 0, deletions: 0,
             fromStart: true, toEnd: true, complete: true, longPauses: [], parts: parts)
    }
    let set = TakeSet(assetID: "a1", options: TakeOptions(), lines: [
        TakeLine(text: "a", takes: [take([r(1, 3.2)])], auto: 0, chosen: 0),
        TakeLine(text: "b", takes: [take([r(3.0, 5)])], auto: 0, chosen: 0),
    ])
    #expect(set.segments().map(\.range.end) == [MediaTime(seconds: 3.0), MediaTime(seconds: 5)])
}

/// Engine with the fixture transcript, its synthetic audio, script and takes.
func takesEngine() throws -> Engine {
    var fakes = FakeServices()
    fakes.words = fixtureWords
    fakes.audio.speech = syntheticSpeech(fixtureSpeech, duration: 13)
    let e = try analysisEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("script.set", params: ["text": .string(fixtureScript.lines.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))])
    return e
}

@Test func takesCommandsListAndSelect() throws {
    let e = try takesEngine()
    #expect(throws: CommandError.self) { try e.execute("takes.select", params: ["line": 2, "take": 1]) }
    let list = try e.checkUndoRedo("takes.list", [:])
    #expect(list.value(at: "lines.1.takes")?.arrayValue?.count == 2)
    #expect(list.value(at: "lines.1.chosenLabel") == "2/2")
    #expect(list["read"] == 3)
    #expect(abs((list.value(at: "lines.0.takes.0.parts.0.in")?.doubleValue ?? 0) - 0.9) < 0.011)
    try e.checkUndoRedo("takes.select", ["line": 2, "take": 1])
    #expect(e.project?.takes?.lines[1].chosen == 0)
    #expect(throws: CommandError.self) { try e.execute("takes.select", params: ["line": 2, "take": 3]) }
    #expect(throws: CommandError.self) { try e.execute("takes.select", params: ["line": 4, "take": 1]) }
    try e.execute("takes.select", params: ["line": 2, "auto": true])
    #expect(e.project?.takes?.lines[1].chosen == 1)
    // A new script invalidates the takes.
    try e.execute("script.set", params: ["text": "Altro testo."])
    #expect(e.project?.takes == nil)
}

@Test func autoCutBuildsFrameSnappedTracksWithOrdinaryCommands() throws {
    let e = try takesEngine()
    try e.execute("takes.list")
    let dry = try e.execute("edit.autoCut", params: ["dryRun": true])
    #expect(e.project?.tracks.isEmpty == true)
    let r = try e.checkUndoRedo("edit.autoCut", [:])
    #expect(r["commands"] == dry["commands"])
    let commands = r["commands"]?.arrayValue?.compactMap { $0["command"]?.stringValue } ?? []
    #expect(commands == ["track.add", "track.add"] + Array(repeating: "timeline.place", count: 8) + ["clip.set"])
    // One undo step for the whole cut.
    try e.execute("history.undo")
    #expect(e.project?.tracks.isEmpty == true)
    try e.execute("history.redo")

    let v = e.clips(0), a = e.clips(1)
    #expect(v.count == 4)
    #expect(v.map(\.sourceIn) == a.map(\.sourceIn) && v.map(\.sourceOut) == a.map(\.sourceOut) && v.map(\.start) == a.map(\.start))
    let frame = MediaTime.frameDuration(at: Rational(30)).ticks
    #expect(v.allSatisfy { $0.sourceIn.ticks % frame == 0 && $0.sourceOut.ticks % frame == 0 && $0.start.ticks % frame == 0 })
    for k in v.indices.dropFirst() { #expect(v[k].start == v[k - 1].end) }   // butt joins, no gaps
    // Picture and sound of each range are linked; the sound has 15 ms edge fades.
    #expect(zip(v, a).allSatisfy { $0.link != nil && $0.link == $1.link } && Set(v.map(\.link)).count == 4)
    #expect(a.allSatisfy { $0.fadeIn == t(0.015) && $0.fadeOut == t(0.015) } && v.allSatisfy { $0.fadeIn == nil })
    #expect(abs(v[0].sourceIn.seconds - 0.9) < 0.02 && abs(v[0].sourceOut.seconds - 3.2) < 0.02)
    #expect(abs(v[1].sourceIn.seconds - 5.9) < 0.02 && abs(v[2].sourceOut.seconds - 9.7) < 0.02)

    // Again: refused on full tracks unless replace.
    #expect(throws: CommandError.self) { try e.execute("edit.autoCut") }
    try e.execute("takes.select", params: ["line": 2, "take": 1])
    let again = try e.execute("edit.autoCut", params: ["replace": true])
    #expect(again["commands"]?.arrayValue?.first?["command"] == "timeline.delete")
    #expect(e.clips(0).count == 3)
    #expect(abs(e.clips(0)[1].sourceIn.seconds - 3.9) < 0.02)
}

@Test func takesCompareAgainstAHandEdit() throws {
    let e = try takesEngine()
    try e.execute("takes.list")
    try e.execute("edit.autoCut")
    let reference = tempDir().appendingPathComponent("segments.json")
    try Data(#"""
    {"segments": [
      {"in": 0.95, "out": 3.25, "line": 1},
      {"in": 5.88, "out": 7.6, "line": 2},
      {"in": 8.4, "out": 12.15, "line": "2-3"}
    ]}
    """#.utf8).write(to: reference)
    let r = try e.execute("takes.compare", params: ["reference": .string(reference.path)])
    #expect(r.value(at: "summary.lines") == 3)
    #expect(r.value(at: "summary.sameTake") == 3)
    #expect(r.value(at: "summary.boundaries") == 4)   // line 2 out and line 3 in sit inside the "2-3" segment
    #expect(r.value(at: "lines.1.outErrMs") == .null)
    #expect((r.value(at: "summary.maxAbsErrMs")?.doubleValue ?? 999) <= 60)
    try e.execute("takes.select", params: ["line": 2, "take": 1])
    try e.execute("edit.autoCut", params: ["replace": true])
    let wrong = try e.execute("takes.compare", params: ["reference": .string(reference.path)])
    #expect(wrong.value(at: "summary.sameTake") == 2)
    #expect(wrong.value(at: "lines.1.manualTake") == "2/2" && wrong.value(at: "lines.1.autoTake") == "1/2")
}

/// edit.autoCut picks (E5 #4): another take and the cut that uses it in one command, one undo step; bad picks fail.
@Test func autoCutAppliesPicksAsOneStep() throws {
    let e = try takesEngine()
    try e.execute("takes.list")
    try e.execute("edit.autoCut")
    #expect(e.project?.takes?.lines[1].chosen == 1)
    let before = e.clips(0).map(\.sourceIn)
    try e.checkUndoRedo("edit.autoCut", ["replace": true, "picks": [["line": 2, "take": 1]]])
    #expect(e.project?.takes?.lines[1].chosen == 0)
    #expect(e.clips(0).map(\.sourceIn) != before)                       // the cut uses the other take
    #expect(throws: CommandError.self) { try e.execute("edit.autoCut", params: ["replace": true, "picks": [["line": 2, "take": 3]]]) }
    #expect(throws: CommandError.self) { try e.execute("edit.autoCut", params: ["replace": true, "picks": [["line": 9, "take": 1]]]) }
    #expect(e.project?.takes?.lines[1].chosen == 0)                      // a failed command changes nothing
}
