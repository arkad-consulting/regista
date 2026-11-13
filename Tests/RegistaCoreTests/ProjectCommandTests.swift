import Foundation
import Testing
@testable import RegistaCore

@Test func newProjectHasSettingsAndResetsHistory() throws {
    let e = try editingEngine()
    try e.execute("project.new", params: ["name": "ntsc", "width": 1920, "height": 1080, "fps": 29.97])
    let p = try #require(e.project)
    #expect(p.name == "ntsc")
    #expect(p.settings.width == 1920)
    #expect(p.settings.frameRate == Rational(30000, 1001))
    #expect(p.tracks.isEmpty)
    #expect(e.context.history.undoStack.isEmpty)
    #expect(e.isDirty)
}

@Test func newRefusesToClobberAnExistingProject() throws {
    let dir = tempDir()
    let e = try editingEngine(directory: dir)
    try e.execute("project.save")
    #expect(throws: CommandError.self) { try e.execute("project.new", params: ["name": "test", "directory": .string(dir.path)]) }
}

@Test func saveAndOpenRoundTrip() throws {
    let dir = tempDir()
    let e = try editingEngine(directory: dir)
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": 2, "sourceIn": 1, "sourceOut": 5.5])
    let saved = try e.execute("project.save")
    let folder = dir.appendingPathComponent("test.regista")
    #expect(saved["path"]?.stringValue == folder.path)
    #expect(!e.isDirty)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.json").path))

    let other = Engine(prober: FakeProber())
    try other.execute("project.open", params: ["path": .string(folder.path)])
    #expect(other.project == e.project)
    #expect(other.projectURL == folder)
    // New ids keep counting after a reopen.
    try other.execute("track.add", params: ["kind": "overlay"])
    #expect(other.project?.tracks.last?.id == "t3")
}

@Test func saveAsAndSaveWithoutFolder() throws {
    let e = try editingEngine()   // in memory only
    #expect(throws: CommandError.self) { try e.execute("project.save") }
    let target = tempDir().appendingPathComponent("copy.regista")
    try e.execute("project.save", params: ["path": .string(target.path)])
    #expect(e.projectURL == target)
    #expect(try ProjectStore.load(from: target) == e.project)
}

@Test func openMissingProjectFails() {
    let e = Engine(prober: FakeProber())
    #expect(throws: CommandError.self) { try e.execute("project.open", params: ["path": .string(tempDir().path)]) }
}

@Test func stateSummarizesInSeconds() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 12.5])
    let s = try e.execute("project.state")
    #expect(s["name"] == "test")
    #expect(s.value(at: "settings.fps") == 30)
    #expect(s.value(at: "assets.0.video.width") == 1080)
    #expect(s.value(at: "assets.0.video.height") == 1920)
    #expect(s.value(at: "assets.0.duration") == 94.703333)
    #expect(s.value(at: "tracks.0.name") == "V1")
    #expect(s.value(at: "tracks.1.name") == "A1")
    #expect(s.value(at: "tracks.0.clips.0.end") == 12.5)
    #expect(s.value(at: "duration") == 12.5)
    #expect(s.value(at: "history.nextUndo") == "timeline.place")
}

@Test func mediaImportUsesTheProberAndIsUndoable() throws {
    let e = Engine(prober: FakeProber())
    try e.execute("project.new", params: ["name": "m"])
    let path = fakeMedia()
    let r = try e.checkUndoRedo("media.import", ["path": .string(path)])
    #expect(r.value(at: "asset.id") == "a1")
    #expect(r.value(at: "asset.video.fps") == 30)
    #expect(e.project?.assets.first?.duration == MediaTime(value: 56822, timescale: 600))
    // Same path again: no duplicate, no history entry.
    let again = try e.execute("media.import", params: ["path": .string(path)])
    #expect(again["existing"] == true)
    #expect(e.project?.assets.count == 1)
    #expect(throws: CommandError.self) { try e.execute("media.import", params: ["path": "/nope/missing.mov"]) }
}

@Test func trackAddAndSet() throws {
    let e = try editingEngine()
    let r = try e.checkUndoRedo("track.add", ["kind": "video", "index": 0])
    #expect(r.value(at: "track.name") == "V2")
    #expect(e.project?.tracks.first?.kind == .video)
    #expect(e.project?.tracks.map(\.id) == ["t3", "t1", "t2"])
    try e.checkUndoRedo("track.set", ["trackId": "t1", "locked": true, "name": "Main"])
    #expect(e.project?.tracks[1].locked == true)
    #expect(e.project?.tracks[1].name == "Main")
    #expect(throws: CommandError.self) { try e.execute("track.add", params: ["kind": "audio", "index": 9]) }
}

/// project.close (the × of the project tab, S1 #75): refuses unsaved changes unless told to discard them.
@Test func closeRefusesUnsavedChangesUnlessDiscarding() throws {
    let dir = tempDir()
    let e = try editingEngine(directory: dir)
    #expect(e.isDirty)
    #expect(throws: CommandError.self) { try e.execute("project.close") }
    #expect(e.project != nil)
    try e.execute("project.save")
    let r = try e.execute("project.close")
    #expect(r["closed"]?.stringValue == "test")
    #expect(e.project == nil && e.projectURL == nil && !e.isDirty && e.context.history.undoStack.isEmpty)
    // Nothing open: a no-op.
    #expect(try e.execute("project.close")["closed"] == .null)
    // discard: true closes an edited project.
    try e.execute("project.open", params: ["path": .string(dir.appendingPathComponent("test.regista").path)])
    try e.execute("track.add", params: ["kind": "overlay"])
    try e.execute("project.close", params: ["discard": true])
    #expect(e.project == nil)
}

/// S2 #76: the headless engine holds one project. project.list lists it (as tab-1); every project command accepts
/// `project` when it names that project (its path or tab-1) and refuses another one; new / open / list take none.
@Test func headlessEngineListsItsOneProjectAndChecksTheProjectTarget() throws {
    let engine = Engine(prober: FakeProber())
    #expect(try engine.execute("project.list") == ["tabs": [], "active": .null])
    #expect(throws: CommandError.self) { try engine.execute("track.add", params: ["kind": "video", "project": "tab-1"]) }
    let dir = tempDir()
    try engine.execute("project.new", params: ["name": "solo", "directory": .string(dir.path)])
    let path = dir.appendingPathComponent("solo.regista").path
    let list = try engine.execute("project.list")
    #expect(list["active"] == "tab-1")
    #expect(list["tabs"] == [["id": "tab-1", "name": "solo", "path": .string(path), "dirty": true, "active": true, "recording": false]])
    try engine.execute("track.add", params: ["kind": "video", "project": "tab-1"])
    try engine.execute("track.add", params: ["kind": "audio", "project": .string(path)])
    try engine.execute("track.add", params: ["kind": "audio", "project": .string(path + "/project.json")])
    try engine.execute("history.undo", params: ["project": .null])
    #expect(engine.project?.tracks.count == 2)
    // The history keeps the command without the routing parameter.
    #expect(engine.context.history.undoStack.allSatisfy { $0.params["project"] == nil })
    #expect(throws: CommandError.self) { try engine.execute("track.add", params: ["kind": "video", "project": "tab-2"]) }
    #expect(throws: CommandError.self) { try engine.execute("track.add", params: ["kind": "video", "project": "/tmp/other.regista"]) }
    #expect(throws: CommandError.self) { try engine.execute("track.add", params: ["kind": "video", "project": 3]) }
    #expect(throws: CommandError.self) { try engine.execute("project.new", params: ["name": "x", "project": "tab-1"]) }
    #expect(engine.project?.tracks.count == 2)
    #expect(ProjectTarget.accepts("timeline.cut") && !ProjectTarget.accepts("project.open") && !ProjectTarget.accepts("project.list"))
}
