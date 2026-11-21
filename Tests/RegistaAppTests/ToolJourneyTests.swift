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
        // In words (#88): the profile and the language by its name, read whole in the panel.
        #expect(why == String(format: loc("Il profilo «%1$@» non ha una voce in %2$@: registrala nel pannello Voce."), "Prova", loc("inglese")),
                "the refused voice_say reads «\(why)»")
        let shown = !why.isEmpty
        let whole = await inClaudePanel { shows(why) }
        #expect(failed && shown && whole, "the window does not say why voice_say was refused: \(why)")
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

extension MouseSuites.ClickAudits.ToolJourneyTests {
    /// 11. A screen tutorial through the tools, the screen-tutorial recipe in its order, from a screen recording made in
    /// the rig with the capture stand-in (screen + camera, as journey 3 records it): the recording's layout, the automatic
    /// zoom, the cursor and the keys, a callout, captions, the rules of this kind of video (its sheet, not the reel's;
    /// «Logo nel video» puts the logo in the corner for the whole video), export 16:9. After each command the window
    /// agrees with the result.
    @Test func claudeMakesAScreenTutorial() async throws {
        let j = try await Journey("11-claude-screen-tutorial", project: nil)
        defer { j.close() }
        try await j.claudeScreenTutorial()
    }
}

extension Journey {
    /// Journey 11 (ToolJourneyTests.claudeMakesAScreenTutorial).
    func claudeScreenTutorial() async throws {
        // The person records the screen with the camera (journey 3's start, not proven again).
        app.capture.take = try take()
        app.capture.screen = true
        app.followRecorder()
        await open(Navigation(activity: .home, rightTab: .claude))
        try await tap("Registra")
        try await tap("Schermo + volto")
        #expect(await until { control("Avvia / Ferma registrazione")?.enabled == true }, "Record is not ready: \(screen())")
        try await tap("Avvia / Ferma registrazione")
        #expect(await until { app.recorder.isRecording })
        await app.idle(1)
        try await tap("Avvia / Ferma registrazione")
        #expect(await until(40) { app.store.bench.notice != nil && store.project?.recordings?.isEmpty == false }, "the session went nowhere: \(screen())")
        await app.settle()
        // Registra stays on screen after a take (#140): the notice's «Vai al montaggio» opens the editor.
        try await tap("Apri il montaggio con questa ripresa in Sorgente")
        // The take's session.json, where the recorder left it (the recording's project names it).
        let session = URL(fileURLWithPath: try #require(store.project?.recordings?.first?.session, "no screen session")).deletingLastPathComponent()
        step("The person records the screen with the camera (Registra › Schermo + volto)", sees: "the session's project in its tab")

        let link = try await connectClaude()
        _ = await readRecipe(link, "screen-tutorial", order: ["media_list", "project_new", "recording_import", "layout_apply", "edit_autoZoom", "cursor_style",
                                                              "keys_overlay", "transcript_run", "audio_clean", "captions_generate", "frame_contactSheet",
                                                              "rules_check", "export_render", "recording_check", "project_save"])

        // 1. project_new 16:9 (a new tab: the active one holds the recording's project).
        let name = "Tutorial di Claude"
        let made = await claude(link, "project.new", ["name": .string(name), "directory": .string(scratch.path), "width": 1920, "height": 1080, "kind": "screen-tutorial"])
        #expect(!made.reply.isError && store.project?.name == name && store.project?.settings.width == 1920, "project_new: \(made.reply.text.prefix(200))")
        #expect(await until(3) { shows("Formato 16:9") }, "the toolbar does not say 16:9: \(screen())")
        step("project_new {1920×1080, kind: screen-tutorial}", sees: await seesClaude("project.new", made.reply) + "; «Formato 16:9»")

        // 2. recording_import: screen, camera above it, microphone, in sync.
        let imported = await claude(link, "recording.import", ["path": .string(session.path), "faces": true], timeout: 180)
        #expect(!imported.reply.isError, "recording_import: \(imported.reply.text.prefix(300))")
        let assets = imported.reply.result?["assets"]
        #expect(store.project?.recordings?.count == 1 && (store.project?.tracks.flatMap(\.clips).count ?? 0) >= 2, "the window's project has no recording")
        #expect(drawn.contains { $0.kind == .layoutBox } || store.project?.tracks.contains { $0.role == "camera" } == true, "no camera on the picture")
        step("recording_import {faces: true}", sees: await seesClaude("recording.import", imported.reply) + "; tracks \(store.project?.tracks.map(\.name).joined(separator: ", ") ?? "")")

        // 3. layout_presets, layout_apply: the bubble in the corner.
        let presets = await claude(link, "layout.presets")
        step("layout_presets", sees: await seesClaude("layout.presets", presets.reply))
        let layout = await claude(link, "layout.apply", ["preset": "bubble", "corner": "bottomRight", "shape": "circle", "size": "M"])
        #expect(!layout.reply.isError && store.project?.recordings?.first?.layouts?.last?.layout.kind == .bubble, "layout_apply: \(layout.reply.text.prefix(200))")
        store.preview.seek(1)
        await app.idle(0.3)
        let box = drawn.first { $0.kind == .layoutBox }
        let corner = box.map { $0.center[0] > 960 && $0.center[1] > 540 } ?? false
        #expect(corner, "the camera's bubble is not in the bottom-right corner: \(String(describing: box?.center))")
        step("layout_apply {bubble, bottomRight}", sees: await seesClaude("layout.apply", layout.reply) + "; the bubble at \(box.map { "\(Int($0.center[0])),\(Int($0.center[1]))" } ?? "nowhere")")

        // 4. edit_autoZoom, cursor_style, keys_overlay.
        let zoom = await claude(link, "edit.autoZoom", ["zoom": 1.8])
        #expect(!zoom.reply.isError, "edit_autoZoom: \(zoom.reply.text.prefix(200))")
        step("edit_autoZoom {zoom: 1.8}", sees: await seesClaude("edit.autoZoom", zoom.reply))
        let cursor = await claude(link, "cursor.style", ["scale": 1.5, "clickRipple": true, "hideWhenIdle": true])
        #expect(!cursor.reply.isError, "cursor_style: \(cursor.reply.text.prefix(200))")
        step("cursor_style {scale: 1.5, clickRipple, hideWhenIdle}", sees: await seesClaude("cursor.style", cursor.reply))
        let keys = await claude(link, "keys.overlay")
        #expect(!keys.reply.isError, "keys_overlay: \(keys.reply.text.prefix(200))")
        step("keys_overlay", sees: await seesClaude("keys.overlay", keys.reply))

        // 5. A callout on what is clicked.
        let callout = await claude(link, "callout.add", ["kind": "circle", "start": 1, "duration": 1.5, "rect": [800, 400, 320, 200]])
        #expect(!callout.reply.isError, "callout_add: \(callout.reply.text.prefix(200))")
        store.preview.seek(1.5)
        await app.idle(0.3)
        let calloutID = callout.reply.result?.value(at: "clip.id")?.stringValue
        let calloutDrawn = calloutID.map { id in drawn.contains { $0.clipID == id } } ?? false
        #expect(calloutDrawn, "the callout is not on the picture at 1.5 s")
        step("callout_add {circle, 1 s}", sees: await seesClaude("callout.add", callout.reply) + "; on the picture")

        // 6. The words (the microphone), the voice, captions.
        if let mic = assets?["mic"]?.stringValue {
            let words = await claude(link, "transcript.run", ["assetId": .string(mic), "language": "it"])
            step("transcript_run {assetId: the microphone}", sees: await seesClaude("transcript.run", words.reply) + (words.reply.isError ? "; refused: \(words.reply.text.prefix(120))" : ""))
            let clean = await claude(link, "audio.clean", timeout: 180)
            step("audio_clean", sees: await seesClaude("audio.clean", clean.reply) + (clean.reply.isError ? "; refused: \(clean.reply.text.prefix(120))" : ""))
            let captions = await claude(link, "captions.generate", ["style": "talking-head-v1", "keywords": ["REGISTA"]])
            step("captions_generate", sees: await seesClaude("captions.generate", captions.reply) + (captions.reply.isError ? "; refused: \(captions.reply.text.prefix(120))" : ""))
        } else {
            Issue.record("the recording has no microphone: \(imported.reply.text.prefix(300))")
        }
        let sheet = await claude(link, "frame.contactSheet")
        step("frame_contactSheet", sees: await seesClaude("frame.contactSheet", sheet.reply))

        // 7. The rules of this kind of video: its own sheet; the logo goes in the corner for the whole video.
        let check = await claude(link, "rules.check")
        #expect(check.reply.result?["kind"] == "screen-tutorial", "rules_check used the sheet «\(check.reply.result?["kind"]?.stringValue ?? "none")», not the screen tutorial's")
        step("rules_check", sees: await seesClaude("rules.check", check.reply) + "; the sheet «\(check.reply.result?["kindTitle"]?.stringValue ?? "?")»")
        let kit = await claude(link, "brandkit.apply", ["kit": "cafe-atelier"])
        #expect(!kit.reply.isError, "brandkit_apply: \(kit.reply.text.prefix(200))")
        step("brandkit_apply {kit: cafe-atelier}", sees: await seesClaude("brandkit.apply", kit.reply))
        // The screen tutorial keeps «The logo only at the end» from «For every video»: the switch says the logo goes at the
        // end because of that rule, naming the rule and never the reel (#87).
        let simple = store.nav.level == .simple
        if simple { try await openRow(.graphics) } else { try await tap("Grafica"); try await tap("Logo") }
        let switchRow = { self.rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix(loc("Logo nel video")) && ["0", "1"].contains($0.value) } }
        #expect(await until(3) { switchRow()?.label.contains(LogoSwitch.caption(atEnd: true)) == true },
                "«Logo nel video» does not name the rule that puts the logo at the end: \(switchRow()?.label ?? "no switch")")
        #expect(switchRow()?.label.contains("reel") != true, "«Logo nel video» cites the reel in a screen tutorial: \(switchRow()?.label ?? "")")
        step(simple ? "Semplice › Grafica, «Logo nel video»" : "Grafica › Logo", sees: "«\(switchRow()?.label ?? "")»")
        // With that rule off for screen tutorials (the person's sheet, written by Claude), the logo is for the whole video.
        let off = await claude(link, "rules.set", ["kind": "screen-tutorial", "checks": ["logo-end": false]])
        #expect(!off.reply.isError, "rules_set: \(off.reply.text.prefix(200))")
        step("rules_set {kind: screen-tutorial, logo-end: off}", sees: await seesClaude("rules.set", off.reply))
        if simple { try await openRow(.graphics) }
        #expect(await until(3) { switchRow()?.label.contains(loc("Nell'angolo della marca, per tutto il video.")) == true },
                "«Logo nel video» does not say the corner for the whole video with the rule off: \(switchRow()?.label ?? "no switch")")
        rig.click(try #require(switchRow(), "no «Logo nel video»: \(screen())").centre)
        await app.settle()
        let logo = store.project?.tracks.first { $0.role == "logo" }?.clips.first
        let length = store.project?.duration.seconds ?? 0
        let whole = logo.map { $0.start.seconds < 0.05 && abs($0.end.seconds - length) < 0.1 } ?? false
        #expect(whole, "the logo is not there for the whole video: \(String(describing: logo.map { "\($0.start.seconds)–\($0.end.seconds)" }))")
        step("«Logo nel video» with the rule off", sees: "«\(loc("Nell'angolo della marca, per tutto il video."))», the logo from 0 to the end")
        try await tap("Esporta")
        #expect(await until { control("Orizzontale")?.selected == true }, "Esporta does not open on 16:9: \(screen())")
        #expect(await until(6) { shows(loc("Tutorial dello schermo")) }, "the rules card does not name the screen tutorial's sheet: \(screen())")
        step("Clicks Esporta", sees: "Orizzontale chosen, the rules card of «Tutorial dello schermo»")
        try await tap("Claude")

        // 8. export_render 16:9, recording_check, project_save.
        let again = await claude(link, "rules.check")
        if again.reply.result?["pass"] != true {
            let fixed = await claude(link, "rules.fix", ["all": true])
            step("rules_fix {all: true}", sees: await seesClaude("rules.fix", fixed.reply))
        }
        let movie = scratch.appendingPathComponent("tutorial-claude.mp4")
        let export = await claude(link, "export.render", ["path": .string(movie.path), "preset": "16:9"], timeout: 180)
        #expect(!export.reply.isError && FileManager.default.fileExists(atPath: movie.path), "export_render: \(export.reply.text.prefix(300))")
        if FileManager.default.fileExists(atPath: movie.path) {
            let m = try await Journey.probe(movie)
            let ratio: Double = Double(m.width) / Double(m.height)
            #expect(abs(ratio - 16.0 / 9) < 0.01, "exported \(m.width)×\(m.height), not 16:9")
        }
        step("export_render {preset: 16:9}", sees: await seesClaude("export.render", export.reply))
        let verify = await claude(link, "recording.check", ["path": .string(movie.path)], timeout: 180)
        step("recording_check", sees: await seesClaude("recording.check", verify.reply) + (verify.reply.isError ? "; refused: \(verify.reply.text.prefix(160))" : ""))
        let saved = await claude(link, "project.save")
        #expect(!saved.reply.isError && !store.dirty, "project_save: \(saved.reply.text.prefix(200))")
        step("project_save", sees: await seesClaude("project.save", saved.reply))
        // The shipped sheet back (the rig's rules folder is the test process's).
        _ = await claude(link, "rules.reset", ["kind": "screen-tutorial"])
    }
}
