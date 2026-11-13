import Foundation

// Screen + camera recordings (issue #6, P2-T2). A recording session is a folder of separate, synced files
// (screen.mov, camera.mov, mic.wav, optional system.wav) and a `session.json` that says when each file starts
// on one common clock, plus the clicks, keystrokes and cursor positions captured meanwhile (auto-zoom input)
// and the layout chosen at recording time. recording.import turns it into a timeline.

/// `session.json`. Times are seconds of *recorded* time from the moment recording started (pauses removed:
/// every file is continuous, so a file's local time t sits at session time `offset + t`).
public struct RecordingSession: Codable, Hashable, Sendable {
    public static let fileName = "session.json"
    public static let currentVersion = 1

    public struct Source: Codable, Hashable, Sendable {
        /// screen | camera | mic | system.
        public var id: String
        /// File name inside the session folder (or an absolute path).
        public var file: String
        /// Session time of the file's first sample (its first frame for video), seconds. On the same clock for
        /// every source (the host time clock in the app), so a source that started late has a larger offset.
        public var offset: Double
        /// Device or capture target ("MacBook Pro Camera", "Display 1", "Finestra: Safari", "Area").
        public var device: String?
        public var width: Int?
        public var height: Int?
        public var fps: Double?
        public var sampleRate: Int?
        public var channels: Int?
        /// Screen only: captured rectangle in global screen points [x, y, w, h] (top-left origin) and
        /// pixels per point, so event coordinates can be mapped into the file.
        public var region: [Double]?
        public var scale: Double?

        public init(id: String, file: String, offset: Double) {
            self.id = id
            self.file = file
            self.offset = offset
        }
    }

    /// A click, a mouse-up or a keystroke. `x`/`y` are pixels of screen.mov (top-left origin).
    public struct Event: Codable, Hashable, Sendable {
        /// click (left button down) | mouseUp (left button up; sessions before issue #42 have none) | rightClick | key.
        public var kind: String
        public var t: Double
        public var x: Double?
        public var y: Double?
        /// key: the characters typed (empty for function keys), with modifier names ("cmd+s").
        public var key: String?

        public init(kind: String, t: Double, x: Double? = nil, y: Double? = nil, key: String? = nil) {
            self.kind = kind
            self.t = t
            self.x = x
            self.y = y
            self.key = key
        }
    }

    /// Cursor position sample, pixels of screen.mov. `kind` and `down` (issue #42) are absent in older sessions and
    /// written only when they say something: nil kind = arrow, nil down = button up.
    public struct CursorSample: Codable, Hashable, Sendable {
        public var t: Double
        public var x: Double
        public var y: Double
        /// The system cursor's shape (CursorKind raw value: arrow, pointingHand, iBeam…).
        public var kind: String?
        /// The left button is held.
        public var down: Bool?

        public init(t: Double, x: Double, y: Double, kind: String? = nil, down: Bool? = nil) {
            self.t = t
            self.x = x
            self.y = y
            self.kind = kind
            self.down = down
        }
    }

    /// A pause: at recorded time `at`, `duration` wall-clock seconds were not recorded (informative only).
    public struct Pause: Codable, Hashable, Sendable {
        public var at: Double
        public var duration: Double

        public init(at: Double, duration: Double) {
            self.at = at
            self.duration = duration
        }
    }

    /// The layout switched to during recording at time `t`.
    public struct LayoutChange: Codable, Hashable, Sendable {
        public var t: Double
        public var layout: LayoutSpec

        public init(t: Double, layout: LayoutSpec) {
            self.t = t
            self.layout = layout
        }
    }

    public var version = RecordingSession.currentVersion
    /// Who wrote it ("Regista 0.2.0", "regista-engine recording.synthesize").
    public var app: String
    /// ISO 8601 date of the start.
    public var created: String
    /// Written by the synthetic session generator (test pattern, not a real capture).
    public var synthetic: Bool?
    /// Recorded seconds (pauses excluded).
    public var duration: Double
    public var sources: [Source]
    public var pauses: [Pause]?
    public var events: [Event]
    public var cursor: [CursorSample]?
    /// Whether screen.mov has the system cursor drawn in (nil = yes: sessions before issue #42). false: the cursor
    /// was hidden while recording and the compositor draws it from `cursor` (cursor.style).
    public var cursorInVideo: Bool?
    /// Layout chosen when recording started.
    public var layout: LayoutSpec?
    public var layoutChanges: [LayoutChange]?
    /// Sync slates: at each of these session times the screen flashes white, the camera frame flashes and the
    /// mic carries a 1 kHz beep (synthetic sessions; recording.check measures them in the export).
    public var syncMarks: [Double]?

    public init(app: String, created: String, duration: Double, sources: [Source], events: [Event] = []) {
        self.app = app
        self.created = created
        self.duration = duration
        self.sources = sources
        self.events = events
    }

    public func source(_ id: String) -> Source? { sources.first { $0.id == id } }

    public var clicks: [Event] { events.filter { $0.kind == "click" && $0.x != nil && $0.y != nil } }

    /// screen.mov shows the system cursor (old sessions always do).
    public var hasCursorInVideo: Bool { cursorInVideo ?? true }

    public static func load(_ url: URL) throws -> RecordingSession {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw CommandError(.io, "Cannot read \(url.path): \(error.localizedDescription)") }
        do { return try JSONDecoder().decode(RecordingSession.self, from: data) }
        catch { throw CommandError(.io, "\(url.lastPathComponent) is not a Regista recording session: \(error)") }
    }

    public func write(to url: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do { try e.encode(self).write(to: url, options: .atomic) }
        catch { throw CommandError(.io, "Cannot write \(url.path): \(error.localizedDescription)") }
    }

    /// Absolute path of a source file (relative names resolve against the session folder).
    public func path(of source: Source, sessionFolder: URL) -> String {
        source.file.hasPrefix("/") ? source.file : sessionFolder.appendingPathComponent(source.file).standardizedFileURL.path
    }
}

/// How the sources of a session go on the timeline: every file starts at the same timeline time (0) and stops at
/// the same end, and a source that started later on the session clock simply begins later inside the window.
public enum SessionSync {
    public struct Placement: Hashable, Sendable {
        public var sourceIn: MediaTime
        public var sourceOut: MediaTime
        /// Timeline start (0) and duration of the common window.
        public var start: MediaTime
        public var duration: MediaTime
    }

    /// Session time shown at timeline 0: the latest start among the sources (before it, some file has no picture
    /// or sound yet). Not snapped: sub-frame offsets live in each clip's `sourceIn`, which is exact.
    public static func origin(offsets: [Double]) -> Double { offsets.max() ?? 0 }

    /// The common window [origin, end) on the frame grid and where each source's clip reads from.
    /// `durations` are the files' lengths, same order as `offsets`.
    public static func placements(offsets: [Double], durations: [MediaTime], frameRate: Rational) -> [Placement] {
        let origin = origin(offsets: offsets)
        let end = zip(offsets, durations).map { $0 + $1.seconds }.min() ?? origin
        let frame = MediaTime.frameDuration(at: frameRate)
        // Whole frames only: the last partial frame would be a frame some source cannot fill.
        let frames = max(Int64(((end - origin) * frameRate.doubleValue + 1e-6).rounded(.down)), 0)
        let length = MediaTime(ticks: frame.ticks * frames)
        return offsets.map { o in
            let sourceIn = MediaTime(seconds: origin - o)
            return Placement(sourceIn: sourceIn, sourceOut: sourceIn + length, start: .zero, duration: length)
        }
    }

    /// Timeline time of session time `s` for the clips of an asset whose file started at `offset`: the clip
    /// containing source time `s − offset` (edits keep working), nil when that moment was cut out.
    public static func timelineTime(session s: Double, offset: Double, asset: String, in project: Project) -> MediaTime? {
        let u = MediaTime(seconds: s - offset)
        for track in project.tracks where track.kind == .video || track.kind == .audio {
            for c in track.clips where c.assetID == asset && c.sourceIn <= u && u < c.sourceOut {
                return c.start + (u - c.sourceIn)
            }
        }
        return nil
    }

    /// Session time shown by an asset's clip at timeline time `t` (inverse of `timelineTime`).
    public static func sessionTime(timeline t: MediaTime, offset: Double, asset: String, in project: Project) -> Double? {
        for track in project.tracks where track.kind == .video || track.kind == .audio {
            if let c = track.clips.first(where: { $0.assetID == asset && $0.start <= t && t < $0.end }) {
                return (c.sourceIn + (t - c.start)).seconds + offset
            }
        }
        return nil
    }
}

/// A session imported into the project (recording.import): which assets came from it and the layouts applied.
public struct RecordingLink: Codable, Hashable, Sendable {
    public var id: String
    /// Absolute path of session.json (read again by edit.autoZoom for clicks and cursor).
    public var session: String
    public var screen: String?
    public var camera: String?
    public var mic: String?
    public var system: String?
    /// Session offsets of the sources (seconds), copied from session.json.
    public var offsets: [String: Double]
    /// Layouts applied, in timeline time (layout.apply), latest last.
    public var layouts: [AppliedLayout]?
    /// false when screen.mov was recorded without the system cursor (copied from session.json; nil = it has it).
    public var cursorInVideo: Bool?
    /// How the drawn cursor looks (cursor.style; nil = the defaults). Only takes without a cursor in the video draw it.
    public var cursor: CursorStyle?
    /// The options of the last edit.autoZoom over the recording (nil: no automatic zoom, or it was removed). A new
    /// layout or output format re-runs the zoom with them, so it fits the new screen box.
    public var autoZoom: [String: JSONValue]?
    /// The options of the last keys.overlay (nil: no key badges, or the defaults); re-run on a new layout or format.
    public var keys: [String: JSONValue]?

    public init(id: String, session: String, offsets: [String: Double]) {
        self.id = id
        self.session = session
        self.offsets = offsets
    }
}

public struct AppliedLayout: Codable, Hashable, Sendable {
    public var from: MediaTime
    public var to: MediaTime
    public var layout: LayoutSpec

    public init(from: MediaTime, to: MediaTime, layout: LayoutSpec) {
        self.from = from
        self.to = to
        self.layout = layout
    }
}
