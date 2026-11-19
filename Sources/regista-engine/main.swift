import Foundation
import RegistaCore
import RegistaEngines
import RegistaMCP

// Headless engine: runs commands and scenarios without the app.

let usage = """
regista-engine — Regista's command engine, headless

  regista-engine exec <command-id> ['<json params>'] [--project <dir.regista>]
      Run one command. With --project the project is opened first and saved after an edit.
  regista-engine run <scenario.json> [--work <dir>] [--mcp <regista-mcp binary> [--engine local|app|auto]] [--skip-requiring <tag>]
      Replay a scenario on an in-process engine, or through an MCP server over stdio with
      --mcp; exit 1 on the first unmet expectation. Through MCP the server runs its own headless
      engine (--engine local, the default: tests never touch a running app); --engine app replays
      on the running Regista app over its socket (fails if it is not running). --skip-requiring engines exits 0 without
      running scenarios marked "requires": ["engines"] (the pre-commit hook uses it); scenarios
      marked "requires": ["footage"] are skipped when a file of their "footage" list is missing, and those marked
      "requires": ["app"] unless they replay on the app (--mcp … --engine app).
  regista-engine list
      List the commands with their parameters.

  What the installer and Settings run on a Mac without developer tools (no python3, #106):
  regista-engine manifest <command> …   the queries of scripts/engines.py on the compiled-in manifest and engines.lock
                                        ($REGISTA_MANIFEST / $REGISTA_LOCK point at other copies)
  regista-engine config get <engines.json> <key> · config set <engines.json> <key> <value> … · config check <file>
  regista-engine claude-desktop status|set <config> <regista-mcp> [KEY=VALUE …] · claude-desktop remove <config>
  regista-engine install <engine id>    what Settings › Engines runs: the installer inside this app, --only <id>
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Splits `--name value` options from positional arguments.
func parse(_ args: ArraySlice<String>) -> (positional: [String], options: [String: String]) {
    var positional: [String] = [], options: [String: String] = [:]
    var it = args.makeIterator()
    while let a = it.next() {
        if a.hasPrefix("--") {
            guard let v = it.next() else { fail("missing value for \(a)") }
            options[String(a.dropFirst(2))] = v
        } else {
            positional.append(a)
        }
    }
    return (positional, options)
}

func exec(_ positional: [String], _ options: [String: String]) {
    guard let id = positional.first else { fail(usage) }
    let params: JSONValue
    do { params = try positional.count > 1 ? JSONValue.parse(positional[1]) : .object([:]) }
    catch { fail("params are not valid JSON: \(error)") }

    let engine = Engine(services: .live())
    do {
        if let dir = options["project"], id != "project.new", id != "project.open" {
            try engine.execute("project.open", params: ["path": .string(dir)])
        }
        let result = try engine.execute(id, params: params)
        if engine.isDirty, engine.projectURL != nil { try engine.execute("project.save") }
        print(result.text(pretty: true))
    } catch {
        fail("error: \(error)")
    }
}

func run(_ positional: [String], _ options: [String: String]) {
    guard let path = positional.first else { fail(usage) }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let scenario: Scenario
    do { scenario = try Scenario.load(url) } catch { fail("\(error)") }
    if let tag = options["skip-requiring"], scenario.requires.contains(tag) {
        print("- \(scenario.name): skipped (requires \(tag))")
        exit(0)
    }
    // A scenario marked "requires": ["app"] runs only on the running app (--mcp … --engine app): several tabs, the window.
    if scenario.requires.contains("app"), options["mcp"] == nil || options["engine"] != "app" {
        print("- \(scenario.name): skipped (requires the app: --mcp <regista-mcp> --engine app)")
        exit(0)
    }
    let missing = scenario.missingFootage()
    if !missing.isEmpty {
        print("- \(scenario.name): skipped (footage missing: \(missing.joined(separator: ", ")))")
        exit(0)
    }

    let work: URL
    if let w = options["work"] {
        work = URL(fileURLWithPath: (w as NSString).expandingTildeInPath)
    } else {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("regista-\(scenario.name)-\(UUID().uuidString.prefix(8))")
    }
    do { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) } catch { fail("\(error)") }
    print("work: \(work.path)")

    let execute: ScenarioRunner.Execute
    var client: MCPClient?
    if let server = options["mcp"] {
        let engineMode = options["engine"] ?? "local"
        guard ["local", "app", "auto"].contains(engineMode) else { fail("--engine is local, app or auto") }
        do { client = try MCPClient(server: URL(fileURLWithPath: server), environment: ["REGISTA_ENGINE": engineMode]) }
        catch { fail("cannot start MCP server: \(error)") }
        let c = client!
        let names = Set(c.tools.compactMap { $0["name"]?.stringValue })
        print("mcp: \(c.serverInfo["name"]?.stringValue ?? "?") \(c.serverInfo["version"]?.stringValue ?? ""), protocol \(c.protocolVersion), \(names.count) tools")
        execute = { id, params in
            let tool = MCPServer.toolName(id)
            guard names.contains(tool) else { throw MCPClientError("server has no tool \(tool)") }
            return try c.callTool(tool, arguments: params)
        }
    } else {
        let engine = Engine(services: .live())
        execute = { try engine.execute($0, params: $1) }
    }
    var variables: [String: JSONValue] = ["WORK": .string(work.path), "SCENARIO_DIR": .string(url.deletingLastPathComponent().path)]
    let environment = scenario.environment()
    for k in scenario.defaults.keys { variables[k] = environment[k].map { .string($0) } }
    var runner = ScenarioRunner(variables: variables, execute: execute)
    let ok = runner.run(scenario)
    client?.close()
    exit(ok ? 0 : 1)
}

func list() {
    for d in Engine().descriptors {
        print("\(d.id)  [\(d.kind.rawValue)]\n    \(d.summary)")
        for p in d.params { print("    - \(p.name)\(p.required ? "" : "?"): \(p.description)") }
    }
}

/// Prints a helper's output and exits with its status.
func finish(_ r: HelperOutput) -> Never {
    FileHandle.standardOutput.write(Data(r.out.utf8))
    FileHandle.standardError.write(Data(r.err.utf8))
    exit(r.status)
}

func config(_ a: [String]) -> Never {
    switch (a.first, a.count) {
    case ("get", 3): finish(EnginesFile.get(URL(fileURLWithPath: a[1]), a[2]))
    case ("check", 2): finish(EnginesFile.check(URL(fileURLWithPath: a[1])))
    case ("set", let n) where n >= 2 && n % 2 == 0:
        let kv = Array(a.dropFirst(2))
        finish(EnginesFile.set(URL(fileURLWithPath: a[1]), stride(from: 0, to: kv.count, by: 2).map { (kv[$0], kv[$0 + 1]) }))
    default: fail("regista-engine config get <file> <key> | set <file> <key> <value> … | check <file>")
    }
}

/// Installs one engine exactly as Settings › Engines does (EngineInstaller, the installer inside this app), printing
/// what the installer printed.
func install(_ a: [String]) -> Never {
    guard a.count == 1 else { fail("regista-engine install <engine id>") }
    guard let installer = EngineInstaller.locate() else { fail("no installer next to this regista-engine (Contents/Resources/Installer)") }
    do {
        let r = try installer.run(a[0])
        FileHandle.standardOutput.write(r.stdout)
        FileHandle.standardError.write(r.stderr)
        exit(r.status)
    } catch { fail("error: \(error)") }
}

let args = CommandLine.arguments.dropFirst()
switch args.first {
case "manifest": finish(ManifestQuery.run(Array(args.dropFirst())))
case "config": config(Array(args.dropFirst()))
case "claude-desktop": finish(ClaudeDesktopConfig.run(Array(args.dropFirst())))
case "install": install(Array(args.dropFirst()))
default: break
}
let (positional, options) = parse(args.dropFirst())
switch args.first {
case "exec": exec(positional, options)
case "run": run(positional, options)
case "list": list()
default: print(usage); exit(args.first == nil || args.first == "help" || args.first == "--help" ? 0 : 1)
}
