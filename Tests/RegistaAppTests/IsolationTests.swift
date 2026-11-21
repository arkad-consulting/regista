import AppKit
import AVFoundation
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The rig's stand-ins (#35, RigIsolation.swift): each one is proven harmless here before the click audit clicks the
// controls behind it, and the app's own services are what they were.

/// A person's app is unchanged: the workbench's live factory gives the support folder, the profiles, the generation
/// providers and the recorder hardware it gave before the seam (today's constants).
@MainActor
@Test func theLiveFactoryGivesTheAppsOwnServices() throws {
    let live = Workbench.liveServices()
    #expect(live.generationState.standardizedFileURL == OwnerSide.support.standardizedFileURL)
    #expect(live.profiles.directory.standardizedFileURL == OwnerSide.support.appendingPathComponent("profiles").standardizedFileURL)
    #expect(Set(live.generators.keys) == ["comfyui", "higgsfield", "voxcpm"])
    #expect(live.generators["higgsfield"] is HiggsfieldProvider && live.generators["comfyui"] is ComfyUIProvider && live.generators["voxcpm"] is VoxCPMProvider)
    #expect(live.speech != nil && live.segmenter != nil && live.screenSynth != nil)
    // A store made the app's way gets them (its approvals are read from the support folder, never written).
    let defaults = TestDefaults.make("live")
    defer { TestDefaults.end(defaults) }
    let store = EditorStore(defaults: defaults, seedFolders: [])
    #expect(store.generationState.standardizedFileURL == OwnerSide.support.standardizedFileURL)
    #expect(store.engine.context.services.generators["higgsfield"] is HiggsfieldProvider)
    #expect(Recorder(defaults: defaults).hardware is MacCapture)
    // The Claude clients' files keep their places under the home folder they are given.
    #expect(ClaudeClients.desktopConfig == ClaudeClients.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"))
    #expect(ClaudeClients.codeConfig == ClaudeClients.home.appendingPathComponent(".claude.json"))
    #expect(EnvironmentValues().pasteboard == NSPasteboard.general)
}

/// The rig's services: scratch folders, stand-in providers, no ComfyUI server, heavy engines not found; the voice is
/// the real VoxCPM provider on the rig's environment, whose uv is the stub (RigVoice, #36).
@MainActor
@Test func theRigServicesStayInScratchFolders() throws {
    _ = rigOutside
    let s = RigServices.factory()()
    let tmp = TemporaryFolder.url.path
    #expect(s.generationState.path.hasPrefix(tmp) && s.profiles.directory.path.hasPrefix(tmp) && s.config.cacheDirectory.hasPrefix(tmp))
    #expect(s.rules.directory.path.hasPrefix(tmp) && RuleBook.defaultDirectory.path.hasPrefix(tmp))
    #expect(Set(s.generators.keys) == ["comfyui", "higgsfield", "voxcpm"])
    #expect(s.generators["comfyui"] is RigGenerator && s.generators["higgsfield"] is RigGenerator && s.generators["voxcpm"] is VoxCPMProvider)
    #expect(s.comfyServer() == nil && s.comfyPlaces.isEmpty && s.comfyLocation.start == nil)
    #expect(URL(string: s.config.comfyServer)?.port == 9, "the rig's ComfyUI address: nothing listens there")
    for path in [s.config.higgsfield ?? "", s.config.blender, s.config.node, s.config.whisperXProject] {
        #expect(path.hasPrefix(tmp) && !FileManager.default.fileExists(atPath: path))
    }
    // The voice's environment: in the scratch folder, its uv the rig's stub (a script there, never the real uv).
    for path in [s.config.uv, s.config.voxcpmProject, s.config.voxcpmScript, s.config.voxcpmModel] { #expect(path.hasPrefix(tmp)) }
    let uv = try String(contentsOfFile: s.config.uv, encoding: .utf8)
    #expect(uv.contains("The test rig's uv") && FileManager.default.isExecutableFile(atPath: s.config.uv))
    #expect(s.generators["voxcpm"]?.unavailableReason(.voice) == nil)
}

/// Every seam the rig writes through resolves under the scratch root of the test process (the hard part of the proof of
/// the click audits, also checked around them).
@MainActor
@Test func theRigWritesOnlyUnderItsScratchRoot() {
    #expect(RigScratch.outside().isEmpty, "\(RigScratch.outside())")
    #expect(RigScratch.seams().count == 16)   // with the rule sheets (#31): the rig's and the support folder's
}

/// A difference in the owner-side listing fails the proof only when no other Regista (the owner's app, an agent's
/// server or engine) was at work.
@Test func anOwnerSideDifferenceFailsOnlyWithoutTheOwnersApp() {
    #expect(OwnerSideVerdict.decide(changes: [], ownerAtWork: false) == .same)
    #expect(OwnerSideVerdict.decide(changes: [], ownerAtWork: true) == .same)
    #expect(OwnerSideVerdict.decide(changes: ["/a 1 2"], ownerAtWork: false) == .failure(["/a 1 2"]))
    #expect(OwnerSideVerdict.decide(changes: ["/a 1 2"], ownerAtWork: true) == .ownersAppMayHaveWritten(["/a 1 2"]))
    // Another session's Regista at work (an agent driving it with the app closed): a server that used CPU time or
    // started or ended during the audits; an idle one is not at work.
    #expect(OtherRegista.worked(before: [10: 1.0, 11: 4.0, 12: 2.0], after: [10: 1.01, 11: 9.5, 13: 0.2])
        == ["process 11 used 5.50 s of CPU", "process 12 ended", "process 13 started"])
    #expect(OtherRegista.worked(before: [:], after: [:]).isEmpty)
    // The reading itself: never this process, only Regista's own executables, each with a time.
    #expect(OtherRegista.cpu().allSatisfy { $0.key != getpid() && $0.value >= 0 })
}

/// A generation in the rig: the free one fails with the stand-in's message, the paid one is priced without its CLI and,
/// once approved, starts nothing either; the budget and the approvals are the scratch ones.
@MainActor
@Test func aRigGenerationStartsNothing() throws {
    _ = rigOutside
    RigGuard.install()
    let s = RigServices.factory()()
    let e = Engine(services: s)
    let projects = rigTempDir("gen")
    _ = try e.execute("project.new", params: ["name": "gen", "directory": .string(projects.path)])
    let started = RigProcesses.started.count
    // The processes of this generation: its providers' programs and stubs live in the services' folder, its job files
    // in the project's; a process another test starts meanwhile names neither (#60: the record is the whole process's).
    let mine = [s.generationState.deletingLastPathComponent().path, projects.path]
    func ours(_ lines: ArraySlice<String>) -> [String] { lines.filter { l in mine.contains { l.contains($0) } } }
    #expect {
        try e.execute("generate.run", params: ["provider": "comfyui", "kind": "image", "prompt": "a red chair"])
    } throws: { "\($0)".contains("a stand-in of the test rig") || "\($0)".contains("ComfyUI is missing") }   // its runner is not found: gated first
    let estimate = try e.execute("generate.estimate", params: ["provider": "higgsfield", "kind": "image", "prompt": "a red chair"])
    #expect(estimate["credits"]?.doubleValue == RigGenerator.estimate, "\(estimate.text())")
    let id = try #require(estimate["estimateId"]?.stringValue)
    let token = try #require(try e.execute("generate.approve", params: ["estimateId": .string(id)])["approval"]?.stringValue)
    #expect {
        try e.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": "a red chair", "approval": .string(token)])
    } throws: { "\($0)".contains("a stand-in of the test rig") }
    #expect(ours(RigProcesses.started.dropFirst(started)).isEmpty, "a rig generation started a process: \(RigProcesses.started.dropFirst(started))")
    #expect(FileManager.default.fileExists(atPath: s.generationState.path))

    // The record cannot cut those folders off (#60). It keeps the executable whole and each of the first four arguments up
    // to 200 characters: both folders are shorter, so a recorded argument that starts with one keeps it whole…
    for folder in mine {
        #expect(folder.count < RigProcesses.argumentLimit, "\(folder) (\(folder.count) characters) can be cut off a recorded argument")
    }
    // …and a generation's process is its job's wrapper, `/bin/sh -c <script> <program> <args…>` (GenerationJobDir.launch),
    // whose program — in the services' folder for every provider of the rig — is the third argument, within the four
    // kept. A launch of that very shape, with a program of the services' folder that only exits, is recorded with it.
    let probe = URL(fileURLWithPath: mine[0]).appendingPathComponent("not-installed/probe-\(String(repeating: "x", count: 40))")
    try FileManager.default.createDirectory(at: probe.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 0\n".write(to: probe, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probe.path)
    let before = RigProcesses.started.count
    try GenerationJobDir(projects.appendingPathComponent("probe-job")).launch(GenerationProcess(probe, ["--out", projects.path]), wait: true)
    let recorded = ours(RigProcesses.started.dropFirst(before))
    #expect(recorded.count == 1 && recorded.first?.contains(mine[0]) == true, "the probe's launch was recorded as \(RigProcesses.started.dropFirst(before))")
    #expect(RigProcesses.line("/bin/sh", ["-c", "s", probe.path, "a", "b", projects.path]).contains(mine[0]))
}

/// The installer is the rig's stub: it writes down what it was asked and installs nothing.
@Test func theRigInstallerInstallsNothing() throws {
    _ = rigOutside
    let installer = try #require(EngineInstaller.locate(resources: nil))
    #expect(installer.script.path.hasPrefix(rigOutside.installer.path))
    let before = rigOutside.installs.count
    try installer.install("whisperx")
    #expect(rigOutside.installs.dropFirst(before).contains("--only whisperx"))
    #expect(EngineCatalog.enginesDirectory.standardizedFileURL == rigOutside.enginesFolder.standardizedFileURL)
    #expect(EngineConfig.defaultFile.standardizedFileURL == rigOutside.enginesFile.standardizedFileURL)
    #expect(ClaudeClients.home.standardizedFileURL == rigOutside.claudeHome.standardizedFileURL)
    #expect(ClaudeClients.claudeCLI()?.hasPrefix(rigOutside.claudeHome.path) == true)
}

/// A test's own defaults suite leaves no file behind (#137, TestDefaults): while it is open its file is in the test
/// process's scratch folder of suites, never in the Preferences folder of the person running the tests; once ended, its
/// keys and its file are gone.
@Test func aTestsOwnDefaultsSuiteLeavesNoFile() async throws {
    let fm = FileManager.default
    let preferences = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Preferences")
    let d = TestDefaults.make("isolation")
    let domain = try #require(TestDefaults.domain(of: d))
    let name = URL(fileURLWithPath: domain).lastPathComponent
    #expect(name.range(of: #"^regista-isolation-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#, options: .regularExpression) != nil, "\(name)")
    let file = TestDefaults.file(of: domain), inPreferences = preferences.appendingPathComponent("\(name).plist")
    #expect(file.deletingLastPathComponent().standardizedFileURL == TestDefaults.folder.standardizedFileURL)
    d.set("value", forKey: "key")
    d.synchronize()
    // The preferences daemon writes the new domain to disk: in the scratch folder.
    let end = Date().addingTimeInterval(35)
    while !fm.fileExists(atPath: file.path), Date() < end { try await Task.sleep(for: .milliseconds(100)) }
    #expect(fm.fileExists(atPath: file.path))
    #expect(!fm.fileExists(atPath: inPreferences.path))
    TestDefaults.end(d)
    #expect(!fm.fileExists(atPath: file.path) && !fm.fileExists(atPath: inPreferences.path))
    #expect(TestDefaults.domain(of: d) == nil)
    #expect(UserDefaults(suiteName: domain)?.object(forKey: "key") == nil)
    TestDefaults.end(d)   // a second end does nothing
    #expect(!fm.fileExists(atPath: inPreferences.path))
}

/// The capture stand-in: allowed without asking, a take is a state that opens no device and writes no file, the screen
/// and speech recognition are refused.
@MainActor
@Test func theCaptureStandInOpensNothing() async throws {
    _ = rigFolder
    let capture = RigCapture()
    let defaults = TestDefaults.make("capture")
    defer { TestDefaults.end(defaults) }
    let recorder = Recorder(defaults: defaults, hardware: capture)
    await recorder.prepare()
    #expect(recorder.isReady && recorder.cameraPermission == .granted && recorder.microphonePermission == .granted)
    #expect(capture.log.contains("openDevices") && !capture.log.contains { $0.hasPrefix("requestAccess") })
    let recordings = (try? FileManager.default.contentsOfDirectory(atPath: Paths.recordings.path)) ?? []
    recorder.start()
    if recorder.blockReason == nil {
        #expect(recorder.isRecording && capture.log.contains { $0.hasPrefix("startMovie") })
        recorder.stop()
        for _ in 0..<50 where recorder.isRecording { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!recorder.isRecording && recorder.errorMessage != nil)
    } else {
        #expect(!recorder.isRecording && recorder.errorMessage == recorder.blockReason, "no device on this Mac: the take is refused")
    }
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: Paths.recordings.path)) ?? []) == recordings, "a take wrote a file")
    recorder.sources.screen = true
    await recorder.refreshScreen(userClicked: true)
    #expect(recorder.screenPermission != .granted && capture.log.contains("requestScreen"))
}

extension MouseSuites {
/// The net and the redirections of RigGuard, and the rig's tabs (serialized with the click audits: a refusal made here
/// must not land inside their proof).
@Suite(.serialized) @MainActor struct RigNetTests {
    /// A window a test shows is never seen by the person at the Mac: a titled floating panel in the middle of the
    /// screen (what the teleprompter is) ends up off every display, transparent and deaf to the mouse, and stays so
    /// when it is shown again.
    @Test func aWindowShownByATestIsNeverSeen() throws {
        RigGuard.install()
        let screen = try #require(NSScreen.screens.first).frame
        let panel = NSPanel(contentRect: NSRect(x: screen.midX - 200, y: screen.midY - 100, width: 400, height: 200),
                            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        defer { panel.orderOut(nil) }
        for _ in 0..<2 {
            panel.orderFrontRegardless()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            #expect(panel.alphaValue == 0 && panel.ignoresMouseEvents)
            #expect(!NSScreen.screens.contains { $0.frame.intersects(panel.frame) }, "\(panel.frame)")
            panel.orderOut(nil)
        }
        panel.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(panel.alphaValue == 0 && !NSScreen.screens.contains { $0.frame.intersects(panel.frame) }, "\(panel.frame)")
    }

    /// A process off the allow-list does not start and is recorded; the tools the suite needs on scratch files do.
    @Test func theNetRefusesProcessesOffTheList() throws {
        RigGuard.install()
        let refused = RigProcesses.refused.count
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Calculator"]
        #expect(throws: (any Error).self) { try open.run() }
        #expect(RigProcesses.refused.dropFirst(refused).contains { $0.hasPrefix("/usr/bin/open") })
        // Regista's own "reopen" (a shell that waits, then opens the app): refused.
        #expect(RigProcesses.refusal("/bin/sh", ["-c", "while kill -0 1 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", "/Applications/Regista.app"]) != nil)
        #expect(RigProcesses.refusal("/opt/homebrew/bin/uv", ["run"]) != nil)
        #expect(RigProcesses.refusal("/usr/bin/python3", ["-I", "/opt/elsewhere/claude_desktop.py", "set"]) != nil)
        // The generation wrapper on a scratch fake, a repository script, a stub of the rig: allowed.
        let tmp = TemporaryFolder.url.appendingPathComponent("x/fake").path
        #expect(RigProcesses.refusal("/bin/sh", ["-c", #""$0" "$@" > stdout.txt 2> stderr.txt; echo $? > exit.tmp && exec mv exit.tmp exit"#, tmp, "a"]) == nil)
        #expect(RigProcesses.refusal("/bin/bash", [RigOutside.repository.appendingPathComponent("scripts/install.sh").path, "--only", "x"]) == nil)
        #expect(RigProcesses.refusal("/bin/bash", [rigOutside.installer.appendingPathComponent("scripts/install.sh").path]) == nil)
        let ffmpeg = EngineConfig.expand(EngineConfig.loadOrDefault().config.ffmpeg)
        if FileManager.default.isExecutableFile(atPath: ffmpeg) {
            _ = try Subprocess.check(URL(fileURLWithPath: ffmpeg), ["-version"])
        }
        #expect(RigProcesses.refused.count == refused + 1)
    }

    /// The Trash and the general pasteboard of the person running the tests are not written.
    @Test func theTrashAndTheClipboardStayUntouched() throws {
        RigGuard.install()
        let file = rigTempDir("trash").appendingPathComponent("gone.txt")
        try Data("x".utf8).write(to: file)
        var out: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &out)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect((out as URL?)?.path.hasPrefix(RigTrash.folder.path) == true && RigTrash.taken.contains("gone.txt"))
        // NSWorkspace's recycle (#142) lands there too, and its completion says where.
        let recycled = rigTempDir("trash").appendingPathComponent("recycled.txt")
        try Data("x".utf8).write(to: recycled)
        nonisolated(unsafe) var places: [URL: URL] = [:]
        NSWorkspace.shared.recycle([recycled]) { moved, _ in places = moved }
        #expect(!FileManager.default.fileExists(atPath: recycled.path) && RigTrash.taken.contains("recycled.txt"))
        #expect(places[recycled]?.path.hasPrefix(RigTrash.folder.path) == true, "\(places)")
        let general = NSPasteboard.general.changeCount, writes = RigPasteboard.generalWrites.count
        NSPasteboard.general.clearContents()
        #expect(!NSPasteboard.general.setString("rig", forType: .string))
        #expect(NSPasteboard.general.changeCount == general && RigPasteboard.generalWrites.count == writes + 2)
        rigPasteboard.clearContents()
        #expect(rigPasteboard.setString("rig", forType: .string) && rigPasteboard.string(forType: .string) == "rig")
    }

    /// A tab opened by a click (the strip's "+") gets the rig's services, the same scratch folders as the first tab.
    @Test func aTabOpenedByAClickUsesTheRigServices() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector))
        await app.settle()
        let bench = app.store.bench
        #expect(app.rig.click("Nuova scheda"))
        await app.settle()
        let tab = try #require(bench.tabs.first { $0 !== app.store }, "+ opened no tab")
        let s = tab.engine.context.services
        #expect(s.generators["comfyui"] is RigGenerator && s.generators["higgsfield"] is RigGenerator)
        #expect(s.config.uv == app.store.engine.context.services.config.uv, "the tab's voice is not the rig's environment")
        #expect(tab.generationState == app.store.generationState)
        #expect(s.profiles.directory == app.store.engine.context.services.profiles.directory)
        #expect(s.generationState.path.hasPrefix(TemporaryFolder.url.path))
    }
}
}
