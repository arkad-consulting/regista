import Foundation
import Testing
@testable import RegistaCore

// 2.5D transforms and behind/in-front switches (issue #22).

@Test func transformDecodesOldProjectsAndWritesNoDefaults() throws {
    let old = #"{"cropLeft":0,"cropTop":0,"cropRight":0,"cropBottom":0,"scale":1.2,"x":0.1,"y":0,"rotation":5,"opacity":1}"#
    let t = try JSONDecoder().decode(Transform.self, from: Data(old.utf8))
    #expect(t.scale == 1.2 && t.anchorX == 0.5 && t.anchorY == 0.5 && t.rotationX == 0 && t.perspective == Transform.defaultPerspective)
    #expect(!t.isSpatial)
    let json = String(decoding: try JSONEncoder().encode(t), as: UTF8.self)
    #expect(!json.contains("anchor") && !json.contains("rotationX") && !json.contains("perspective"))
    var s = t
    s.rotationY = 30; s.anchorY = 0
    let back = try JSONDecoder().decode(Transform.self, from: try JSONEncoder().encode(s))
    #expect(back == s && back.isSpatial)
}

@Test func projectionTiltsAroundThePivot() {
    let flat = Projection.corners(w: 200, h: 100, centre: (500, 500), scale: 1, rotation: 0)
    #expect(flat.map(\.0) == [400, 600, 600, 400] && flat.map(\.1) == [450, 450, 550, 550])
    // Right side away: the right edge gets shorter and moves left; the left edge comes closer (taller).
    let turned = Projection.corners(w: 200, h: 100, centre: (500, 500), scale: 1, rotation: 0, rotationY: 40, distance: 800)
    let right = turned[2].1 - turned[1].1, left = turned[3].1 - turned[0].1
    #expect(right < 100 && left > 100 && turned[1].0 < 600)
    // Pivot on the top edge: the top stays put while the card swings.
    let hung = Projection.corners(w: 200, h: 100, centre: (500, 500), scale: 1, rotation: 20, anchorX: 0.5, anchorY: 0)
    let topMid = ((hung[0].0 + hung[1].0) / 2, (hung[0].1 + hung[1].1) / 2)
    #expect(abs(topMid.0 - 500) < 1e-9 && abs(topMid.1 - 450) < 1e-9)
}

@Test func keyframesInterpolateTheSpatialFields() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4])
    let cid = e.clips(0)[0].id
    try e.checkUndoRedo("clip.set", ["clipId": .string(cid), "keyframes": [["time": 0, "rotationY": 0, "anchorY": 0], ["time": 2, "rotationY": 60, "anchorY": 0, "perspective": 1000]]])
    let mid = e.clips(0)[0].transform(at: t(1))
    #expect(abs(mid.rotationY - 30) < 1e-9 && mid.anchorY == 0 && abs(mid.perspective - 1500) < 1e-9)
    let layer = try #require(RenderJob(project: e.project!, preset: .vertical, captions: false).layers(at: t(1)).first)
    #expect(layer.isSpatial && abs(layer.rotationY - 30) < 1e-9)
}

@Test func behindSwitchesFlipTheLayerOverTime() throws {
    var c = Clip(id: "c1", assetID: "", sourceIn: .zero, sourceOut: t(4), start: .zero)
    #expect(!c.isBehindSubject(at: t(1)))
    c.behindSubject = true
    #expect(c.isBehindSubject(at: t(1)))
    c.behindSwitches = [BehindSwitch(time: t(1), behind: false), BehindSwitch(time: t(2.5), behind: true)]
    #expect(c.isBehindSubject(at: t(0.5)) && !c.isBehindSubject(at: t(1.2)) && c.isBehindSubject(at: t(3)))
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4])
    try e.execute("title.add", params: ["text": "HI", "start": 0, "duration": 4])
    let title = e.project!.tracks.last!.clips[0]
    try e.checkUndoRedo("clip.set", ["clipId": .string(title.id), "behindSwitches": [["time": 2, "behind": true]]])
    let job = RenderJob(project: e.project!, preset: .vertical, captions: false)
    #expect(job.layers(at: t(1)).last?.behindSubject == false && job.layers(at: t(3)).last?.behindSubject == true)
}
