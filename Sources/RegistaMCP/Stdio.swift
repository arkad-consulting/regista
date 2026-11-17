import Foundation
import RegistaCore

/// MCP stdio framing: one JSON-RPC message per line, UTF-8, no embedded newlines.
/// stdout carries only protocol messages; logs go to stderr.
public enum StdioTransport {
    /// Seconds between two progress notifications of a long tool call (REGISTA_MCP_PROGRESS_INTERVAL overrides it).
    public static var progressInterval: TimeInterval {
        ProcessInfo.processInfo.environment["REGISTA_MCP_PROGRESS_INTERVAL"].flatMap(Double.init).map { max(0.2, $0) } ?? 10
    }

    /// Serves until stdin closes.
    public static func serve(_ server: MCPServer) {
        let out = FileHandle.standardOutput
        let lock = NSLock()
        while let line = readLine(strippingNewline: true) {
            respond(server, line: line, interval: progressInterval) { text in
                lock.withLock { out.write(Data((text + "\n").utf8)) }
            }
        }
    }

    /// Answers one line. A tools/call whose request carries `_meta.progressToken` gets a `notifications/progress`
    /// every `interval` seconds while the command runs (#15: clients that reset their request timeout on progress —
    /// Claude Desktop's SDK can — do not give up on a long transcription or render). The progress is a counter that
    /// grows with each notification; the message says how long it has been running and, when the engine runs in this
    /// process, how far the command is. Requests are still answered one at a time.
    public static func respond(_ server: MCPServer, line: String, interval: TimeInterval, write: @escaping @Sendable (String) -> Void) {
        let message = try? JSONValue.parse(line.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let token = message.flatMap(progressToken) else {
            if let reply = server.handle(line: line) { write(reply) }
            return
        }
        let state = ProgressState()
        let job = CommandJob(estimates: { fraction, _, estimated in state.set(fraction, estimated: estimated) })
        let started = Date()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "regista.mcp.progress"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler {
            var text = "working for \(Int(Date().timeIntervalSince(started))) s"
            // The number the app's jobs list shows; an estimate (an engine that prints no progress, #13) says so.
            if let p = state.progress { text += " · \(Int((p.0 * 100).rounded())) %" + (p.1 ? " (estimate)" : "") }
            // Sent under the state's lock: once the reply is out, no notification follows it.
            state.tick { n in
                let note: JSONValue = ["jsonrpc": "2.0", "method": "notifications/progress",
                                       "params": ["progressToken": token, "progress": .number(Double(n)), "message": .string(text)]]
                write(note.text())
            }
        }
        timer.resume()
        let reply = CommandJob.$current.withValue(job) { server.handle(line: line) }
        timer.cancel()
        state.finish()
        if let reply { write(reply) }
    }

    /// The progress token of a tools/call request, if the client sent one.
    static func progressToken(_ m: JSONValue) -> JSONValue? {
        guard m["method"]?.stringValue == "tools/call", let id = m["id"], id != .null,
              let token = m.value(at: "params._meta.progressToken"), token != .null else { return nil }
        return token
    }

    final class ProgressState: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var latest: Double?
        private var estimated = false
        private var done = false
        var progress: (Double, Bool)? { lock.withLock { latest.map { ($0, estimated) } } }
        func set(_ f: Double?, estimated e: Bool) { lock.withLock { latest = f; estimated = e } }   // nil: an engine that reports nothing runs now
        /// Calls `send` with the next progress value, unless the reply already went out.
        func tick(_ send: (Int) -> Void) {
            lock.withLock {
                guard !done else { return }
                count += 1
                send(count)
            }
        }
        func finish() { lock.withLock { done = true } }
    }

    public static func logToStderr(_ message: String) {
        FileHandle.standardError.write(Data("[regista-mcp] \(message)\n".utf8))
    }
}

/// Buffered line reader over a pipe.
final class LineReader {
    private let handle: FileHandle
    private var buffer = Data()

    init(_ handle: FileHandle) { self.handle = handle }

    /// Next line without its newline, nil at end of stream.
    func next() -> String? {
        while true {
            if let nl = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return String(decoding: line, as: UTF8.self)
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll() }
                return String(decoding: buffer, as: UTF8.self)
            }
            buffer.append(chunk)
        }
    }
}
