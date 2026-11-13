import Foundation

/// Output formats of export.render / frame.render. A preset whose aspect differs from the project's
/// reframes by crop: every clip's crop is narrowed (or shortened) to the output aspect around its centre.
public struct ExportPreset: Hashable, Sendable {
    public var id: String
    public var width: Int
    public var height: Int

    public init(id: String, width: Int, height: Int) {
        self.id = id
        self.width = width
        self.height = height
    }

    public static let vertical = ExportPreset(id: "9:16", width: 1080, height: 1920)
    /// Instagram / LinkedIn feed portrait.
    public static let portrait = ExportPreset(id: "4:5", width: 1080, height: 1350)
    public static let square = ExportPreset(id: "1:1", width: 1080, height: 1080)
    public static let landscape = ExportPreset(id: "16:9", width: 1920, height: 1080)
    public static let all = [vertical, portrait, square, landscape]

    public static func named(_ id: String?, project: Project) -> ExportPreset {
        if let id, let p = all.first(where: { $0.id == id }) { return p }
        return ExportPreset(id: "project", width: project.settings.width, height: project.settings.height)
    }
}

/// Where a layer's picture comes from.
public enum LayerSource: Hashable, Sendable {
    /// The frame of the clip's composition track (AVFoundation).
    case video
    /// An image file: a still, or the frame of a PNG sequence at the source time.
    case image(String)
    /// Text drawn with Core Text.
    case title(Title)
    /// An emoji or SF Symbol.
    case sticker(Sticker)
    /// A vector callout / progress bar, drawn up to `progress` (0…1).
    case shape(ShapeLayer, Double)
    /// A motion template at `time` seconds into a clip of `duration` seconds; `part` of a split layer.
    case motion(MotionLayer, time: Double, duration: Double, part: MotionPart)
}

/// What the compositor draws on one output frame, bottom to top. Pure data from the project, so
/// preview, export and frame.render all draw the same thing.
public struct VideoLayer: Hashable, Sendable {
    public var trackID: String
    public var clipID: String
    public var assetID: String
    /// Time in the source media.
    public var sourceTime: MediaTime
    /// Source display size (rotation applied); 0 for titles.
    public var sourceWidth: Int
    public var sourceHeight: Int
    /// Region of the source drawn, display pixels, top-left origin: [w, h, x, y]; for fill layers already at the output aspect.
    public var crop: [Double]
    public var scale: Double
    /// Centre offset, fractions of the output frame (y down).
    public var x: Double
    public var y: Double
    public var rotation: Double
    public var opacity: Double
    /// 2.5D (Transform): pivot, tilts and camera distance.
    public var anchorX = 0.5, anchorY = 0.5
    public var rotationX = 0.0, rotationY = 0.0
    public var perspective = Transform.defaultPerspective
    public var color: ColorAdjust?
    public var source: LayerSource = .video
    /// nil: fill the frame.
    public var placement: Placement?
    public var blend: BlendMode = .normal
    public var effects: [LayerEffect] = []
    /// Visible part of the picture, fractions of the drawn crop [x0, y0, x1, y1] (image assets with transparent margins).
    public var ink: [Double]?
    /// Drawn under the person of the full-frame layer below it (that layer's `matte`).
    public var behindSubject = false
    /// Person matte of this source frame (video layers of an asset tracked with matte.track): 8-bit grey PNG,
    /// display orientation, at its own size (scaled to the source frame when drawn).
    public var matte: String?
    /// Shape of a boxed layer (circle, rounded, cut-out with the matte above, border, shadow).
    public var mask: LayerMask?
    /// Look and adjustments at this frame (the clip's, else the project's for video and image layers).
    public var grade: ResolvedGrade?
    /// The drawn cursor over this screen frame (takes recorded without the system cursor, issue #42).
    public var cursor: CursorOverlay?
    /// Smear of a camera move (the clip's crop keyframes moving, `Clip.motionBlur`), maps in fractions of the crop.
    public var cameraBlur: CameraBlur?
    /// How far the picture is darkened towards black (a full-frame clip's picture fade, #79): 0 = none, 1 = black.
    public var dim = 0.0

    /// Size of the drawn picture before the transform, output pixels, for a `width`×`height` output
    /// (`content`: the title's box size at that output, for titles).
    public func baseSize(width: Int, height: Int, content: (Double, Double)? = nil) -> (Double, Double) {
        let W = Double(width), H = Double(height)
        guard let p = placement, p.fit != .fill else { return (W, H) }
        if p.fit == .box { return ((p.width ?? 1) * W, (p.height ?? 1) * H) }
        let k = W / SafeZones.referenceWidth
        let (cw, ch) = content ?? (crop[0] * k, crop[1] * k)
        if p.fit == .contain {
            let f = min(W / max(cw, 1), H / max(ch, 1))
            return (cw * f, ch * f)
        }
        return (cw, ch)
    }

    /// Centre of the drawn picture after the transform, output pixels (top-left origin).
    public func centre(width: Int, height: Int) -> (Double, Double) {
        let W = Double(width), H = Double(height)
        let home = placement.map { $0.fit == .fill ? (0.5, 0.5) : ($0.x, $0.y) } ?? (0.5, 0.5)
        return ((home.0 + x) * W, (home.1 + y) * H)
    }

    /// Drawn through the perspective path (tilt or off-centre pivot).
    public var isSpatial: Bool { rotationX != 0 || rotationY != 0 || anchorX != 0.5 || anchorY != 0.5 }

    /// Where the corners of the drawn picture land (TL, TR, BR, BL), output pixels, top-left origin.
    public func corners(width: Int, height: Int, content: (Double, Double)? = nil) -> [(Double, Double)] {
        let (w, h) = baseSize(width: width, height: height, content: content)
        return Projection.corners(w: w, h: h, centre: centre(width: width, height: height), scale: scale, rotation: rotation, anchorX: anchorX,
                                  anchorY: anchorY, rotationX: rotationX, rotationY: rotationY, distance: perspective * Double(width) / SafeZones.referenceWidth)
    }

    /// Axis-aligned bounding box after scale and rotation, output pixels [x, y, w, h], top-left origin
    /// (only the visible pixels when `ink` is known and the layer is not rotated).
    public func box(width: Int, height: Int, content: (Double, Double)? = nil) -> [Double] {
        if isSpatial { return Projection.bounds(corners(width: width, height: height, content: content)) }
        let (w, h) = baseSize(width: width, height: height, content: content)
        let (cx, cy) = centre(width: width, height: height)
        if let f = ink, rotation == 0 {
            let x0 = cx + (f[0] - 0.5) * w * scale, y0 = cy + (f[1] - 0.5) * h * scale
            return [x0, y0, (f[2] - f[0]) * w * scale, (f[3] - f[1]) * h * scale]
        }
        let r = rotation * .pi / 180
        let bw = (abs(cos(r)) * w + abs(sin(r)) * h) * scale, bh = (abs(sin(r)) * w + abs(cos(r)) * h) * scale
        return [cx - bw / 2, cy - bh / 2, bw, bh]
    }
}

public struct RenderJob: Sendable {
    public var project: Project
    public var width: Int
    public var height: Int
    public var frameRate: Rational
    /// Caption track drawn on top (nil: no captions).
    public var captions: Captions?
    /// Screen asset id → its drawn cursor (recordings without the system cursor in the video).
    public var cursors: [String: CursorPath]

    public init(project: Project, preset: ExportPreset, captions: Bool = true) {
        self.project = project
        width = preset.width
        height = preset.height
        frameRate = project.settings.frameRate
        self.captions = captions ? project.tracks.last { $0.kind == .caption && !$0.hidden && $0.captions != nil }?.captions : nil
        cursors = CursorPaths.paths(for: project)
    }

    public var duration: MediaTime { project.duration }
    public var frameCount: Int {
        let f = MediaTime.frameDuration(at: frameRate).ticks
        return Int((duration.ticks + f - 1) / f)
    }

    /// Start of the last frame that has a picture: where a player parks at the end (the end time itself has no frame, #32).
    public var lastFrame: MediaTime { Self.lastFrame(duration: duration, rate: frameRate) }

    public static func lastFrame(duration: MediaTime, rate: Rational) -> MediaTime {
        let f = MediaTime.frameDuration(at: rate).ticks
        return MediaTime(ticks: max((duration.ticks + f - 1) / f - 1, 0) * f)
    }

    /// Visual tracks drawn, bottom to top.
    public var visualTracks: [Track] { project.tracks.filter { ($0.kind == .video || $0.kind == .overlay) && !$0.hidden } }

    /// The colour under every layer (#RRGGBB, nil = black): the project's background; a project with no video picture
    /// (a voice-only reel, or only titles and stills) takes its brand kit's surface colour (#72).
    public var background: String? {
        if let b = project.settings.background { return b }
        let picture = visualTracks.contains { track in
            track.clips.contains { c in !c.isGenerated && project.asset(c.assetID).map { $0.video != nil && $0.image == nil } == true }
        }
        return picture ? nil : project.brand?.colors["surface"]
    }

    /// For each layer drawn behind the subject (index into `layers`), the full-frame layer below it whose person
    /// covers it — nil when the picture under it has no matte at this frame (e.g. an insert covers the speaker).
    public static func subjects(_ layers: [VideoLayer]) -> [Int: Int?] {
        var out: [Int: Int?] = [:]
        var subject: Int?
        for (i, l) in layers.enumerated() {
            if l.behindSubject { out[i] = subject }
            if l.placement == nil || l.placement?.fit == .fill { subject = l.matte != nil ? i : nil }
        }
        return out
    }

    public func layers(at t: MediaTime) -> [VideoLayer] {
        visualTracks.flatMap { track -> [VideoLayer] in
            guard let layer = layer(of: track, at: t) else { return [] }
            // A split motion template: its back part under the person, its front part over it.
            if case .motion(let m, let time, let duration, _) = layer.source, m.layering == .split {
                var back = layer, front = layer
                back.source = .motion(m, time: time, duration: duration, part: .back)
                back.behindSubject = true
                front.source = .motion(m, time: time, duration: duration, part: .front)
                front.behindSubject = false
                return [back, front]
            }
            return [layer]
        }
    }

    func layer(of track: Track, at t: MediaTime) -> VideoLayer? {
        guard let clip = track.clips.first(where: { $0.start <= t && t < $0.end }) else { return nil }
        let local = t - clip.start
        var tr = clip.transform(at: local)
        var effects: [LayerEffect] = []
        let fps = frameRate.doubleValue
        for e in clip.effects ?? [] {
            let s = e.strength(at: local, clipDuration: clip.duration)
            guard s > 0 else { continue }
            switch e.kind {
            case .punchZoom: tr.scale *= 1 + s * ((e.zoom ?? 1.12) - 1)
            case .shake:
                let (dx, dy, r) = Effect.shake(at: t.seconds, frequency: e.frequency ?? 7)
                tr.x += dx * s; tr.y += dy * s; tr.rotation += r * s
                if clip.placement == nil || clip.placement?.fit == .fill { tr.scale *= 1 + 0.04 * s }   // keep the edges out of view
            case .flash: break   // frame-wide: frameFX
            default:
                var le = LayerEffect(kind: e.kind, strength: s, radius: (e.radius ?? Self.defaultRadius(e.kind)) * Double(width) / SafeZones.referenceWidth,
                                     path: e.path)
                le.color = e.color
                le.tolerance = e.tolerance
                le.spill = e.spill
                if e.kind == .glitch {
                    let f = Int((t.seconds * fps).rounded())
                    le.seed = Int((Double(f) / max(fps / max(e.frequency ?? 12, 0.5), 1)).rounded(.down)) &* 7919 &+ e.id.hashValueStable
                }
                effects.append(le)
            }
        }
        var layer = VideoLayer(trackID: track.id, clipID: clip.id, assetID: clip.assetID, sourceTime: clip.sourceTime(atLocal: local),
                               sourceWidth: 0, sourceHeight: 0, crop: [0, 0, 0, 0], scale: tr.scale, x: tr.x, y: tr.y,
                               rotation: tr.rotation, opacity: tr.opacity, color: clip.color, source: .video,
                               placement: clip.placement, blend: clip.blend ?? .normal, effects: effects)
        // Picture fade (#79): a full-frame clip of a video track goes to black, anything else to transparent.
        let visible = clip.pictureVisibility(at: local)
        if visible < 1 {
            if track.kind == .video, clip.placement == nil || clip.placement?.fit == .fill { layer.dim = 1 - visible }
            else { layer.opacity *= visible }
        }
        layer.behindSubject = clip.isBehindSubject(at: local)
        layer.mask = clip.mask
        layer.anchorX = tr.anchorX; layer.anchorY = tr.anchorY
        layer.rotationX = tr.rotationX; layer.rotationY = tr.rotationY
        layer.perspective = tr.perspective
        if let m = clip.motion {
            layer.source = .motion(m, time: local.seconds, duration: clip.duration.seconds, part: .whole)
            if m.layering == .behind { layer.behindSubject = true }
            return layer
        }
        if let title = clip.title {
            layer.source = .title(title)
            return layer
        }
        if let sticker = clip.sticker {
            layer.source = .sticker(sticker)
            return layer
        }
        if let shape = clip.shape {
            layer.source = .shape(shape, shape.progress(at: local, duration: clip.duration))
            return layer
        }
        guard let asset = project.asset(clip.assetID), let video = asset.video else { return nil }
        let rect = tr.cropRect(sourceWidth: video.width, sourceHeight: video.height)
        let fill = clip.placement == nil || clip.placement?.fit == .fill
        let within = (Double(video.width), Double(video.height))
        // The project's look grades the picture (video, inserts, layout boxes), never a logo or a native-size overlay.
        if let g = clip.grade { layer.grade = g.resolved(at: local) }
        else if fill || clip.placement?.fit == .box { layer.grade = project.grade?.resolved(at: t) }
        // The drawn crop of a crop rect: a box is filled like the frame, the crop narrowed to the box's aspect around its centre.
        let (bw, bh) = layer.baseSize(width: width, height: height)
        let boxed = clip.placement?.fit == .box
        func drawn(_ r: [Double]) -> [Double] {
            if boxed { return Self.fit(r, aspect: bw / max(bh, 1), within: within) }
            return fill ? Self.fit(r, aspect: Double(width) / Double(height), within: within) : r
        }
        layer.crop = drawn(rect)
        if let amount = clip.motionBlur, amount > 0, (fill || boxed), (clip.keyframes?.count ?? 0) > 1 {
            // The crop half a frame before and after, from the keyframes alone (effects do not move the camera).
            let half = MediaTime(seconds: 0.5 / frameRate.doubleValue)
            let t0 = max(local - half, .zero), t1 = min(local + half, clip.duration)
            func cropAt(_ u: MediaTime) -> [Double] { drawn(clip.transform(at: u).cropRect(sourceWidth: video.width, sourceHeight: video.height)) }
            layer.cameraBlur = CameraBlur.make(crop: layer.crop, before: cropAt(t0), after: cropAt(t1), amount: amount,
                                               width: boxed ? bw : Double(width), height: boxed ? bh : Double(height))
        }
        layer.sourceWidth = video.width
        layer.sourceHeight = video.height
        layer.cursor = cursors[asset.id]?.overlay(atScreen: layer.sourceTime.seconds)
        if asset.image == nil, let m = asset.analysis?.matte { layer.matte = m.file(at: layer.sourceTime) }
        if let image = asset.image {
            layer.source = .image(image.file(at: layer.sourceTime))
            if let k = image.ink, !fill, rect[0] > 0, rect[1] > 0 {
                let x0 = max(k[0], rect[2]), y0 = max(k[1], rect[3]), x1 = min(k[0] + k[2], rect[2] + rect[0]), y1 = min(k[1] + k[3], rect[3] + rect[1])
                if x1 > x0, y1 > y0 {
                    layer.ink = [(x0 - rect[2]) / rect[0], (y0 - rect[3]) / rect[1], (x1 - rect[2]) / rect[0], (y1 - rect[3]) / rect[1]]
                }
            }
        }
        return layer
    }

    static func defaultRadius(_ kind: Effect.Kind) -> Double {
        switch kind {
        case .blur: 12
        case .glow: 24
        case .vignette: 1
        case .sharpen: 2
        default: 0
        }
    }

    /// Whole-frame modifiers at `t`: transitions around their cut and flash effects of the clips showing.
    public func frameFX(at t: MediaTime) -> FrameFX {
        var fx = FrameFX()
        for tr in project.transitions ?? [] {
            let cut = tr.time(in: project), half = tr.duration.seconds / 2
            let dt = (t - cut).seconds
            guard half > 0, dt >= -half, dt < half else { continue }
            let p = 1 - abs(dt) / half
            switch tr.kind {
            case .flash:
                let v = Easing.easeIn.apply(p) * 0.9
                if v > fx.flash { fx.flash = v; fx.flashColor = tr.color ?? "#FFFFFF" }
            case .dip: fx.dip = max(fx.dip, Easing.easeInOut.apply(p))
            case .blur:
                // Defocus ramps up to the cut and resolves on the next shot.
                fx.defocus = max(fx.defocus, 44 * Double(width) / SafeZones.referenceWidth * Easing.easeInOut.apply(p))
            case .whip:
                let dir: (Double, Double) = switch tr.direction ?? "left" {
                case "right": (1, 0)
                case "up": (0, -1)
                case "down": (0, 1)
                default: (-1, 0)
                }
                // Out: the picture accelerates away; in: the next one arrives from the other side and settles.
                let move = dt < 0 ? Easing.easeIn.apply(p) : -(1 - Easing.easeOut.apply(1 - p))
                fx.shiftX = dir.0 * move
                fx.shiftY = dir.1 * move
                fx.blur = 90 * Double(width) / SafeZones.referenceWidth * p
            }
        }
        for track in visualTracks {
            guard let clip = track.clips.first(where: { $0.start <= t && t < $0.end }) else { continue }
            for e in clip.effects ?? [] where e.kind == .flash {
                let s = e.strength(at: t - clip.start, clipDuration: clip.duration)
                if s > fx.flash { fx.flash = s; fx.flashColor = e.color ?? "#FFFFFF" }
            }
        }
        return fx
    }

    /// The largest rectangle of `aspect` (w/h) inside `crop`, same centre (aspect fill = reframe by crop).
    public static func fit(_ crop: [Double], aspect: Double, within size: (Double, Double)) -> [Double] {
        var (w, h) = (crop[0], crop[1])
        let cx = crop[2] + w / 2, cy = crop[3] + h / 2
        if abs(w / h - aspect) > 1e-4 {
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
        }
        let x = min(max(cx - w / 2, 0), size.0 - w), y = min(max(cy - h / 2, 0), size.1 - h)
        return [w, h, x, y]
    }

    /// Caption geometry at this output size: style pixels scale with the width, the band keeps its height fraction.
    public var captionScale: Double { Double(width) / (captions?.style.referenceWidth ?? 1080) }
    public var captionBandTop: Double {
        guard let s = captions?.style else { return 0 }
        return s.bandY / s.referenceHeight * Double(height)
    }
    /// Top of chunk `i`'s band (moved off a face, else the style's), output pixels.
    public func captionBandTop(chunk i: Int) -> Double {
        guard let c = captions, c.chunks.indices.contains(i), let y = c.chunks[i].bandY else { return captionBandTop }
        return y / c.style.referenceHeight * Double(height)
    }
    /// Horizontal shift of chunk `i`'s line from the centre, output pixels.
    public func captionShiftX(chunk i: Int) -> Double {
        guard let c = captions, c.chunks.indices.contains(i), let dx = c.chunks[i].offsetX else { return 0 }
        return dx * captionScale
    }

    /// Size of chunk `i`'s caption band, output pixels: the rasterizer lays the line out centred in a band of the
    /// output width and the style's band height, both times the chunk's scale.
    public func captionBandSize(chunk i: Int) -> (width: Int, height: Int) {
        let s = captions?.scale(chunk: i) ?? 1
        return (Int((Double(width) * s).rounded()), Int(((captions?.style.bandHeight ?? 0) * captionScale * s).rounded()))
    }

    /// Top-left corner of chunk `i`'s band on the output frame, output pixels, for a line whose ink box inside the band
    /// is `line` [x, y, w, h]. Automatic chunks: the style's band (or the one moved off a face) and shift, exactly as
    /// before manual placement existed. Chunks placed by hand (captions.place): x is the line's left edge / centre /
    /// right edge (align), y the band's vertical centre, scaled around that centre; clamped so the line stays inside the
    /// frame (when it fits), on whole pixels. `clamped` says whether the frame edge moved it.
    public func captionBandOrigin(chunk i: Int, line: [Double]) -> (x: Double, y: Double, clamped: Bool) {
        guard let c = captions, c.isManual(chunk: i), line.count == 4 else { return (captionShiftX(chunk: i), captionBandTop(chunk: i), false) }
        let m = c.manualPlace(chunk: i)
        let size = captionBandSize(chunk: i)
        let W = Double(width), H = Double(height)
        let cy = m.y.map { $0 / c.style.referenceHeight * H } ?? (captionBandTop(chunk: i) + c.style.bandHeight * captionScale / 2)
        var y = cy - Double(size.height) / 2
        var x: Double
        if let mx = m.x {
            let anchor: Double = switch m.align ?? .center {
            case .left: line[0]
            case .center: line[0] + line[2] / 2
            case .right: line[0] + line[2]
            }
            x = mx / c.style.referenceWidth * W - anchor
        } else {
            x = W / 2 + captionShiftX(chunk: i) - (line[0] + line[2] / 2)   // centred (or beside a face)
        }
        let free = (x.rounded(), y.rounded())
        if line[2] <= W { x = min(max(x, -line[0]), W - line[0] - line[2]) }
        if line[3] <= H { y = min(max(y, -line[1]), H - line[1] - line[3]) }
        x = x.rounded(); y = y.rounded()
        return (x, y, x != free.0 || y != free.1)
    }
}

/// One sound clip of the mix, in samples at the mix rate.
public struct AudioMixClip: Hashable, Sendable {
    public var path: String
    public var channels: Int
    public var sourceStart: Int
    public var sourceEnd: Int
    public var timelineStart: Int
    public var fadeIn: Double
    public var fadeOut: Double
    /// Static gain, dB.
    public var gain: Double = 0
    /// Mono float wav of a per-sample linear gain over the whole timeline (ducking), applied after placement.
    public var envelope: URL?
    /// Playback rate with the pitch kept (clip.speed): the source span plays in span / tempo.
    public var tempo: Double = 1
    /// Speed ramps: source offset (samples from `sourceStart`) every `mapStep` output samples, over `mapLength` samples.
    public var timeMap: [Double]?
    public var mapLength: Int?
    public static let mapStep = 160

    public var isStretched: Bool { tempo != 1 || timeMap != nil }

    /// Samples this clip lasts on the timeline.
    public var timelineLength: Int {
        if let m = mapLength { return m }
        return tempo == 1 ? sourceEnd - sourceStart : Int((Double(sourceEnd - sourceStart) / tempo).rounded())
    }

    /// Source sample (from `sourceStart`, fractional) played at output sample `i`.
    public func sourceOffset(atOutput i: Int) -> Double {
        guard let m = timeMap, !m.isEmpty else { return Double(i) * tempo }
        let x = Double(i) / Double(Self.mapStep)
        let k = min(max(Int(x), 0), m.count - 1)
        guard k + 1 < m.count else { return m[m.count - 1] }
        return m[k] + (m[k + 1] - m[k]) * (x - Double(k))
    }
}

public enum AudioPlan {
    /// Every clip of the unmuted audio tracks (or only `tracks`), sample-exact at `rate`; `envelopes` maps a track id
    /// to its gain envelope file (DuckingEnvelope).
    public static func clips(_ project: Project, rate: Int, tracks: Set<String>? = nil, envelopes: [String: URL] = [:]) -> [AudioMixClip] {
        func samples(_ t: MediaTime) -> Int { Int((t.seconds * Double(rate)).rounded()) }
        return project.tracks.filter { $0.kind == .audio && !$0.muted && (tracks?.contains($0.id) ?? true) }.flatMap { track in
            track.clips.flatMap { c -> [AudioMixClip] in
                guard let a = project.asset(c.assetID), let info = a.audio else { return [] }
                let plain = AudioMixClip(path: a.path, channels: info.channels, sourceStart: samples(c.sourceIn), sourceEnd: samples(c.sourceOut),
                                         timelineStart: samples(c.start), fadeIn: c.fadeIn?.seconds ?? 0, fadeOut: c.fadeOut?.seconds ?? 0,
                                         gain: c.gain ?? 0, envelope: envelopes[track.id])
                guard let speed = c.speed else { return [plain] }
                return retimed(plain, clip: c, speed: speed, rate: rate)
            }
        }
    }

    /// A retimed clip's sound: nothing when muted, one time-stretched clip for a constant rate, one time-mapped clip for
    /// a ramp (the mixer stretches it so each output sample plays the source sample its frame shows).
    static func retimed(_ c: AudioMixClip, clip: Clip, speed: Speed, rate: Int) -> [AudioMixClip] {
        guard speed.effectiveAudio == .pitch else { return [] }
        func samples(_ s: Double) -> Int { Int((s * Double(rate)).rounded()) }
        if !speed.isRamp {
            var one = c
            one.tempo = Double(c.sourceEnd - c.sourceStart) / Double(max(samples(clip.duration.seconds), 1))
            return [one]
        }
        // A ramp: one clip with its time map (source position every 160 output samples).
        var ramp = c
        let length = samples(clip.duration.seconds), span = clip.sourceDuration.seconds
        ramp.mapLength = length
        ramp.timeMap = stride(from: 0, through: length + AudioMixClip.mapStep, by: AudioMixClip.mapStep).map { i in
            speed.sourceOffset(atTimeline: Double(i) / Double(rate), span: span) * Double(rate)
        }
        return [ramp]
    }

    /// Writes the ducking envelope of every ducked audio track into `directory`; returns track id → file.
    public static func writeEnvelopes(_ project: Project, rate: Int, to directory: URL) throws -> [String: URL] {
        let length = Int((project.duration.seconds * Double(rate)).rounded())
        var out: [String: URL] = [:]
        for track in project.tracks where track.kind == .audio && !track.muted {
            guard let d = track.ducking, let source = project.tracks.first(where: { $0.id == d.sourceTrack }) else { continue }
            let regions = DuckingEnvelope.regions(of: source, in: project, mergeGap: d.mergeGap)
            let url = directory.appendingPathComponent("duck-\(track.id)-\(UUID().uuidString.prefix(6)).wav")
            try WAVAudio(sampleRate: rate, channels: 1, samples: DuckingEnvelope.samples(regions: regions, ducking: d, rate: rate, length: length))
                .writeFloat(to: url)
            out[track.id] = url
        }
        return out
    }
}

public struct ExportReport: Sendable {
    public var frames: Int
    public var seconds: Double

    public init(frames: Int, seconds: Double) {
        self.frames = frames
        self.seconds = seconds
    }
}

/// Draws the timeline (Core Image compositor in RegistaEngines). One code path for export.render and frame.render.
public protocol VideoRenderer {
    /// Encodes the timeline to an H.264/AAC mp4 (`audio`: a wav of the mix, or nil for silence-free video only).
    func export(_ job: RenderJob, audio: URL?, to output: URL, bitrate: Int) throws -> ExportReport
    /// One PNG per time, through the same compositor as the export.
    func renderFrames(_ job: RenderJob, at times: [MediaTime], to outputs: [URL]) throws
    /// Word boxes per chunk, output pixels, top-left origin: [x, y, w, h].
    func captionLayout(_ job: RenderJob) throws -> [[[Double]]]
    /// Every caption state's band (`Captions.states` order), downscaled by an integer factor (box average):
    /// BT.709 luma and alpha, 0…255, top-left origin. The caption timing check matches these against a render.
    func captionStates(_ job: RenderJob, downscale: Int) throws -> [CaptionRaster]
    /// One full-frame transparent PNG per caption state (for the MLT export), in `Captions.states` order.
    func writeCaptionImages(_ job: RenderJob, to directory: URL) throws -> [URL]
    /// Each chunk's caption band on the frame [x, y, w, h], output pixels (the region `captionStates` templates cover).
    func captionBands(_ job: RenderJob) throws -> [[Double]]
    /// Size of a title's box (background, or text block) at this output width, px.
    func titleBox(_ title: Title, outputWidth: Int) throws -> (width: Double, height: Double)
    /// A full-frame transparent PNG of one generated or image layer (title, still, sequence frame) as it is drawn
    /// at timeline time `time` (the MLT export places these where Shotcut cannot draw them itself).
    func writeLayerImage(_ job: RenderJob, clipID: String, at time: MediaTime, to url: URL) throws
}

extension VideoRenderer {
    /// Estimate for hosts without Core Text: the style estimate of each line placed like the compositor places it.
    public func captionBands(_ job: RenderJob) throws -> [[Double]] {
        guard let c = job.captions else { return [] }
        let k = job.captionScale
        return CaptionPlacement.estimatedInk(c.chunks, style: c.style).enumerated().map { i, boxes in
            let s = c.scale(chunk: i) * k
            let line = (FaceFraming.union(boxes) ?? [0, 0, 0, 0]).map { $0 * s }
            let o = job.captionBandOrigin(chunk: i, line: line)
            let size = job.captionBandSize(chunk: i)
            return [o.x, o.y, Double(size.width), Double(size.height)]
        }
    }

    /// Estimate for hosts without Core Text (unit tests): 0.55 em per character, 1.15 em per line.
    public func titleBox(_ title: Title, outputWidth: Int) throws -> (width: Double, height: Double) {
        let k = Double(outputWidth) / SafeZones.referenceWidth
        let lines = title.displayText.components(separatedBy: "\n")
        let w = Double(lines.map(\.count).max() ?? 0) * title.size * 0.55 + 2 * (title.background?.padX ?? 0)
        let h = Double(lines.count) * title.size * 1.15 + 2 * (title.background?.padY ?? 0)
        return (w * k, h * k)
    }

    public func writeLayerImage(_ job: RenderJob, clipID: String, at time: MediaTime, to url: URL) throws {
        throw CommandError(.io, "this host cannot draw layer images")
    }
}

public struct CaptionRaster: Sendable {
    public var width: Int
    public var height: Int
    public var luma: [UInt8]
    public var alpha: [UInt8]

    public init(width: Int, height: Int, luma: [UInt8], alpha: [UInt8]) {
        self.width = width
        self.height = height
        self.luma = luma
        self.alpha = alpha
    }
}
