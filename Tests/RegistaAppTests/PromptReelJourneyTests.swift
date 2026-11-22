import AVFoundation
import Foundation
import RegistaCore
import Testing
@testable import Regista

// Journey 15: Claude makes a faceless reel from one sentence with the prompt-to-reel recipe (#144), through the tools while
// the window shows it. The voice is the rig's (a tone from a stub), the music a file of the test; nothing is generated,
// downloaded or paid. The HyperFrames scene is left out: the rig has no stand-in for it (its engine reads as missing), so
// the signature moment is a template. What Claude writes to the person (the plan, the report) is data here, and the edit is
// built from it.

/// One row of the scene plan Claude shows the person.
private struct PlannedScene {
    enum Music: String { case bed, build, stop }
    var words: String
    /// What is seen: a catalog template (nil: a title on the kit's own colour).
    var template: String?
    var fields: JSONValue = [:]
    var title: String?
    var transition = "cut"
    var music: Music
    /// The bank sound of the scene's action, and seconds from the scene's start to the action; `leads`: the J-cut, heard in
    /// the scene before, its loudest moment on this scene's first frame.
    var sound: (name: String, action: Double, leads: Bool)?

    var row: String {
        "\(words) | \(template ?? "title «\(title ?? "")»") | \(transition) | \(music.rawValue) | \(sound.map { $0.name + ($0.leads ? " (J-cut)" : "") } ?? "none")"
    }
}

private struct ReelPlan {
    let sentence = "Prima di registrare, leggi il testo ad alta voce una volta"
    let structures = ["una domanda e la sua risposta", "un errore e la sua correzione", "un conto alla rovescia"]
    let chosen = 1
    let subject = "leggere il testo", goal = "provarlo prima della prossima ripresa", turn = "non sei tu, è la riga"
    let opening = "Ripresa 7", ending = "Ripresa 1", signature = "il contatore che da 7 scende a 1"
    /// The scene of the turn (the near-silence is before it) and of the signature moment.
    let turnScene = 3, peakScene = 4
    let silence = 0.6
    let scenes: [PlannedScene] = [
        PlannedScene(words: "Settima volta, sempre quella.", title: "Ripresa 7", music: .bed),
        PlannedScene(words: "Inciampi sulla stessa riga.", template: "checklist",
                     fields: ["title": "LA STESSA RIGA", "rows": ["Troppo in fretta", "Troppo lunga"], "firstTick": 0.5, "interval": 0.6],
                     music: .bed, sound: ("tap/soft", 0.5, false)),
        PlannedScene(words: "E ricominci da capo.", template: "progress-rows", fields: ["rows": ["Ripresa 5", "Ripresa 6", "Ripresa 7"], "symbols": ["mic", "mic", "mic"]],
                     music: .bed),
        PlannedScene(words: "Il problema non sei tu.", template: "kicker-headline", fields: ["kicker": "SETTE VOLTE DOPO", "headline": "è la *riga*"],
                     transition: "dark stage", music: .build, sound: ("sub_drop/punch", 0, false)),
        PlannedScene(words: "Leggila ad alta voce, prima.", template: "counter",
                     fields: ["value": "1", "from": "7", "icon": "", "dim": 0, "label": "RIPRESE"], music: .bed, sound: ("riser/rush", 0, true)),
        PlannedScene(words: "Poi accendi la camera.", title: "Ripresa 1", music: .bed, sound: ("pluck/kalimba_soft", 0, false)),
    ]

    var text: String {
        "Strutture: \(structures.joined(separator: "; ")). Scelta: \(structures[chosen]). Soggetto: \(subject). Obiettivo: \(goal). Svolta: \(turn). "
            + "Apertura «\(opening)», finale «\(ending)». Momento: \(signature). "
            + "scena | parole | cosa si vede | passaggio | musica | suono: " + scenes.enumerated().map { "\($0.offset + 1) | \($0.element.row)" }.joined(separator: " // ")
    }
}

extension MouseSuites.ClickAudits.ToolJourneyTests {
    /// 15. A reel from one sentence through the tools, the prompt-to-reel recipe in its order: the plan (treatment, scenes,
    /// music and sound columns), the voice around a near-silence, the scenes from the catalog's templates, captions, music
    /// by section, the planned sounds, the contact sheet, the rules, the 9:16 file and every check on it.
    @Test func claudeMakesAReelFromOneSentence() async throws {
        let j = try await Journey("15-claude-prompt-to-reel", project: nil)
        defer { j.close() }
        try await j.claudePromptToReel()
    }
}

extension Journey {
    /// The loudness (dBFS, RMS) of a stretch of a movie's sound.
    nonisolated static func rms(_ url: URL, from: Double, to: Double) async throws -> Double {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first, "no sound in \(url.lastPathComponent)")
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                                                          AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        reader.add(out)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48000), end: CMTime(seconds: to, preferredTimescale: 48000))
        reader.startReading()
        var sum = 0.0, n = 0
        while let sample = out.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var floats = [Float](repeating: 0, count: CMBlockBufferGetDataLength(block) / 4)
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: floats.count * 4, destination: &floats)
            for f in floats { sum += Double(f) * Double(f) }
            n += floats.count
        }
        #expect(n > 0, "nothing read of \(from)–\(to) s")
        return 10 * log10(max(sum / Double(max(n, 1)), 1e-12))
    }

    /// Journey 15 (ToolJourneyTests.claudeMakesAReelFromOneSentence).
    func claudePromptToReel() async throws {
        let plan = ReelPlan()
        await open(Navigation(activity: .home, rightTab: .claude))
        let link = try await connectClaude()
        let recipe = await readRecipe(link, "prompt-to-reel", order: ["voice_list", "effects_catalog", "project_new", "brandkit_apply", "voice_say", "motion_add",
                                                                      "graphics_hyperframes", "captions_generate", "audio_addMusic", "sfx_add", "frame_contactSheet",
                                                                      "rules_check", "export_render", "sfx_checkOnsets", "audio_checkDucking", "captions_checkTiming",
                                                                      "export_srt", "project_save"])
        let mismatches = recipeParameters(recipe)
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
        let said = await claude(link, "recipe.get", ["name": "prompt-to-reel", "language": "it"])
        #expect(said.reply.result?["kind"] == "voice-over-video" && said.reply.result?["text"]?.stringValue?.contains("Un solo soggetto, un solo obiettivo e una sola svolta") == true,
                "the recipe does not carry the rules of every video")

        // 1–3. What there is, then the plan: nothing is built before it.
        let catalog = await claude(link, "effects.catalog", ["category": "templates", "brief": true])
        let templates = Set(catalog.reply.result?["items"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? [])
        let planned = plan.scenes.compactMap(\.template)
        #expect(planned.allSatisfy(templates.contains), "the plan names templates the catalog does not have: \(planned.filter { !templates.contains($0) })")
        let library = await claude(link, "sfx.library")
        let bank = Dictionary((library.reply.result?["effects"]?.arrayValue ?? []).compactMap { e in e["name"]?.stringValue.map { ($0, e["peak"]?.doubleValue ?? 0) } },
                              uniquingKeysWith: { a, _ in a })
        let sounds = plan.scenes.compactMap(\.sound)
        #expect(sounds.allSatisfy { bank[$0.name] != nil }, "the plan names sounds the bank does not have")
        #expect(plan.structures.count == 3 && plan.scenes.contains { $0.music == .build } && plan.scenes.contains { $0.sound?.leads == true })
        #expect(store.project == nil, "something was built before the plan")
        step("«\(plan.sentence)»: effects_catalog, sfx_library, then the plan", sees: await seesClaude("sfx.library", library.reply) + "; nothing built; \(plan.text)")

        // The person's voice (seeded: the rig's, a tone).
        _ = await claude(link, "profile.create", ["name": "Prova"])
        try await recordTheVoice()
        let voices = await claude(link, "voice.list")
        #expect(voices.reply.result?["languages"]?.arrayValue?.contains { $0["language"] == "it" && $0["ready"] == true } == true, "voice_list: \(voices.reply.text.prefix(200))")

        // 4. The project, of the kind the recipe says.
        let name = "Una frase"
        let made = await claude(link, "project.new", ["name": .string(name), "directory": .string(scratch.path), "kind": "voice-over-video"])
        #expect(!made.reply.isError && store.project?.settings.width == 1080 && store.project?.settings.height == 1920, "project_new: \(made.reply.text.prefix(200))")
        step("The person says yes; project_new {kind: voice-over-video}", sees: await seesClaude("project.new", made.reply))
        let kit = await claude(link, "brandkit.apply", ["kit": "cafe-atelier"])
        #expect(!kit.reply.isError, "brandkit_apply: \(kit.reply.text.prefix(200))")
        step("brandkit_apply {kit: cafe-atelier}", sees: await seesClaude("brandkit.apply", kit.reply))

        // 5. The voice: the lines up to the turn, then the rest after the near-silence. The rig's voice is a tone: with
        // nothing heard in it, the words are the script's, spread over each clip.
        RigHearing.words = []
        defer { RigHearing.words = nil }
        func say(_ lines: [String], at: Double) async throws -> [(start: Double, end: Double)] {
            let r = await claude(link, "voice.say", ["text": .string(lines.joined(separator: "\n\n")), "language": "it", "at": .number(at), "gap": 1.1], timeout: 180)
            #expect(!r.reply.isError, "voice_say: \(r.reply.text.prefix(300))")
            let clips = (r.reply.result?["clips"]?.arrayValue ?? []).compactMap { c -> (start: Double, end: Double)? in
                guard let s = c["start"]?.doubleValue, let d = c["duration"]?.doubleValue else { return nil }
                return (s, s + d)
            }
            #expect(clips.count == lines.count, "\(clips.count) clips for \(lines.count) lines")
            step("voice_say (\(lines.count) lines, at \(String(format: "%.2f", at)) s)", sees: await seesClaude("voice.say", r.reply))
            return clips
        }
        let before = try await say(plan.scenes[..<plan.turnScene].map(\.words), at: 0.3)
        let silenceStart = try #require(before.last).end
        let after = try await say(plan.scenes[plan.turnScene...].map(\.words), at: silenceStart + plan.silence)
        let voice = before + after
        try #require(voice.count == plan.scenes.count)
        let silenceEnd = voice[plan.turnScene].start
        let starts = voice.indices.map { $0 == 0 ? 0 : voice[$0].start }
        let end = try #require(voice.last).end + 1.4
        func sceneEnd(_ i: Int) -> Double { i == plan.turnScene - 1 ? silenceStart : i + 1 < starts.count ? starts[i + 1] : end }

        // 6. The scenes: the kit's own colour, the dark stage for the turn and the peak, one template or title each.
        let stage = await claude(link, "motion.add", ["template": "background-scene", "start": .number(silenceStart), "fields": ["style": "dark-grid"],
                                                      "duration": .number(starts[plan.peakScene + 1] - silenceStart)])
        #expect(!stage.reply.isError, "motion_add background-scene: \(stage.reply.text.prefix(200))")
        for (i, s) in plan.scenes.enumerated() {
            let length = JSONValue.number(sceneEnd(i) - starts[i])
            if let template = s.template {
                let r = await claude(link, "motion.add", ["template": .string(template), "start": .number(starts[i]), "duration": length, "fields": s.fields, "band": "middle"])
                #expect(!r.reply.isError && r.reply.result?["warnings"]?.arrayValue?.isEmpty != false, "motion_add \(template): \(r.reply.text.prefix(300))")
                step("motion_add \(template) (scene \(i + 1))", sees: await seesClaude("motion.add", r.reply))
            } else {
                let r = await claude(link, "title.add", ["text": .string(s.title ?? ""), "start": .number(starts[i]), "duration": length, "size": 140, "background": "none",
                                                         "animIn": i == 0 ? "none" : "pop", "animOut": "none", "band": "middle"])
                #expect(!r.reply.isError, "title_add: \(r.reply.text.prefix(200))")
                step("title_add «\(s.title ?? "")» (scene \(i + 1))", sees: await seesClaude("title.add", r.reply))
            }
        }

        // 9. Captions from the voice.
        let voiceTrack = try #require(store.project?.tracks.first { $0.kind == .audio && !$0.clips.isEmpty && $0.clips.allSatisfy { store.project?.asset($0.assetID)?.generated != nil } })
        let captions = await claude(link, "captions.generate", ["style": "talking-head-v1", "keywords": ["RIGA", "VOCE"], "sourceTrackId": .string(voiceTrack.id)])
        let spokenWords = plan.scenes.reduce(0) { $0 + $1.words.split(separator: " ").count }
        #expect(!captions.reply.isError && captions.reply.result?["words"]?.doubleValue == Double(spokenWords), "\(spokenWords) words said: \(captions.reply.text.prefix(300))")
        step("captions_generate {sourceTrackId: the voice}", sees: await seesClaude("captions.generate", captions.reply))
        let cleared = await claude(link, "captions.clear", ["from": .number(silenceStart), "to": .number(silenceEnd)])
        #expect(!cleared.reply.isError, "captions_clear: \(cleared.reply.text.prefix(300))")
        let chunks = store.project?.tracks.first { $0.captions != nil }?.captions?.chunks ?? []
        let lingering = chunks.filter { ch in
            let from = ch.words.first?.start.seconds ?? ch.end.seconds
            return from < silenceEnd - 0.02 && ch.end.seconds > silenceStart + 0.02
        }
        #expect(lingering.isEmpty, "a caption is on screen in the near-silence")
        step("captions_clear over the near-silence", sees: await seesClaude("captions.clear", cleared.reply))

        // 10. Music by section (bed, stop, build, bed), then every planned sound on its action.
        let bed = try music("base.wav", seconds: 30)
        let peak = starts[plan.peakScene]
        for (what, args) in [("bed", ["start": 0, "end": .number(silenceStart), "fadeOut": 0.15]),
                             ("build", ["start": .number(silenceEnd + 0.4), "end": .number(peak), "level": -19, "fadeIn": 0.8, "fadeOut": 0.05]),
                             ("bed", ["start": .number(peak), "end": .number(end), "sourceIn": 4, "fadeIn": 0.05])] as [(String, [String: JSONValue])] {
            var p = args
            p["path"] = .string(bed.path)
            let r = await claude(link, "audio.addMusic", .object(p), timeout: 180)
            #expect(!r.reply.isError, "audio_addMusic (\(what)): \(r.reply.text.prefix(300))")
            step("audio_addMusic (\(what))", sees: await seesClaude("audio.addMusic", r.reply))
        }
        var plannedAt: [(name: String, at: Double)] = []
        for (i, s) in plan.scenes.enumerated() {
            guard let sound = s.sound else { continue }
            let at = starts[i] + sound.action - (bank[sound.name] ?? 0) * (sound.leads ? 1 : 0)
            let r = await claude(link, "sfx.add", ["name": .string(sound.name), "at": .number(at), "volume": 0.3])
            #expect(!r.reply.isError, "sfx_add \(sound.name): \(r.reply.text.prefix(200))")
            plannedAt.append((sound.name, at))
            step("sfx_add \(sound.name) (scene \(i + 1)\(sound.leads ? ", J-cut" : ""))", sees: await seesClaude("sfx.add", r.reply))
        }
        let placed = store.project?.tracks.filter { $0.role == "sfx" }.flatMap(\.clips) ?? []
        #expect(placed.count == plannedAt.count && plannedAt.allSatisfy { p in placed.contains { abs($0.start.seconds - p.at) < 0.001 } }, "the planned sounds are not all on the timeline")
        // The J-cut starts in the scene before its picture; nothing sounds in the near-silence.
        let jcut = try #require(plannedAt.first { $0.name == "riser/rush" })
        #expect(jcut.at < peak && jcut.at > silenceEnd, "the J-cut starts at \(jcut.at) s, its picture at \(peak) s")
        let audible = store.project?.tracks.filter { $0.kind == .audio }.flatMap(\.clips) ?? []
        #expect(silenceEnd - silenceStart >= 0.4 && !audible.contains { $0.start.seconds < silenceEnd - 0.02 && $0.end.seconds > silenceStart + 0.02 },
                "something sounds in the near-silence \(silenceStart)–\(silenceEnd) s")

        // 11. Look: frame 0 and one time in the middle of each scene (for the reviewer, full size beside the snapshots).
        let sheetFile = Self.folder.appendingPathComponent("\(self.name)-sheet.jpg")
        let first = await claude(link, "frame.render", ["time": 0, "path": .string(Self.folder.appendingPathComponent("\(self.name)-frame0.png").path), "inline": false])
        #expect(!first.reply.isError, "frame_render: \(first.reply.text.prefix(200))")
        let times = plan.scenes.indices.map { JSONValue.number((starts[$0] + sceneEnd($0)) / 2) } + [.number((silenceStart + silenceEnd) / 2)]
        let sheet = await claude(link, "frame.contactSheet", ["times": .array(times), "path": .string(sheetFile.path)])
        #expect(!sheet.reply.isError && FileManager.default.fileExists(atPath: sheetFile.path), "frame_contactSheet: \(sheet.reply.text.prefix(200))")
        step("frame_render {time: 0}, frame_contactSheet", sees: await seesClaude("frame.contactSheet", sheet.reply))

        // 12. Is it this reel's own? Claude's comparison, as it says it to the person.
        let own = ["struttura": true, "apertura": true, "momento": false, "forma della musica": true, "finale": true]
        #expect(own.values.filter { $0 }.count >= 3)

        // 13. The checks, one round of fixes, the export, the checks on the file.
        var verdicts: [String: String] = [:]
        let rules = await claude(link, "rules.check")
        #expect(rules.reply.result?["kind"] == "voice-over-video")
        let failing = rules.reply.result?["violations"]?.arrayValue?.filter { $0["severity"] == "fail" }.compactMap { $0["check"]?.stringValue } ?? []
        step("rules_check", sees: await seesClaude("rules.check", rules.reply) + "; failing: \(failing)")
        verdicts["regole"] = "passato"
        if !failing.isEmpty {
            let fixed = await claude(link, "rules.fix", ["all": true])
            #expect(fixed.reply.result?.value(at: "check.pass") == true, "rules_fix: \(fixed.reply.text.prefix(300))")
            step("rules_fix {all: true}", sees: await seesClaude("rules.fix", fixed.reply))
            verdicts["regole"] = "corretto"
            // Looked at again after the fixes.
            let again = await claude(link, "frame.contactSheet", ["times": .array(times), "path": .string(sheetFile.path)])
            #expect(!again.reply.isError, "frame_contactSheet: \(again.reply.text.prefix(200))")
        }
        let layout = await claude(link, "graphics.checkLayout")
        #expect(layout.reply.result?["pass"] == true, "graphics_checkLayout: \(layout.reply.text.prefix(300))")
        verdicts["impaginazione"] = "passato"
        let movie = scratch.appendingPathComponent("una-frase.mp4")
        let export = await claude(link, "export.render", ["path": .string(movie.path), "preset": "9:16", "loudness": -15], timeout: 240)
        #expect(!export.reply.isError && FileManager.default.fileExists(atPath: movie.path), "export_render: \(export.reply.text.prefix(300))")
        step("export_render {preset: 9:16, loudness: -15}", sees: await seesClaude("export.render", export.reply))
        for (label, tool, args) in [("suoni", "sfx.checkOnsets", ["path": .string(movie.path)]), ("musica sotto la voce", "audio.checkDucking", [:]),
                                    ("sottotitoli", "captions.checkTiming", ["path": .string(movie.path)])] as [(String, String, JSONValue)] {
            let r = await claude(link, tool, args, timeout: 180)
            #expect(!r.reply.isError && r.reply.result?["pass"] == true, "\(tool): \(r.reply.text.prefix(400))")
            if tool == "sfx.checkOnsets" { #expect(r.reply.result?["effects"]?.doubleValue == Double(plannedAt.count), "\(r.reply.text.prefix(200))") }
            verdicts[label] = r.reply.result?["pass"] == true ? "passato" : "problema noto"
            step(MCPToolName(tool), sees: await seesClaude(tool, r.reply))
        }
        // The file: 9:16, as long as the edit, captions in it, the near-silence in its sound.
        let exported = try await Journey.probe(movie)
        #expect(exported.width == 1080 && exported.height == 1920 && abs(exported.seconds - (store.project?.duration.seconds ?? 0)) < 0.1, "exported \(exported)")
        #expect((store.project?.tracks.first { $0.captions != nil }?.captions?.chunks.count ?? 0) > 0, "no captions in the exported edit")
        let quiet = try await Journey.rms(movie, from: silenceStart + 0.08, to: silenceEnd - 0.08), loud = try await Journey.rms(movie, from: voice[1].start, to: voice[1].end)
        #expect(quiet < -50 && loud > quiet + 25, "the near-silence is \(quiet) dBFS, the speech \(loud) dBFS")
        verdicts["scena HyperFrames"] = "non controllato"
        verdicts["ascolto"] = "non controllato"
        #expect(Set(verdicts.values).isSubset(of: ["passato", "corretto", "problema noto", "non controllato"]))

        let srt = scratch.appendingPathComponent("una-frase.srt")
        let subtitles = await claude(link, "export.srt", ["path": .string(srt.path)])
        #expect(!subtitles.reply.isError && FileManager.default.fileExists(atPath: srt.path), "export_srt: \(subtitles.reply.text.prefix(200))")
        let saved = await claude(link, "project.save")
        #expect(!saved.reply.isError && !store.dirty, "project_save: \(saved.reply.text.prefix(200))")
        step("export_srt, project_save", sees: await seesClaude("project.save", saved.reply) + "; \(exported.width)×\(exported.height), \(String(format: "%.2f", exported.seconds)) s; "
             + "silence \(String(format: "%.1f", quiet)) dBFS, speech \(String(format: "%.1f", loud)) dBFS; " + verdicts.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", "))
    }

    private func MCPToolName(_ command: String) -> String { command.replacingOccurrences(of: ".", with: "_") }
}
