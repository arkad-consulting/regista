import Foundation

/// Per-frame hand poses of a video over a time range, display pixels (rotation applied, origin top-left), from Apple
/// Vision's hand pose request (hands.track). Saved as a sidecar JSON like the face track; the asset keeps a summary.
public struct HandTrack: Codable, Hashable, Sendable {
    public struct Hand: Codable, Hashable, Sendable {
        /// "left" | "right" as Vision reports it (the person's own hand), "?" when unknown.
        public var chirality: String
        /// Centre of the palm: the mean of the wrist and the four finger knuckles (MCP joints).
        public var palm: [Double]
        public var wrist: [Double]
        /// Index finger tip.
        public var index: [Double]
        /// Box of the confident joints [x, y, w, h].
        public var box: [Double]
        /// 0 (fist) … 1 (open, fingers spread): fingertip distance from the wrist relative to the palm size.
        public var open: Double
        /// Mean joint confidence 0…1.
        public var confidence: Double

        public init(chirality: String, palm: [Double], wrist: [Double], index: [Double], box: [Double], open: Double, confidence: Double) {
            self.chirality = chirality
            self.palm = palm
            self.wrist = wrist
            self.index = index
            self.box = box
            self.open = open
            self.confidence = confidence
        }

        /// The point a follower sits on: palm, index (fingertip) or wrist.
        public func point(_ name: String) -> [Double] {
            switch name {
            case "index": index
            case "wrist": wrist
            default: palm
            }
        }
    }

    public struct Frame: Codable, Hashable, Sendable {
        /// Seconds from the start of the video.
        public var t: Double
        public var hands: [Hand]

        public init(t: Double, hands: [Hand]) {
            self.t = t
            self.hands = hands
        }
    }

    public var video: String
    public var engine: String
    public var width: Int
    public var height: Int
    public var fps: Double
    /// Source range analysed, seconds.
    public var from: Double
    public var to: Double
    public var frames: [Frame]

    public init(video: String, engine: String, width: Int, height: Int, fps: Double, from: Double, to: Double, frames: [Frame]) {
        self.video = video
        self.engine = engine
        self.width = width
        self.height = height
        self.fps = fps
        self.from = from
        self.to = to
        self.frames = frames
    }

    public var detected: Int { frames.filter { !$0.hands.isEmpty }.count }

    /// The frame nearest to source time `t` (within 1.5 frames), nil outside the analysed range.
    public func frame(at t: Double) -> Frame? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        while lo < hi { let mid = (lo + hi) / 2; if frames[mid].t < t { lo = mid + 1 } else { hi = mid } }
        if lo > 0, abs(frames[lo - 1].t - t) < abs(frames[lo].t - t) { lo -= 1 }
        return abs(frames[lo].t - t) <= 1.5 / max(fps, 1) ? frames[lo] : nil
    }

    /// The hand to follow in a frame: the given chirality, else the most open (then most confident) one; `minOpen`
    /// drops closed hands.
    public static func pick(_ hands: [Hand], chirality: String?, minOpen: Double) -> Hand? {
        hands.filter { (chirality == nil || chirality == "any" || $0.chirality == chirality) && $0.open >= minOpen }
            .max { ($0.open, $0.confidence) < ($1.open, $1.confidence) }
    }
}

/// What the project keeps about a hand track.
public struct HandTrackSummary: Codable, Hashable, Sendable {
    public var path: String
    public var frames: Int
    public var detected: Int
    public var from: Double
    public var to: Double

    public init(path: String, frames: Int, detected: Int, from: Double, to: Double) {
        self.path = path
        self.frames = frames
        self.detected = detected
        self.from = from
        self.to = to
    }
}

/// Hand poses of video frames (Apple Vision in RegistaEngines).
public protocol HandTracker {
    /// Frames of `video` between `from` and `to` source seconds, at most `maxHands` hands each.
    func track(_ video: URL, from: Double, to: Double, maxHands: Int) throws -> HandTrack
}

/// Source points of a tracked target (face or hand) mapped onto the output frame through the clips that show the asset,
/// smoothed (One-Euro) and with gaps held briefly: what clip.follow turns into keyframes.
public enum FollowPath {
    public struct Sample: Sendable {
        /// Timeline time.
        public var t: MediaTime
        /// Output pixels, nil when the target is not visible (lost, or the asset is not on screen).
        public var point: (x: Double, y: Double)?
        /// Scale hint from the target size (face width or palm size, output pixels).
        public var size: Double?
    }

    /// A source point through the layer of the clip that shows it (full frame or a layout box), output pixels.
    public static func toOutput(_ p: [Double], layer: VideoLayer, width: Int, height: Int) -> (Double, Double)? {
        guard layer.crop[0] > 0, layer.crop[1] > 0 else { return nil }
        let (bw, bh) = layer.baseSize(width: width, height: height)
        let (cx, cy) = layer.centre(width: width, height: height)
        let kx = bw / layer.crop[0] * layer.scale, ky = bh / layer.crop[1] * layer.scale
        let sx = layer.crop[2] + layer.crop[0] / 2, sy = layer.crop[3] + layer.crop[1] / 2
        return (cx + (p[0] - sx) * kx, cy + (p[1] - sy) * ky)
    }

    /// One-Euro smoothing of the visible stretches (reset after a gap), then gaps up to `hold` seconds keep the last point.
    public static func smooth(_ samples: [Sample], rate: Double, minCutoff: Double = 1.2, beta: Double = 0.02, hold: Double = 0.25) -> [Sample] {
        var out = samples
        var fx: OneEuroFilter?, fy: OneEuroFilter?
        var last: (x: Double, y: Double)?
        var lastSize: Double?
        var gap = 0.0
        for i in out.indices {
            if let p = out[i].point {
                if fx == nil { fx = OneEuroFilter(rate: rate, minCutoff: minCutoff, beta: beta); fy = OneEuroFilter(rate: rate, minCutoff: minCutoff, beta: beta) }
                let s = (fx!.filter(p.x), fy!.filter(p.y))
                out[i].point = s
                last = s
                lastSize = out[i].size
                gap = 0
            } else {
                gap += 1 / rate
                if gap <= hold, let l = last { out[i].point = l; out[i].size = lastSize } else { fx = nil; fy = nil; last = nil }
            }
        }
        return out
    }
}
