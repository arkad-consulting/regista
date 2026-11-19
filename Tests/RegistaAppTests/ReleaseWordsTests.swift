import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #113: a downloaded app (a release build: `RegistaRelease` in its Info.plist) never tells a person to run a script of the
// source folder; a build of that folder keeps naming it.

/// A Regista.app in a scratch folder, with or without the release key (no regista-mcp: what Settings › Claude says then).
@MainActor private func app(release: Bool) throws -> Bundle {
    let app = rigTempDir("release-words").appendingPathComponent("build.noindex/Regista.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    let key = release ? "<key>RegistaRelease</key><true/>" : ""
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.regista.release\(release)</string>\(key)</dict></plist>".utf8)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    return try #require(Bundle(url: app))
}

/// What a person can be shown: a mention of a source folder's script, Homebrew or brew.
private func namesSourceTooling(_ text: String) -> Bool {
    text.contains("scripts/") || text.contains("brew install") || text.contains("Homebrew") || text.contains(".sh ")
}

/// Every key and value of a table.
private func table(_ language: String) throws -> [String: String] {
    let url = RigOutside.repository.appendingPathComponent("Resources/Localization/\(language).lproj/Localizable.strings")
    return try #require(NSDictionary(contentsOf: url) as? [String: String], "\(language) table")
}

@Test @MainActor func theReleaseFlagIsTheBundlesKey() throws {
    #expect(ReleaseBuild.isRelease(try app(release: true)))
    #expect(!ReleaseBuild.isRelease(try app(release: false)))
    #expect(!ReleaseBuild.isRelease(), "the test process is a build of the source folder")
    let key = "Non trovo regista-mcp: esegui scripts/install.sh"
    #expect(ReleaseWords.pick(key, bundle: try app(release: false)) == key)
    #expect(ReleaseWords.pick(key, bundle: try app(release: true)) == ReleaseWords.forRelease[key])
    #expect(ReleaseBuild.sourceHint(" (run scripts/x.sh)", isRelease: true).isEmpty)
    #expect(ReleaseBuild.sourceHint(" (run scripts/x.sh)", release: "y", isRelease: true) == "y")
}

/// The user-facing strings a release build can show: every entry of the four tables except the source-only ones
/// (ReleaseWords' keys), which a release build replaces by their release text. None names a script, brew or Homebrew.
@Test func noTextOfAReleaseBuildNamesAScript() throws {
    for language in ["it", "en", "fr", "pt"] {
        let t = try table(language)
        let shown = t.filter { ReleaseWords.forRelease[$0.key] == nil }
        let bad = shown.filter { namesSourceTooling($0.key) || namesSourceTooling($0.value) }.map(\.key).sorted()
        #expect(bad.isEmpty, "\(language): a release build can show \(bad)")
        for (source, release) in ReleaseWords.forRelease {
            #expect(t[source] != nil, "\(language): the source text «\(source)» is not in the table")
            let value = try #require(t[release], "\(language): the release text «\(release)» is not in the table")
            #expect(!namesSourceTooling(value) && !namesSourceTooling(release), "\(language): «\(value)»")
        }
    }
}

/// The command errors and hints a release build sends (shown in a job's line, relayed by Claude): every literal of the
/// engine's sources that names a script of the source folder goes through ReleaseBuild.sourceHint (or is a file path).
@Test func theEngineNamesAScriptOnlyInASourceBuild() throws {
    let root = RigOutside.repository.appendingPathComponent("Sources", isDirectory: true)
    var bad: [String] = []
    let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
    while let f = walker?.nextObject() as? URL {
        guard f.pathExtension == "swift", f.lastPathComponent != "ReleaseWords.swift" else { continue }
        let lines = try String(contentsOf: f, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
        for (n, line) in lines.enumerated() {
            let code = line.trimmingCharacters(in: .whitespaces)
            if code.hasPrefix("//") { continue }
            guard let r = code.range(of: "\"[^\"]*scripts/[a-z-]+\\.sh", options: .regularExpression) else { continue }
            if code.contains("ReleaseBuild.sourceHint(") || code.contains("ReleaseWords.pick(") || code.contains("appendingPathComponent(\"scripts/") { continue }
            // A source text ReleaseWords replaces in a release build (the call site picks it).
            if ReleaseWords.forRelease.keys.contains(where: { code.contains($0) }) { continue }
            // A summary for agents or a doc string inside a code literal is fine when it is not a message to a person:
            // only the message builders are checked (an error, a reason, a notice).
            if code.contains("static let summary") || code.contains("description:") { continue }
            bad.append("\(f.lastPathComponent):\(n + 1): \(code[r])")
        }
    }
    #expect(bad.isEmpty, "\(bad.joined(separator: "\n"))")
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct ReleaseWordsMouseTests {
    /// Settings › Claude in a release build without its server: the line says to install Regista again from its disk
    /// image; in a source build it still names the script.
    @Test(arguments: [true, false])
    func settingsClaudeSaysWhatADownloadedAppCanDo(_ release: Bool) async throws {
        let rig = try await AppRig()
        defer { rig.close() }
        rig.host(ClaudeSettings().frame(width: SettingsView.size.width, height: SettingsView.size.height).environment(\.appBundle, try app(release: release)),
                 size: SettingsView.size, language: "fr")
        await rig.settle()
        let words = MouseRig.table("fr")
        let source = "Non incluso in questa build: installa l'app con scripts/install.sh"
        let expected = words.localizedString(forKey: release ? ReleaseWords.forRelease[source]! : source, value: nil, table: nil)
        #expect(!rig.rig.elements(containing: String(expected.prefix(30))).isEmpty, "\(release): «\(expected)» is not shown")
        #expect(rig.rig.elements(containing: "scripts/").isEmpty == release, "\(release): a mention of a script")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"], release {
            try rig.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("n26-claude-release-fr.png"))
        }
    }
}
}
