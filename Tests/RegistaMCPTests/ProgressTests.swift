import Foundation
import Testing
import RegistaCore
@testable import RegistaMCP

// #15: a long tool call with a progress token gets notifications/progress while it runs, so a client that resets its
// request timeout on progress does not give up; without a token nothing extra is sent.

/// A command that takes `seconds` and reports its progress halfway, like an engine inside a CommandJob.
private final class SlowHost: EngineHost {
    let seconds: Double
    init(seconds: Double) { self.seconds = seconds }
    func descriptors() throws -> [CommandDescriptor] { Engine().descriptors }
    func execute(_ command: String, params: JSONValue) throws -> JSONValue {
        Thread.sleep(forTimeInterval: seconds / 2)
        CommandJob.report(0.5)
        Thread.sleep(forTimeInterval: seconds / 2)
        return ["ok": true]
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    func add(_ s: String) { lock.withLock { all.append(s) } }
    var values: [String] { lock.withLock { all } }
}

@Test func longToolCallsSendProgressUntilTheReply() throws {
    let server = MCPServer(host: SlowHost(seconds: 1.2))
    let out = Lines()
    let call = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"project_state","arguments":{},"_meta":{"progressToken":"tok-1"}}}"#
    StdioTransport.respond(server, line: call, interval: 0.25) { out.add($0) }
    let messages = try out.values.map { try JSONValue.parse($0) }
    let notes = messages.filter { $0["method"] == "notifications/progress" }
    #expect(notes.count >= 3)
    #expect(notes.allSatisfy { $0.value(at: "params.progressToken") == "tok-1" })
    let progress = notes.compactMap { $0.value(at: "params.progress")?.doubleValue }
    #expect(progress == progress.sorted() && Set(progress).count == progress.count)   // strictly increasing
    #expect(notes.contains { ($0.value(at: "params.message")?.stringValue ?? "").contains("50 %") })   // the engine's own progress
    #expect(messages.last?["id"] == 7 && messages.last?["result"] != nil)              // the reply comes last
    // Without a token: only the reply.
    let plain = Lines()
    let noToken = #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"project_state","arguments":{}}}"#
    StdioTransport.respond(MCPServer(host: SlowHost(seconds: 0.6)), line: noToken, interval: 0.1) { plain.add($0) }
    #expect(plain.values.count == 1)
}
