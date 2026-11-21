import Foundation
import Testing
@testable import RegistaCore

// media.remove (#142): a file taken out of the project from its Media tile.

/// The editing engine with a second file (a2) beside the take (a1): a1 on V1 with its linked sound on A1 and once more
/// on V1, a2 on V1 after them.
private func twoFiles() throws -> (Engine, take: String, other: String) {
    let e = try editingEngine()
    let other = fakeMedia("other.mov")
    try e.execute("media.import", params: ["path": .string(other)])
    let picture = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": 0, "sourceIn": 0, "sourceOut": 4]).value(at: "clip.id")?.stringValue ?? ""
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "start": 0, "sourceIn": 0, "sourceOut": 4, "linkTo": .string(picture)])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": 6, "sourceIn": 10, "sourceOut": 12])
    try e.execute("timeline.place", params: ["assetId": "a2", "trackId": "t1", "start": 12, "sourceIn": 0, "sourceOut": 3])
    return (e, e.project!.asset("a1")!.path, other)
}

@Test func mediaRemoveTakesTheAssetAndItsClipsAndLeavesTheGaps() throws {
    let (e, take, other) = try twoFiles()
    let modified = try FileManager.default.attributesOfItem(atPath: take)[.modificationDate] as? Date
    let r = try e.checkUndoRedo("media.remove", ["assetId": "a1"])
    #expect(r["name"] == "take.mov" && r["removedClips"] == 3, "\(r)")
    let p = try #require(e.project)
    #expect(p.assets.map(\.id) == ["a2"])
    #expect(p.tracks.flatMap(\.clips).map(\.assetID) == ["a2"], "a clip of a1 is left: \(p.tracks.flatMap(\.clips))")
    // The gaps stay: a2's clip has not moved.
    #expect(p.tracks[0].clips.first?.start == t(12))
    // The file is untouched, the other file too.
    #expect(FileManager.default.fileExists(atPath: take) && FileManager.default.fileExists(atPath: other))
    #expect(try FileManager.default.attributesOfItem(atPath: take)[.modificationDate] as? Date == modified)
    #expect(e.project.map { $0.tracks.flatMap(\.clips).count } == 1)
    let s = try e.execute("project.state")
    #expect(s.value(at: "history.nextUndo") == "media.remove")
}

@Test func mediaRemoveOfAnUnusedFileRemovesNoClip() throws {
    let e = try editingEngine()
    try e.execute("media.import", params: ["path": .string(fakeMedia("unused.mov"))])
    let r = try e.checkUndoRedo("media.remove", ["assetId": "a2"])
    #expect(r["removedClips"] == 0 && r["name"] == "unused.mov")
    #expect(e.project?.assets.map(\.id) == ["a1"])
}

@Test func mediaRemoveRefusesAnUnknownAssetAndALockedTrack() throws {
    let (e, _, _) = try twoFiles()
    #expect(throws: CommandError.self) { try e.execute("media.remove", params: ["assetId": "a9"]) }
    try e.execute("track.set", params: ["trackId": "t2", "locked": true])
    let before = e.project
    #expect(throws: CommandError.self) { try e.execute("media.remove", params: ["assetId": "a1"]) }
    #expect(e.project == before, "a refused removal changed the project")
}
