import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #110: an app opened outside an Applications folder (Downloads, its disk image, the temporary place macOS translocates
// a download to) offers to move itself there and reopen; Settings › Claude does not register its helper meanwhile.

/// A Regista.app in a scratch folder: an Info.plist and the regista-mcp a copy ships, enough to be moved and found.
@MainActor private func fakeApp(in folder: String) throws -> (app: URL, root: URL) {
    let root = rigTempDir("app-location")
    let app = root.appendingPathComponent("\(folder)/Regista.app", isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.regista.copy</string></dict></plist>".utf8)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let mcp = macOS.appendingPathComponent("regista-mcp")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: mcp)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcp.path)
    return (app, root)
}

@Test func onlyACopyOutsideTheApplicationsFoldersOffersToMove() {
    // A home folder of someone else (built, not written: a literal user path does not belong in the repository).
    let home = URL(fileURLWithPath: "/", isDirectory: true).appendingPathComponent("Users").appendingPathComponent("someone", isDirectory: true)
    func at(_ rel: String) -> URL { home.appendingPathComponent(rel) }
    let folders = AppLocation.applicationsFolders(home: home)
    #expect(!AppLocation.shouldOffer(URL(fileURLWithPath: "/Applications/Regista.app"), folders: folders))
    #expect(!AppLocation.shouldOffer(at("Applications/Regista.app"), folders: folders))
    #expect(!AppLocation.shouldOffer(URL(fileURLWithPath: "/Applications/Tools/Regista.app"), folders: folders))
    #expect(AppLocation.shouldOffer(at("Downloads/Regista.app"), folders: folders))
    #expect(AppLocation.shouldOffer(URL(fileURLWithPath: "/Volumes/Regista 0.2.0/Regista.app"), folders: folders))
    #expect(AppLocation.shouldOffer(URL(fileURLWithPath: "/private/var/folders/x/T/AppTranslocation/ABC/d/Regista.app"), folders: folders))
    // A build of the source folder and a test run never ask.
    #expect(!AppLocation.shouldOffer(at("src/regista/build.noindex/Regista.app"), folders: folders))
    #expect(!AppLocation.shouldOffer(at("src/regista/.build/debug"), folders: folders))
    #expect(AppLocation.current() == nil, "the test process is not an app bundle")
    #expect(!AppLocation.shouldOffer(Bundle.main.bundleURL))
    // Where it runs from, in words.
    let dmg = AppLocation(bundle: URL(fileURLWithPath: "/Volumes/Regista 0.2.0/Regista.app"), applications: folders[0])
    #expect(dmg.placeName.contains("Regista 0.2.0"))
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct AppLocationMouseTests {
    /// A host for the launch alert, as the app's window carries it.
    struct Host: View {
        @ObservedObject var prompt: MovePrompt
        var body: some View { Color.clear.frame(width: 520, height: 360).movePrompt(prompt) }
    }

    /// «Sposta e riapri»: the copy lands in the rig's Applications folder (never the real one), without the download's
    /// quarantine, and the reopen gets it once; the alert closes.
    @Test func moveAndReopenCopiesTheAppAndReopensIt() throws {
        let (app, root) = try fakeApp(in: "Downloads")
        setxattr(app.path, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, XATTR_NOFOLLOW)
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        var reopened: [URL] = []
        let prompt = MovePrompt(location: AppLocation(bundle: app, applications: apps), reopen: { reopened.append($0) })
        let rig = MouseRig(Host(prompt: prompt), size: CGSize(width: 520, height: 360))
        defer { rig.close() }
        _ = rig.wait(3) { !rig.sheetButtons().isEmpty }
        #expect(Set(rig.sheetButtons().map(\.title)) == ["Sposta e riapri", "Non ora"], "\(rig.sheetButtons().map(\.title))")
        let move = try #require(rig.sheetButtons().first { $0.title == "Sposta e riapri" })
        rig.click(move)
        _ = rig.wait(3) { !reopened.isEmpty }
        let copy = apps.appendingPathComponent("Regista.app")
        #expect(reopened == [copy], "reopened \(reopened)")
        #expect(FileManager.default.isExecutableFile(atPath: copy.appendingPathComponent("Contents/MacOS/regista-mcp").path))
        #expect(getxattr(copy.path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW) < 0, "the copy keeps no quarantine")
        #expect(FileManager.default.fileExists(atPath: app.path), "the downloaded copy is left where it was")
        _ = rig.wait(2) { rig.window.attachedSheet == nil }
        #expect(rig.window.attachedSheet == nil && prompt.location == nil, "the alert is still open")
    }

    /// «Non ora»: nothing copied, nothing reopened, the alert closes and stays closed.
    @Test func notNowLeavesEverythingAsItIs() throws {
        let (app, root) = try fakeApp(in: "Downloads")
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        var reopened = 0
        let prompt = MovePrompt(location: AppLocation(bundle: app, applications: apps), reopen: { _ in reopened += 1 })
        let rig = MouseRig(Host(prompt: prompt), size: CGSize(width: 520, height: 360))
        defer { rig.close() }
        _ = rig.wait(3) { !rig.sheetButtons().isEmpty }
        let later = try #require(rig.sheetButtons().first { $0.title == "Non ora" })
        rig.click(later)
        _ = rig.wait(2) { rig.window.attachedSheet == nil }
        #expect(rig.window.attachedSheet == nil && prompt.location == nil)
        #expect(reopened == 0 && !FileManager.default.fileExists(atPath: apps.path))
    }

    /// A copy already in Applications: the alert says it is replaced, and it is (the old one goes only after the new one
    /// is complete beside it).
    @Test func aCopyAlreadyThereIsReplacedAfterSayingSo() throws {
        let (app, root) = try fakeApp(in: "Downloads")
        let apps = root.appendingPathComponent("Applications", isDirectory: true)
        let old = apps.appendingPathComponent("Regista.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("old-marker"))
        var reopened: [URL] = []
        let prompt = MovePrompt(location: AppLocation(bundle: app, applications: apps), reopen: { reopened.append($0) })
        #expect(prompt.message.contains(loc("Nella cartella Applicazioni c'è già un Regista: lo sostituisco con questa copia.")))
        let rig = MouseRig(Host(prompt: prompt), size: CGSize(width: 520, height: 360))
        defer { rig.close() }
        _ = rig.wait(3) { !rig.sheetButtons().isEmpty }
        rig.click(try #require(rig.sheetButtons().first { $0.title == "Sposta e riapri" }))
        _ = rig.wait(3) { !reopened.isEmpty }
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("old-marker").path), "the old copy was replaced")
        #expect(FileManager.default.fileExists(atPath: apps.appendingPathComponent("Regista.app/Contents/MacOS/regista-mcp").path))
        #expect(!FileManager.default.fileExists(atPath: apps.appendingPathComponent(".Regista.app.part").path))
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { _ = dir }
    }

    /// Settings › Claude in a copy outside Applications: one line says to move the app first, and «Collega Claude
    /// Desktop…» registers nothing (no confirmation opens, the scratch Claude Desktop configuration is untouched).
    @Test func settingsClaudeSaysToMoveTheAppFirst() async throws {
        let (app, _) = try fakeApp(in: "Downloads")
        let bundle = try #require(Bundle(url: app))
        let config = rigOutside.desktopConfig
        try? FileManager.default.removeItem(at: config)
        let rig = try await AppRig()
        defer { rig.close() }
        rig.host(ClaudeSettings().frame(width: SettingsView.size.width, height: SettingsView.size.height).environment(\.appBundle, bundle),
                 size: SettingsView.size)
        await rig.settle()
        let line = loc("Sposta Regista nella cartella Applicazioni prima di collegare Claude: da dove è aperto ora, il collegamento smetterebbe di funzionare.")
        #expect(!rig.rig.elements(containing: String(line.prefix(40))).isEmpty, "the line is not shown")
        _ = rig.rig.click("Collega Claude Desktop…")
        rig.rig.pump(0.5)
        #expect(rig.rig.sheetButtons().isEmpty, "a confirmation opened: \(rig.rig.sheetButtons().map(\.title))")
        #expect(!FileManager.default.fileExists(atPath: config.path), "Claude Desktop's configuration was written")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try rig.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("n25-claude-outside-applications.png"))
        }
        // In French: the same line, in the window's language.
        rig.host(ClaudeSettings().frame(width: SettingsView.size.width, height: SettingsView.size.height).environment(\.appBundle, bundle),
                 size: SettingsView.size, language: "fr")
        await rig.settle()
        let fr = MouseRig.table("fr").localizedString(forKey: "Sposta Regista nella cartella Applicazioni prima di collegare Claude: da dove è aperto ora, il collegamento smetterebbe di funzionare.", value: nil, table: nil)
        #expect(!rig.rig.elements(containing: String(fr.prefix(40))).isEmpty, "the French line is not shown")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try rig.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("n25-claude-outside-applications-fr.png"))
        }
        // The same tab in the test process (no shipped server): no line.
        rig.host(ClaudeSettings().frame(width: SettingsView.size.width, height: SettingsView.size.height), size: SettingsView.size)
        await rig.settle()
        #expect(rig.rig.elements(containing: String(line.prefix(40))).isEmpty)
    }
}
}
