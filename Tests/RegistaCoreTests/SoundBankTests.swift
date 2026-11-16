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

/// sfx.onCuts (E5 #4): a soft whoosh on the cuts at least 3 s apart, its loudest moment on the cut, one undo step; again
/// changes nothing; remove takes every effect off in one step.
@Test func soundEffectsOnTheCutsInOneSwitch() throws {
    var services = EngineServices.standard()
    services.config.sfxLibrary = tempDir().path
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "sfx"])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    for (start, a) in [(0.0, 0.0), (4.0, 10.0), (5.0, 20.0), (9.0, 30.0)] {   // cuts at 4, 5 (too close) and 9 s
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": .number(start), "sourceIn": .number(a), "sourceOut": .number(a + 1)])
    }
    #expect(throws: CommandError.self) { try e.execute("sfx.onCuts", params: ["name": "whoosh_fast/nope"]) }
    let r = try e.checkUndoRedo("sfx.onCuts", [:])
    let peak = try #require(SoundLibrary.bank().first { $0.name == "whoosh_fast/crisp" }?.peak)
    #expect(r["placed"] == 2)
    let clips = e.project!.tracks.filter { $0.role == "sfx" }.flatMap(\.clips)
    #expect(clips.map { ($0.start.seconds * 1000).rounded() / 1000 } == [4 - peak, 9 - peak].map { ($0 * 1000).rounded() / 1000 })
    #expect(clips.allSatisfy { abs($0.gain! - 20 * log10(0.2)) < 1e-9 })
    let again = try e.execute("sfx.onCuts")
    #expect(again["placed"] == 0 && e.project!.tracks.filter { $0.role == "sfx" }.flatMap(\.clips).count == 2)
    try e.checkUndoRedo("sfx.onCuts", ["remove": true])
    #expect(e.project!.tracks.filter { $0.role == "sfx" }.flatMap(\.clips).isEmpty)
}

/// #23: energico's "whoosh on cuts" lands: the step is under `applied`, and the whooshes sit with their loudest moment on
/// the cuts (≥ 3 s apart), as sfx.onCuts places them.
@Test func energicoPutsItsWhooshOnTheCuts() throws {
    var services = EngineServices.standard()
    services.config.sfxLibrary = tempDir().path
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "energico"])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    for (start, a) in [(0.0, 0.0), (4.0, 10.0), (5.0, 20.0), (9.0, 30.0)] {   // cuts at 4, 5 (too close) and 9 s
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": .number(start), "sourceIn": .number(a), "sourceOut": .number(a + 1)])
    }
    let r = try e.execute("style.apply", params: ["style": "energico"])
    let applied = r["applied"]?.arrayValue?.compactMap(\.stringValue) ?? []
    let skipped = r["skipped"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(applied.contains("whoosh on cuts"), "skipped: \(skipped)")
    #expect(!skipped.contains { $0.hasPrefix("whoosh") })
    let peak = try #require(SoundLibrary.bank().first { $0.name == "whoosh_fast/crisp" }?.peak)
    let clips = e.project!.tracks.filter { $0.role == "sfx" }.flatMap(\.clips)
    #expect(clips.map { (($0.start.seconds + peak) * 100).rounded() / 100 } == [4, 9])
}

/// #23: every sound name a style, a recipe or a command's default names (`group/variant` of a bank group) is in the
/// shipped bank, so no step that places a sound can fail on a name that does not exist.
@Test func everySoundNameTheStylesAndRecipesUseIsInTheBank() throws {
    let bank = Set(SoundLibrary.bank().map(\.name))
    let groups = Set(bank.compactMap { $0.split(separator: "/").first.map(String.init) })
    let roots = ["Sources/RegistaCore", "Sources/RegistaEngines", "Sources/Regista", "handoff"].map { repo.appendingPathComponent($0) }
    let pattern = try NSRegularExpression(pattern: #"(?<![\w/.-])([a-z][a-z_]*)/([a-z][a-z_0-9]*)(?![\w/.-])"#)
    var used: [String: String] = [:]
    for root in roots {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
        for case let f as URL in files where ["swift", "md", "json"].contains(f.pathExtension) {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let ns = text as NSString
                let group = ns.substring(with: m.range(at: 1))
                if groups.contains(group) { used[ns.substring(with: m.range), default: f.lastPathComponent] = f.lastPathComponent }
            }
        }
    }
    #expect(used["whoosh_fast/crisp"] != nil, "sfx.onCuts' default is no longer found by this scan")
    let missing = used.filter { !bank.contains($0.key) }.map { "\($0.key) (\($0.value))" }.sorted()
    #expect(missing.isEmpty, "not in the shipped bank: \(missing.joined(separator: ", "))")
    // energico's whoosh is sfx.onCuts' default sound.
    #expect(bank.contains("whoosh_fast/crisp"))
}
