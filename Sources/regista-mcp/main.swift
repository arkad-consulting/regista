import Foundation
import RegistaCore
import RegistaEngines
import RegistaMCP

// Regista MCP server over stdio. On the first tool call it attaches to the running Regista app
// (Unix socket, see EngineSocket.swift) so commands edit the project open in the app and the UI follows
// live; when the app is not running the engine runs here, headless. REGISTA_ENGINE=app|local forces one.
//
//   regista-mcp [--media-root <dir>]… [--output-dir <dir>]
//
// media.list / text.read only see the media roots (also REGISTA_MEDIA_ROOT, colon-separated, and the
// default ~/Movies/Regista) and the output directory (also REGISTA_OUTPUT_DIR). An explicit output
// directory is created and becomes the working directory, so relative paths land there.

let library = MediaLibrary.from(arguments: Array(CommandLine.arguments.dropFirst()), environment: ProcessInfo.processInfo.environment)
if let out = library.outputDirectory {
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    FileManager.default.changeCurrentDirectoryPath(out.path)
}
StdioTransport.logToStderr("media roots: \(library.roots.map(\.path).joined(separator: ", "))")
let mode = AutoEngineHost.Mode(rawValue: ProcessInfo.processInfo.environment["REGISTA_ENGINE"] ?? "") ?? .auto
// REGISTA_BUILD_ID makes this server claim another build id: only for trying the app/MCP mismatch warning.
let build = ProcessInfo.processInfo.environment["REGISTA_BUILD_ID"].map { BuildStamp(id: $0) } ?? .current
StdioTransport.logToStderr("build \(build.id)")
let host = AutoEngineHost(mode: mode, log: StdioTransport.logToStderr, build: build) { Engine(services: .live(library: library)) }
let server = MCPServer(host: host, log: StdioTransport.logToStderr)
StdioTransport.serve(server)
