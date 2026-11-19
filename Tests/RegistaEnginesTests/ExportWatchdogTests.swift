import AVFoundation
import Foundation
import Testing
@testable import RegistaCore
@testable import RegistaEngines

/// #71: a frame that never arrives (the compositor blocked at 0.5 s, so the reader's copyNextSampleBuffer never
/// returns, as in the stuck regista-mcp) stops the export with a readable error once nothing moved for the stall
/// timeout, instead of waiting forever; the partial file is removed.
@Test func exportStopsWhenNoFrameArrives() throws {
    // Not shorter: in the full parallel suite the first frames alone can take more than 2 s, and the export then stopped
    // at frame 0, before the stuck frame.
    let stall: TimeInterval = 6
    let voice = try syntheticVoice(seconds: 2)
    defer { try? FileManager.default.removeItem(at: voice) }
    var p = voiceOnlyProject(voice, seconds: 2)
    p.name = "stall-\(UUID().uuidString)"
    let name = p.name
    let release = DispatchSemaphore(value: 0)
    let held = HeldSince()
    TimelineCompositor.testHook.set(name) { t in
        if t >= MediaTime(seconds: 0.5) { held.mark(); release.wait() }
    }
    defer {
        TimelineCompositor.testHook.set(name, nil)
        for _ in 0..<64 { release.signal() }
    }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("regista-stall-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    var message = ""
    do {
        _ = try AVRenderer(stallTimeout: stall, startTimeout: stall).export(RenderJob(project: p, preset: .vertical), audio: voice, to: out, bitrate: 2_000_000)
        Issue.record("the export should have stopped")
    } catch let e as CommandError {
        message = e.message
    }
    // The frame is stuck before the first second, so the export starts again once (#116) and is stuck again: stopped
    // within twice the stall timeout plus the bounded cancels (5 s each) of the frames that never came, whatever the load.
    let elapsed = Date().timeIntervalSince(try #require(held.since, "the export stopped before the stuck frame: \(message)"))
    #expect(elapsed < 2 * stall + 15, "stopped \(elapsed) s after the stuck frame")
    #expect(message.contains("nothing moved for \(Int(stall)) s while reading frames") && message.contains("of 60"), "\(message)")
    #expect(message.contains("The export had already started again once"), "\(message)")
    #expect(!FileManager.default.fileExists(atPath: out.path))

    // frame.render reads through the same compositor: bounded too, and a frame before the stuck one still renders.
    let r = AVRenderer(stallTimeout: stall)
    #expect(try r.renderImages(RenderJob(project: p, preset: .vertical), at: [MediaTime(seconds: 0.2)]).count == 1)
    #expect(throws: CommandError.self) { try r.renderImages(RenderJob(project: p, preset: .vertical), at: [MediaTime(seconds: 1)]) }
}

/// #116: a frame stuck once before the first second of output (the stall seen once in the commit hook, at frame 17 of a
/// 4-second synthetic clip) costs the start timeout, not a minute: the first attempt is stopped, the export starts again
/// once from a new reader and writer, and the file is whole. The result says it started again, and at which frame.
@Test func anExportStuckOnceAtTheStartStartsAgainAndFinishes() throws {
    // The start timeout as long as the stall test's timeout: the frames before the stuck one arrive within it under load.
    let start: TimeInterval = 6
    let voice = try syntheticVoice(seconds: 2)
    defer { try? FileManager.default.removeItem(at: voice) }
    var p = voiceOnlyProject(voice, seconds: 2)
    p.name = "restart-\(UUID().uuidString)"
    let name = p.name
    let release = DispatchSemaphore(value: 0)
    let held = HeldSince()
    let once = NSLock()
    nonisolated(unsafe) var stuck = false
    TimelineCompositor.testHook.set(name) { t in
        guard t >= MediaTime(seconds: 0.5) else { return }
        once.lock()
        let first = !stuck
        stuck = true
        once.unlock()
        if first { held.mark(); release.wait() }   // only the first attempt's frame at 0.5 s never comes
    }
    defer {
        TimelineCompositor.testHook.set(name, nil)
        for _ in 0..<64 { release.signal() }
    }
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("regista-restart-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    let began = Date()
    let report = try AVRenderer(stallTimeout: 60, startTimeout: start)
        .export(RenderJob(project: p, preset: .vertical), audio: voice, to: out, bitrate: 2_000_000)
    let elapsed = Date().timeIntervalSince(began)
    #expect(held.since != nil, "the frame at 0.5 s was never asked for")
    #expect(elapsed < start + 30, "the export took \(elapsed) s")
    #expect(report.frames == 60)
    let frame = try #require(report.restartedAtFrame, "the export did not start again")
    #expect(frame < 30, "restarted at frame \(frame), after the first second")
    #expect(FileManager.default.fileExists(atPath: out.path))
}

final class HeldSince: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Date?
    func mark() { lock.lock(); if first == nil { first = Date() }; lock.unlock() }
    var since: Date? { lock.lock(); defer { lock.unlock() }; return first }
}

/// #19: a reader is never cancelled while a read is in flight (copyNextSampleBuffer on a reader cancelled under it, or
/// woken up in one, crashed the test runner with signal 11). The cancel waits for the read and runs when it returns;
/// later reads answer nil without touching the reader.
@Test func aReaderIsCancelledOnlyBetweenReads() throws {
    let voice = try syntheticVoice(seconds: 2)
    defer { try? FileManager.default.removeItem(at: voice) }
    var p = voiceOnlyProject(voice, seconds: 2)
    p.name = "gate-\(UUID().uuidString)"
    let name = p.name
    let release = DispatchSemaphore(value: 0)
    let held = HeldSince()
    TimelineCompositor.testHook.set(name) { t in
        if t >= MediaTime(seconds: 0.5) { held.mark(); release.wait() }
    }
    defer {
        TimelineCompositor.testHook.set(name, nil)
        for _ in 0..<64 { release.signal() }
    }
    let r = AVRenderer()
    let job = RenderJob(project: p, preset: .vertical)
    let built = try r.build(job)

    // No read in flight: cancelled at once, and reading after it is harmless.
    let idle = try r.reader(built, range: CMTimeRange(start: .zero, end: AVRenderer.cm(job.duration)))
    #expect(idle.next() != nil)
    idle.cancel()
    #expect(idle.reader.status == .cancelled)
    #expect(idle.next() == nil)

    // A read stuck in the compositor: the cancel returns at once but leaves the reader alone until the read returns.
    let gate = try r.reader(built, range: CMTimeRange(start: .zero, end: AVRenderer.cm(job.duration)))
    let drained = DispatchSemaphore(value: 0)
    Thread {
        while gate.next() != nil {}
        drained.signal()
    }.start()
    for _ in 0..<600 where held.since == nil { Thread.sleep(forTimeInterval: 0.05) }   // up to 30 s on a busy Mac
    try #require(held.since != nil)
    gate.cancel()
    #expect(gate.isWaitingForARead)
    #expect(gate.reader.status == .reading)
    for _ in 0..<64 { release.signal() }
    #expect(drained.wait(timeout: .now() + 30) == .success)
    #expect(gate.reader.status == .cancelled)
    #expect(gate.next() == nil)
}
