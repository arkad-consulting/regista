import AppKit
import Foundation
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The hang log (#161): a stand-in sampler and clock, a scratch folder; nothing samples this process and nothing is
// written to the person's logs folder.

/// Writes what `sample` would, and counts.
final class StandInSampler: HangSampler, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [URL] = []
    var calls: [URL] { lock.withLock { _calls } }

    func sample(pid: Int32, seconds: Int, into file: URL) {
        lock.withLock { _calls.append(file) }
        try? "Sampling process \(pid) for \(seconds) seconds (stand-in)\n".write(to: file, atomically: true, encoding: .utf8)
    }
}

/// A clock the test moves by hand.
final class HandClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = 1000.0
    var now: Double { lock.withLock { t } }
    func advance(_ s: Double) { lock.withLock { t += s } }
}

/// The watched queue of a test: holds each block until the test lets it run (a main queue that does not answer).
final class HeldQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var blocks: [@Sendable () -> Void] = []
    func add(_ b: @escaping @Sendable () -> Void) { lock.withLock { blocks.append(b) } }
    func release() {
        let all = lock.withLock { let b = blocks; blocks = []; return b }
        all.forEach { $0() }
    }
}

private func watchdog(_ tag: String) -> (HangWatchdog, StandInSampler, HandClock, HeldQueue) {
    let folder = TemporaryFolder.url.appendingPathComponent("hang-\(tag)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let sampler = StandInSampler(), clock = HandClock(), held = HeldQueue()
    let w = HangWatchdog(folder: folder, sampler: sampler, clock: { clock.now },
                         now: { Date(timeIntervalSinceReferenceDate: 800_000_000 + clock.now) }, ping: { held.add($0) })
    return (w, sampler, clock, held)
}

/// The main queue blocked for `seconds`: the watchdog looks every half second meanwhile, then it answers.
private func block(_ w: HangWatchdog, _ clock: HandClock, _ held: HeldQueue, for seconds: Double) {
    w.lookNow()   // the question
    var waited = 0.0
    while waited < seconds - 1e-9 {
        let step = min(0.5, seconds - waited)
        clock.advance(step)
        waited += step
        w.lookNow()
    }
    held.release()
    w.drain()
}

@Test func aMainQueueBlockedForTwoAndAHalfSecondsWritesOneReportWithItsLength() throws {
    let (w, sampler, clock, held) = watchdog("long")
    block(w, clock, held, for: 2.5)
    let reports = HangLog.reports(in: w.folder)
    #expect(reports.count == 1 && sampler.calls.count == 1, "\(reports)")
    let text = try String(contentsOf: try #require(reports.first), encoding: .utf8)
    #expect(text.contains("Sampling process") && text.contains("did not answer for 2.5 s"), "\(text)")
    #expect(reports.first?.lastPathComponent.hasPrefix("hang-") == true)
}

@Test func aBlockOfOneAndAHalfSecondsWritesNone() {
    let (w, sampler, clock, held) = watchdog("short")
    block(w, clock, held, for: 1.5)
    #expect(HangLog.reports(in: w.folder).isEmpty && sampler.calls.isEmpty)
}

@Test func oneSampleAMinuteAndTwentyReportsKept() {
    let (w, sampler, clock, held) = watchdog("cap")
    // Two hangs 30 s apart: one sample.
    block(w, clock, held, for: 2.5)
    clock.advance(30)
    block(w, clock, held, for: 2.5)
    #expect(sampler.calls.count == 1, "a second sample within a minute")
    // 25 more, a minute apart: the newest 20 stay.
    for _ in 0..<25 {
        clock.advance(61)
        block(w, clock, held, for: 2.5)
    }
    let reports = HangLog.reports(in: w.folder)
    #expect(sampler.calls.count == 26 && reports.count == 20, "\(sampler.calls.count) samples, \(reports.count) reports")
    #expect(reports.first == sampler.calls.last, "the newest report was removed")
    #expect(!reports.contains(sampler.calls[0]), "the oldest report is still there")
}

/// The real timer and a real queue the test blocks (not the main queue: the other tests beside this one keep it busy).
@Test func theRealTimerCatchesARealBlockAndCostsNothingWhileIdle() async throws {
    let folder = TemporaryFolder.url.appendingPathComponent("hang-real-\(UUID().uuidString.prefix(8))", isDirectory: true)
    let sampler = StandInSampler()
    let watched = DispatchQueue(label: "watched")
    let w = HangWatchdog(folder: folder, sampler: sampler, ping: { watched.async(execute: $0) })
    w.start()
    defer { w.stop() }
    // Idle: a look every half second, nothing more (a timer, no busy loop).
    let before = w.lookCount
    try await Task.sleep(for: .seconds(2))
    let idle = w.lookCount - before
    #expect((3...5).contains(idle), "\(idle) looks in 2 s")
    #expect(sampler.calls.isEmpty)
    // A 1.5 s block: nothing.
    watched.async { Thread.sleep(forTimeInterval: 1.5) }
    try await Task.sleep(for: .seconds(2.5))
    #expect(sampler.calls.isEmpty, "a 1.5 s block was sampled")
    // A 3 s block (asked within its first half second, the question waits at least 2.5 s): one report, with its length.
    watched.async { Thread.sleep(forTimeInterval: 3) }
    try await Task.sleep(for: .seconds(4.5))
    w.drain()
    let reports = HangLog.reports(in: folder)
    #expect(reports.count == 1, "\(reports)")
    let text = try String(contentsOf: try #require(reports.first), encoding: .utf8)
    #expect(text.contains("did not answer for"), "\(text)")
}

extension MouseSuites {
/// Impostazioni › Generale › «Mostra i rapporti di blocco» (#161), on the rig's scratch logs folder.
@Suite(.serialized) @MainActor struct HangReportsSettingsTests {
    @Test func theLineShowsTheNewestReportInTheFinderAndIsDisabledWithoutOne() async throws {
        let saved = UserDefaults.standard.object(forKey: SettingsRoute.tabKey)
        defer { UserDefaults.standard.set(saved, forKey: SettingsRoute.tabKey) }
        UserDefaults.standard.set(SettingsTab.general.rawValue, forKey: SettingsRoute.tabKey)
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let folder = HangLog.folder
        #expect(folder.path.hasPrefix(rigOutside.root.path), "the reports folder is not the rig's scratch one: \(folder.path)")
        try? FileManager.default.removeItem(at: folder)
        let title = loc("Mostra i rapporti di blocco")
        func host() async throws -> RigElement {
            app.rig?.close()
            app.host(SettingsView().environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)), size: SettingsView.size)
            await app.settle()
            var line = try #require(app.rig.element(title), "no «\(title)» in Generale")
            // Below the fold: scroll the form to it.
            for _ in 0..<12 where !line.visible {
                app.rig.scroll(at: CGPoint(x: SettingsView.size.width / 2, y: SettingsView.size.height / 2), dy: -10)
                await app.settle()
                line = try #require(app.rig.element(title))
            }
            return line
        }
        // No report: disabled, a click shows nothing.
        let events = RigGuard.events.count
        let none = try await host()
        #expect(!none.enabled, "the line is enabled without a report")
        app.rig.click(none.centre)
        await app.settle()
        #expect(!RigGuard.events.dropFirst(events).contains { $0.kind == .finder })
        // Two reports: the newest is shown in the Finder (recorded by the rig, nothing opens), once.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["hang-2026-11-24-10.00.00.txt", "hang-2026-11-24-11.30.00.txt"] {
            try "stand-in report\n".write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let line = try await host()
        #expect(line.enabled && line.visible, "\(line)")
        let before = RigGuard.events.count
        app.rig.click(line.centre)
        await app.settle()
        let shown = RigGuard.events.dropFirst(before).filter { $0.kind == .finder }
        #expect(shown.map(\.detail) == ["hang-2026-11-24-11.30.00.txt"], "\(RigGuard.events.dropFirst(before))")
        #expect(app.rig.element(title) != nil, "the line went away after its click")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            for lang in ["it", "fr"] {
                app.rig?.close()
                app.host(SettingsView().environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)), size: SettingsView.size, language: lang)
                await app.settle()
                // To the end of the form, where the line is.
                for _ in 0..<6 { _ = app.rig.scrollContent(at: CGPoint(x: SettingsView.size.width / 2, y: SettingsView.size.height / 2), by: 20) }
                await app.settle()
                try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("settings-hang-reports-\(lang).png"))
            }
        }
        try? FileManager.default.removeItem(at: folder)
    }
}
}
