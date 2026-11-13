import Foundation

/// Per-frame face boxes of a video, in display pixels (rotation applied, origin top-left).
/// Saved as a sidecar JSON next to the project; the project keeps a `FaceTrackSummary`.
public struct FaceTrack: Codable, Hashable, Sendable {
    public struct Frame: Codable, Hashable, Sendable {
        /// Seconds from the start of the video.
        public var t: Double
        /// [x, y, width, height] as detected, nil when no face was found.
        public var raw: [Double]?
        /// One-Euro smoothed box (held through missed detections, reset at cuts).
        public var smooth: [Double]?
        /// Optional landmark points (eyes, nose, mouth), [x, y].
        public var points: [String: [Double]]?
        /// The other faces found in the frame (a child in the arms, a second speaker), same box kind as `raw`.
        public var others: [[Double]]?

        public init(t: Double, raw: [Double]?, smooth: [Double]? = nil, points: [String: [Double]]? = nil, others: [[Double]]? = nil) {
            self.t = t
            self.raw = raw
            self.smooth = smooth
            self.points = points
            self.others = others
        }

        /// Every face of the frame, the main one first.
        public var all: [[Double]] { (raw.map { [$0] } ?? []) + (others ?? []) }
    }

    public var video: String
    public var engine: String
    public var width: Int
    public var height: Int
    public var fps: Double
    public var minCutoff: Double
    public var beta: Double
    /// Frame indices where a new shot starts (filter reset).
    public var cuts: [Int]
    public var frames: [Frame]

    public init(video: String, engine: String, width: Int, height: Int, fps: Double, minCutoff: Double, beta: Double,
                cuts: [Int], frames: [Frame]) {
        self.video = video
        self.engine = engine
        self.width = width
        self.height = height
        self.fps = fps
        self.minCutoff = minCutoff
        self.beta = beta
        self.cuts = cuts
        self.frames = frames
    }

    public var detected: Int { frames.filter { $0.raw != nil }.count }
    /// Frames with more than one face.
    public var multiFace: Int { frames.filter { !($0.others ?? []).isEmpty }.count }

    /// The frame showing source time `t` (nearest by index), nil outside the video.
    public func frame(at t: Double) -> Frame? {
        guard !frames.isEmpty, fps > 0 else { return nil }
        var k = Int((t * fps).rounded(.down))
        k = min(max(k, 0), frames.count - 1)
        // Timestamps may not start at 0 or be perfectly regular: walk to the closest one.
        while k + 1 < frames.count, abs(frames[k + 1].t - t) < abs(frames[k].t - t) { k += 1 }
        while k > 0, abs(frames[k - 1].t - t) < abs(frames[k].t - t) { k -= 1 }
        return abs(frames[k].t - t) <= 1.5 / fps ? frames[k] : nil
    }

    /// Within-shot shake of the box centre: RMS of the second difference, px (raw or smoothed).
    public func jitter(smoothed: Bool) -> Double {
        let cut = Set(cuts)
        var acc: [Double] = []
        func centre(_ b: [Double]) -> (Double, Double) { (b[0] + b[2] / 2, b[1] + b[3] / 2) }
        for k in frames.indices.dropFirst(2) {
            if cut.contains(k) || cut.contains(k - 1) { continue }
            let boxes = [k - 2, k - 1, k].map { smoothed ? frames[$0].smooth : frames[$0].raw }
            guard let a = boxes[0], let b = boxes[1], let c = boxes[2] else { continue }
            let (ax, ay) = centre(a), (bx, by) = centre(b), (cx, cy) = centre(c)
            acc.append(hypot(cx - 2 * bx + ax, cy - 2 * by + ay))
        }
        guard !acc.isEmpty else { return 0 }
        return (acc.map { $0 * $0 }.reduce(0, +) / Double(acc.count)).squareRoot()
    }

    /// Mean frame-to-frame step of the box centre, px.
    public func meanStep(smoothed: Bool) -> Double {
        let cut = Set(cuts)
        var steps: [Double] = []
        for k in frames.indices.dropFirst() where !cut.contains(k) {
            guard let a = smoothed ? frames[k - 1].smooth : frames[k - 1].raw,
                  let b = smoothed ? frames[k].smooth : frames[k].raw else { continue }
            steps.append(hypot(b[0] + b[2] / 2 - a[0] - a[2] / 2, b[1] + b[3] / 2 - a[1] - a[3] / 2))
        }
        return steps.isEmpty ? 0 : steps.reduce(0, +) / Double(steps.count)
    }

    /// Fills `smooth` from `raw`: One-Euro per coordinate (centre x/y, width, height), reset at cuts,
    /// last box held through missed detections.
    public mutating func smooth() {
        let cut = Set(cuts)
        var filters: [OneEuroFilter] = []
        var last: [Double]?
        for k in frames.indices {
            if k == 0 || cut.contains(k) {
                filters = (0..<4).map { _ in OneEuroFilter(rate: fps, minCutoff: minCutoff, beta: beta) }
                last = nil
            }
            if let r = frames[k].raw {
                let c = [r[0] + r[2] / 2, r[1] + r[3] / 2, r[2], r[3]]
                let s = zip(filters.indices, c).map { filters[$0].filter($1) }
                last = [s[0] - s[2] / 2, s[1] - s[3] / 2, s[2], s[3]].map { ($0 * 100).rounded() / 100 }
            }
            frames[k].smooth = last
        }
    }
}

/// Casiez et al. 2012: low jitter when still, low lag when moving. Units: value units, Hz.
public struct OneEuroFilter: Sendable {
    public var rate: Double
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff = 1.0
    var x: Double?
    var dx = 0.0

    public init(rate: Double, minCutoff: Double, beta: Double) {
        self.rate = rate
        self.minCutoff = minCutoff
        self.beta = beta
    }

    func alpha(_ cutoff: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau * rate)
    }

    public mutating func filter(_ value: Double) -> Double {
        guard let prev = x else { x = value; dx = 0; return value }
        let d = (value - prev) * rate
        dx += alpha(derivativeCutoff) * (d - dx)
        let next = prev + alpha(minCutoff + beta * abs(dx)) * (value - prev)
        x = next
        return next
    }
}
