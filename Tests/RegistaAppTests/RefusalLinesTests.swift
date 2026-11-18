import Foundation
import RegistaCore
import Testing
@testable import Regista

// What the person reads when a command is refused (#88): the refusals the four recipes meet, each produced by the real
// command on the rig's services, say in a sentence of the interface language what happened and what to do — the rule
// as the rules card names it, the profile, the language by its name, the file — never a rule id, a language code or the
// engine's English. The engine's text stays whole in the row's tooltip; an error without a sentence of its own keeps the
// translated lead before the engine's text.

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

/// The engine's words a sentence for the person never carries (in Italian, French and Portuguese).
private let englishWords = ["the", "has", "voice", "editing", "rule", "rules", "breaks", "approval", "needs", "installed", "person",
                            "records", "found", "kind", "paid", "estimate", "credits", "profile", "file at"]

/// A word or a code as a whole token of `line`.
private func token(_ word: String, in line: String) -> Bool {
    line.range(of: "(?<![\\p{L}\\d-])\(NSRegularExpression.escapedPattern(for: word))(?![\\p{L}\\d-])", options: [.regularExpression, .caseInsensitive]) != nil
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct RefusalLinesTests {
    @Test func everyRefusalIsSaidInWordsInFourLanguages() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let store = app.store.bench.active
        let scratch = rigTempDir("refusals")
        func refused(_ id: String, _ params: JSONValue = [:]) async -> Error? {
            do { _ = try await store.perform(id, params); return nil } catch { return error }
        }

        // A reel with a title too small for its rules (the text-size check of «Per ogni video»).
        _ = try await store.perform("project.new", ["name": "Rifiuti", "directory": .string(scratch.path), "kind": "talking-head-reel"])
        _ = try await store.perform("media.import", ["path": .string(try RigProject.media.get().appendingPathComponent("take.mov").path)])
        _ = try await store.perform("title.add", ["text": "PICCOLO", "start": 0, "size": 8])
        var refusals: [(what: String, error: Error)] = []
        func keep(_ what: String, _ e: Error?, sourceLocation: SourceLocation = #_sourceLocation) {
            guard let e else { Issue.record("\(what) was not refused", sourceLocation: sourceLocation); return }
            refusals.append((what, e))
        }
        keep("rules", await refused("export.render", ["path": .string(scratch.appendingPathComponent("rifiuto.mp4").path), "preset": "9:16"]))
        let exportRow = store.activity.last { $0.command == "export.render" }
        keep("no profile", await refused("voice.say", ["text": "Ciao a tutti.", "language": "it"]))
        _ = try await store.perform("profile.create", ["name": "Prova"])
        keep("no voice", await refused("voice.say", ["text": "Ciao a tutti.", "language": "it"]))

        // The person's Italian voice (seeded as journey 10 does), then a text in English.
        let services = store.engine.context.services
        let script = try RecordingScript.load(language: "it", config: services.config)
        var seeding = services
        var words: [RegistaCore.Word] = [], t = 1.0
        for s in [script.consent(name: "Prova")] + script.lines("neutral").prefix(30) {
            for w in s.split(separator: " ") { words.append(RegistaCore.Word(text: String(w), start: MediaTime(seconds: t), end: MediaTime(seconds: t + 0.3))); t += 0.35 }
            t += 0.8
        }
        seeding.transcribers = [WhisperCppTranscriber.engineID: Heard(id: WhisperCppTranscriber.engineID, words: words),
                                WhisperXTranscriber.engineID: Heard(id: WhisperXTranscriber.engineID, words: words)]
        let take = scratch.appendingPathComponent("neutral.wav")
        try WAVAudio(sampleRate: 16_000, channels: 1, samples: (0..<(180 * 16_000)).map { i in Float(0.2 * sin(2 * .pi * 180 * Double(i) / 16_000)) }).write16(to: take)
        _ = try Engine(services: seeding).execute("voice.enroll.add", params: ["path": .string(take.path), "language": "it", "tone": "neutral"])
        keep("language", await refused("voice.say", ["text": "Hello everyone.", "language": "en"]))

        keep("paid", await refused("generate.run", ["provider": "higgsfield", "kind": "image", "prompt": "a red chair"]))
        keep("engine", await refused("graphics.hyperframes", ["folder": .string(scratch.path), "start": 0]))
        keep("file", await refused("media.import", ["path": .string(scratch.appendingPathComponent("non-qui.mov").path)]))
        let plain = try #require(await refused("takes.select", ["line": 9, "take": 1]), "takes.select on a line that does not exist was not refused")

        // The log's row: the sentence in red, the engine's text whole in the tooltip after the parameters.
        let rules = try #require(refusals.first { $0.what == "rules" }?.error)
        #expect(exportRow?.status == .failed, "the refused export is not a failed row")
        await app.idle(0.2)
        let row = try #require(store.activity.last { $0.command == "export.render" })
        #expect(row.result == StepError.readable(rules, fallback: "Il motore ha risposto: %@"), "the row reads «\(row.result)»")
        #expect(row.details == JobCenter.message(rules), "the tooltip does not keep the engine's text whole: «\(row.details)»")

        for language in ["it", "en", "fr", "pt"] {
            Words.override = MouseRig.table(language)
            Words.applies = { true }
            defer { Words.override = nil; Words.applies = nil }
            for (what, error) in refusals {
                let raw = JobCenter.message(error)
                let line = StepError.readable(error, fallback: "Il motore ha risposto: %@")
                FileHandle.standardError.write(Data("refusal \(language) \(what): \(line)\n".utf8))
                #expect(line != String(format: loc("Il motore ha risposto: %@"), raw), "\(language) \(what): no sentence of its own: «\(line)»")
                #expect(!line.contains("%@") && !line.contains(scratch.path), "\(language) \(what): «\(line)»")
                for id in RuleCheckSpec.ids + RuleBook.builtInKinds where line.contains(id) { Issue.record("\(language) \(what): «\(line)» names \(id)") }
                for code in ["it", "en", "fr", "pt"] where token(code, in: line) && !(language == "fr" && code == "en") && !(language == "en" && code == "it") {
                    Issue.record("\(language) \(what): «\(line)» carries the language code «\(code)»")
                }
                if language != "en" {
                    for w in englishWords where token(w, in: line) { Issue.record("\(language) \(what): «\(line)» carries the English «\(w)»") }
                }
                switch what {
                case "rules":
                    let name = loc(try #require(RuleCheckSpec.named("text-size")).title)
                    #expect(line.contains(name), "\(language): the refused export does not name the rule as the card does («\(name)»): «\(line)»")
                case "language":
                    #expect(line.contains("Prova") && line.contains(StepError.languageInWords("en")), "\(language): «\(line)»")
                case "no voice": #expect(line.contains("Prova"), "\(language): «\(line)»")
                case "file": #expect(line.contains("non-qui.mov"), "\(language): «\(line)»")
                default: break
                }
            }
            // An error without a sentence of its own: the translated lead, then the engine's text (today's fallback).
            #expect(StepError.readable(plain, fallback: "Il motore ha risposto: %@") == String(format: loc("Il motore ha risposto: %@"), JobCenter.message(plain)))
        }
        #expect(refusals.count == 7, "refused: \(refusals.map(\.what))")
    }
}
}
