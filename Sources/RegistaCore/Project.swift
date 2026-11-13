import Foundation

// Project model, loosely after OpenTimelineIO (assets ≈ media references, tracks in a stack,
// clips with a source range placed at a timeline time) without depending on it.
// Value types only: an undo snapshot is just a copy.

public struct Project: Codable, Hashable, Sendable {
    public static let currentSchema = 1

    public var schema = Project.currentSchema
    public var name: String
    public var settings: ProjectSettings
    public var assets: [MediaAsset] = []
    /// Bottom to top: the last video track is composited on top.
    public var tracks: [Track] = []
    public var markers: [Marker] = []
    /// The text the speaker read (script.set).
    public var script: Script?
    /// Takes found by aligning a transcript to the script (takes.list), with the chosen one per line.
    public var takes: TakeSet?
    /// Frame-wide transitions at cut points (transition.add).
    public var transitions: [Transition]?
    /// generate.run jobs (generated assets carry their own metadata in `MediaAsset.generated`).
    public var generations: [GenerationJob]?
    /// The brand kit applied with brandkit.apply (title presets, colours, fonts), copied in so the project is self-contained.
    public var brand: BrandKit?
    /// Screen recordings imported with recording.import (session file, assets, layouts applied).
    public var recordings: [RecordingLink]?
    /// Look and adjustments for the whole picture (look.apply / adjust.set without a clip): applied to every video and
    /// image layer that has no grade of its own; titles, stickers and callouts keep their colours. Keys: timeline time.
    public var grade: Grade?
    /// Next serial per id prefix: ids stay short, stable and predictable ("c3").
    var idCounters: [String: Int] = [:]

    public init(name: String, settings: ProjectSettings = ProjectSettings()) {
        self.name = name
        self.settings = settings
    }

    /// End of the last clip on any track.
    public var duration: MediaTime {
        tracks.flatMap(\.clips).map(\.end).max() ?? .zero
    }

    /// End of the picture (video and overlay tracks): sound effects and music are cut there.
    public var pictureEnd: MediaTime {
        tracks.filter { $0.kind == .video || $0.kind == .overlay }.flatMap(\.clips).map(\.end).max() ?? .zero
    }

    mutating func makeID(_ prefix: String) -> String {
        let n = (idCounters[prefix] ?? 0) + 1
        idCounters[prefix] = n
        return "\(prefix)\(n)"
    }

    // MARK: Lookup

    public func asset(_ id: String) -> MediaAsset? { assets.first { $0.id == id } }
    public func trackIndex(_ id: String) -> Int? { tracks.firstIndex { $0.id == id } }

    /// (track index, clip index) of a clip.
    public func locate(clip id: String) -> (track: Int, clip: Int)? {
        for (t, track) in tracks.enumerated() {
            if let c = track.clips.firstIndex(where: { $0.id == id }) { return (t, c) }
        }
        return nil
    }
}

public struct ProjectSettings: Codable, Hashable, Sendable {
    /// Output frame size; defaults to a vertical 9:16 reel.
    public var width = 1080
    public var height = 1920
    /// Timeline edits snap to this frame grid.
    public var frameRate = Rational(30)
    public var sampleRate = 48_000
    /// Frame background under the layers (#RRGGBB; nil = black): the backdrop of boxed layouts (split).
    public var background: String?
    /// Drawn instead of `background` when set: the colour, gradient or image behind a styled screen frame (issue #44).
    public var backdrop: Backdrop?

    public init(width: Int = 1080, height: Int = 1920, frameRate: Rational = Rational(30), sampleRate: Int = 48_000) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.sampleRate = sampleRate
    }
}

public struct MediaAsset: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Absolute path of the source file (never modified by Regista).
    public var path: String
    public var duration: MediaTime
    public var video: VideoInfo?
    public var audio: AudioInfo?
    /// Engine results for this asset (extracted audio, transcript, face track).
    public var analysis: AssetAnalysis?
    /// Set when Regista produced this file from another asset (audio.clean).
    public var origin: AssetOrigin?
    /// A still image or an RGBA frame sequence, drawn from files by the compositor (not through AVFoundation).
    public var image: ImageSource?
    /// Set when a generation provider made this file (generate.run / generate.upscale).
    public var generated: GenerationInfo?
}

/// Pictures that are files rather than a video stream: a still (PNG/JPEG, or an SVG rasterized at import) or a
/// numbered RGBA PNG sequence (alpha overlays: Blender, HyperFrames, converted ProRes 4444 / HEVC-alpha).
public struct ImageSource: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case still, sequence }
    public var kind: Kind
    /// The still's file, or a printf pattern of the frames ("/dir/%04d.png").
    public var path: String
    /// Number of the first frame.
    public var first: Int
    /// Frames in the sequence (1 for a still).
    public var count: Int
    public var frameRate: Rational
    /// Union of the visible (non-transparent) pixels over the frames, source pixels [x, y, w, h], top-left origin:
    /// layout checks use it instead of the transparent margins of the canvas.
    public var ink: [Double]?

    public init(kind: Kind, path: String, first: Int = 1, count: Int = 1, frameRate: Rational = Rational(30)) {
        self.kind = kind
        self.path = path
        self.first = first
        self.count = count
        self.frameRate = frameRate
    }

    /// The file shown at a source time.
    public func file(at t: MediaTime) -> String {
        guard kind == .sequence else { return path }
        let k = min(max(Int((t.seconds * frameRate.doubleValue + 1e-6).rounded(.down)), 0), max(count - 1, 0))
        return String(format: path, first + k)
    }

    /// A still lasts as long as it is placed for: this is its nominal duration.
    public static let stillDuration = MediaTime(seconds: 3600)
}

public struct VideoInfo: Codable, Hashable, Sendable {
    /// Display size, rotation already applied (an iPhone portrait clip is 1080×1920).
    public var width: Int
    public var height: Int
    public var frameRate: Rational
    public var codec: String
    /// Rotation from the container's display matrix, degrees.
    public var rotation: Int = 0
    /// The stream carries transparency (ProRes 4444, HEVC with alpha, VP9 alpha, RGBA PNG).
    public var alpha: Bool?
}

public struct AudioInfo: Codable, Hashable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var codec: String
}

public enum TrackKind: String, Codable, CaseIterable, Sendable {
    case video, audio, caption, overlay

    /// Prefix of the default track name: V1, A1, C1, O1.
    var namePrefix: String {
        switch self {
        case .video: "V"
        case .audio: "A"
        case .caption: "C"
        case .overlay: "O"
        }
    }
}

public struct Track: Codable, Hashable, Sendable {
    public var id: String
    public var kind: TrackKind
    public var name: String
    public var locked = false
    public var muted = false
    public var hidden = false
    /// Sorted by start, never overlapping.
    public var clips: [Clip] = []
    /// Content of a caption track (captions.generate).
    public var captions: Captions?
    /// What the track is for ("music", "sfx", "titles", "overlays"): the graphics and audio commands find their tracks by it.
    public var role: String?
    /// Audio track only: lower it while another track speaks (audio.addMusic).
    public var ducking: Ducking?

    public var end: MediaTime { clips.last?.end ?? .zero }

    mutating func sortClips() { clips.sort { $0.start < $1.start } }

    /// First clip overlapping [start, end), ignoring `except`.
    func overlap(start: MediaTime, end: MediaTime, except: String? = nil) -> Clip? {
        clips.first { $0.id != except && $0.start < end && start < $0.end }
    }
}

public struct Clip: Codable, Hashable, Sendable {
    public var id: String
    public var assetID: String
    /// Range used from the source media.
    public var sourceIn: MediaTime
    public var sourceOut: MediaTime
    /// Where the clip starts on the timeline.
    public var start: MediaTime
    public var transform: Transform?
    /// Clips sharing a link id (picture and sound of one take) are placed, moved, trimmed, cut and
    /// deleted together unless a command is told otherwise (`linked: false`).
    public var link: String?
    /// Audio micro-fades at the clip edges (the renderer applies them to audio clips).
    public var fadeIn: MediaTime?
    public var fadeOut: MediaTime?
    /// Animated transform: clip-relative times, linear in between, held outside. Overrides `transform`.
    public var keyframes: [Keyframe]?
    /// Grade with ffmpeg `eq` semantics.
    public var color: ColorAdjust?
    /// Where a picture that does not fill the frame sits (stills, titles, alpha overlays); nil = fill the frame.
    public var placement: Placement?
    /// How the layer combines with what is under it (nil = normal).
    public var blend: BlendMode?
    /// A text layer drawn by the compositor (title.add); such a clip has no asset (`assetID` is empty).
    public var title: Title?
    /// Keyframable Core Image effects (effect.add), clip-relative.
    public var effects: [Effect]?
    /// Audio gain in dB (music bed, sound effects).
    public var gain: Double?
    /// Drawn between the background and the person (title or overlay over a talking head with a person matte,
    /// matte.track): where the person is, the frame shows what was under this layer.
    public var behindSubject: Bool?
    /// Behind / in front of the person over time (clip-relative, each holding until the next); overrides behindSubject
    /// from the first switch on.
    public var behindSwitches: [BehindSwitch]?
    /// A motion template drawn by the compositor (motion.add); such a clip has no asset.
    public var motion: MotionLayer?
    /// Shape of a boxed layer: rounded corners, circle, person cut-out, border, shadow (layout.apply).
    public var mask: LayerMask?
    /// Brand-kit title preset the title was made from (brandkit.apply restyles it with the new kit's preset).
    public var titlePreset: String?
    /// Retiming: slow motion, fast, ramp, reverse, freeze (clip.speed). The source range stays; `duration` follows it.
    public var speed: Speed?
    /// Look and adjustments of this clip (look.apply / adjust.set); keys are clip-relative.
    public var grade: Grade?
    /// An emoji or SF Symbol drawn by the compositor (sticker.add); such a clip has no asset.
    public var sticker: Sticker?
    /// A vector callout or progress bar drawn by the compositor (callout.add, progress.add); no asset.
    public var shape: ShapeLayer?
    /// Where the clip was before it was first moved by hand (clip.place, a drag on the preview): `reset` goes back to it.
    public var placeOrigin: PlaceOrigin?
    /// Motion blur while the crop keyframes move the camera (edit.autoZoom): shutter as a fraction of a frame, 0…1.
    public var motionBlur: Double?
    /// Picture fades at the clip edges (#79): from / to black on a full-frame clip of a video track, from / to
    /// transparent otherwise (overlay tracks, boxed pictures). The sound has its own `fadeIn` / `fadeOut`.
    public var pictureFadeIn: MediaTime?
    public var pictureFadeOut: MediaTime?

    /// How much of the picture shows at `t` from the clip start under its picture fades: 0 (black or transparent) … 1.
    public func pictureVisibility(at t: MediaTime) -> Double {
        var v = 1.0
        if let f = pictureFadeIn, f > .zero { v = min(v, max(t.seconds, 0) / f.seconds) }
        if let f = pictureFadeOut, f > .zero { v = min(v, max((duration - t).seconds, 0) / f.seconds) }
        return min(max(v, 0), 1)
    }

    /// Timeline length: the source range, retimed by `speed`.
    public var duration: MediaTime { speed?.duration ?? (sourceOut - sourceIn) }
    public var end: MediaTime { start + duration }

    /// Transform at `t` from the clip start (keyframes interpolated with the easing of the keyframe
    /// each move leaves), the static transform (or identity) when there are no keyframes.
    public func transform(at t: MediaTime) -> Transform {
        guard let k = keyframes, let first = k.first else { return transform ?? Transform() }
        if t <= first.time { return first.transform }
        guard let next = k.firstIndex(where: { $0.time > t }) else { return k.last!.transform }
        let a = k[next - 1], b = k[next]
        let f = Double((t - a.time).ticks) / Double((b.time - a.time).ticks)
        return a.transform.interpolated(to: b.transform, (a.easing ?? .linear).apply(f))
    }

    /// A generated layer (title, sticker, callout) rather than media.
    public var isGenerated: Bool { title != nil || sticker != nil || shape != nil || motion != nil }

    /// Whether the layer is drawn behind the person at `t` from the clip start.
    public func isBehindSubject(at t: MediaTime) -> Bool {
        if let s = behindSwitches, let last = s.last(where: { $0.time <= t }) { return last.behind }
        return behindSubject == true
    }
}

/// From `time` (clip-relative) the layer is drawn behind the person (true) or in front of it.
public struct BehindSwitch: Codable, Hashable, Sendable {
    public var time: MediaTime
    public var behind: Bool
    public init(time: MediaTime, behind: Bool) { self.time = time; self.behind = behind }
}

/// A clip's placement, rest transform and keyframes as they were before clip.place first moved it.
public struct PlaceOrigin: Codable, Hashable, Sendable {
    public var placement: Placement?
    public var transform: Transform?
    public var keyframes: [Keyframe]?

    public init(placement: Placement?, transform: Transform?, keyframes: [Keyframe]?) {
        self.placement = placement
        self.transform = transform
        self.keyframes = keyframes
    }
}

public struct Keyframe: Codable, Hashable, Sendable {
    /// From the clip start.
    public var time: MediaTime
    public var transform: Transform
    /// Curve towards the next keyframe (nil = linear).
    public var easing: Easing?

    public init(time: MediaTime, transform: Transform, easing: Easing? = nil) {
        self.time = time
        self.transform = transform
        self.easing = easing
    }
}

/// ffmpeg `eq` parameters: brightness −1…1 (0 = none), contrast and saturation factors (1 = none).
public struct ColorAdjust: Codable, Hashable, Sendable {
    public var brightness = 0.0
    public var contrast = 1.0
    public var saturation = 1.0

    public init(brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) {
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
    }

    public var isIdentity: Bool { brightness == 0 && contrast == 1 && saturation == 1 }
}

/// Spatial placement of a visual clip. Fractions of the frame, so independent of resolution.
/// The crop (fractions of the source's display frame, rotation applied) is scaled to fill the
/// output frame (aspect fill, centred), then `scale`, `x`/`y`, `rotation` and `opacity` apply.
/// 2.5D (issue #22): `rotationX`/`rotationY` tilt the picture in depth around the pivot `anchorX`/`anchorY`
/// (fractions of the picture, 0.5/0.5 = centre: the picture does not move at rest, scale and rotations turn around
/// it), seen from `perspective` px (at 1080 wide) in front of the frame. Old projects decode with the defaults, and
/// default values are not written, so a project without 2.5D saves exactly as before.
public struct Transform: Codable, Hashable, Sendable {
    public var cropLeft = 0.0, cropTop = 0.0, cropRight = 0.0, cropBottom = 0.0
    public var scale = 1.0
    /// Offset of the center, fraction of the output frame.
    public var x = 0.0, y = 0.0
    /// Degrees, clockwise.
    public var rotation = 0.0
    public var opacity = 1.0
    /// Pivot of scale and rotations, fractions of the picture (0 = left/top edge, 1 = right/bottom).
    public var anchorX = 0.5, anchorY = 0.5
    /// Degrees of tilt: around the horizontal axis (positive = the top goes away) and the vertical axis (positive =
    /// the right side goes away).
    public var rotationX = 0.0, rotationY = 0.0
    /// Camera distance, px at 1080 wide (smaller = stronger perspective).
    public var perspective = Transform.defaultPerspective

    public static let defaultPerspective = 2000.0

    public init() {}

    /// Anything beyond the flat transform (tilt or an off-centre pivot): drawn through the perspective path.
    public var isSpatial: Bool { rotationX != 0 || rotationY != 0 || anchorX != 0.5 || anchorY != 0.5 }

    enum CodingKeys: String, CodingKey {
        case cropLeft, cropTop, cropRight, cropBottom, scale, x, y, rotation, opacity, anchorX, anchorY, rotationX, rotationY, perspective
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func v(_ k: CodingKeys, _ d: Double) throws -> Double { try c.decodeIfPresent(Double.self, forKey: k) ?? d }
        cropLeft = try v(.cropLeft, 0); cropTop = try v(.cropTop, 0); cropRight = try v(.cropRight, 0); cropBottom = try v(.cropBottom, 0)
        scale = try v(.scale, 1); x = try v(.x, 0); y = try v(.y, 0); rotation = try v(.rotation, 0); opacity = try v(.opacity, 1)
        anchorX = try v(.anchorX, 0.5); anchorY = try v(.anchorY, 0.5); rotationX = try v(.rotationX, 0); rotationY = try v(.rotationY, 0)
        perspective = try v(.perspective, Transform.defaultPerspective)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cropLeft, forKey: .cropLeft); try c.encode(cropTop, forKey: .cropTop)
        try c.encode(cropRight, forKey: .cropRight); try c.encode(cropBottom, forKey: .cropBottom)
        try c.encode(scale, forKey: .scale); try c.encode(x, forKey: .x); try c.encode(y, forKey: .y)
        try c.encode(rotation, forKey: .rotation); try c.encode(opacity, forKey: .opacity)
        if anchorX != 0.5 { try c.encode(anchorX, forKey: .anchorX) }
        if anchorY != 0.5 { try c.encode(anchorY, forKey: .anchorY) }
        if rotationX != 0 { try c.encode(rotationX, forKey: .rotationX) }
        if rotationY != 0 { try c.encode(rotationY, forKey: .rotationY) }
        if perspective != Transform.defaultPerspective { try c.encode(perspective, forKey: .perspective) }
    }

    /// Crop from a source pixel rectangle [w, h, x, y] (top-left origin) of a `width`×`height` frame.
    public init(crop: [Double], sourceWidth width: Int, sourceHeight height: Int) {
        let (w, h, x, y) = (crop[0], crop[1], crop[2], crop[3])
        cropLeft = x / Double(width)
        cropTop = y / Double(height)
        cropRight = 1 - (x + w) / Double(width)
        cropBottom = 1 - (y + h) / Double(height)
    }

    /// The crop as a source pixel rectangle [w, h, x, y].
    public func cropRect(sourceWidth width: Int, sourceHeight height: Int) -> [Double] {
        let W = Double(width), H = Double(height)
        return [(1 - cropLeft - cropRight) * W, (1 - cropTop - cropBottom) * H, cropLeft * W, cropTop * H]
    }

    func interpolated(to b: Transform, _ f: Double) -> Transform {
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        var r = Transform()
        r.cropLeft = mix(cropLeft, b.cropLeft); r.cropTop = mix(cropTop, b.cropTop)
        r.cropRight = mix(cropRight, b.cropRight); r.cropBottom = mix(cropBottom, b.cropBottom)
        r.scale = mix(scale, b.scale); r.x = mix(x, b.x); r.y = mix(y, b.y)
        r.rotation = mix(rotation, b.rotation); r.opacity = mix(opacity, b.opacity)
        r.anchorX = mix(anchorX, b.anchorX); r.anchorY = mix(anchorY, b.anchorY)
        r.rotationX = mix(rotationX, b.rotationX); r.rotationY = mix(rotationY, b.rotationY)
        r.perspective = mix(perspective, b.perspective)
        return r
    }
}

/// The 2.5D projection shared by the compositor, the layout boxes and the motion templates: where the four corners
/// of a w×h picture land on the frame.
public enum Projection {
    /// Corners top-left, top-right, bottom-right, bottom-left, in output pixels (top-left origin), of a `w`×`h` picture
    /// whose rest centre is `centre`, pivoting around (`anchorX`, `anchorY`) of itself: scale, then rotation (clockwise,
    /// degrees), then tilts `rotationX` (top away) and `rotationY` (right away), projected from `distance` px.
    public static func corners(w: Double, h: Double, centre: (Double, Double), scale: Double, rotation: Double, anchorX: Double = 0.5,
                               anchorY: Double = 0.5, rotationX: Double = 0, rotationY: Double = 0, distance: Double = Transform.defaultPerspective)
        -> [(Double, Double)] {
        let px = centre.0 + (anchorX - 0.5) * w, py = centre.1 + (anchorY - 0.5) * h
        let rz = rotation * .pi / 180, rx = rotationX * .pi / 180, ry = rotationY * .pi / 180
        let d = max(distance, 1)
        return [(0.0, 0.0), (w, 0), (w, h), (0, h)].map { (u, v) in
            var x = (u - anchorX * w) * scale, y = (v - anchorY * h) * scale, z = 0.0
            (x, y) = (x * cos(rz) - y * sin(rz), x * sin(rz) + y * cos(rz))
            // Top away (y < 0 goes to +z) for positive rotationX; right away (x > 0 to +z) for positive rotationY.
            (y, z) = (y * cos(rx), -y * sin(rx))
            (x, z) = (x * cos(ry), z + x * sin(ry))
            let k = d / max(d + z, 1)
            return (px + x * k, py + y * k)
        }
    }

    /// Axis-aligned bounds [x, y, w, h] of corners.
    public static func bounds(_ c: [(Double, Double)]) -> [Double] {
        let xs = c.map(\.0), ys = c.map(\.1)
        return [xs.min()!, ys.min()!, xs.max()! - xs.min()!, ys.max()! - ys.min()!]
    }
}

public struct Marker: Codable, Hashable, Sendable {
    public var id: String
    public var time: MediaTime
    public var duration: MediaTime = .zero
    public var name: String
    public var color: String?
}
