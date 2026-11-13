import Foundation
import Testing
@testable import RegistaCore

/// Engine with the whole asset on V1 (c1) and A1 (c2).
private func placedEngine() throws -> Engine {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2"])
    return e
}

@Test func placeAppendsAndChecksRoom() throws {
    let e = try editingEngine()
    try e.checkUndoRedo("timeline.place", ["assetId": "a1", "trackId": "t1", "sourceIn": 10, "sourceOut": 20])
    try e.checkUndoRedo("timeline.place", ["assetId": "a1", "trackId": "t1", "sourceIn": 30, "sourceOut": 35])
    #expect(e.clips().map(\.start) == [t(0), t(10)])
    #expect(e.clips()[1].end == t(15))
    // Occupied spot, bad ranges, wrong track kinds.
    #expect(throws: CommandError.self) { try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": 12]) }
    #expect(throws: CommandError.self) { try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 5, "sourceOut": 5]) }
    #expect(throws: CommandError.self) { try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 100]) }
    try e.execute("track.add", params: ["kind": "caption"])
    #expect(throws: CommandError.self) { try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t3"]) }
    try e.execute("media.import", params: ["path": .string(fakeMedia("voice.wav"))])
    #expect(throws: CommandError.self) { try e.execute("timeline.place", params: ["assetId": "a2", "trackId": "t1"]) }
    try e.execute("timeline.place", params: ["assetId": "a2", "trackId": "t2"])
}

@Test func placeSnapsToTheFrameGrid() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": 1.01, "sourceOut": 2])
    #expect(e.clips()[0].start == t(1))
}

@Test func cutSplitsEveryTrackByDefault() throws {
    let e = try placedEngine()
    let r = try e.checkUndoRedo("timeline.cut", ["at": 10])
    #expect(r.value(at: "cuts.0.left") == "c1")
    #expect(r.value(at: "cuts.0.right") == "c3")
    #expect(r.value(at: "cuts.1.right") == "c4")
    let v = e.clips(0)
    #expect(v.map(\.id) == ["c1", "c3"])
    #expect(v[0].end == t(10))
    #expect(v[1].start == t(10))
    #expect(v[1].sourceIn == t(10))
    #expect(v[1].sourceOut == MediaTime(value: 56822, timescale: 600))
    #expect(e.clips(1).count == 2)
}

@Test func cutTargetsOneClipOrTrack() throws {
    let e = try placedEngine()
    try e.checkUndoRedo("timeline.cut", ["at": 5, "clipId": "c1"])
    #expect(e.clips(0).count == 2)
    #expect(e.clips(1).count == 1)
    try e.checkUndoRedo("timeline.cut", ["at": 7, "trackId": "t2"])
    #expect(e.clips(1).count == 2)
    #expect(throws: CommandError.self) { try e.execute("timeline.cut", params: ["at": 5, "clipId": "c1"]) }   // on the edge
    #expect(throws: CommandError.self) { try e.execute("timeline.cut", params: ["at": 200]) }
}

@Test func cutSkipsLockedTracks() throws {
    let e = try placedEngine()
    try e.execute("track.set", params: ["trackId": "t2", "locked": true])
    try e.execute("timeline.cut", params: ["at": 10])
    #expect(e.clips(0).count == 2)
    #expect(e.clips(1).count == 1)
    #expect(throws: CommandError.self) { try e.execute("timeline.cut", params: ["at": 20, "clipId": "c2"]) }
}

@Test func trimMovesEdgesWithinTheSource() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": 10, "sourceIn": 5, "sourceOut": 15])
    try e.checkUndoRedo("timeline.trim", ["clipId": "c1", "edge": "start", "to": 12])
    var c = e.clips()[0]
    #expect(c.start == t(12))
    #expect(c.sourceIn == t(7))
    #expect(c.end == t(20))
    try e.checkUndoRedo("timeline.trim", ["clipId": "c1", "edge": "end", "to": 18])
    c = e.clips()[0]
    #expect(c.sourceOut == t(13))
    // Start can't go before source 0 (timeline 5 s), end can't pass the media end.
    #expect(throws: CommandError.self) { try e.execute("timeline.trim", params: ["clipId": "c1", "edge": "start", "to": 4]) }
    try e.execute("timeline.trim", params: ["clipId": "c1", "edge": "start", "to": 5])
    #expect(e.clips()[0].sourceIn == .zero)
    #expect(throws: CommandError.self) { try e.execute("timeline.trim", params: ["clipId": "c1", "edge": "end", "to": 100]) }
    #expect(throws: CommandError.self) { try e.execute("timeline.trim", params: ["clipId": "c1", "edge": "end", "to": 5]) }
}

@Test func trimRefusesOverlapUnlessRippling() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 10])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 20, "sourceOut": 30])
    #expect(throws: CommandError.self) { try e.execute("timeline.trim", params: ["clipId": "c1", "edge": "end", "to": 12]) }
    try e.checkUndoRedo("timeline.trim", ["clipId": "c1", "edge": "end", "to": 12, "ripple": true])
    #expect(e.clips().map(\.start) == [t(0), t(12)])
    // Rippled start trim: c1 stays at 0, loses 3 s, c2 follows.
    try e.checkUndoRedo("timeline.trim", ["clipId": "c1", "edge": "start", "to": 3, "ripple": true])
    #expect(e.clips()[0].start == .zero)
    #expect(e.clips()[0].sourceIn == t(3))
    #expect(e.clips()[1].start == t(9))
}

@Test func moveAcrossTimeAndTracks() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 10])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 10, "sourceOut": 20])
    try e.checkUndoRedo("timeline.move", ["clipId": "c1", "start": 30])
    #expect(e.clips().map(\.id) == ["c2", "c1"])
    #expect(throws: CommandError.self) { try e.execute("timeline.move", params: ["clipId": "c1", "start": 15]) }
    try e.execute("track.add", params: ["kind": "overlay"])
    try e.checkUndoRedo("timeline.move", ["clipId": "c1", "start": 2, "trackId": "t3"])
    #expect(e.project?.tracks[2].clips.first?.start == t(2))
    #expect(e.clips().count == 1)
}

@Test func deleteWithAndWithoutRipple() throws {
    let e = try placedEngine()
    try e.execute("timeline.cut", params: ["at": 10])
    try e.execute("timeline.cut", params: ["at": 20])
    // V1: c1 [0,10) c3 [10,20) c5 [20,94.7); A1: c2 c4 c6.
    #expect(e.clips(0).map(\.id) == ["c1", "c3", "c5"])
    try e.checkUndoRedo("timeline.delete", ["clipId": "c3"])
    #expect(e.clips(0).map(\.start) == [t(0), t(20)])
    try e.execute("history.undo")
    try e.checkUndoRedo("timeline.delete", ["clipIds": ["c3", "c4"], "ripple": true])
    #expect(e.clips(0).map(\.start) == [t(0), t(10)])
    #expect(e.clips(1).map(\.start) == [t(0), t(10)])
    #expect(e.clips(0)[1].sourceIn == t(20))
    #expect(e.project?.duration == MediaTime(value: 56822, timescale: 600) - t(10))
    #expect(throws: CommandError.self) { try e.execute("timeline.delete", params: [:]) }
    #expect(throws: CommandError.self) { try e.execute("timeline.delete", params: ["clipId": "c99"]) }
}

@Test func rippleDeleteOfSeveralClipsOnOneTrack() throws {
    let e = try editingEngine()
    for (i, o) in [(0, 5), (10, 15), (20, 25), (30, 35)] {
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": .number(Double(i)), "sourceOut": .number(Double(o))])
    }
    try e.execute("timeline.delete", params: ["clipIds": ["c1", "c3"], "ripple": true])
    #expect(e.clips().map(\.id) == ["c2", "c4"])
    #expect(e.clips().map(\.start) == [t(0), t(5)])
}

@Test func undoRedoStacks() throws {
    let e = try placedEngine()
    #expect(throws: CommandError.self) { try e.execute("history.redo") }
    try e.execute("timeline.cut", params: ["at": 10])
    try e.execute("timeline.cut", params: ["at": 20])
    let r = try e.execute("history.undo")
    #expect(r["undone"] == "timeline.cut")
    #expect(e.clips().count == 2)
    try e.execute("history.undo")
    #expect(e.clips().count == 1)
    try e.execute("history.redo")
    #expect(e.clips().count == 2)
    // A new edit drops the redo stack.
    try e.execute("timeline.delete", params: ["clipId": "c3"])
    #expect(throws: CommandError.self) { try e.execute("history.redo") }
    // Queries and saves are not recorded.
    let depth = e.context.history.undoStack.count
    try e.execute("project.state")
    #expect(e.context.history.undoStack.count == depth)
    // Undo down to the empty project, then nothing left.
    while (try? e.execute("history.undo")) != nil {}
    #expect(e.project?.assets.isEmpty == true)
    #expect(e.project?.tracks.isEmpty == true)
}
