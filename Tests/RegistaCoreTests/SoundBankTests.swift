import Foundation
import Testing
@testable import RegistaCore

// E3 (#55, #33): the sound-effect bank shipped with Regista (Resources/SFX, rendered from earshot) is listed on a fresh
// install, its files match the pinned manifest, sfx.add places a bank sound by name, and one loudness target is used
// everywhere.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Test func theBankIsListedOnAFreshSupportFolder() throws {
    var services = EngineServices.standard()
    services.config.sfxLibrary = tempDir().appendingPathComponent("no-sfx-here").path   // a fresh install: no folder of your own
    let e = Engine(prober: FakeProber(), services: services)
    let r = try e.execute("sfx.library")
    let effects = try #require(r["effects"]?.arrayValue)
    #expect(effects.count >= 150)
    #expect(effects.allSatisfy { $0["source"]?.stringValue == "bank" })
    for g in SoundLibrary.groups {
        #expect(effects.contains { $0["group"]?.stringValue == g }, "group \(g) is empty")
        #expect(try e.execute("sfx.library", params: ["group": .string(g)])["effects"]?.arrayValue?.isEmpty == false)
    }
    #expect(effects.allSatisfy { FileManager.default.fileExists(atPath: $0["path"]?.stringValue ?? "") })
    #expect(try e.execute("sfx.library", params: ["query": "whoosh"])["effects"]?.arrayValue?.count ?? 0 >= 10)
}

@Test func theBankFilesMatchTheirPinnedManifest() throws {
    let dir = repo.appendingPathComponent("Resources/SFX")
    let manifest = dir.appendingPathComponent("manifest.json")
    // engines.lock pins manifest.json (repo: row); the manifest pins every file.
    let row = try #require(EngineManifest.shared.artifact("sfx-bank"))
    #expect(row.url == "repo:Resources/SFX/manifest.json")
    #expect(try FileDigest.sha256(manifest) == row.sha256)
    let sounds = try #require(try JSONValue.parse(Data(contentsOf: manifest))["sounds"]?.objectValue)
    #expect(sounds.count == SoundLibrary.bank().count)
    for (name, v) in sounds {
        let file = dir.appendingPathComponent(v["file"]?.stringValue ?? "")
        #expect(try FileDigest.sha256(file) == v["sha256"]?.stringValue, "\(name) differs from its manifest entry")
    }
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("LICENSE.txt").path))
    #expect(EngineManifest.shared.entry("sfx-bank")?.licence == "MIT")
}

@Test func aBankSoundGoesOnTheSFXTrackByName() throws {
    var services = EngineServices.standard()
    services.config.sfxLibrary = tempDir().path
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "sfx"])
    let name = try #require(SoundLibrary.bank().first { $0.group == "whoosh" }?.name)
    try e.checkUndoRedo("sfx.add", ["name": .string(name), "at": 2.5, "duration": 0.5])
    let track = try #require(e.project!.tracks.first { $0.role == "sfx" })
    #expect(track.clips.count == 1 && track.clips[0].start == t(2.5))
    #expect(abs(track.clips[0].gain! - 20 * log10(0.3)) < 1e-9)                       // the command's default volume
    #expect(e.project!.asset(track.clips[0].assetID)?.path.hasSuffix("Resources/SFX/\(name).m4a") == true)
    #expect(throws: CommandError.self) { try e.execute("sfx.add", params: ["name": "whoosh_fast/nope", "at": 1]) }
}

/// The −15 LUFS / −1.5 dBTP targets live in LoudnessTarget only: no other code line repeats them as a number next to a
/// loudness word (comments and strings are not code: prose may name the target).
@Test func oneLoudnessTargetIsUsedEverywhere() throws {
    let sources = repo.appendingPathComponent("Sources")
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "LoudnessTarget.swift" }
    let words = try NSRegularExpression(pattern: #"(?i)lufs|truepeak|peak|ceiling|integrated|loudness|curve|target|y\("#)
    let numbers = try NSRegularExpression(pattern: #"(?<![\w.])-\s*(1\.5|1\.0|15(\.0)?)(?![\w.])|\+\s*15\b"#)
    var offenders: [String] = []
    for f in files {
        for (i, raw) in try String(contentsOf: f, encoding: .utf8).components(separatedBy: "\n").enumerated() {
            var code = raw
            if let r = code.range(of: "//") { code = String(code[..<r.lowerBound]) }
            code = code.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression)
            let ns = code as NSString
            let range = NSRange(location: 0, length: ns.length)
            if words.firstMatch(in: code, range: range) != nil, numbers.firstMatch(in: code, range: range) != nil {
                offenders.append("\(f.lastPathComponent):\(i + 1): \(raw.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    #expect(offenders.isEmpty, "use LoudnessTarget instead of: \(offenders.joined(separator: "\n"))")
    #expect(LoudnessTarget.integrated == -15 && LoudnessTarget.truePeak == -1.5)
    #expect(LoudnessTarget.verdict(integrated: -15.4) == .ok && LoudnessTarget.verdict(integrated: -17) == .tooQuiet)
    #expect(LoudnessTarget.verdict(integrated: -12) == .tooLoud && LoudnessTarget.verdict(integrated: -.infinity) == .unmeasured)
    #expect(LoudnessTarget.peakOver(-1.0) && !LoudnessTarget.peakOver(-1.5) && !LoudnessTarget.peakOver(-.infinity))
}
