import Foundation
import Testing
@testable import RegistaCore

// The engine manifest (scripts/engines.manifest.json + scripts/engines.lock, issue #58): one source for the installer,
// the app and docs/engines.md.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let manifest = EngineManifest.shared
private let manifestIDs = Set(manifest.entries.map(\.id))

/// engines.status on a services set with every standard provider, the way the app and regista-mcp build it.
private func statusIDs(tier: MachineTier) throws -> (engines: [JSONValue], components: [JSONValue]) {
    var fakes = FakeServices()
    fakes.tier = tier
    var services = fakes.make()
    let config = EngineConfig()
    for g in [ComfyUIProvider(config: config), HiggsfieldProvider(config: config) as GeneratorProvider,
              VoxCPMProvider(config: config, profiles: ProfileStore(directory: tempDir()))] { services.generators[g.id] = g }
    let s = try Engine(prober: FakeProber(), services: services).execute("engines.status")
    return (try #require(s["engines"]?.arrayValue), try #require(s["components"]?.arrayValue))
}

@Test func everyEngineTheAppKnowsIsInTheManifestAndTheReverse() throws {
    let (engines, components) = try statusIDs(tier: .pro)
    let reported = (engines + components).compactMap { $0["id"]?.stringValue }
    #expect(Set(reported) == manifestIDs, "reported but not in the manifest: \(Set(reported).subtracting(manifestIDs)); in the manifest but not reported: \(manifestIDs.subtracting(reported))")
    #expect(reported.count == Set(reported).count, "an id is reported twice")
    // Every live engine the app checks, every provider and every transcriber is a manifest entry.
    let config = EngineConfig()
    let providers: [GeneratorProvider] = [ComfyUIProvider(config: config), HiggsfieldProvider(config: config),
                                          VoxCPMProvider(config: config, profiles: ProfileStore(directory: tempDir()))]
    for p in providers {
        let e = try #require(manifest.entry(p.id), "provider \(p.id) not in the manifest")
        #expect(p.minimumTier == manifest.tier(of: e))
    }
    for t in [WhisperCppTranscriber.engineID, WhisperXTranscriber.engineID] {
        #expect(manifest.entry(t) != nil, "transcriber \(t) not in the manifest")
    }
    // Every manifest entry marked available is checked by the app (installed / missing), except the ones it cannot see.
    let notChecked = Set(components.filter { $0["state"] == "notChecked" }.compactMap { $0["id"]?.stringValue })
    #expect(notChecked == ["comfyui-z-image", "comfyui-wan22", "comfyui-ace-step", "comfyui-upscale"])
    let planned = Set(components.filter { $0["state"] == "planned" }.compactMap { $0["id"]?.stringValue })
    #expect(planned == Set(manifest.entries.filter(\.planned).map(\.id)))
}

@Test func enginesStatusKeepsItsFieldsAndAddsTheManifestFacts() throws {
    let (engines, components) = try statusIDs(tier: .base)
    for e in engines {
        for k in ["id", "role", "minimumTier", "available", "enabled", "name", "unlocks", "minRamGB", "diskGB", "licence", "install", "state"] {
            #expect(e[k] != nil, "\(e["id"]?.stringValue ?? "?") has no \(k)")
        }
    }
    let wx = try #require(engines.first { $0["id"] == "whisperx" })
    #expect(wx["minimumTier"] == "medium" && wx["enabled"] == false && wx["minRamGB"] == 16)
    #expect(wx["tierReason"]?.stringValue?.contains("medium tier (16 GB)") == true)
    let it = try #require(components.first { $0["id"] == "aligner-it" })
    #expect(it["nonCommercial"] == true && it["licence"] == "CC-BY-NC-4.0")
    let sam = try #require(components.first { $0["id"] == "sam-3.1" })
    #expect(sam["state"] == "planned" && sam["enabled"] == false && sam["reason"] != nil)
    let train = try #require(components.first { $0["id"] == "voice-training" })
    #expect(train["minimumTier"] == "pro" && train["tierReason"] != nil)
}

@Test func everyTierAndNameUsedInTheSourcesIsInTheManifest() throws {
    let sources = repo.appendingPathComponent("Sources")
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
    #expect(files.count > 50)
    let lookups = try NSRegularExpression(pattern: #"(minimumTier|entry|diskText)\("([^"\\]+)"\)"#)
    let artifacts = try NSRegularExpression(pattern: #"artifact\("([^"\\]+)"\)"#)
    let literalTier = try NSRegularExpression(pattern: #"minimumTier\s*[:=][^\n]*MachineTier\.(base|medium|pro)|minimumTier\s*=\s*\.(base|medium|pro)"#)
    let size = try NSRegularExpression(pattern: #"[0-9][0-9.,]*\s?(GB|GiB)\b"#)
    var checked = 0
    for f in files {
        let text = try String(contentsOf: f, encoding: .utf8)
        let range = NSRange(text.startIndex..., in: text)
        for m in lookups.matches(in: text, range: range) {
            checked += 1
            let id = String(text[Range(m.range(at: 2), in: text)!])
            #expect(manifestIDs.contains(id), "\(f.lastPathComponent): \(id) is not in scripts/engines.manifest.json")
        }
        for m in artifacts.matches(in: text, range: range) {
            let id = String(text[Range(m.range(at: 1), in: text)!])
            #expect(manifest.artifact(id) != nil, "\(f.lastPathComponent): \(id) is not in scripts/engines.lock")
        }
        guard f.path.contains("/RegistaCore/") else { continue }   // the UI formats the RAM it reads from engines.status
        #expect(literalTier.firstMatch(in: text, range: range) == nil, "\(f.lastPathComponent): a hard-coded minimum tier (take it from the manifest)")
        if f.lastPathComponent != "EngineManifest.swift" {
            let hits = size.matches(in: text, range: range).map { String(text[Range($0.range, in: text)!]) }
            #expect(hits.isEmpty, "\(f.lastPathComponent): hard-coded sizes \(hits) (take them from the manifest)")
        }
    }
    #expect(checked >= 3, "the scan found only \(checked) manifest lookups: the pattern no longer matches the sources")
}

@Test func tierFromRAMAndForcedTier() {
    #expect(manifest.tier(forMemoryGB: 8) == .base)
    #expect(manifest.tier(forMemoryGB: 16) == .medium)
    #expect(manifest.tier(forMemoryGB: 15.8) == .medium)   // macOS reports a little less than 16 GiB on some models
    #expect(manifest.tier(forMemoryGB: 24) == .medium)
    #expect(manifest.tier(forMemoryGB: 32) == .pro)
    #expect(manifest.tier(forMemoryGB: 64) == .pro)
    let gib: UInt64 = 1_073_741_824
    #expect(MachineTier.detect(physicalMemory: 8 * gib) == .base)
    #expect(MachineTier.detect(physicalMemory: 16 * gib) == .medium)
    #expect(MachineTier.detect(physicalMemory: 32 * gib) == .pro)
    #expect(MachineTier.detect(physicalMemory: 64 * gib) == .pro)
    var forced = EngineConfig()
    forced.tier = "base"
    if ProcessInfo.processInfo.environment["REGISTA_TIER"] == nil { #expect(MachineTier.resolve(forced) == .base) }
    #expect(manifest.tiers.map(\.ramGB) == [8, 16, 32])
    // Entry tiers are derived from minRamGB.
    #expect(manifest.minimumTier("whisper.cpp") == .base)
    #expect(manifest.minimumTier("voxcpm") == .medium)
    #expect(manifest.minimumTier("voice-training") == .pro)
    #expect(manifest.minimumTier("comfyui") == .pro)
    #expect(manifest.minimumTier("higgsfield") == .base)
}

@Test func perTierDiskTotalsMatchTheInstaller() throws {
    let need = MachineTier.allCases.map { manifest.installerNeedGB($0) }
    #expect(need[0] < need[1] && need[1] <= need[2])
    // The installer computes the same numbers with scripts/engines.py (the bash side of the manifest).
    for (i, t) in MachineTier.allCases.enumerated() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", repo.appendingPathComponent("scripts/engines.py").path, "need-gb", t.rawValue]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int(text) == need[i], "\(t): Swift \(need[i]) GB, scripts/engines.py \(text)")
    }
    // Base installs whisper.cpp + its model + DeepFilterNet + Homebrew tools, nothing from Medium.
    let base = Set(manifest.installerEntries(.base).map(\.id))
    #expect(base.isSuperset(of: ["ffmpeg", "whisper.cpp", "whisper-model", "deepfilternet"]) && !base.contains("whisperx"))
    let medium = Set(manifest.installerEntries(.medium).map(\.id))
    #expect(medium.isSuperset(of: ["whisperx", "voxcpm", "voxcpm-weights", "aligner-en", "aligner-pt", "node", "hyperframes"]))
    #expect(medium.isDisjoint(with: ["aligner-it", "aligner-fr"]), "the non-commercial aligners are opt-in (#20)")
    // VoxCPM2 weights = the vox: rows of the lock.
    #expect(manifest.diskBytes(manifest.entry("voxcpm-weights")!) == manifest.artifacts.filter { $0.id.hasPrefix("vox:") }.compactMap(\.size).reduce(0, +))
}

@Test func licencesAreRecordedAndNonCommercialIsMarked() {
    for e in manifest.entries {
        #expect(!e.licence.trimmingCharacters(in: .whitespaces).isEmpty, "\(e.id) has no licence")
        let words = e.licence.replacingOccurrences(of: "-", with: " ").split(separator: " ")
        if words.contains("NC") || e.licence.lowercased().contains("non-commercial") {
            #expect(e.nonCommercial, "\(e.id): \(e.licence) is non-commercial")
        }
    }
    #expect(manifest.entries.filter(\.nonCommercial).map(\.id).sorted() == ["aligner-fr", "aligner-it"])
    // Every lock row belongs to an entry; every entry with a download has a licence.
    let named = Set(manifest.entries.flatMap { manifest.artifacts(of: $0).map(\.id) })
    #expect(Set(manifest.artifacts.map(\.id)) == named)
    // Every aligner is pinned (M3 #60): nothing is left to download unpinned at first use.
    for lang in ["en", "pt", "it", "fr"] { #expect(manifest.entry("aligner-\(lang)")?.install.method == "installer") }
}

@Test func manifestParsingErrorsAreReadable() throws {
    let lock = "a | 1 | - | - | - | 10 | https://x/a\n"
    func error(_ json: String, lock: String = lock) -> String {
        do { _ = try EngineManifest.parse(manifest: Data(json.utf8), lock: lock); return "parsed" }
        catch { return "\(error)" }
    }
    let tiers = #""tiers": [{"id": "base", "name": "Base", "ramGB": 8, "detectFromGB": 0}, {"id": "medium", "name": "Medium", "ramGB": 16, "detectFromGB": 14}, {"id": "pro", "name": "Pro", "ramGB": 32, "detectFromGB": 28}], "diskMarginGB": 2"#
    let good = #"{"id": "x", "name": "X", "role": "r", "unlocks": [], "minRamGB": 8, "licence": "MIT", "nonCommercial": false, "install": {"method": "installer"}, "artifacts": ["a"], "optional": false, "dependsOn": [], "status": "available"}"#
    #expect(error("{\(tiers), \"engines\": [\(good)]}") == "parsed")
    let noLicence = good.replacingOccurrences(of: #""licence": "MIT", "#, with: "")
    let e1 = error("{\(tiers), \"engines\": [\(good.replacingOccurrences(of: "\"x\"", with: "\"y\"")), \(noLicence)]}")
    #expect(e1.contains("engines.manifest.json") && e1.contains("entry 2 (x)") && e1.contains("'licence' missing"), "\(e1)")
    let e2 = error("{\(tiers), \"engines\": [")
    #expect(e2.hasPrefix("engines.manifest.json"), "\(e2)")
    let e3 = error("{\(tiers), \"engines\": [\(good.replacingOccurrences(of: #"["a"]"#, with: #"["b"]"#))]}")
    #expect(e3.contains("x: artifact b is not in engines.lock"), "\(e3)")
    let e4 = error("{\(tiers), \"engines\": [\(good)]}", lock: "a | 1 | -\n")
    #expect(e4.contains("engines.lock line 1"), "\(e4)")
    let e5 = error("{\(tiers), \"engines\": [\(good.replacingOccurrences(of: #""minRamGB": 8"#, with: #""minRamGB": null"#))]}")
    #expect(e5.contains("minRamGB null is only allowed for planned entries"), "\(e5)")
}
