import Foundation
import Testing
@testable import RegistaCore

private let script = """
Ciao a tutti, oggi vi parlo di come l'intelligenza artificiale può aiutare le piccole imprese.
Prima di tutto c'è un problema: il tempo. Ogni giorno perdiamo ore in attività ripetitive.
Con gli strumenti giusti possiamo automatizzare le email, i preventivi e la contabilità.
Il risultato? Più tempo per i clienti e meno stress per tutti.
Se vuoi saperne di più, scrivimi nei commenti o visita il nostro sito.
"""

/// Simulates the recognizer: the hypothesis grows one word at a time.
private func speak(_ text: String, into aligner: inout ScriptAligner, after previous: [String] = []) -> [String] {
    var heard = previous
    for w in text.split(separator: " ") {
        heard.append(String(w))
        aligner.ingest(heard: heard)
    }
    return heard
}

private func index(of word: String, in aligner: ScriptAligner, occurrence: Int = 1) -> Int {
    var seen = 0
    for (i, t) in aligner.tokens.enumerated() where t.key == word {
        seen += 1
        if seen == occurrence { return i }
    }
    fatalError("word \(word) not in script")
}

@Test func tokenizeKeepsRangesAndSplitsApostrophes() {
    let tokens = ScriptAligner.tokenize("C'è l'intelligenza, perché!")
    #expect(tokens.map(\.key) == ["c", "e", "l", "intelligenza", "perche"])
    let ns = "C'è l'intelligenza, perché!" as NSString
    #expect(ns.substring(with: tokens[3].range) == "intelligenza")
    #expect(ns.substring(with: tokens[4].range) == "perché")
}

@Test func followsReadingInOrder() {
    var a = ScriptAligner(script: script)
    _ = speak("Ciao a tutti oggi vi parlo di come l'intelligenza artificiale", into: &a)
    #expect(a.cursor == index(of: "artificiale", in: a) + 1)
    #expect(a.state == .onScript)
}

@Test func stopsWhenGoingOffScriptAndResumes() {
    var a = ScriptAligner(script: script)
    var heard = speak("Ciao a tutti oggi vi parlo di come", into: &a)
    let before = a.cursor
    heard = speak("scusate un attimo mi è squillato il telefono aspettate", into: &a, after: heard)
    #expect(a.state == .offScript)
    #expect(a.cursor == before)
    _ = speak("l'intelligenza artificiale può aiutare", into: &a, after: heard)
    #expect(a.state == .onScript)
    #expect(a.cursor == index(of: "aiutare", in: a) + 1)
}

@Test func reanchorsAfterSkippingAhead() {
    var a = ScriptAligner(script: script)
    let heard = speak("Ciao a tutti oggi vi parlo", into: &a)
    // Skips a whole sentence and continues from "Ogni giorno perdiamo ore".
    _ = speak("ogni giorno perdiamo ore in attività", into: &a, after: heard)
    #expect(a.cursor == index(of: "attivita", in: a) + 1)
}

@Test func toleratesRecognitionErrors() {
    var a = ScriptAligner(script: script)
    // "c'è" heard as "ce", "problema" as "problemi", "ripetitive" as "ripetitivi".
    var heard = speak("Prima di tutto ce un problemi il tempo", into: &a)
    #expect(a.cursor == index(of: "tempo", in: a) + 1)
    heard = speak("ogni giorno perdiamo ore in attività ripetitivi", into: &a, after: heard)
    #expect(a.cursor == index(of: "ripetitive", in: a) + 1)
}

@Test func commonWordsDoNotDragTheCursor() {
    var a = ScriptAligner(script: script)
    let heard = speak("Ciao a tutti oggi vi parlo", into: &a)
    let before = a.cursor
    // A digression made of very common words that also appear in the script.
    _ = speak("e allora di più per il resto", into: &a, after: heard)
    #expect(a.cursor == before)
}

@Test func doesNotJumpBackForRepeatedWords() {
    var a = ScriptAligner(script: script)
    var heard = speak("Ciao a tutti oggi vi parlo di come l'intelligenza artificiale può aiutare le piccole imprese", into: &a)
    heard = speak("Prima di tutto c'è un problema il tempo", into: &a, after: heard)
    let before = a.cursor
    // Repeats two words already read: stays where it is.
    _ = speak("il tempo", into: &a, after: heard)
    #expect(a.cursor == before)
}

@Test func manualJump() {
    var a = ScriptAligner(script: script)
    a.jump(to: 30)
    #expect(a.cursor == 30)
    #expect(a.state == .waiting)
}

@Test func readsWholeScriptToTheEnd() {
    var a = ScriptAligner(script: script)
    let plain = script.replacingOccurrences(of: "\n", with: " ")
    _ = speak(plain, into: &a)
    #expect(a.isFinished)
}
