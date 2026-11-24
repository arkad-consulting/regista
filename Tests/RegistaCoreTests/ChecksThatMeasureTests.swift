import Foundation
import Testing
@testable import RegistaCore

// The checks that measure (#145): reading time and text in frame, the «always» measures inside rules.check, the faceless
// reel's still stretches, jump cuts and the voice read back. Every engine is a stand-in: the fakes' audio toolkit and
// transcription, a frame sampler that hands synthetic frames, a render file that is an empty scratch file.

/// An engine on fakes with the 6 s take on V1 (a 1080×1920 reel: the talking-head kind) and the compositor stand-in.
private func measuringEngine(_ fakes: FakeServices = FakeServices(), configure: (inout EngineServices) -> Void = { _ in }) throws -> Engine {
    var services = fakes.make()
    services.renderer = FakeRenderer()
    configure(&services)
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "measures", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 6])
    return e
}

private func violations(_ check: JSONValue, _ id: String) -> [JSONValue] {
    check["violations"]?.arrayValue?.filter { $0["check"]?.stringValue == id } ?? []
}

private func row(_ check: JSONValue, _ id: String) -> JSONValue? {
    check["checks"]?.arrayValue?.first { $0["id"]?.stringValue == id }
}

// MARK: 1. Reading time and text in frame

@Test func theReadingTimeIsTheBasePlusTheLettersAndShortTextsAreExempt() throws {
    // 12 words, 40 letters: 0.6 + 40 / 12 = 3.93 s.
    let title = "Ecco tre modi per\nfare un reel che\nsi fa notare ora"
    #expect(title.split(whereSeparator: \.isWhitespace).count == 12)
    #expect(abs((RuleCheck.readingSeconds(title) ?? 0) - (0.6 + 40.0 / 12)) < 1e-9)
    // A dense script reads 6 characters a second.
    #expect(abs((RuleCheck.readingSeconds("今日は三つのこと") ?? 0) - (0.6 + 8.0 / 6)) < 1e-9)
    #expect(RuleCheck.readingSeconds("3") == nil && RuleCheck.readingSeconds("🔥") == nil && RuleCheck.readingSeconds("OK") == nil)
    #expect(RuleCheck.readingSeconds("WOW") != nil)
}

@Test func aTitleShownTooBrieflyFailsWithTheSecondsMissingAndAFixThatLengthensIt() throws {
    let e = try measuringEngine()
    let title = "Ecco tre modi per\nfare un reel che\nsi fa notare ora"
    let added = try e.execute("title.add", params: ["text": .string(title), "start": 1, "duration": 1.5])
    let id = try #require(added.value(at: "clip.id")?.stringValue)
    let check = try e.execute("rules.check", params: ["language": "en"])
    let v = try #require(violations(check, "reading-time").first, "\(check)")
    #expect(check["pass"] == false && v["severity"] == "fail" && v["clipId"]?.stringValue == id)
    #expect(v.value(at: "messageArgs.1") == 1.5 && v.value(at: "messageArgs.2") == 3.93 && v.value(at: "messageArgs.3") == 2.43, "\(v)")
    #expect(v.value(at: "fix.command") == "timeline.trim" && v.value(at: "fix.params.edge") == "end")
    let to = try #require(v.value(at: "fix.params.to")?.doubleValue)
    #expect(to >= 1 + 3.9333 - 1e-6 && to < 1 + 3.9333 + 1.0 / 30 + 1e-6, "the fix does not end it on the frame after the time needed: \(to)")
    // rules.fix lengthens it in one undo step; then it passes.
    let fixed = try e.checkUndoRedo("rules.fix", ["check": "reading-time"])
    #expect(violations(fixed["check"] ?? [:], "reading-time").isEmpty, "\(fixed)")
}

@Test func aTitleShownFourSecondsPassesAndOneWithNoRoomAfterItHasNoFix() throws {
    let e = try measuringEngine()
    let title = "Ecco tre modi per\nfare un reel che\nsi fa notare ora"
    try e.execute("title.add", params: ["text": .string(title), "start": 1, "duration": 4])
    let passing = try e.execute("rules.check", params: ["language": "en"])
    #expect(violations(passing, "reading-time").isEmpty, "\(violations(passing, "reading-time"))")
    try e.execute("history.undo")
    // Ending with the video: nothing to lengthen into, the text is too long.
    try e.execute("title.add", params: ["text": .string(title), "start": 4.5, "duration": 1.5])
    let v = try #require(violations(try e.execute("rules.check", params: ["language": "en"]), "reading-time").first)
    #expect(v["fix"] == .null && v["message"]?.stringValue?.contains("The text is too long") == true, "\(v)")
}

@Test func aTitleOutOfTheFrameFailsWithoutAFix() throws {
    let e = try measuringEngine()
    // Long enough to be read, its top edge 40 px above the frame.
    try e.execute("title.add", params: ["text": "TRE MODI", "start": 1, "duration": 3, "top": -40])
    let v = try #require(violations(try e.execute("rules.check", params: ["language": "en"]), "reading-time").first)
    #expect(v["messageKey"] == "«%1$@» goes out of the frame by %2$@ px." && v["fix"] == .null, "\(v)")
    #expect((v.value(at: "messageArgs.1")?.doubleValue ?? 0) >= 39)
}

@Test func captionsAreNeverMeasuredAndANumberStickerIsExempt() throws {
    var fakes = FakeServices()
    // A long caption line spoken fast: a caption follows its words, it is not a text to read.
    fakes.words = [Word("supercalifragilistichespiralidoso", 1.0, 1.2), Word("precipitevolissimevolmente", 1.2, 1.4)]
    let e = try measuringEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("captions.generate")
    try e.execute("sticker.add", params: ["emoji": "3", "start": 2, "duration": 0.4])
    let check = try e.execute("rules.check")
    #expect(violations(check, "reading-time").isEmpty, "\(check)")
    #expect(row(check, "reading-time")?["ran"] == true)
}

@Test func aHyperFramesSceneGivesTheTextItShows() {
    let html = "<html><head><title>x</title><style>h1{color:red}</style></head><body><h1>Tre&nbsp;modi</h1><!-- note --><p>per fare &amp; rifare</p><script>var a = 1</script></body></html>"
    #expect(GraphicsHyperframes.visibleText(html) == "Tre modi per fare & rifare")
}
