import Foundation

// Auto-zoom on clicks (issue #6, the Screen Studio idea): the screen clip zooms in smoothly on each click, holds,
// pans to the next click when they come close together, and zooms back out. Optionally the resting framing
// follows the cursor (vertical reels show a narrow slice of a wide screen). Written as ordinary crop keyframes
// on the screen clips, so the result can be inspected, edited with clip.keyframe and undone in one step.

public struct ZoomOptions: Hashable, Sendable {
    /// Magnification at the click (1.8 = the crop is 1/1.8 of the resting framing).
    public var zoom = 1.8
    /// Seconds held after the last click of a group before zooming out.
    public var hold = 1.0
    /// Seconds of the zoom-in, ending on the click.
    public var easeIn = 0.45
    /// Seconds of the zoom-out.
    public var easeOut = 0.6
    /// Longest pan between two clicks of a group.
    public var pan = 0.45
    public var easing = Easing.easeInOut
    /// Clicks closer than zoom-out + zoom-in + this gap stay zoomed and pan instead.
    public var mergeGap = 0.6
    /// The resting framing follows the (smoothed) cursor instead of staying centred.
    public var follow = false
    /// Smoothing time constant of the cursor follow, seconds.
    public var followSmoothing = 0.5
    /// Follow only: the camera holds while the smoothed cursor stays inside this central fraction of the visible
    /// frame and moves just enough to bring it back when it leaves (0 = follow every move, the old behaviour).
    public var safeZone = 0.6
    /// Shutter of the camera-move blur, fraction of a frame (0 = none); written on the screen clips.
    public var motionBlur = 0.5

    public init() {}
}

/// One click in screen-source time (seconds of screen.mov) and pixels.
public struct ZoomClick: Hashable, Sendable {
    public var t: Double
    public var x: Double
    public var y: Double
    /// When the press was a drag: the (smoothed) cursor from the press to the release, the last point being the
    /// release. The zoom holds and pans along it instead of zooming out mid-drag (DragHold).
    public var drag: [ZoomClick]?

    public init(t: Double, x: Double, y: Double, drag: [ZoomClick]? = nil) {
        self.t = t
        self.x = x
        self.y = y
        self.drag = drag
    }

    /// When the press ends: the release of a drag, else the click itself.
    public var end: ZoomClick { drag?.last ?? ZoomClick(t: t, x: x, y: y) }
}

/// A key of the camera move: at screen time `t`, magnification `zoom` around `centre` (nil = the resting centre:
/// the middle of the screen area, or the smoothed cursor), easing towards the next key.
public struct ZoomKey: Hashable, Sendable {
    public var t: Double
    public var zoom: Double
    public var centre: [Double]?
    public var easing: Easing

    public init(t: Double, zoom: Double, centre: [Double]?, easing: Easing) {
        self.t = t
        self.zoom = zoom
        self.centre = centre
        self.easing = easing
    }
}

public enum AutoZoom {
    /// Clicks grouped into zoom windows (close clicks share one zoom and pan between them).
    public static func groups(_ clicks: [ZoomClick], _ o: ZoomOptions) -> [[ZoomClick]] {
        var out: [[ZoomClick]] = []
        for c in clicks.sorted(by: { $0.t < $1.t }) {
            // Measured from the release: a click right after a long drag still pans instead of zooming out and in.
            if let last = out.last?.last, c.t - last.end.t < o.hold + o.easeOut + o.easeIn + o.mergeGap {
                out[out.count - 1].append(c)
            } else {
                out.append([c])
            }
        }
        return out
    }

    /// The keys of the whole move, sorted (rest → zoomed on the first click → pans → hold → rest).
    public static func keys(_ clicks: [ZoomClick], _ o: ZoomOptions) -> [ZoomKey] {
        var keys: [ZoomKey] = []
        for g in groups(clicks, o) {
            let first = g[0]
            keys.append(ZoomKey(t: max(first.t - o.easeIn, keys.last.map { $0.t + 0.01 } ?? -.infinity), zoom: 1, centre: nil, easing: o.easing))
            keys.append(ZoomKey(t: first.t, zoom: o.zoom, centre: [first.x, first.y], easing: o.easing))
            appendDrag(first, &keys, o)
            for k in g.indices.dropFirst() {
                let prev = g[k - 1].end, c = g[k]
                let pan = min(o.pan, (c.t - prev.t) * 0.6)
                if c.t - pan > prev.t + 0.01 { keys.append(ZoomKey(t: c.t - pan, zoom: o.zoom, centre: [prev.x, prev.y], easing: o.easing)) }
                keys.append(ZoomKey(t: c.t, zoom: o.zoom, centre: [c.x, c.y], easing: o.easing))
                appendDrag(c, &keys, o)
            }
            let last = g[g.count - 1].end
            keys.append(ZoomKey(t: last.t + o.hold, zoom: o.zoom, centre: [last.x, last.y], easing: o.easing))
            keys.append(ZoomKey(t: last.t + o.hold + o.easeOut, zoom: 1, centre: nil, easing: o.easing))
        }
        return keys
    }

    /// During a drag the zoom stays and the camera travels with the dragged cursor: keys every ~0.2 s along the
    /// smoothed path, linear between them (the path itself is smooth), ending on the release.
    static func appendDrag(_ c: ZoomClick, _ keys: inout [ZoomKey], _ o: ZoomOptions) {
        guard let path = c.drag, let release = path.last, release.t > c.t + 0.01 else { return }
        keys[keys.count - 1].easing = .linear
        var next = c.t + 0.2
        for p in path.dropLast() where p.t >= next && p.t < release.t - 0.1 {
            keys.append(ZoomKey(t: p.t, zoom: o.zoom, centre: [p.x, p.y], easing: .linear))
            next = p.t + 0.2
        }
        keys.append(ZoomKey(t: release.t, zoom: o.zoom, centre: [release.x, release.y], easing: o.easing))
    }

    /// Zoom and centre at screen time `u` (`rest(u)` is the resting centre at that time).
    public static func state(at u: Double, keys: [ZoomKey], rest: (Double) -> [Double]) -> (zoom: Double, centre: [Double]) {
        guard let first = keys.first else { return (1, rest(u)) }
        func centre(_ k: ZoomKey) -> [Double] { k.centre ?? rest(u) }
        if u <= first.t { return (first.zoom, centre(first)) }
        guard let n = keys.firstIndex(where: { $0.t > u }) else { return (keys.last!.zoom, centre(keys.last!)) }
        let a = keys[n - 1], b = keys[n]
        let p = a.easing.apply((u - a.t) / max(b.t - a.t, 1e-9))
        // Interpolate the crop's size (1/zoom) rather than the zoom: it is what the keyframes of the renderer mix.
        let wa = 1 / a.zoom, wb = 1 / b.zoom
        let ca = centre(a), cb = centre(b)
        return (1 / (wa + (wb - wa) * p), [ca[0] + (cb[0] - ca[0]) * p, ca[1] + (cb[1] - ca[1]) * p])
    }

    /// The crop [w, h, x, y] of aspect `aspect` (w/h) at `zoom` around `centre`, inside `area` ([w, h, x, y], the
    /// screen part the clip shows at rest): the largest rect of that aspect in the area, divided by the zoom,
    /// clamped inside the area.
    /// `anchor` is where the centre point should land inside the crop (fractions; 0.5, 0.5 = in the middle).
    public static func crop(zoom: Double, centre: [Double], aspect: Double, area: [Double], anchor: [Double] = [0.5, 0.5]) -> [Double] {
        var w = area[0], h = w / aspect
        if h > area[1] { h = area[1]; w = h * aspect }
        w /= max(zoom, 1e-6); h /= max(zoom, 1e-6)
        let x = min(max(centre[0] - anchor[0] * w, area[2]), area[2] + area[0] - w)
        let y = min(max(centre[1] - anchor[1] * h, area[3]), area[3] + area[1] - h)
        return [w, h, x, y]
    }

    /// The part of a screen layer drawn in `screen` ([x, y, w, h], output pixels) that the face leaves free when it
    /// covers `occluder`: the largest band above, below, left or right of it, as fractions [x0, y0, x1, y1] of the
    /// layer; the whole layer when the face covers little of it (a corner bubble).
    public static func freeBand(screen s: [Double], occluder o: [Double]?) -> [Double] {
        guard let o, s[2] > 0, s[3] > 0 else { return [0, 0, 1, 1] }
        let ix = max(0, min(s[0] + s[2], o[0] + o[2]) - max(s[0], o[0])), iy = max(0, min(s[1] + s[3], o[1] + o[3]) - max(s[1], o[1]))
        guard ix * iy > 0.12 * s[2] * s[3] else { return [0, 0, 1, 1] }
        let bands: [[Double]] = [
            [s[0], s[1], s[2], o[1] - s[1]],                                // above
            [s[0], o[1] + o[3], s[2], s[1] + s[3] - (o[1] + o[3])],          // below
            [s[0], s[1], o[0] - s[0], s[3]],                                // left
            [o[0] + o[2], s[1], s[0] + s[2] - (o[0] + o[2]), s[3]],          // right
        ].filter { $0[2] > 0 && $0[3] > 0 }
        guard let b = bands.max(by: { $0[2] * $0[3] < $1[2] * $1[3] }), b[2] * b[3] > 0.2 * s[2] * s[3] else { return [0, 0, 1, 1] }
        return [(b[0] - s[0]) / s[2], (b[1] - s[1]) / s[3], (b[0] + b[2] - s[0]) / s[2], (b[1] + b[3] - s[1]) / s[3]]
    }

    /// Where clicks should land inside the layer: the middle of the free band.
    public static func anchor(screen s: [Double], occluder o: [Double]?) -> [Double] {
        let b = freeBand(screen: s, occluder: o)
        return [(b[0] + b[2]) / 2, (b[1] + b[3]) / 2]
    }

    /// The zoomed keys of `keys` with their magnification raised (up to `maxZoom`) where a click near the edge of the
    /// screen would otherwise stay under the face: the crop cannot slide past the screen's edge, so only a closer
    /// zoom brings the click into the free band.
    public static func raisedForBand(_ keys: [ZoomKey], band: [Double], aspect: Double, area: [Double], maxZoom: Double = 2.5) -> [ZoomKey] {
        guard band != [0, 0, 1, 1] else { return keys }
        let anchor = [(band[0] + band[2]) / 2, (band[1] + band[3]) / 2]
        let mx = 0.08 * (band[2] - band[0]), my = 0.08 * (band[3] - band[1])
        return keys.map { k in
            guard let c = k.centre, k.zoom > 1 else { return k }
            var k = k
            var z = k.zoom
            while z < maxZoom {
                let r = crop(zoom: z, centre: c, aspect: aspect, area: area, anchor: anchor)
                let fx = (c[0] - r[2]) / r[0], fy = (c[1] - r[3]) / r[1]
                if fx >= band[0] + mx, fx <= band[2] - mx, fy >= band[1] + my, fy <= band[3] - my { break }
                z += 0.05
            }
            k.zoom = min(z, maxZoom)
            return k
        }
    }

    /// Cursor path smoothed forward and backward (zero lag) with time constant `tau`, sampled at `times`.
    public static func smoothedCursor(_ samples: [RecordingSession.CursorSample], offset: Double, times: [Double], tau: Double) -> [[Double]] {
        guard !samples.isEmpty else { return [] }
        let s = samples.sorted { $0.t < $1.t }
        func raw(_ u: Double) -> [Double] {
            let t = u + offset
            if t <= s[0].t { return [s[0].x, s[0].y] }
            guard let n = s.firstIndex(where: { $0.t > t }) else { return [s.last!.x, s.last!.y] }
            let a = s[n - 1], b = s[n]
            let f = (t - a.t) / max(b.t - a.t, 1e-9)
            return [a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f]
        }
        var out = times.map(raw)
        guard out.count > 1, tau > 0 else { return out }
        for pass in 0..<2 {
            let order = pass == 0 ? Array(out.indices) : Array(out.indices.reversed())
            var prev = out[order[0]]
            var prevT = times[order[0]]
            for i in order.dropFirst() {
                let dt = abs(times[i] - prevT)
                let a = 1 - exp(-dt / tau)
                prev = [prev[0] + (out[i][0] - prev[0]) * a, prev[1] + (out[i][1] - prev[1]) * a]
                out[i] = prev
                prevT = times[i]
            }
        }
        return out
    }

    /// Camera centres for the follow mode with a safe zone, one per entry of `cursor` (the smoothed cursor, sampled
    /// every `dt` s): the camera holds while the cursor stays within `zone` (half-extents, pixels) of it and moves just
    /// enough to bring the cursor back to the zone's edge when it leaves; `bounds` [x0, y0, x1, y1] is where the centre
    /// can go (the crop stays inside the screen area). The path is then eased with two passes of a `smoothing`-second
    /// moving average (finite support: holds stay exactly still), and pulled back where needed so the cursor (and the
    /// `raw` one, same sampling, which the smoothing rounds off on fast moves) stays at least `margin` inside the
    /// visible half-extents `frame`.
    public static func safeZoneCentres(_ cursor: [[Double]], raw: [[Double]]? = nil, dt: Double, zone: [Double], frame: [Double], bounds: [Double],
                                       margin: Double = 0.04, smoothing: Double = 0.3) -> [[Double]] {
        guard let p0 = cursor.first else { return [] }
        func clamp(_ v: Double, _ axis: Int) -> Double { min(max(v, bounds[axis]), max(bounds[axis], bounds[axis + 2])) }
        var c = [clamp(p0[0], 0), clamp(p0[1], 1)]
        var out: [[Double]] = []
        out.reserveCapacity(cursor.count)
        for p in cursor {
            for a in 0..<2 {
                if p[a] - c[a] > zone[a] { c[a] = p[a] - zone[a] } else if c[a] - p[a] > zone[a] { c[a] = p[a] + zone[a] }
                c[a] = clamp(c[a], a)
            }
            out.append(c)
        }
        let r = max(Int((smoothing / max(dt, 1e-6) / 2).rounded()), 0)
        if r > 0, out.count > 2 {
            for _ in 0..<2 {
                // Centred moving average with the ends held (prefix sums keep it linear in time).
                var sum = [[0.0, 0.0]]
                for v in out { sum.append([sum.last![0] + v[0], sum.last![1] + v[1]]) }
                let n = out.count
                out = (0..<n).map { i in
                    var acc = [0.0, 0.0]
                    for a in 0..<2 {
                        let lo = i - r, hi = i + r
                        var total = sum[min(hi, n - 1) + 1][a] - sum[max(lo, 0)][a]
                        if lo < 0 { total += Double(-lo) * out[0][a] }
                        if hi > n - 1 { total += Double(hi - n + 1) * out[n - 1][a] }
                        acc[a] = total / Double(2 * r + 1)
                    }
                    return acc
                }
            }
        }
        // The smoothing may cut a corner: never let the cursor out of the visible frame.
        for i in out.indices {
            for a in 0..<2 {
                let reach = frame[a] * (1 - margin)
                for p in [cursor[i], raw.map { $0[min(i, $0.count - 1)] }].compactMap({ $0 }) {
                    out[i][a] = min(max(out[i][a], p[a] - reach), p[a] + reach)
                }
                out[i][a] = clamp(out[i][a], a)
            }
        }
        return out
    }

    /// The keyframes of `frames` that matter: a keyframe whose crop lies within `tolerance` pixels of the straight
    /// line between its kept neighbours is dropped (camera holds become two keyframes instead of fifteen a second).
    public static func simplified(_ frames: [(t: Double, crop: [Double], easing: Easing?)], tolerance: Double = 0.5) -> [(t: Double, crop: [Double], easing: Easing?)] {
        guard frames.count > 2 else { return frames }
        func fits(_ a: Int, _ b: Int) -> Bool {
            let ta = frames[a].t, tb = frames[b].t
            for i in (a + 1)..<b {
                let f = (frames[i].t - ta) / max(tb - ta, 1e-9)
                for k in 0..<4 where abs(frames[a].crop[k] + (frames[b].crop[k] - frames[a].crop[k]) * f - frames[i].crop[k]) > tolerance { return false }
            }
            return true
        }
        var out = [frames[0]]
        var anchor = 0
        for i in 1..<(frames.count - 1) where frames[i].easing != nil || !fits(anchor, i + 1) {
            out.append(frames[i])
            anchor = i
        }
        out.append(frames[frames.count - 1])
        return out
    }

    /// Crop keyframes (clip-relative) of one screen clip reading screen times [sourceIn, sourceOut), drawn at
    /// `aspect`. Keys inside the clip become keyframes with their easing; a move cut by the clip's edge, and the
    /// cursor follow, are sampled every `step` seconds (linear). Empty when the clip stays at rest throughout.
    public static func keyframeCrops(keys: [ZoomKey], sourceIn: Double, sourceOut: Double, aspect: Double, area: [Double],
                                     rest: (Double) -> [Double], dense: Bool, anchor: [Double] = [0.5, 0.5],
                                     step: Double = 1.0 / 15) -> [(t: Double, crop: [Double], easing: Easing?)] {
        let dur = sourceOut - sourceIn
        guard dur > 0 else { return [] }
        var times: [(Double, Easing?)] = []
        if dense {
            var u = sourceIn
            while u < sourceOut - 1e-9 { times.append((u, nil)); u += step }
            times.append((sourceOut, nil))
            // Key times too, so the zoom peaks land exactly.
            for k in keys where k.t > sourceIn && k.t < sourceOut { times.append((k.t, nil)) }
            times.sort { $0.0 < $1.0 }
        } else {
            times.append((sourceIn, nil))
            for (i, k) in keys.enumerated() {
                if k.t > sourceIn, k.t < sourceOut { times.append((k.t, k.easing)) }
                guard i + 1 < keys.count else { continue }
                let end = keys[i + 1].t
                guard end > sourceIn, k.t < sourceOut else { continue }
                // A move the clip's edge cuts is sampled (linear between samples): re-easing a partial move would
                // change its timing.
                if k.t < sourceIn || end > sourceOut {
                    var u = max(k.t, sourceIn) + step
                    while u < min(end, sourceOut) - 1e-9 { times.append((u, nil)); u += step }
                }
            }
            times.append((sourceOut, nil))
            // Sorted by time; at equal times the key (with its easing) wins over a sample.
            times.sort { $0.0 != $1.0 ? $0.0 < $1.0 : ($0.1 != nil && $1.1 == nil) }
        }
        var out: [(t: Double, crop: [Double], easing: Easing?)] = []
        var anyZoom = false
        for (u, e) in times {
            if let last = out.last, abs(last.t - (u - sourceIn)) < 1e-6 { continue }
            let s = state(at: u, keys: keys, rest: rest)
            if s.zoom > 1.0001 { anyZoom = true }
            out.append((u - sourceIn, crop(zoom: s.zoom, centre: s.centre, aspect: aspect, area: area, anchor: anchor), e))
        }
        return anyZoom || dense ? out : []
    }
}
