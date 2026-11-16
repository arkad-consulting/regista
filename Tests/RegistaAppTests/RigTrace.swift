import AppKit
import Foundation
import Testing

// #40: which call stops the test runner's loop. Before each await that can run AppKit (and each event or accessibility
// read of the rig), the rig writes down its operation and the test running it: the last ones are kept in memory and the
// very last one in a small file (it survives a crash). A stop that lands in one of the rig's own nested loops is
// written down too, with the operation it interrupted: those are the stops absorbed; one that lands while a test
// awaits reaches the runner's loop and ends the process. When the process exits from inside a test (RigGuard's exit
// check), the last operations are printed with the stack.

enum RigTrace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ring: [String] = []
    nonisolated(unsafe) private static var current = "-"
    nonisolated(unsafe) private static var fd: Int32 = -1
    static let size = 60
    nonisolated(unsafe) private static var allFD: Int32? = ProcessInfo.processInfo.environment["REGISTA_RIG_TRACE"].map { open($0, O_WRONLY | O_CREAT | O_APPEND, 0o644) }
    static let file = FileManager.default.temporaryDirectory.appendingPathComponent("regista-rig-trace-\(ProcessInfo.processInfo.processIdentifier).txt")

    /// Writes down `op` (with the current test) before it runs.
    static func note(_ op: String) {
        let test = Test.current?.name ?? "-"
        let line = String(format: "%.3f", ProcessInfo.processInfo.systemUptime) + " \(op) [\(test)]"
        lock.withLock {
            current = op
            if ring.count == size { ring.removeFirst() }
            ring.append(line)
            if fd < 0 { fd = open(file.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
            if fd >= 0 {
                let data = Array((line + "\n").utf8)
                ftruncate(fd, 0)
                _ = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
            }
            // REGISTA_RIG_TRACE=<file>: every operation, appended (to study a run).
            if let all = allFD, all >= 0 { let data = Array((line + "\n").utf8); _ = data.withUnsafeBytes { write(all, $0.baseAddress, $0.count) } }
        }
    }

    /// A nested loop of the rig's returned because something stopped the run loop: written down with the operation it
    /// interrupted (that stop was absorbed there).
    static func stopped(in loop: String) {
        let op = lock.withLock { current }
        note("STOP absorbed by \(loop) during «\(op)»")
    }

    /// Runs the main run loop in the default mode for at most `seconds`, in a nested loop of the rig's; notes a stop.
    @discardableResult
    static func run(_ loop: String, _ seconds: Double) -> CFRunLoopRunResult {
        let r = CFRunLoopRunInMode(.defaultMode, seconds, false)
        if r == .stopped { stopped(in: loop) }
        return r
    }

    /// The last operations, oldest first.
    static var last: [String] { lock.withLock { ring } }
}

extension NSApplication {
    /// `-[NSApplication stop:]` asked inside a test: written down with its caller (#40), then obeyed.
    @objc func rig_stop(_ sender: Any?) {
        let callers = Thread.callStackSymbols.dropFirst(1).prefix(8).map { line in
            line.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
        }
        RigTrace.note("NSApp.stop from " + callers.joined(separator: " ← "))
        rig_stop(sender)
    }
}
