import Foundation

/// Runs an external engine (ffmpeg, whisper-cli, deep-filter, uv…) and collects its output.
/// stdin is /dev/null: under regista-mcp our own stdin is the MCP pipe and must never leak.
/// Inside a `CommandJob` the process is registered with the job: Cancel kills it (and what it started), a cancelled
/// job starts nothing new, and `progress` reads the engine's progress lines as they come.
public enum Subprocess {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data

        public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Runs to completion. Throws if the executable cannot be started, or when the current job was cancelled.
    public static func run(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                           currentDirectory: URL? = nil, progress: CommandJob.LineProgress? = nil) throws -> Result {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw CommandError(.io, "\(executable.lastPathComponent) not found at \(executable.path)")
        }
        let job = CommandJob.current
        if job?.isCancelled == true { throw CommandJob.cancelledError(executable.lastPathComponent) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let out = Pipe(), err = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let pid = process.processIdentifier
        job?.cancellation.register(pid, includingSelf: true)
        defer { job?.cancellation.unregister(pid) }
        // Drain both pipes concurrently: a full pipe would block the child forever.
        let scan: ((String) -> Void)? = job.flatMap { j in progress.map { kind in { j.consume($0, kind) } } }
        // stderr on a thread of its own, not a global-queue worker: an engine can run for minutes, and blocked workers
        // starve everything else that waits on the global queues (Process's own exit notification included).
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            errData = drain(err.fileHandleForReading, scan)
            errDone.signal()
        }
        let outData = drain(out.fileHandleForReading, scan)
        errDone.wait()
        process.waitUntilExit()
        if job?.isCancelled == true { throw CommandJob.cancelledError(executable.lastPathComponent) }
        return Result(status: process.terminationStatus, stdout: outData, stderr: errData)
    }

    /// Reads a pipe to its end; with `scan`, hands over each line (split on \n or \r) as it arrives.
    static func drain(_ handle: FileHandle, _ scan: ((String) -> Void)?) -> Data {
        guard let scan else { return handle.readDataToEndOfFile() }
        var all = Data(), pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            all.append(chunk)
            pending.append(chunk)
            while let i = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
                scan(String(decoding: pending[pending.startIndex..<i], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...i)
            }
        }
        if !pending.isEmpty { scan(String(decoding: pending, as: UTF8.self)) }
        return all
    }

    /// Runs and throws with the tail of stderr when the exit status is not 0.
    @discardableResult
    public static func check(_ executable: URL, _ arguments: [String], environment: [String: String]? = nil,
                             currentDirectory: URL? = nil, progress: CommandJob.LineProgress? = nil) throws -> Result {
        let r = try run(executable, arguments, environment: environment, currentDirectory: currentDirectory, progress: progress)
        guard r.status == 0 else {
            let tail = r.stderrText.split(separator: "\n").suffix(8).joined(separator: "\n")
            throw CommandError(.io, "\(executable.lastPathComponent) exited with \(r.status): \(tail)")
        }
        return r
    }
}
