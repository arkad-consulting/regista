import Foundation
import Testing
@testable import RegistaCore

// #139: a project made without a folder keeps what Regista generates for it in a temporary media folder until its first
// save; that save moves those files into <project>.regista/media and every path follows, so the saved project never
// points into the temporary folder. The person's own files stay where they are.

/// The absolute paths a saved project.json names.
private func paths(in folder: URL) throws -> [String] {
    let text = try String(contentsOf: folder.appendingPathComponent(ProjectStore.fileName), encoding: .utf8)
    let re = try NSRegularExpression(pattern: #""(/[^"]+)""#)
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } }
}

@Test func aFirstSaveTakesTheGeneratedFilesIntoTheProject() throws {
    let fm = FileManager.default
    let fakes = FakeServices()
    let e = Engine(prober: FakeProber(), services: fakes.make())
    try e.execute("project.new", params: ["name": "first"])
    let original = fakeMedia()
    try e.execute("media.import", params: ["path": .string(original)])
    try e.execute("media.extractAudio", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "audio"])   // an edit after the extraction, undone after the save
    let before = try #require(e.project?.assets[0].analysis?.audio)
    let scratch = URL(fileURLWithPath: before.speech).deletingLastPathComponent()
    #expect(scratch.path.hasPrefix(TemporaryFolder.url.path) && scratch.lastPathComponent.hasPrefix("regista-media-"))
    // An analysis file that names a generated file (as a sidecar can), escaped the way JSONEncoder writes slashes.
    let sidecar = scratch.appendingPathComponent("a1-notes.json")
    try Data(#"{"audio":"\#(before.working.replacingOccurrences(of: "/", with: "\\/"))","source":"\#(original)"}"#.utf8).write(to: sidecar)

    let folder = tempDir().appendingPathComponent("first.regista")
    let media = folder.appendingPathComponent("media")
    // A file of that name already in the folder is kept: the moved one gets a free name.
    try fm.createDirectory(at: media, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: media.appendingPathComponent("a1-speech16k.wav"))

    let saved = try e.execute("project.save", params: ["path": .string(folder.path)])
    #expect(saved["movedMedia"] == 3, "\(saved.text())")
    let audio = try #require(e.project?.assets[0].analysis?.audio)
    #expect(audio.speech == media.appendingPathComponent("a1-speech16k-2.wav").path, "\(audio.speech)")
    #expect(audio.working == media.appendingPathComponent("a1-work48k.wav").path, "\(audio.working)")
    #expect(fm.fileExists(atPath: audio.speech) && fm.fileExists(atPath: audio.working))
    #expect(try String(contentsOf: media.appendingPathComponent("a1-speech16k.wav"), encoding: .utf8) == "keep")
    #expect(!fm.fileExists(atPath: scratch.path), "the temporary media folder is left")
    // The person's file is where it was, untouched.
    #expect(e.project?.assets[0].path == original && fm.fileExists(atPath: original))
    // The saved project names no path in the temporary media folder: only the original and the project's own files.
    let named = try paths(in: folder)
    #expect(!named.isEmpty && named.allSatisfy { $0 == original || $0.hasPrefix(folder.path + "/") }, "\(named)")
    #expect(!named.contains { $0.contains("regista-media-") })
    let notes = try String(contentsOf: media.appendingPathComponent("a1-notes.json"), encoding: .utf8)
    #expect(notes.contains(audio.working.replacingOccurrences(of: "/", with: "\\/")) && notes.contains(original) && !notes.contains("regista-media-"), "\(notes)")

    // Undo after the save: the earlier states name the moved files too.
    try e.execute("history.undo")
    #expect(e.project?.assets[0].analysis?.audio == audio && e.project?.tracks.count == 0)
    try e.execute("history.undo")
    #expect(e.project?.assets[0].analysis?.audio == nil)
    try e.execute("history.redo")
    #expect(e.project?.assets[0].analysis?.audio == audio)

    // Reopened elsewhere: the files are found.
    let again = Engine(prober: FakeProber(), services: fakes.make())
    try again.execute("project.open", params: ["path": .string(folder.path)])
    let reopened = try #require(again.project?.assets[0].analysis?.audio)
    #expect(reopened == audio && fm.fileExists(atPath: reopened.speech))
    // The next generated file goes straight into the project's folder.
    try again.execute("media.extractAudio", params: ["assetId": "a1", "force": true])
    #expect(again.project?.assets[0].analysis?.audio?.working.hasPrefix(media.path + "/") == true)
}

/// Save as from a project that already has a folder moves nothing: its files stay in the first folder.
@Test func aSaveAsOfASavedProjectMovesNothing() throws {
    let fm = FileManager.default
    let fakes = FakeServices()
    let e = Engine(prober: FakeProber(), services: fakes.make())
    try e.execute("project.new", params: ["name": "kept"])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("media.extractAudio", params: ["assetId": "a1"])
    let first = tempDir().appendingPathComponent("kept.regista")
    try e.execute("project.save", params: ["path": .string(first.path)])
    let audio = try #require(e.project?.assets[0].analysis?.audio)
    #expect(audio.speech.hasPrefix(first.path + "/media/"))

    let second = tempDir().appendingPathComponent("copy.regista")
    let r = try e.execute("project.save", params: ["path": .string(second.path)])
    #expect(r["movedMedia"] == nil)
    #expect(e.project?.assets[0].analysis?.audio == audio && fm.fileExists(atPath: audio.speech))
    #expect(!fm.fileExists(atPath: second.appendingPathComponent("media").path))
}

/// A project made with a folder never had a temporary media folder: its save moves nothing either.
@Test func aProjectMadeWithAFolderSavesAsBefore() throws {
    let fakes = FakeServices()
    let e = Engine(prober: FakeProber(), services: fakes.make())
    let dir = tempDir()
    try e.execute("project.new", params: ["name": "placed", "directory": .string(dir.path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("media.extractAudio", params: ["assetId": "a1"])
    let audio = try #require(e.project?.assets[0].analysis?.audio)
    let r = try e.execute("project.save")
    #expect(r["movedMedia"] == nil && e.project?.assets[0].analysis?.audio == audio)
    #expect(audio.speech.hasPrefix(dir.appendingPathComponent("placed.regista/media/").path))
}
