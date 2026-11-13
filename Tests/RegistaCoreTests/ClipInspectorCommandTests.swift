import Foundation
import Testing
@testable import RegistaCore

// E1 #53: what the clip inspector and the basic gestures need from the command layer — clip.set gain / text / effect
// amount, pictures through media.import, a still placed for 5 s, timeline.duplicate.

/// A prober that answers like ffprobe on a PNG (one video stream, no duration) for picture files.
private struct PictureProber: MediaProber {
    func probe(_ url: URL) throws -> ProbedMedia {
        if Graphics.imageExtensions.contains(url.pathExtension.lowercased()) {
            return ProbedMedia(duration: ImageSource.stillDuration, video: VideoInfo(width: 800, height: 600, frameRate: Rational(25), codec: "png"))
        }
        return try FakeProber().probe(url)
    }
}

@Test func clipSetGainIsForSoundAndOneUndoStep() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceOut": 10])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 10])
    try e.checkUndoRedo("clip.set", ["clipId": "c1", "gain": -6])
    #expect(e.clips(1).first?.gain == -6)
    try e.execute("clip.set", params: ["clipId": "c1", "gain": 0])
    #expect(e.clips(1).first?.gain == nil)
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": "c2", "gain": -3]) }
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": "c1", "gain": 40]) }
}

@Test func clipSetChangesATitlesTextAndAnEffectsAmount() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 10])
    let r = try e.execute("title.add", params: ["text": "Prima", "start": 1])
    let title = try #require(r.value(at: "clip.id")?.stringValue)
    try e.checkUndoRedo("clip.set", ["clipId": .string(title), "text": "Dopo\nriga due"])
    let (tt, tc) = try #require(e.project?.locate(clip: title))
    #expect(e.project?.tracks[tt].clips[tc].title?.text == "Dopo\nriga due")
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": "c1", "text": "no"]) }
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": "c1", "fields": ["title": "no"]]) }

    let fx = try e.execute("effect.add", params: ["clipId": "c1", "kind": "blur", "amount": 1])
    let eid = try #require(fx.value(at: "effectId")?.stringValue)
    try e.checkUndoRedo("clip.set", ["clipId": "c1", "effectId": .string(eid), "effectAmount": 0.4])
    #expect(e.clips(0).first?.effects?.first?.amount == 0.4)
    #expect(throws: CommandError.self) { try e.execute("clip.set", params: ["clipId": "c1", "effectAmount": 0.4]) }
}

@Test func mediaImportMakesAPictureAStillAndTimelinePlaceGivesIt5Seconds() throws {
    let e = Engine(prober: PictureProber())
    try e.execute("project.new", params: ["name": "pictures"])
    let png = fakeMedia("card.png")
    let r = try e.execute("media.import", params: ["path": .string(png)])
    let id = try #require(r.value(at: "asset.id")?.stringValue)
    let asset = try #require(e.project?.asset(id))
    #expect(asset.image?.kind == .still && asset.image?.path == png)
    // The same file through overlay.add reuses that asset.
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": .string(id), "trackId": "t1", "start": 2])
    #expect(e.clips(0).first?.duration.seconds == 5)
    let o = try e.execute("overlay.add", params: ["path": .string(png), "start": 0, "duration": 5, "fit": "contain"])
    #expect(o.value(at: "asset.id")?.stringValue == id)
    #expect(e.project?.assets.count == 1)
}

@Test func timelineDuplicateCopiesClipsWithTheirLinksInOneStep() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceOut": 4])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceOut": 4, "linkTo": "c1"])
    try e.execute("clip.set", params: ["clipId": "c1", "opacity": 0.5])
    let undo = e.context.history.undoStack.count
    let r = try e.execute("timeline.duplicate", params: ["clipIds": ["c1"]])
    #expect(e.context.history.undoStack.count == undo + 1)
    #expect(r.value(at: "clips")?.arrayValue?.count == 2)
    let v = e.clips(0), a = e.clips(1)
    #expect(v.count == 2 && a.count == 2)
    #expect(v[1].start.seconds == 4 && a[1].start.seconds == 4)
    #expect(v[1].transform?.opacity == 0.5)
    #expect(v[1].link != nil && v[1].link == a[1].link && v[1].link != v[0].link)
    // Paste at a time; an occupied spot fails and changes nothing.
    try e.execute("timeline.duplicate", params: ["clipIds": ["c1"], "start": 10, "linked": false])
    #expect(e.clips(0).last?.start.seconds == 10 && e.clips(0).last?.link == nil && e.clips(1).count == 2)
    let before = e.project
    #expect(throws: CommandError.self) { try e.execute("timeline.duplicate", params: ["clipIds": ["c1"], "start": 1]) }
    #expect(e.project == before)
}
