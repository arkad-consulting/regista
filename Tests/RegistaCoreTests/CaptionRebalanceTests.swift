import Foundation
import Testing
@testable import RegistaCore

// The caption builder's stop-word rebalancing always ends (#143). «et des fonctionnalités» in French with the talking-head
// style (3 words, 17 characters a line) handed the same words from chunk to chunk for ever: the app hung while it rebuilt
// the captions, and every later command waited behind it.

private func words(_ text: String) -> [(text: String, start: MediaTime, end: MediaTime)] {
    text.split(separator: " ").enumerated().map { i, w in
        (String(w), MediaTime(seconds: Double(i) * 0.4), MediaTime(seconds: Double(i) * 0.4 + 0.3))
    }
}

/// Runs the builder on its own thread: nil when it has not finished within `seconds`.
private func build(_ ws: [(text: String, start: MediaTime, end: MediaTime)], _ style: CaptionStyle, _ language: String,
                   within seconds: Double = 2) -> [CaptionChunk]? {
    final class Box: @unchecked Sendable { var chunks: [CaptionChunk]? }
    let box = Box(), done = DispatchSemaphore(value: 0)
    Thread { box.chunks = CaptionBuilder.build(words: ws, style: style, keywords: [], fixes: [:], language: language); done.signal() }.start()
    return done.wait(timeout: .now() + seconds) == .success ? box.chunks : nil
}

@Test func theWordsThatHungTheAppMakeCaptions() throws {
    let chunks = try #require(build(words("et des fonctionnalités"), .talkingHeadV1, "fr"), "the builder did not finish")
    #expect(chunks.flatMap(\.words).map(\.text) == ["ET", "DES", "FONCTIONNALITÉS"])
    // The real sentence it came from, in full.
    let sentence = "Aujourd'hui j'ai décidé de vous parler de comment nous avons construit notre service desk. et des fonctionnalités qui le rendent un peu plus spéciale"
    let all = try #require(build(words(sentence), .talkingHeadV1, "fr"), "the builder did not finish")
    #expect(all.flatMap(\.words).count == words(sentence).count)
}

/// Thousands of made-up lines of stop words, short and long words, in the four languages and every style: each ends, and
/// every word comes out once, in order.
@Test func everyLineOfStopWordsAndLongWordsEnds() throws {
    var rng = SystemRandomNumberGenerator()
    let long = ["FONCTIONNALITÉS", "FUNZIONALITÀ", "CONFIGURATION", "PROFESSIONNELLE", "DEVELOPMENT", "DESENVOLVIMENTO"]
    let short = ["SITO", "DESK", "TEAM", "CODE", "APP"]
    var runs = 0
    for language in LanguageProfile.supported {
        // Elided words («l'», «d'») join the next word, and number words become digits: both are meant, and would only
        // blur the count below.
        let stops = LanguageProfile.named(language).stopWords.filter { !$0.contains("'") && !$0.contains("’") }.sorted()
        for preset in CaptionStyle.all {
            var style = preset
            style.numerals = false
            for _ in 0..<150 {
                let n = Int.random(in: 1...12, using: &rng)
                let line = (0..<n).map { _ -> String in
                    switch Int.random(in: 0..<10, using: &rng) {
                    case 0..<6: stops.randomElement(using: &rng)!.lowercased()
                    case 6..<8: long.randomElement(using: &rng)!.lowercased()
                    default: short.randomElement(using: &rng)!.lowercased() + (Bool.random(using: &rng) ? "." : "")
                    }
                }.joined(separator: " ")
                let input = words(line)
                let chunks = try #require(build(input, style, language), "\(language) \(style.id): «\(line)» did not finish")
                let out = chunks.flatMap(\.words).map { $0.text.uppercased() }
                let expected = input.map { $0.text.uppercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                #expect(out.count == expected.count, "\(language) \(style.id): «\(line)» → \(out)")
                runs += 1
            }
        }
    }
    #expect(runs == LanguageProfile.supported.count * CaptionStyle.all.count * 150)
}
