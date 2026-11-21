import Foundation
import Testing
import RegistaCore
@testable import RegistaMCP

private func server() -> MCPServer { MCPServer(host: InProcessEngineHost(engine: Engine())) }

private func request(_ method: String, _ params: JSONValue = [:], id: JSONValue = 1) -> JSONValue {
    ["jsonrpc": "2.0", "id": id, "method": .string(method), "params": params]
}

@Test func initializeNegotiatesTheProtocol() throws {
    let s = server()
    let r = try #require(s.handle(request("initialize", ["protocolVersion": "2025-06-18", "capabilities": [:],
                                                         "clientInfo": ["name": "test", "version": "1"]])))
    #expect(r["id"] == 1)
    #expect(r.value(at: "result.protocolVersion") == "2025-06-18")
    #expect(r.value(at: "result.serverInfo.name") == "regista")
    #expect(r.value(at: "result.capabilities.tools") != nil)
    let unknown = try #require(s.handle(request("initialize", ["protocolVersion": "1999-01-01"])))
    #expect(unknown.value(at: "result.protocolVersion") == .string(MCPServer.supportedProtocolVersions[0]))
}

@Test func notificationsGetNoReplyAndPingWorks() throws {
    let s = server()
    #expect(s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
    let pong = try #require(s.handle(request("ping", id: "abc")))
    #expect(pong["id"] == "abc")
    #expect(pong["result"] == .object([:]))
}

@Test func toolsListExposesEveryCommandWithASchema() throws {
    let r = try #require(server().handle(request("tools/list")))
    let tools = try #require(r.value(at: "result.tools")?.arrayValue)
    #expect(tools.count == Engine().descriptors.filter { !$0.humanOnly }.count)
    #expect(!tools.contains { $0["name"] == "generate_approve" })   // human-only: never a tool
    let names = tools.compactMap { $0["name"]?.stringValue }
    #expect(names.contains("timeline_cut"))
    #expect(names.allSatisfy { $0.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil })
    let cut = try #require(tools.first { $0["name"] == "timeline_cut" })
    #expect(cut.value(at: "inputSchema.type") == "object")
    #expect(cut.value(at: "inputSchema.required") == ["at"])
    #expect(cut.value(at: "inputSchema.properties.at.type") == "number")
    #expect(tools.first { $0["name"] == "project_state" }?.value(at: "annotations.readOnlyHint") == true)
    // A download only adds files outside the project: neither read-only nor destructive. An edit may change what is there.
    let fetch = try #require(tools.first { $0["name"] == "generate_fetch" })
    #expect(fetch.value(at: "annotations.readOnlyHint") == false && fetch.value(at: "annotations.destructiveHint") == false)
    #expect(cut.value(at: "annotations.readOnlyHint") == false && cut.value(at: "annotations.destructiveHint") == nil)
}

@Test func toolsCallRunsCommandsAndReportsErrorsAsResults() throws {
    let s = server()
    let ok = try #require(s.handle(request("tools/call", ["name": "project_new", "arguments": ["name": "mcp"]])))
    #expect(ok.value(at: "result.isError") == false)
    #expect(ok.value(at: "result.structuredContent.name") == "mcp")
    let text = try #require(ok.value(at: "result.content.0.text")?.stringValue)
    #expect(try JSONValue.parse(text)["name"] == "mcp")

    let bad = try #require(s.handle(request("tools/call", ["name": "timeline_cut", "arguments": ["at": "x"]])))
    #expect(bad.value(at: "result.isError") == true)
    #expect(bad.value(at: "result.content.0.text")?.stringValue?.contains("parameter 'at'") == true)

    let unknown = try #require(s.handle(request("tools/call", ["name": "nope"])))
    #expect(unknown.value(at: "error.code") == -32602)

    // Approving a paid generation is the human's: refused even when called by name.
    for name in ["generate_approve", "generate.approve"] {
        let human = try #require(s.handle(request("tools/call", ["name": .string(name), "arguments": ["estimateId": "e-1"]])))
        #expect(human.value(at: "result.isError") == true)
        #expect(human.value(at: "result.content.0.text")?.stringValue?.contains("reserved to the person at the Mac") == true)
    }
}

@Test func protocolErrors() throws {
    let s = server()
    #expect(try JSONValue.parse(s.handle(line: "{not json")!).value(at: "error.code") == -32700)
    #expect(s.handle(line: "   ") == nil)
    #expect(s.handle(request("resources/list"))?.value(at: "error.code") == -32601)
    #expect(s.handle(["id": 3, "method": "ping"])?.value(at: "error.code") == -32600)
}

@Test func initializeAnnouncesPromptsAndInstructions() throws {
    let r = try #require(server().handle(request("initialize", ["protocolVersion": "2025-11-25"])))
    #expect(r.value(at: "result.capabilities.prompts") != nil)
    let instructions = try #require(r.value(at: "result.instructions")?.stringValue)
    #expect(instructions.contains("recipe_get") && instructions.contains("media_list") && instructions.contains("frame_contactSheet"))
}

@Test func promptsListAndGetServeTheTalkingHeadRecipe() throws {
    let s = server()
    let list = try #require(s.handle(request("prompts/list")))
    let prompts = try #require(list.value(at: "result.prompts")?.arrayValue)
    let reel = try #require(prompts.first { $0["name"] == "talking-head-reel" })
    #expect(reel["description"]?.stringValue?.isEmpty == false)
    #expect(reel["arguments"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["footage", "script", "brand"])

    let get = try #require(s.handle(request("prompts/get", ["name": "talking-head-reel", "arguments": ["brand": "WeSites"]])))
    #expect(get.value(at: "result.messages.0.role") == "user")
    #expect(get.value(at: "result.messages.0.content.type") == "text")
    let text = try #require(get.value(at: "result.messages.0.content.text")?.stringValue)
    #expect(text.hasPrefix("Inputs:\n- brand: WeSites"))
    for step in ["takes_list", "edit_autoCut", "audio_clean", "edit_punchIns", "captions_generate", "talking-head-v1",
                 "frame_contactSheet", "export_render", "export_srt", "export_mlt", "−15 LUFS", "Claude Code"] {
        #expect(text.contains(step), "recipe lacks \(step)")
    }
    // The same text is a tool for clients that do not show prompts to the model, followed by the editing rules (#31).
    let tool = try #require(s.handle(request("tools/call", ["name": "recipe_get", "arguments": ["name": "talking-head-reel", "language": "en"]])))
    let toolText = try #require(tool.value(at: "result.structuredContent.text")?.stringValue)
    #expect(toolText.hasPrefix(Recipes.talkingHeadReel.text() + "\n\n# Editing rules (talking-head-reel)"))
    #expect(toolText.contains("# For every video") && toolText.contains("# Talking-head reel") && toolText.contains("logo-pause (0.3 s)"))

    #expect(s.handle(request("prompts/get", ["name": "nope"]))?.value(at: "error.code") == -32602)
    #expect(s.handle(request("prompts/get"))?.value(at: "error.code") == -32602)
}

/// Returns a fixed result for every call, to test how results are encoded.
private final class FixedHost: EngineHost {
    let result: JSONValue
    init(_ result: JSONValue) { self.result = result }
    func descriptors() throws -> [CommandDescriptor] { Engine().descriptors.filter { $0.id == "frame.render" } }
    func execute(_ command: String, params: JSONValue) throws -> JSONValue { result }
}

/// A 1×1 PNG.
private let pngBytes = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

@Test func toolResultsInlineTheirImagesAsImageContent() throws {
    let dir = TemporaryFolder.url.appendingPathComponent("regista-mcp-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let png = dir.appendingPathComponent("f.png"), jpg = dir.appendingPathComponent("f.jpg")
    try pngBytes.write(to: png)
    try pngBytes.write(to: jpg)   // mimeType comes from the entry, not the bytes
    let result: JSONValue = ["frames": 2, "images": [["path": .string(png.path), "mimeType": "image/png"],
                                                     ["path": .string(jpg.path), "mimeType": "image/jpeg"],
                                                     ["path": .string(dir.appendingPathComponent("gone.jpg").path)]]]
    let s = MCPServer(host: FixedHost(result))
    let r = try #require(s.handle(request("tools/call", ["name": "frame_render", "arguments": [:]])))
    let content = try #require(r.value(at: "result.content")?.arrayValue)
    #expect(content.count == 3)   // the text, then the two images that exist
    #expect(content[0]["type"] == "text")
    #expect(try JSONValue.parse(content[0]["text"]!.stringValue!)["frames"] == 2)
    #expect(content[1]["type"] == "image" && content[1]["mimeType"] == "image/png")
    #expect(content[2]["mimeType"] == "image/jpeg")
    let b64 = try #require(content[1]["data"]?.stringValue)
    let decoded = try #require(Data(base64Encoded: b64))
    #expect(decoded == pngBytes && decoded.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    #expect(r.value(at: "result.isError") == false)

    // Over the limit: only the first maxImages are sent.
    let many = JSONValue.array((0..<12).map { _ in ["path": .string(png.path), "mimeType": "image/png"] })
    let r2 = try #require(MCPServer(host: FixedHost(["images": many])).handle(request("tools/call", ["name": "frame_render"])))
    #expect(r2.value(at: "result.content")?.arrayValue?.count == 1 + MCPServer.maxImages)
}

// MARK: - Live attach (engine socket)

/// A short socket path (sun_path is 104 bytes): /tmp, not the long per-user temporary directory.
private func socketPath() -> URL { URL(fileURLWithPath: "/tmp/regista-test-\(UUID().uuidString.prefix(8)).sock") }

@Test func socketHostForwardsCommandsToTheAppEngine() throws {
    let path = socketPath()
    let appEngine = Engine()
    let lock = NSLock()
    var seen: [String] = []
    var clients: [String?] = []
    let server = EngineSocketServer(path: path, handler: { command, params, client in
        lock.lock(); defer { lock.unlock() }
        seen.append("\(client):\(command)")
        return try appEngine.execute(command, params: params)
    }, onClient: { name, _ in lock.lock(); clients.append(name); lock.unlock() })
    try server.start()
    defer { server.stop() }
    #expect(throws: (any Error).self) { try EngineSocketServer(path: path, handler: { _, _, _ in .null }).start() }   // one owner

    let auto = AutoEngineHost(socketPath: path) { Engine() }
    let mcp = MCPServer(host: auto)
    _ = mcp.handle(request("initialize", ["protocolVersion": "2025-11-25", "clientInfo": ["name": "claude-code", "version": "1"]]))
    let ok = try #require(mcp.handle(request("tools/call", ["name": "project_new", "arguments": ["name": "live"]])))
    #expect(ok.value(at: "result.isError") == false)
    #expect(auto.attachedTo == "app")
    #expect(appEngine.project?.name == "live")   // the app's engine changed, not one in the MCP process
    let bad = try #require(mcp.handle(request("tools/call", ["name": "timeline_cut", "arguments": ["at": 1]])))
    #expect(bad.value(at: "result.isError") == true)
    let headless = try #require(mcp.handle(request("tools/call", ["name": "ui_screenshot", "arguments": [:]])))
    #expect(headless.value(at: "result.content.0.text")?.stringValue?.contains("needs the Regista app") == true)
    // A socket client (an agent) cannot reach a human-only command even without the MCP layer.
    let direct = try SocketEngineHost(path: path, client: "agent")
    do {
        _ = try direct.execute("generate.approve", params: ["estimateId": "e-1"])
        Issue.record("generate.approve went through the socket")
    } catch {
        #expect("\(error)".contains("reserved to the person at the Mac"))
    }
    lock.lock()
    #expect(!seen.contains { $0.hasSuffix("generate.approve") })
    #expect(seen.first == "claude-code:project.new")
    #expect(clients.first == "claude-code")
    lock.unlock()
}

@Test func autoHostFallsBackToAHeadlessEngine() throws {
    let auto = AutoEngineHost(socketPath: socketPath()) { Engine() }
    _ = try auto.execute("project.new", params: ["name": "solo"])
    #expect(auto.attachedTo == "local")
    #expect(throws: (any Error).self) { try AutoEngineHost(socketPath: socketPath(), mode: .app) { Engine() }.execute("project.state", params: [:]) }
}

@Test func enginesStatusThroughTheAppComparesBuilds() throws {
    let path = socketPath()
    let appEngine = Engine()
    var clientBuilds: [BuildStamp?] = []
    let lock = NSLock()
    // Stamped builds of our own, not BuildStamp.current: that is "dev" until scripts/build-stamp.sh has run in this
    // checkout (a fresh clone or worktree, #73), and an unstamped app is always the side to rebuild.
    let app = BuildStamp(id: "1234567", commitTime: 2)
    let server = EngineSocketServer(path: path, build: app, handler: { command, params, _ in try appEngine.execute(command, params: params) },
                                    onClient: { name, build in if name != nil { lock.lock(); clientBuilds.append(build); lock.unlock() } })
    try server.start()
    defer { server.stop() }

    let same = try SocketEngineHost(path: path, build: app)
    let r = try same.execute("engines.status", params: [:])
    #expect(r["appBuild"]?.stringValue == app.id)
    #expect(r["mcpBuild"]?.stringValue == app.id)
    #expect(r["buildWarning"] == nil)

    let other = BuildStamp(id: "0000000", commitTime: 1)   // an older regista-mcp
    let old = try SocketEngineHost(path: path, build: other)
    let w = try old.execute("engines.status", params: [:])
    #expect(w["mcpBuild"]?.stringValue == "0000000")
    #expect(w["buildWarning"]?.stringValue?.contains("scripts/build-mcp.sh") == true)
    lock.lock()
    #expect(clientBuilds == [app, other])   // the app learns each client's build from the hello
    lock.unlock()
}

@Test func unknownCommandSaysTheAppIsOlder() throws {
    let path = socketPath()
    let server = EngineSocketServer(path: path, handler: { _, _, _ in .null })
    try server.start()
    defer { server.stop() }
    // The app side: a command it does not know.
    let fd = try EngineSocket.connect(path.path)
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    try EngineSocket.send(["op": "execute", "command": "profile.future", "params": [:]], on: handle)
    let reply = try #require(LineReader(handle).next().flatMap { try? JSONValue.parse($0) })
    #expect(reply["error"]?.stringValue?.contains("older than the MCP server") == true)
}

/// S2 #76: every project-scoped tool takes `project` (which tab); project_new / project_open / project_list do not;
/// project_list answers from the headless engine.
@Test func projectScopedToolsTakeAProjectTarget() throws {
    let s = server()
    let r = try #require(s.handle(request("tools/list")))
    let tools = try #require(r.value(at: "result.tools")?.arrayValue)
    func tool(_ name: String) -> JSONValue? { tools.first { $0["name"]?.stringValue == name } }
    #expect(tool("timeline_cut")?.value(at: "inputSchema.properties.project.type") == "string")
    #expect(tool("project_save")?.value(at: "inputSchema.properties.project") != nil)
    #expect(tool("project_list") != nil)
    for name in ["project_new", "project_open", "project_list"] { #expect(tool(name)?.value(at: "inputSchema.properties.project") == nil) }
    let list = try #require(s.handle(request("tools/call", ["name": "project_list", "arguments": [:]])))
    #expect(list.value(at: "result.isError") == false)
    #expect(list.value(at: "result.structuredContent.tabs") == [])
}


/// What the agent is told must exist: every tool named in the recipes, the server instructions, the start prompt
/// partners paste into Claude and the regista skill is a real tool, and every recipe is announced where the agent
/// looks first.
@Test func everythingTheAgentIsToldToCallExists() throws {
    let s = server()
    let tools = try #require(s.handle(request("tools/list"))?.value(at: "result.tools")?.arrayValue)
    let names = Set(tools.compactMap { $0["name"]?.stringValue })
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var texts: [String: String] = ["server instructions": MCPServer.instructions]
    for r in Recipes.all { texts["recipe \(r.name)"] = r.text() }
    for file in ["handoff/START-PROMPT.md", "handoff/skill/regista/SKILL.md"] {
        texts[file] = try String(contentsOf: repo.appendingPathComponent(file), encoding: .utf8)
    }
    // tool-shaped words: lower-case, an underscore, camel case allowed (media_list, frame_contactSheet, voice_enroll_script)
    let shape = try NSRegularExpression(pattern: "(?<![A-Za-z0-9_./-])[a-z]+(?:_[a-z][A-Za-z0-9]*)+(?![A-Za-z0-9_])")
    let prefixes = Set(names.compactMap { $0.split(separator: "_").first.map(String.init) })
    for (source, text) in texts {
        let ns = text as NSString
        for m in shape.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let word = ns.substring(with: m.range)
            guard prefixes.contains(String(word.split(separator: "_")[0])) else { continue }   // not a tool family
            #expect(names.contains(word), "\(source) names \(word), which is not a tool")
        }
    }
    // Each recipe is named in the instructions, the start prompt and the skill, and listed by recipe_get.
    let listed = try #require(s.handle(request("tools/call", ["name": "recipe_get", "arguments": [:]])))
    let recipes = listed.value(at: "result.structuredContent.recipes")?.arrayValue?.compactMap { $0["name"]?.stringValue }
    #expect(recipes == Recipes.all.map(\.name) && recipes?.count == 4)
    for r in Recipes.all {
        for source in ["server instructions", "handoff/START-PROMPT.md", "handoff/skill/regista/SKILL.md"] {
            #expect(texts[source]?.contains(r.name) == true, "\(source) does not mention the recipe \(r.name)")
        }
    }
    // Where to save is always said.
    #expect(MCPServer.instructions.contains("projectsDirectory") && MCPServer.instructions.contains("exportsDirectory"))
}
