import Foundation
import Testing
@testable import RegistaCore

private let lines = ["Ti hanno detto che un sito è sicuro.",
                     "Mercoledì scorso erano al sicuro quelli che non avevano niente.",
                     "PHP ha chiuso d'urgenza due falle da 9,2 su 10."]

/// A synthetic session: lines 1 and 2 once, line 3 three times (broken off, broken off with a
/// restart, then complete). Returns the transcript words and the markers a live TakeTracker logged.
private func session() -> (words: [Word], markers: [LiveTakeMarker]) {
    var tracker = TakeTracker(script: PromptScript(lines.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")))
    var heard: [HeardWord] = []
    var words: [Word] = []
    var t = 1.0
    func say(_ text: String, pauseAfter: Double = 0.6) {
        for w in text.split(separator: " ") {
            words.append(Word(String(w), t, t + 0.25))
            heard.append(HeardWord(String(w), start: t, end: t + 0.25))
            t += 0.3
            tracker.update(heard, epoch: 0, now: t + 0.15)
        }
        t += pauseAfter
    }
    say(lines[0])
    say(lines[1])
    say("PHP ha chiuso d'urgenza")             // take 1: stops
    say("PHP ha chiuso d'urgenza due falle")   // take 2: restart, stops again
    say(lines[2])                              // take 3: complete
    return (words, tracker.finish())
}

@Test func liveMarkersForThreeTakesOfTheLastLine() {
    let (_, markers) = session()
    #expect(markers.map(\.sentence) == [1, 2, 3, 3, 3])
    let third = markers.filter { $0.sentence == 3 }
    #expect(third.map(\.take) == [1, 2, 3])
    #expect(third.map(\.complete) == [false, false, true])
    // Each take starts where its first word was spoken and ends with its last word.
    #expect(abs(third[1].start - (third[0].end + 0.05 + 0.6)) < 1e-6)
    #expect(third[0].end < third[1].start && third[1].end < third[2].start)
}

@Test func takesFromMarkersScoreTheReadingsAndPickTheLastComplete() {
    let (words, markers) = session()
    let script = Script(lines: lines)
    let log = LiveTakeLog(sentences: lines, markers: markers)
    #expect(log.matches(script))
    #expect(!log.matches(Script(lines: ["Altro."])))
    let set = TakeFinder.fromMarkers(script: script, log: log, words: words, envelope: nil, assetID: "a1")
    #expect(set.source == "live")
    #expect(set.lines.map(\.takes.count) == [1, 1, 3])
    let l3 = set.lines[2]
    #expect(l3.chosen == 2)
    #expect(l3.takes[2].complete && l3.takes[2].wer == 0 && l3.takes[2].coverage == 1)
    #expect(l3.takes[0].text == "PHP ha chiuso d'urgenza" && l3.takes[0].deletions == 8)
    #expect(l3.takes[1].text == "PHP ha chiuso d'urgenza due falle")
    // Without a transcript the marker times are the cut.
    let bare = TakeFinder.fromMarkers(script: script, log: log, words: nil, envelope: nil, assetID: "a1")
    #expect(bare.lines[2].chosen == 2)
    #expect(bare.lines[2].takes[2].parts[0].start == MediaTime(seconds: max(markers[4].start - 0.1, 0)))
}

@Test func wordErrorsCountSubstitutionsInsertionsDeletions() {
    let (s, i, d, good) = TakeFinder.wordErrors(["ti", "hanno", "dato", "che", "un", "bel", "sito"], ["ti", "hanno", "detto", "che", "un", "sito", "sicuro"])
    #expect((s, i, d, good) == (1, 1, 1, 5))
}

/// Engine with the session's transcript and the markers as the recording's sidecar.
private func liveEngine() throws -> (Engine, [LiveTakeMarker]) {
    let (words, markers) = session()
    var fakes = FakeServices()
    fakes.words = words
    let e = Engine(prober: FakeProber(), services: fakes.make())
    let dir = tempDir()
    try e.execute("project.new", params: ["name": "live", "directory": .string(dir.appendingPathComponent("p").path)])
    let movie = fakeMedia("Registrazione 1.mov", in: dir)
    try LiveTakeLog(sentences: lines, markers: markers, recognizer: "test").write(to: LiveTakeLog.sidecar(for: URL(fileURLWithPath: movie)))
    let r = try e.execute("media.import", params: ["path": .string(movie)])
    #expect(r["liveTakeMarkers"] == 5)
    try e.execute("transcript.run", params: ["assetId": "a1"])
    return (e, markers)
}

@Test func takesListPrefersLiveMarkersAndAutoCutUsesThem() throws {
    let (e, markers) = try liveEngine()
    #expect(LiveTakeLog.sidecar(for: URL(fileURLWithPath: "/x/Registrazione 1.mov")).lastPathComponent == "Registrazione 1.takes.json")
    try e.execute("script.set", params: ["text": .string(lines.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n"))])
    let list = try e.checkUndoRedo("takes.list", [:])
    #expect(list["source"] == "live")
    #expect(list.value(at: "lines.2.takes")?.arrayValue?.count == 3)
    #expect(list.value(at: "lines.2.chosenLabel") == "3/3")
    let cut = try e.execute("edit.autoCut")
    let segs = cut["segments"]?.arrayValue ?? []
    #expect(segs.map { $0["line"] } == [1, 2, 3])
    // Line 3's clip is the third take: it starts just before that take's first word.
    let in3 = segs[2]["sourceIn"]?.doubleValue ?? 0
    #expect(abs(in3 - (markers[4].start - 0.1)) < 0.04)
    // source: transcript ignores the markers (the aligner finds the same three readings here).
    let tr = try e.execute("takes.list", params: ["source": "transcript"])
    #expect(tr["source"] == "transcript")
}

@Test func liveMarkersForAnotherScriptAreIgnored() throws {
    let (e, _) = try liveEngine()
    try e.execute("script.set", params: ["text": "1. Ti hanno detto che un sito è sicuro.\n2. Una riga diversa."])
    let list = try e.execute("takes.list")
    #expect(list["source"] == "transcript")
    #expect(throws: CommandError.self) { try e.execute("takes.list", params: ["source": "live"]) }
}

@Test func takesLiveAttachesAndClearsMarkers() throws {
    let (e, markers) = try liveEngine()
    try e.execute("script.set", params: ["text": .string(lines.joined(separator: "\n"))])
    try e.checkUndoRedo("takes.live", ["clear": true])
    try e.execute("takes.live", params: ["clear": true])
    #expect(e.project?.assets[0].analysis?.liveTakes == nil)
    let file = tempDir().appendingPathComponent("sim.json")
    try LiveTakeLog(sentences: lines, markers: markers).write(to: file)
    let r = try e.execute("takes.live", params: ["path": .string(file.path)])
    #expect(r["markers"] == 5 && r["matchesScript"] == true)
    #expect(r.value(at: "lines.2.takes") == 3)
    #expect(r.value(at: "lines.2.complete") == [3])
}

// MARK: script.prepare / script.set

@Test func prepareMakesShortLinesBreathMarksAndKeywords() {
    let text = "1. PHP, il motore sotto ogni sito WordPress, ha chiuso d'urgenza due falle da nove virgola due su dieci.\n2. Un sito in HTML statico non aveva niente da sistemare."
    let out = PromptScript.prepare(text, keywords: ["nove virgola due", "statico"])
    let p = PromptScript(out)
    #expect(p.sentences.map(\.text) == Script.parse(text).lines)
    #expect(p.sentences.flatMap(\.lines).allSatisfy { PromptScript.plain($0).count <= 32 + 4 })
    #expect(p.sentences.flatMap(\.lines).filter { PromptScript.plain($0).count > 32 }.isEmpty)
    #expect(out.contains("PHP, /"))
    #expect(out.contains("*nove virgola due*"))
    #expect(out.contains("*statico*"))
    #expect(p.keywords == ["nove virgola due", "statico"])
    #expect(out.hasPrefix("1. ") && out.contains("\n\n2. "))
    // Re-preparing keeps the flagged keywords and is stable.
    #expect(PromptScript.prepare(out) == out)
}

@Test func prepareBreaksBeforeFunctionWordsAndPicksKeywordsWhenNoneGiven() {
    let out = PromptScript.prepare("Se ci metti più di un minuto a rispondere il sito lavora per WordPress e non per te.", maxChars: 28)
    let lines = PromptScript(out).sentences[0].lines
    #expect(lines.count >= 3)
    #expect(lines.allSatisfy { PromptScript.plain($0).count <= 28 })
    #expect(out.contains("*WordPress*"))
    // No line is one lonely short word.
    #expect(lines.allSatisfy { PromptScript.plain($0).split(separator: " ").count > 1 })
}

@Test func scriptPrepareAndSetKeepThePromptForTheTeleprompter() throws {
    let e = try analysisEngine()
    let r = try e.checkUndoRedo("script.prepare", ["text": "Ciao a tutti, oggi parliamo di PHP.\nSeconda frase breve.", "keywords": ["PHP"]])
    #expect(r["set"] == true)
    #expect(r["keywords"] == ["PHP"])
    #expect(e.project?.script?.lines == ["Ciao a tutti, oggi parliamo di PHP.", "Seconda frase breve."])
    #expect(e.project?.script?.prompt == r["text"]?.stringValue)
    #expect(e.project?.script?.keywords == ["PHP"])
    let s = try e.execute("script.set", params: ["text": "1. Una *riga* / con pausa.\n2. Due."])
    #expect(s["keywords"] == ["riga"])
    #expect(e.project?.script?.lines == ["Una riga con pausa.", "Due."])
    #expect(e.project?.script?.prompt == "1. Una *riga* / con pausa.\n2. Due.")
    // Without a project it only formats.
    let bare = Engine(prober: FakeProber(), services: FakeServices().make())
    #expect(try bare.execute("script.prepare", params: ["text": "Una riga."])["set"] == false)
}

@Test func captionsUseTheScriptKeywordsWhenGivenNone() throws {
    let e = try analysisEngine()
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0.9, "sourceOut": 4.6])
    try e.execute("script.prepare", params: ["text": "Uno due tre quattro.", "keywords": ["tre"]])
    let r = try e.execute("captions.generate")
    #expect(r["keywordsShown"] == 1)
    #expect(try e.execute("captions.get").value(at: "list.1.words.0.keyword") == true)
}
