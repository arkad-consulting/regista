import Foundation
import Testing
@testable import RegistaCore

private func words(_ text: String, step: Double = 0.3, pauseAfter: Set<Int> = []) -> [(text: String, start: MediaTime, end: MediaTime)] {
    var at = 0.0
    return text.split(separator: " ").enumerated().map { i, w in
        defer { at += step + (pauseAfter.contains(i) ? 1.0 : 0) }
        return (String(w), t(at), t(at + step * 0.9))
    }
}

@Test func frenchChunksNeverEndOnFunctionWords() {
    let style = CaptionStyle.talkingHeadV1
    // A French test take's opening as whisper.cpp heard it, plus the cases the first agent edit got wrong.
    let text = "Bonjour. Votre entreprise perd du temps entre les tâches répétitives Des outils qui ne communiquent pas, des processus compliqués, du temps et de l'argent perdus. Chez Arkad Consulting, nous créons des solutions digitales pour l'automatisation et l'intégration de vos outils. Je m'appelle Léa et je suis pâtissière."
    let ws = words(text, pauseAfter: [9])   // a pause after "répétitives" (no punctuation there)
    let chunks = CaptionBuilder.build(words: ws, style: style, keywords: [], fixes: [:], language: "fr", pauses: [9])
    let profile = LanguageProfile.french
    for (i, ch) in chunks.enumerated() where ch.closed != true {
        #expect(!profile.isStopWord(ch.words.last!.text), "chunk \(i) \"\(ch.text)\" ends on a function word")
    }
    // The pause ends a sentence: "RÉPÉTITIVES" never shares a chunk with "DES".
    #expect(!chunks.contains { $0.text.contains("RÉPÉTITIVES DES") })
    #expect(chunks.contains { $0.text.hasSuffix("RÉPÉTITIVES") })
    // Elisions stay with the next word.
    #expect(chunks.contains { $0.words.contains { $0.text == "L'ARGENT" } })
    #expect(chunks.contains { $0.words.contains { $0.text == "L'INTÉGRATION" } })
    #expect(chunks.allSatisfy { $0.words.count <= 4 && $0.text.count <= 21 }, "\(chunks.map(\.text))")
    #expect(!chunks.contains { $0.text == "LÉA ET JE" })
    let captions = Captions(style: style, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "", chunks: chunks)
    #expect(CaptionBuilder.stopWordEnds(captions, language: "fr").isEmpty)
    // The same text read as Italian has no French stop list: a French article may end a chunk there.
    let italian = Captions(style: style, keywords: [], fixes: [:], sourceTrack: "t1", sourceSignature: "",
                           chunks: CaptionBuilder.build(words: words("tu la pètes la phrase et des outils"), style: style, keywords: [], fixes: [:], language: "it"))
    #expect(CaptionBuilder.stopWordEnds(italian, language: "fr").count >= 1)
    // A split elision ("l'" + "argent" as two tokens) is glued back.
    let split = CaptionBuilder.build(words: words("de l' argent"), style: style, keywords: [], fixes: [:], language: "fr")
    #expect(split.map(\.text) == ["DE L'ARGENT"])
}

@Test func frenchNumeralsAsDigits() {
    let style = CaptionStyle.talkingHeadV1
    func build(_ s: String) -> [String] {
        CaptionBuilder.build(words: words(s), style: style, keywords: [], fixes: [:], language: "fr").flatMap { $0.words.map(\.text) }
    }
    #expect(build("dix ans d'argent perdu") == ["10", "ANS", "D'ARGENT", "PERDU"])
    #expect(build("neuf virgule deux sur dix") == ["9,2", "SUR", "10"])
    #expect(build("deux mille vingt-cinq") == ["2025"])
    #expect(build("quatre-vingt-dix-neuf euros") == ["99", "EUROS"])
    #expect(build("soixante et onze clients") == ["71", "CLIENTS"])
    #expect(build("onze mille personnes") == ["11\u{00A0}000", "PERSONNES"])
    #expect(build("vingt pour cent") == ["20\u{00A0}%"])
    #expect(build("trois petits enfants") == ["TROIS", "PETITS", "ENFANTS"])
    #expect(build("un livre pour vous") == ["UN", "LIVRE", "POUR", "VOUS"])
    #expect(build("deux trois fois") == ["DEUX", "TROIS", "FOIS"])
    // Digits from the transcriber stay digits; grouping from 10 000.
    #expect(build("10 ans") == ["10", "ANS"])
    #expect(LanguageProfile.french.number(["quatre-vingts"]) == 80 && LanguageProfile.french.number(["deux", "cents"]) == 200)
    #expect(LanguageProfile.french.number(["mille", "trois", "cent", "douze"]) == 1312)
    #expect(LanguageProfile.english.number(["one", "hundred", "and", "five"]) == 105)
    #expect(LanguageProfile.portuguese.number(["vinte", "e", "cinco"]) == 25)
    #expect(LanguageProfile.portuguese.number(["dois", "e", "três"]) == nil)
    // English and Portuguese go through the same rules.
    let en = CaptionBuilder.build(words: words("nine point two out of ten"), style: style, keywords: [], fixes: [:], language: "en")
    #expect(en.flatMap { $0.words.map(\.text) } == ["9.2", "OUT", "OF", "10"])
    let pt = CaptionBuilder.build(words: words("vinte e cinco por cento"), style: style, keywords: [], fixes: [:], language: "pt")
    #expect(pt.flatMap { $0.words.map(\.text) } == ["25%"])
}

@Test func frenchTextNormalisation() {
    #expect(TextNorm.numbersToWords("9,2 sur 10 en 2025, 71 et 80 et 11 000", language: "fr")
            == "neuf virgule deux sur dix en deux mille vingt cinq, soixante et onze et quatre vingts et onze mille")
    #expect(TextNorm.numbersToWords("10 %", language: "fr") == "dix pour cent")
    #expect(TextNorm.tokens("L'intégration à 99 %", language: "fr") == ["l", "integration", "a", "quatre", "vingt", "dix", "neuf", "pour", "cent"])
    // Italian stays the default.
    #expect(TextNorm.numbersToWords("9,2 su 10") == "nove virgola due su dieci")
}

@Test func sentencesWithoutPunctuationSplitAtPauses() {
    let ws: [(text: String, start: Double, end: Double)] = [
        ("bonjour", 0, 0.4), ("votre", 1.2, 1.4), ("entreprise", 1.4, 1.9), ("perd", 1.95, 2.2), ("du", 2.2, 2.3), ("temps", 2.3, 2.6),
        ("des", 3.5, 3.6), ("outils", 3.6, 4.0), ("compliqués.", 4.0, 4.6), ("merci", 4.7, 5.0),
    ]
    let s = SentenceSegmenter.split(ws, pause: 0.6)
    // "bonjour" alone is one word before the pause: it joins the next sentence (minWords 2) — then the pause, then punctuation.
    #expect(s == [0...5, 6...8, 9...9])
    // A run-on longer than maxWords splits at its longest pause.
    let run: [(text: String, start: Double, end: Double)] = (0..<8).map { i in ("w\(i)", Double(i), Double(i) + (i == 4 ? 0.3 : 0.9)) }
    #expect(SentenceSegmenter.split(run, pause: 5, maxWords: 6) == [0...4, 5...7])
}

@Test func scriptFromTranscriptFoldsRepeatedReadings() throws {
    // A take without a script: a false start, a restart of a sentence, then a second voice's line.
    var at = 0.0
    func say(_ s: String, gapAfter: Double = 1.2) -> [Word] {
        let ws = s.split(separator: " ").map { w -> Word in
            defer { at += 0.3 }
            return Word(text: String(w), start: t(at), end: t(at + 0.25))
        }
        at += gapAfter
        return ws
    }
    let words = say("Bonjour.") + say("Votre entreprise") + say("Votre entreprise perd du temps entre les tâches répétitives.")
        + say("Des outils qui ne communiquent pas.") + say("Des outils qui ne communiquent pas, des processus compliqués.")
        + say("Vas-y.") + say("Chez Arkad Consulting nous créons des solutions digitales.")
    let lines = ScriptFromTranscript.lines(words, language: "fr")
    #expect(lines.map(\.text) == ["Bonjour.", "Votre entreprise perd du temps entre les tâches répétitives.",
                                  "Des outils qui ne communiquent pas, des processus compliqués.", "Vas-y.",
                                  "Chez Arkad Consulting nous créons des solutions digitales."])
    #expect(lines.map(\.readings.count) == [1, 2, 2, 1, 1])
    // Without punctuation, pauses segment the sentences.
    at = 0
    let bare = say("votre entreprise perd du temps", gapAfter: 0.8) + say("des outils qui ne communiquent pas", gapAfter: 0.8)
        + say("des outils qui ne communiquent pas des processus compliqués", gapAfter: 0.8)
    let l2 = ScriptFromTranscript.lines(bare, language: "fr")
    #expect(l2.map(\.text) == ["Votre entreprise perd du temps", "Des outils qui ne communiquent pas des processus compliqués"])

    // Through the engine: the script is set, takes.list finds both readings of a line.
    var fakes = FakeServices()
    fakes.words = words
    let e = try analysisEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1", "language": "fr"])
    let dry = try e.execute("script.fromTranscript", params: ["dryRun": true])
    #expect(dry["count"] == 5 && dry["set"] == false && e.project?.script == nil)
    let r = try e.checkUndoRedo("script.fromTranscript", ["drop": [4]])
    #expect(r["count"] == 4 && e.project?.script?.lines.count == 4 && e.project?.script?.lines[3].hasPrefix("Chez") == true)
    #expect(throws: CommandError.self) { try e.execute("script.fromTranscript", params: ["drop": [9]]) }
    let takes = try e.execute("takes.list")
    #expect(takes.value(at: "lines.1.takes")?.arrayValue?.count == 2)
    #expect(takes.value(at: "lines.1.chosen") == 2 && takes["read"] == 4)
}

@Test func quietSecondVoiceIsLevelMatched() {
    // 10 ms envelope: the speaker at −20 dB for 3 s, a second voice at −38 dB (18 dB under) for 1 s, the speaker again.
    var db = [Double](repeating: -80, count: 700)
    for f in 10..<300 { db[f] = -20 }
    for f in 340..<440 { db[f] = -38 }
    for f in 480..<690 { db[f] = -20 + (f % 2 == 0 ? 1 : -1) }
    let env = Envelope(db: db)
    let segs = LevelMatch.segments(env, ranges: [(0, 7)])
    #expect(segs.count == 3)
    let (main, matched) = LevelMatch.match(segs, threshold: 6, cap: 12)
    #expect(abs(main + 20) < 0.5)
    #expect(matched.map(\.gain) == [0, 12, 0])          // 18 dB under: raised toward the speaker, capped at 12 dB
    #expect(abs(matched[1].relative + 18) < 0.5)
    // A segment within 6 dB is left alone; threshold 0 turns matching off.
    #expect(LevelMatch.match([(0, 1, -20), (1, 2, -24), (2, 3, -20)]).segments.map(\.gain) == [0, 0, 0])
    #expect(LevelMatch.match(segs, threshold: 0).segments.allSatisfy { $0.gain == 0 })
    // The gain curve ramps in just before the segment and out just after it, on top of the take gains.
    let curve = LevelMatch.curve(count: 700, rate: 100, ranges: [(0, 7)], rangeGains: [-3], segments: matched)
    #expect(abs(Double(curve[100]) - pow(10, -3.0 / 20)) < 1e-4)
    #expect(abs(Double(curve[400]) - pow(10, 9.0 / 20)) < 1e-4)
    #expect(curve[339] > curve[330] && curve[339] < curve[341])
}
