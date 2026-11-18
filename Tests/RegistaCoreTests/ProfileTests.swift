import Foundation
import Testing
@testable import RegistaCore

// Voice profiles (#41): a fresh Regista has no voice, a copied profile is locked, only the active profile's voice is
// usable, and enrolment turns the person's own reading of the script into clips, references and a training job.

private let testLines = [
    "Le site est en ligne depuis ce matin.",
    "Votre téléphone affiche la page en une seconde.",
    "On regarde ensemble les réglages de la newsletter.",
]

private let testScript = """
# Voice recording script — French

consent: Je m'appelle {name}, et j'accepte que Regista apprenne ma voix pour en faire un clone.

""" + RecordingScript.tones.map { "## \($0)\n" + testLines.map { "- \($0)" }.joined(separator: "\n") }.joined(separator: "\n") + "\n"

/// Words read one after the other (0.35 s per word, 0.8 s between sentences), from `start`.
private func spoken(_ sentences: [String], start: Double = 1) -> [Word] {
    var t = start, out: [Word] = []
    for s in sentences {
        for w in s.split(separator: " ") { out.append(Word(String(w), t, t + 0.3)); t += 0.35 }
        t += 0.8
    }
    return out
}

private struct EnrollFixture {
    let dir = tempDir()
    let profiles: ProfileStore
    var config = EngineConfig()
    let script: RecordingScript

    init(name: String = "Lucia") throws {
        profiles = ProfileStore(directory: dir.appendingPathComponent("profiles"), machine: "this-mac")
        _ = try profiles.create(name: name)
        let project = dir.appendingPathComponent("voxcpm")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try testScript.write(to: project.appendingPathComponent("scripts/fr.md"), atomically: true, encoding: .utf8)
        config.voxcpmProject = project.path
        script = try RecordingScript.load(language: "fr", config: config)
    }

    func add(_ words: [Word], tone: String = "neutral") throws -> VoiceEnrollment.AddResult {
        let take = fakeMedia("take.m4a", in: tempDir())
        return try VoiceEnrollment.add(path: take, language: "fr", tone: tone, profiles: profiles, script: script,
                                       audio: FakeAudio(speech: syntheticSpeech([], duration: 40)),
                                       transcriber: FakeTranscriber(words: words), command: "voice.enroll.add")
    }

    var folder: URL { VoiceEnrollment.languageFolder(try! profiles.requireActive(command: "t"), "fr") }
}

@Test func aFreshRegistaHasNoProfileAndTheFirstOneBecomesActive() throws {
    let store = ProfileStore(directory: tempDir(), machine: "this-mac")
    #expect(try store.active() == nil)
    #expect(throws: CommandError.self) { try store.requireActive(command: "voice") }

    let (ada, activated) = try store.create(name: "Ada")
    #expect(activated)
    #expect(ada.profile.id == "ada")
    #expect(ada.profile.voices.isEmpty)
    let (marco, second) = try store.create(name: "Marco")
    #expect(!second)                                   // the active one stays: switching is the person's choice
    #expect(store.activeID == "ada")
    #expect(try store.create(name: "Ada").entry.profile.id == "ada-2")
    try store.setActive(marco.profile.id)
    #expect(try store.requireActive(command: "t").profile.name == "Marco")
}

@Test func aProfileCopiedToAnotherMacIsLockedUntilAdopted() throws {
    let f = try VoiceFixture()
    let elsewhere = ProfileStore(directory: f.profiles.directory, machine: "another-mac")
    #expect(try elsewhere.active()?.locked == true)
    do {
        _ = try VoiceSetup.resolve(text: "Bonjour.", options: ["language": "fr"], profiles: elsewhere, config: f.config)
        Issue.record("a locked profile must not speak")
    } catch let e as CommandError {
        #expect(e.code == .conflict)
    }
    #expect(throws: CommandError.self) { try elsewhere.setActive("ada") }
    _ = try elsewhere.adopt("ada")
    #expect(try elsewhere.active()?.locked == false)
    #expect(try f.profiles.active()?.locked == true)    // and now it is the first Mac that has a copy
}

@Test func onlyTheActiveProfilesVoiceCanBeUsed() throws {
    let f = try VoiceFixture()
    _ = try f.profiles.create(name: "Marco")
    try f.profiles.update("marco") { $0.voices = ["fr": VoiceLanguage(refs: ["neutral": VoiceReference(wav: f.dir.appendingPathComponent("fr-neutral.wav").path, text: "x")])] }
    #expect(throws: CommandError.self) {
        try VoiceSetup.resolve(text: "Bonjour.", options: ["language": "fr", "voice": "marco"], profiles: f.profiles, config: f.config)
    }
    #expect(try VoiceSetup.resolve(text: "Bonjour.", options: ["language": "fr", "voice": "ada"], profiles: f.profiles, config: f.config).voice == "ada")
    // Switching, adopting and deleting are human-only (MCP refuses them); creating is not.
    #expect(ProfileSwitch.humanOnly && ProfileAdopt.humanOnly && ProfileDelete.humanOnly)
    #expect(!ProfileCreate.humanOnly)
    let e = try f.engine()
    #expect(e.descriptors.filter { $0.humanOnly }.map { $0.id }.contains("profile.switch"))
}

@Test func profileCommandsWorkThroughTheEngine() throws {
    let e = Engine(prober: FakeProber(), services: FakeServices().make())
    let none = try e.execute("profile.get")
    #expect(none["active"] == .null)
    #expect(none["note"] != nil)
    let made = try e.execute("profile.create", params: ["name": "Noor"])
    #expect(made["active"] == true)
    let empty = try e.execute("voice.list")
    #expect(empty["languages"] == [])
    // The next step is the one the voice-over recipe gives (#85): the person records the voice in Regista's Voce panel.
    let note = empty["note"]?.stringValue ?? ""
    #expect(note.contains("Voce panel") && note.contains("Regista"), "voice.list's note: \(note)")
}

@Test func recordingScriptParsesAndRejectsBrokenFiles() throws {
    let s = try RecordingScript.parse(testScript, language: "fr")
    #expect(s.blocks.map(\.tone) == RecordingScript.tones)
    #expect(s.lines("calm") == testLines)
    #expect(s.consent(name: "Lucia").hasPrefix("Je m'appelle Lucia,"))
    #expect(s.readable(name: "Lucia").contains("## sad"))
    #expect(throws: CommandError.self) { try RecordingScript.parse(testScript.replacingOccurrences(of: "{name}", with: "X"), language: "fr") }
    #expect(throws: CommandError.self) { try RecordingScript.parse(testScript.replacingOccurrences(of: "## calm", with: "## soft"), language: "fr") }
    #expect(throws: CommandError.self) { try RecordingScript.parse(testScript + "a stray note\n", language: "fr") }
}

@Test func alignmentSkipsMissingLinesAndKeepsTheBestReading() {
    let lines = ["le site est en ligne depuis ce matin", "votre téléphone affiche la page en une seconde", "on regarde ensemble les réglages"]
    // Line 0 read with a slip then again, line 1 skipped, line 2 read.
    let heard = VoiceEnrollment.keys("le site est en panne euh le site est en ligne depuis ce matin on regarde ensemble les réglages")
    let m = VoiceEnrollment.align(lines: lines, heard: heard)
    #expect(m.map(\.line) == [0, 2])
    #expect(m[0].first == 6)                           // the second, complete reading
    #expect(m[0].score == 1)
}

@Test func enrolmentNeedsTheConsentThenCutsClipsAndRegistersAZeroShotVoice() throws {
    let f = try EnrollFixture()
    // No consent at the start: refused, nothing kept.
    #expect(throws: CommandError.self) { try f.add(spoken(testLines)) }
    #expect(VoiceEnrollment.loadClips(f.folder).isEmpty)

    let consent = f.script.consent(name: "Lucia")
    let r = try f.add(spoken([consent] + testLines))
    #expect(r.consent)
    #expect(r.accepted == 3)
    #expect(r.missing.isEmpty)
    let clips = VoiceEnrollment.loadClips(f.folder)
    #expect(clips.count == 3)
    #expect(clips.allSatisfy { FileManager.default.fileExists(atPath: $0.file) && $0.seconds > 1 })
    let p = try #require(try f.profiles.active()?.profile)
    #expect(p.consents?["fr"]?.text == consent)
    let ref = try #require(p.voices["fr"]?.refs["neutral"])
    #expect(ref.text.hasPrefix(testLines[0]))          // consecutive lines, their exact script text
    #expect(p.voices["fr"]?.lora == nil)               // zero-shot until trained

    // Another tone: no consent needed any more; its lines carry the tone tag in the trainer manifest.
    let s = try f.add(spoken(Array(testLines.prefix(2))), tone: "serious")
    #expect(s.accepted == 2)
    #expect(s.missing == [testLines[2]])
    let manifest = try String(contentsOf: f.folder.appendingPathComponent("clips/train.jsonl"), encoding: .utf8)
    #expect(manifest.split(separator: "\n").count == 5)
    #expect(manifest.contains("(serious, authoritative)Le site est en ligne"))
    #expect(manifest.contains("\"text\":\"Le site est en ligne"))   // neutral: no tag
}

@Test func trainingRecipeFollowsTheAmountOfAudio() {
    let m = URL(fileURLWithPath: "/m/train.jsonl"), o = URL(fileURLWithPath: "/o")
    let pilot = VoiceEnrollment.trainingConfig(manifest: m, out: o, model: "/w", seconds: 120)
    #expect(pilot.steps == 300 && pilot.accum == 4)
    #expect(pilot.0["lora"]?["r"]?.doubleValue == 32)
    let full = VoiceEnrollment.trainingConfig(manifest: m, out: o, model: "/w", seconds: 1500)
    #expect(full.steps == 1000 && full.accum == 16)
    #expect(full.0["save_path"] == "/o")
}

@Test func trainingRefusesThinDataAndAFinishedRunBecomesTheLoRA() throws {
    let f = try EnrollFixture()
    _ = try f.add(spoken([f.script.consent(name: "Lucia")] + testLines))
    // ~7 s of clips: too little.
    #expect(throws: CommandError.self) { try VoiceEnrollment.train(language: "fr", profiles: f.profiles, config: f.config, command: "t") }

    // A finished run (as the trainer leaves it): the last checkpoint is registered, tones by clip count.
    let entry = try f.profiles.requireActive(command: "t")
    let dir = VoiceEnrollment.trainingDirectory(entry, "fr")
    let run = dir.appendingPathComponent("run-1")
    for step in ["step_0000150", "step_0000300"] {
        try FileManager.default.createDirectory(at: run.appendingPathComponent(step), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: run.appendingPathComponent("\(step)/lora_weights.safetensors").path, contents: Data())
    }
    let job = dir.appendingPathComponent("job")
    try FileManager.default.createDirectory(at: job, withIntermediateDirectories: true)
    try "step 300 done".write(to: job.appendingPathComponent("stdout.txt"), atomically: true, encoding: .utf8)
    try "0".write(to: job.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
    try run.path.write(to: job.appendingPathComponent("run"), atomically: true, encoding: .utf8)
    let s = try VoiceEnrollment.trainingStatus(entry, language: "fr", profiles: f.profiles)
    #expect(s["state"] == "done")
    let v = try #require(try f.profiles.active()?.profile.voices["fr"])
    #expect(v.lora == run.appendingPathComponent("step_0000300").path)
    #expect(v.tones == ["neutral"])                    // 3 clips < 10: no tone trained, neutral by default
}
