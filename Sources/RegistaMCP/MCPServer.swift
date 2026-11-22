import Foundation
import RegistaCore

/// Minimal Model Context Protocol server (JSON-RPC 2.0): initialize, ping, tools/list,
/// tools/call, prompts/list, prompts/get. Every engine command is a tool; its schema comes from the command's
/// parameter description. Transport-agnostic: `handle` maps one message to its reply.
public final class MCPServer {
    /// Newest first. We answer with the client's version when we know it.
    public static let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    public static let serverVersion = "0.3.0"

    /// The server `instructions` (clients put them in the model's context): the short version of the
    /// talking-head recipe; `recipe_get` / the `talking-head-reel` prompt hold the full one.
    static let instructions = """
    Regista is a video editor on the user's Mac, driven entirely through these tools: no shell or file tools are \
    needed. With the Regista app open the user sees every step live in it (closed, the tools still work, unseen); \
    when a tool answers that the app closed, ask the user to reopen Regista and call again. Start every job with recipe_get {} and follow the recipe that fits: talking-head-reel (a person \
    speaking to camera), screen-tutorial (a screen recording made in Regista), voice-over-video (no one on camera: \
    the user's own cloned voice over footage and graphics), reel-graphics (titles, cards, sound effects and music \
    on top of an edit), prompt-to-reel (a faceless reel from one sentence: plan to confirm, then templates, sound and \
    captions). Find footage, scripts and recordings with media_list (the folders you may read; it also \
    gives projectsDirectory for project_new and exportsDirectory for the exported files) and read scripts with \
    text_read. Short version of a talking-head reel: project_new → media_import → media_extractAudio → \
    transcript_run → script_set → takes_list (write the kept-take list for the user; takes_select fixes a \
    pick) → edit_autoCut → audio_clean (−15 LUFS) → edit_punchIns + clip_set light grade → choose caption \
    keywords (hook word, brand/product names, numbers, the point of each line: 1–2 per line, never stop \
    words) → captions_generate {style: "talking-head-v1", keywords, fixes for misheard names} → \
    frame_contactSheet to look at the result (images come back inline) and fix what looks wrong → \
    export_render 9:16 + export_srt + export_mlt → project_save → captions_checkTiming and media_checkSync \
    on the mp4. Every effect, look, style and motion template (animated cards, checklists, counters, carousels, \
    device frames, charts) is in effects_catalog with what it looks like, when to use it and when not to: read it, \
    propose 1–3 items that fit the line to the user with a one-line reason each, show one with effects_preview when \
    they ask (renders it without touching the edit), then apply it with the command the catalog gives (motion \
    templates: motion_add). The user's editing rules for each kind of video close the recipe (rules_get reads any sheet): \
    follow them, and run rules_check before export_render, which refuses while a rule fails (rules_fix applies the \
    safe fixes; exportAnyway only when the user said to export anyway). Rules that always hold: never modify or delete the user's original files; look at your \
    work (frame_contactSheet) before exporting; a voice-over is only ever the active profile's own voice \
    (voice_list); a paid generation needs the cost told first and the user's approval in the app; when a tool says \
    an engine is missing, engines_status says which and the user installs it in Regista › Settings › Motori. Times \
    are seconds and snap to the frame grid; project_state shows the timeline; every edit can be undone with \
    history_undo; a failed command changes nothing and its error says what to fix; a tool that times out is still \
    running in the app (wait, then project_state). The app can hold several projects, one tab each: commands act \
    on the active tab (the one the user sees); project_list shows the tabs, and every project command accepts \
    project (a tab id or the .regista path) to work on another tab without switching the user's view.
    """

    /// At most this many image blocks per tool result.
    static let maxImages = 8

    let host: EngineHost
    let log: (String) -> Void

    public init(host: EngineHost, log: @escaping (String) -> Void = { _ in }) {
        self.host = host
        self.log = log
    }

    /// MCP clients (and the Claude API) want [A-Za-z0-9_-] tool names: "timeline.cut" → "timeline_cut".
    public static func toolName(_ commandID: String) -> String {
        commandID.replacingOccurrences(of: ".", with: "_")
    }

    /// Reply to one decoded message, nil for notifications.
    public func handle(_ message: JSONValue) -> JSONValue? {
        guard case .object(let m) = message, m["jsonrpc"] == "2.0", let method = m["method"]?.stringValue else {
            return Self.error(id: message["id"] ?? .null, code: -32600, "Invalid Request")
        }
        guard let id = m["id"], id != .null else {
            log("notification \(method)")   // notifications/initialized, cancelled…: nothing to do
            return nil
        }
        let params = m["params"] ?? .object([:])
        do {
            let result: JSONValue
            switch method {
            case "initialize": result = initialize(params)
            case "ping": result = .object([:])
            case "tools/list": result = try listTools()
            case "tools/call": result = try callTool(params)
            case "prompts/list": result = listPrompts()
            case "prompts/get": result = try getPrompt(params)
            default: return Self.error(id: id, code: -32601, "Method not found: \(method)")
            }
            return ["jsonrpc": "2.0", "id": id, "result": result]
        } catch let e as RPCError {
            return Self.error(id: id, code: e.code, e.message)
        } catch {
            return Self.error(id: id, code: -32603, "Internal error: \(error)")
        }
    }

    /// Reply to one raw line (stdio framing). Nil when there is nothing to send.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONValue.parse(trimmed) else {
            return Self.error(id: .null, code: -32700, "Parse error").text()
        }
        return handle(message)?.text()
    }

    // MARK: Methods

    func initialize(_ params: JSONValue) -> JSONValue {
        let requested = params["protocolVersion"]?.stringValue ?? ""
        let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
        let client = params.value(at: "clientInfo.name")?.stringValue ?? "?"
        log("initialize from \(client) (protocol \(requested) → \(version))")
        host.clientDidInitialize(name: client)
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
            "serverInfo": ["name": "regista", "title": "Regista", "version": .string(Self.serverVersion)],
            "instructions": .string(Self.instructions),
        ]
    }

    func listTools() throws -> JSONValue {
        // Human-only commands (approving a paid generation) are not tools: an agent cannot call them.
        let tools = try host.descriptors().filter { !$0.humanOnly }.map { d -> JSONValue in
            [
                "name": .string(Self.toolName(d.id)),
                "title": .string(d.id),
                "description": .string(d.summary),
                // Every project-scoped command also takes `project` (which tab): the host routes it, no command declares it.
                "inputSchema": ProjectTarget.accepts(d.id) ? ProjectTarget.adding(to: d.inputSchema) : d.inputSchema,
                "annotations": Self.annotations(d),
            ]
        }
        return ["tools": .array(tools)]
    }

    /// The MCP hints of a command: a query reads only; a job (a download, a training) only adds files outside the project,
    /// never overwriting one, so it is not destructive; every other command may change or replace what is there.
    static func annotations(_ d: CommandDescriptor) -> JSONValue {
        switch d.kind {
        case .query: ["readOnlyHint": true]
        case .job: ["readOnlyHint": false, "destructiveHint": false]
        case .edit, .session, .history: ["readOnlyHint": false]
        }
    }

    func callTool(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.stringValue else { throw RPCError(code: -32602, message: "tools/call: missing name") }
        guard let d = try host.descriptors().first(where: { Self.toolName($0.id) == name || $0.id == name }) else {
            throw RPCError(code: -32602, message: "Unknown tool: \(name)")
        }
        if d.humanOnly {
            log("\(d.id) refused: human-only")
            return ["content": [["type": "text", "text": .string(d.humanOnlyRefusal)]], "isError": true]
        }
        // Command failures (bad params included) are tool results with isError, so the model can correct itself.
        do {
            let result = try host.execute(d.id, params: params["arguments"] ?? .object([:]))
            log("\(d.id) ok")
            var content: [JSONValue] = [["type": "text", "text": .string(result.text())]]
            content += imageContent(result)
            var reply: [String: JSONValue] = ["content": .array(content), "isError": false]
            if case .object = result { reply["structuredContent"] = result }
            return .object(reply)
        } catch {
            log("\(d.id) error: \(error)")
            return ["content": [["type": "text", "text": .string("\(error)")]], "isError": true]
        }
    }

    /// The files a command lists under "images" ({path, mimeType}) as MCP image content, so the client sees them.
    func imageContent(_ result: JSONValue) -> [JSONValue] {
        guard let images = result["images"]?.arrayValue else { return [] }
        return images.prefix(Self.maxImages).compactMap { image -> JSONValue? in
            guard let path = image["path"]?.stringValue, let data = FileManager.default.contents(atPath: path) else {
                log("image missing: \(image)")
                return nil
            }
            let mime = image["mimeType"]?.stringValue ?? (path.lowercased().hasSuffix(".png") ? "image/png" : "image/jpeg")
            return ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mime)]
        }
    }

    // MARK: Prompts

    func listPrompts() -> JSONValue {
        ["prompts": .array(Recipes.all.map { r in
            ["name": .string(r.name), "title": .string(r.title), "description": .string(r.description),
             "arguments": .array(r.arguments.map { ["name": .string($0.name), "description": .string($0.description), "required": .bool($0.required)] })]
        })]
    }

    func getPrompt(_ params: JSONValue) throws -> JSONValue {
        guard let name = params["name"]?.stringValue else { throw RPCError(code: -32602, message: "prompts/get: missing name") }
        guard let recipe = Recipes.named(name) else { throw RPCError(code: -32602, message: "Unknown prompt: \(name)") }
        let args = (params["arguments"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        return ["description": .string(recipe.description),
                "messages": [["role": "user", "content": ["type": "text", "text": .string(recipe.text(args))]]]]
    }

    // MARK: Errors

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    static func error(id: JSONValue, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }
}
