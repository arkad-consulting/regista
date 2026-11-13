import Foundation

/// Runs async work (AVFoundation's async loaders, the live speech recognizer) for a synchronous engine call and blocks
/// until it ends.
///
/// The work runs on a task executor of its own (a private serial dispatch queue, SE-0417), never on Swift's cooperative
/// pool. A synchronous caller may itself hold a cooperative thread (a synchronous Swift Testing test, a detached task):
/// with a plain `Task.detached` it blocks that thread while waiting for work that needs a free one, and once every pool
/// thread is held that way the work never runs. That is how long render tests stalled each other until the 60 s render
/// watchdog in the full test suite (#80). A private serial queue always gets a thread of its own (GCD over-commits for
/// it), so the work runs however busy the pool is.
enum BlockingBridge {
    /// The value `body` returns, or its error.
    static func run<T>(_ label: String = "regista.async-bridge", _ body: @escaping () async throws -> T) -> Result<T, Error> {
        let done = DispatchSemaphore(value: 0)
        let box = Box<Result<T, Error>>()
        let executor = QueueExecutor(label: label)
        Task.detached(executorPreference: executor) {
            do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
            done.signal()
        }
        done.wait()
        return box.value!
    }

    /// A task executor that runs every job on one private serial queue.
    final class QueueExecutor: TaskExecutor, @unchecked Sendable {
        let queue: DispatchQueue

        init(label: String) { queue = DispatchQueue(label: label) }

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }

    final class Box<T>: @unchecked Sendable { var value: T? }
}
