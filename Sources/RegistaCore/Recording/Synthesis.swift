import Foundation

// Synthetic sessions (issue #6): screen and camera capture need permissions an unattended session cannot grant,
// so recording.synthesize writes a session in exactly the format of a real recording — an animated desktop with
// a moving cursor and clicks (screen.mov), a real camera take (camera.mov) and its sound (mic.wav), sync slates —
// and the whole import → layout → auto-zoom → export path is tested on it.

/// What the screen synthesizer draws: an animated desktop (two windows), the cursor on `cursor`, a ripple at each
/// click, the session clock, and white frames at `flashes`.
public struct SyntheticScreen: Sendable {
    public struct Button: Sendable {
        public var x: Double
        public var y: Double
        public var label: String

        public init(x: Double, y: Double, label: String) {
            self.x = x
            self.y = y
            self.label = label
        }
    }

    public var width: Int
    public var height: Int
    public var fps: Int
    public var frames: Int
    /// Cursor position per frame, pixels (top-left origin).
    public var cursor: [[Double]]
    /// Clicks in seconds of the file.
    public var clicks: [ZoomClick]
    /// Buttons drawn under the click targets.
    public var buttons: [Button]
    /// Frames drawn white (sync slates).
    public var flashes: Set<Int>
    /// Session time of frame 0 (the on-screen clock shows session time).
    public var clockOffset: Double
    public var output: URL
    /// Draw the cursor and the click ripples into the video (false: a take recorded without the system cursor).
    public var drawsCursor = true

    public init(width: Int, height: Int, fps: Int, frames: Int, cursor: [[Double]], clicks: [ZoomClick], buttons: [Button],
                flashes: Set<Int>, clockOffset: Double, output: URL) {
        self.width = width
        self.height = height
        self.fps = fps
        self.frames = frames
        self.cursor = cursor
        self.clicks = clicks
        self.buttons = buttons
        self.flashes = flashes
        self.clockOffset = clockOffset
        self.output = output
    }
}

/// A synthetic talking head (issue #22): a wall, a speaker silhouette (head and shoulders) that sways and nods, and
/// its exact person matte as `%06d.png` frames — scenarios test "behind the person" without Vision or footage.
public struct SyntheticTalkingHead: Sendable {
    public var width = 1080
    public var height = 1920
    public var fps = 30
    public var frames: Int
    public var output: URL
    public var matteDirectory: URL
    /// Matte frames are written at width / 4 × height / 4.
    public var matteScale = 4

    public init(frames: Int, output: URL, matteDirectory: URL) {
        self.frames = frames
        self.output = output
        self.matteDirectory = matteDirectory
    }

    /// The head at time t (top-left origin pixels of a W×H frame): centre and size of its ellipse, with a slow sway
    /// and a small nod. The synthesizer draws it there; media.synthesize writes the face track from it.
    public static func head(t: Double, W: Double, H: Double) -> (cx: Double, cy: Double, w: Double, h: Double) {
        let sway = 0.025 * W * sin(t * 1.3), nod = 0.006 * H * sin(t * 2.7 + 0.4)
        return (W / 2 + sway, 0.43 * H + nod, 0.27 * W, 0.36 * W)
    }

    /// The face box at time t as a face tracker reports it (eyes to chin, inside the head ellipse), [x, y, w, h].
    public static func face(t: Double, W: Double, H: Double) -> [Double] {
        let h = head(t: t, W: W, H: H)
        return [h.cx - 0.38 * h.w, h.cy - 0.12 * h.h, 0.76 * h.w, 0.55 * h.h]
    }
}

/// Encodes a synthetic screen recording (H.264 .mov). Lives in RegistaEngines (Core Graphics + AVFoundation).
public protocol ScreenSynthesizer {
    func write(_ screen: SyntheticScreen) throws
    /// A synthetic talking head and its matte.
    func writeTalkingHead(_ head: SyntheticTalkingHead) throws
}

extension ScreenSynthesizer {
    public func writeTalkingHead(_ head: SyntheticTalkingHead) throws { throw CommandError(.io, "this host cannot draw a synthetic talking head") }
}

public enum SyntheticSession {
    /// Default clicks: session time, position (fractions of the screen), label of the button under it.
    public static let defaultClicks: [(t: Double, x: Double, y: Double, label: String?)] = [
        (2.6, 0.205, 0.255, "Esegui"),
        (4.0, 0.36, 0.52, nil),
        (9.2, 0.74, 0.735, "Pubblica"),
        (11.6, 0.70, 0.37, nil),
    ]

    /// The drag of a session recorded without the cursor (issue #42): press at `t0` on (x0, y0), release at `t1` on
    /// (x1, y1); session time, fractions of the screen.
    public static let defaultDrag = (t0: 6.2, t1: 7.0, x0: 0.40, y0: 0.62, x1: 0.56, y1: 0.66)

    /// Cursor position at session time `t`: it rests at the screen's lower middle, travels to each click target
    /// (arriving 0.3 s early, ease in-out) and lingers after the click, with a small idle drift. A drag (pixels)
    /// travels to its press point, then moves to the release point while the button is held.
    public static func cursor(at t: Double, clicks: [(t: Double, x: Double, y: Double)], width: Double, height: Double,
                              drags: [(t0: Double, t1: Double, x0: Double, y0: Double, x1: Double, y1: Double)] = []) -> [Double] {
        var waypoints: [(t: Double, x: Double, y: Double)] = [(0, 0.5 * width, 0.62 * height)]
        let moves = clicks.map { (t: $0.t, end: $0.t, x: $0.x, y: $0.y, x1: $0.x, y1: $0.y) }
            + drags.map { (t: $0.t0, end: $0.t1, x: $0.x0, y: $0.y0, x1: $0.x1, y1: $0.y1) }
        for c in moves.sorted(by: { $0.t < $1.t }) {
            let leave = max(waypoints.last!.t + 0.2, c.t - 1.1)
            waypoints.append((leave, waypoints.last!.x, waypoints.last!.y))
            waypoints.append((c.t - 0.3, c.x, c.y))
            if c.end > c.t {
                waypoints.append((c.t, c.x, c.y))
                waypoints.append((c.end, c.x1, c.y1))
            }
            waypoints.append((c.end + 0.35, c.x1, c.y1))
        }
        var x = waypoints.last!.x, y = waypoints.last!.y
        if let n = waypoints.firstIndex(where: { $0.t > t }), n > 0 {
            let a = waypoints[n - 1], b = waypoints[n]
            let f = Easing.easeInOut.apply((t - a.t) / max(b.t - a.t, 1e-9))
            x = a.x + (b.x - a.x) * f
            y = a.y + (b.y - a.y) * f
        }
        // Idle drift so the cursor is never perfectly still (like a hand on a trackpad).
        return [x + 3 * sin(t * 1.7), y + 2 * sin(t * 2.3 + 1)]
    }
}
