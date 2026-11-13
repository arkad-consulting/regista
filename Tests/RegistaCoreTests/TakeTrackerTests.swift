import Foundation
import Testing
@testable import RegistaCore

private let prepared = """
1. Ti hanno detto che un sito / è *sicuro*
se lo tieni *aggiornato*.

2. Mercoledì scorso / erano al sicuro
quelli che non avevano niente da aggiornare.

3. PHP, / il motore sotto ogni sito WordPress,
ha chiuso d'urgenza / due falle da *nove virgola due* su dieci.

4. Se ci metti più di un minuto a rispondere, / il sito lavora per WordPress, non per te.
"""

/// A synthetic speaker: the recognizer's hypothesis grows by `burst` words, each word 0.3 s long,
/// reported 0.2 s after it ends.
private struct Speaker {
    var tracker: TakeTracker
    var words: [HeardWord] = []
    var t = 0.0
    var events: [TakeTracker.Event] = []
    var withTimes = true

    init(_ script: String = prepared, commands: VoiceCommandSet = .italian) {
        tracker = TakeTracker(script: PromptScript(script), commands: commands)
    }

    mutating func say(_ text: String, burst: Int = 1) {
        let new = text.split(separator: " ").map(String.init)
        var i = 0
        while i < new.count {
            for w in new[i..<min(i + burst, new.count)] {
                words.append(HeardWord(w, start: withTimes ? t : nil, end: withTimes ? t + 0.25 : nil))
                t += 0.3
            }
            i += burst
            events += tracker.update(words, epoch: 0, now: t + 0.2)
        }
    }

    mutating func pause(_ s: Double) { t += s }

    var restarts: [Int] {
        events.compactMap { if case .restart(let s) = $0 { return s } else { return nil } }
    }

    func start(of sentence: Int) -> Int { tracker.script.sentences[sentence].tokens.lowerBound }
}

private func line(_ n: Int) -> String {
    Script.parse(prepared).lines[n - 1].replacingOccurrences(of: ",", with: "").replacingOccurrences(of: ".", with: "")
}

// MARK: PromptScript

@Test func promptScriptParsesSentencesLinesBreathsAndKeywords() {
    let p = PromptScript(prepared)
    #expect(p.sentences.count == 4)
    #expect(p.sentences[0].text == "Ti hanno detto che un sito è sicuro se lo tieni aggiornato.")
    #expect(p.sentences[0].lines == ["Ti hanno detto che un sito / è *sicuro*", "se lo tieni *aggiornato*."])
    #expect(p.keywords == ["sicuro", "aggiornato", "nove virgola due"])
    let ns = p.display as NSString
    #expect(Set(p.keywordTokens.map { ns.substring(with: p.tokens[$0].range) }) == ["sicuro", "aggiornato", "nove", "virgola", "due"])
    // Breath marks are drawn, never read; display lines stay inside the sentence's paragraph.
    #expect(p.breathRanges.count == 5)
    #expect(p.breathRanges.allSatisfy { ns.substring(with: $0) == PromptScript.breathGlyph })
    #expect(p.display.components(separatedBy: "\n").count == 4)
    #expect(p.display.hasPrefix("Ti hanno detto che un sito\u{2002}·\u{2002}è sicuro\u{2028}se lo tieni aggiornato."))
    #expect(p.tokens.map(\.key).prefix(9) == ["ti", "hanno", "detto", "che", "un", "sito", "e", "sicuro", "se"])
    #expect(p.sentences.map(\.tokens) == [0..<12, 12..<24, 24..<43, 43..<60])
    #expect(p.sentence(at: 30) == 2 && p.sentence(at: 999) == 3)
    // Script lines agree with the teleprompter's sentences.
    #expect(Script.parse(prepared).lines == p.sentences.map(\.text))
}

@Test func promptScriptPlainTextAndScriptMd() {
    let plain = PromptScript("Ciao a tutti.\n\nSeconda frase, 24/7.\n# nota")
    #expect(plain.sentences.map(\.text) == ["Ciao a tutti.", "Seconda frase, 24/7."])
    #expect(plain.breathRanges.isEmpty && plain.keywords.isEmpty)
    let md = "# Titolo\n## Testo (una riga = una ripresa)\n\n1. Prima riga.\n2. Seconda\nche continua.\n\nNon fa parte.\n## Hook\n3. No."
    #expect(PromptScript(md).sentences.map(\.text) == ["Prima riga.", "Seconda che continua."])
}

@Test func spelledAndDigitNumbersMatch() {
    #expect(ScriptAligner.keys(of: "9,2") == ["nove", "virgola", "due"])
    #expect(ScriptAligner.keys(of: "11.000") == ["undicimila"])
    let tokens = ScriptAligner.tokenize("falle da 9,2 su 10")
    #expect(tokens.map(\.key) == ["falle", "da", "nove", "virgola", "due", "su", "dieci"])
    #expect(tokens[2].range == tokens[4].range)
}

// MARK: Tracking and restarts

@Test func readsSentencesInOrderAndLogsOneTakeEach() {
    var s = Speaker()
    s.say(line(1)); s.pause(0.8)
    s.say(line(2)); s.pause(0.8)
    s.say("PHP il motore sotto ogni sito WordPress ha chiuso d'urgenza due falle da 9,2 su 10")
    #expect(s.restarts.isEmpty)
    #expect(s.tracker.cursor == s.start(of: 3))
    let m = s.tracker.finish()
    #expect(m.map(\.sentence) == [1, 2, 3])
    #expect(m.allSatisfy { $0.take == 1 && $0.complete && $0.fromStart && !$0.discarded })
    #expect(m[0].start == 0 && abs(m[0].end - 3.55) < 1e-9)       // 12 words: last ends at 11 × 0.3 + 0.25
    #expect(abs(m[1].start - 4.4) < 1e-9)                          // after the 0.8 s pause
    #expect(m[1].end < m[2].start)
}

@Test func restartAfterFinishingTheSentenceStartsANewTake() {
    var s = Speaker()
    s.say(line(1))
    s.say(line(2))
    s.say("PHP il motore sotto ogni sito WordPress ha chiuso d'urgenza due falle da 9,2 su 10")
    s.pause(1)
    let restartAt = s.t
    s.say("PHP il motore")
    #expect(s.restarts == [2])
    #expect(s.tracker.cursor == s.start(of: 2) + 3)
    s.say("sotto ogni sito WordPress ha chiuso d'urgenza due falle da 9,2 su 10")
    let m = s.tracker.finish().filter { $0.sentence == 3 }
    #expect(m.count == 2)
    #expect(m.map(\.take) == [1, 2] && m.allSatisfy(\.complete))
    #expect(abs(m[1].start - restartAt) < 1e-9)
    #expect(m[0].end < m[1].start)
}

@Test func partialRestartsOfTheLastSentence() {
    // Line 10 of the test take: complete, then two broken starts, then the good one.
    var s = Speaker()
    s.tracker.jump(toSentence: 3)
    s.say("Se ci metti più di un minuto a rispondere il sito lavora per WordPress non lavora per te")
    s.say("Se ci metti più di un minuto")
    s.say("se ci metti più di un minuto a rispondere il sito lavora per WordPress")
    s.pause(1)
    s.say("Se ci metti più di un minuto a rispondere il sito lavora per WordPress non per te")
    #expect(s.restarts == [3, 3, 3])
    let m = s.tracker.finish()
    #expect(m.map(\.sentence) == [4, 4, 4, 4])
    #expect(m.map(\.complete) == [true, false, false, true])
    #expect(m.map(\.take) == [1, 2, 3, 4])
    #expect(s.tracker.markers.last?.end == s.t - 0.3 + 0.25)
}

@Test func restartDetectedWhenWordsArriveInBursts() {
    var s = Speaker()
    s.tracker.jump(toSentence: 3)
    s.say("Se ci metti più di un minuto a rispondere il sito lavora per", burst: 3)
    s.say("Se ci metti più di un minuto", burst: 4)
    #expect(s.restarts == [3])
    #expect(s.tracker.cursor >= s.start(of: 3) + 4)
}

@Test func repeatedCommonWordsAndSkippedWordsDoNotRestart() {
    var s = Speaker()
    // "il sito" comes back inside line 3, a word is skipped ("ogni"), a short word is misheard.
    s.say(line(1))
    s.say(line(2))
    s.say("PHP il motore sotto sito WordPress ha chiuso d'urgenza il sito due falle da 9,2 su 10")
    #expect(s.restarts.isEmpty)
    let m = s.tracker.finish()
    #expect(m.count == 3)
    #expect(m[2].complete)
}

@Test func twoShortWordsAreNotEnoughForARestart() {
    var s = Speaker()
    s.tracker.jump(toSentence: 3)
    s.say("Se ci metti più di un minuto a rispondere")
    s.say("se ci")        // "se ci" alone: 4 characters
    #expect(s.restarts.isEmpty)
    s.say("metti")
    #expect(s.restarts == [3])
}

@Test func startingWithoutTheFirstWordsIsAnIncompleteTake() {
    var s = Speaker()
    s.say("detto che un sito è sicuro se lo tieni aggiornato")
    let m = s.tracker.finish()
    #expect(m.count == 1)
    #expect(m[0].fromStart == false && m[0].complete == false)
}

@Test func splitNumbersAndAcronymsAreGluedBack() {
    let keys = Set(["php", "il", "motore", "nove", "virgola", "due", "e"])
    let words = ["P", "hp", "il", "motore", "9", ",", "2", "e"].map { HeardWord($0) }
    let (k, owner) = TakeTracker.keys(of: words, scriptKeys: keys)
    #expect(k == ["php", "il", "motore", "nove", "virgola", "due", "e"])
    #expect(owner == [0, 2, 3, 4, 4, 4, 7])
    // A restart heard as "P hp il motore" is still a restart.
    var s = Speaker()
    s.say(line(1)); s.say(line(2))
    s.say("PHP il motore sotto ogni sito WordPress ha chiuso d'urgenza due falle da 9 , 2 su 10")
    s.say("P hp il motore")
    #expect(s.restarts == [2])
    #expect(s.tracker.finish().filter { $0.sentence == 3 }.map(\.complete) == [true, false])
}

// MARK: Voice commands and manual control

@Test func redoCommandDiscardsTheTakeAndGoesBack() {
    var s = Speaker()
    s.say(line(1))
    s.say("Mercoledì scorso erano al sicuro quelli")
    s.say("no rifaccio")
    #expect(s.events.contains(.command(.redo)))
    #expect(s.tracker.cursor == s.start(of: 1))
    s.say(line(2))
    let m = s.tracker.finish()
    #expect(m.filter { $0.sentence == 2 }.map(\.discarded) == [true, false])
    #expect(m.filter { $0.sentence == 2 }.map(\.complete) == [false, true])
    // The command fires once, not again on the next hypotheses.
    #expect(s.events.filter { $0 == .command(.redo) }.count == 1)
}

@Test func redoAfterFinishingASentenceRedoesThatSentence() {
    var s = Speaker()
    s.say(line(1))
    s.say("rifaccio")
    #expect(s.tracker.cursor == 0)
    s.say(line(1))
    let m = s.tracker.finish()
    #expect(m.map(\.discarded) == [true, false] && m.map(\.complete) == [false, true])
}

@Test func stopCommandAndCommandWordsInsideTheScript() {
    var s = Speaker("1. Diciamo stop agli abbonamenti.\n2. Fine.")
    s.say("Diciamo stop agli abbonamenti")
    #expect(!s.events.contains(.command(.stop)))
    s.say("stop")
    #expect(s.events.contains(.command(.stop)))
    var f = Speaker(commands: .defaults(language: "fr-FR"))
    f.say("Ti hanno detto je recommence")
    #expect(f.events.contains(.command(.redo)))
    #expect(VoiceCommandSet.defaults(language: nil) == .italian)
    // R1 (#50): the teleprompter follows English and Portuguese too, each with its own spoken commands.
    #expect(VoiceCommandSet.defaults(language: "en") == .english && VoiceCommandSet.defaults(language: "pt-BR") == .portuguese)
    var pt = Speaker(commands: .defaults(language: "pt"))
    pt.say("Eu disse vou refazer")
    #expect(pt.events.contains(.command(.redo)))
    #expect(VoiceCommandSet.italian.match(["la", "rifaccio"])! == (VoiceCommand.redo, 2))
}

@Test func pedalRestartAndSentenceJumps() {
    var s = Speaker()
    s.say("Ti hanno detto che un sito")
    let events = s.tracker.restart(discard: false, at: s.t)
    #expect(events.contains(.restart(sentence: 0)))
    #expect(s.tracker.cursor == 0)
    #expect(s.tracker.markers.count == 1 && !s.tracker.markers[0].complete && !s.tracker.markers[0].discarded)
    s.tracker.jump(toSentence: 2)
    #expect(s.tracker.cursor == s.start(of: 2))
    s.tracker.jump(toSentence: 99)
    #expect(s.tracker.cursor == s.start(of: 3))
}

@Test func recognizerWithoutWordTimesUsesArrivalTime() {
    var s = Speaker()
    s.withTimes = false
    s.say(line(1))
    let m = s.tracker.finish()
    // First word reported at 0.3 + 0.2, minus the assumed latency.
    #expect(abs(m[0].start - (0.5 - 0.35)) < 1e-9)
    #expect(m[0].complete)
}

@Test func newRecognitionEpochKeepsThePosition() {
    var s = Speaker()
    s.say(line(1))
    let cursor = s.tracker.cursor
    // The recognizer restarted its task: the hypothesis starts over.
    s.words = []
    s.events += s.tracker.update([HeardWord("Mercoledì", start: s.t, end: s.t + 0.2)], epoch: 1, now: s.t + 0.4)
    #expect(s.tracker.cursor == cursor)
    s.words = [HeardWord("Mercoledì", start: s.t, end: s.t + 0.2)]
    s.t += 0.3
    s.tracker.update([], epoch: 1, now: s.t)
    var words = s.words
    for w in "scorso erano al sicuro".split(separator: " ") {
        words.append(HeardWord(String(w), start: s.t, end: s.t + 0.25))
        s.t += 0.3
        s.tracker.update(words, epoch: 1, now: s.t)
    }
    #expect(s.tracker.cursor == s.start(of: 1) + 5)
}

@Test func revisedHypothesesKeepWhenWordsWereFirstHeard() {
    let old = ["ti", "hanno", "detto", "che", "un"].map { HeardWord($0) }
    let seen = [1.0, 1.3, 1.6, 1.9, 2.2]
    // The recognizer inserts a word and revises the tail.
    let new = ["ti", "hanno", "detto", "che", "è", "un", "sito"].map { HeardWord($0) }
    #expect(TakeTracker.carryFirstSeen(old: old, seen: seen, new: new, now: 3) == [1.0, 1.3, 1.6, 1.9, 3, 2.2, 3])
    #expect(TakeTracker.carryFirstSeen(old: [], seen: [], new: new.prefix(2).map { $0 }, now: 5) == [5, 5])
}

// MARK: Pace

@Test func paceMeterMeasuresWordsPerMinuteWithoutPauses() {
    var p = PaceMeter()
    var t = 0.0
    for _ in 0..<20 { t += 0.375; p.record(at: t, words: 1) }      // 160 wpm
    #expect(abs((p.wordsPerMinute(at: t) ?? 0) - 160) < 0.5)
    #expect(PaceMeter.band(160) == .good)
    // A long breath does not make the pace look slow.
    t += 3
    for _ in 0..<4 { t += 0.375; p.record(at: t, words: 1) }
    #expect((p.wordsPerMinute(at: t) ?? 0) > 140)
    #expect(p.wordsPerMinute(at: t + 5) == nil)
    var slow = PaceMeter()
    t = 0
    for _ in 0..<12 { t += 0.6; slow.record(at: t, words: 1) }     // 100 wpm
    #expect(PaceMeter.band(slow.wordsPerMinute(at: t)!) == .slow)
    #expect(PaceMeter.band(200) == .fast)
}

@Test func trackerFeedsThePaceMeter() {
    var s = Speaker()
    s.say(line(1))
    s.say(line(2))
    // 0.3 s per word = 200 wpm, read by the cursor.
    let wpm = s.tracker.pace.wordsPerMinute(at: s.t)
    #expect(wpm != nil && abs(wpm! - 200) < 20)
}
