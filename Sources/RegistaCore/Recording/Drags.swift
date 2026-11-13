import Foundation

// Drags in a screen recording (issue #42, used by the drag-aware zoom of #43): a left-button press that lasts long
// enough and travels far enough is a drag (a selection, a slider, a window moved), not a click.

/// A left-button press: down at a `click` event, up at the next `mouseUp`. Session time, screen.mov pixels.
public struct Press: Hashable, Sendable {
    public var down: Double
    public var up: Double
    public var x: Double
    public var y: Double

    public init(down: Double, up: Double, x: Double, y: Double) {
        self.down = down
        self.up = up
        self.x = x
        self.y = y
    }
}

/// A press that moved: from the press point to where the button was released.
public struct Drag: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var from: [Double]
    public var to: [Double]
    /// Farthest the cursor got from the press point, pixels.
    public var travel: Double

    public init(start: Double, end: Double, from: [Double], to: [Double], travel: Double) {
        self.start = start
        self.end = end
        self.from = from
        self.to = to
        self.travel = travel
    }
}

public enum Drags {
    /// A drag lasts at least this long, seconds.
    public static let minDuration = 0.16
    /// …and travels farther than this fraction of the screen's diagonal.
    public static let minTravel = 0.015

    /// Presses: each click paired with the first mouseUp after it, before the next click. Sessions without mouseUp
    /// events (before issue #42) have none.
    public static func presses(_ events: [RecordingSession.Event]) -> [Press] {
        let sorted = events.sorted { $0.t < $1.t }
        var out: [Press] = []
        var open: RecordingSession.Event?
        for e in sorted {
            switch e.kind {
            case "click": if e.x != nil, e.y != nil { open = e }
            case "mouseUp":
                if let d = open { out.append(Press(down: d.t, up: e.t, x: d.x!, y: d.y!)) }
                open = nil
            default: break
            }
        }
        return out
    }

    /// The drags of a take whose screen is `width`×`height` pixels: presses of ≥ `minDuration` during which the
    /// cursor (samples inside the press, and the release point) got farther than `minTravel` × diagonal from the
    /// press point.
    public static func detect(events: [RecordingSession.Event], cursor: [RecordingSession.CursorSample], width: Double, height: Double) -> [Drag] {
        let limit = minTravel * (width * width + height * height).squareRoot()
        let samples = cursor.sorted { $0.t < $1.t }
        let ups = Dictionary(events.filter { $0.kind == "mouseUp" }.map { ($0.t, $0) }, uniquingKeysWith: { a, _ in a })
        return presses(events).compactMap { p in
            guard p.up - p.down >= minDuration else { return nil }
            var path = samples.filter { $0.t >= p.down && $0.t <= p.up }.map { [$0.x, $0.y] }
            if let up = ups[p.up], let x = up.x, let y = up.y { path.append([x, y]) }
            let far = path.map { hypot($0[0] - p.x, $0[1] - p.y) }.max() ?? 0
            guard far > limit, let end = path.last else { return nil }
            return Drag(start: p.down, end: p.up, from: [p.x, p.y], to: end, travel: far)
        }
    }
}

extension RecordingSession {
    /// Drags on the screen (empty without a screen source of known size or without mouseUp events).
    public var drags: [Drag] {
        guard let s = source("screen"), let w = s.width, let h = s.height else { return [] }
        return Drags.detect(events: events, cursor: cursor ?? [], width: Double(w), height: Double(h))
    }
}
