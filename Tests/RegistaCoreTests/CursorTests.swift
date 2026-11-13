import Foundation
import Testing
@testable import RegistaCore

// The drawn cursor (issue #42): session format old/new, drags, spring smoothing, idle fade, ripples, cursor.style.

/// sessionFolder()'s session (clicks 2.6, 4.0, 9.2; cursor moving right at 100 px/s) recorded without the cursor:
/// mouse-ups 0.1 s after each click, kinds and button states in the samples.
func cursorlessSessionFolder() throws -> URL {
    let dir = try sessionFolder(layout: LayoutSpec(kind: .screen))
    let url = dir.appendingPathComponent(RecordingSession.fileName)
    var s = try RecordingSession.load(url)
    s.cursorInVideo = false
    s.sources[0].width = 1920; s.sources[0].height = 1080; s.sources[0].scale = 2
    s.events += s.clicks.map { RecordingSession.Event(kind: "mouseUp", t: $0.t + 0.1, x: $0.x, y: $0.y) }
    s.cursor = s.cursor!.map { c in
        var c = c
        if c.t > 4 && c.t < 5 { c.kind = "pointingHand" }
        if s.clicks.contains(where: { c.t >= $0.t && c.t < $0.t + 0.1 }) { c.down = true }
        return c
    }
    try s.write(to: url)
    return dir
}

@Test func oldSessionsDecodeWithTheCursorInTheVideoAndNoDrags() throws {
    let json = """
    {"version": 1, "app": "Regista 0.2.0", "created": "2026-11-02T10:00:00Z", "duration": 3,
     "sources": [{"id": "screen", "file": "screen.mov", "offset": 0, "width": 1920, "height": 1080}],
     "events": [{"kind": "click", "t": 1, "x": 10, "y": 20}], "cursor": [{"t": 0, "x": 1, "y": 2}, {"t": 1.5, "x": 400, "y": 2}]}
    """
    let s = try JSONDecoder().decode(RecordingSession.self, from: Data(json.utf8))
    #expect(s.cursorInVideo == nil && s.hasCursorInVideo)
    #expect(s.cursor?.first?.kind == nil && s.cursor?.first?.down == nil)
    #expect(s.drags.isEmpty)   // no mouseUp events: no press is known
    #expect(CursorKind(logged: s.cursor?.first?.kind) == .arrow)
}

@Test func newSessionFieldsRoundTripAndStayOutOfTheFileWhenEmpty() throws {
    var s = RecordingSession(app: "test", created: "2026-11-11T10:00:00Z", duration: 2, sources: [RecordingSession.Source(id: "screen", file: "screen.mov", offset: 0)])
    s.cursorInVideo = false
    s.cursor = [RecordingSession.CursorSample(t: 0, x: 1, y: 2), RecordingSession.CursorSample(t: 0.1, x: 3, y: 4, kind: "iBeam", down: true)]
    let url = tempDir().appendingPathComponent("session.json")
    try s.write(to: url)
    let back = try RecordingSession.load(url)
    #expect(back == s && !back.hasCursorInVideo)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.components(separatedBy: "\"kind\"").count == 2 && text.components(separatedBy: "\"down\"").count == 2)
    #expect(CursorKind(logged: "iBeam") == .iBeam && CursorKind(logged: "someFutureCursor") == .arrow)
}

@Test func aLongPressThatMovesIsADrag() {
    func events(_ presses: [(Double, Double)]) -> [RecordingSession.Event] {
        presses.flatMap { [RecordingSession.Event(kind: "click", t: $0.0, x: 100, y: 100), RecordingSession.Event(kind: "mouseUp", t: $0.1, x: 100, y: 100)] }
    }
    // Diagonal of 1920×1080 ≈ 2203 px: the limit is 33 px.
    let moving = stride(from: 0.0, through: 3, by: 1.0 / 30).map { RecordingSession.CursorSample(t: $0, x: 100 + 400 * max(0, $0 - 1), y: 100) }
    let still = stride(from: 0.0, through: 3, by: 1.0 / 30).map { RecordingSession.CursorSample(t: $0, x: 100, y: 100) }
    let drags = Drags.detect(events: events([(1.0, 1.3)]), cursor: moving, width: 1920, height: 1080)
    #expect(drags.count == 1)
    #expect(drags.first?.start == 1 && drags.first?.end == 1.3 && drags.first?.from == [100, 100])
    #expect(abs((drags.first?.travel ?? 0) - 120) < 14)          // ~0.3 s × 400 px/s (the release point is the press point here)
    // Too short (even when it moves), long but still, or a press without a mouse-up: not drags.
    #expect(Drags.detect(events: events([(1.5, 1.6)]), cursor: moving, width: 1920, height: 1080).isEmpty)
    #expect(Drags.detect(events: events([(1.0, 2.0)]), cursor: still, width: 1920, height: 1080).isEmpty)
    #expect(Drags.detect(events: [RecordingSession.Event(kind: "click", t: 1, x: 100, y: 100)], cursor: moving, width: 1920, height: 1080).isEmpty)
    // A movement of 30 px (under the 1.5 % limit) is a click that jittered.
    let small = still.map { RecordingSession.CursorSample(t: $0.t, x: $0.t > 1.1 ? 130 : 100, y: 100) }
    #expect(Drags.detect(events: events([(1.0, 1.4)]), cursor: small, width: 1920, height: 1080).isEmpty)
    // Presses pair each click with the next mouse-up only.
    let pairs = Drags.presses(events([(1, 1.2)]) + [RecordingSession.Event(kind: "click", t: 2, x: 5, y: 5)])
    #expect(pairs == [Press(down: 1, up: 1.2, x: 100, y: 100)])
}

@Test func theSpringIsCriticallyDampedAndSmoothingZeroIsTheRawPath() {
    // A jump of 1000 px at t = 1 s: the spring follows the critically damped step response, never overshoots.
    let s = [RecordingSession.CursorSample(t: 0, x: 0, y: 0), RecordingSession.CursorSample(t: 1, x: 0, y: 0),
             RecordingSession.CursorSample(t: 1.0001, x: 1000, y: 0), RecordingSession.CursorSample(t: 4, x: 1000, y: 0)]
    let w = 10.0, rate = 120.0
    let path = CursorPath.spring(s, omega: w, rate: rate)
    #expect(path.count == 481)
    for i in [150, 180, 240] {   // 0.25, 0.5, 1 s after the jump
        let tau = Double(i) / rate - 1.0001
        let expected = 1000 * (1 - (1 + w * tau) * exp(-w * tau))
        #expect(abs(path[i][0] - expected) < 15, "at \(Double(i) / rate) s: \(path[i][0]) vs \(expected)")
    }
    #expect(path.allSatisfy { $0[0] <= 1000 + 1e-6 })
    #expect(zip(path, path.dropFirst()).allSatisfy { $1[0] >= $0[0] - 1e-9 })
    #expect(abs(path.last![0] - 1000) < 0.01)
    // No smoothing: the raw path, linear between samples.
    let raw = CursorPath.spring(s, omega: nil, rate: rate)
    #expect(raw[60][0] == 0 && raw[240][0] == 1000)
    // The style maps smoothing 0…1 onto a softer spring.
    var style = CursorStyle()
    #expect(style.springOmega! > 14 && style.springOmega! < 16)
    style.smoothing = 0
    #expect(style.springOmega == nil)
}

@Test func theCursorFadesOutAfterTwoIdleSecondsAndComesBackBeforeItMoves() {
    let activity = [0.0, 1.0, 6.0]
    #expect(CursorPath.idleOpacity(at: 2.9, activity: activity) == 1)
    #expect(abs(CursorPath.idleOpacity(at: 3.15, activity: activity) - 0.5) < 1e-9)
    #expect(CursorPath.idleOpacity(at: 3.3, activity: activity) < 1e-9)
    #expect(CursorPath.idleOpacity(at: 5.0, activity: activity) == 0)
    #expect(abs(CursorPath.idleOpacity(at: 5.925, activity: activity) - 0.5) < 1e-9)   // fading back in over 0.15 s
    #expect(CursorPath.idleOpacity(at: 6.0, activity: activity) == 1)
    // Sub-threshold drift is not activity; a click is.
    let samples = (0..<90).map { RecordingSession.CursorSample(t: Double($0) / 30, x: 500 + 0.3 * Double($0 % 2), y: 300) }
    #expect(CursorPath.activity(samples, threshold: 1, clicks: [2.5]) == [0, 2.5])
}

@Test func theOverlayFollowsTheLogWithKindRipplesAndScale() throws {
    let dir = try cursorlessSessionFolder()
    let s = try RecordingSession.load(dir.appendingPathComponent(RecordingSession.fileName))
    var style = CursorStyle()
    style.smoothing = 0
    let path = CursorPath(session: s, style: style, offset: 0)
    let a = try #require(path.overlay(atScreen: 2.7))
    #expect(abs(a.x - 470) < 1e-6 && a.y == 540)
    #expect(a.kind == .arrow && a.size == 3 && a.opacity == 1)
    #expect(a.ripples.count == 1 && abs(a.ripples[0].progress - 0.25) < 1e-6 && a.ripples[0].x == 300)
    #expect(path.overlay(atScreen: 4.5)?.kind == .pointingHand)
    #expect(path.overlay(atScreen: 3.2)?.ripples.isEmpty == true)
    style.clickRipple = false
    #expect(CursorPath(session: s, style: style, offset: 0).overlay(atScreen: 2.7)?.ripples.isEmpty == true)
    style.visible = false
    #expect(CursorPath(session: s, style: style, offset: 0).overlay(atScreen: 2.7) == nil)
}

@Test func cursorStyleIsOneUndoStepAndReachesTheScreenLayer() throws {
    let e = Engine(prober: SessionProber())
    try e.execute("project.new", params: ["name": "cursor", "width": 1920, "height": 1080])
    let r = try e.execute("recording.import", params: ["path": .string(try cursorlessSessionFolder().path)])
    #expect(r["cursorInVideo"]?.boolValue == false && r["events"]?["drags"]?.doubleValue == 0)
    #expect(e.project!.recordings!.last!.cursorInVideo == false)
    let screen = r["assets"]!["screen"]!.stringValue!
    func layer(_ e: Engine, at seconds: Double) -> VideoLayer? {
        RenderJob(project: e.project!, preset: .landscape, captions: false).layers(at: t(seconds).snapped(to: Rational(30))).first { $0.assetID == screen }
    }
    // Defaults: drawn at 1.5× the 2 px/pt screen.
    #expect(layer(e, at: 3)?.cursor?.size == 3)
    let styled = try e.checkUndoRedo("cursor.style", ["scale": 2, "color": "#ff8800", "smoothing": 0])
    #expect(styled["drawn"]?.boolValue == true && styled["style"]?["color"]?.stringValue == "#FF8800")
    let c = try #require(layer(e, at: 3)?.cursor)
    #expect(c.size == 4 && c.color == "#FF8800")
    // Timeline 3 s = session 3.25 s (origin 0.25): the raw cursor is at 200 + 325.
    #expect(abs(c.x - 525) < 4)
    // Only the given fields change; reset goes back to the defaults (nothing stored).
    try e.execute("cursor.style", params: ["hideWhenIdle": false])
    #expect(e.project!.recordings!.last!.cursor?.scale == 2 && e.project!.recordings!.last!.cursor?.hideWhenIdle == false)
    try e.execute("cursor.style", params: ["reset": true])
    #expect(e.project!.recordings!.last!.cursor == nil)
    try e.execute("cursor.style", params: ["visible": false])
    #expect(layer(e, at: 3)?.cursor == nil)
    #expect(throws: CommandError.self) { try e.execute("cursor.style", params: ["scale": 9]) }
    #expect(throws: CommandError.self) { try e.execute("cursor.style", params: ["color": "orange"]) }
    // A take with the cursor baked in keeps the style but draws nothing.
    let (old, _) = try recordingEngine()
    let w = try old.execute("cursor.style", params: ["scale": 2])
    #expect(w["drawn"]?.boolValue == false && w["warnings"]?.arrayValue?.count == 1)
    #expect(RenderJob(project: old.project!, preset: .landscape, captions: false).layers(at: t(3)).allSatisfy { $0.cursor == nil })
}

@Test func importReportsTheDragsOfTheTake() throws {
    let dir = try cursorlessSessionFolder()
    let url = dir.appendingPathComponent(RecordingSession.fileName)
    var s = try RecordingSession.load(url)
    // Hold the 4.0 s click for 0.5 s: the cursor (100 px/s) travels 50 px > 33 px.
    s.events = s.events.map { $0.kind == "mouseUp" && abs($0.t - 4.1) < 1e-9 ? RecordingSession.Event(kind: "mouseUp", t: 4.5, x: 650, y: 540) : $0 }
    try s.write(to: url)
    #expect(s.drags.count == 1 && s.drags[0].start == 4)
    let e = Engine(prober: SessionProber())
    try e.execute("project.new", params: ["name": "drags"])
    #expect(try e.execute("recording.import", params: ["path": .string(dir.path)])["events"]?["drags"]?.doubleValue == 1)
}
