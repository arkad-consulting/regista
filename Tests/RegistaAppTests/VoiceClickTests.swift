import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The Voce panel and the "Le tue voci" window on the real model (#36), with the rig's voice services (RigVoice): a
// scratch profiles folder, the rig's VoxCPM2 environment whose uv is a stub (a synthetic tone where a file is expected,
// a checkpoint of placeholder files for a training), the capture stand-in for a take. «Ascolta», «Metti in timeline»,
// «+ Lingua», «+ Tono» › «Registra questo tono» › Registra / Ferma and «Allena la voce» are clicked and each runs its
// command once. Nothing is synthesised by an engine, played (RigGuard mutes every player) or recorded, and no profile
// of the person running the tests is read or written.

/// A transcription that hears what the test says was read (the seeding of a voice below).
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

/// A tone of `seconds` as a WAV file (a "recording" for the seeding and the capture stand-in).
private func toneFile(_ url: URL, seconds: Double) throws {
    let rate = 16_000
    let samples = (0..<Int(seconds * Double(rate))).map { i in Float(0.2 * sin(2 * .pi * 180 * Double(i) / Double(rate))) }
    try WAVAudio(sampleRate: rate, channels: 1, samples: samples).write16(to: url)
}

@MainActor
private final class VoiceRig {
    let app: AppRig
    var store: EditorStore { app.store }
    var model: VoiceModel { app.store.voice }
    let services: EngineServices
    /// The stub uv's record of its calls.
    let uvLog: URL

    /// The rig's store with a profile «Prova» whose Italian voice is ready in zero-shot: its consent and 30 neutral lines
    /// heard from a synthetic take (more than the 90 s a training needs), added through voice.enroll.add on the rig's
    /// own services with a transcription that hears them.
    init() async throws {
        app = try await AppRig()
        services = app.store.engine.context.services
        uvLog = RigVoice.log(URL(fileURLWithPath: services.config.voxcpmProject))
        let script = try RecordingScript.load(language: "it", config: services.config)
        var seeding = services
        let heard = Heard(id: WhisperCppTranscriber.engineID, words: spoken([script.consent(name: "Prova")] + script.lines("neutral").prefix(30)))
        seeding.transcribers = [WhisperCppTranscriber.engineID: heard, WhisperXTranscriber.engineID: Heard(id: WhisperXTranscriber.engineID, words: heard.words)]
        let e = Engine(services: seeding)
        _ = try e.execute("profile.create", params: ["name": "Prova"])
        let take = rigTempDir("voice-take").appendingPathComponent("neutral.wav")
        try toneFile(take, seconds: 180)
        _ = try e.execute("voice.enroll.add", params: ["path": .string(take.path), "language": "it", "tone": "neutral"])
        await model.refresh()
        #expect(model.state == .ready, "the seeded voice is not ready: \(model.state)")
    }

    func close() { app.close() }

    /// The stub's calls of `script` (vox_say.py, train_voxcpm_finetune.py).
    func calls(_ script: String) -> Int {
        ((try? String(contentsOf: uvLog, encoding: .utf8)) ?? "").split(separator: "\n").filter { $0.hasPrefix(script) }.count
    }

    /// Waits (at most `seconds`) until `done` holds, the main run loop turning in a loop of ours.
    func until(_ seconds: Double = 20, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > end { return false }
            await app.idle(0.1)
        }
        return true
    }

    func control(_ name: String) throws -> RigElement {
        try #require(app.rig.controls().first { $0.name == name }, "no «\(name)» on screen: \(app.rig.controls().map(\.description))")
    }

    /// The control once it is drawn enabled (#58): a click right after a job ends can reach a button the panel has not
    /// drawn enabled yet, and a click on a disabled button does nothing.
    func enabledControl(_ name: String, _ seconds: Double = 10) async throws -> RigElement {
        _ = await until(seconds) { app.rig.controls().first { $0.name == name }?.enabled == true }
        let c = try control(name)
        #expect(c.enabled, "«\(name)» is still disabled after \(seconds) s")
        return c
    }
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct VoiceClickTests {
    /// The Voce panel: «Ascolta» renders the paragraph once and changes nothing in the edit; «Metti in timeline» places
    /// it on the Voce track (voice.say, once); «+ Lingua» opens the window on a language without a voice; «+ Tono» opens
    /// it on the voice's language.
    @Test func theVoicePanelRunsItsCommands() async throws {
        let v = try await VoiceRig()
        defer { v.close() }
        v.app.hostEditor(Navigation(activity: .voice, rightTab: .inspector))
        await v.app.settle()
        v.model.text = "Ciao a tutti, oggi vi mostro Regista."
        await v.app.settle()

        // Ascolta.
        let says = v.calls("vox_say.py"), clips = v.app.clips.count
        v.app.rig.click(try await v.enabledControl("Ascolta la selezione, o il paragrafo dove sta il cursore, senza toccare il montaggio").centre)
        #expect(await v.until { v.store.jobs.latest("voice")?.isRunning == false }, "the listening job did not end")
        #expect(v.calls("vox_say.py") == says + 1, "Ascolta rendered \(v.calls("vox_say.py") - says) times")
        #expect(v.store.jobs.latest("voice")?.state == .done, "Ascolta did not end well: \(String(describing: v.store.jobs.latest("voice")?.state))")
        #expect(v.app.clips.count == clips, "Ascolta changed the edit")

        // Metti in timeline.
        var n = v.store.activity.count
        // The job's end reaches the store before the panel draws the button enabled again (#58): wait for the button.
        v.app.rig.click(try await v.enabledControl("Ogni paragrafo diventa una clip sulla pista Voce, con i tempi delle parole").centre)
        #expect(await v.until { v.app.commands(since: n).contains("voice.say") }, "Metti in timeline ran \(v.app.commands(since: n))")
        await v.app.settle()
        #expect(v.app.commands(since: n).filter { $0 == "voice.say" }.count == 1, "voice.say ran \(v.app.commands(since: n))")
        let voce = v.store.project?.tracks.first { $0.kind == .audio && $0.name == "Voce" }
        #expect(voce?.clips.count == 1, "the Voce track has \(voce?.clips.count ?? 0) clips")

        // + Lingua: the window, on a language the profile has no voice in.
        n = v.store.activity.count
        v.app.rig.click(try v.control("Clona la tua voce in un'altra lingua").centre)
        await v.app.settle()
        #expect(v.store.showVoiceSetup, "+ Lingua did not open the voice window")
        let language = v.model.windowLanguage
        #expect(language != "it" && v.model.snapshot.language(language)?.hasVoice != true, "+ Lingua opened the window on \(language)")
        v.store.showVoiceSetup = false
        await v.app.settle()

        // + Tono: the window, on the voice's language.
        v.app.rig.click(try v.control("Registra un altro tono di questa voce").centre)
        await v.app.settle()
        #expect(v.store.showVoiceSetup && v.model.windowLanguage == "it", "+ Tono opened \(v.store.showVoiceSetup) on \(v.model.windowLanguage)")
    }

    /// «Metti in timeline» refused (the playhead on a voice clip with «Al cursore»): the job says why in the panel's words,
    /// never the engine's text (#94), and the edit is unchanged.
    @Test func aRefusedPlacementSaysWhyInWords() async throws {
        let v = try await VoiceRig()
        defer { v.close() }
        v.model.text = "Ciao a tutti."
        v.model.placement = .afterVoice
        v.model.place()
        #expect(await v.until { v.store.jobs.latest("voice")?.isRunning == false && v.model.placed != nil }, "the first placement did not end")
        await v.app.idle(0.3)
        let first = try #require(v.store.project?.tracks.first { $0.id == v.model.placed?.trackId }?.clips.first)
        let clips = v.app.clips.count
        v.model.placement = .playhead
        v.store.preview.seek((first.start.seconds + first.end.seconds) / 2)
        v.model.place()
        _ = await v.until { v.store.jobs.latest("voice")?.isRunning == false }
        await v.app.idle(0.3)
        let state = (v.store.jobs.latest("voice").map { "\($0.state)" } ?? "").replacingOccurrences(of: "\\'", with: "'")
        #expect(state.contains(loc("La pista Voce è già occupata al cursore: scegli «Dopo l'ultima voce» o sposta il cursore.")), "the job reads \(state)")
        #expect(!state.contains("occupied"), "the job shows the engine's text: \(state)")
        #expect(v.app.clips.count == clips, "the refused placement changed the edit")
    }

    /// The window on the voice: «Registra questo tono» on a tone not recorded yet, Registra, Ferma: the take (the capture
    /// stand-in's synthetic file) is added once (voice.enroll.add). Then «Allena la voce» starts the training once
    /// (voice.enroll.train; the stub trainer writes a checkpoint of placeholder files).
    @Test func theVoiceWindowRecordsAToneAndTrains() async throws {
        let v = try await VoiceRig()
        defer { v.close() }
        let take = rigTempDir("voice-capture").appendingPathComponent("tone.wav")
        try toneFile(take, seconds: 20)
        v.app.capture.take = take
        v.model.setup.language = "it"
        v.app.host(VoiceSetupSheet(), size: VoiceSetupView.size)
        await v.app.settle()

        // A tone not recorded yet: its tile opens its recording page.
        v.app.rig.click(try v.control("Registra questo tono").centre)
        await v.app.settle()
        let tone = try #require(v.model.setup.pendingTone, "the tile did not open a tone's page")
        #expect(tone != VoiceTone.neutral)
        let record = "Registra solo il microfono: il file resta fuori dal montaggio"
        v.app.rig.click(try v.control(record).centre)
        #expect(await v.until(5) { v.app.recorder.isRecording }, "Registra did not start a take: \(v.app.recorder.errorMessage ?? "")")
        let n = v.store.activity.count
        v.app.rig.click(try v.control(record).centre)   // now «Ferma»
        #expect(await v.until(30) { v.app.commands(since: n).contains("voice.enroll.add") }, "Ferma added no take: \(v.app.commands(since: n)) \(v.store.errorMessage ?? "")")
        await v.app.settle()
        #expect(v.app.commands(since: n).filter { $0 == "voice.enroll.add" }.count == 1, "voice.enroll.add ran \(v.app.commands(since: n))")

        // The take's check, then back to the overview with its own button: Allena la voce (the Pro tier: 32 GB or more).
        #expect(await v.until(10) { v.model.setup.check != nil }, "no check of the take")
        await v.app.settle()
        let next = try #require(v.app.rig.controls().first { $0.name == "Continua" || $0.name == "Continua comunque" },
                                "no way on from the check: \(v.app.rig.controls().map(\.description))")
        v.app.rig.click(next.centre)
        #expect(await v.until(10) { v.model.setup.check == nil && v.model.windowPage == .overview }, "the check did not go back to the overview (\(v.model.windowPage))")
        await v.app.settle()
        guard v.services.tier >= .pro else {
            withKnownIssue("this Mac is below the Pro tier: «Allena la voce» is disabled with its reason", isIntermittent: true) { Issue.record("not Pro") }
            return
        }
        let m = v.store.activity.count, trains = v.calls("train_voxcpm_finetune.py")
        v.app.rig.click(try v.control("Allena la voce").centre)
        #expect(await v.until { v.app.commands(since: m).contains("voice.enroll.train") }, "Allena la voce ran \(v.app.commands(since: m)) \(v.store.errorMessage ?? "")")
        await v.app.settle()
        #expect(v.app.commands(since: m).filter { $0 == "voice.enroll.train" }.count == 1, "voice.enroll.train ran \(v.app.commands(since: m))")
        #expect(await v.until(10) { v.calls("train_voxcpm_finetune.py") == trains + 1 }, "the trainer was started \(v.calls("train_voxcpm_finetune.py") - trains) times")
    }
}
}
