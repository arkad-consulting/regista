import Foundation
import Testing
@testable import RegistaCore

// #61: an engines folder installed by an older app gets the app's current helper scripts. Every test works on a fake
// engines folder of its own (passed explicitly: never the process's REGISTA_SUPPORT_DIR, never the real one), with the
// repository's engines/ as the app's copy.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let source = repo.appendingPathComponent("engines", isDirectory: true)
private let manifest = EngineManifest.shared

private func write(_ url: URL, _ text: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// WhisperX installed as an older installer left it: its environment, lock file and project, an older wx_align.py, no
/// textnorm.py (added later), plus a model and a file of the person's that the refresh must leave alone.
private func olderWhisperX(in engines: URL) throws {
    let wx = engines.appendingPathComponent("whisperx")
    try write(wx.appendingPathComponent(".venv/bin/python"), "#!/bin/sh\n")
    try write(wx.appendingPathComponent("pyproject.toml"), "[project]\nname = \"older\"\n")
    try write(wx.appendingPathComponent("uv.lock"), "# an older lock\n")
    try write(wx.appendingPathComponent("wx_align.py"), "# an older wx_align.py\n")
    try write(wx.appendingPathComponent("models/ct2-whisper-large-v3-turbo/model.bin"), "weights")
}

private func contents(_ url: URL) -> String? { (try? String(contentsOf: url, encoding: .utf8)) }

@Test func anOlderHelperScriptIsReplacedAndNothingElseIsTouched() throws {
    let engines = tempDir().appendingPathComponent("engines")
    try olderWhisperX(in: engines)
    let wx = engines.appendingPathComponent("whisperx")
    let before = try FileManager.default.subpathsOfDirectory(atPath: wx.path).filter { !$0.hasSuffix(".py") }
        .reduce(into: [String: String?]()) { $0[$1] = contents(wx.appendingPathComponent($1)) }
    let whisperx = try #require(manifest.entry("whisperx"))
    #expect(EngineScripts.differing(whisperx, in: engines, source: source) == ["whisperx/wx_align.py", "whisperx/textnorm.py"])

    var logged: [String] = []
    let report = EngineScripts.refresh(in: engines, source: source) { logged.append($0) }
    #expect(report.replaced == ["whisperx/wx_align.py", "whisperx/textnorm.py"] && report.failed.isEmpty)
    for f in ["wx_align.py", "textnorm.py"] {
        #expect(FileManager.default.contents(atPath: wx.appendingPathComponent(f).path)
                == FileManager.default.contents(atPath: source.appendingPathComponent("whisperx/\(f)").path), "\(f) is the app's")
    }
    // The environment, the lock file, the project and the model are as they were (scripts only).
    for (path, text) in before { #expect(contents(wx.appendingPathComponent(path)) == text, "\(path) untouched") }
    #expect(EngineScripts.differing(whisperx, in: engines, source: source).isEmpty)
    #expect(logged.count == 2 && logged.allSatisfy { $0.contains("replaced") })
    // A second refresh has nothing to do.
    #expect(EngineScripts.refresh(in: engines, source: source) { _ in } == EngineScripts.Report())
}

@Test func anEngineThatIsNotInstalledGetsNothing() throws {
    let engines = tempDir().appendingPathComponent("engines")
    try FileManager.default.createDirectory(at: engines, withIntermediateDirectories: true)
    // A half-installed VoxCPM (its folder and an old script, no environment) is left to the installer too.
    try write(engines.appendingPathComponent("voxcpm/vox_say.py"), "# old\n")
    let report = EngineScripts.refresh(in: engines, source: source) { _ in }
    #expect(report == EngineScripts.Report())
    #expect(!FileManager.default.fileExists(atPath: engines.appendingPathComponent("whisperx").path), "no folder created for a missing engine")
    #expect(contents(engines.appendingPathComponent("voxcpm/vox_say.py")) == "# old\n")
    #expect(try FileManager.default.contentsOfDirectory(atPath: engines.appendingPathComponent("voxcpm").path) == ["vox_say.py"])
}

@Test func aScriptThatCannotBeWrittenIsALineInTheLogNotAnError() throws {
    let engines = tempDir().appendingPathComponent("engines")
    try olderWhisperX(in: engines)
    let wx = engines.appendingPathComponent("whisperx")
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: wx.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wx.path) }
    var logged: [String] = []
    let report = EngineScripts.refresh(in: engines, source: source) { logged.append($0) }
    #expect(report.replaced.isEmpty && report.failed.count == 2, "\(report)")
    #expect(logged.count == 2 && logged.allSatisfy { $0.contains("cannot replace") })
    #expect(contents(wx.appendingPathComponent("wx_align.py")) == "# an older wx_align.py\n")
}

/// The manifest's scripts are every file the installer copies from engines/ that is not a lock file or a project (so a
/// script added later is not forgotten), and each is among the entry's files.
@Test func theManifestNamesEveryHelperScriptTheInstallerCopies() throws {
    let notScripts: Set<String> = ["pyproject.toml", "uv.lock", "package.json", "package-lock.json", ".npmrc"]
    let fm = FileManager.default
    for engine in try fm.contentsOfDirectory(atPath: source.path) where !engine.hasPrefix(".") {
        let files = (fm.subpaths(atPath: source.appendingPathComponent(engine).path) ?? [])
            .filter { p in !p.split(separator: "/").contains { $0.hasPrefix(".") || $0 == "__pycache__" } && !notScripts.contains(p) }
            .filter { var d: ObjCBool = false; return fm.fileExists(atPath: source.appendingPathComponent("\(engine)/\($0)").path, isDirectory: &d) && !d.boolValue }
            .map { "\(engine)/\($0)" }
        let declared = manifest.entries.flatMap(\.scripts).filter { $0.hasPrefix(engine + "/") }
        #expect(Set(files) == Set(declared), "\(engine): engines/ has \(files.sorted()), the manifest names \(declared.sorted())")
    }
    for e in manifest.entries { for s in e.scripts { #expect(!notScripts.contains((s as NSString).lastPathComponent), "\(e.id): \(s) is not a script") } }
}

/// Motori (engines.status → EngineCatalog) and scripts/doctor.sh (lib.sh scripts_state) agree on the same fake folder:
/// before the refresh both say the scripts differ, after it both say they match.
@Test func motoriAndTheDoctorAgreeTheScriptsMatchAfterTheRefresh() throws {
    let support = tempDir(), engines = support.appendingPathComponent("engines")
    try olderWhisperX(in: engines)
    func answers() throws -> (motori: EngineCatalog.Row, status: JSONValue?, doctor: String) {
        var services = FakeServices().make()
        services.enginesFolder = engines
        let status = try Engine(prober: FakeProber(), services: services).execute("engines.status")
        let entry = (status["engines"]?.arrayValue ?? []).first { $0["id"]?.stringValue == "whisperx" }
        // The row as Motori draws it once the engine is installed (the fake services report it missing).
        let installed = JSONValue.object(["tier": "medium", "engines": .array([.object(["id": "whisperx", "state": "installed",
            "scriptsCurrent": entry?["scriptsCurrent"] ?? .null])])])
        let row = try #require(EngineCatalog(status: installed, tier: .medium, enginesDirectory: engines).row("whisperx"))
        let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", ". \"$0/scripts/lib.sh\"; scripts_state whisperx", repo.path],
                                   environment: ["REGISTA_SUPPORT_DIR": support.path, "REGISTA_ENGINES": support.appendingPathComponent("engines.json").path,
                                                 "REGISTA_LANG": "en"])
        return (row, entry, r.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    let old = try answers()
    #expect(old.status?["scriptsCurrent"] == false && old.status?["scriptsDiffer"]?.arrayValue?.count == 2)
    #expect(!old.motori.scriptsCurrent)
    #expect(old.doctor == "differ whisperx/wx_align.py whisperx/textnorm.py", "\(old.doctor)")
    EngineScripts.refresh(["whisperx"], in: engines, source: source) { _ in }
    let new = try answers()
    #expect(new.status?["scriptsCurrent"] == true && new.status?["scriptsDiffer"] == nil)
    #expect(new.motori.scriptsCurrent)
    #expect(new.doctor == "current", "\(new.doctor)")
    // Without an engines folder in its services (a host other than the app), engines.status says nothing about scripts.
    let bare = try Engine(prober: FakeProber(), services: FakeServices().make()).execute("engines.status")
    #expect(!(bare["engines"]?.arrayValue ?? []).contains { $0["scriptsCurrent"] != nil })
}
