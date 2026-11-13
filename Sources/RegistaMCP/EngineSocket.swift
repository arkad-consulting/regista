import Darwin
import Foundation
import RegistaCore

// Live attach: the running Regista app owns the Engine and listens on a Unix socket; regista-mcp
// forwards tool calls to it, so the agent and the user edit the same project and the UI updates live.
//
// Framing: one JSON object per line (UTF-8, no embedded newlines), request → reply, in order.
//   {"op": "hello", "client": "claude-code", "build": "…"}      → {"ok": true, "server": "Regista", "build": "…", "commands": [...]}
//   {"op": "execute", "command": "timeline.cut", "params": {…}} → {"ok": true, "result": …} | {"ok": false, "error": "…"}
// The socket file is owner-only (0600) in the user's Application Support folder.

public enum EngineSocket {
    /// `~/Library/Application Support/Regista/engine.sock`, or `$REGISTA_ENGINE_SOCKET`.
    public static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let p = environment["REGISTA_ENGINE_SOCKET"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Regista/engine.sock")
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return addr
    }

    static func socketFD() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket(): \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))   // EPIPE, not a signal
        return fd
    }

    /// A connected socket, or an error when nobody listens.
    static func connect(_ path: String) throws -> Int32 {
        var addr = try address(path)
        let fd = try socketFD()
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else {
            let e = errno
            close(fd)
            throw SocketError("connect \(path): \(String(cString: strerror(e)))")
        }
        return fd
    }

    static func send(_ message: JSONValue, on handle: FileHandle) throws {
        let text = message.text()
        precondition(!text.contains("\n"))
        try handle.write(contentsOf: Data((text + "\n").utf8))
    }
}

public struct SocketError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

// MARK: - Server (the app)

/// Accepts connections on the engine socket; one thread per connection. `handler` runs each command (the
/// app serializes them on its engine queue) and may be called from any thread.
public final class EngineSocketServer: @unchecked Sendable {
    public typealias Handler = (_ command: String, _ params: JSONValue, _ client: String) throws -> JSONValue

    public let path: URL
    let handler: Handler
    /// Called with the client name and its build (nil when it sends none) when a client says hello, and with
    /// (nil, nil) when a connection closes.
    let onClient: (String?, BuildStamp?) -> Void
    /// The app's build, sent in the hello: this binary's (tests pass another).
    let build: BuildStamp
    private var listener: Int32 = -1

    public init(path: URL = EngineSocket.defaultPath(), build: BuildStamp = .current, handler: @escaping Handler,
                onClient: @escaping (String?, BuildStamp?) -> Void = { _, _ in }) {
        self.path = path
        self.build = build
        self.handler = handler
        self.onClient = onClient
    }

    deinit { stop() }

    /// Binds and listens. Fails when another live server owns the socket.
    public func start() throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path.path) {
            if let fd = try? EngineSocket.connect(path.path) {
                close(fd)
                throw SocketError("another Regista is already listening on \(path.path)")
            }
            unlink(path.path)   // stale file from a crash
        }
        var addr = try EngineSocket.address(path.path)
        let fd = try EngineSocket.socketFD()
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path.path, 0o600) == 0, listen(fd, 8) == 0 else {
            let e = errno
            close(fd)
            throw SocketError("cannot listen on \(path.path): \(String(cString: strerror(e)))")
        }
        listener = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "regista.engine-socket"
        thread.start()
    }

    public func stop() {
        guard listener >= 0 else { return }
        close(listener)
        listener = -1
        unlink(path.path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return   // listener closed
            }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [weak self] in self?.serve(client) }
            thread.name = "regista.engine-client"
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let reader = LineReader(handle)
        var client = "client"
        var clientBuild: BuildStamp?
        var greeted = false
        defer { if greeted { onClient(nil, nil) } }
        while let line = reader.next() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let reply: JSONValue
            if let message = try? JSONValue.parse(line) {
                switch message["op"]?.stringValue {
                case "hello":
                    client = message["client"]?.stringValue ?? client
                    clientBuild = BuildStamp(json: message)
                    greeted = true
                    onClient(client, clientBuild)
                    var hello: [String: JSONValue] = ["ok": true, "server": "Regista",
                                                      "commands": .array(Commands.all.map { .string($0.id) }.sorted { $0.stringValue! < $1.stringValue! })]
                    hello.merge(build.json) { _, new in new }
                    reply = .object(hello)
                case "execute":
                    let command = message["command"]?.stringValue ?? ""
                    // A command this app does not know comes from a newer MCP server: say so, not just "Unknown command".
                    guard Commands.all.contains(where: { $0.id == command }) else {
                        reply = ["ok": false, "error": .string(BuildStamp.unknownInApp(command, app: build, mcp: clientBuild))]
                        do { try EngineSocket.send(reply, on: handle) } catch { return }
                        continue
                    }
                    // Socket clients are agents (regista-mcp): human-only commands stay with the app's own UI.
                    if let d = Commands.all.first(where: { $0.id == command })?.descriptor, d.humanOnly {
                        reply = ["ok": false, "error": .string(d.humanOnlyRefusal)]
                        do { try EngineSocket.send(reply, on: handle) } catch { return }
                        continue
                    }
                    do {
                        reply = ["ok": true, "result": try handler(command, message["params"] ?? .object([:]), client)]
                    } catch {
                        reply = ["ok": false, "error": .string("\(error)")]
                    }
                default:
                    reply = ["ok": false, "error": "unknown op"]
                }
            } else {
                reply = ["ok": false, "error": "invalid JSON"]
            }
            do { try EngineSocket.send(reply, on: handle) } catch { return }
        }
    }
}

// MARK: - Client hosts (regista-mcp)

/// Forwards commands to the app over the socket. Throws `SocketError` when the connection is gone.
public final class SocketEngineHost: EngineHost {
    let handle: FileHandle
    let reader: LineReader
    public let path: URL
    /// Command ids the app knows (from the hello).
    public private(set) var appCommands: Set<String> = []
    /// This process's build, and the app's from the hello (nil: an app from before build ids).
    public let build: BuildStamp
    public private(set) var appBuild: BuildStamp?

    public init(path: URL = EngineSocket.defaultPath(), client: String = "regista-mcp", build: BuildStamp = .current) throws {
        self.path = path
        self.build = build
        let fd = try EngineSocket.connect(path.path)
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        reader = LineReader(handle)
        var message: [String: JSONValue] = ["op": "hello", "client": .string(client)]
        message.merge(build.json) { _, new in new }
        let hello = try roundTrip(.object(message))
        appCommands = Set(hello["commands"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        appBuild = BuildStamp(json: hello)
    }

    public func descriptors() throws -> [CommandDescriptor] {
        Commands.all.map { $0.descriptor }.sorted { $0.id < $1.id }
    }

    public func execute(_ command: String, params: JSONValue) throws -> JSONValue {
        // An app older than this server answers a new command with a bare "Unknown command": name the cause first.
        if !appCommands.isEmpty, !appCommands.contains(command), Commands.all.contains(where: { $0.id == command }) {
            throw SocketError(BuildStamp.unknownInApp(command, app: appBuild, mcp: build))
        }
        let reply = try roundTrip(["op": "execute", "command": .string(command), "params": params])
        guard reply["ok"] == true else { throw SocketError(reply["error"]?.stringValue ?? "the app refused \(command)") }
        let result = reply["result"] ?? .null
        guard command == "engines.status", case .object(var o) = result else { return result }
        o["appBuild"] = .string(appBuild?.id ?? "from before build ids")
        o["mcpBuild"] = .string(build.id)
        if let w = BuildStamp.warning(app: appBuild, mcp: build) { o["buildWarning"] = .string(w) }
        return .object(o)
    }

    private func roundTrip(_ message: JSONValue) throws -> JSONValue {
        do { try EngineSocket.send(message, on: handle) } catch { throw Disconnected() }
        guard let line = reader.next() else { throw Disconnected() }
        guard let reply = try? JSONValue.parse(line) else { throw SocketError("the app sent invalid JSON") }
        return reply
    }

    public struct Disconnected: Error, CustomStringConvertible {
        public var description: String { "the Regista app closed the connection" }
    }
}

/// What regista-mcp uses: on the first tool call it attaches to the running app if its socket answers,
/// otherwise it runs a headless engine in this process; the choice then sticks for the session.
/// `REGISTA_ENGINE=app` requires the app, `REGISTA_ENGINE=local` never attaches.
public final class AutoEngineHost: EngineHost {
    public enum Mode: String { case auto, app, local }

    let socketPath: URL
    let mode: Mode
    let makeLocal: () -> Engine
    let log: (String) -> Void
    let build: BuildStamp
    private var remote: SocketEngineHost?
    private var local: InProcessEngineHost?
    private var client = "regista-mcp"

    public init(socketPath: URL = EngineSocket.defaultPath(), mode: Mode = .auto, log: @escaping (String) -> Void = { _ in },
                build: BuildStamp = .current, makeLocal: @escaping () -> Engine) {
        self.socketPath = socketPath
        self.build = build
        self.mode = mode
        self.makeLocal = makeLocal
        self.log = log
    }

    /// "app" once attached, "local" once headless, nil before the first call.
    public var attachedTo: String? { remote != nil ? "app" : local != nil ? "local" : nil }

    public func clientDidInitialize(name: String) { client = name }

    public func descriptors() throws -> [CommandDescriptor] {
        Commands.all.map { $0.descriptor }.sorted { $0.id < $1.id }
    }

    public func execute(_ command: String, params: JSONValue) throws -> JSONValue {
        let target = try resolve()
        do {
            return try target.execute(command, params: params)
        } catch is SocketEngineHost.Disconnected {
            remote = nil
            throw SocketError("\(command): the Regista app closed (or crashed) — reopen it and call again; the project state is in the app's last save")
        }
    }

    private func resolve() throws -> EngineHost {
        if let remote { return remote }
        if let local { return local }
        if mode != .local {
            do {
                let r = try SocketEngineHost(path: socketPath, client: client, build: build)
                remote = r
                log("attached to the Regista app at \(socketPath.path)")
                if let w = BuildStamp.warning(app: r.appBuild, mcp: build) { log(w) }
                return r
            } catch {
                if mode == .app { throw SocketError("REGISTA_ENGINE=app but the Regista app is not running (\(error))") }
            }
        }
        let l = InProcessEngineHost(engine: makeLocal())
        local = l
        log("Regista app not running: headless engine in this process")
        return l
    }
}
