import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// Journey 13: a voice-over video made by hand, the person's side of journey 10, by clicks on the real windows with the
// rig's stand-ins: the capture stand-in hands the recorder a synthetic take (nothing is recorded from the microphone),
// the rig's transcription hears what the test says was read (RigHearing), the rig's VoxCPM2 environment answers with a
// tone (no model is loaded) and every player is muted and recorded (RigPlayers: nothing reaches the speakers). From an
// app with no profile: the profile and the guided reading in «Gestisci voci», a take without the consent sentence, two
// paragraphs listened to and placed, the voice track already occupied at the playhead, captions from the voice, the
// rules of a voice-over video, the export with the AI-voice note and «Copia», one paragraph changed, a second language.

/// A tone of `seconds` as a WAV file (the capture stand-in's take).
private func toneFile(_ url: URL, seconds: Double) throws {
    let rate = 16_000
    try WAVAudio(sampleRate: rate, channels: 1, samples: (0..<Int(seconds * Double(rate))).map { i in Float(0.2 * sin(2 * .pi * 180 * Double(i) / Double(rate))) })
        .write16(to: url)
}

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct VoiceJourneyTests {
    /// 13. A voice-over video made by hand.
    @Test func aVoiceOverVideoIsMadeByHand() async throws {
        let j = try await Journey("13-voice-over-by-hand", project: nil)
        defer {
            RigHearing.words = nil
            j.close()
        }
        try await j.voiceOverByHand()
    }
}
}

extension Journey {
    /// «Gestisci voci» as the app shows it over the window (the rig's window draws no sheets: it is hosted on its own).
    func voiceWindow() async -> MouseRig {
        let w = MouseRig(VoiceSetupSheet().environmentObject(store).environmentObject(store.preview).environmentObject(store.preview.playhead)
                            .environmentObject(store.media).environmentObject(app.meter).environmentObject(app.recorder)
                            .environment(\.colorScheme, .dark),
                         // The main window's language holds for this one too (a language of its own would end with it).
                         size: VoiceSetupView.size)
        w.pump(0.3)
        await app.idle(0.2)
        return w
    }

    /// Closes a window hosted beside the main one; the main window takes the keyboard back, as the app's window does
    /// when its sheet ends.
    func closeWindow(_ w: MouseRig) async {
        w.close()
        rig.window.orderFrontRegardless()
        rig.window.makeKey()
        rig.pump(0.1)
        await app.idle(0.2)
    }

    /// A snapshot of a window other than the main one, beside the journey's.
    func shot(_ w: MouseRig, _ tag: String) {
        guard let rep = w.host.bitmapImageRepForCachingDisplay(in: w.host.bounds) else { return }
        w.host.cacheDisplay(in: w.host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: Journey.folder.appendingPathComponent("\(name)-\(tag).png"))
    }

    /// The stub uv's calls of vox_say.py (one per render of the voice).
    func voiceRenders() -> Int {
        let log = RigVoice.log(URL(fileURLWithPath: store.engine.context.services.config.voxcpmProject))
        return ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix("vox_say.py") }.count
    }

    /// Records a take in «Gestisci voci» (Registra, Ferma) whose words the rig hears as `heard`; waits for its check.
    func recordTake(_ w: MouseRig, heard: [String], sourceLocation: SourceLocation = #_sourceLocation) async throws {
        RigHearing.words = RigHearing.reading(heard)
        let record = "Registra solo il microfono: il file resta fuori dal montaggio"
        _ = await until(5) { w.controls().first { $0.name == record }?.enabled == true }
        try await tap(record, in: w, sourceLocation: sourceLocation)
        #expect(await until(5) { app.recorder.isRecording }, "Registra did not start a take: \(app.recorder.errorMessage ?? "")", sourceLocation: sourceLocation)
        await app.idle(0.3)
        try await tap(record, in: w, sourceLocation: sourceLocation)   // now «Ferma»
        #expect(await until(30) { store.voice.setup.check != nil && store.jobs.latest("voice-take")?.isRunning != true },
                "the take was not checked: \(screen(w))", sourceLocation: sourceLocation)
        RigHearing.words = nil   // what the rig hears afterwards (a generated voice's words) is the fixture's again
        w.pump(0.3)
        await app.settle()
    }

    /// Journey 13 (VoiceJourneyTests.aVoiceOverVideoIsMadeByHand).
    func voiceOverByHand() async throws {
        let model = store.voice
        let services = store.engine.context.services
        let script = try RecordingScript.load(language: "it", config: services.config)
        let take = scratch.appendingPathComponent("lettura.wav")
        try toneFile(take, seconds: 180)
        app.capture.take = take

        // 1. The Voce panel of an app with no profile: the way into cloning.
        await open(Navigation(activity: .voice, rightTab: .inspector))
        #expect(await until(3) { shows(loc("Inizia a clonare la tua voce")) && shows(loc("Nessun profilo")) }, "the Voce panel does not offer to clone a voice: \(screen())")
        step("Opens the Voce panel (no profile on this Mac)", sees: "«\(loc("Clona la tua voce"))», «\(loc("Inizia a clonare la tua voce"))», «\(loc("Nessun profilo"))»")

        // 2. «Gestisci voci» asks for the profile first.
        try await tap("Inizia a clonare la tua voce")
        #expect(store.showVoiceSetup, "the button did not open «Gestisci voci»")
        let w = await voiceWindow()
        #expect(model.windowPage == .profile, "the window opens on \(model.windowPage), not the profile")
        let field = try #require(w.elements().first { $0.isControl && $0.visible && ($0.label.contains(loc("Il tuo nome")) || $0.title.contains(loc("Il tuo nome")) || $0.value.isEmpty && $0.role == "AXTextField") },
                                 "no name field: \(screen(w))")
        w.click(field.centre)
        w.type("Prova")
        try await tap("Crea il profilo", in: w)
        #expect(await until(5) { model.snapshot.profile == "Prova" }, "no profile «Prova»: \(screen(w))")
        w.pump(0.3)
        shot(w, "02-profile")
        step("Clicks «Inizia a clonare la tua voce», types Prova, «Crea il profilo»", sees: "the profile «Prova»; the window on the intro of \(VoiceLanguages.name(model.windowLanguage))")
        // The voice in Italian: its row in the window's rail (the window opens on the Mac's language).
        if model.windowLanguage != "it" {
            let italian = try #require(w.controls().first { $0.name.hasPrefix(VoiceLanguages.name("it")) }, "no Italiano in the window's rail: \(screen(w))")
            w.click(italian.centre)
            w.pump(0.3)
        }
        #expect(model.windowLanguage == "it" && model.windowPage == .intro, "the window is on \(model.windowLanguage) \(model.windowPage)")

        // 3. The intro, the consent sentence to read first, then the record page.
        try await tap("Inizia", in: w)
        w.pump(0.2)
        #expect(model.windowPage == .consent, "Inizia led to \(model.windowPage)")
        let consent = script.consent(name: "Prova")
        #expect(!w.elements(containing: String(consent.prefix(25))).isEmpty, "the window does not show the consent sentence «\(consent.prefix(40))…»: \(screen(w))")
        shot(w, "03-consent")
        try await tap("Ho capito, registra", in: w)
        w.pump(0.2)
        #expect(model.windowPage == .record, "«Ho capito, registra» led to \(model.windowPage)")
        shot(w, "03-record")
        step("«Inizia», reads the consent page, «Ho capito, registra»", sees: "the record page with the text to read, the consent sentence first")

        // 4. A take without the consent sentence: the check says so in words; «Registra di nuovo» starts again.
        let lines = Array(script.lines("neutral").prefix(30))
        try await recordTake(w, heard: lines)
        let missing = loc("Non ho sentito la frase di consenso all'inizio della registrazione. Ricomincia leggendola per prima, con calma.")
        #expect(model.setup.check?.error != nil && !w.elements(containing: String(missing.prefix(40))).isEmpty, "the check does not say the consent sentence is missing: \(screen(w))")
        #expect(model.snapshot.language("it")?.hasVoice != true, "a take without the consent made a voice")
        shot(w, "04-no-consent")
        step("Records the text without the consent sentence first", sees: "the check: «\(missing)»; no voice")
        try await tap("Registra di nuovo", in: w)
        w.pump(0.2)
        #expect(model.windowPage == .record, "«Registra di nuovo» led to \(model.windowPage)")

        // 5. The guided reading to the end: the consent first, then the text. The voice is ready.
        try await recordTake(w, heard: [consent] + lines)
        #expect(model.setup.check?.error == nil, "the full reading was refused: \(model.setup.check?.error ?? "")")
        shot(w, "05-check")
        let next = try #require(w.controls().first { $0.name == loc("Continua") || $0.name == loc("Continua comunque") }, "no way on from the check: \(screen(w))")
        w.click(next.centre)
        w.pump(0.3)
        await app.settle()
        #expect(model.windowPage == .overview, "the window is on \(model.windowPage) after the check")
        shot(w, "05-overview")
        try await tap("Chiudi", in: w)
        #expect(!store.showVoiceSetup, "Chiudi did not close «Gestisci voci»")
        await closeWindow(w)   // the sheet goes away with its window, as in the app
        await model.refresh()
        await app.settle()
        #expect(await until(3) { model.state == .ready && shows(String(format: loc("Voce di %@"), "Prova")) && shows(VoiceLanguages.name("it")) },
                "the Voce panel does not say the voice is ready in Italian: \(screen())")
        step("Reads the consent, then the text, to the end; Continua, Chiudi", sees: "the Voce panel: «\(String(format: loc("Voce di %@"), "Prova"))», the language «\(VoiceLanguages.name("it"))», the composer")

        // 6. A new project for the video (Inizio › Video senza volto), the footage first (Media › Importa…: on the empty
        // timeline it goes on V1).
        try await tap("Inizio")
        try await tap("Video senza volto")
        #expect(await until(5) { store.project != nil && store.nav.activity == .voice }, "«Video senza volto» did not open a project on the Voce panel: \(screen())")
        await app.settle()
        let footage = try self.take("riprese.mov")
        try await tap("Media")
        RigGuard.panelAnswer = [footage]
        try await tap("Importa video, audio o immagini nel progetto")
        #expect(await until(10) { store.project?.tracks.contains { $0.kind == .video && !$0.clips.isEmpty } == true }, "the footage is not on the timeline: \(screen())")
        await app.settle()
        step("Inizio › Video senza volto; Media › Importa… riprese.mov", sees: "«\(store.project?.name ?? "?")» on the Voce panel, then the footage on V1")

        // 7. Two paragraphs, typed; Ascolta: one render, the stand-in player asked to play (muted), nothing placed.
        store.nav = Navigation(activity: .voice, rightTab: .inspector)
        await app.settle()
        let placeholder = String(loc("Scrivi qui il testo della voce. Una riga vuota separa i paragrafi: ognuno diventa una clip.").prefix(20))
        let editor = try #require(rig.elements(containing: placeholder).first { $0.isControl && $0.visible }, "no text editor in the Voce panel: \(screen())")
        rig.click(editor.centre)
        #expect(rig.isTyping, "a click on the Voce panel's text did not give it the keyboard")
        let first = "Oggi Regista monta il video da solo.", second = "La voce è la tua, clonata su questo Mac."
        rig.type(first)
        rig.key(.returnKey)
        rig.key(.returnKey)
        rig.type(second)
        await app.settle()
        #expect(model.paragraphs == [first, second], "the panel reads the paragraphs \(model.paragraphs)")
        let renders = voiceRenders(), played = RigPlayers.played.count, clips = app.clips.count
        let listen = "Ascolta la selezione, o il paragrafo dove sta il cursore, senza toccare il montaggio"
        _ = await until(5) { control(listen)?.enabled == true }
        try await tap(listen)
        #expect(await until(20) { store.jobs.latest("voice")?.isRunning == false && RigPlayers.played.count > played }, "Ascolta played nothing")
        #expect(voiceRenders() == renders + 1 && app.clips.count == clips, "Ascolta rendered \(voiceRenders() - renders) times or changed the edit")
        step("Types two paragraphs, clicks Ascolta", sees: "one render, the player asked to play «\(RigPlayers.played.last ?? "?")» (muted), the edit unchanged")
        if model.playing { try await tap("Ferma") }

        // 8. «Dopo l'ultima voce» (the default), «Metti in timeline»: two clips on the Voce track.
        #expect(control(loc("Dopo l'ultima voce"))?.selected == true || model.placement == .afterVoice, "«Dopo l'ultima voce» is not the choice")
        let place = "Ogni paragrafo diventa una clip sulla pista Voce, con i tempi delle parole"
        _ = await until(5) { control(place)?.enabled == true }
        try await tap(place)
        #expect(await until(30) { store.jobs.latest("voice")?.isRunning == false && model.placed != nil }, "Metti in timeline placed nothing: \(screen())")
        await app.settle()
        let voce = try #require(store.project?.tracks.first { $0.kind == .audio && $0.clips.contains { store.project?.asset($0.assetID)?.generated != nil } }, "no Voce track")
        #expect(voce.clips.count == 2, "\(voce.clips.count) clips for two paragraphs")
        let placed = String(format: loc("%d clip sulla pista Voce · %@"), 2, VoiceFormat.duration(model.placed?.seconds ?? 0))
        #expect(shows(placed), "the panel does not say «\(placed)»: \(screen())")
        step("«Dopo l'ultima voce», Metti in timeline", sees: "«\(placed)», the clips on «\(voce.name)»")

        // 9. «Al cursore» with the playhead inside the first clip: the track is occupied there, said in words.
        try await tap("Al cursore")
        store.preview.seek((voce.clips[0].start.seconds + voce.clips[0].end.seconds) / 2)
        await app.settle()
        let before = voce.clips.count
        try await tap(place)
        _ = await until(30) { store.jobs.latest("voice")?.isRunning == false }
        await app.settle()
        let occupied = loc("La pista Voce è già occupata al cursore: scegli «Dopo l'ultima voce» o sposta il cursore.")
        let job = store.jobs.latest("voice")
        let said = [store.errorMessage, job.map { "\($0.state)" }, job?.detail].compactMap { $0 }.joined(separator: " | ")
        #expect(store.project?.tracks.first { $0.id == voce.id }?.clips.count == before, "the occupied playhead changed the Voce track")
        #expect(shows(String(occupied.prefix(30))) || said.contains(String(occupied.prefix(30))), "the window does not say the track is occupied: \(said); \(screen())")
        step("«Al cursore» with the playhead on the first clip, Metti in timeline", sees: "refused: \(said)")
        store.errorMessage = nil
        try await tap("Dopo l'ultima voce")

        // 10. Captions from the voice.
        try await tap("Sottotitoli da questo testo")
        #expect(await until(10) { store.project?.tracks.contains { $0.captions != nil } == true }, "no captions from the voice (\(store.errorMessage ?? "no error")): \(screen())")
        await app.settle()
        step("Sottotitoli da questo testo", sees: "the captions on T1 from the voice's words")

        // 11. The rules of a voice-over video, the export: the AI-voice note, «Copia» on the rig's pasteboard.
        try await tap("Esporta")
        let kindTitle = loc(RuleBook.builtInTitle("voice-over-video") ?? "")
        let card = await until(6) { shows(kindTitle) }
        #expect(card, "the rules card does not follow the voice-over video's sheet («\(kindTitle)»): \(screen())")
        #expect(await until(3) { shows(loc("Voce generata con IA")) }, "Esporta does not show the AI-voice note: \(screen())")
        step("Clicks Esporta", sees: "the rules card \(card ? "of «\(kindTitle)»" : "of another kind"); «\(loc("Voce generata con IA"))»")
        let out = scratch.appendingPathComponent("voce-a-mano.mp4")
        RigGuard.panelAnswer = [out]
        if let fixAll = control("Sistema tutto ed esporta") { rig.click(fixAll.centre) } else { try await tap("Esporta video…") }
        await app.settle()
        #expect(await until(180) { FileManager.default.fileExists(atPath: out.path) && store.jobs.latest("export")?.isRunning == false },
                "no exported file (export job: \(String(describing: store.jobs.latest("export").map { "\($0.state) \($0.detail)" }))): \(screen())")
        await app.settle()
        rigPasteboard.clearContents()
        try await tap("Copia")
        #expect(rigPasteboard.string(forType: .string) == loc(AIVoiceNote.sentence), "«Copia» put «\(rigPasteboard.string(forType: .string) ?? "nothing")» on the pasteboard")
        step("Esporta video…, then «Copia» on the AI-voice note", sees: "voce-a-mano.mp4 written; the pasteboard: «\(loc(AIVoiceNote.sentence))»")

        // 12. One paragraph changed, «Metti in timeline» again: what the product does with the other one.
        store.nav = Navigation(activity: .voice, rightTab: .inspector)
        await app.settle()
        let changed = "La voce è la tua, e resta su questo Mac."
        let editorAgain = try #require(rig.elements(containing: "Oggi Regista").first { $0.isControl && $0.visible }, "no text editor: \(screen())")
        rig.click(editorAgain.centre)
        #expect(rig.isTyping, "a click on the Voce panel's text did not give it the keyboard")
        // ⌘A is the Edit menu's (the rig hosts no menu bar): the text view's own Select All.
        (rig.window.firstResponder as? NSTextView)?.selectAll(nil)
        rig.type(first)
        rig.key(.returnKey)
        rig.key(.returnKey)
        rig.type(changed)
        await app.settle()
        #expect(model.paragraphs == [first, changed], "the panel reads \(model.paragraphs)")
        let rendersBefore = voiceRenders(), voiceClips = store.project?.tracks.first { $0.id == voce.id }?.clips.count ?? 0
        _ = await until(5) { control(place)?.enabled == true }
        try await tap(place)
        _ = await until(30) { store.jobs.latest("voice")?.isRunning == false }
        await app.settle()
        let rendered = voiceRenders() - rendersBefore
        let nowClips = store.project?.tracks.first { $0.id == voce.id }?.clips.count ?? 0
        #expect(rendered == 1, "the unchanged paragraph was rendered again (\(rendered) renders for one changed paragraph)")
        step("Changes the second paragraph, Metti in timeline again", sees: "\(rendered) render (the unchanged paragraph from the cache); the Voce track \(voiceClips) → \(nowClips) clips: the whole text is placed again after the last voice (no way to replace one paragraph's clip in place)")

        // 13. A second language for the same profile: «Gestisci voci…», Français, its consent and text. The panel lists both.
        try await tap("Le tue voci: lingue, toni e allenamento")   // «Gestisci voci…», read by its tooltip
        #expect(store.showVoiceSetup, "«Gestisci voci…» did not open the window")
        let w2 = await voiceWindow()
        let french = try #require(w2.controls().first { $0.name.hasPrefix(VoiceLanguages.name("fr")) }, "no Français in the window's rail: \(screen(w2))")
        w2.click(french.centre)
        w2.pump(0.3)
        #expect(model.windowLanguage == "fr" && model.windowPage == .intro, "the rail's Français opened \(model.windowLanguage) on \(model.windowPage)")
        try await tap("Inizia", in: w2)
        try await tap("Ho capito, registra", in: w2)
        let frScript = try RecordingScript.load(language: "fr", config: services.config)
        try await recordTake(w2, heard: [frScript.consent(name: "Prova")] + frScript.lines("neutral").prefix(30))
        #expect(model.setup.check?.error == nil, "the French reading was refused: \(model.setup.check?.error ?? "")")
        if let on = w2.controls().first(where: { $0.name == loc("Continua") || $0.name == loc("Continua comunque") }) { w2.click(on.centre); w2.pump(0.3) }
        shot(w2, "13-french")
        try await tap("Chiudi", in: w2)
        await closeWindow(w2)
        await model.refresh()
        await app.settle()
        let chips = model.snapshot.readyLanguages.map(\.code)
        #expect(chips.contains("it") && chips.contains("fr"), "the profile's ready languages are \(chips)")
        #expect(await until(3) { shows(VoiceLanguages.name("it")) && shows(VoiceLanguages.name("fr")) }, "the Voce panel does not list both languages: \(screen())")
        // A paragraph in a language without a voice: the panel offers only the languages the voice speaks (its chips),
        // so its own path cannot send one; the refusal's sentence is the one Claude's route shows (journey 10).
        #expect(!shows(VoiceLanguages.name("en")) || control(VoiceLanguages.name("en")) == nil, "the panel offers English, which has no voice")
        step("«Gestisci voci…», Français: its consent, its text; Chiudi", sees: "the Voce panel's languages: \(chips.map(VoiceLanguages.name).joined(separator: ", ")); no chip for a language without a voice")
    }
}
