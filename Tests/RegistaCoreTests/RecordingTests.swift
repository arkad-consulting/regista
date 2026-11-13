import Foundation
import Testing
@testable import RegistaCore

// Screen + camera recordings (issue #6): session sync math, layout geometry, auto-zoom keyframes, import → tracks.

/// Metadata per file name of a synthetic session: 1920×1080 60 fps screen, 1080×1920 30 fps camera, 48 kHz mic.
struct SessionProber: MediaProber {
    var screen = 14.0, camera = 13.75, mic = 13.82
    func probe(_ url: URL) throws -> ProbedMedia {
        switch url.lastPathComponent {
        case "screen.mov": ProbedMedia(duration: MediaTime(seconds: screen), video: VideoInfo(width: 1920, height: 1080, frameRate: Rational(60), codec: "h264"))
        case "camera.mov": ProbedMedia(duration: MediaTime(seconds: camera), video: VideoInfo(width: 1080, height: 1920, frameRate: Rational(30), codec: "h264"))
        default: ProbedMedia(duration: MediaTime(seconds: mic), audio: AudioInfo(sampleRate: 48000, channels: 1, codec: "pcm_s16le"))
        }
    }
}

/// A session folder with empty media files and a session.json (offsets screen 0, camera 0.25, mic 0.18).
func sessionFolder(layout: LayoutSpec? = nil, changes: [RecordingSession.LayoutChange]? = nil,
                   sources ids: [String] = ["screen", "camera", "mic"]) throws -> URL {
    let dir = tempDir()
    let all = [RecordingSession.Source(id: "screen", file: "screen.mov", offset: 0),
               RecordingSession.Source(id: "camera", file: "camera.mov", offset: 0.25),
               RecordingSession.Source(id: "mic", file: "mic.wav", offset: 0.18)].filter { ids.contains($0.id) }
    for s in all { FileManager.default.createFile(atPath: dir.appendingPathComponent(s.file).path, contents: Data()) }
    var s = RecordingSession(app: "test", created: "2026-11-02T10:00:00Z", duration: 14, sources: all)
    s.events = [RecordingSession.Event(kind: "click", t: 2.6, x: 300, y: 240), RecordingSession.Event(kind: "click", t: 4.0, x: 600, y: 450),
                RecordingSession.Event(kind: "key", t: 5, key: "cmd+s"), RecordingSession.Event(kind: "click", t: 9.2, x: 1380, y: 760)]
    s.cursor = stride(from: 0.0, through: 14, by: 1.0 / 30).map { RecordingSession.CursorSample(t: $0, x: 200 + 100 * $0, y: 540) }
    s.layout = layout
    s.layoutChanges = changes
    try s.write(to: dir.appendingPathComponent(RecordingSession.fileName))
    return dir
}

func recordingEngine(width: Int = 1920, height: Int = 1080, layout: LayoutSpec? = nil,
                     changes: [RecordingSession.LayoutChange]? = nil) throws -> (Engine, JSONValue) {
    let e = Engine(prober: SessionProber())
    try e.execute("project.new", params: ["name": "tutorial", "width": .number(Double(width)), "height": .number(Double(height))])
    let r = try e.execute("recording.import", params: ["path": .string(try sessionFolder(layout: layout, changes: changes).path)])
    return (e, r)
}

// MARK: - Screen-only takes (issue #39)

@Test func screenOnlySessionsImportWithTheScreenFillingTheFrame() throws {
    for ids in [["screen", "mic"], ["screen"]] {
        let e = Engine(prober: SessionProber())
        try e.execute("project.new", params: ["name": "faceless", "width": 1080, "height": 1920])
        // The face layout picked while recording is ignored: there is no camera to place.
        let r = try e.execute("recording.import", params: ["path": .string(try sessionFolder(layout: LayoutSpec(kind: .bubble), sources: ids).path)])
        let p = e.project!
        #expect(r["assets"]?["camera"] == nil)
        #expect(!p.tracks.contains { $0.role == "camera" })
        #expect(p.tracks.contains { $0.role == "mic" } == ids.contains("mic"))
        #expect(p.recordings?.last?.camera == nil)
        #expect(r["layouts"]?.arrayValue?.map { $0["layout"]?.stringValue } == ["screen"])
    }
}

// MARK: - Sync

@Test func sessionSourcesShareTheTimelineWindowWithExactSubFrameOffsets() {
    let rate = Rational(30)
    let p = SessionSync.placements(offsets: [0, 0.25, 0.18], durations: [t(14), t(13.75), t(13.82)], frameRate: rate)
    // Window: from the latest start (0.25) to the earliest end (14.0), whole frames: 13.75 s = 412.5 → 412 frames.
    #expect(p.allSatisfy { $0.start == .zero && $0.duration == MediaTime(ticks: MediaTime.frameDuration(at: rate).ticks * 412) })
    #expect(p[0].sourceIn == t(0.25) && p[1].sourceIn == .zero)
    #expect(abs(p[2].sourceIn.seconds - 0.07) < 1e-9)
    // At any timeline time the three files show the same session instant, to the tick.
    for k in [0, 7, 101, 411] {
        let tl = MediaTime(ticks: MediaTime.frameDuration(at: rate).ticks * Int64(k))
        let s = [0.0, 0.25, 0.18].enumerated().map { (p[$0.offset].sourceIn + tl).seconds + $0.element }
        #expect(abs(s[0] - s[1]) < 1e-8 && abs(s[1] - s[2]) < 1e-8)
    }
    // Camera offset 0.25 s is 7.5 frames: not snapped (snapping would shift the camera by half a frame).
    #expect(p[1].sourceIn.seconds + 0.25 == 0.25)
}

@Test func sessionTimeMapsThroughEditedClips() throws {
    let (e, r) = try recordingEngine(layout: LayoutSpec(kind: .screen))
    let screen = r["assets"]?["screen"]?.stringValue ?? ""
    let p = e.project!
    // Session 3.0 s on the screen (offset 0) → timeline 3.0 − origin 0.25 = 2.75 s.
    let tl = SessionSync.timelineTime(session: 3.0, offset: 0, asset: screen, in: p)
    #expect(abs((tl?.seconds ?? 0) - 2.75) < 1e-9)
    #expect(abs((SessionSync.sessionTime(timeline: t(2.75), offset: 0, asset: screen, in: p) ?? 0) - 3.0) < 1e-9)
    // Cut out 1–2 s with a ripple: later session times move 1 s earlier, cut times map to nothing.
    try e.execute("timeline.cut", params: ["at": 1])
    try e.execute("timeline.cut", params: ["at": 2])
    let mid = e.project!.tracks[0].clips[1].id
    try e.execute("timeline.delete", params: ["clipId": .string(mid), "ripple": true])
    #expect(abs((SessionSync.timelineTime(session: 3.0, offset: 0, asset: screen, in: e.project!)?.seconds ?? 0) - 1.75) < 1e-9)
    #expect(SessionSync.timelineTime(session: 1.5 + 0.25, offset: 0, asset: screen, in: e.project!) == nil)
}

// MARK: - Import

@Test func importBuildsScreenCameraMicTracksLinkedOnTheSessionClock() throws {
    let (e, r) = try recordingEngine()
    let p = e.project!
    #expect(p.tracks.map(\.name) == ["Schermo", "Camera", "Microfono"])
    #expect(p.tracks.map(\.role) == ["screen", "camera", "mic"])
    #expect(p.tracks.map(\.kind) == [.video, .video, .audio])
    let clips = p.tracks.map { $0.clips[0] }
    #expect(clips.allSatisfy { $0.start == .zero && $0.duration == clips[0].duration })
    #expect(Set(clips.compactMap(\.link)).count == 1)
    #expect(abs(clips[2].sourceIn.seconds - 0.07) < 1e-9)
    #expect(r["origin"]?.doubleValue == 0.25)
    #expect(r["events"]?["clicks"]?.doubleValue == 3 && r["events"]?["keys"]?.doubleValue == 1)
    // Default layout: bubble bottom right, circle, M.
    let cam = clips[1]
    #expect(cam.placement?.fit == .box && cam.mask?.shape == .circle)
    #expect(p.recordings?.first?.layouts?.first?.layout.kind == .bubble)
    // Undo restores the empty project in one step.
    try e.execute("history.undo")
    #expect(e.project!.tracks.isEmpty && e.project!.assets.isEmpty && e.project!.recordings == nil)
}

@Test func importAppliesTheLayoutSwitchesMadeWhileRecording() throws {
    let (e, _) = try recordingEngine(layout: LayoutSpec(kind: .bubble, corner: "topLeft"),
                                     changes: [RecordingSession.LayoutChange(t: 7.25, layout: LayoutSpec(kind: .split))])
    let p = e.project!
    let cam = p.tracks[1].clips
    #expect(cam.count == 2)
    #expect(cam[1].start == t(7))   // session 7.25 − origin 0.25
    #expect(cam[0].mask?.shape == .circle && cam[1].mask?.shape == .rounded)
    #expect(p.settings.background == Layouts.backdrop)
    #expect(p.recordings?[0].layouts?.map(\.layout.kind) == [.bubble, .split])
    // The mic was cut with the pictures (linked).
    #expect(p.tracks[2].clips.count == 2)
}

// MARK: - Layouts

@Test func bubblePresetSitsInTheChosenCornerWithItsSize() {
    let face = [400.0, 500, 300, 360]
    for (corner, cx, cy) in [("bottomRight", 1709.0, 869.0), ("topLeft", 211.0, 211.0)] {
        let g = Layouts.geometry(LayoutSpec(kind: .bubble, corner: corner), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920), face: face)
        let pl = g.camera.placement!
        let (w, h) = g.camera.boxSize(width: 1920, height: 1080)
        #expect(w == 324 && h == 324)                 // M = 0.30 × 1080
        #expect(abs(pl.x * 1920 - cx) < 0.5 && abs(pl.y * 1080 - cy) < 0.5)   // 49 px margin
        #expect(g.screen.placement == nil && g.camera.mask?.shape == .circle && g.camera.mask?.borderWidth == 3)
        // Square crop of 2.7 face heights (Vision's box is brow to chin), the face centre 52% down.
        let c = g.camera.crop!
        #expect(abs(c[0] - c[1]) < 1e-9 && abs(c[1] - 972) < 1e-9)
        #expect(abs((c[3] + 0.52 * c[1]) - 680) < 1e-9 && abs((c[2] + c[0] / 2) - 550) < 1e-9)
    }
    let small = Layouts.geometry(LayoutSpec(kind: .bubble, shape: "rounded", size: "S"), width: 1080, height: 1920, screen: (1920, 1080), camera: (1080, 1920))
    #expect(small.camera.boxSize(width: 1080, height: 1920).0 == 238 && small.camera.mask?.shape == .rounded)
}

@Test func splitKeepsTheWholeScreenInTwoThirdsAndTheFaceInTheLastThird() {
    let g = Layouts.geometry(LayoutSpec(kind: .split), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920), face: [400, 500, 300, 360])
    let (sw, sh) = g.screen.boxSize(width: 1920, height: 1080), (fw, fh) = g.camera.boxSize(width: 1920, height: 1080)
    #expect(abs(sw / sh - 16.0 / 9) < 1e-9)          // contained, not cropped
    #expect(abs(fh - sh) < 1e-9)                     // cards of the same height
    #expect(abs(sw - 2 * fw) < 1e-9)                 // 2/3 + 1/3
    let sx = g.screen.placement!.x * 1920, fx = g.camera.placement!.x * 1920
    #expect(fx > sx)                                  // face on the right
    #expect(abs((fx - fw / 2) - (sx + sw / 2) - 38) < 1e-6)   // one gap between the cards
    #expect(abs((sx - sw / 2) - (1920 - (fx + fw / 2))) < 1e-6)  // centred as a pair
    #expect(g.background == Layouts.backdrop)
    let crop = g.camera.crop!
    #expect(abs(crop[0] / crop[1] - fw / fh) < 1e-9)
    let left = Layouts.geometry(LayoutSpec(kind: .split, side: "left"), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920))
    #expect(left.camera.placement!.x < left.screen.placement!.x)
}

@Test func stackFaceAndCutoutGeometry() {
    let face = [400.0, 500, 300, 360]
    let s = Layouts.geometry(LayoutSpec(kind: .stack), width: 1080, height: 1920, screen: (1920, 1080), camera: (1080, 1920), face: face)
    #expect(s.screen.boxSize(width: 1080, height: 1920) == (1080, 960) && s.camera.boxSize(width: 1080, height: 1920) == (1080, 960))
    #expect(s.screen.placement!.y == 0.25 && s.camera.placement!.y == 0.75)
    let top = Layouts.geometry(LayoutSpec(kind: .stack, side: "top"), width: 1080, height: 1920, screen: (1920, 1080), camera: (1080, 1920), face: face)
    #expect(top.camera.placement!.y == 0.25)

    let f = Layouts.geometry(LayoutSpec(kind: .face), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920), face: face)
    #expect(f.screen.visible == false && f.camera.placement == nil && abs(f.camera.crop![0] / f.camera.crop![1] - 16.0 / 9) < 1e-9)

    let c = Layouts.geometry(LayoutSpec(kind: .cutout, corner: "bottomLeft"), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920), face: face)
    let (w, h) = c.camera.boxSize(width: 1920, height: 1080)
    #expect(c.camera.mask?.cutout == true && h == 756)                            // M = 0.70 × 1080
    #expect(abs(c.camera.placement!.y * 1080 + h / 2 - 1080) < 1e-9)              // stands on the bottom edge
    #expect(abs(c.camera.placement!.x * 1920 - w / 2 - 32) < 1e-6)                // left margin
    #expect(c.screen.placement == nil && c.screen.visible)
    #expect(throws: CommandError.self) { try LayoutSpec(kind: .cutout, corner: "topLeft").validate() }
    #expect(throws: CommandError.self) { try LayoutSpec(kind: .stack, side: "left").validate() }
}

@Test func cropAroundTheFaceStaysInsideTheSource() {
    let c = Layouts.cropAround(face: [20, 10, 200, 240], aspect: 1, faceHeights: 2.3, faceAt: 0.44, source: (1080, 1920))
    #expect(c[2] == 0 && c[3] == 0 && c[0] == 552)
    let big = Layouts.cropAround(face: [0, 0, 1000, 1000], aspect: 1, faceHeights: 3, faceAt: 0.5, source: (1080, 1920))
    #expect(big[0] == 1080 && big[1] == 1080)
}

@Test func layoutApplyOnARangeCutsAndKeepsTheRest() throws {
    let (e, r) = try recordingEngine()
    let res = try e.checkUndoRedo("layout.apply", ["preset": "split", "from": 6, "to": 9])
    #expect(res["cameraClips"]?.arrayValue?.count == 1)
    let p = e.project!
    let cam = p.tracks[1].clips
    #expect(cam.map(\.start.seconds) == [0, 6, 9])
    #expect(cam.map { $0.mask?.shape } == [.circle, .rounded, .circle])
    #expect(p.tracks[0].clips[1].placement?.fit == .box && p.tracks[0].clips[0].placement == nil)
    // A new shape pops in at 6 s; the bubble returning at 9 s too.
    #expect(cam[1].keyframes?.first?.transform.opacity == 0 && cam[2].keyframes?.count == 2)
    #expect(p.recordings![0].layouts!.map(\.layout.kind) == [.bubble, .split, .bubble])
    // Moving the bubble to another corner glides (same shape).
    try e.execute("layout.apply", params: ["preset": "bubble", "corner": "topLeft", "from": 10, "transition": 0.5])
    let moved = e.project!.tracks[1].clips.last!
    #expect(moved.keyframes?.count == 2 && moved.keyframes![0].transform.x > 0.5 && moved.keyframes![1].transform.x == 0)
    #expect(r["recordingId"]?.stringValue == "r1")
    #expect(throws: CommandError.self) { try e.execute("layout.apply", params: ["preset": "cutout", "corner": "topRight"]) }
}

// MARK: - Auto-zoom

@Test func zoomKeysHoldPanAndReleaseAroundClicks() {
    var o = ZoomOptions()
    o.zoom = 2
    let clicks = [ZoomClick(t: 2, x: 300, y: 200), ZoomClick(t: 3, x: 900, y: 600), ZoomClick(t: 9, x: 100, y: 100)]
    #expect(AutoZoom.groups(clicks, o).map(\.count) == [2, 1])
    let keys = AutoZoom.keys(clicks, o)
    #expect(keys.map(\.t) == [1.55, 2, 2.55, 3, 4, 4.6, 8.55, 9, 10, 10.6])
    let rest: (Double) -> [Double] = { _ in [960, 540] }
    #expect(AutoZoom.state(at: 2, keys: keys, rest: rest).zoom == 2)
    #expect(AutoZoom.state(at: 2, keys: keys, rest: rest).centre == [300, 200])
    #expect(AutoZoom.state(at: 3.5, keys: keys, rest: rest).centre == [900, 600])   // held on the second click
    #expect(AutoZoom.state(at: 6, keys: keys, rest: rest).zoom == 1)
    let mid = AutoZoom.state(at: 1.775, keys: keys, rest: rest)
    #expect(abs(mid.zoom - 1 / 0.75) < 1e-9)          // half-way in crop width (easeInOut at 0.5)
    // The crop at the click: half the screen, centred on the click but clamped inside it.
    #expect(AutoZoom.crop(zoom: 2, centre: [300, 200], aspect: 16.0 / 9, area: [1920, 1080, 0, 0]) == [960, 540, 0, 0])
    #expect(AutoZoom.crop(zoom: 2, centre: [900, 600], aspect: 16.0 / 9, area: [1920, 1080, 0, 0]) == [960, 540, 420, 330])
    // A narrower box (9:16 reel) gets a narrower crop of the same height logic.
    let tall = AutoZoom.crop(zoom: 1, centre: [1800, 540], aspect: 9.0 / 16, area: [1920, 1080, 0, 0])
    #expect(abs(tall[0] - 607.5) < 1e-9 && tall[1] == 1080 && abs(tall[2] - 1312.5) < 1e-9)
}

@Test func zoomKeyframesFollowKeysAndSampleMovesCutByTheClipEdge() {
    var o = ZoomOptions()
    o.zoom = 2
    let keys = AutoZoom.keys([ZoomClick(t: 2, x: 300, y: 200)], o)
    let rest: (Double) -> [Double] = { _ in [960, 540] }
    let whole = AutoZoom.keyframeCrops(keys: keys, sourceIn: 0, sourceOut: 10, aspect: 16.0 / 9, area: [1920, 1080, 0, 0], rest: rest, dense: false)
    #expect(whole.map(\.t) == [0, 1.55, 2, 3, 3.6, 10])
    #expect(whole[1].easing == .easeInOut && whole[2].crop == [960, 540, 0, 0] && whole[5].crop == [1920, 1080, 0, 0])
    // A clip starting in the middle of the zoom-in samples that move (linear) and keeps the eased keys after it.
    let part = AutoZoom.keyframeCrops(keys: keys, sourceIn: 1.8, sourceOut: 10, aspect: 16.0 / 9, area: [1920, 1080, 0, 0], rest: rest, dense: false)
    #expect(part.first!.t == 0 && part.first!.easing == nil)
    #expect(part.contains { abs($0.t - 0.2) < 1e-9 && $0.easing == .easeInOut })
    #expect(part.filter { $0.t < 0.2 }.count >= 3)
    // A clip with no click stays at rest: no keyframes.
    #expect(AutoZoom.keyframeCrops(keys: keys, sourceIn: 5, sourceOut: 10, aspect: 16.0 / 9, area: [1920, 1080, 0, 0], rest: rest, dense: false).isEmpty)
}

@Test func autoZoomWritesCropKeyframesOnTheScreenClipsInOneUndoStep() throws {
    let (e, _) = try recordingEngine()
    try e.execute("layout.apply", params: ["preset": "split", "from": 7])
    let r = try e.checkUndoRedo("edit.autoZoom", ["zoom": 2])
    let clicks = r["clicks"]!.arrayValue!
    #expect(clicks.count == 3)
    #expect(abs((clicks[0]["time"]?.doubleValue ?? 0) - 2.35) < 1e-6)        // session 2.6 − origin 0.25
    #expect(clicks.allSatisfy { abs(($0["zoom"]?.doubleValue ?? 0) - 2) < 0.03 })
    #expect(r["groups"]?.doubleValue == 2)
    let screen = e.project!.tracks[0].clips
    #expect(screen.allSatisfy { $0.keyframes != nil })
    // The split half keeps its box placement; the zoom crop is at the box's aspect (the screen's own: contained).
    let job = RenderJob(project: e.project!, preset: .landscape, captions: false)
    let at = MediaTime(seconds: 8.95).snapped(to: Rational(30))
    let layer = job.layers(at: at).first { $0.assetID == "a1" }!
    #expect(layer.placement?.fit == .box && abs(layer.crop[0] / layer.crop[1] - 16.0 / 9) < 0.01 && layer.crop[0] < 1000)
    // Follow: the resting framing tracks the cursor in a 9:16 reel.
    let (v, _) = try recordingEngine(width: 1080, height: 1920, layout: LayoutSpec(kind: .cutout))
    try v.execute("edit.autoZoom", params: ["follow": true, "zoom": 1.4])
    let vj = RenderJob(project: v.project!, preset: .vertical, captions: false)
    let early = vj.layers(at: t(0.5)).first { $0.assetID == "a1" }!, late = vj.layers(at: t(12)).first { $0.assetID == "a1" }!
    #expect(late.crop[2] > early.crop[2] + 300)   // the cursor moved right by ~1100 px
}

@Test func timelineCutRebasesKeyframesOfTheRightPart() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1"])
    try e.execute("clip.set", params: ["clipId": "c1", "keyframes": [["time": 0, "scale": 1], ["time": 10, "scale": 2]]])
    try e.execute("timeline.cut", params: ["at": 4])
    let (l, r) = (e.clips()[0], e.clips()[1])
    #expect(abs(l.transform(at: t(2)).scale - 1.2) < 1e-6)
    #expect(abs(r.transform(at: .zero).scale - 1.4) < 1e-6 && abs(r.transform(at: t(6)).scale - 2) < 1e-6)
    #expect(abs(r.transform(at: t(3)).scale - 1.7) < 1e-6)   // was the clip-relative 3 s of the original (1.3) before the fix
}

@Test func clicksLandAwayFromAFaceThatCoversTheScreen() {
    // 9:16 cut-out: the person covers the lower half → clicks go to the middle of the upper half.
    #expect(AutoZoom.anchor(screen: [0, 0, 1080, 1920], occluder: [280, 960, 768, 960]) == [0.5, 0.25])
    // A corner bubble covers little: centred.
    #expect(AutoZoom.anchor(screen: [0, 0, 1920, 1080], occluder: [1547, 707, 324, 324]) == [0.5, 0.5])
    #expect(AutoZoom.anchor(screen: [0, 0, 1920, 1080], occluder: nil) == [0.5, 0.5])
    // A tall cut-out on the right of a 16:9 frame → the free left part.
    let a = AutoZoom.anchor(screen: [0, 0, 1920, 1080], occluder: [1300, 324, 600, 756])
    #expect(abs(a[0] - 650.0 / 1920) < 1e-9 && a[1] == 0.5)
    // The crop puts the click at the anchor (clamped inside the screen).
    let c = AutoZoom.crop(zoom: 2, centre: [960, 500], aspect: 9.0 / 16, area: [1920, 1080, 0, 0], anchor: [0.5, 0.25])
    #expect(abs(c[3] + 0.25 * c[1] - 500) < 1e-9)
}

@Test func clicksNearTheScreenEdgeZoomCloserToLeaveThePersonsShadow() {
    // 9:16 slice of a 1920×1080 screen, the person over the lower half: a click at y 794 cannot reach the upper
    // half at 1.4× (the crop stops at the screen's bottom), so its zoom rises until it does.
    let band = AutoZoom.freeBand(screen: [0, 0, 1080, 1920], occluder: [280, 960, 768, 960])
    #expect(band == [0, 0, 1, 0.5])
    let keys = [ZoomKey(t: 0, zoom: 1, centre: nil, easing: .easeInOut), ZoomKey(t: 1, zoom: 1.4, centre: [1421, 794], easing: .easeInOut),
                ZoomKey(t: 2, zoom: 1.4, centre: [394, 275], easing: .easeInOut)]
    let raised = AutoZoom.raisedForBand(keys, band: band, aspect: 9.0 / 16, area: [1920, 1080, 0, 0])
    #expect(raised[0].zoom == 1 && raised[2].zoom == 1.4)
    #expect(raised[1].zoom > 1.9 && raised[1].zoom <= 2.5)
    let r = AutoZoom.crop(zoom: raised[1].zoom, centre: [1421, 794], aspect: 9.0 / 16, area: [1920, 1080, 0, 0], anchor: [0.5, 0.25])
    #expect((794 - r[3]) / r[1] <= 0.46)
}
