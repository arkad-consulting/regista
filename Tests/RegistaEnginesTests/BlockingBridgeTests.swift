import AVFoundation
import Foundation
import RegistaCore
import Testing
@testable import RegistaEngines

/// #80: the synchronous bridge to async work runs it on a queue of its own, never on Swift's cooperative pool.
@Test func theBridgeRunsItsWorkOffTheCooperativePool() throws {
    func label() -> String { String(cString: __dispatch_queue_get_label(nil)) }
    let labels = try BlockingBridge.run("regista.test-bridge") { () async throws -> [String] in
        let before = label()
        try await Task.sleep(for: .milliseconds(10))   // resumes on the same executor after a suspension
        return [before, label()]
    }.get()
    #expect(labels == ["regista.test-bridge", "regista.test-bridge"])
    // Errors come back as errors.
    struct Boom: Error {}
    #expect(throws: Boom.self) { try BlockingBridge.run { () async throws -> Int in throw Boom() }.get() }
}

/// With every cooperative thread blocked (as by long synchronous tests running in parallel), an AVFoundation load
/// through the bridge still completes at once; with a plain `Task.detached` it waited for a free pool thread, here
/// until the blockers' 20 s timeout.
@Test func aLoadCompletesWhileTheCooperativePoolIsBlocked() throws {
    let width = ProcessInfo.processInfo.activeProcessorCount
    let release = DispatchSemaphore(value: 0)
    let started = Counter()
    for _ in 0..<width {
        Task.detached {
            started.add()
            _ = release.wait(timeout: .now() + 20)
        }
    }
    // Until the blockers hold the pool (this test holds one thread, other tests may hold more).
    let deadline = Date().addingTimeInterval(1)
    while started.value < width - 1, Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }

    // Measured on a plain thread, which also releases the blockers: nothing here needs the pool.
    let missing = TemporaryFolder.url.appendingPathComponent("regista-bridge-\(UUID().uuidString).mov")
    let measured = DispatchSemaphore(value: 0)
    let elapsed = Counter()
    Thread {
        let t0 = Date()
        let asset = AVURLAsset(url: missing)
        _ = VisionFaceTracker.load { try await asset.loadTracks(withMediaType: .video) }
        _ = try? BlockingBridge.run { () async throws -> Int in await Task.yield(); return 1 }.get()
        elapsed.set(Int(Date().timeIntervalSince(t0) * 1000))
        for _ in 0..<width { release.signal() }
        measured.signal()
    }.start()
    measured.wait()
    #expect(elapsed.value < 10_000, "the bridge waited \(elapsed.value) ms for the blocked pool")
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    func set(_ v: Int) { lock.lock(); n = v; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}
