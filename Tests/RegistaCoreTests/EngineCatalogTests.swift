import Foundation
import Testing
@testable import RegistaCore

// Impostazioni › Motori (M2 #59): the rows engines.status gives the screen, the action per install method, removal limited
// to the engine's own files, and scripts/install.sh --only <id> (unknown ids refused, a fake engine installed into a temp
// support folder with its sha256 checked). Nothing here touches the real engines folder or engines.json.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let manifest = EngineManifest.shared

private func status(tier: MachineTier) throws -> JSONValue {
    var fakes = FakeServices()
    fakes.tier = tier
    var services = fakes.make()
    let config = EngineConfig()
    for g in [ComfyUIProvider(config: config), HiggsfieldProvider(config: config) as GeneratorProvider,
              VoxCPMProvider(config: config, profiles: ProfileStore(directory: tempDir()))] { services.generators[g.id] = g }
    return try Engine(prober: FakeProber(), services: services).execute("engines.status")
}

/// A status where every entry has `state` (planned ones stay planned).
private func uniformStatus(_ state: String, tier: MachineTier = .pro) -> JSONValue {
    ["tier": .string(tier.rawValue), "memoryGB": 48,
     "engines": .array(manifest.entries.map { ["id": .string($0.id), "state": .string($0.planned ? "planned" : state)] })]
}

@Test func motoriRowsMatchTheManifestForEachForcedTier() throws {
    let s = try status(tier: .pro)
    let empty = tempDir()
    for tier in MachineTier.allCases {
        let c = EngineCatalog(status: s, tier: tier, enginesDirectory: empty)
        #expect(c.tier == tier)
        #expect(c.rows.map(\.id) == manifest.entries.map(\.id), "every manifest entry is a row, in manifest order")
        for r in c.rows {
            let e = try #require(manifest.entry(r.id))
            let needed = manifest.tier(of: e)
            if e.planned {
                #expect(r.state == .planned && r.group == .planned && r.action == .nothing, "\(r.id)")
            } else if let needed, needed > tier {
                #expect(r.state == .needsTier(needed), "\(r.id) on \(tier) needs \(needed)")
                #expect(r.action != .install, "\(r.id): nothing above the tier is offered for install")
            } else {
                if case .needsTier = r.state { Issue.record("\(r.id) is within \(tier) but shown as needing a tier") }
            }
            if e.install.method == "cloud" { #expect(r.group == .cloud) }
            else if let needed, !e.planned { #expect(r.group.rawValue == needed.rawValue, "\(r.id) grouped under its tier") }
            #expect(r.disk == manifest.diskText(r.id))
            #expect(r.nonCommercial == e.nonCommercial && r.licence == e.licence)
        }
    }
    // The spec's table: base shows the Medium and Pro engines as needing their tier, pro none of them.
    let base = EngineCatalog(status: s, tier: .base, enginesDirectory: empty)
    let pro = EngineCatalog(status: s, tier: .pro, enginesDirectory: empty)
    let medium = EngineCatalog(status: s, tier: .medium, enginesDirectory: empty)
    #expect(base.row("whisperx")?.state == .needsTier(.medium) && base.row("comfyui")?.state == .needsTier(.pro))
    #expect(medium.row("whisperx")?.state != .needsTier(.medium) && medium.row("voice-training")?.state == .needsTier(.pro))
    #expect(!pro.rows.contains { if case .needsTier = $0.state { true } else { false } })
    #expect(base.row("aligner-it")?.nonCommercial == true)
}

@Test func theActionFollowsTheInstallMethod() throws {
    let empty = tempDir()
    let missing = EngineCatalog(status: uniformStatus("missing"), enginesDirectory: empty)
    for r in missing.rows {
        let e = try #require(manifest.entry(r.id))
        switch (e.planned, e.install.method) {
        case (true, _): #expect(r.action == .nothing)
        case (_, "installer"), (_, "homebrew"): #expect(r.action == .install, "\(r.id)")
        case (_, "manual"), (_, "cloud"): #expect(r.action == .howTo(e.install.steps ?? []), "\(r.id)")
        case (_, "firstUse"): #expect(r.action == .firstUse(e.install.steps ?? []), "\(r.id)")
        default: #expect(r.action == .nothing, "\(r.id) (\(e.install.method))")
        }
    }
    #expect(missing.row("comfyui")?.action == .howTo(manifest.entry("comfyui")!.install.steps!))
    #expect(missing.row("higgsfield").map { if case .howTo = $0.action { true } else { false } } == true)
    // Installed: Rimuovi only where the engine's files are in the engines folder.
    let dir = tempDir()
    let aligner = dir.appendingPathComponent(manifest.entry("aligner-it")!.files[0])
    try FileManager.default.createDirectory(at: aligner.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: aligner)
    let installed = EngineCatalog(status: uniformStatus("installed"), enginesDirectory: dir)
    #expect(installed.row("aligner-it")?.action == .remove)
    #expect(installed.row("aligner-fr")?.action == .nothing, "nothing of it on disk here: nothing to remove")
    #expect(installed.row("ffmpeg")?.action == .nothing, "Homebrew's own: never removed from here")
    #expect(installed.row("vision")?.action == .nothing)
}

@Test func removeDeletesOnlyTheEnginesOwnFiles() throws {
    let dir = tempDir()
    let fm = FileManager.default
    func make(_ rel: String) throws -> URL {
        let u = dir.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: u)
        return u
    }
    let it = try make(manifest.entry("aligner-it")!.files[0])
    let fr = try make(manifest.entry("aligner-fr")!.files[0])
    let venv = try make("whisperx/.venv/bin/python")
    let outside = dir.deletingLastPathComponent().appendingPathComponent("regista-outside-\(UUID().uuidString)")
    try Data("keep".utf8).write(to: outside)
    defer { try? fm.removeItem(at: outside) }

    let removed = try EngineCatalog.remove("aligner-it", in: dir)
    #expect(removed.map(\.lastPathComponent) == [it.lastPathComponent])
    #expect(!fm.fileExists(atPath: it.path))
    #expect(fm.fileExists(atPath: fr.path) && fm.fileExists(atPath: venv.path) && fm.fileExists(atPath: outside.path))
    // A folder engine goes as a whole, and only it.
    let ct2 = try make("whisperx/models/ct2-whisper-large-v3-turbo/model.bin")
    try EngineCatalog.remove("faster-whisper-model", in: dir)
    #expect(!fm.fileExists(atPath: ct2.deletingLastPathComponent().path) && fm.fileExists(atPath: fr.path))
    // Nothing of it there: nothing happens.
    #expect(try EngineCatalog.remove("aligner-it", in: dir).isEmpty)
    #expect(throws: CommandError.self) { try EngineCatalog.remove("no-such-engine", in: dir) }
    // The manifest cannot name a file outside the engines folder.
    let bad = String(decoding: PackageResources.engines_manifest_json, as: UTF8.self)
        .replacingOccurrences(of: "\"files\": [\"deepfilternet\"]", with: "\"files\": [\"../profiles\"]")
    #expect(throws: EngineManifest.ParseError.self) {
        try EngineManifest.parse(manifest: Data(bad.utf8), lock: String(decoding: PackageResources.engines_lock, as: UTF8.self))
    }
    // The confirmation says what stops working: the engine's own unlocks, then those of what needs it.
    let stops = EngineCatalog.stopsWorking("whisperx")
    #expect(stops.starts(with: manifest.entry("whisperx")!.unlocks))
    #expect(EngineCatalog.dependents(of: "whisperx").map(\.id).contains("aligner-it"))
    #expect(stops.contains("precise word timings in Italian"))
}

@Test func everyFileOfTheManifestIsWhereTheAppLooks() {
    // The removal paths and the paths the app and the installer use agree.
    let c = EngineConfig()
    let managed = EngineConfig.expand(EngineConfig.managedDirectory)
    func rel(_ p: String) -> String { String(EngineConfig.expand(p).dropFirst(managed.count + 1)) }
    #expect(manifest.entry("whisper.cpp")!.files.contains(rel(c.whisperCpp).components(separatedBy: "/bin/")[0]))
    #expect(manifest.entry("whisper-model")!.files == [rel(c.whisperModel)])
    #expect(rel(c.deepFilter).hasPrefix(manifest.entry("deepfilternet")!.files[0] + "/"))
    #expect(manifest.entry("voxcpm-weights")!.files == [rel(c.voxcpmModel)])
    #expect(manifest.entry("voxcpm")!.files.contains(rel(c.voxcpmScript)))
    #expect(manifest.entry("whisperx")!.files.contains(rel(c.whisperXScript)))
}

// MARK: scripts/install.sh --only

/// A copy of the manifest and lock with a fake engine whose one artifact is a local file (file:// url).
private func fakeInstaller(corrupt: Bool = false) throws -> (env: [String: String], support: URL, payload: URL) {
    let dir = tempDir()
    let payload = dir.appendingPathComponent("payload.bin")
    let bytes = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    try bytes.write(to: payload)
    let sha = try FileDigest.sha256(payload)
    let lock = String(decoding: PackageResources.engines_lock, as: UTF8.self)
        + "fake-engine | 1.0 | 2026-01-01 | 2026-01-20 | \(corrupt ? String(repeating: "0", count: 64) : sha) | 300000 | file://\(payload.path)\n"
    try lock.write(to: dir.appendingPathComponent("engines.lock"), atomically: true, encoding: .utf8)
    var m = try #require(try JSONSerialization.jsonObject(with: Data(PackageResources.engines_manifest_json)) as? [String: Any])
    var engines = try #require(m["engines"] as? [[String: Any]])
    engines.append(["id": "fake-engine", "name": "Fake engine", "role": "test", "unlocks": ["nothing"], "minRamGB": 8,
                    "licence": "MIT", "nonCommercial": false, "install": ["method": "installer", "step": "test"],
                    "files": ["fake/fake-engine.bin"], "artifacts": ["fake-engine"], "optional": true, "dependsOn": [String](),
                    "status": "available"])
    m["engines"] = engines
    try JSONSerialization.data(withJSONObject: m).write(to: dir.appendingPathComponent("manifest.json"))
    let support = dir.appendingPathComponent("support")
    return (["REGISTA_MANIFEST": dir.appendingPathComponent("manifest.json").path, "REGISTA_LOCK": dir.appendingPathComponent("engines.lock").path,
             "REGISTA_SUPPORT_DIR": support.path, "REGISTA_CACHE_DIR": dir.appendingPathComponent("cache").path,
             "REGISTA_ENGINES": support.appendingPathComponent("engines.json").path], support, payload)
}

private func installSh(_ args: [String], env: [String: String] = [:]) throws -> (status: Int32, output: String) {
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), [repo.appendingPathComponent("scripts/install.sh").path] + args,
                               environment: env)
    return (r.status, r.stdoutText + r.stderrText)
}

@Test func installOnlyRefusesWhatItCannotInstall() throws {
    let (env, support, _) = try fakeInstaller()
    let unknown = try installSh(["--only", "no-such-engine"], env: env)
    #expect(unknown.status != 0 && unknown.output.contains("unknown engine id 'no-such-engine'"))
    for id in ["vision", "comfyui", "higgsfield", "sfx-library", "sam-3.1"] {
        let r = try installSh(["--only", id, "--check"], env: env)
        #expect(r.status != 0, "\(id) is not the installer's: \(r.output)")
    }
    // Every installer / Homebrew entry has a step (--check: the plan, nothing done).
    for e in manifest.entries where !e.planned && ["installer", "homebrew"].contains(e.install.method) {
        let r = try installSh(["--only", e.id, "--check", "--tier", "pro"], env: env)
        #expect(r.status == 0, "\(e.id): \(r.output)")
    }
    // Above the tier: refused.
    let low = try installSh(["--only", "whisperx", "--check", "--tier", "base"], env: env)
    #expect(low.status != 0 && low.output.contains("needs the medium tier"))
    #expect(!FileManager.default.fileExists(atPath: support.path), "--check and refusals create nothing")
}

@Test func installOnlyInstallsAFakeEngineWithItsSha256Checked() throws {
    let (env, support, payload) = try fakeInstaller()
    let r = try installSh(["--only", "fake-engine"], env: env)
    #expect(r.status == 0, "\(r.output)")
    let file = support.appendingPathComponent("engines/fake/fake-engine.bin")
    #expect(try FileDigest.sha256(file) == FileDigest.sha256(payload))
    #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("engines.json").path), "no engines.json key for it")
    // A wrong sha256: refused, nothing installed.
    let (badEnv, badSupport, _) = try fakeInstaller(corrupt: true)
    let bad = try installSh(["--only", "fake-engine"], env: badEnv)
    #expect(bad.status != 0 && bad.output.contains("SHA256 mismatch"))
    #expect(!FileManager.default.fileExists(atPath: badSupport.appendingPathComponent("engines/fake/fake-engine.bin").path))
}

@Test func theInstallerJobReportsProgressAndFailsWithTheInstallersReason() throws {
    let (env, support, _) = try fakeInstaller()
    let installer = EngineInstaller(script: repo.appendingPathComponent("scripts/install.sh"), environment: env)
    final class Log: @unchecked Sendable { let lock = NSLock(); var details: [String] = [] }
    let log = Log()
    let job = CommandJob { _, detail in if let detail { log.lock.withLock { log.details.append(detail) } } }
    try CommandJob.$current.withValue(job) { try installer.install("fake-engine") }
    #expect(FileManager.default.fileExists(atPath: support.appendingPathComponent("engines/fake/fake-engine.bin").path))
    #expect(log.lock.withLock { log.details.contains { $0.contains("payload.bin") } }, "the download is the job's detail: \(log.details)")
    #expect(throws: CommandError.self) { try installer.install("no-such-engine") }
    do { try installer.install("no-such-engine") } catch { #expect("\(error)".contains("unknown engine id")) }
    // curl's bar.
    #expect(CommandJob.curlPercent("######################                     45.3%") == 45.3)
    #expect(CommandJob.curlPercent("  ↓ model.bin (1.6 GB)") == nil)
}
