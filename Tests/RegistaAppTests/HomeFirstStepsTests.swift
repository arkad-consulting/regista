import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #112: Inizio's «Per cominciare» on a downloaded app: one row per thing still missing (the transcription model, the
// connection to Claude), each button proven by a click; nothing pending, no block at all.

/// A Regista.app that ships its own regista-mcp (so no Claude client of the rig runs *its* server), in a folder named
/// build.noindex (a build of the source folder: no move prompt) or in a Downloads folder (outside Applications, #110).
@MainActor private func shippedApp(in folder: String = "build.noindex") throws -> Bundle {
    let app = rigTempDir("first-steps-app").appendingPathComponent("\(folder)/Regista.app", isDirectory: true)
    let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.regista.firststeps</string></dict></plist>".utf8)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let mcp = macOS.appendingPathComponent("regista-mcp")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: mcp)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mcp.path)
    return try #require(Bundle(url: app))
}

/// The rig's services with the transcription model missing (a path nothing is at) or present (an empty file).
@MainActor private func model(present: Bool) -> @MainActor (inout EngineServices) -> Void {
    model(at: modelFile(present: present))
}

/// A model file in a scratch folder, there or not.
@MainActor private func modelFile(present: Bool) -> URL {
    let file = rigTempDir("first-steps-model").appendingPathComponent("ggml-large-v3-turbo.bin")
    if present { FileManager.default.createFile(atPath: file.path, contents: Data()) }
    return file
}

/// The rig's services reading the transcription model at `file`.
@MainActor private func model(at file: URL) -> @MainActor (inout EngineServices) -> Void {
    { $0.config.whisperModel = file.path }
}

/// An installer of the test's own (scripts/install.sh in a scratch folder, run as the app runs its own): it writes down
/// its arguments, then writes the model file where the configuration expects it, or fails with its «✗» line.
@MainActor private func installer(writing model: URL, fails: Bool = false) throws -> (installer: EngineInstaller, calls: URL) {
    let dir = rigTempDir("first-steps-installer")
    let calls = dir.appendingPathComponent("calls.log")
    let script = dir.appendingPathComponent("scripts/install.sh")
    try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    let work = fails ? "echo \"✗ the model could not be downloaded (test installer)\"\nexit 1"
        : "printf 'model' > \"\(model.path)\"\necho \"✓ whisper-model installed (test installer)\""
    try "#!/bin/bash\necho \"$@\" >> \"\(calls.path)\"\n\(work)\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return (EngineInstaller(script: script), calls)
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct HomeFirstStepsTests {
    static let size = CGSize(width: 1100, height: 900)

    /// A key in the window's language (the buttons' titles go through the app's own lookup).
    static func word(_ key: String, _ language: String?) -> String {
        guard let language else { return key }
        return MouseRig.table(language).localizedString(forKey: key, value: nil, table: nil)
    }

    /// No Claude client connected to any Regista server (a Mac the app was just downloaded on).
    static let noClient = ClaudeClients(desktop: .notConnected, code: .notConnected)

    /// Inizio hosted as the window shows it, with `bundle` as this app, `clients` as the Claude clients' state (nil: the
    /// rig's own — Claude Code runs the test process's server) and `installer` as the one «Scarica» runs (nil: the
    /// rig's, which installs nothing). The Settings window «Collega…» brings up is a count (no Settings scene here).
    static func host(_ app: AppRig, bundle: Bundle = .main, language: String? = nil, clients: ClaudeClients? = noClient,
                     installer: EngineInstaller? = nil, raised: @escaping () -> Void = {}) async {
        app.host(HomeWorkspace().environment(\.appBundle, bundle).environment(\.settingsWindowOpener, raised)
            .environment(\.claudeClientsReader, clients.map { c in { c } })
            .environment(\.firstStepsInstaller, installer.map { i in { i } })
            .frame(width: size.width, height: size.height), size: size, language: language)
        await app.settle()
        _ = app.rig.wait(5) { app.store.engineSummary != nil }
        await app.settle()
    }

    static func label(_ language: String?) -> String { word("Per cominciare", language).uppercased(with: Locale.current) }

    static func snapshot(_ app: AppRig, _ name: String) throws {
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
    }

    /// Both rows pending (no model, no Claude client on this app's server), in Italian and French: «Scarica» starts the
    /// install job of Settings › Motori once (the rig's installer writes down `--only whisper-model` and installs
    /// nothing); the row is still there afterwards with its button, and the start cards are still on screen.
    @Test(arguments: ["it", "fr"])
    func bothRowsAndTheDownload(_ language: String) async throws {
        let app = try await AppRig(project: nil, services: model(present: false))
        defer { app.close() }
        await Self.host(app, bundle: try shippedApp(), language: language)
        #expect(!app.rig.elements(containing: Self.label(language)).isEmpty, "\(language): no «Per cominciare»")
        #expect(!app.rig.elements(containing: Self.word("Modello per trascrivere e fare i sottotitoli", language)).isEmpty)
        #expect(!app.rig.elements(containing: Self.word("Collega Claude per montare parlando", language)).isEmpty)
        #expect(!app.rig.elements(containing: Self.word("Reel parlato", language)).isEmpty, "the start cards are not on screen")
        try Self.snapshot(app, "n26-home-first-steps-\(language).png")

        let before = rigOutside.installs.filter { $0.contains("--only whisper-model") }.count
        let download = try #require(app.rig.element(Self.word("Scarica", language)), "no «Scarica»")
        app.rig.click(download.centre)
        _ = app.rig.wait(5) { rigOutside.installs.filter { $0.contains("--only whisper-model") }.count > before }
        _ = app.rig.wait(5) { app.store.jobs.latest(EnginesModel.jobKind("whisper-model"))?.isRunning == false }
        await app.settle()
        #expect(rigOutside.installs.filter { $0.contains("--only whisper-model") }.count == before + 1, "the download did not start once")
        #expect(app.store.jobs.latest(EnginesModel.jobKind("whisper-model"))?.title == String(format: loc("Installo %@"), loc("Whisper large-v3-turbo (ggml)")),
                "not the job Settings › Motori starts")
        // The stand-in installed nothing: the model is still missing and the row keeps its button.
        #expect(app.rig.element(Self.word("Scarica", language)) != nil, "the row lost its button")
    }

    /// A download running (the job Settings › Motori shows): the row shows its progress and «Annulla», which stops it.
    @Test(arguments: ["it", "fr"])
    func aDownloadRunning(_ language: String) async throws {
        let app = try await AppRig(project: nil, services: model(present: false))
        defer { app.close() }
        let job = app.store.jobs.start(kind: EnginesModel.jobKind("whisper-model"), title: String(format: loc("Installo %@"), loc("Whisper large-v3-turbo (ggml)")),
                                       tab: loc("Motori")) { _ in try await Task.sleep(for: .seconds(600)) }
        app.store.jobs.update(job, progress: 0.42, detail: nil)
        await Self.host(app, bundle: try shippedApp(), language: language)
        #expect(app.rig.element(Self.word("Scarica", language)) == nil, "«Scarica» while the download runs")
        #expect(!app.rig.elements(containing: "42 %").isEmpty, "\(language): the progress is not shown")
        try Self.snapshot(app, "n26-home-first-steps-downloading-\(language).png")
        let cancel = try #require(app.rig.element(Self.word("Annulla", language)), "no «Annulla»")
        app.rig.click(cancel.centre)
        _ = app.rig.wait(3) { app.store.jobs.job(job)?.isRunning == false }
        #expect(app.store.jobs.job(job)?.state == .cancelled, "«Annulla» did not stop the download")
        await app.settle()
        #expect(app.rig.element(Self.word("Scarica", language)) != nil, "the row did not come back to «Scarica»")
    }

    /// #119: «Collega…» takes the route of every «open Settings on a tab» (SettingsRoute.open): a Settings window already
    /// open on Generale beside Inizio shows the Claude tab after the click, and the window is brought up once; the row
    /// stays (nothing is connected yet).
    @Test func connectShowsTheClaudeTabInSettings() async throws {
        let saved = (UserDefaults.standard.object(forKey: SettingsRoute.tabKey), UserDefaults.standard.object(forKey: SettingsRoute.engineKey))
        defer {
            UserDefaults.standard.set(saved.0, forKey: SettingsRoute.tabKey)
            UserDefaults.standard.set(saved.1, forKey: SettingsRoute.engineKey)
        }
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: SettingsRoute.tabKey)
        let app = try await AppRig(project: nil, services: model(present: true))
        defer { app.close() }
        var raised = 0
        let size = CGSize(width: Self.size.width + SettingsView.size.width, height: Self.size.height)
        app.host(HStack(alignment: .top, spacing: 0) {
            HomeWorkspace().frame(width: Self.size.width, height: Self.size.height)
            SettingsView()
        }
        .environment(\.appBundle, try shippedApp()).environment(\.settingsWindowOpener, { raised += 1 })
        .environment(\.claudeClientsReader, { Self.noClient }), size: size)
        await app.settle()
        _ = app.rig.wait(5) { app.store.engineSummary != nil }
        await app.settle()
        #expect(app.rig.element("Scarica") == nil, "the model row with the model there")
        #expect(!app.rig.elements(containing: "Lingua dell'interfaccia").isEmpty, "Settings does not start on Generale")
        #expect(app.rig.elements(containing: "Build di questa app").isEmpty, "Settings shows Claude before the click")
        let connect = try #require(app.rig.element("Collega…"), "no «Collega…»")
        app.rig.click(connect.centre)
        await app.settle()
        _ = app.rig.wait(3) { !app.rig.elements(containing: "Build di questa app").isEmpty }
        #expect(raised == 1, "the Settings window was brought up \(raised) times")
        #expect(UserDefaults.standard.string(forKey: SettingsRoute.tabKey) == SettingsTab.claude.rawValue)
        #expect(!app.rig.elements(containing: "Build di questa app").isEmpty, "Settings does not show the Claude tab after the click")
        #expect(app.rig.elements(containing: "Lingua dell'interfaccia").isEmpty, "Settings still shows Generale")
        #expect(app.rig.element("Collega…") != nil)
    }

    /// #119: «Scarica» with an installer that really writes the model file where the configuration expects it: when the
    /// job ends the row leaves the view tree (the whole block, the Claude row being hidden) and the engine summary of the
    /// status line counts the model, without opening the app again.
    @Test func aRealDownloadTakesTheRowAway() async throws {
        let file = modelFile(present: false)
        let (stand, calls) = try installer(writing: file)
        let bundle = try shippedApp()
        let app = try await AppRig(project: nil, services: model(at: file))
        defer { app.close() }
        app.store.bench.defaults.set(true, forKey: FirstSteps.noClaudeKey)
        await Self.host(app, bundle: bundle, installer: stand)
        let before = try #require(app.store.engineSummary)
        #expect(before.modelMissing, "the model is not missing before the download")
        let download = try #require(app.rig.element("Scarica"), "no «Scarica»")
        app.rig.click(download.centre)
        _ = app.rig.wait(10) { app.store.jobs.latest(EnginesModel.jobKind("whisper-model"))?.isRunning == false }
        _ = app.rig.wait(5) { app.store.engineSummary?.modelMissing == false }
        await app.settle()
        #expect((try? String(contentsOf: calls, encoding: .utf8))?.contains("--only whisper-model") == true, "the installer was not run for the model")
        #expect(app.store.jobs.latest(EnginesModel.jobKind("whisper-model"))?.state == .done)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let after = try #require(app.store.engineSummary)
        #expect(!after.modelMissing && after.ready > before.ready, "the engine summary did not follow: \(before) → \(after)")
        #expect(app.rig.element("Scarica") == nil && app.rig.elements(containing: "Modello per trascrivere e fare i sottotitoli").isEmpty,
                "the model row is still there")
        #expect(app.rig.elements(containing: Self.label(nil)).isEmpty, "«Per cominciare» with nothing pending")
    }

    /// #119: the installer fails: the row stays, with the installer's own reason under it, and «Scarica» again.
    @Test(arguments: ["it", "fr"])
    func aFailedDownloadKeepsTheRowWithItsReason(_ language: String) async throws {
        let file = modelFile(present: false)
        let (stand, _) = try installer(writing: file, fails: true)
        let app = try await AppRig(project: nil, services: model(at: file))
        defer { app.close() }
        await Self.host(app, bundle: try shippedApp(), language: language, installer: stand)
        let download = try #require(app.rig.element(Self.word("Scarica", language)), "no «Scarica»")
        app.rig.click(download.centre)
        _ = app.rig.wait(10) { app.store.jobs.latest(EnginesModel.jobKind("whisper-model"))?.isRunning == false }
        await app.settle()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(!app.rig.elements(containing: "the model could not be downloaded (test installer)").isEmpty, "\(language): the reason is not shown")
        let failed = String(format: Self.word("Installazione non riuscita: %@", language), "")
        #expect(!app.rig.elements(containing: failed.trimmingCharacters(in: .whitespaces)).isEmpty, "\(language): no «\(failed)»")
        #expect(app.rig.element(Self.word("Scarica", language)) != nil, "the row lost «Scarica»")
        #expect(app.store.engineSummary?.modelMissing == true)
        try Self.snapshot(app, "n27-home-first-steps-failed-\(language).png")
    }

    /// «Non uso Claude» hides the row (and the whole block, nothing else being pending) and it stays hidden in a new store
    /// on the same defaults (the app opened again).
    @Test func notUsingClaudeHidesTheRowForGood() async throws {
        let bundle = try shippedApp()
        let app = try await AppRig(project: nil, services: model(present: true))
        await Self.host(app, bundle: bundle)
        let no = try #require(app.rig.element("Non uso Claude"), "no «Non uso Claude»")
        app.rig.click(no.centre)
        await app.settle()
        #expect(app.rig.element("Collega Claude per montare parlando") == nil && app.rig.elements(containing: Self.label(nil)).isEmpty,
                "the row is still there")
        #expect(app.store.bench.defaults.bool(forKey: FirstSteps.noClaudeKey))
        let again = try await AppRig(relaunching: app, services: model(present: true))
        await Self.host(again, bundle: bundle)
        #expect(again.rig.element("Collega Claude per montare parlando") == nil, "the row came back in a new store")
        // The model missing in that new store: the block is back with the model row only.
        let third = try await AppRig(relaunching: again, services: model(present: false))
        defer { third.close() }
        await Self.host(third, bundle: bundle)
        #expect(third.rig.element("Scarica") != nil && third.rig.element("Collega Claude per montare parlando") == nil)
    }

    /// An app opened outside Applications (#110): the Claude row reads as Settings › Claude does there.
    @Test func outsideApplicationsTheClaudeRowSaysToMoveFirst() async throws {
        let app = try await AppRig(project: nil, services: model(present: true))
        defer { app.close() }
        await Self.host(app, bundle: try shippedApp(in: "Downloads"))
        let line = loc("Sposta Regista nella cartella Applicazioni prima di collegare Claude: da dove è aperto ora, il collegamento smetterebbe di funzionare.")
        #expect(!app.rig.elements(containing: String(line.prefix(40))).isEmpty, "the move line is not shown")
        #expect(app.rig.element("Collega Claude per montare parlando") == nil)
    }

    /// Claude already connected to another copy of Regista that is still there (a build of the source folder, an older
    /// app): no Claude row — repointing it is Settings › Claude's job. A connection to a file that is gone counts as none.
    @Test func aWorkingConnectionToAnotherCopyIsNotAFirstStep() async throws {
        let bundle = try shippedApp()
        let app = try await AppRig(project: nil, services: model(present: true))
        defer { app.close() }
        await Self.host(app, bundle: bundle, clients: nil)   // the rig's Claude Code runs the test process's server, not this bundle's
        #expect(app.rig.element("Collega…") == nil && app.rig.elements(containing: Self.label(nil)).isEmpty,
                "«Per cominciare» although Claude Code is connected to a working copy")
        let gone = ClaudeClients(desktop: .notConnected, code: .connected(command: "/nowhere/Regista.app/Contents/MacOS/regista-mcp", exists: false))
        #expect(FirstSteps.claudePending(gone, bundle: bundle))
        #expect(FirstSteps.claudePending(Self.noClient, bundle: bundle))
    }

    /// Nothing pending (the model there, Claude Code connected to this app — the rig's client runs the test process's
    /// server): the block is not in the view tree, in Italian and French.
    @Test(arguments: ["it", "fr"])
    func nothingPendingNoBlock(_ language: String) async throws {
        let app = try await AppRig(project: nil, services: model(present: true))
        defer { app.close() }
        await Self.host(app, language: language, clients: nil)
        #expect(app.rig.elements(containing: Self.label(language)).isEmpty, "\(language): «Per cominciare» with nothing pending")
        #expect(app.rig.element(Self.word("Scarica", language)) == nil && app.rig.element(Self.word("Collega…", language)) == nil)
        #expect(!app.rig.elements(containing: Self.word("Reel parlato", language)).isEmpty)
        try Self.snapshot(app, "n26-home-nothing-pending-\(language).png")
    }
}
}
