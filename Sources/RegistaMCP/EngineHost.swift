import Foundation
import RegistaCore

/// Where the MCP server sends commands. The seam between the protocol and the engine: the engine
/// runs inside the server process (`InProcessEngineHost`, headless) or in the running Regista app
/// (`SocketEngineHost` over a local Unix socket, see EngineSocket.swift), so the agent and the user
/// edit the same project live. Both calls are plain JSON-able data.
public protocol EngineHost: AnyObject {
    func descriptors() throws -> [CommandDescriptor]
    func execute(_ command: String, params: JSONValue) throws -> JSONValue
    /// The MCP client's name from `initialize` (shown in the app's agent panel).
    func clientDidInitialize(name: String)
}

extension EngineHost {
    public func clientDidInitialize(name: String) {}
}

/// Owns an Engine in this process. Not thread-safe: the stdio loop is serial.
public final class InProcessEngineHost: EngineHost {
    public let engine: Engine

    public init(engine: Engine = Engine()) {
        self.engine = engine
    }

    public func descriptors() throws -> [CommandDescriptor] { engine.descriptors }

    public func execute(_ command: String, params: JSONValue) throws -> JSONValue {
        try engine.execute(command, params: params)
    }
}
