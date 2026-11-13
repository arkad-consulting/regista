import Foundation

// Drag-aware auto-zoom (issue #43): a press that moves (drag a window, select text, move a slider) must not zoom
// out or jump to the next click halfway through. Sessions with the mouse-up log (issue #42) say exactly which presses
// are drags (Drags.detect); older sessions only have clicks and the cursor, so there sustained movement starting
// right after a click is taken for a drag.

public enum DragHold {
    /// Heuristic only: the cursor must already be moving this soon after the click, seconds…
    static let startWithin = 0.3
    /// …and the drag ends once the cursor has stayed within `restRadius` of the diagonal for `restTime` seconds.
    static let restRadius = 0.004
    static let restTime = 0.15
    /// Longest drag the heuristic will believe, seconds.
    static let maxHeuristic = 6.0

    /// The release time (session time) of each click that starts a drag, keyed by the click's index in `clicks`
    /// (session times and screen.mov pixels; `width`×`height` is the screen's size in pixels).
    public static func releases(clicks: [(t: Double, x: Double, y: Double)], events: [RecordingSession.Event],
                                cursor: [RecordingSession.CursorSample], width: Double, height: Double) -> [Int: Double] {
        var out: [Int: Double] = [:]
        if events.contains(where: { $0.kind == "mouseUp" }) {
            for d in Drags.detect(events: events, cursor: cursor, width: width, height: height) {
                if let i = clicks.firstIndex(where: { abs($0.t - d.start) < 1e-6 }) { out[i] = d.end }
            }
            return out
        }
        let diagonal = hypot(width, height)
        let samples = cursor.sorted { $0.t < $1.t }
        let order = clicks.indices.sorted { clicks[$0].t < clicks[$1].t }
        for (n, i) in order.enumerated() {
            let c = clicks[i]
            let next = n + 1 < order.count ? clicks[order[n + 1]].t : .infinity
            guard let r = heuristicRelease(after: c, until: next, samples: samples, diagonal: diagonal), r - c.t >= Drags.minDuration else { continue }
            let travel = samples.filter { $0.t >= c.t && $0.t <= r }.map { hypot($0.x - c.x, $0.y - c.y) }.max() ?? 0
            if travel > Drags.minTravel * diagonal { out[i] = r }
        }
        return out
    }

    /// Without a mouse-up log: the cursor moving within `startWithin` of the click and then until it rests.
    static func heuristicRelease(after c: (t: Double, x: Double, y: Double), until next: Double, samples: [RecordingSession.CursorSample],
                                 diagonal: Double) -> Double? {
        let span = samples.filter { $0.t >= c.t && $0.t < min(next, c.t + maxHeuristic) }
        // The cursor must be on the click when it happens (a log that disagrees with its clicks proves nothing)…
        guard let origin = span.first, origin.t - c.t < 0.05, hypot(origin.x - c.x, origin.y - c.y) <= Drags.minTravel * diagonal,
              // …and already moving away from it right after.
              let early = span.last(where: { $0.t <= c.t + startWithin }),
              hypot(early.x - origin.x, early.y - origin.y) > restRadius * diagonal else { return nil }
        // It rests again once it stays put for restTime (looked for after it got going: a drag may start slowly).
        guard var restStart = span.firstIndex(where: { hypot($0.x - origin.x, $0.y - origin.y) > restRadius * diagonal }) else { return nil }
        for k in span.indices.dropFirst(restStart + 1) {
            if hypot(span[k].x - span[restStart].x, span[k].y - span[restStart].y) > restRadius * diagonal {
                restStart = k
            } else if span[k].t - span[restStart].t >= restTime {
                return span[restStart].t
            }
        }
        return span.last?.t
    }
}
