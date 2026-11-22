import Foundation
import Testing
@testable import RegistaCore

// Editing rules (#31): the sheets' header, the shipped defaults, the commands on a scratch rules folder (the fakes'
// services never point at the user's support folder), the project's kind and the export gate. The checks on real
// pictures, each with its fix and an export, are the rules-*.json scenarios.

/// An engine on fakes with a 3.7 s take (words from the fake transcription, the last ending at 4.5 s in the source)
/// on V1 and the compositor stand-in.
private func rulesEngine(_ fakes: FakeServices = FakeServices()) throws -> (Engine, RuleBook) {
    var services = fakes.make()
    services.renderer = FakeRenderer()
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "rules", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 6])
    return (e, services.rules)
}

@Test func theHeaderIsReadLineByLineAndEveryProblemIsReported() {
    let text = """
        ---
        # a comment
        logo-pause: on 0,4
        text-size: off
        title-captions:
        no colon here
        face-clear: on 3
        surprise: on
        text-size: on 30
        logo-pause: on 9
        text-size: on 12px
        ---
        # Prose
        Body.
        """
    let s = RuleSheetText.parse(text)
    #expect(s.entries.map(\.id) == ["logo-pause", "text-size"])
    #expect(s.entries[0].value == 0.4 && s.entries[0].on && s.entries[0].line == 3)
    #expect(s.entries[1].on == false && s.entries[1].value == nil)
    #expect(s.prose == "# Prose\nBody.")
    let lines = s.problems.map(\.line)
    #expect(lines == [5, 6, 7, 8, 9, 10, 11], "\(s.problems.map(\.text.english))")
    #expect(s.problems.contains { $0.text.english == "Line 8: unknown check «surprise»." })
    #expect(s.problems.contains { $0.text.english == "Line 7: face-clear takes no number." })
    #expect(s.problems.contains { $0.text.english == "Line 10: logo-pause must be between 0 and 5." })
    #expect(s.problems.contains { $0.text.english == "Line 9: text-size is listed twice; the first line counts." })

    // Not closed: no switch is taken, and it is said.
    let open = RuleSheetText.parse("---\ntext-size: off\n# Prose")
    #expect(open.entries.isEmpty && open.header == nil && open.problems.count == 1 && open.problems[0].line == 1)
    // No header at all is fine: prose only.
    let none = RuleSheetText.parse("# Just prose\n")
    #expect(none.entries.isEmpty && none.problems.isEmpty && none.prose == "# Just prose\n")
    // Changing switches rewrites their line and keeps every other line as written.
    let changed = RuleSheetText.parse(RuleSheetText.parse(text).setting([("text-size", true, 32), ("logo-end", false, nil)]))
    #expect(changed.entries.first { $0.id == "text-size" }?.value == 32 && changed.entries.first { $0.id == "logo-end" }?.on == false)
    #expect(changed.problems.count == s.problems.count && changed.prose == s.prose)
}

@Test func theDefaultSheetsShipInFourLanguagesWithAValidHeader() {
    for kind in [RuleBook.everyVideo] + RuleBook.builtInKinds {
        #expect(RuleBook.builtInTitle(kind) != nil)
        for lang in RuleBook.languages {
            let text = RuleDefaults.text(kind, language: lang)
            #expect(text != nil, "\(kind).\(lang) is missing")
            let s = RuleSheetText.parse(text ?? "")
            #expect(s.header != nil && s.problems.isEmpty, "\(kind).\(lang): \(s.problems.map(\.text.english))")
            #expect(s.prose.hasPrefix("# "), "\(kind).\(lang) has no title")
            if kind == RuleBook.everyVideo {
                #expect(s.entries.map(\.id) == RuleCheckSpec.ids && s.entries.allSatisfy(\.on))
                #expect(s.entries.first { $0.id == "logo-pause" }?.value == 0.3 && s.entries.first { $0.id == "text-size" }?.value == 28)
            }
        }
    }
    // An unknown language reads the English sheet.
    #expect(RuleDefaults.text("every-video", language: "de") == RuleDefaults.text("every-video", language: "en"))
}

/// The four languages of a sheet say the same things: the same sections, the same number of rules in each.
@Test func theDefaultSheetsHaveTheSameSectionsAndRulesInEveryLanguage() throws {
    for kind in [RuleBook.everyVideo] + RuleBook.builtInKinds {
        let shapes = try RuleBook.languages.map { lang -> [Int] in
            let prose = RuleSheetText.parse(try #require(RuleDefaults.text(kind, language: lang))).prose
            return prose.components(separatedBy: "\n## ").map { $0.components(separatedBy: "\n- ").count - 1 }
        }
        #expect(Set(shapes).count == 1, "\(kind): rules per section \(zip(RuleBook.languages, shapes).map { "\($0) \($1)" })")
    }
}

/// prompt-to-reel (#144) has no sheet of its own: its projects are voice-over videos, recipe.get gives that kind with the
/// rules of that kind, and what holds for every video is said once, in the "For every video" sheet, never in a recipe.
@Test func promptToReelFollowsTheVoiceOverSheetAndLeavesTheGeneralRulesToTheSheet() throws {
    let (e, _) = try rulesEngine()
    #expect(!RuleBook.builtInKinds.contains("prompt-to-reel") && Recipes.promptToReel.kind == "voice-over-video")
    #expect(Recipes.all.filter { $0.name != "prompt-to-reel" }.allSatisfy { $0.kind == $0.name })
    let r = try e.execute("recipe.get", params: ["name": "prompt-to-reel", "language": "en"])
    let text = try #require(r["text"]?.stringValue)
    #expect(r["kind"] == "voice-over-video" && text.contains("# Editing rules (voice-over-video)") && text.contains("# Voice-over video"))
    try e.execute("project.new", params: ["name": "sentence", "kind": "voice-over-video"])
    #expect(try e.execute("rules.check")["kind"] == "voice-over-video")
    #expect(throws: CommandError.self) { try e.execute("project.new", params: ["name": "x", "kind": "prompt-to-reel"]) }
    // Not longer than the others.
    let longest = Recipes.all.filter { $0.name != "prompt-to-reel" }.map { $0.text().count }.max() ?? 0
    #expect(Recipes.promptToReel.text().count < longest)
    let sheet = try #require(RuleDefaults.text("every-video", language: "en"))
    for rule in ["The first 3 seconds say", "One subject, one goal and one turn", "The ending echoes the opening", "one round of fixes", "never said to have been listened to",
                 "Every line stays long enough to be read"] {
        #expect(sheet.components(separatedBy: rule).count == 2, "«\(rule)» is not in the sheet once")
        for recipe in Recipes.all { #expect(!recipe.text().contains(rule), "\(recipe.name) repeats «\(rule)»") }
    }
}

@Test func editingTheProseChangesWhatRecipeGetReturnsAndResetBringsTheDefaultBack() throws {
    let (e, book) = try rulesEngine()
    #expect(!book.directory.path.contains("Library/Application Support"))
    let before = try #require(e.execute("recipe.get", params: ["name": "talking-head-reel", "language": "en"])["text"]?.stringValue)
    #expect(before.hasPrefix(Recipes.talkingHeadReel.text()) && before.contains("# For every video") && before.contains("# Talking-head reel"))
    #expect(!before.contains("Always thank the viewer"))

    let set = try e.execute("rules.set", params: ["kind": "talking-head-reel", "prose": "# Talking-head reel\n\nAlways thank the viewer.\n", "language": "en"])
    #expect(set["edited"] == true && set["path"]?.stringValue == book.file("talking-head-reel").path)
    #expect(FileManager.default.fileExists(atPath: book.file("talking-head-reel").path))
    let after = try #require(e.execute("recipe.get", params: ["name": "talking-head-reel", "language": "it"])["text"]?.stringValue)
    #expect(after.contains("Always thank the viewer.") && after.contains("# Per ogni video"), "the user's sheet replaces the default in every language")

    let reset = try e.execute("rules.reset", params: ["kind": "talking-head-reel", "language": "en"])
    #expect(reset["removed"] == true && reset.value(at: "sheet.edited") == false)
    #expect(try e.execute("recipe.get", params: ["name": "talking-head-reel", "language": "en"])["text"]?.stringValue == before)
    #expect(try e.execute("rules.reset", params: ["kind": "talking-head-reel"])["removed"] == false)
    #expect(throws: CommandError.self) { try e.execute("rules.set", params: ["kind": "nope", "prose": "x"]) }
    #expect(throws: CommandError.self) { try e.execute("rules.set", params: ["kind": "every-video", "checks": ["surprise": true]]) }
    #expect(throws: CommandError.self) { try e.execute("rules.set", params: ["kind": "every-video", "checks": ["logo-end": ["value": 2]]]) }
}

@Test func switchingACheckOffStopsItFromBlockingTheExport() throws {
    let (e, _) = try rulesEngine()
    try e.execute("title.add", params: ["text": "small print", "start": 1, "duration": 2, "size": 20])
    let check = try e.execute("rules.check")
    #expect(check["pass"] == false && check.value(at: "violations.0.check") == "text-size" && check.value(at: "violations.0.fix") == .null)
    let out = tempDir().appendingPathComponent("out.mp4").path
    #expect(throws: CommandError.self) { try e.execute("export.render", params: ["path": .string(out)]) }
    do { try e.execute("export.render", params: ["path": .string(out)]) } catch let error as CommandError {
        #expect(error.message.contains("text-size at 1.00 s") && error.message.contains("exportAnyway"))
    }
    // The person said to export anyway.
    let anyway = try e.execute("export.render", params: ["path": .string(out), "exportAnyway": true])
    #expect(anyway.value(at: "rules.exportedAnyway") == true && anyway.value(at: "rules.violations.0.check") == "text-size")

    // A lower number lets it through; the switch off too.
    try e.execute("rules.set", params: ["kind": "every-video", "checks": ["text-size": ["value": 18]]])
    #expect(try e.execute("rules.check")["pass"] == true)
    try e.execute("rules.set", params: ["kind": "every-video", "checks": ["text-size": ["value": 28]]])
    #expect(try e.execute("rules.check")["pass"] == false)
    let off = try e.execute("rules.set", params: ["kind": "every-video", "checks": ["text-size": false], "language": "en"])
    #expect(off.value(at: "switches.5.on") == false)
    let passed = try e.execute("rules.check")
    #expect(passed["pass"] == true && passed["checks"]?.arrayValue?.first { $0["id"] == "text-size" }?["on"] == false)
    let r = try e.execute("export.render", params: ["path": .string(out)])
    #expect(r.value(at: "rules.pass") == true && r.value(at: "rules.exportedAnyway") == false)
    // A kind's own line wins over every-video's.
    try e.execute("rules.set", params: ["kind": "talking-head-reel", "checks": ["text-size": true]])
    let kindLine = try e.execute("rules.check")
    #expect(kindLine["pass"] == false && kindLine["checks"]?.arrayValue?.first { $0["id"] == "text-size" }?["source"] == "talking-head-reel")
}

@Test func aUserKindCanBeCreatedChosenForAProjectAndDeleted() throws {
    let (e, book) = try rulesEngine()
    let added = try e.execute("rules.addKind", params: ["title": "YouTube tutorial", "from": "screen-tutorial", "language": "en"])
    #expect(added["kind"] == "youtube-tutorial" && added["title"] == "YouTube tutorial" && added["builtIn"] == false)
    #expect(added["prose"]?.stringValue?.hasPrefix("# YouTube tutorial\n") == true && added["prose"]?.stringValue?.contains("Zoom on the action") == true)
    let list = try e.execute("rules.list", params: ["language": "en"])
    #expect(list["sheets"]?.arrayValue?.map { $0["kind"]?.stringValue ?? "" }
            == ["every-video", "talking-head-reel", "screen-tutorial", "voice-over-video", "reel-graphics", "youtube-tutorial"])
    #expect(list.value(at: "project.kind") == "talking-head-reel" && list.value(at: "project.source") == "format")
    #expect(throws: CommandError.self) { try e.execute("rules.addKind", params: ["title": "YouTube tutorial"]) }

    try e.checkUndoRedo("project.setKind", ["kind": "youtube-tutorial"])
    #expect(e.project?.kind == "youtube-tutorial")
    #expect(try e.execute("rules.check")["kind"] == "youtube-tutorial")
    #expect(try e.execute("project.state")["kind"] == "youtube-tutorial")
    #expect(throws: CommandError.self) { try e.execute("project.setKind", params: ["kind": "every-video"]) }
    #expect(throws: CommandError.self) { try e.execute("rules.reset", params: ["kind": "youtube-tutorial"]) }
    #expect(throws: CommandError.self) { try e.execute("rules.removeKind", params: ["kind": "screen-tutorial"]) }

    try e.execute("rules.removeKind", params: ["kind": "youtube-tutorial"])
    #expect(!FileManager.default.fileExists(atPath: book.file("youtube-tutorial").path))
    let fallback = try e.execute("rules.check")
    #expect(fallback["kind"] == "talking-head-reel" && fallback["kindSource"] == "format")
    #expect(fallback.value(at: "note.messageArgs") == ["youtube-tutorial", "talking-head-reel"])
    try e.execute("project.setKind")
    #expect(e.project?.kind == nil)
}

@Test func aMalformedHeaderIsReportedInTheSheetAndInTheCheckWithoutBlocking() throws {
    let (e, _) = try rulesEngine()
    try e.execute("rules.set", params: ["kind": "every-video", "text": "---\ntext-size: maybe\nwhatever: on\n---\n# For every video\n"])
    let sheet = try e.execute("rules.get", params: ["kind": "every-video"])
    #expect(sheet.value(at: "status.ok") == false)
    #expect(sheet.value(at: "status.problems")?.arrayValue?.compactMap { $0["line"]?.doubleValue } == [2, 3])
    let check = try e.execute("rules.check")
    #expect(check["pass"] == true && check["sheetProblems"]?.arrayValue?.count == 2 && check.value(at: "sheetProblems.0.sheet") == "every-video")
    // The checks the bad lines meant keep their defaults.
    #expect(check["checks"]?.arrayValue?.first { $0["id"] == "text-size" }?["on"] == true)
}

@Test func aProjectStoresItsKindAndOldProjectsTakeTheKindOfTheirFormat() throws {
    let e = Engine(prober: FakeProber(), services: FakeServices().make())
    let dir = tempDir()
    try e.execute("project.new", params: ["name": "wide", "directory": .string(dir.path), "width": 1920, "height": 1080])
    #expect(try e.execute("project.state")["kind"] == "screen-tutorial")
    try e.execute("project.save")
    let json = try String(contentsOf: dir.appendingPathComponent("wide.regista/project.json"), encoding: .utf8)
    #expect(!json.contains("\"kind\""), "a project without a kind saves as before")
    try e.execute("project.open", params: ["path": .string(dir.appendingPathComponent("wide.regista").path)])
    let reopened = try e.execute("rules.check")
    #expect(e.project?.kind == nil && reopened["kindSource"] == "format")
    try e.execute("project.new", params: ["name": "vo", "kind": "voice-over-video"])
    #expect(e.project?.kind == "voice-over-video")
    #expect(throws: CommandError.self) { try e.execute("project.new", params: ["name": "x", "kind": "nope"]) }
}

@Test func captionsClearTakesAStretchOffInOneUndoStep() throws {
    let (e, _) = try rulesEngine()
    try e.execute("captions.generate")
    let before = try #require(e.project?.tracks.first { $0.captions != nil }?.captions)
    #expect(before.chunks.first?.words.first?.start == t(1.0))
    try e.checkUndoRedo("captions.clear", ["from": 0, "to": 1.6])
    let after = try #require(e.project?.tracks.first { $0.captions != nil }?.captions)
    // "uno" (1.0–1.4) was spoken under the stretch: gone; "due" (1.5–2.0) is still being spoken at 1.6: shown from 1.6.
    #expect(!after.chunks.flatMap(\.words).contains { $0.text.uppercased() == "UNO" })
    #expect(after.chunks.first?.words.first?.start == t(1.6))
    #expect(throws: CommandError.self) { try e.execute("captions.clear", params: ["from": 2, "to": 1]) }
}

@Test func aLongPauseBeforeTheLogoWarnsWithoutBlocking() throws {
    let (e, _) = try rulesEngine()
    let logo = fakeMedia("logo.png")
    // The last word ends at 4.5 s: a logo 0.8 s later is more than 0.6 s of pause.
    try e.execute("logo.add", params: ["path": .string(logo), "start": 5.3, "end": 6])
    let check = try e.execute("rules.check")
    #expect(check["pass"] == true && check["warnings"] == 1, "\(check)")
    #expect(check.value(at: "violations.0.check") == "logo-pause" && check.value(at: "violations.0.severity") == "warn")
    #expect(check.value(at: "violations.0.fix.params.start")?.doubleValue.map { abs($0 - 4.9) < 0.02 } == true)
    // On the last word: a failure, fixed by rules.fix in one step.
    try e.execute("history.undo")
    try e.execute("logo.add", params: ["path": .string(logo), "start": 4.4, "end": 6])
    #expect(try e.execute("rules.check").value(at: "violations.0.severity") == "fail")
    let fixed = try e.checkUndoRedo("rules.fix", ["all": true])
    #expect(fixed.value(at: "check.pass") == true && fixed["applied"]?.arrayValue?.count == 1)
}

@Test func violationsOfOneCheckOverTheSameWindowAreListedOnce() throws {
    // Seen on a real project: two title layers over the same opening stretch listed «captions under the opening title»
    // twice, with the same time, message and fix.
    let (e, _) = try rulesEngine()
    try e.execute("captions.generate")
    try e.execute("title.add", params: ["text": "HOOK", "start": 0, "duration": 2])
    try e.execute("title.add", params: ["text": "SUBTITLE", "start": 0, "duration": 2])
    let check = try e.execute("rules.check")
    let opening = check["violations"]?.arrayValue?.filter { $0["check"] == "title-captions" } ?? []
    #expect(opening.count == 1, "\(opening)")
    #expect(check["failures"]?.doubleValue == Double(check["violations"]?.arrayValue?.filter { $0["severity"] == "fail" }.count ?? -1))
    // Another window is another problem.
    try e.execute("history.undo")
    try e.execute("title.add", params: ["text": "SHORT", "start": 0, "duration": 1.2])
    #expect(try e.execute("rules.check")["violations"]?.arrayValue?.filter { $0["check"] == "title-captions" }.count == 2)
}

// MARK: The logo follows the rules of the project's kind (#74)

@Test func theLogoGoesInTheClosingSecondsWhenTheRulesWantItOnlyAtTheEnd() throws {
    let (e, book) = try rulesEngine()
    let logo = fakeMedia("logo.png")
    #expect(book.logoOnlyAtEnd(e.project!))
    // No time given: the closing 2 s of the 6 s video, and the result says why; the rule then holds.
    let placed = try e.checkUndoRedo("logo.add", ["path": .string(logo)])
    #expect(placed.value(at: "clip.start")?.doubleValue == 4 && placed.value(at: "clip.end")?.doubleValue == 6)
    #expect(placed["timing"]?.stringValue?.contains("logo-end") == true)
    #expect(try e.execute("rules.check")["violations"]?.arrayValue?.contains { $0["check"] == "logo-end" } == false)
    // An explicit time is kept, and the check fails as before, now with its fix.
    let across = try e.execute("logo.add", params: ["path": .string(logo), "replace": true, "start": 0, "end": 6])
    #expect(across.value(at: "clip.start")?.doubleValue == 0 && across["timing"] == nil)
    let check = try e.execute("rules.check")
    let v = try #require(check["violations"]?.arrayValue?.first { $0["check"] == "logo-end" })
    #expect(v.value(at: "fix.command") == "logo.add" && v.value(at: "fix.params.clipId") == v["clipId"])
    #expect(v.value(at: "fix.messageKey") == "Keep the logo for the last %1$@ s only")
    // The fix: the same clip, the last 2 s, its exit with it — one undo step.
    let id = try #require(v["clipId"]?.stringValue)
    let before = try #require(e.project?.tracks.flatMap(\.clips).first { $0.id == id })
    let fixed = try e.checkUndoRedo("rules.fix", ["check": "logo-end"])
    #expect(fixed.value(at: "check.violations")?.arrayValue?.contains { $0["check"] == "logo-end" } == false, "\(fixed)")
    let after = try #require(e.project?.tracks.flatMap(\.clips).first { $0.id == id })
    #expect(after.start == t(4) && after.end == t(6) && after.placement == before.placement && after.transform == before.transform)
    #expect(after.keyframes?.first?.time == .zero && after.keyframes?.last?.time == t(2), "\(String(describing: after.keyframes))")
    #expect(after.keyframes?.last?.transform.opacity == before.keyframes?.last?.transform.opacity)
    // A logo placed by hand in the middle fails the rule too, and is fixed the same way.
    try e.execute("logo.add", params: ["path": .string(logo), "replace": true, "start": 2, "end": 3])
    #expect(try e.execute("rules.fix", params: ["all": true]).value(at: "check.violations")?.arrayValue?.contains { $0["check"] == "logo-end" } == false)
    // The rule off: no time given is the whole video again.
    try e.execute("rules.set", params: ["kind": "every-video", "checks": ["logo-end": false]])
    defer { _ = try? e.execute("rules.reset", params: ["kind": "every-video"]) }
    #expect(!book.logoOnlyAtEnd(e.project!))
    let whole = try e.execute("logo.add", params: ["path": .string(logo), "replace": true])
    #expect(whole.value(at: "clip.start")?.doubleValue == 0 && whole.value(at: "clip.end")?.doubleValue == 6 && whole["timing"] == nil)
}

@Test func aRetimedLogoKeepsItsEntranceAndItsExit() {
    var rest = Transform(), gone = Transform()
    gone.opacity = 0
    let keys = [Keyframe(time: .zero, transform: gone), Keyframe(time: t(0.25), transform: rest),
                Keyframe(time: t(5.75), transform: rest), Keyframe(time: t(6), transform: gone)]
    let short = LogoAdd.retimed(keys, from: t(6), to: t(2))!
    #expect(short.map(\.time) == [.zero, t(0.25), t(1.75), t(2)])
    #expect(LogoAdd.retimed(nil, from: t(6), to: t(2)) == nil)
}
