// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Regista",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure logic (timeline model, script aligner, cutting): no UI, fully testable.
        // The engine manifest and the download lock (symlinks to scripts/) are compiled in: one source of truth for the
        // installer, the app and the docs, with nothing to find at run time.
        // The default editing-rule sheets (#31), one per kind and interface language, are compiled in too.
        .target(name: "RegistaCore", resources: [.embedInCode("Engines/Manifest/engines.manifest.json"),
                                                 .embedInCode("Engines/Manifest/engines.lock")]
                    + ["every-video", "talking-head-reel", "screen-tutorial", "voice-over-video", "reel-graphics"].flatMap { kind in
                        ["it", "en", "fr", "pt"].map { Resource.embedInCode("Rules/Sheets/\(kind).\($0).md") }
                    }),
        // The start prompt for Claude (handoff/START-PROMPT.md, a symlink) is compiled in for Impostazioni › Claude.
        .executableTarget(name: "Regista", dependencies: ["RegistaCore", "RegistaEngines", "RegistaMCP"],
                          resources: [.embedInCode("Resources/START-PROMPT.md")]),
        // Engine adapters that need Apple frameworks (Vision face tracking): kept out of the Core.
        .target(name: "RegistaEngines", dependencies: ["RegistaCore"]),
        // MCP protocol (server, stdio transport, test client) on top of the engine.
        .target(name: "RegistaMCP", dependencies: ["RegistaCore"]),
        // Headless engine CLI: one command (`exec`) or a scenario (`run`, optionally through MCP).
        .executableTarget(name: "regista-engine", dependencies: ["RegistaCore", "RegistaEngines", "RegistaMCP"]),
        // Local MCP server over stdio, used by Claude Code via .mcp.json.
        .executableTarget(name: "regista-mcp", dependencies: ["RegistaCore", "RegistaEngines", "RegistaMCP"]),
        .testTarget(name: "RegistaCoreTests", dependencies: ["RegistaCore"]),
        .testTarget(name: "RegistaMCPTests", dependencies: ["RegistaMCP"]),
        .testTarget(name: "RegistaEnginesTests", dependencies: ["RegistaEngines"]),
        // App-level checks that need AppKit windows (the teleprompter panel).
        .testTarget(name: "RegistaAppTests", dependencies: ["Regista"]),
    ],
    swiftLanguageModes: [.v5]
)
