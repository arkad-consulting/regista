import Foundation
import Testing
@testable import RegistaCore

/// A profile "Ada" (active) in a temp folder: French with a LoRA (+ a serious tone trained, a calm reference clip),
/// Italian zero-shot. `uv` is a fake that writes the WAV vox_say.py would write and logs its input.
struct VoiceFixture {
    let dir = tempDir()
    var config = EngineConfig()
    let profiles: ProfileStore

    var lora: URL { dir.appendingPathComponent("lora/fr/step_0000300") }
    var inputs: URL { dir.appendingPathComponent("vox-inputs.txt") }

    init() throws {
        profiles = ProfileStore(directory: dir.appendingPathComponent("profiles"), machine: "this-mac")
        let fm = FileManager.default
        try fm.createDirectory(at: lora, withIntermediateDirectories: true)
        for f in ["lora_weights.safetensors", "lora_config.json"] { fm.createFile(atPath: lora.appendingPathComponent(f).path, contents: Data()) }
        for f in ["fr-neutral.wav", "fr-calm.wav", "it-neutral.wav"] { fm.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data()) }
        let model = dir.appendingPathComponent("VoxCPM2")
        try fm.createDirectory(at: model, withIntermediateDirectories: true)
        fm.createFile(atPath: model.appendingPathComponent("config.json").path, contents: Data("{}".utf8))
        let project = dir.appendingPathComponent("voxcpm")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        fm.createFile(atPath: project.appendingPathComponent("pyproject.toml").path, contents: Data())
        fm.createFile(atPath: project.appendingPathComponent("vox_say.py").path, contents: Data())
        let uv = dir.appendingPathComponent("uv")
        let script = """
        #!/bin/sh
        for last; do :; done
        printf '%s\\n' "$last" >> '\(inputs.path)'
        /usr/bin/python3 -I -c 'import json,sys; r=json.loads(sys.argv[1]); o=r["items"][0]["out"]; open(o,"wb").write(b"RIFF"); print(json.dumps({"files":[o],"seconds":[1.0],"model":"voxcpm2","wall_seconds":2.5}))' "$last"
        """
        try script.write(to: uv, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)

        config.uv = uv.path
        config.voxcpmProject = project.path
        config.voxcpmScript = project.appendingPathComponent("vox_say.py").path
        config.voxcpmModel = model.path
        let dir = self.dir, lora = self.lora
        _ = try profiles.create(name: "Ada")
        try profiles.update("ada") { p in p.voices = [
            "fr": VoiceLanguage(lora: lora.path,
                                refs: ["neutral": VoiceReference(wav: dir.appendingPathComponent("fr-neutral.wav").path, text: "Alors, honnêtement…"),
                                       "calm": VoiceReference(wav: dir.appendingPathComponent("fr-calm.wav").path, text: "Doucement…")],
                                tones: ["neutral", "serious"]),
            "it": VoiceLanguage(refs: ["neutral": VoiceReference(wav: dir.appendingPathComponent("it-neutral.wav").path, text: "Allora…")]),
        ] }
        try writeLexicon("fr", [.init(word: "WeSites", say: "We Sites", status: "confirmed"), .init(word: "Wi-Fi", say: "Oui-Fi", status: "pending")])
    }

    func writeLexicon(_ language: String, _ entries: [VoiceLexicon.Entry]) throws {
        let f = profiles.lexiconFile(try #require(try profiles.active()), language: language)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(VoiceLexicon(entries: entries)).write(to: f)
    }

    func engine() throws -> Engine {
        var fakes = FakeServices().make()
        fakes.config.uv = config.uv
        fakes.config.voxcpmProject = config.voxcpmProject
        fakes.config.voxcpmScript = config.voxcpmScript
        fakes.config.voxcpmModel = config.voxcpmModel
        fakes.profiles = profiles
        fakes.generators = ["voxcpm": VoxCPMProvider(config: fakes.config, profiles: profiles)]
        let e = Engine(prober: FakeProber(), services: fakes)
        try e.execute("project.new", params: ["name": "vo", "directory": .string(tempDir().path)])
        return e
    }

    var lastInput: JSONValue? {
        ((try? String(contentsOf: inputs, encoding: .utf8)) ?? "").split(separator: "\n").last.flatMap { try? JSONValue.parse(String($0)) }
    }
}

@Test func lexiconReplacesWholeWordsOnlyLongestFirst() {
    let lex = VoiceLexicon(entries: [.init(word: "Claude", say: "Clôde"), .init(word: "Claude Code", say: "Clôde Côde"),
                                     .init(word: "WeSites", say: "We Sites"), .init(word: "Wi-Fi", say: "Oui-Fi")])
    #expect(lex.apply("Avec WeSites, le Wi-Fi et Claude Code.") == "Avec We Sites, le Oui-Fi et Clôde Côde.")
    #expect(lex.apply("Claude, pas WeSitesPro ni xWi-Fi.") == "Clôde, pas WeSitesPro ni xWi-Fi.")
    #expect(VoiceLexicon().apply("WeSites") == "WeSites")
}

@Test func voiceSetupAppliesTheLexiconToTheModelTextAndPicksTheTone() throws {
    let f = try VoiceFixture()
    let s = try VoiceSetup.resolve(text: "WeSites marche sans Wi-Fi.", options: ["language": "fr"], profiles: f.profiles, config: f.config)
    #expect(s.voice == "ada")                       // the only voice
    #expect(s.tone == "neutral")
    #expect(s.modelText == "We Sites marche sans Oui-Fi.")
    #expect(s.lora == f.lora.path)
    #expect(s.ref.wav.hasSuffix("fr-neutral.wav"))

    // A trained tone: style tag in front, neutral reference.
    let serious = try VoiceSetup.resolve(text: "Attention.", options: ["language": "fr", "tone": "serious"], profiles: f.profiles, config: f.config)
    #expect(serious.modelText == "(serious, authoritative)Attention.")
    #expect(serious.ref.wav.hasSuffix("fr-neutral.wav"))
    // A tone with its own reference clip but not trained: no tag, that clip.
    let calm = try VoiceSetup.resolve(text: "Doucement.", options: ["language": "fr", "tone": "calm"], profiles: f.profiles, config: f.config)
    #expect(calm.modelText == "Doucement.")
    #expect(calm.ref.wav.hasSuffix("fr-calm.wav"))
    #expect(throws: CommandError.self) { try VoiceSetup.resolve(text: "x", options: ["language": "fr", "tone": "sad"], profiles: f.profiles, config: f.config) }

    // Zero-shot language: no LoRA, no lexicon file.
    let it = try VoiceSetup.resolve(text: "Ciao WeSites.", options: ["language": "it"], profiles: f.profiles, config: f.config)
    #expect(it.lora == nil)
    #expect(it.modelText == "Ciao WeSites.")
    // Two languages: the language is required.
    #expect(throws: CommandError.self) { try VoiceSetup.resolve(text: "x", options: nil, profiles: f.profiles, config: f.config) }
}

@Test func voiceSetupNamesTheMissingFile() throws {
    let f = try VoiceFixture()
    try FileManager.default.removeItem(at: f.lora.appendingPathComponent("lora_weights.safetensors"))
    do {
        _ = try VoiceSetup.resolve(text: "Bonjour.", options: ["language": "fr"], profiles: f.profiles, config: f.config)
        Issue.record("expected a missing-file error")
    } catch let e as CommandError {
        #expect(e.code == .notFound)
        #expect(e.message.contains(f.lora.appendingPathComponent("lora_weights.safetensors").path))
    }
    // No profile at all (a fresh Regista): no voice.
    let empty = ProfileStore(directory: tempDir(), machine: "this-mac")
    #expect(throws: CommandError.self) { try VoiceSetup.resolve(text: "x", options: ["language": "fr"], profiles: empty, config: f.config) }
}

@Test func voxcpmRequestCarriesTheModelTextAndTheCacheFollowsTheLexicon() throws {
    let f = try VoiceFixture()
    let p = VoxCPMProvider(config: f.config, profiles: f.profiles)
    let raw = GenerationRequest(provider: "voxcpm", kind: .voice, prompt: "Bienvenue chez WeSites.", options: ["language": "fr"])
    let r = try p.prepare(raw)
    #expect(r.prompt == "Bienvenue chez WeSites.")              // real spelling kept
    #expect(r.options?["modelText"] == "Bienvenue chez We Sites.")
    #expect(r.seed == GenerationRequest.defaultSeed(raw.prompt))

    let job = tempDir()
    let proc = try p.process(r, job: job)
    #expect(proc.executable.path == f.config.uv)
    #expect(Array(proc.arguments.prefix(7)) == ["run", "--frozen", "--project", f.config.voxcpmProject, "python", "-I", f.config.voxcpmScript])
    let input = try JSONValue.parse(try #require(proc.arguments.last))
    #expect(input.value(at: "items")?.arrayValue?.first?["text"]?.stringValue == "Bienvenue chez We Sites.")
    #expect(input["lora"]?.stringValue == f.lora.path)
    #expect(input.value(at: "ref.text")?.stringValue == "Alors, honnêtement…")
    #expect(proc.environment["HF_HUB_OFFLINE"] == "1")

    // A lexicon change is a different job.
    let before = try r.hash()
    try f.writeLexicon("fr", [.init(word: "WeSites", say: "Oui Saïts")])
    #expect(try p.prepare(raw).hash() != before)
    #expect(p.unavailableReason(.voice) == nil)
    #expect(p.unavailableReason(.image) != nil)
}

@Test func generateVoiceLandsInTheBinAsAudioAndIsCached() throws {
    let f = try VoiceFixture()
    let e = try f.engine()
    let r = try e.execute("generate.run", params: ["kind": "voice", "prompt": "Bonjour, ici WeSites.", "options": ["language": "fr"]])
    #expect(r["status"] == "done")
    #expect(r["provider"] == "voxcpm")                 // the default provider for voice
    let aid = try #require(r["assetId"]?.stringValue)
    let asset = try #require(e.project?.asset(aid))
    #expect(asset.audio != nil && asset.video == nil)
    #expect(asset.generated?.kind == .voice)
    #expect(asset.generated?.prompt == "Bonjour, ici WeSites.")
    #expect(f.lastInput?.value(at: "items")?.arrayValue?.first?["text"]?.stringValue == "Bonjour, ici We Sites.")

    let again = try e.execute("generate.run", params: ["kind": "voice", "prompt": "Bonjour, ici WeSites.", "options": ["language": "fr"]])
    #expect(again["cached"] == true)
    #expect(((try? String(contentsOf: f.inputs, encoding: .utf8)) ?? "").split(separator: "\n").count == 1)

    #expect(throws: CommandError.self) {
        try e.execute("generate.run", params: ["kind": "voice", "prompt": "Ciao.", "options": ["language": "pt"]])
    }
}

@Test func voiceListShowsModesTonesLexiconAndProblems() throws {
    let f = try VoiceFixture()
    let e = try f.engine()
    try FileManager.default.removeItem(at: f.dir.appendingPathComponent("it-neutral.wav"))
    let r = try e.execute("voice.list")
    #expect(r.value(at: "engine.available") == true)
    #expect(r.value(at: "profile.name") == "Ada")
    let langs = try #require(r["languages"]?.arrayValue)
    let fr = try #require(langs.first { $0["language"] == "fr" })
    #expect(fr["mode"] == "lora")
    #expect(fr["tones"]?.arrayValue?.compactMap(\.stringValue) == ["neutral", "serious", "calm"])
    #expect(fr.value(at: "lexicon.entries")?.doubleValue == 2)
    #expect(fr.value(at: "lexicon.pending")?.doubleValue == 1)
    #expect(fr["ready"] == true)
    let it = try #require(langs.first { $0["language"] == "it" })
    #expect(it["mode"] == "zero-shot")
    #expect(it["ready"] == false)
    #expect(it["problems"]?.arrayValue?.first?.stringValue?.contains("it-neutral.wav") == true)
}

@Test func voiceOverParagraphsSplitOnBlankLinesAndLongOnesAtSentences() {
    #expect(VoiceScript.paragraphs("Un.\n\n\n  Deux   trois.\nQuatre.  \n\n") == ["Un.", "Deux trois. Quatre."])
    let long = Array(repeating: "Une phrase assez longue pour remplir la ligne.", count: 20).joined(separator: " ")
    let parts = VoiceScript.paragraphs(long, limit: 200)
    #expect(parts.count > 1)
    #expect(parts.allSatisfy { $0.count <= 200 && $0.hasSuffix(".") })
}

@Test func wordTimingsKeepTheRealSpellingAndShareMisheardGaps() {
    let heard = [Word("Avec", 0.2, 0.5), Word("8", 0.6, 0.8), Word("sites,", 0.85, 1.2), Word("tout", 1.4, 1.6), Word("marche.", 1.7, 2.1)]
    let w = VoiceScript.timedWords("Avec We Sites, tout marche.", heard: heard, duration: 2.5)
    #expect(w.map(\.text) == ["Avec", "We", "Sites,", "tout", "marche."])
    #expect(w[0].start.seconds == 0.2)
    #expect(w[2].start.seconds == 0.85)                // "Sites," matched "sites,"
    #expect(w[1].start.seconds >= 0.5 && w[1].end.seconds <= 0.85)   // "We" fills the gap before it
    #expect(zip(w, w.dropFirst()).allSatisfy { $0.start <= $1.start })
    // French spaced punctuation stays with its word.
    let fr = VoiceScript.timedWords("Combien de plugins ? Dix !", heard: [Word("Combien", 0, 0.3), Word("de", 0.35, 0.45), Word("plugins", 0.5, 0.9), Word("Dix", 1.2, 1.5)], duration: 2)
    #expect(fr.map(\.text) == ["Combien", "de", "plugins\u{00A0}?", "Dix\u{00A0}!"])
}

@Test func voiceSayPlacesParagraphsOnTheVoceTrackWithWordsAndOneUndo() throws {
    let f = try VoiceFixture()
    let e = try f.engine()
    let r = try e.execute("voice.say", params: ["text": "Bonjour, ici WeSites.\n\nDeuxième paragraphe.", "language": "fr", "gap": 0.5])
    let tid = try #require(r["trackId"]?.stringValue)
    let track = try #require(e.project?.tracks.first { $0.id == tid })
    #expect(track.name == "Voce" && track.kind == .audio)
    #expect(track.clips.count == 2)
    let first = track.clips[0], second = track.clips[1]
    #expect(first.start == .zero)
    #expect(abs((second.start - first.end).seconds - 0.5) < 0.04)  // the gap, snapped to frames
    let words = try #require(e.project?.asset(first.assetID)?.analysis?.transcript?.words)
    #expect(words.map(\.text) == ["Bonjour,", "ici", "WeSites."])   // real spelling, not the model text
    #expect(f.lastInput?.value(at: "items")?.arrayValue?.first?["text"]?.stringValue == "Deuxième paragraphe.")

    let caps = try e.execute("captions.generate", params: ["sourceTrackId": .string(tid)])
    #expect(caps["error"] == nil)
    try e.execute("history.undo")                                  // captions.generate
    #expect(e.project?.tracks.first { $0.id == tid }?.clips.count == 2)
    try e.execute("history.undo")                                  // the whole voice.say is one step
    #expect(e.project?.tracks.first { $0.id == tid } == nil)
}

@Test func voiceLexiconAddsAndRemovesEntries() throws {
    let f = try VoiceFixture()
    let e = try f.engine()
    let r = try e.execute("voice.lexicon", params: ["language": "fr", "add": ["word": "Kimi", "say": "Ki-mi"]])
    #expect(r["entries"]?.arrayValue?.contains { $0["word"] == "Kimi" && $0["status"] == "pending" } == true)
    let s = try VoxCPMProvider(config: f.config, profiles: f.profiles)
        .prepare(GenerationRequest(provider: "voxcpm", kind: .voice, prompt: "Kimi et WeSites.", options: ["language": "fr"]))
    #expect(s.options?["modelText"] == "Ki-mi et We Sites.")
    _ = try e.execute("voice.lexicon", params: ["language": "fr", "remove": "Kimi"])
    #expect(throws: CommandError.self) { try e.execute("voice.lexicon", params: ["language": "fr", "remove": "Kimi"]) }
}

// V2 (#62): the Voce panel's Ascolta renders without touching the edit; Metti in timeline reuses those renders.
@Test func voicePreviewRendersOutsideTheProjectAndVoiceSayReusesIt() throws {
    let f = try VoiceFixture()
    let e = try f.engine()
    let text = "Bonjour, ici WeSites.\n\nDeuxième paragraphe."
    let est = try e.execute("voice.preview", params: ["text": .string(text), "language": "fr", "estimate": true])
    #expect(est["paragraphs"]?.arrayValue?.count == 2)
    #expect(est["paragraphs"]?.arrayValue?.allSatisfy { $0["cached"] == false && $0["file"] == nil } == true)
    #expect((est["renderSeconds"]?.doubleValue ?? 0) > 40)                  // two model loads
    #expect(!FileManager.default.fileExists(atPath: f.inputs.path))       // nothing rendered

    let one = try e.execute("voice.preview", params: ["text": .string(text), "language": "fr", "paragraph": 1])
    #expect(one["paragraphs"]?.arrayValue?.count == 1)
    let file = try #require(one.value(at: "paragraphs")?.arrayValue?.first?["file"]?.stringValue)
    #expect(FileManager.default.fileExists(atPath: file))
    #expect(e.project?.assets.isEmpty == true)                             // the edit is untouched
    #expect(e.context.history.undoStack.isEmpty)

    let all = try e.execute("voice.preview", params: ["text": .string(text), "language": "fr"])
    #expect(all["paragraphs"]?.arrayValue?.map { $0["cached"] } == [false, true])
    let rendered = ((try? String(contentsOf: f.inputs, encoding: .utf8)) ?? "").split(separator: "\n").count
    #expect(rendered == 2)

    let r = try e.execute("voice.say", params: ["text": .string(text), "language": "fr"])
    #expect(r["clips"]?.arrayValue?.count == 2)
    #expect(((try? String(contentsOf: f.inputs, encoding: .utf8)) ?? "").split(separator: "\n").count == rendered)   // reused
    #expect(throws: CommandError.self) { try e.execute("voice.preview", params: ["text": .string(text), "language": "fr", "paragraph": 5]) }
}

@Test func cancelStopsARenderAndFreesItsJobFolder() throws {
    let f = try VoiceFixture()
    // A model that never finishes on its own.
    try "#!/bin/sh\nsleep 60\n".write(to: URL(fileURLWithPath: f.config.uv), atomically: true, encoding: .utf8)
    var fakes = FakeServices().make()
    fakes.config.uv = f.config.uv
    fakes.config.voxcpmProject = f.config.voxcpmProject
    fakes.config.voxcpmScript = f.config.voxcpmScript
    fakes.config.voxcpmModel = f.config.voxcpmModel
    fakes.profiles = f.profiles
    fakes.generators = ["voxcpm": VoxCPMProvider(config: fakes.config, profiles: f.profiles)]
    let cancel = GenerationCancellation()
    fakes.cancellation = cancel
    let e = Engine(prober: FakeProber(), services: fakes)
    let started = Date()
    // A thread of its own: in the full parallel suite the global queues can be saturated for seconds, which delayed a
    // cancel scheduled there (#77).
    Thread.detachNewThread { Thread.sleep(forTimeInterval: 1); cancel.cancel() }
    #expect { try e.execute("voice.preview", params: ["text": "Bonjour.", "language": "fr"]) } throws: { "\($0)".contains("cancelled") }
    // Well under the model's 60 s: the cancel stopped it (alone about 1.2 s).
    #expect(Date().timeIntervalSince(started) < 20)
    // Refused until reset; after reset a new run may start (the folder is not "still running").
    #expect(throws: CommandError.self) { try e.execute("voice.preview", params: ["text": "Bonjour.", "language": "fr"]) }
    cancel.reset()
    try "#!/bin/sh\nexit 3\n".write(to: URL(fileURLWithPath: f.config.uv), atomically: true, encoding: .utf8)
    #expect { try e.execute("voice.preview", params: ["text": "Bonjour.", "language": "fr"]) } throws: { "\($0)".contains("exit 3") }
}

@Test func trainingProgressComesFromTheLogAndTheStatusSaysWhetherThisMacCanTrain() throws {
    let log = """
    [train] step 0: loss/diff: 0.88, epoch: 0.0
    [train] step 25: loss/diff: 0.90, epoch: 5.0, grad_norm: 0.08, log interval: 40.0s
    [train] step 50: loss/diff: 1.02, epoch: 10.0, grad_norm: 0.13, log interval: 30.0s
    """
    let p = VoiceEnrollment.trainingProgress(log: log, config: ["num_iters": 300])
    #expect(p.step == 50 && p.steps == 300)
    #expect(abs((p.minutesLeft ?? 0) - 249.0 * 30 / 25 / 60) < 0.01)
    #expect(VoiceEnrollment.trainingProgress(log: "", config: nil).step == nil)
    #expect(VoiceEnrollment.estimatedTrainingMinutes(seconds: 120) == 8)
    #expect(VoiceEnrollment.estimatedTrainingMinutes(seconds: 1500) > 100)

    let f = try VoiceFixture()
    for tier in [MachineTier.medium, .pro] {
        var fakes = FakeServices(tier: tier).make()
        fakes.profiles = f.profiles
        fakes.config.voxcpmProject = f.config.voxcpmProject
        let e = Engine(prober: FakeProber(), services: fakes)
        let s = try e.execute("voice.enroll.status")
        #expect(s.value(at: "trainer.available") == false)
        #expect(s.value(at: "trainer.reason")?.stringValue == (tier == .medium ? "tier" : "trainer"))
        let fr = try #require(s["languages"]?.arrayValue?.first { $0["language"] == "fr" })
        #expect(fr["trainMinimumSeconds"]?.doubleValue == 90)
        #expect(fr["trainedTones"]?.arrayValue?.compactMap(\.stringValue) == ["neutral", "serious"])
    }
}
