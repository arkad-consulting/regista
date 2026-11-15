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
    let defaults = UserDefaults(suiteName: "regista-live-\(UUID().uuidString)")!
    let store = EditorStore(defaults: defaults, seedFolders: [])
    #expect(store.generationState.standardizedFileURL == OwnerSide.support.standardizedFileURL)
    #expect(store.engine.context.services.generators["higgsfield"] is HiggsfieldProvider)
    #expect(Recorder(defaults: defaults).hardware is MacCapture)
    // The Claude clients' files keep their places under the home folder they are given.
    #expect(ClaudeClients.desktopConfig == ClaudeClients.home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json"))
    #expect(ClaudeClients.codeConfig == ClaudeClients.home.appendingPathComponent(".claude.json"))
    #expect(EnvironmentValues().pasteboard == NSPasteboard.general)
}

/// The rig's services: scratch folders, stand-in providers, no ComfyUI server, heavy engines not found.
@MainActor
@Test func theRigServicesStayInScratchFolders() throws {
    _ = rigOutside
    let s = RigServices.factory()()
    let tmp = FileManager.default.temporaryDirectory.path
    #expect(s.generationState.path.hasPrefix(tmp) && s.profiles.directory.path.hasPrefix(tmp) && s.config.cacheDirectory.hasPrefix(tmp))
    #expect(Set(s.generators.keys) == ["comfyui", "higgsfield", "voxcpm"] && s.generators.values.allSatisfy { $0 is RigGenerator })
    #expect(s.comfyServer() == nil)
    for path in [s.config.uv, s.config.comfyGen, s.config.higgsfield ?? "", s.config.voxcpmProject, s.config.blender, s.config.node, s.config.whisperXProject] {
        #expect(path.hasPrefix(tmp) && !FileManager.default.fileExists(atPath: path))
    }
}

/// A generation in the rig: the free one fails with the stand-in's message, the paid one is priced without its CLI and,
/// once approved, starts nothing either; the budget and the approvals are the scratch ones.
@MainActor
@Test func aRigGenerationStartsNothing() throws {
    _ = rigOutside
    RigGuard.install()
    let s = RigServices.factory()()
    let e = Engine(services: s)
    _ = try e.execute("project.new", params: ["name": "gen", "directory": .string(rigTempDir("gen").path)])
    let started = RigProcesses.started.count
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
    #expect(RigProcesses.started.count == started, "a rig generation started a process: \(RigProcesses.started.dropFirst(started))")
    #expect(FileManager.default.fileExists(atPath: s.generationState.path))
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

/// The capture stand-in: allowed without asking, a take is a state that opens no device and writes no file, the screen
/// and speech recognition are refused.
@MainActor
@Test func theCaptureStandInOpensNothing() async throws {
    _ = rigFolder
    let capture = RigCapture()
    let recorder = Recorder(defaults: UserDefaults(suiteName: "regista-capture-\(UUID().uuidString)")!, hardware: capture)
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
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("x/fake").path
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
        #expect(s.generators.values.allSatisfy { $0 is RigGenerator } && !s.generators.isEmpty)
        #expect(tab.generationState == app.store.generationState)
        #expect(s.profiles.directory == app.store.engine.context.services.profiles.directory)
        #expect(s.generationState.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }
}
}
