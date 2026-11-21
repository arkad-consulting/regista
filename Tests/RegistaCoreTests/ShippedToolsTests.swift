import Foundation
import Testing
@testable import RegistaCore

// #107: ffmpeg, ffprobe, whisper-cli and deep-filter shipped inside the app win over engines.json; Settings › Motori shows
// them as part of the app, with nothing to install, and CMake (only there to build whisper.cpp) as not needed.

private func scratch() -> URL {
    let url = TemporaryFolder.url.appendingPathComponent("regista-shipped-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func theShippedHelpersAreFoundByName() throws {
    let dir = scratch()
    for name in ["ffmpeg", "whisper-cli"] {
        let f = dir.appendingPathComponent(name)
        try Data("#!/bin/sh\n".utf8).write(to: f)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
    }
    try Data("not executable".utf8).write(to: dir.appendingPathComponent("ffprobe"))
    #expect(ShippedTools.path("ffmpeg", in: dir) == dir.appendingPathComponent("ffmpeg").path)
    #expect(ShippedTools.path("ffprobe", in: dir) == nil, "a file that cannot run is not a helper")
    #expect(ShippedTools.path("deep-filter", in: dir) == nil)
    #expect(ShippedTools.path("ffmpeg", in: nil) == nil, "a build without helpers")
    #expect(ShippedTools.isShipped(dir.appendingPathComponent("whisper-cli").path, in: dir))
    #expect(!ShippedTools.isShipped(dir.appendingPathComponent("other").path, in: dir), "only the shipped names")
    #expect(!ShippedTools.isShipped("/opt/homebrew/bin/ffmpeg", in: dir))
    // A test process is not an app bundle: no Contents/Helpers of its own.
    #expect(ShippedTools.bundled == nil)
}

@Test func motoriShowsTheShippedEnginesAsPartOfTheApp() throws {
    let status: JSONValue = ["tier": "base", "memoryGB": 8, "engines": [
        ["id": "ffmpeg", "state": "installed", "shipped": true],
        ["id": "ffprobe", "state": "installed", "shipped": true],
        ["id": "whisper.cpp", "state": "installed", "shipped": true],
        ["id": "deepfilternet", "state": "installed", "shipped": true],
        ["id": "whisper-model", "state": "missing"],
    ], "components": [["id": "cmake", "state": "installed", "notNeeded": true]]]
    let c = EngineCatalog(status: status, enginesDirectory: scratch())
    for id in ["ffmpeg", "ffprobe", "whisper.cpp", "deepfilternet"] {
        let r = try #require(c.row(id))
        #expect(r.shipped && r.state == .installed && r.action == .nothing, "\(id): \(r)")
    }
    #expect(c.row("cmake")?.notNeeded == true && c.row("cmake")?.action == .nothing)
    // The Base tier then lacks only the transcription model.
    let missing = c.rows(.base).filter { $0.state == .missing }.map(\.id)
    #expect(missing == ["whisper-model"], "\(missing)")
    // Without the flags (a developer's build): Homebrew's ffmpeg is installed, never removed from here; a missing one installs.
    let dev = EngineCatalog(status: ["tier": "base", "memoryGB": 8, "engines": [["id": "ffmpeg", "state": "missing"]]], enginesDirectory: scratch())
    #expect(dev.row("ffmpeg")?.action == .install && dev.row("ffmpeg")?.shipped == false)
}

@Test func enginesStatusMarksOnlyShippedHelpers() throws {
    // This test process ships nothing (unless REGISTA_HELPERS points at the build cache: the whole suite then runs on
    // the shipped helpers, and every one of them is marked).
    let r = try Engine(prober: FakeProber(), services: FakeServices().make()).execute("engines.status")
    let engines = try #require(r["engines"]?.arrayValue)
    for id in ["ffmpeg", "ffprobe", "whisper.cpp", "deepfilternet"] {
        let e = try #require(engines.first { $0["id"]?.stringValue == id })
        let path = try #require(e["path"]?.stringValue)
        #expect((e["shipped"]?.boolValue ?? false) == ShippedTools.isShipped(path), "\(id): \(e)")
        if e["shipped"] != nil { #expect(e["expectedSha256"] == nil && e["verified"] == nil, "a shipped binary carries the app's signature") }
    }
}
