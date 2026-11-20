import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #120: every screen the click audits open, rendered in Italian and French into $REGISTA_LANGUAGE_SHOTS (only when it is
// set): a run before and after a change to the words shows, image by image, what changed. Not part of the hooks' runs.
// #129: REGISTA_SHOT_LANGUAGES ("en,pt") renders other languages, here and in the tests that render a newer state.

private let shotsFolder = ProcessInfo.processInfo.environment["REGISTA_LANGUAGE_SHOTS"]

/// The languages of the language renders: $REGISTA_SHOT_LANGUAGES, comma-separated ("en,pt"), else Italian and French.
let shotLanguages: [String] = {
    let named = (ProcessInfo.processInfo.environment["REGISTA_SHOT_LANGUAGES"] ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return named.isEmpty ? ["it", "fr"] : named
}()

extension MouseSuites {
@Suite(.serialized, .enabled(if: shotsFolder != nil, "only with REGISTA_LANGUAGE_SHOTS")) @MainActor struct LanguageShotsTests {
    static var screens: [(name: String, nav: Navigation, size: CGSize)] {
        let standard = CGSize(width: 1440, height: 900)
        var out: [(String, Navigation, CGSize)] = [
            ("shell", Navigation(activity: .media, rightTab: .inspector), standard),
            ("home", Navigation(activity: .home, rightTab: .inspector), standard),
            ("record", Navigation(activity: .record, rightTab: .inspector), standard),
            ("voice", Navigation(activity: .voice, rightTab: .inspector), standard),
            ("generate", Navigation(activity: .generate, rightTab: .inspector), CGSize(width: 1440, height: 1300)),
            ("export", Navigation(activity: .export, rightTab: .inspector), CGSize(width: 1440, height: 1300)),
        ]
        for t in Navigation.TextsTab.allCases { var n = Navigation(activity: .texts, rightTab: .inspector); n.textsTab = t; out.append(("texts-\(t.rawValue)", n, standard)) }
        for t in Navigation.SoundTab.allCases { var n = Navigation(activity: .audio, rightTab: .inspector); n.soundTab = t; out.append(("audio-\(t.rawValue)", n, standard)) }
        for g in Navigation.GraphicsSection.allCases { var n = Navigation(activity: .graphics, rightTab: .inspector); n.showGraphics(g); out.append(("graphics-\(g.rawValue)", n, standard)) }
        var simple = Navigation(activity: .media, rightTab: .inspector)
        simple.show(.simple)
        out.append(("simple", simple, standard))
        for r in Navigation.RightTab.allCases { out.append(("right-\(r.rawValue)", Navigation(activity: .media, rightTab: r), standard)) }
        return out
    }

    @Test(arguments: shotLanguages)
    func everyScreenInTheLanguage(_ language: String) async throws {
        let dir = URL(fileURLWithPath: shotsFolder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for s in Self.screens {
            let app = try await AppRig(project: s.name == "home" ? nil : "rich")
            app.hostEditor(s.nav, size: s.size, language: language)
            await app.settle()
            await app.idle(0.3)
            try app.snapshot(to: dir.appendingPathComponent("\(s.name)-\(language).png"))
            app.close()
        }
        for tab in SettingsTab.allCases {
            let app = try await AppRig()
            let status = try await app.store.silent("engines.status")
            let size = CGSize(width: SettingsView.size.width, height: tab == .engines ? CGFloat(SettingsView.enginesRenderHeight) : SettingsView.size.height)
            app.host(SettingsView(pinned: tab, engines: tab == .engines ? EnginesDemo(status: status, tier: .pro, open: "comfyui") : nil,
                                  rulesDemo: tab == .rules, height: size.height), size: size, language: language)
            await app.settle()
            await app.idle(0.3)
            try app.snapshot(to: dir.appendingPathComponent("settings-\(tab.rawValue)-\(language).png"))
            app.close()
        }
    }

    /// A step of the Claude panel as the store logs it once the command answered: its sentence (CommandLines) and, for the
    /// tooltip, its raw fields (Summary.details), in the language the rig set.
    static func step(_ id: String, _ params: JSONValue, _ result: JSONValue, agent: Bool = true) -> EditorStore.Activity {
        var a = EditorStore.Activity(source: agent ? "Claude" : "Tu", isAgent: agent, command: id, params: Summary.params(params))
        a.status = .ok
        a.result = CommandLines.line(id, result) ?? ""
        a.details = Summary.details(id, result)
        a.seconds = 1.4
        return a
    }

    /// The states newer than the last sweeps that the screens above do not reach (#129): the Claude panel's second line for
    /// a few commands (the filler words found and deleted as ranges among them), an export that restarted once (the
    /// Claude panel and «Ultimo export»), and the teleprompter window. The row's tooltip cannot be drawn offscreen: its
    /// text is written beside the images (claude-lines-<language>.txt).
    @Test(arguments: shotLanguages)
    func theNewerStatesInTheLanguage(_ language: String) async throws {
        let dir = URL(fileURLWithPath: shotsFolder!)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let check: JSONValue = ["kind": "talking-head-reel", "pass": true, "failures": 0, "warnings": 0, "violations": [], "checks": []]
        let export: JSONValue = ["path": "/scratch/reel.mp4", "preset": "9:16", "width": 1080, "height": 1920, "fps": 30, "frames": 106,
                                 "duration": 3.53, "rules": check, "warnings": [], "loudness": ["integrated": -15.1, "truePeak": -1.7],
                                 "restartedAtFrame": 12]
        for screen in [("claude-lines", Navigation(activity: .media, rightTab: .claude)), ("export-restarted", Navigation(activity: .export, rightTab: .claude))] {
            let app = try await AppRig(project: "rich")
            app.hostEditor(screen.1, size: CGSize(width: 1440, height: screen.0 == "export-restarted" ? 1300 : 900), language: language)
            await app.settle()
            _ = try? await app.store.perform("takes.select", ["line": 9, "take": 1])   // a failed step, its reason in words
            app.store.activity += [
                Self.step("transcript.run", ["language": "it"], ["words": 48]),
                Self.step("transcript.fillers", [:], ["trackId": "t1", "language": "it", "count": 3, "fillers": [], "delete": [:]]),
                Self.step("transcript.fillers", [:], ["trackId": "t1", "language": "it", "count": 1, "fillers": [], "delete": [:]]),
                Self.step("transcript.deleteWords", ["ranges": [[1.2, 1.5], [2.2, 2.9], [4.0, 4.3]]],
                          ["ranges": [[1.2, 1.5], [2.2, 2.9], [4.0, 4.3]], "removed": "ehm · allora · cioè", "commands": []]),
                Self.step("transcript.deleteWords", ["ranges": [[2.2, 2.9]]], ["ranges": [[2.2, 2.9]], "removed": "ehm", "commands": []]),
                Self.step("transcript.deleteWords", ["from": 2.2, "to": 2.9], ["removed": "ehm allora", "from": 2.2, "to": 2.9, "commands": []]),
                Self.step("edit.autoCut", [:], ["commands": [], "segments": [["line": 1], ["line": 2]], "duration": 3.53]),
                Self.step("audio.clean", [:], ["trackId": "t2", "commands": [], "loudness": ["integrated": -15.02, "truePeak": -1.6], "lagMs": 0]),
                Self.step("captions.generate", ["style": "talking-head-v1"], ["trackId": "t3", "style": "talking-head-v1", "chunks": 5, "words": 10]),
                Self.step("export.render", ["path": "/scratch/reel.mp4"], export),
            ]
            await app.settle()
            await app.idle(0.3)
            try app.snapshot(to: dir.appendingPathComponent("\(screen.0)-\(language).png"))
            if screen.0 == "claude-lines" {
                let text = app.store.activity.map { "\($0.command) | \($0.status) | \($0.result) | tooltip: \([$0.params, $0.details].filter { !$0.isEmpty }.joined(separator: " / "))" }
                try text.joined(separator: "\n").write(to: dir.appendingPathComponent("claude-lines-\(language).txt"), atomically: true, encoding: .utf8)
            }
            app.close()
        }
        // The teleprompter window, as the speaker sees it, with its own sample text.
        let app = try await AppRig()
        let prompter = TeleprompterController.preview(text: MouseRig.table(language).localizedString(forKey: TeleprompterController.sampleKey, value: nil, table: nil), mirror: false, fontSize: 40, mode: .voice)
        app.host(TeleprompterView(controller: prompter, settled: true), size: TeleprompterController.defaultSize, language: language)
        await app.settle()
        await app.idle(0.6)
        try app.snapshot(to: dir.appendingPathComponent("teleprompter-\(language).png"))
        app.close()
    }
}
}
