import Foundation
import Testing
@testable import RegistaCore

// Calmer auto-zoom (issue #43): spring easing, safe-zone follow, drag-aware hold, motion blur on camera moves.

// MARK: - Spring easing

@Test func springEasingStartsAtOnceSettlesOnTheTargetAndKeepsTheKeyTiming() {
    let s = Easing.spring
    #expect(s.apply(0) == 0 && s.apply(1) == 1)
    let xs = stride(from: 0.0, through: 1.0, by: 0.01).map { s.apply($0) }
    #expect(zip(xs, xs.dropFirst()).allSatisfy { $1 >= $0 - 1e-12 })   // monotonic: no overshoot past the target
    #expect(xs.allSatisfy { $0 >= 0 && $0 <= 1 })
    // Front-loaded: most of the way early, arriving slowly (speed at the end ≪ peak speed).
    #expect(s.apply(0.3) > 0.6 && s.apply(0.3) > Easing.easeInOut.apply(0.3))
    let speeds = zip(xs, xs.dropFirst()).map { ($1 - $0) / 0.01 }
    #expect(speeds.last! < 0.05 * speeds.max()! && speeds.first! < speeds.max()!)
    // Same key times as the smooth curve: only the shape of each move changes; the click is reached on time.
    var o = ZoomOptions()
    let clicks = [ZoomClick(t: 2, x: 300, y: 200), ZoomClick(t: 3, x: 900, y: 600)]
    let smooth = AutoZoom.keys(clicks, o)
    o.easing = .spring
    let spring = AutoZoom.keys(clicks, o)
    #expect(spring.map(\.t) == smooth.map(\.t) && spring.allSatisfy { $0.easing == .spring })
    let rest: (Double) -> [Double] = { _ in [960, 540] }
    #expect(abs(AutoZoom.state(at: 2, keys: spring, rest: rest).zoom - o.zoom) < 1e-9)
    #expect(AutoZoom.state(at: 1.7, keys: spring, rest: rest).zoom > AutoZoom.state(at: 1.7, keys: smooth, rest: rest).zoom)
}

@Test func autoZoomAcceptsSmoothAndSpring() throws {
    let (e, _) = try recordingEngine()
    let r = try e.execute("edit.autoZoom", params: ["easing": "spring"])
    #expect(r["easing"]?.stringValue == "spring")
    #expect(e.project!.tracks[0].clips[0].keyframes!.contains { $0.easing == .spring })
    #expect(try e.execute("edit.autoZoom", params: ["easing": "smooth"])["easing"]?.stringValue == "easeInOut")
    #expect(throws: CommandError.self) { try e.execute("edit.autoZoom", params: ["safeZone": 0.95]) }
    #expect(throws: CommandError.self) { try e.execute("edit.autoZoom", params: ["motionBlur": 1.5]) }
}

// MARK: - Safe-zone follow

/// A hand on a trackpad: slow wander with jitter, then a big move to the right half and back.
func jitteryCursor(seconds: Double = 20) -> [RecordingSession.CursorSample] {
    var seed: UInt64 = 42
    func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) - 0.5 }
    return stride(from: 0.0, through: seconds, by: 1.0 / 30).map { t in
        let big = t < 8 ? 0 : t < 10 ? (t - 8) / 2 : t < 14 ? 1 : t < 16 ? 1 - (t - 14) / 2 : 0
        return RecordingSession.CursorSample(t: t, x: 700 + 40 * sin(t * 0.9) + 900 * big + 30 * rnd(), y: 500 + 30 * cos(t * 1.3) + 20 * rnd())
    }
}

@Test func safeZoneFollowHoldsStillWithFewerKeyframesAndKeepsTheCursorInFrame() {
    let raw = jitteryCursor()
    let rate = 30.0
    let times = (0..<Int(20 * rate)).map { Double($0) / rate }
    let smooth = AutoZoom.smoothedCursor(raw, offset: 0, times: times, tau: 0.5)
    let area = [1920.0, 1080, 0, 0], aspect = 9.0 / 16
    let rest = AutoZoom.crop(zoom: 1, centre: [960, 540], aspect: aspect, area: area)   // a 607×1080 slice
    let frame = [rest[0] / 2, rest[1] / 2]
    let bounds = [rest[0] / 2, rest[1] / 2, 1920 - rest[0] / 2, 1080 - rest[1] / 2]
    let rawTable = AutoZoom.smoothedCursor(raw, offset: 0, times: times, tau: 0)
    let centres = AutoZoom.safeZoneCentres(smooth, raw: rawTable, dt: 1 / rate, zone: frame.map { $0 * 0.6 }, frame: frame, bounds: bounds)
    func table(_ tab: [[Double]]) -> (Double) -> [Double] { { u in tab[min(max(Int((u * rate).rounded()), 0), tab.count - 1)] } }
    let plain = AutoZoom.keyframeCrops(keys: [], sourceIn: 0, sourceOut: 19.9, aspect: aspect, area: area, rest: table(smooth), dense: true)
    let safe = AutoZoom.simplified(AutoZoom.keyframeCrops(keys: [], sourceIn: 0, sourceOut: 19.9, aspect: aspect, area: area, rest: table(centres), dense: true))
    #expect(safe.count * 4 < plain.count)
    // The camera does not move at all while the cursor wanders in the zone (the first 8 s).
    let early = safe.filter { $0.t < 7.5 }
    #expect(early.count <= 3 && early.allSatisfy { abs($0.crop[2] - safe[0].crop[2]) < 0.5 })
    // The smoothed cursor stays well inside the frame everywhere, and the raw one never leaves it.
    func inside(_ p: RecordingSession.CursorSample, margin: Double) -> Bool {
        let crop = AutoZoom.crop(zoom: 1, centre: table(centres)(p.t), aspect: aspect, area: area)
        return p.x >= crop[2] + margin && p.x <= crop[2] + crop[0] - margin && p.y >= crop[3] && p.y <= crop[3] + crop[1]
    }
    #expect(zip(times, smooth).allSatisfy { inside(RecordingSession.CursorSample(t: $0, x: $1[0], y: $1[1]), margin: 0.03 * rest[0]) })
    #expect(raw.filter { $0.t < 19.9 }.allSatisfy { inside($0, margin: 0) })
    // It still goes where the cursor goes.
    #expect(table(centres)(12)[0] > 1300)
}

@Test func autoZoomFollowWithASafeZoneWritesFewerKeyframesThanPlainFollow() throws {
    let (a, _) = try recordingEngine(width: 1080, height: 1920, layout: LayoutSpec(kind: .cutout))
    let plain = try a.execute("edit.autoZoom", params: ["follow": true, "safeZone": 0])["keyframes"]!.doubleValue!
    let safe = try a.execute("edit.autoZoom", params: ["follow": true])
    #expect(safe["safeZone"]?.doubleValue == 0.6)
    #expect(safe["keyframes"]!.doubleValue! < plain * 0.7)
}

// MARK: - Drag-aware hold

@Test func dragsComeFromTheMouseUpLogElseFromTheCursor() {
    // Press at 2 on (400, 400), dragged to (900, 600) by 3.2, still until the next click at 6.
    let cursor = stride(from: 0.0, through: 8, by: 1.0 / 30).map { t -> RecordingSession.CursorSample in
        let f = min(max((t - 2.03) / 1.2, 0), 1)
        return RecordingSession.CursorSample(t: t, x: 400 + 500 * f, y: 400 + 200 * f)
    }
    let clicks = [(t: 2.0, x: 400.0, y: 400.0), (t: 6.0, x: 900.0, y: 600.0)]
    let events = clicks.map { RecordingSession.Event(kind: "click", t: $0.t, x: $0.x, y: $0.y) }
    // With mouse-ups (issue #42): Drags.detect decides; the second press barely moved, a click.
    let logged = events + [RecordingSession.Event(kind: "mouseUp", t: 3.3, x: 900, y: 600), RecordingSession.Event(kind: "mouseUp", t: 6.05, x: 900, y: 600)]
    #expect(DragHold.releases(clicks: clicks, events: logged, cursor: cursor, width: 1920, height: 1080) == [0: 3.3])
    // An old session (no mouse-ups): the cursor moving right after the click, until it rests.
    let guessed = DragHold.releases(clicks: clicks, events: events, cursor: cursor, width: 1920, height: 1080)
    #expect(guessed[0].map { abs($0 - 3.23) < 0.05 } == true && guessed[1] == nil)
    // A plain click, then a pause before the cursor goes on to the next target: not a drag.
    let wander = stride(from: 0.0, through: 8, by: 1.0 / 30).map { t -> RecordingSession.CursorSample in
        let f = min(max((t - 2.4) / 1.0, 0), 1)
        return RecordingSession.CursorSample(t: t, x: 400 + 500 * f, y: 400 + 200 * f)
    }
    #expect(DragHold.releases(clicks: clicks, events: events, cursor: wander, width: 1920, height: 1080).isEmpty)
    // A logged session trusts its log: a click with no drag there stays a click whatever the cursor did.
    #expect(DragHold.releases(clicks: clicks, events: events + [RecordingSession.Event(kind: "mouseUp", t: 2.08)], cursor: cursor,
                              width: 1920, height: 1080).isEmpty)
}

@Test func theZoomHoldsAndTravelsThroughADrag() {
    let o = ZoomOptions()
    // Press at 2, dragged until 5.5, next click at 7: without the drag the zoom would go out at 3–3.6.
    let path = stride(from: 2.0, through: 5.5, by: 1.0 / 30).map { ZoomClick(t: $0, x: 300 + 200 * ($0 - 2), y: 400) }
    let plain = [ZoomClick(t: 2, x: 300, y: 400), ZoomClick(t: 7, x: 1000, y: 400)]
    var dragged = plain
    dragged[0].drag = path
    #expect(AutoZoom.groups(plain, o).count == 2 && AutoZoom.groups(dragged, o).count == 1)
    let keys = AutoZoom.keys(dragged, o)
    let rest: (Double) -> [Double] = { _ in [960, 540] }
    for u in stride(from: 2.0, through: 7.0, by: 0.05) { #expect(abs(AutoZoom.state(at: u, keys: keys, rest: rest).zoom - o.zoom) < 1e-9) }
    // The camera travels with the cursor, smoothly (no jump between two frames), and lands on the release.
    let xs = stride(from: 2.0, through: 5.5, by: 1.0 / 30).map { AutoZoom.state(at: $0, keys: keys, rest: rest).centre[0] }
    #expect(zip(xs, xs.dropFirst()).allSatisfy { abs($1 - $0) < 12 })
    #expect(abs(AutoZoom.state(at: 4, keys: keys, rest: rest).centre[0] - 700) < 15)
    let landed = AutoZoom.state(at: 5.5, keys: keys, rest: rest).centre
    #expect(abs(landed[0] - 1000) < 0.5 && landed[1] == 400)
}

// MARK: - Motion blur on camera moves

@Test func cameraBlurIsZeroWhenStillGrowsWithSpeedAndIsCapped() {
    let crop = [960.0, 540, 400, 300]
    #expect(CameraBlur.make(crop: crop, before: crop, after: crop, amount: 0.5, width: 1920, height: 1080) == nil)
    func pan(_ px: Double) -> CameraBlur? {
        CameraBlur.make(crop: crop, before: [960, 540, 400 - px, 300], after: [960, 540, 400 + px, 300], amount: 0.5, width: 1920, height: 1080)
    }
    #expect(pan(0.1) == nil)   // under a pixel of smear
    let slow = pan(5)!, fast = pan(20)!
    // 2× output scale (960 → 1920), half a frame each side, shutter 0.5: smear = 2 · 5 px · 2 · 0.5 = 10 px.
    #expect(abs(slow.length - 10) < 1e-6 && abs(fast.length - 40) < 1e-6)
    #expect(slow.back.scale == 1 && slow.back.dx > 0 && slow.forward.dx < 0)   // the picture moves against the crop
    #expect(pan(400)!.length == CameraBlur.maxLength * 1920 * 0.5)
    // A zoom (the crop shrinks about its centre) is a scale, smaller than 1 before, larger after.
    let z = CameraBlur.make(crop: crop, before: [980, 551.25, 390, 294.375], after: [940, 528.75, 410, 305.625], amount: 1, width: 1920, height: 1080)!
    #expect(z.back.scale < 1 && z.forward.scale > 1 && z.length > 10)
}

@Test func autoZoomBlursTheScreenOnlyWhileTheCameraMoves() throws {
    let (e, _) = try recordingEngine()
    try e.execute("edit.autoZoom", params: ["zoom": 2])
    #expect(e.project!.tracks[0].clips.allSatisfy { $0.motionBlur == 0.5 })
    let job = RenderJob(project: e.project!, preset: .landscape, captions: false)
    func blur(_ s: Double) -> CameraBlur? { job.layers(at: t(s).snapped(to: Rational(30))).first { $0.assetID == "a1" }?.cameraBlur }
    #expect(blur(0.5) == nil)          // at rest
    #expect(blur(2.6) == nil)          // held on the first click (2.35 → hold)
    #expect((blur(2.13)?.length ?? 0) > 5)   // halfway through the zoom-in onto it
    try e.execute("edit.autoZoom", params: ["zoom": 2, "motionBlur": 0])
    #expect(e.project!.tracks[0].clips.allSatisfy { $0.motionBlur == nil })
    #expect(RenderJob(project: e.project!, preset: .landscape, captions: false).layers(at: t(2.13).snapped(to: Rational(30))).first { $0.assetID == "a1" }?.cameraBlur == nil)
}

@Test func autoZoomReportsTheDragsOfTheSessionInTimelineTime() throws {
    // The second click (4.0 s, 600×450) becomes a drag to 1000×450 released at 5.5 s (a mouseUp event).
    let dir = try sessionFolder()
    let url = dir.appendingPathComponent(RecordingSession.fileName)
    var s = try RecordingSession.load(url)
    s.events.append(RecordingSession.Event(kind: "mouseUp", t: 5.5, x: 1000, y: 450))
    s.cursor = stride(from: 0.0, through: 14, by: 1.0 / 30).map { t in
        let f = min(max((t - 4.05) / 1.4, 0), 1)
        return RecordingSession.CursorSample(t: t, x: t < 4 ? 300 : 600 + 400 * f, y: t < 4 ? 240 : 450)
    }
    try s.write(to: url)
    let e = Engine(prober: SessionProber())
    try e.execute("project.new", params: ["name": "drag", "width": 1920, "height": 1080])
    try e.execute("recording.import", params: ["path": .string(dir.path), "layout": "screen"])
    let r = try e.execute("edit.autoZoom", params: [:])
    let drags = r["drags"]?.arrayValue ?? []
    #expect(drags.count == 1)
    #expect(abs((drags.first?["from"]?.doubleValue ?? 0) - 3.75) < 1e-6 && abs((drags.first?["to"]?.doubleValue ?? 0) - 5.25) < 1e-6)
    #expect(try e.execute("edit.autoZoom", params: ["drags": false])["drags"]?.arrayValue?.isEmpty == true)
}
