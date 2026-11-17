import AppKit
import Combine
import Foundation
import RegistaCore
import Testing
@testable import Regista

// #19: the face's side for «Affiancati» and «Verticale», and «Pausa» for a take with no screen. Real clicks on the real
// Registra panel with the capture stand-in (no camera, microphone or screen is opened; the teleprompter's window is
// kept offscreen by the rig).

/// Seconds of the recorded file at `wall` seconds after Record, with the pauses taken out.
@Test func theTeleprompterMarkersSkipTheTakesPauses() {
    let pauses = [(start: 2.0, end: 5.0), (start: 8.0, end: 9.5)]
    #expect(ScriptFollower.recorded(1, pauses: pauses) == 1)
    #expect(ScriptFollower.recorded(3, pauses: pauses) == 2)        // inside the first pause: where it began
    #expect(ScriptFollower.recorded(6, pauses: pauses) == 3)
    #expect(ScriptFollower.recorded(10, pauses: pauses) == 5.5)
    #expect(ScriptFollower.recorded(4, pauses: []) == 4)
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct RecordSideMouseTests {
    @Test(arguments: ["it", "fr"])
    func theFacesSideChangesTheLayoutOnceAndThePreview(_ language: String) async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.capture.screen = true
        app.capture.displays = Array(DisplayInfo.samples.prefix(1))
        let table = MouseRig.table(language)
        func w(_ key: String) -> String { table.localizedString(forKey: key, value: key, table: nil) }
        app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: CGSize(width: 1440, height: 900), language: language)
        await app.settle()
        func control(_ name: String) -> RigElement? {
            app.rig.elements().first { $0.isControl && $0.visible && ($0.label == name || $0.title == name || $0.label.hasPrefix(name + ",")
                || $0.label.hasPrefix(name + " (") || $0.label.components(separatedBy: ", ").contains(name)) }
        }
        func until(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        /// The face's box in the live preview (its drawn geometry).
        var face: CGRect? { app.rig.elements().first { $0.role == "AXUnknown" && $0.label == w("Volto nel video") && $0.visible }?.frame }
        func inView(_ e: RigElement?) -> Bool { e.map { $0.visible && $0.clip.insetBy(dx: -1, dy: -1).contains($0.frame) } ?? false }
        /// A control of the column, scrolled into view when it is below the fold.
        func reach(_ name: String) async throws -> RigElement {
            // The left column (its preset tiles are at x < 330): down, then back up, until the control is in view.
            let column = CGPoint(x: 170, y: app.rig.size.height / 2)
            for dy: CGFloat in [6, -6] {
                for _ in 0..<40 where !inView(control(name)) {
                    if !app.rig.scrollContent(at: column, by: dy) { break }
                    await app.settle()
                }
            }
            return try #require(control(name).flatMap { inView($0) ? $0 : nil }, "\(language): «\(name)» is not reachable")
        }
        let tag = language
        var changes = 0
        let watch = app.recorder.$sources.map(\.layout).removeDuplicates().dropFirst().sink { _ in changes += 1 }
        defer { watch.cancel() }

        app.rig.click(try #require(control(w("Schermo + volto")), "\(tag): no «Schermo + volto»").centre)
        await app.settle()
        #expect(await until { app.recorder.sources.screen && app.recorder.sources.camera })
        let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }

        // «Affiancati»: the face on the right by default, «Volto a sinistra» moves it left — one change, the preview with it.
        app.rig.click(try await reach(w("Affiancati")).centre)
        await app.settle()
        #expect(app.recorder.sources.layout.kind == .split, "\(tag): \(app.recorder.sources.layout)")
        let right = try #require(face, "\(tag): no face in the preview: \(app.rig.elements().filter { $0.name.contains(w("Volto")) }.map { "\($0.role) \($0.name) \($0.visible) \($0.frame)" })")
        let toLeft = try await reach(w("Volto a sinistra"))
        #expect(try await reach(w("a destra")).selected, "\(tag): «a destra» is not the default")
        if let dir { try? app.snapshot(to: dir.appendingPathComponent("record-side-split-\(language)-1440.png")) }
        changes = 0
        app.rig.click(toLeft.centre)
        await app.settle()
        #expect(app.recorder.sources.layout.side == "left" && changes == 1, "\(tag): \(app.recorder.sources.layout) after \(changes) changes")
        let left = try #require(face)
        #expect(left.midX < right.midX - 50, "\(tag): the preview's face did not move left (\(right) → \(left))")
        #expect(control(w("Volto a sinistra")) != nil, "\(tag): the row went away")

        // «Verticale»: below by default, «Volto sopra» moves it up.
        app.rig.click(try await reach(w("Verticale")).centre)
        await app.settle()
        #expect(app.recorder.sources.layout.kind == .stack, "\(tag): \(app.recorder.sources.layout)")
        let below = try #require(face)
        let up = try await reach(w("Volto sopra"))
        #expect(try await reach(w("sotto")).selected, "\(tag): «sotto» is not the default")
        changes = 0
        app.rig.click(up.centre)
        await app.settle()
        #expect(app.recorder.sources.layout.side == "top" && changes == 1, "\(tag): \(app.recorder.sources.layout) after \(changes) changes")
        let above = try #require(face)
        #expect(above.midY < below.midY - 30, "\(tag): the preview's face did not move up (\(below) → \(above))")
        if let dir { try? app.snapshot(to: dir.appendingPathComponent("record-side-stack-\(language)-1440.png")) }

        // At the smallest window the row fits and «Registra» stays in view; the column says it continues when it does.
        app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: CGSize(width: 1024, height: 640), language: language)
        await app.settle()
        let record = control(w("Avvia / Ferma registrazione"))
        #expect(inView(record), "\(tag): «Registra» is not in view at 1024×640")
        let row = control(w("Volto sopra"))
        let cue = app.rig.elements().contains { $0.name == w("Altro sotto") && $0.visible }
        #expect(inView(row) || cue, "\(tag): the side row is below the fold and the column does not say it continues")
        if let dir { try? app.snapshot(to: dir.appendingPathComponent("record-side-stack-\(language)-1024.png")) }
        app.rig.click(try await reach(w("Affiancati")).centre)
        await app.settle()
        if let dir { try? app.snapshot(to: dir.appendingPathComponent("record-side-split-\(language)-1024.png")) }
    }
}
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct CameraPauseMouseTests {
    @Test(arguments: [1, 3])
    func aCameraTakePausesWithoutAGapInItsFile(_ pauses: Int) async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let prompter = TeleprompterController.shared
        let mode = prompter.mode
        prompter.mode = .speed   // scrolls on its own: no speech recognition in the rig
        defer {
            prompter.mode = mode
            // Closed inside loops of ours (the end of its closing animation stops the running run loop, #40).
            if prompter.isVisible { prompter.hide() }
            app.rig?.hold(0.8)
        }
        let take = rigTempDir("pause").appendingPathComponent("take.mov")
        try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: take)
        app.capture.take = take
        await app.recorder.prepare()   // what the live Registra screen does when it opens
        app.hostEditor(Navigation(activity: .record, rightTab: .inspector), size: CGSize(width: 1440, height: 900))
        await app.settle()
        func control(_ name: String) -> RigElement? {
            app.rig.elements().first { $0.isControl && $0.visible && ($0.label == name || $0.title == name || $0.label.hasPrefix(name + ",")
                || $0.label.hasPrefix(name + " (") || $0.label.components(separatedBy: ", ").contains(name)) }
        }
        func until(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        app.rig.click(try #require(control("Solo volto"), "no «Solo volto»").centre)
        await app.settle()
        app.recorder.sources.prompter = true
        #expect(!app.recorder.sources.screen && app.recorder.sources.camera)
        #expect(await until { app.recorder.isReady && control("Avvia / Ferma registrazione")?.enabled == true }, "Record is not ready: \(app.recorder.isReady) \(app.recorder.blockReason ?? "") \(app.rig.elements().filter { $0.isControl && $0.visible }.map(\.label).suffix(12))")

        app.rig.click(try #require(control("Avvia / Ferma registrazione")).centre)
        #expect(await until { app.recorder.isRecording }, "Record did not start: \(app.recorder.errorMessage ?? "")")
        let started = ProcessInfo.processInfo.systemUptime
        var paused = 0.0
        for k in 0..<pauses {
            await app.idle(0.6)
            let button = try #require(control("Pausa / Riprendi"), "no «Pausa» on a take without the screen")
            #expect(button.enabled, "«Pausa» is disabled on a camera take")
            app.rig.click(button.centre)
            let from = ProcessInfo.processInfo.systemUptime
            #expect(await until { app.recorder.isPaused }, "pause \(k + 1) did not pause")
            #expect(!prompter.isPlaying, "the teleprompter goes on during pause \(k + 1)")
            let clock = app.recorder.elapsed
            await app.idle(0.8)
            #expect(abs(app.recorder.elapsed - clock) < 0.01, "the timer ran during pause \(k + 1): \(clock) → \(app.recorder.elapsed)")
            app.rig.click(try #require(control("Pausa / Riprendi"), "no «Riprendi»").centre)
            #expect(await until { !app.recorder.isPaused }, "resume \(k + 1) did not resume")
            paused += ProcessInfo.processInfo.systemUptime - from
            #expect(prompter.isPlaying, "the teleprompter did not go on after pause \(k + 1)")
        }
        await app.idle(0.6)
        app.rig.click(try #require(control("Avvia / Ferma registrazione")).centre)
        let wall = ProcessInfo.processInfo.systemUptime - started
        #expect(await until(10) { !app.recorder.isRecording }, "Stop did not end the take")
        #expect(app.capture.log.filter { $0 == "pauseMovie" }.count == pauses && app.capture.log.filter { $0 == "resumeMovie" }.count == pauses,
                "\(app.capture.log)")
        // The file: the recorded time without the pauses, picture and sound as long as each other, no gap in either.
        let file = try #require(app.capture.lastMovie)
        #expect(file.pauses == pauses)
        // As long as the take's clock said when it stopped (it ticks every 0.25 s), the pauses left out.
        // (A stretch between two pauses is whole frames: up to a frame shorter each.)
        let frames: Double = Double(pauses + 1) / 30 + 0.05
        #expect(file.duration >= app.recorder.elapsed - frames && file.duration - app.recorder.elapsed < 0.4,
                "the file lasts \(file.duration) s, the clock said \(app.recorder.elapsed) s (\(wall) s with the pauses)")
        #expect(abs(file.paused - paused) < 0.4, "the file left out \(file.paused) s of \(paused) s paused")
        let audioEnd = (file.audio.last ?? 0) + 1024.0 / 48000
        // Each stream may lose part of a sample at each edge of each pause: within one sample of each per pause.
        let slack: Double = Double(pauses + 1) * (1.0 / 30 + 1024.0 / 48000) + 1e-6
        #expect(abs(audioEnd - file.duration) <= slack, "sound \(audioEnd) s, picture \(file.duration) s")
        for (name, stream, step) in [("picture", file.video, 1.0 / 30), ("sound", file.audio, 1024.0 / 48000)] {
            let jumps = zip(stream, stream.dropFirst()).map { $1 - $0 }.filter { abs($0 - step) > 1e-6 }
            #expect(jumps.isEmpty, "\(name): \(jumps.count) jumps in the timestamps")
        }
        #expect(app.recorder.errorMessage == nil, "\(app.recorder.errorMessage ?? "")")
    }
}
}
