import Foundation
import Testing
@testable import RegistaCore

// #109: the Medium tier's Python engines use the pinned uv and the pinned Python the installer puts in the engines folder;
// Homebrew's uv is neither needed nor preferred.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func uvAndItsPythonArePinnedAndNeedNoHomebrew() throws {
    let m = EngineManifest.shared
    let uv = try #require(m.entry("uv"))
    #expect(uv.install.method == "installer" && uv.install.formula == nil, "uv comes from the installer, not Homebrew")
    let bin = try #require(m.artifact("uv-bin")), python = try #require(m.artifact("uv-python"))
    #expect(bin.url.hasPrefix("https://github.com/astral-sh/uv/releases/download/\(bin.version)/") && bin.sha256.count == 64)
    #expect(python.version.hasPrefix("3.12.") && python.version.contains("+") && python.sha256.count == 64, "an exact Python build: \(python.version)")
    #expect(m.artifact("uv") == nil, "no Homebrew row for uv")
    #expect(EngineConfig.developerDefaults["uv"] == nil && EngineConfig().uv.hasSuffix("/uv/uv-\(bin.version)/uv"), "\(EngineConfig().uv)")
    // What Settings › Engines runs: the WhisperX and VoxCPM2 steps need uv (installed by the installer), never brew.
    let dir = TemporaryFolder.url.appendingPathComponent("regista-uv-tests-\(UUID().uuidString)")
    let env = ["REGISTA_SUPPORT_DIR": dir.appendingPathComponent("support").path, "REGISTA_CACHE_DIR": dir.appendingPathComponent("cache").path,
               "REGISTA_ENGINES": dir.appendingPathComponent("support/engines.json").path, "REGISTA_LANG": "en"]
    for (id, expected) in [("uv", "uv \(bin.version) and Python \(python.version.split(separator: "+")[0])"),
                           ("whisperx", "uv \(bin.version), Python \(python.version.split(separator: "+")[0])"),
                           ("voxcpm", "uv \(bin.version), Python \(python.version.split(separator: "+")[0])")] {
        let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), [repo.appendingPathComponent("scripts/install.sh").path, "--only", id, "--check", "--tier", "medium"],
                                   environment: env)
        #expect(r.status == 0 && r.stdoutText.contains(expected), "\(id): \(r.stdoutText) \(r.stderrText)")
        #expect(!r.stdoutText.contains("brew"), "\(id): \(r.stdoutText)")
    }
}
