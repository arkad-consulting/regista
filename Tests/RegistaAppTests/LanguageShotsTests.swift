import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #120: every screen the click audits open, rendered in Italian and French into $REGISTA_LANGUAGE_SHOTS (only when it is
// set): a run before and after a change to the words shows, image by image, what changed. Not part of the hooks' runs.

private let shotsFolder = ProcessInfo.processInfo.environment["REGISTA_LANGUAGE_SHOTS"]

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

    @Test(arguments: ["it", "fr"])
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
}
}
