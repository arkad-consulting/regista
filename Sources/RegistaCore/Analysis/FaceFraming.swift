import Foundation

/// Face-aware geometry shared by edit.punchIns (crops that never cut a head and keep every face in
/// frame) and the captions (which keep clear of every face). Face boxes are the tracker's landmark
/// extent (brow to chin), in source display pixels; boxes are [x, y, w, h], top-left origin.
public enum FaceFraming {
    /// The whole head around a landmark face box: hair above (0.6 of the face height), ears on the
    /// sides, the chin below.
    public static func head(_ b: [Double]) -> [Double] {
        [b[0] - 0.25 * b[2], b[1] - 0.6 * b[3], 1.5 * b[2], 1.75 * b[3]]
    }

    /// The zone a caption must keep out of: hair, eyes, nose and mouth (to just under the lower lip), with
    /// a margin on the sides. The chin may be covered — the approved talking-head look has the caption band
    /// right under the mouth — but never the mouth or anything above it.
    public static func captionZone(_ b: [Double]) -> [Double] {
        [b[0] - 0.1 * b[2], b[1] - 0.45 * b[3], 1.2 * b[2], 1.35 * b[3]]
    }

    public static func union(_ boxes: [[Double]]) -> [Double]? {
        guard let f = boxes.first else { return nil }
        var x0 = f[0], y0 = f[1], x1 = f[0] + f[2], y1 = f[1] + f[3]
        for b in boxes.dropFirst() { x0 = min(x0, b[0]); y0 = min(y0, b[1]); x1 = max(x1, b[0] + b[2]); y1 = max(y1, b[1] + b[3]) }
        return [x0, y0, x1 - x0, y1 - y0]
    }

    public static func intersects(_ a: [Double], _ b: [Double]) -> Bool {
        a[0] < b[0] + b[2] && b[0] < a[0] + a[2] && a[1] < b[1] + b[3] && b[1] < a[1] + a[3]
    }

    /// Is `inner` inside `outer` (with `tolerance` px of slack)?
    public static func contains(_ outer: [Double], _ inner: [Double], tolerance: Double = 0.5) -> Bool {
        inner[0] >= outer[0] - tolerance && inner[1] >= outer[1] - tolerance
            && inner[0] + inner[2] <= outer[0] + outer[2] + tolerance && inner[1] + inner[3] <= outer[1] + outer[3] + tolerance
    }

    /// The faces of each frame in a source range, without the stray detections: a face counts when a
    /// face is found at about the same place in at least `minPresence` of the frames.
    public static func faces(_ track: FaceTrack, from s0: Double, to s1: Double, minPresence: Double = 0.15) -> [(t: Double, boxes: [[Double]])] {
        let frames = track.frames.filter { $0.t >= s0 - 1e-6 && $0.t < s1 - 1e-6 }
        guard !frames.isEmpty else { return [] }
        let all = frames.map(\.all)
        func near(_ a: [Double], _ b: [Double]) -> Bool {
            let d = hypot(a[0] + a[2] / 2 - b[0] - b[2] / 2, a[1] + a[3] / 2 - b[1] - b[3] / 2)
            return d < 0.6 * max(a[2], a[3], b[2], b[3])
        }
        let need = max(1, Int((minPresence * Double(frames.count)).rounded(.up)))
        // Presence of a box = frames (in a ±2 s window, enough for handheld drift) with a face near it.
        let window = Int(2 * track.fps)
        return frames.indices.map { k in
            let kept = all[k].filter { b in
                let lo = max(0, k - window), hi = min(all.count - 1, k + window)
                let span = hi - lo + 1
                let n = (lo...hi).filter { j in all[j].contains { near($0, b) } }.count
                return n >= min(need, max(1, span / 4))
            }
            return (frames[k].t, kept)
        }
    }

    public struct Options: Sendable {
        /// Crop height as a fraction of the largest crop of the output aspect (1 = no zoom).
        public var zoom = 0.8
        /// Space kept above the hair, fraction of the crop height.
        public var headroom = 0.05
        /// Moving-average window on the crop position when it has to move, seconds.
        public var smooth = 0.6
        /// Fastest pan of a moving crop, fraction of the crop width per second.
        public var maxSpeed = 0.25
        /// The main head (hair to chin, median over the shot) fills at most this fraction of the crop height:
        /// a close selfie is zoomed less than a medium shot (0.6 ≈ the approved WeSites base framing).
        public var maxHead = 0.6

        public init(zoom: Double = 0.8, headroom: Double = 0.05, smooth: Double = 0.6, maxSpeed: Double = 0.25, maxHead: Double = 0.6) {
            self.zoom = zoom
            self.headroom = headroom
            self.smooth = smooth
            self.maxSpeed = maxSpeed
            self.maxHead = maxHead
        }
    }

    public struct Path: Sendable {
        /// Clip-relative times (seconds) and crops [w, h, x, y]; one point = a static crop.
        public var points: [(time: Double, crop: [Double])]
        /// Every head (with headroom) inside the crop on every frame.
        public var fits: Bool
        /// Largest number of faces kept on one frame.
        public var faces: Int
    }

    /// The crop path of one clip (source range [s0, s1)): at the zoom asked for when the heads allow it,
    /// larger when they need it (two faces apart, a head near the edge); static whenever one crop can
    /// hold every head of the clip, else following them, smoothed and speed-limited.
    public static func cropPath(_ track: FaceTrack, from s0: Double, to s1: Double, frame: (Int, Int), aspect: Double,
                                options: Options = Options()) -> Path? {
        let samples = faces(track, from: s0, to: s1)
        guard !samples.isEmpty else { return nil }
        let W = Double(frame.0), H = Double(frame.1)
        // The largest crop of the output aspect.
        let (maxW, maxH) = W / H > aspect ? (H * aspect, H) : (W, W / aspect)
        // Required rectangle per frame: every head, held through frames without a detection.
        var req: [[Double]?] = samples.map { FaceFraming.union($0.boxes.compactMap { clip(head($0), to: frame) }) }
        var last: [Double]?
        for k in req.indices { if let r = req[k] { last = r } else { req[k] = last } }
        last = nil
        for k in req.indices.reversed() { if let r = req[k] { last = r } else { req[k] = last } }
        guard req.allSatisfy({ $0 != nil }) else { return nil }
        // Each frame also holds its neighbours' heads (±1 frame): the crop never lags a moving head.
        let n = req.count
        let rects: [[Double]] = (0..<n).map { k in
            FaceFraming.union((max(0, k - 1)...min(n - 1, k + 1)).map { req[$0]! })!
        }
        // Size: the zoom asked for, grown until every head fits with its headroom.
        let needH = rects.map { max($0[3] / (1 - options.headroom - 0.01), $0[2] / aspect) }.max()!
        let heads = samples.compactMap { $0.boxes.max { $0[3] < $1[3] } }.map { 1.75 * $0[3] }.sorted()
        let headH = heads.isEmpty ? 0 : heads[heads.count / 2]
        var ch = min(maxH, max(options.zoom * maxH, needH, headH / options.maxHead))
        var cw = ch * aspect
        if cw > maxW { cw = maxW; ch = cw / aspect }
        let fits = needH <= ch + 0.5
        let room = options.headroom * ch
        // Feasible positions per frame (the crop holds the heads) and the preferred one (hair under the headroom).
        func bounds(_ r: [Double]) -> (x: ClosedRange<Double>, y: ClosedRange<Double>, want: (Double, Double)) {
            let xlo = max(0, min(r[0] + r[2] - cw, W - cw)), xhi = min(W - cw, max(r[0], 0))
            let ylo = max(0, min(r[1] + r[3] - ch, H - ch)), yhi = min(H - ch, max(r[1] - room, 0))
            let x = xlo <= xhi ? xlo...xhi : (xlo + xhi) / 2...(xlo + xhi) / 2
            let y = ylo <= yhi ? ylo...yhi : (ylo + yhi) / 2...(ylo + yhi) / 2
            return (x, y, (r[0] + r[2] / 2 - cw / 2, r[1] - room))
        }
        var b = rects.map(bounds)
        func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        let facesKept = samples.map(\.boxes.count).max() ?? 0
        // Static when one position holds every frame.
        let sx = (lo: b.map(\.x.lowerBound).max()!, hi: b.map(\.x.upperBound).min()!)
        let sy = (lo: b.map(\.y.lowerBound).max()!, hi: b.map(\.y.upperBound).min()!)
        if sx.lo <= sx.hi + 0.5, sy.lo <= sy.hi + 0.5 {
            let wx = b.map(\.want.0).sorted()[n / 2], wy = b.map(\.want.1).sorted()[n / 2]
            let x = sx.lo <= sx.hi ? clamp(wx, sx.lo...sx.hi) : sx.lo
            let y = sy.lo <= sy.hi ? clamp(wy, sy.lo...sy.hi) : sy.lo
            return Path(points: [(0, [r1(cw), r1(ch), r1(x), r1(y)])], fits: fits, faces: facesKept)
        }
        // Moving: preferred position, smoothed, kept feasible, speed-limited (feasibility wins). Keyframes are
        // 5 frames apart and interpolated: each frame's range is narrowed to what holds its ±5 neighbours too, so
        // the straight line between two keyframes stays feasible.
        let b0 = b
        b = b0.indices.map { k in
            let b = b0
            let win = (max(0, k - 5)...min(n - 1, k + 5)).map { b[$0] }
            let xl = win.map(\.x.lowerBound).max()!, xh = win.map(\.x.upperBound).min()!
            let yl = win.map(\.y.lowerBound).max()!, yh = win.map(\.y.upperBound).min()!
            return (xl <= xh ? xl...xh : b[k].x, yl <= yh ? yl...yh : b[k].y, b[k].want)
        }
        let half = max(Int((options.smooth * track.fps / 2).rounded()), 0)
        var xs = b.map { clamp($0.want.0, $0.x) }, ys = b.map { clamp($0.want.1, $0.y) }
        func smoothed(_ v: [Double]) -> [Double] {
            v.indices.map { k in let lo = max(0, k - half), hi = min(v.count - 1, k + half); return v[lo...hi].reduce(0, +) / Double(hi - lo + 1) }
        }
        xs = smoothed(xs).enumerated().map { clamp($1, b[$0].x) }
        ys = smoothed(ys).enumerated().map { clamp($1, b[$0].y) }
        let step = options.maxSpeed * cw / track.fps
        for k in xs.indices.dropFirst() {
            xs[k] = clamp(min(max(xs[k], xs[k - 1] - step), xs[k - 1] + step), b[k].x)
            ys[k] = clamp(min(max(ys[k], ys[k - 1] - step), ys[k - 1] + step), b[k].y)
        }
        // Every frame feasible on its own; keyframes every 5 frames, plus wherever the interpolation would cut a head.
        for k in xs.indices { xs[k] = clamp(xs[k], b0[k].x); ys[k] = clamp(ys[k], b0[k].y) }
        var picks = Array(stride(from: 0, to: n, by: 5))
        if picks.last != n - 1 { picks.append(n - 1) }
        var changed = true
        while changed {
            changed = false
            var p = 0
            for k in 0..<n {
                while p + 1 < picks.count, picks[p + 1] <= k { p += 1 }
                guard p + 1 < picks.count, picks[p] != k else { continue }
                let a = picks[p], c = picks[p + 1], f = Double(k - a) / Double(c - a)
                let x = xs[a] + (xs[c] - xs[a]) * f, y = ys[a] + (ys[c] - ys[a]) * f
                if x < b0[k].x.lowerBound - 0.5 || x > b0[k].x.upperBound + 0.5 || y < b0[k].y.lowerBound - 0.5 || y > b0[k].y.upperBound + 0.5 {
                    picks.insert(k, at: p + 1)
                    changed = true
                    break
                }
            }
        }
        let points = picks.map { k in (time: max(samples[k].t - s0, 0), crop: [r1(cw), r1(ch), r1(xs[k]), r1(ys[k])]) }
        return Path(points: points, fits: fits, faces: facesKept)
    }

    /// A box cut to the source frame (a head partly out of the shot can only be kept as far as it is in it); nil when outside.
    public static func clip(_ b: [Double], to frame: (Int, Int)) -> [Double]? {
        let x0 = max(b[0], 0), y0 = max(b[1], 0), x1 = min(b[0] + b[2], Double(frame.0)), y1 = min(b[1] + b[3], Double(frame.1))
        return x1 > x0 && y1 > y0 ? [x0, y0, x1 - x0, y1 - y0] : nil
    }

    /// The heads of a frame (cut to the source frame) that are not wholly inside `crop` [w, h, x, y], with
    /// `headroom` (fraction of the crop height) above the hair where the frame has it: what a framing check reports.
    public static func cutHeads(_ boxes: [[Double]], crop: [Double], frame: (Int, Int), headroom: Double = 0) -> [[Double]] {
        let c = [crop[2], crop[3], crop[0], crop[1]]
        return boxes.compactMap { clip(head($0), to: frame) }.filter { h in
            let room = min(headroom * crop[1], h[1])   // no headroom to ask for above the frame's own top
            return !contains(c, [h[0], h[1] - room, h[2], h[3] + room], tolerance: 1)
        }
    }
}
