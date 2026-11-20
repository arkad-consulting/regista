import Foundation
import Testing
@testable import RegistaCore

// #59: transcript.fillers lists the candidate filler words of the edit, per language, and changes nothing; its delete
// parameters, sent to transcript.deleteWords, remove them in one undo step.

/// Words of 0.3 s from 1.0 s: "|" between two words is a pause of 0.5 s, otherwise 0.05 s.
private func speech(_ text: String) -> [Word] {
    var t = 1.0, out: [Word] = [], pause = false
    for token in text.split(separator: " ") {
        if token == "|" { pause = true; continue }
        if !out.isEmpty { t += pause ? 0.5 : 0.05 }
        out.append(Word(String(token), t, t + 0.3))
        t += 0.3
        pause = false
    }
    return out
}

/// An engine whose take says `text` in `language`, on a linked picture + sound clip covering it (the sound with
/// edit.autoCut's 15 ms fades).
private func fillersEngine(_ text: String, language: String) throws -> Engine {
    let words = speech(text)
    let e = try analysisEngine(FakeServices(words: words))
    try e.execute("transcript.run", params: ["assetId": "a1", "language": .string(language)])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    let end = words.last!.end.seconds + 0.2
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0.9, "sourceOut": .number(end)])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": 0.9, "sourceOut": .number(end), "linkTo": "c1"])
    try e.execute("clip.set", params: ["trackId": "t2", "fadeIn": 0.015, "fadeOut": 0.015])
    return e
}

private func listed(_ r: JSONValue) -> [String] {
    (r["fillers"]?.arrayValue ?? []).map { "\($0["class"]?.stringValue ?? "?"):\($0["text"]?.stringValue ?? "?")" }
}

/// Per language: the three classes found, and the same words used inside a clause never listed.
@Test(arguments: [
    ("it", "Allora | oggi ehm parliamo di di come il tipo di lavoro cambia | cioè | è tutto allora pronto",
     ["maybe:Allora", "sure:ehm", "repeat:di", "maybe:cioè"], "Allora oggi parliamo di come il tipo di lavoro cambia cioè è tutto allora pronto"),
    ("en", "So | today um we we talk about what I like | you know | so this is like the best",
     ["maybe:So", "sure:um", "repeat:we", "maybe:you know"], "So today we talk about what I like you know so this is like the best"),
    ("fr", "Bon | alors euh nous nous sommes là du coup | du coup | on fait le le bon travail",
     ["maybe:Bon", "sure:euh", "maybe:du coup", "repeat:le"], "Bon alors nous nous sommes là du coup du coup on fait le bon travail"),
    ("pt", "Então | hã a a gente tipo | né | tipo vai então começar",
     ["maybe:Então", "sure:hã", "repeat:a", "maybe:né"], "Então a gente tipo né tipo vai então começar"),
])
func fillersAreFoundOnlyWhereTheyStandAlone(_ language: String, _ text: String, _ expected: [String], _ withoutSureAndRepeat: String) throws {
    let e = try fillersEngine(text, language: language)
    let before = e.project!
    let r = try e.execute("transcript.fillers")
    #expect(listed(r) == expected, "\(language): \(listed(r))")
    #expect(r["language"] == .string(language))
    #expect(e.project == before, "a query changed the project")
    // Each candidate: index, times and pauses as the timeline has them.
    let tl = try e.execute("transcript.timeline")
    for f in r["fillers"]?.arrayValue ?? [] {
        let i = Int(f["i"]?.doubleValue ?? -1)
        #expect(f["start"] == tl.value(at: "words.\(i).start"), "\(f)")
        #expect((f["pauseBefore"]?.doubleValue ?? -1) >= 0 && (f["pauseAfter"]?.doubleValue ?? -1) >= 0)
    }
    // A sure hesitation 0.05 s from its neighbours: removing it saves its 0.3 s and the 0.05 s after it (to the frame).
    let sure = r.value(at: "seconds.sure")?.doubleValue ?? 0
    #expect(sure > 0.3 && sure < 0.4, "\(r["seconds"] ?? .null)")

    // The delete parameters of sure and repeat replayed: the timeline says the rest, shorter by the seconds announced.
    let duration = e.project!.duration.seconds
    var ranges = (r.value(at: "delete.sure.ranges")?.arrayValue ?? []) + (r.value(at: "delete.repeat.ranges")?.arrayValue ?? [])
    ranges.sort { ($0["from"]?.doubleValue ?? 0) < ($1["from"]?.doubleValue ?? 0) }
    try e.checkUndoRedo("transcript.deleteWords", ["ranges": .array(ranges)])
    #expect(try e.execute("transcript.timeline")["text"] == .string(withoutSureAndRepeat))
    let saved = (r.value(at: "seconds.sure")?.doubleValue ?? 0) + (r.value(at: "seconds.repeat")?.doubleValue ?? 0)
    #expect(abs(duration - e.project!.duration.seconds - saved) < 0.001, "\(duration) − \(e.project!.duration.seconds) ≠ \(saved)")
    // Nothing sure or repeated is left (a maybe word next to a removed hesitation may now stand alone: still the person's call).
    let after = try e.execute("transcript.fillers")
    #expect(after.value(at: "seconds.sure") == 0 && after.value(at: "seconds.repeat") == 0, "\(listed(after))")
    // Every sound piece keeps the 15 ms fades at the new cuts.
    #expect(e.clips(1).count == e.clips(0).count && e.clips(1).allSatisfy { $0.fadeIn == t(0.015) && $0.fadeOut == t(0.015) })
}

/// A maybe word is removed only when named: one range of delete.maybe sent alone takes that word, nothing else.
@Test func aNamedMaybeWordIsTheOnlyOneRemoved() throws {
    let e = try fillersEngine("Allora | oggi parliamo | cioè | di lavoro", language: "it")
    let r = try e.execute("transcript.fillers")
    let maybe = try #require(r.value(at: "delete.maybe.ranges")?.arrayValue)
    #expect(maybe.map { $0["expect"] } == ["Allora", "cioè"])
    try e.execute("transcript.deleteWords", params: ["trackId": "t1", "ranges": [maybe[1]]])
    #expect(try e.execute("transcript.timeline")["text"] == "Allora oggi parliamo di lavoro")
}

/// Hesitations written long («ehmmm», «Euhhh…») are the same hesitation; an unknown language still finds them.
@Test func longHesitationsAndOtherLanguages() throws {
    let e = try fillersEngine("Ehmmm, | oggi mmm parliamo", language: "it")
    #expect(listed(try e.execute("transcript.fillers")) == ["sure:Ehmmm,", "sure:mmm"])
    let es = try fillersEngine("Hola euh mundo", language: "es")
    #expect(listed(try es.execute("transcript.fillers")) == ["sure:euh"])
}

/// A removal inside a caption line takes the word out of the captions too.
@Test func aRemovedFillerLeavesTheCaptions() throws {
    let e = try fillersEngine("Oggi ehm parliamo di lavoro", language: "it")
    try e.execute("captions.generate")
    func text(_ v: JSONValue) throws -> String { String(decoding: try v.data(), as: UTF8.self).lowercased() }
    #expect(try text(e.execute("captions.get")).contains("ehm"))
    let r = try e.execute("transcript.fillers")
    try e.execute("transcript.deleteWords", params: try #require(r.value(at: "delete.sure")))
    let captions = try text(e.execute("captions.get"))
    #expect(!captions.contains("ehm") && captions.contains("parliamo"), "\(captions)")
}

@Test func deleteWordsRefusesMixedOrBadRanges() throws {
    let e = try fillersEngine("uno due tre quattro", language: "it")
    #expect(throws: CommandError.self) { try e.execute("transcript.deleteWords", params: ["from": 1, "ranges": [["from": 2]]]) }
    #expect(throws: CommandError.self) { try e.execute("transcript.deleteWords", params: ["ranges": []]) }
    #expect(throws: CommandError.self) { try e.execute("transcript.deleteWords", params: ["ranges": [["from": 9]]]) }
    #expect(throws: CommandError.self) { try e.execute("transcript.deleteWords", params: ["ranges": [["from": 1, "expect": "tre"]]]) }
    #expect(throws: CommandError.self) { try e.execute("transcript.deleteWords") }
    // Two ranges side by side are one cut.
    try e.execute("transcript.deleteWords", params: ["ranges": [["from": 1], ["from": 2]]])
    #expect(try e.execute("transcript.timeline")["text"] == "uno quattro")
}
