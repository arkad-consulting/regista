import AppKit
import Foundation
import Testing
@testable import RegistaEngines

// The app object belongs to the main thread (#46): made first on a worker thread (a cursor rendered there), AppKit's
// main event queue is that thread's and the first event the main thread asks for traps the process.

@Test func aWorkerThreadGetsTheAppObjectFromTheMainThread() async {
    let took: TimeInterval = await withCheckedContinuation { done in
        Thread.detachNewThread {
            let start = Date()
            CursorSprites.ensureApplication(wait: 60)
            done.resume(returning: Date().timeIntervalSince(start))
        }
    }
    #expect(took < 55, "the app object came from the wait running out, not from the main thread")
    #expect(await MainActor.run { NSApp != nil })
}
