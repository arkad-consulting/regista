import Foundation
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// M2 (#59): Impostazioni rebuilt — the Claude tab reads Claude Desktop's and Claude Code's config files, the Scorciatoie
// tab lists the catalog the menus use, Generale's choices, the forced tier written into engines.json without losing a key.

private func settingsTempDir() -> URL {
    let url = TemporaryFolder.url.appendingPathComponent("regista-settings-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func theClaudeTabReadsBothConfigFiles() throws {
    let dir = settingsTempDir()
    let mcp = dir.appendingPathComponent("regista-mcp")
    try Data("#!/bin/sh\n".utf8).write(to: mcp)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcp.path)
    // Claude Desktop: other servers and keys beside regista.
    let desktop = dir.appendingPathComponent("claude_desktop_config.json")
    try Data("""
    {"globalShortcut": "", "mcpServers": {"other": {"command": "/bin/echo"}, "regista": {"command": "\(mcp.path)", "args": []}}}
    """.utf8).write(to: desktop)
    // Claude Code (~/.claude.json): user-scope servers without regista.
    let code = dir.appendingPathComponent(".claude.json")
    try Data(#"{"numStartups": 3, "mcpServers": {"github": {"type": "stdio", "command": "gh"}}, "projects": {}}"#.utf8).write(to: code)

    let c = ClaudeClients.read(desktop: desktop, code: code)
    #expect(c.desktop == .connected(command: mcp.path, exists: true))
    #expect(c.code == .notConnected)
    #expect(c.mcpBinary(bundle: Bundle(for: BundleToken.self)) == mcp.path, "the command a client already runs, when the app ships none")

    // A command that is gone; a broken file (never touched); no file at all.
    try Data(#"{"mcpServers": {"regista": {"type": "stdio", "command": "/nowhere/regista-mcp", "args": [], "env": {}}}}"#.utf8).write(to: code)
    #expect(ClaudeClients.state(code) == .connected(command: "/nowhere/regista-mcp", exists: false))
    try Data("{not json".utf8).write(to: desktop)
    if case .unreadable = ClaudeClients.state(desktop) {} else { Issue.record("a broken config is reported unreadable") }
    #expect(String(decoding: try Data(contentsOf: desktop), as: UTF8.self) == "{not json")
    #expect(ClaudeClients.state(dir.appendingPathComponent("missing.json")) == .notConnected)
    #expect(ClaudeClients.read(desktop: desktop, code: code).mcpBinary(bundle: Bundle(for: BundleToken.self)) == nil)
    // What "Collega Claude Desktop" shows before writing: the same entry ClaudeDesktopConfig writes.
    #expect(ClaudeClients.desktopEntry("/x/regista-mcp") == #""regista": {"command": "/x/regista-mcp", "args": []}"#)
    #expect(StartPrompt.text.contains("recipe_get"), "the start prompt of handoff/START-PROMPT.md is compiled in")
    #expect(!StartPrompt.text.hasPrefix("#"), "only the block to paste, not the page's own heading")
}

private final class BundleToken {}

@Test func theClaudeTabSaysWhenAConfigPointsToAnotherCopy() {
    // M3 (#60): the app ships its own regista-mcp; a config that runs another one (a development build under .build/, an
    // older app, a file that is gone) is shown as such and offered a repoint.
    let bundled = "/Applications/Regista.app/Contents/MacOS/regista-mcp"
    let dev = "/tmp/some-clone/.build/release/regista-mcp"
    #expect(ClaudeClients.verdict(.connected(command: bundled, exists: true), bundled: bundled) == .here(bundled))
    #expect(ClaudeClients.verdict(.connected(command: dev, exists: true), bundled: bundled) == .elsewhere(command: dev, exists: true))
    #expect(ClaudeClients.verdict(.connected(command: dev, exists: false), bundled: bundled) == .elsewhere(command: dev, exists: false))
    #expect(ClaudeClients.verdict(.notConnected, bundled: bundled) == .notConnected)
    // A plain swift build (no server inside): what already works is kept, a missing file still offers to reconnect.
    #expect(ClaudeClients.verdict(.connected(command: dev, exists: true), bundled: nil) == .here(dev))
    #expect(ClaudeClients.verdict(.connected(command: dev, exists: false), bundled: nil) == .elsewhere(command: dev, exists: false))
    #expect(ClaudeClients.bundledMCP(bundle: Bundle(for: BundleToken.self)) == nil)
    // The licence shown before a non-commercial engine is installed (Motori, #20).
    let row = EngineCatalog(status: ["tier": "pro", "memoryGB": 48, "engines": []]).row("aligner-it")!
    let text = EnginesSettings.licenceMessage(row)
    #expect(text.contains("CC-BY-NC-4.0") && text.contains("https://creativecommons.org/licenses/by-nc/4.0/"))
}

@Test func theShortcutListIsTheMenusCatalog() throws {
    let all = AppShortcuts.all
    let keys = Set(all.map(\.display))
    for n in 1...9 { #expect(keys.contains("⌘\(n)"), "⌘\(n)") }
    for k in ["⌘T", "⌘W", "⇧⌘R", "⌘S", "⇧⌘S", "⌘Z", "⇧⌘Z", "⌃⇥"] { #expect(keys.contains(k), "\(k)") }
    #expect(AppShortcuts.activities.count == Navigation.Activity.allCases.count)
    #expect(Set(all.map(\.id)).count == all.count, "ids are unique")
    // The menu shortcuts are unique (two menu items cannot share a key); the editor's keys work outside the menus.
    let menu = all.filter { $0.group != .editor && $0.group != .teleprompter }
    #expect(Set(menu.map(\.display)).count == menu.count, "two menu items share a key: \(menu.map(\.display))")
    // Search, by words or by keys.
    #expect(AppShortcuts.search("registrazione").flatMap(\.items).contains { $0.id == "record" })
    #expect(AppShortcuts.search("⇧⌘R").flatMap(\.items).map(\.id) == ["record"])
    #expect(AppShortcuts.search("nessuna-parola-così").isEmpty)
    // Generated, not hand-written: every menu item of the app takes its key from the catalog, through the one table the
    // menu bar is drawn from (#36: MenuCommands.swift; MenuCommandTests runs it).
    for file in ["Sources/Regista/App/RegistaApp.swift", "Sources/Regista/App/MenuCommands.swift"] {
        let text = try String(contentsOf: sourceRoot.appendingPathComponent(file), encoding: .utf8)
        #expect(!text.contains(".keyboardShortcut("), "a menu shortcut bypasses AppShortcuts in \(file)")
    }
    let table = try String(contentsOf: sourceRoot.appendingPathComponent("Sources/Regista/App/MenuCommands.swift"), encoding: .utf8)
    #expect(table.components(separatedBy: "AppShortcuts.").count - 1 >= 20)
}

@Test func generalChoicesShapeNewProjects() {
    let d = TestDefaults.make("settings")
    defer { TestDefaults.end(d) }
    let dir = URL(fileURLWithPath: "/tmp/p")
    #expect(GeneralPrefs.newProject(name: "a", directory: dir, d)["width"] == 1080 && GeneralPrefs.newProject(name: "a", directory: dir, d)["height"] == 1920)
    d.set("16:9", forKey: GeneralPrefs.formatKey)
    #expect(GeneralPrefs.newProject(name: "a", directory: dir, d)["width"] == 1920 && GeneralPrefs.newProject(name: "a", directory: dir, d)["height"] == 1080)
    d.set("4:5", forKey: GeneralPrefs.formatKey)
    #expect(GeneralPrefs.newProject(name: "a", directory: dir, d)["height"] == 1350)
    #expect(GeneralPrefs.newProject(name: "a", directory: dir, d)["directory"] == "/tmp/p")
    // Auto-save: only projects with a folder and unsaved changes.
    #expect(AutoSave.due([(true, true, true), (true, true, false), (true, false, true), (false, false, false)]) == [0])
    #expect(GeneralPrefs.interfaceLanguages == ["", "it", "en", "fr", "pt"])
    #expect(GeneralPrefs.spokenLanguageKey == StepSettings.languageKey, "Generale and the steps share one language choice")
}

@Test func theForcedTierIsWrittenWithoutLosingAKey() throws {
    let file = settingsTempDir().appendingPathComponent("engines.json")
    try Data(#"{"ffmpeg": "/opt/homebrew/bin/ffmpeg", "sfxLibrary": "~/sfx"}"#.utf8).write(to: file)
    try EnginesModel.writeForcedTier(.medium, to: file)
    #expect(EnginesModel.readForcedTier(file) == .medium)
    let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])
    #expect(o == ["ffmpeg": "/opt/homebrew/bin/ffmpeg", "sfxLibrary": "~/sfx", "tier": "medium"])
    try EnginesModel.writeForcedTier(nil, to: file)
    #expect(EnginesModel.readForcedTier(file) == nil)
    #expect((try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: String])?.keys.sorted() == ["ffmpeg", "sfxLibrary"])
    // A broken file is refused, not overwritten.
    try Data("{oops".utf8).write(to: file)
    #expect(throws: (any Error).self) { try EnginesModel.writeForcedTier(.pro, to: file) }
    #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "{oops")
}

@Test func everySettingsTabHasARender() {
    #expect(SettingsTab.allCases.map(\.screenshotName) == ["settings-general", "settings-engines", "settings-voice", "settings-brand", "settings-rules", "settings-claude", "settings-shortcuts"])
    let shots = (try? String(contentsOf: sourceRoot.appendingPathComponent("scripts/ui-shots.sh"), encoding: .utf8)) ?? ""
    for name in SettingsTab.allCases.map(\.screenshotName) + ["settings-engines-base", "settings-engines-medium", "settings-engines-pro", "export-rules", "export-rules-pass"] {
        #expect(shots.contains(name), "scripts/ui-shots.sh renders \(name)")
    }
}

@Test func theLegacyPipelineIsGone() throws {
    // No live code reads the old API keys (the Keychain items the user stored stay where they are, untouched).
    let fm = FileManager.default
    let root = sourceRoot.appendingPathComponent("Sources/Regista")
    let files = fm.enumerator(at: root, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for f in files {
        let text = try String(contentsOf: f, encoding: .utf8)
        for word in ["SecItemDelete", "SecItemAdd", "ProjectModel", "api.openai.com", "ElevenLabs"] {
            #expect(!text.contains(word), "\(f.lastPathComponent) still has \(word)")
        }
    }
}

/// Every tab draws, and Motori differs between the forced tiers (the spec's acceptance line). With REGISTA_UI_SNAPSHOTS set,
/// the renders are written there as settings-<tab>.png.
@MainActor
@Test func everySettingsTabDrawsAndMotoriFollowsTheTier() async throws {
    _ = NSApplication.shared
    setenv("REGISTA_ENGINE_SOCKET", settingsTempDir().appendingPathComponent("e.sock").path, 1)
    let defaults = TestDefaults.make("settings-render")
    defer { TestDefaults.end(defaults) }
    let store = EditorStore(defaults: defaults, seedFolders: [])
    let status = try await store.silent("engines.status")
    func render(_ tab: SettingsTab, tier: MachineTier? = nil) async throws -> NSBitmapImageRep {
        let h = tab == .engines ? CGFloat(SettingsView.enginesRenderHeight) : SettingsView.size.height
        let root = SettingsView(pinned: tab, engines: EnginesDemo(status: status, tier: tier), voiceProfiles: VoiceDemo.profiles, height: h)
            .environmentObject(store).environment(\.voiceDemo, VoiceDemo.model("ready", tier: nil))
            .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor))
        let view = NSHostingView(rootView: root)
        view.frame = CGRect(origin: .zero, size: CGSize(width: SettingsView.size.width, height: h))
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        w.contentView = nil
        return rep
    }
    var shots: [(String, NSBitmapImageRep)] = []
    for t in SettingsTab.allCases { shots.append((t.screenshotName, try await render(t))) }
    for t in MachineTier.allCases { shots.append(("settings-engines-\(t.rawValue)", try await render(.engines, tier: t))) }
    let png = shots.map { ($0.0, $0.1.representation(using: .png, properties: [:])!) }
    #expect(png.allSatisfy { $0.1.count > 10_000 }, "every tab draws something")
    let byName = Dictionary(uniqueKeysWithValues: png)
    #expect(byName["settings-engines-base"] != byName["settings-engines-pro"], "Motori on Base and on Pro differ")
    #expect(byName["settings-engines-base"] != byName["settings-engines-medium"])
    if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
        for (n, d) in png { try d.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(n).png")) }
    }
}
