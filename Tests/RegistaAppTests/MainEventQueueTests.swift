import AppKit
import Carbon
import RigBootstrap
import Testing

// #118: the test process's main event queue is its main thread's. HIToolbox gives the main event queue to the thread
// that first needs one, and AppKit traps the process (SIGTRAP) on the first event the main thread asks for when that
// thread was not the main one: a test on a worker thread that made the application object first, and the mouse rig's
// next click on an AppKit control ended the suite. The test bundle makes the queue on the main thread while it loads
// (Tests/RigBootstrap), before any test runs.

/// The load-time hook ran on the main thread, and a worker thread that makes the application object afterwards (as a
/// cursor rendered off the main thread does, #46) leaves the queue to the main thread.
@Test func theMainEventQueueStaysTheMainThreads() async {
    #expect(rig_main_event_queue_made_on_main() == 1, "the test bundle's load-time hook did not run on the main thread")
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        Thread.detachNewThread {
            _ = NSApplication.shared
            _ = GetCurrentEventQueue()
            done.resume()
        }
    }
    let mains = await MainActor.run { GetMainEventQueue() == GetCurrentEventQueue() }
    #expect(mains, "the main event queue is not the main thread's: the first event the main thread asks for would trap")
}
