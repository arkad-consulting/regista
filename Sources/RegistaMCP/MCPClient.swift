import Foundation
import RegistaCore

public struct MCPClientError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Tiny MCP client over stdio: launches a server executable and calls its tools.
/// Used to replay scenarios through the real protocol (scripts/scenario.sh).
public final class MCPClient {
    private let process = Process()
    private let input: FileHandle
    private let reader: LineReader
    private var nextID = 1
    public private(set) var serverInfo: JSONValue = .null
    public private(set) var protocolVersion = ""
    public private(set) var tools: [JSONValue] = []

    /// Starts the server and performs the initialize handshake. Server stderr is inherited.
    public init(server: URL, arguments: [String] = [], environment: [String: String] = [:]) throws {
        let stdin = Pipe(), stdout = Pipe()
        process.executableURL = server
        process.arguments = arguments
        if !environment.isEmpty { process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 } }
        process.standardInput = stdin
        process.standardOutput = stdout
        input = stdin.fileHandleForWriting
        reader = LineReader(stdout.fileHandleForReading)
        try process.run()

        let initResult = try request("initialize", [
            "protocolVersion": .string(MCPServer.supportedProtocolVersions[0]),
            "capabilities": .object([:]),
            "clientInfo": ["name": "regista-scenario", "version": .string(MCPServer.serverVersion)],
        ])
        protocolVersion = initResult["protocolVersion"]?.stringValue ?? ""
        serverInfo = initResult["serverInfo"] ?? .null
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        tools = try request("tools/list", [:])["tools"]?.arrayValue ?? []
    }

    deinit { close() }

    public func close() {
        guard process.isRunning else { return }
        try? input.close()
        process.waitUntilExit()
    }

    /// Calls a tool; an `isError` result throws with the tool's message.
    public func callTool(_ name: String, arguments: JSONValue) throws -> JSONValue {
        let result = try request("tools/call", ["name": .string(name), "arguments": arguments])
        let text = result["content"]?.arrayValue?.compactMap { $0["text"]?.stringValue }.joined(separator: "\n") ?? ""
        if result["isError"] == true { throw MCPClientError(text) }
        if let structured = result["structuredContent"] { return structured }
        return (try? JSONValue.parse(text)) ?? .string(text)
    }

    /// Sends a request and waits for the response with the same id.
    public func request(_ method: String, _ params: JSONValue) throws -> JSONValue {
        let id = nextID
        nextID += 1
        try send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        while let line = reader.next() {
            guard let message = try? JSONValue.parse(line) else { throw MCPClientError("server sent invalid JSON: \(line)") }
            guard message["jsonrpc"] == "2.0" else { throw MCPClientError("not a JSON-RPC 2.0 message: \(line)") }
            guard message["id"] == .number(Double(id)) else { continue }   // server notifications
            if let error = message["error"] { throw MCPClientError("\(method): JSON-RPC error \(error)") }
            guard let result = message["result"] else { throw MCPClientError("\(method): response without result") }
            return result
        }
        throw MCPClientError("server closed the connection during \(method)")
    }

    private func send(_ message: JSONValue) throws {
        let text = message.text()
        precondition(!text.contains("\n"))
        try input.write(contentsOf: Data((text + "\n").utf8))
    }
}
