import Foundation
import Testing
@testable import RegistaCore

// One regia (step 3): one place answers what this person wants for this project — the kind's sheet over "For every video"
// over the default, the project's own choices on top. The commands a choice decides start from it where a call leaves the
// value out, a value passed still wins, and the result's fromChoices names exactly the choices used.

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

/// A result's fromChoices.
private func used(_ r: JSONValue) -> [String: String] { (r["fromChoices"]?.objectValue ?? [:]).compactMapValues(\.stringValue) }

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

@Test func theProjectsOwnChoicesWinForThisProjectOnlyAsOneUndoStep() throws {
    let e = try regiaEngine()
    let book = e.context.services.rules
    try kindSays(e, ["pace": "fast"])
    let r = try e.checkUndoRedo("project.setChoices", ["choices": ["pace": "calm", "framing": ["value": "still", "number": 1.3]]])
    let c = ProjectChoices(e.project, book: book)
    #expect(c.value("pace") == "calm" && c.regiaValue("pace") == "fast" && c.differs("pace"))
    #expect(c.value("framing") == "still" && c.number("framing") == [1.3])
    let pace = r["choices"]?.arrayValue?.first { $0["id"] == "pace" }
    #expect(pace?["value"] == "calm" && pace?["regia"] == "fast" && pace?["source"] == "project")
    // The commands read them; recipe.get names them for this project.
    #expect(used(try e.execute("takes.list")) == ["pace": "calm"])
    let recipe = try e.execute("recipe.get", params: ["name": "talking-head-reel"])["text"]?.stringValue ?? ""
    #expect(recipe.contains("This project's own choices") && recipe.contains("pace: calm") && recipe.contains("framing: still 1.3"))
    // A number alone keeps the option; reset takes them back to the regia.
    try e.execute("project.setChoices", params: ["choices": ["framing": ["number": 1.2]]])
    #expect(ProjectChoices(e.project, book: book).value("framing") == "still" && ProjectChoices(e.project, book: book).number("framing") == [1.2])
    try e.execute("project.setChoices", params: ["reset": ["pace", "framing"]])
    #expect(e.project?.choices == nil && ProjectChoices(e.project, book: book).value("pace") == "fast")
    // Unknown choices and options are refused with the list; nothing to do is refused too.
    #expect(throws: CommandError.self) { try e.execute("project.setChoices", params: ["choices": ["tempo": "fast"]]) }
    #expect(throws: CommandError.self) { try e.execute("project.setChoices", params: ["choices": ["pace": "slowest"]]) }
    #expect(throws: CommandError.self) { try e.execute("project.setChoices", params: ["reset": ["tempo"]]) }
    #expect(throws: CommandError.self) { try e.execute("project.setChoices") }
}

@Test func theChoiceAndTheEditItMakesAreOneUndoStep() throws {
    let e = try regiaEngine()
    try e.execute("takes.list")
    try e.execute("edit.autoCut")
    let before = e.project
    let r = try e.execute("project.setChoices", params: ["choices": ["pace": "fast"], "then": ["command": "edit.autoCut", "params": ["replace": true]]])
    #expect(used(r["then"] ?? .null) == ["pace": "fast"] && e.project?.takes?.options.maxPause == 0.4)
    try e.execute("history.undo")
    #expect(e.project == before)
    #expect(throws: CommandError.self) { try e.execute("project.setChoices", params: ["choices": ["pace": "fast"], "then": ["command": "project.state"]]) }
    #expect(e.project == before, "a refused then left the choice in")
}

@Test func takesAndTheCutTakeTheirPausesFromThePace() throws {
    let e = try regiaEngine()
    try kindSays(e, ["pace": "fast"])
    let takes = try e.execute("takes.list")
    #expect(used(takes) == ["pace": "fast"] && e.project?.takes?.options.maxPause == 0.4 && e.project?.takes?.options.keepPause == 0.06)
    let fast = try e.execute("edit.autoCut")
    #expect(used(fast) == ["pace": "fast"])
    #expect(fast["segments"]?.arrayValue?.count == 2, "the 1 s pause is cut at the fast pace: \(fast)")
    // A value passed wins and is not reported; one passed alone leaves the other to the choice.
    let calm = try e.execute("edit.autoCut", params: ["replace": true, "maxPause": 1.2, "keepPause": 0.25])
    #expect(used(calm).isEmpty && calm["segments"]?.arrayValue?.count == 1)
    let half = try e.execute("edit.autoCut", params: ["replace": true, "maxPause": 1.2])
    #expect(used(half) == ["pace": "fast"] && e.project?.takes?.options.keepPause == 0.06)
    try kindSays(e, ["pace": "calm"])
    #expect(used(try e.execute("takes.list")) == ["pace": "calm"] && e.project?.takes?.options.maxPause == 1.2)
    #expect(used(try e.execute("takes.list", params: ["maxPause": 0.5, "keepPause": 0.1])).isEmpty)
}

@Test func captionsTakeTheirStyleAndKeywordsFromTheChoices() throws {
    let e = try regiaEngine()
    try e.execute("takes.list")
    try e.execute("edit.autoCut")
    try kindSays(e, ["captions": "none"])
    // «No captions»: a call without a style is refused and says how to caption anyway.
    #expect(throws: CommandError.self) { try e.execute("captions.generate") }
    try kindSays(e, ["captions": "bold-keyword", "keywords": "off"])
    let dry = try e.execute("captions.generate", params: ["dryRun": true])
    #expect(dry["suggestedKeywords"]?.arrayValue == [] && used(dry) == ["captions": "bold-keyword", "keywords": "off"])
    let made = try e.execute("captions.generate")
    #expect(used(made) == ["captions": "bold-keyword", "keywords": "off"])
    #expect(e.project?.tracks.first { $0.captions != nil }?.captions?.style.id == "bold-keyword")
    try kindSays(e, ["keywords": "on"])
    let on = try e.execute("captions.generate", params: ["dryRun": true, "style": "elegant-serif"])
    #expect(used(on) == ["keywords": "on"] && (on["suggestedKeywords"]?.arrayValue?.isEmpty == false))
    // Keywords and a style passed win.
    #expect(used(try e.execute("captions.generate", params: ["style": "ghost-karaoke", "keywords": ["TRE"]])).isEmpty)
    // setStyle: the choice when neither a style nor overrides are given.
    let styled = try e.execute("captions.setStyle")
    #expect(used(styled) == ["captions": "bold-keyword"] && e.project?.tracks.first { $0.captions != nil }?.captions?.style.id == "bold-keyword")
    #expect(used(try e.execute("captions.setStyle", params: ["style": "elegant-serif"])).isEmpty)
    #expect(used(try e.execute("captions.setStyle", params: ["overrides": ["maxWords": 2]])).isEmpty)
    try kindSays(e, ["captions": "none"])
    #expect(throws: CommandError.self) { try e.execute("captions.setStyle") }
}

@Test func punchInsTakeTheirSwitchAndZoomFromTheFraming() throws {
    let e = try regiaEngine()
    try e.execute("faces.track", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    for (start, a) in [(0.0, 0.0), (2.0, 10.0), (4.0, 20.0)] {
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": .number(start), "sourceIn": .number(a), "sourceOut": .number(a + 2)])
    }
    let crops: JSONValue = ["base": [864, 1536, 152, 384], "punch": [760, 1351, 204, 487]]
    func framings(_ r: JSONValue) -> [String] { r["clips"]?.arrayValue?.compactMap { $0["framing"]?.stringValue } ?? [] }
    try kindSays(e, ["framing": "still"])
    var r = try e.execute("edit.punchIns", params: crops)
    #expect(framings(r) == ["base", "base", "base"] && used(r) == ["framing": "still"])
    try kindSays(e, ["framing": "alternate-cut"])
    r = try e.execute("edit.punchIns", params: crops)
    #expect(framings(r) == ["base", "punch", "base"] && used(r) == ["framing": "alternate-cut"])
    // By line without takes: at every clip, and the result says why.
    try kindSays(e, ["framing": "alternate"])
    r = try e.execute("edit.punchIns", params: crops)
    #expect(framings(r) == ["base", "punch", "base"] && used(r) == ["framing": "alternate"] && r["note"] != nil)
    var explicit = crops.objectValue!
    explicit["by"] = "clip"
    #expect(used(try e.execute("edit.punchIns", params: .object(explicit))).isEmpty)
    // The face-aware crops: the punch-in is the choice's number closer than the base.
    try kindSays(e, ["framing": ["value": "alternate-cut", "number": 1.25]])
    r = try e.execute("edit.punchIns")
    #expect(used(r) == ["framing": "alternate-cut 1.25"], "\(r)")
    let heights = (r["clips"]?.arrayValue ?? []).compactMap { $0["crop"]?.arrayValue?[1].doubleValue }
    #expect(heights.count == 3 && abs(heights[0] / heights[1] - 1.25) < 0.02, "\(heights)")
    #expect(used(try e.execute("edit.punchIns", params: ["zoom": [0.8, 0.7], "by": "clip"])).isEmpty)
}

@Test func theColourTouchUpTakesItsDefaultFromTheColourChoice() throws {
    let e = try regiaEngine()
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4])
    let light = try e.checkUndoRedo("look.apply", [:])
    #expect(used(light) == ["colour": "light"] && e.project?.tracks[0].clips.allSatisfy { LightGrade.isOn($0.color) } == true)
    try e.execute("look.apply", params: ["look": "film", "amount": 0.5])
    try kindSays(e, ["colour": "none"])
    let none = try e.execute("look.apply")
    #expect(used(none) == ["colour": "none"] && e.project?.grade?.look == nil)
    #expect(e.project?.tracks[0].clips.contains { LightGrade.isOn($0.color) } == false)
    try kindSays(e, ["colour": "look"])
    #expect(throws: CommandError.self) { try e.execute("look.apply") }   // which look: the call says
    #expect(used(try e.execute("look.apply", params: ["look": "golden"])).isEmpty)
}

@Test func soundEffectsAndMusicFollowTheirChoices() throws {
    let e = try regiaEngine()
    try e.execute("track.add", params: ["kind": "video"])
    for k in 0..<6 {   // cuts every 2 s
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": .number(Double(k) * 2), "sourceIn": .number(Double(k) * 10), "sourceOut": .number(Double(k) * 10 + 2)])
    }
    let sparse = try e.execute("sfx.onCuts")
    #expect(used(sparse) == ["sfx": "sparse"] && sparse["placed"] == 3, "≥ 3 s apart: \(sparse)")
    try kindSays(e, ["sfx": "actions"])
    let every = try e.execute("sfx.onCuts", params: ["replace": true])
    #expect(used(every) == ["sfx": "actions"] && every["placed"] == 5, "every cut: \(every)")
    // None: the effects there go with replace, and a call with nothing to replace is refused unless the person asked.
    try kindSays(e, ["sfx": "none"])
    let gone = try e.execute("sfx.onCuts", params: ["replace": true])
    #expect(gone["placed"] == 0 && gone["removed"] == 5 && used(gone) == ["sfx": "none"])
    #expect(throws: CommandError.self) { try e.execute("sfx.onCuts") }
    let asked = try e.execute("sfx.onCuts", params: ["override": true])
    #expect(used(asked).isEmpty && asked["placed"] == 3)

    let bed = fakeMedia("bed.wav")
    try kindSays(e, ["music": "never"])
    #expect(throws: CommandError.self) { try e.execute("audio.addMusic", params: ["path": .string(bed)]) }
    let music = try e.execute("audio.addMusic", params: ["path": .string(bed), "override": true])
    #expect(used(music).isEmpty)
    try e.execute("history.undo")
    try kindSays(e, ["music": "bed"])
    #expect(used(try e.execute("audio.addMusic", params: ["path": .string(bed)])) == ["music": "bed"])
}

@Test func theLogoAtTheEndFollowsTheClosingLogoChoice() throws {
    let e = try regiaEngine()
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 8])
    let logo = fakeMedia("logo.png")
    try kindSays(e, ["closing-logo": "off"])
    #expect(throws: CommandError.self) { try e.execute("logo.add", params: ["path": .string(logo)]) }
    try kindSays(e, ["closing-logo": ["value": "on", "number": 3]])
    let end = try e.checkUndoRedo("logo.add", ["path": .string(logo)])
    #expect(used(end) == ["closing-logo": "on 3"])
    #expect(end.value(at: "clip.start")?.doubleValue == 5 && end.value(at: "clip.end")?.doubleValue == 8, "\(end)")
    let placed = try e.execute("logo.add", params: ["path": .string(logo), "replace": true, "start": 1, "end": 2])
    #expect(used(placed).isEmpty)
    // The logo moved to the end (rules.fix's fix) stays the choice's seconds too.
    let id = try #require(placed.value(at: "clip.id")?.stringValue)
    let moved = try e.execute("logo.add", params: ["clipId": .string(id)])
    #expect(used(moved) == ["closing-logo": "3"] && moved.value(at: "clip.start")?.doubleValue == 5)
    try kindSays(e, ["closing-logo": "off"])
    #expect(used(try e.execute("logo.add", params: ["path": .string(logo), "replace": true, "override": true])).isEmpty)
}
