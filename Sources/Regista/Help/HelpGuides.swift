import AppKit
import Foundation
import SwiftUI

/// The hand-written guides (K1 #7): docs/<it|en|fr|pt>/<guide>.md, copied into the app bundle (Contents/Resources/Help/
/// <lang>/) by scripts/build-app.sh, so the Help menu opens them offline and in the app's language.
enum HelpGuide: String, CaseIterable, Identifiable {
    case userGuide = "user-guide", voice, install, troubleshooting

    var id: String { rawValue }
    var file: String { rawValue + ".md" }

    /// Lookup key of the title: the Help menu item and the row of the help window's list.
    var title: String {
        switch self {
        case .userGuide: "Guida di Regista"
        case .voice: "Registrare la tua voce"
        case .install: "Installazione e motori"
        case .troubleshooting: "Risoluzione dei problemi"
        }
    }

    var symbol: String {
        switch self {
        case .userGuide: "book"
        case .voice: "person.wave.2"
        case .install: "cpu"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }

    /// The `ui.screenshot` workspace that renders the help window on this guide.
    var screenshotName: String { self == .userGuide ? "help" : "help-\(rawValue)" }  // l10n-ignore — an id

    /// The guide a link inside a guide points to ("voice.md", "../en/voice.md#training"), or nil for any other link.
    init?(link url: URL) {
        guard url.scheme == nil || url.isFileURL else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard url.pathExtension == "md", let g = HelpGuide(rawValue: name) else { return nil }
        self = g
    }
}

enum HelpLibrary {
    /// The languages the guides are written in (the UI languages).
    static let languages = ["it", "en", "fr", "pt"]
    /// Where problems are reported (Aiuto › Segnala un problema…).
    static let issuesURL = URL(string: "https://github.com/arkad-consulting/regista/issues")!  // l10n-ignore — a URL

    /// The app's language among the guides' (English for any other).
    static var language: String {
        let preferred = Bundle.main.preferredLocalizations.first ?? "en"
        return languages.first { preferred.hasPrefix($0) } ?? "en"
    }

    /// The folder of one language's guides: the copy inside the app (Contents/Resources/Help/<lang>), else — a plain
    /// `swift build` or the tests — the repository's docs/<lang>.
    static func folder(_ language: String, bundle: Bundle = .main) -> URL? {
        let candidates = [bundle.resourceURL?.appendingPathComponent("Help/\(language)", isDirectory: true),
                          repositoryDocs.appendingPathComponent(language, isDirectory: true)]
        return candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent(HelpGuide.userGuide.file).path) }
    }

    /// docs/ of the source tree this file was built from (only useful on the machine that built it; a release build
    /// carries no path of the Mac that built it, #108).
    #if REGISTA_RELEASE
    static let repositoryDocs = URL(fileURLWithPath: "/nonexistent/docs", isDirectory: true)
    #else
    static let repositoryDocs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs", isDirectory: true)
    #endif

    /// The Markdown of a guide in `language` (English when that language has no copy), nil when no copy is found.
    static func text(_ guide: HelpGuide, language: String = language) -> String? {
        for lang in [language, "en"] {
            if let dir = folder(lang), let s = try? String(contentsOf: dir.appendingPathComponent(guide.file), encoding: .utf8) { return s }
        }
        return nil
    }
}

/// The help window's state (which guide shows) and the Help menu's actions.
@MainActor
final class HelpCenter: ObservableObject {
    static let shared = HelpCenter()
    static let windowID = "help"   // l10n-ignore — a scene id

    @Published var guide: HelpGuide = .userGuide

    /// Shows `guide` in the help window (opened if needed).
    static func open(_ guide: HelpGuide, with openWindow: OpenWindowAction) {
        shared.guide = guide
        openWindow(id: windowID)
        NSApp.activate()
    }

    /// The public issues page, in the browser.
    static func reportProblem() { NSWorkspace.shared.open(HelpLibrary.issuesURL) }
}
