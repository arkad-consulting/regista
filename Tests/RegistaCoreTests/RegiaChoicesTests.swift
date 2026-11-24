import Foundation
import Testing
@testable import RegistaCore

// One regia (step 3): one place answers what this person wants for this project — the kind's sheet over "For every video"
// over the default, the project's own choices on top.

/// A talking-head reel project on fakes, its own rule sheets in a scratch folder: the take transcribed («uno due», a 1 s
/// pause, «tre quattro») and its script.
private func regiaEngine(_ fakes: FakeServices = FakeServices()) throws -> Engine {
    var services = fakes.make()
    services.renderer = FakeRenderer()
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "regia", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("script.set", params: ["text": "uno due tre quattro"])
    try e.execute("project.setKind", params: ["kind": "talking-head-reel"])
    return e
}

/// The kind's sheet (the person's copy, in the engine's scratch rules folder) says `choices`.
private func kindSays(_ e: Engine, _ choices: JSONValue) throws {
    try e.execute("rules.set", params: ["kind": "talking-head-reel", "choices": choices])
}

@Test func onePlaceResolvesTheKindOverEveryVideoOverTheDefaultWithTheProjectOnTop() throws {
    let e = try regiaEngine()
    let book = e.context.services.rules
    #expect(ProjectChoices(e.project, book: book).value("pace") == "normal")
    try e.execute("rules.set", params: ["kind": "every-video", "choices": ["pace": "calm", "captions": "elegant-serif"]])
    try kindSays(e, ["pace": "fast"])
    var c = ProjectChoices(e.project, book: book)
    #expect(c.kind == "talking-head-reel")
    #expect(c.value("pace") == "fast" && c.value("captions") == "elegant-serif" && c.value("sfx") == "sparse")
    #expect(c.pace.maxPause == 0.4 && c.pace.keepPause == 0.06 && !c.differs("pace"))
    // A choice that is not one of the kind's still resolves (the voice-over's sound without a face).
    #expect(c.value("faceless-sound") == "directed")
    // The project's own choices on top; an option that does not exist is left out.
    var p = try #require(e.project)
    p.choices = ["pace": ChoiceOverride(value: "calm"), "framing": ChoiceOverride(value: "still", number: [1.3]), "music": ChoiceOverride(value: "loud")]
    c = ProjectChoices(p, book: book)
    #expect(c.value("pace") == "calm" && c.regiaValue("pace") == "fast" && c.differs("pace"))
    #expect(c.value("framing") == "still" && c.number("framing") == [1.3] && c.regiaNumber("framing") == [1.15] && c.differs("framing"))
    #expect(c.value("music") == "on-request" && !c.differs("music"))
    p.choices = ["pace": ChoiceOverride(value: "fast")]
    #expect(!ProjectChoices(p, book: book).differs("pace"), "the same option as the regia is no difference")
    // Without a rule book (a render's sample data): the defaults stand for the regia.
    #expect(ProjectChoices(nil, book: nil).value("captions") == "talking-head-v1")
    // The cut presets before the choices map to their pace.
    #expect(ProjectChoices.pace(maxPause: 1.0, keepPause: 0.2) == "calm" && ProjectChoices.pace(maxPause: 0.7, keepPause: 0.12) == "normal")
    #expect(ProjectChoices.pace(maxPause: 0.4, keepPause: 0.06) == "fast" && ProjectChoices.pace(maxPause: 1.2, keepPause: 0.25) == "calm")
    #expect(ProjectChoices.pace(maxPause: 0.9, keepPause: 0.2) == nil)
    // A project file from before the field reads the same.
    #expect(try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(Project(name: "old"))).choices == nil)
}
