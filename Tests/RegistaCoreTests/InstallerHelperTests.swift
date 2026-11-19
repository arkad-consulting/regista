import Foundation
import Testing
@testable import RegistaCore

// #106: what the installer's Python helpers did, in the app's own code (regista-engine manifest / config / claude-desktop),
// so Settings › Engines and › Claude work on a Mac whose python3 is only the Command Line Tools stub.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func scratch() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-helper-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// scripts/engines.py with these arguments (a developer's clone has python3: the parity check runs there).
private func enginesPy(_ args: [String]) throws -> HelperOutput {
    let r = try Subprocess.run(URL(fileURLWithPath: "/usr/bin/python3"), ["-I", repo.appendingPathComponent("scripts/engines.py").path] + args)
    return HelperOutput(status: r.status, out: r.stdoutText)
}

@Test func theManifestQueriesAnswerLikeEnginesPy() throws {
    let env = [String: String]()
    var calls: [[String]] = [["ids"], ["comfy-bytes"], ["others", "whisper.cpp,ffmpeg"], ["others"]]
    for gb in ["7", "8", "15.5", "16", "30", "48", "64", "128"] { calls.append(["tier-for-ram", gb]) }
    for t in ["base", "medium", "pro"] { calls += [["need-gb", t], ["need-gb", t, "--detail"], ["disk", t]] }
    for e in EngineManifest.shared.entries {
        for c in ["steps", "name", "size", "install-info", "scripts", "need-gb"] { calls.append([c, e.id]) }
        for k in ["licence", "licenceUrl", "minRamGB", "nonCommercial", "dependsOn", "nothing"] { calls.append(["field", e.id, k]) }
    }
    var differ: [String] = []
    for c in calls {
        let swift = ManifestQuery.run(c, environment: env), py = try enginesPy(c)
        if swift.out != py.out || swift.status != py.status { differ.append("\(c.joined(separator: " ")): \(swift.out) ≠ \(py.out)") }
    }
    #expect(calls.count > 300)
    #expect(differ.isEmpty, "\(differ.prefix(10).joined(separator: "\n"))")
    #expect(ManifestQuery.run(["name", "no-such-engine"], environment: env).status == 1)
    #expect(ManifestQuery.run(["validate"], environment: env).status == 1, "validate and docs stay in engines.py")
}

@Test func theManifestQueriesReadTheInstallerTestsCopies() throws {
    // $REGISTA_LOCK points the installer and its helper at another lock (the installer tests' fake downloads).
    let dir = scratch()
    let lock = String(decoding: PackageResources.engines_lock, as: UTF8.self).replacingOccurrences(of: "deep-filter | 0.5.6 |", with: "deep-filter | 0.5.7 |")
    let file = dir.appendingPathComponent("engines.lock")
    try lock.write(to: file, atomically: true, encoding: .utf8)
    let r = ManifestQuery.run(["install-info", "deepfilternet"], environment: ["REGISTA_LOCK": file.path])
    #expect(r.status == 0 && r.out.contains("|deep-filter|"), "\(r)")
    #expect(ManifestQuery.run(["ids"], environment: ["REGISTA_MANIFEST": dir.appendingPathComponent("missing.json").path]).status == 1)
}

@Test func enginesJsonKeepsWhatThePersonSet() throws {
    let file = scratch().appendingPathComponent("support/engines.json")
    #expect(EnginesFile.get(file, "tier") == HelperOutput(), "no file: empty")
    #expect(EnginesFile.set(file, [("ffmpeg", "/x/ffmpeg"), ("tier", "medium")]).status == 0)
    #expect(EnginesFile.get(file, "ffmpeg").out == "/x/ffmpeg\n")
    try Data(#"{"whisperThreads": 4, "transcription": {"base": "whisper.cpp"}, "tier": "medium", "flag": true}"#.utf8).write(to: file)
    #expect(EnginesFile.set(file, [("tier", ""), ("deepFilter", "/d/deep-filter")]).status == 0)
    let o = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(o["tier"] == nil && o["deepFilter"] as? String == "/d/deep-filter" && o["whisperThreads"] as? Int == 4 && o["transcription"] != nil)
    #expect(EnginesFile.get(file, "whisperThreads").out == "4\n" && EnginesFile.get(file, "flag").out == "True\n")
    #expect(EnginesFile.get(file, "missing").out == "\n")
    #expect(EnginesFile.check(file).status == 0)
    try Data("{broken".utf8).write(to: file)
    #expect(EnginesFile.set(file, [("tier", "base")]).status == 1)
    #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "{broken", "a broken file is left as it is")
    #expect(EnginesFile.check(file).status == 1)
}

/// The file `set` writes, byte for byte what scripts/claude_desktop.py wrote for the same input (checked against it when
/// it was retired, 2026-11-19): keys in their order, two-space indent, non-ASCII kept, other servers untouched.
@Test func claudeDesktopsConfigIsEditedAsThePythonHelperDid() throws {
    let dir = scratch()
    let config = dir.appendingPathComponent("Claude/claude_desktop_config.json")
    try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"preferences": {"x": 1, "f": 1.5, "big": 12345678901234567890},  "zeta":"é ☃ \" \\ \n\t\u0001", "mcpServers": {"other": {"command": "/bin/echo", "args": ["a"]}, "regista": {"command": "/old/regista-mcp", "args": []}}, "arr": [1, [], {}, true, false, null]}"#.utf8).write(to: config)
    #expect(ClaudeDesktopConfig.run(["status", config.path, "/new/regista-mcp"]) == HelperOutput(status: 2, out: "/old/regista-mcp\n"))
    let set = ClaudeDesktopConfig.run(["set", config.path, "/new/regista-mcp"])
    #expect(set.status == 0 && set.out.hasSuffix("replaced /old/regista-mcp\n"), "\(set)")
    let backup = try #require(set.out.split(separator: "\n").first { $0.hasPrefix("backup ") }.map { String($0.dropFirst(7)) })
    #expect(backup.hasPrefix(config.path + ".regista-backup-") && FileManager.default.fileExists(atPath: backup))
    #expect(String(decoding: try Data(contentsOf: config), as: UTF8.self) == """
    {
      "preferences": {
        "x": 1,
        "f": 1.5,
        "big": 12345678901234567890
      },
      "zeta": "é ☃ \\" \\\\ \\n\\t\\u0001",
      "mcpServers": {
        "other": {
          "command": "/bin/echo",
          "args": [
            "a"
          ]
        },
        "regista": {
          "command": "/new/regista-mcp",
          "args": []
        }
      },
      "arr": [
        1,
        [],
        {},
        true,
        false,
        null
      ]
    }

    """)
    #expect(ClaudeDesktopConfig.run(["status", config.path, "/new/regista-mcp"]).status == 0)
    #expect(ClaudeDesktopConfig.run(["set", config.path, "/new/regista-mcp"]).out == "unchanged\n")
    // With an env: another entry (status 2, same command), then written with it.
    #expect(ClaudeDesktopConfig.run(["status", config.path, "/new/regista-mcp", "REGISTA_ENGINES=/e.json"]).out == "/new/regista-mcp (other arguments or env)\n")
    #expect(ClaudeDesktopConfig.run(["set", config.path, "/new/regista-mcp", "REGISTA_ENGINES=/e.json"]).status == 0)
    #expect(ClaudeDesktopConfig.run(["status", config.path, "/new/regista-mcp", "REGISTA_ENGINES=/e.json"]).status == 0)
    // Disconnect: the entry goes, the other server stays.
    #expect(ClaudeDesktopConfig.run(["remove", config.path]).out.hasSuffix("removed\n"))
    #expect(ClaudeDesktopConfig.run(["status", config.path, "/new/regista-mcp"]).status == 1)
    #expect(try OrderedJSON.parse(Data(contentsOf: config))["mcpServers"]?["other"] != nil)
    #expect(ClaudeDesktopConfig.run(["remove", config.path]).out == "absent\n")

    // No file: created, no backup. A file that is not JSON, or not an object with an mcpServers object: never touched.
    let fresh = dir.appendingPathComponent("new/claude_desktop_config.json")
    #expect(ClaudeDesktopConfig.run(["status", fresh.path, "/m"]).status == 1)
    #expect(ClaudeDesktopConfig.run(["set", fresh.path, "/m"]).out == "added\n")
    #expect(String(decoding: try Data(contentsOf: fresh), as: UTF8.self) == "{\n  \"mcpServers\": {\n    \"regista\": {\n      \"command\": \"/m\",\n      \"args\": []\n    }\n  }\n}\n")
    for broken in ["{bad", #"{"mcpServers": []}"#, "[1]"] {
        try Data(broken.utf8).write(to: fresh)
        #expect(ClaudeDesktopConfig.run(["status", fresh.path, "/m"]).status == 3, "\(broken)")
        #expect(ClaudeDesktopConfig.run(["set", fresh.path, "/m"]).status == 3, "\(broken)")
        #expect(String(decoding: try Data(contentsOf: fresh), as: UTF8.self) == broken)
    }
    #expect(ClaudeDesktopConfig.run(["set", fresh.path]).status == 64, "usage")
}
