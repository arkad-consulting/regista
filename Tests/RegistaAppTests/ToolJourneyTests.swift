import AppKit
import RegistaCore
import RegistaMCP
import Testing
@testable import Regista

// Journeys 10 and 11: Claude follows a recipe through the tools while the window shows it, the route of journey 8 (an
// MCP server on the running app's engine socket, as regista-mcp runs it), with the rig's stand-in engines: the
// voice-over-video recipe with the rig's voice (a tone from a stub, nothing loaded, nothing played), and the
// screen-tutorial recipe on a screen recording made in the rig with the capture stand-in.

/// A transcription that hears what the test says was read (the seeding of the person's voice).
private struct Heard: RegistaCore.Transcriber {
    var id: String
    var model = "heard"
    let words: [RegistaCore.Word]
    func unavailableReason() -> String? { nil }
    func transcribe(_ speech16k: URL, language: String) throws -> RegistaCore.Transcript {
        RegistaCore.Transcript(engine: id, model: model, language: language, words: words)
    }
}

/// `sentences` read one after the other from 1 s: 0.35 s a word, 0.8 s between sentences.
private func spoken(_ sentences: [String]) -> [RegistaCore.Word] {
    var t = 1.0, out: [RegistaCore.Word] = []
    for s in sentences {
        for w in s.split(separator: " ") { out.append(RegistaCore.Word(text: String(w), start: MediaTime(seconds: t), end: MediaTime(seconds: t + 0.3))); t += 0.35 }
        t += 0.8
    }
    return out
}

private final class Box<T>: @unchecked Sendable { var value: T?; init() {} }

extension Journey {
    /// Claude connects to the window's app the way regista-mcp does.
    func connectClaude(sourceLocation: SourceLocation = #_sourceLocation) async throws -> ClaudeLink {
        let socket = EngineSocket.defaultPath()
        let box = Box<ClaudeLink>(), done = Box<Bool>()
        Task.detached { box.value = try? ClaudeLink(socket: socket); done.value = true }
        #expect(await until(10) { done.value == true }, "Claude did not connect", sourceLocation: sourceLocation)
        let link = try #require(box.value, "Claude could not connect to the app's socket", sourceLocation: sourceLocation)
        #expect(await until(3) { shows(loc("Claude collegato")) }, "the pill does not say Claude is connected: \(screen())", sourceLocation: sourceLocation)
        return link
    }

    /// recipe_get {name}: every tool it names exists, and `order` comes in that order. Returns its text.
    func readRecipe(_ link: ClaudeLink, _ name: String, order: [String], sourceLocation: SourceLocation = #_sourceLocation) async -> String {
        let recipe = await claude(link, "recipe.get", ["name": .string(name)])
        #expect(!recipe.reply.isError, "recipe_get: \(recipe.reply.text)", sourceLocation: sourceLocation)
        let text = recipe.reply.result?["text"]?.stringValue ?? recipe.reply.text
        let tools = Set(link.toolNames)
        let words = text.components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "_")).inverted)
        let named = Set(words.filter { $0.contains("_") && !$0.hasSuffix("_") && $0.first?.isLowercase == true })
            .filter { n in Commands.all.contains { MCPServer.toolName($0.id).hasPrefix(n.split(separator: "_")[0] + "_") } }
        #expect(named.subtracting(tools).isEmpty, "the recipe names tools that do not exist: \(named.subtracting(tools).sorted())", sourceLocation: sourceLocation)
        // In the steps (the recipe's introduction names a few tools first).
        let steps = text.range(of: "## Steps")?.upperBound ?? text.startIndex
        let positions = order.map { text.range(of: $0, range: steps..<text.endIndex)?.lowerBound }
        #expect(positions.allSatisfy { $0 != nil }, "the recipe does not name \(zip(order, positions).filter { $0.1 == nil }.map(\.0))", sourceLocation: sourceLocation)
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted(), "the recipe does not name \(order) in this order", sourceLocation: sourceLocation)
        step("recipe_get {name: \(name)}", sees: "\(await seesClaude("recipe.get", recipe.reply)); the recipe names \(named.count) tools, all of them exist")
        return text
    }

    /// The person's voice, recorded in the app (Voce › «Inizia a clonare la tua voce»): its consent and 30 neutral lines
    /// heard from a synthetic take, added on the rig's own services with a transcription that hears them (VoiceClickTests).
    func recordTheVoice(language: String = "it") async throws {
        let services = app.store.engine.context.services
        let script = try RecordingScript.load(language: language, config: services.config)
        var seeding = services
        let name = try #require((try? services.profiles.active())??.profile.name, "no profile to record the voice of")
        let heard = Heard(id: WhisperCppTranscriber.engineID, words: spoken([script.consent(name: name)] + script.lines("neutral").prefix(30)))
        seeding.transcribers = [WhisperCppTranscriber.engineID: heard, WhisperXTranscriber.engineID: Heard(id: WhisperXTranscriber.engineID, words: heard.words)]
        let take = scratch.appendingPathComponent("neutral.wav")
        let rate = 16_000
        let samples = (0..<(180 * rate)).map { i in Float(0.2 * sin(2 * .pi * 180 * Double(i) / Double(rate))) }
        try WAVAudio(sampleRate: rate, channels: 1, samples: samples).write16(to: take)
        _ = try Engine(services: seeding).execute("voice.enroll.add", params: ["path": .string(take.path), "language": .string(language), "tone": "neutral"])
        await app.store.voice.refresh()
    }
}

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct ToolJourneyTests {
    /// 10. A voice-over video through the tools, the voice-over-video recipe in its order, the rig's voice: voice_list
    /// with no profile and no voice says what the person does in the app, as the Voce panel does; voice_say in a voice
    /// the profile does not have is refused and the window says why; voice_preview, voice_say, the picture under the
    /// voice, captions from the voice, the rules, export_render with the AI-voice note in Esporta (not for a project
    /// without a generated voice), export_srt, project_save. After each command the window agrees with the result.
    @Test func claudeMakesAVoiceOverVideo() async throws {
        let j = try await Journey("10-claude-voice-over", project: nil)
        defer { j.close() }
        try await j.claudeVoiceOver()
    }
}
}

extension Journey {
    /// The Voce panel of the window (the Voce activity), what it shows now.
    func voicePanelShows(_ text: String) async -> Bool {
        let back = store.nav
        store.nav = Navigation(activity: .voice, rightTab: back.rightTab)
        await app.settle()
        let seen = await until(3) { shows(text) }
        store.nav = back
        await app.settle()
        return seen
    }

    /// Journey 10 (ToolJourneyTests.claudeMakesAVoiceOverVideo).
    func claudeVoiceOver() async throws {
        let footage = try take("riprese.mov")
        await open(Navigation(activity: .home, rightTab: .claude))
        let link = try await connectClaude()
        step("Claude connects", sees: "«Claude collegato», the Claude panel open")
        let recipeText = await readRecipe(link, "voice-over-video", order: ["voice_list", "project_new", "voice_preview", "voice_say", "timeline_place",
                                                               "captions_generate", "frame_contactSheet", "rules_check", "export_render", "export_srt", "project_save"])

        // 1. voice_list: no profile on this Mac. The recipe's first step and the reply say the same next step, and so does
        // the Voce panel.
        let none = await claude(link, "voice.list")
        #expect(!none.reply.isError && none.reply.result?["profile"] == .null, "voice_list: \(none.reply.text.prefix(200))")
        #expect(await voicePanelShows(loc("Inizia a clonare la tua voce")), "the Voce panel does not offer to clone the voice: \(screen())")
        step("voice_list (no profile)", sees: await seesClaude("voice.list", none.reply) + "; the Voce panel: «Clona la tua voce», «Inizia a clonare la tua voce»; the reply's note: \(none.reply.result?["note"]?.stringValue ?? "none")")
        let made = await claude(link, "profile.create", ["name": "Prova"])
        #expect(!made.reply.isError, "profile_create: \(made.reply.text.prefix(200))")
        step("profile_create {name: Prova}", sees: await seesClaude("profile.create", made.reply))
        let empty = await claude(link, "voice.list")
        #expect(empty.reply.result?["languages"]?.arrayValue?.isEmpty == true, "voice_list after profile_create: \(empty.reply.text.prefix(200))")
        #expect(await voicePanelShows(loc("Inizia a clonare la tua voce")), "the Voce panel does not show the next step for a profile without a voice: \(screen())")
        // The reply and the recipe's first step name the same next step: the Voce panel (#85).
        let note = empty.reply.result?["note"]?.stringValue ?? ""
        #expect(note.contains("Voce panel") && recipeText.contains("Voce panel"), "voice_list's note «\(note)» and the recipe disagree on the next step")
                step("voice_list (a profile, no voice)", sees: await seesClaude("voice.list", empty.reply) + "; the Voce panel shows the same next step; the note: \(empty.reply.result?["note"]?.stringValue ?? "none")")

        // The person records their voice in the app (seeded: the rig's voice, a tone).
        try await recordTheVoice()
        let ready = await claude(link, "voice.list")
        let languages = ready.reply.result?["languages"]?.arrayValue ?? []
        let italian = languages.contains { $0["language"] == "it" && $0["ready"] == true }
        #expect(italian, "the voice is not ready: \(ready.reply.text.prefix(300))")
        #expect(await voicePanelShows("Prova"), "the Voce panel does not name the profile's voice: \(screen())")
        step("The person records their voice; voice_list", sees: await seesClaude("voice.list", ready.reply) + "; the Voce panel names «Prova»")

        // 2. project_new.
        let name = "Voce di Claude"
        let project = await claude(link, "project.new", ["name": .string(name), "directory": .string(scratch.path), "kind": "voice-over-video"])
        #expect(!project.reply.isError && store.project?.name == name, "project_new: \(project.reply.text.prefix(200))")
        step("project_new {kind: voice-over-video}", sees: await seesClaude("project.new", project.reply))

        // 3. voice_preview (estimate only), then voice_say in a voice the profile does not have: refused.
        let text = "Oggi Regista monta il video da solo.\n\nLa voce è la tua, clonata su questo Mac."
        let preview = await claude(link, "voice.preview", ["text": .string(text), "language": "it", "estimate": true])
        #expect(!preview.reply.isError && preview.reply.result?["paragraphs"]?.arrayValue?.count == 2, "voice_preview: \(preview.reply.text.prefix(200))")
        step("voice_preview {estimate: true}", sees: await seesClaude("voice.preview", preview.reply))
        let clipsBefore = store.project?.tracks.flatMap(\.clips).count ?? 0
        let other = await claude(link, "voice.say", ["text": .string(text), "language": "en"])
        #expect(other.reply.isError, "voice_say in a language the profile has no voice for was not refused: \(other.reply.text.prefix(200))")
        #expect(store.project?.tracks.flatMap(\.clips).count == clipsBefore, "the refused voice_say changed the edit")
        let refusal = store.activity.last { $0.command == "voice.say" }
        let why = refusal?.result ?? ""
        let failed = refusal?.status == .failed
        let shown = !why.isEmpty && shows(String(why.prefix(30)))
        #expect(failed && shown, "the window does not say why voice_say was refused: \(why)")
        step("voice_say {language: en} (no English voice)", sees: await seesClaude("voice.say", other.reply) + "; the panel: «\(refusal?.result.prefix(120) ?? "")»")

        // 4. voice_say: the clips on the Voce track, their text in the Inspector, the profile's voice named in Voce.
        let said = await claude(link, "voice.say", ["text": .string(text), "language": "it", "tone": "neutral", "at": 0, "gap": 0.3], timeout: 180)
        #expect(!said.reply.isError, "voice_say: \(said.reply.text.prefix(300))")
        let voiceTrack = try #require(store.project?.tracks.first { $0.kind == .audio && !$0.clips.isEmpty && $0.clips.allSatisfy { store.project?.asset($0.assetID)?.generated != nil } },
                                      "no voice track: \(store.project?.tracks.map { "\($0.name) \($0.clips.count)" } ?? [])")
        #expect(voiceTrack.clips.count == 2, "\(voiceTrack.clips.count) voice clips for two paragraphs")
        // Each clip's file is named by the words it says (#86: «voxcpm voice: …»).
        let names = voiceTrack.clips.compactMap { store.project?.asset($0.assetID)?.name }
        #expect(names.first == "Oggi Regista monta il video da solo." && !names.contains { $0.contains("voxcpm") }, "the voice clips are named \(names)")
        let sayLine = await seesClaude("voice.say", said.reply)
        let first = try #require(voiceTrack.clips.first)
        rig.click(CGPoint(x: try #require(timelineX((first.start.seconds + first.end.seconds) / 2)), y: try #require(laneY(voiceTrack.name) ?? laneY("A1"))))
        await app.settle()
        try await tap("Ispettore")
        #expect(await until(3) { shows("Oggi Regista monta il video da solo.") }, "the Inspector does not show the voice clip's text: \(screen())")
        step("voice_say (two paragraphs, it); clicks the first voice clip, the Inspector", sees: sayLine + "; \(voiceTrack.clips.count) clips on «\(voiceTrack.name)», the first one's text in the Inspector")
        try await tap("Claude")

        // 5. The picture under the voice: media_import, track_add, timeline_place.
        let imported = await claude(link, "media.import", ["path": .string(footage.path)])
        let asset = try #require(imported.reply.result?.value(at: "asset.id")?.stringValue, "media_import: \(imported.reply.text.prefix(200))")
        step("media_import riprese.mov", sees: await seesClaude("media.import", imported.reply))
        var videoTrack = store.project?.tracks.first { $0.kind == .video && $0.role == nil }?.id
        if videoTrack == nil || store.project?.tracks.first(where: { $0.id == videoTrack })?.clips.isEmpty == false {
            let added = await claude(link, "track.add", ["kind": "video"])
            videoTrack = added.reply.result?.value(at: "track.id")?.stringValue
            step("track_add {kind: video}", sees: await seesClaude("track.add", added.reply))
        }
        let end = store.project?.duration.seconds ?? 4
        let placed = await claude(link, "timeline.place", ["assetId": .string(asset), "trackId": .string(try #require(videoTrack)), "start": 0, "sourceIn": 0, "sourceOut": .number(min(6, end))])
        #expect(!placed.reply.isError, "timeline_place: \(placed.reply.text.prefix(200))")
        step("timeline_place the footage under the voice", sees: await seesClaude("timeline.place", placed.reply))

        // 6. captions_generate from the voice, frame_contactSheet.
        let captions = await claude(link, "captions.generate", ["style": "talking-head-v1", "keywords": ["REGISTA", "MAC"], "sourceTrackId": .string(voiceTrack.id)])
        #expect(!captions.reply.isError && store.project?.tracks.contains { $0.captions != nil } == true, "captions_generate: \(captions.reply.text.prefix(200))")
        step("captions_generate {sourceTrackId: the voice}", sees: await seesClaude("captions.generate", captions.reply))
        let sheet = await claude(link, "frame.contactSheet")
        step("frame_contactSheet", sees: await seesClaude("frame.contactSheet", sheet.reply))

        // 7. rules_check (and the fixes), export_render: the AI-voice note in Esporta.
        let check = await claude(link, "rules.check")
        step("rules_check", sees: await seesClaude("rules.check", check.reply))
        if check.reply.result?["pass"] != true {
            let fixed = await claude(link, "rules.fix", ["all": true])
            step("rules_fix {all: true}", sees: await seesClaude("rules.fix", fixed.reply))
        }
        let movie = scratch.appendingPathComponent("voce.mp4")
        let export = await claude(link, "export.render", ["path": .string(movie.path), "preset": "9:16"], timeout: 180)
        #expect(!export.reply.isError && FileManager.default.fileExists(atPath: movie.path), "export_render: \(export.reply.text.prefix(300))")
        #expect(export.reply.result?["aiDisclosure"] != nil, "export_render does not carry the AI-voice note")
        step("export_render {preset: 9:16}", sees: await seesClaude("export.render", export.reply))
        try await tap("Esporta")
        #expect(await until(3) { shows(loc("Voce generata con IA")) }, "Esporta does not show the AI-voice note for a project with a generated voice: \(screen())")
        step("Clicks Esporta", sees: "«Voce generata con IA» with the sentence to copy")

        // 8. export_srt, project_save.
        let srt = await claude(link, "export.srt", ["path": .string(scratch.appendingPathComponent("voce.srt").path)])
        #expect(!srt.reply.isError, "export_srt: \(srt.reply.text.prefix(200))")
        step("export_srt", sees: await seesClaude("export.srt", srt.reply))
        let saved = await claude(link, "project.save")
        #expect(!saved.reply.isError && !store.dirty, "project_save: \(saved.reply.text.prefix(200))")
        step("project_save", sees: await seesClaude("project.save", saved.reply))

        // A project without a generated voice: no note in Esporta.
        try await tap("Nuova scheda")
        let plain = await claude(link, "project.new", ["name": "Senza voce", "directory": .string(scratch.path)])
        _ = await claude(link, "media.import", ["path": .string(footage.path)])
        #expect(!plain.reply.isError && store.project?.name == "Senza voce", "project_new: \(plain.reply.text.prefix(200))")
        try await tap("Esporta")
        await app.idle(0.5)
        #expect(!shows(loc("Voce generata con IA")), "Esporta shows the AI-voice note for a project without a generated voice")
        step("Another tab, a project with only footage; Esporta", sees: "no AI-voice note")
    }
}

