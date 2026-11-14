import Foundation

// Direct manipulation on the preview (issue #21): what can be grabbed on a frame (from the render plan, so the
// hit boxes are where the compositor draws), the view ↔ frame mapping of a monitor, and the snap guides.

/// Something drawn on the preview that a click answers: a caption chunk, a title / sticker / logo / overlay clip, the
/// full-frame picture (a camera take, a full-frame insert), a box of a recording layout, a callout, a progress bar, a
/// status row or level meters (#30). A halo following an object and a motion template are only selected by a click.
public struct CanvasElement: Hashable, Sendable {
    public enum Kind: String, Sendable {
        case caption, title, sticker, logo, overlay
        /// A clip that fills the frame (or filled it before it was first moved by hand).
        case picture
        /// A box of a recording layout (screen, camera bubble).
        case layoutBox
        case callout, progress, status, meters
        /// Follows an object (clip.follow): selected by a click, never moved by hand.
        case halo
        /// A motion template, drawn from its own fields over the whole frame: selected by a click, never moved by hand.
        case motion
    }
    public var kind: Kind
    public var trackID: String
    /// The clip (nil for captions).
    public var clipID: String?
    /// The chunk index (captions).
    public var chunk: Int?
    /// The caption chunk's text.
    public var text: String?
    /// Axis-aligned box on the output frame [x, y, w, h], output pixels (rotation included).
    public var box: [Double]
    /// Centre and unrotated size of the drawn content, output pixels; rotation in degrees clockwise.
    public var center: [Double]
    public var size: [Double]
    public var rotation: Double
    /// Current size factor (captions: the chunk's scale; boxes, pictures and callouts: their size against the one
    /// before they were first moved by hand; other clips: the rest transform's scale).
    public var scale: Double
    /// Put there by hand (captions.place / clip.place).
    public var manual: Bool
    /// A drag, the handles and the bar move and resize it (false: a click only selects its clip).
    public var movable = true
    /// Hit only where nothing else is under the pointer (a motion template drawn over the whole frame).
    public var background = false

    public var rotatable: Bool { [.title, .sticker, .logo, .overlay].contains(kind) }
    /// A full-frame picture is never moved by accident: a click selects it first, a drag moves it only once selected.
    public var needsSelection: Bool { kind == .picture }

    /// Stable identity for selection: the clip id, or `caption:<track>:<chunk>`.
    public var id: String { clipID ?? "caption:\(trackID):\(chunk ?? -1)" }

    public func contains(_ p: (x: Double, y: Double), margin: Double = 0) -> Bool {
        // In the element's own (unrotated) frame.
        let r = -rotation * .pi / 180
        let dx = p.x - center[0], dy = p.y - center[1]
        let u = dx * cos(r) - dy * sin(r), v = dx * sin(r) + dy * cos(r)
        return abs(u) <= size[0] / 2 + margin && abs(v) <= size[1] / 2 + margin
    }

    public var json: JSONValue {
        func r(_ v: [Double]) -> JSONValue { .array(v.map { .number(($0 * 10).rounded() / 10) }) }
        var o: [String: JSONValue] = ["kind": .string(kind.rawValue), "trackId": .string(trackID), "box": r(box), "center": r(center),
                                      "size": r(size), "rotation": .number((rotation * 10).rounded() / 10),
                                      "scale": .number((scale * 1000).rounded() / 1000), "manual": .bool(manual), "movable": .bool(movable)]
        if let clipID { o["clipId"] = .string(clipID) }
        if let chunk { o["chunk"] = .number(Double(chunk)) }
        if let text { o["text"] = .string(text) }
        return .object(o)
    }
}

extension Clip {
    /// A picture drawn over the whole frame, or that was before clip.place first moved it (the move turns "fills the
    /// frame" into a box as large as the frame).
    public var isFullFramePicture: Bool {
        guard !isGenerated else { return false }
        if placement == nil || placement?.fit == .fill { return true }
        guard placement?.fit == .box, let o = placeOrigin else { return false }
        return o.placement == nil || o.placement?.fit == .fill
    }

    /// What scale 1 means for a boxed picture (clip.place): the box before it was first moved by hand, the whole frame
    /// for a picture that filled it. Fractions of the frame's width and height; nil when the clip is not boxed.
    public var boxBase: (width: Double, height: Double)? {
        guard let p = placement, p.fit == .box else { return nil }
        if isFullFramePicture { return (1, 1) }
        let o = placeOrigin?.placement?.fit == .box ? placeOrigin!.placement! : p
        return (o.width ?? 1, o.height ?? 1)
    }
}

public enum CanvasLayout {
    /// The elements on the frame at timeline time `t`, bottom to top (the caption last: it is drawn on top). Every
    /// visible layer is listed; a halo and a motion template are listed as not movable.
    public static func elements(_ project: Project, at t: MediaTime, renderer: VideoRenderer?) -> [CanvasElement] {
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project))
        let W = Double(job.width), H = Double(job.height)
        var out: [CanvasElement] = []
        for layer in job.layers(at: t) {
            guard layer.opacity > 0.01 else { continue }
            let track = project.tracks.first { $0.id == layer.trackID }
            let clip = track?.clips.first { $0.id == layer.clipID }
            let manual = clip?.placeOrigin != nil
            func element(_ kind: CanvasElement.Kind, _ b: [Double], scale: Double = 1) -> CanvasElement {
                CanvasElement(kind: kind, trackID: layer.trackID, clipID: layer.clipID, chunk: nil, text: clip?.title?.text, box: b,
                              center: [b[0] + b[2] / 2, b[1] + b[3] / 2], size: [b[2], b[3]], rotation: 0, scale: scale, manual: manual)
            }
            switch layer.source {
            case .shape(let s, _):
                // Drawn in frame coordinates from its own rectangle (only the layer's offset applies).
                let kind: CanvasElement.Kind = switch s.kind {
                case .progressBar: .progress
                case .statusBar: .status
                case .audioMeters: .meters
                case .halo: .halo
                default: .callout
                }
                let o = clip?.placeOrigin?.rect ?? s.rect
                let base = max(abs(o[2]), abs(o[3])), now = max(abs(s.rect[2]), abs(s.rect[3]))
                var e = element(kind, shapeBox(s, width: job.width, height: job.height, offset: (layer.x, layer.y)), scale: base > 0 ? now / base : 1)
                e.movable = s.kind != .halo
                out.append(e)
                continue
            case .motion:
                // A split template comes as two layers of one clip.
                guard !out.contains(where: { $0.clipID == layer.clipID }) else { continue }
                var e = element(.motion, [0, 0, W, H])
                e.movable = false
                e.background = true
                out.append(e)
                continue
            default: break
            }
            let fill = layer.placement == nil || layer.placement?.fit == .fill
            let asset = project.asset(layer.assetID)
            let kind: CanvasElement.Kind
            switch layer.source {
            case .title: kind = .title
            case .sticker: kind = .sticker
            default:
                if fill || clip?.isFullFramePicture == true { kind = .picture }
                else if layer.placement?.fit == .box, asset?.image == nil { kind = .layoutBox }
                else { kind = track?.role == "logo" ? .logo : .overlay }
            }
            var drawn = layer
            // A full-frame picture with transparent margins (an alpha overlay drawn over the whole frame): its visible part.
            if fill, let ink = asset?.image?.ink, drawn.crop[0] > 0, drawn.crop[1] > 0 {
                let c = drawn.crop
                let f = [(ink[0] - c[2]) / c[0], (ink[1] - c[3]) / c[1], (ink[0] + ink[2] - c[2]) / c[0], (ink[1] + ink[3] - c[3]) / c[1]].map { min(max($0, 0), 1) }
                if f[2] > f[0], f[3] > f[1], f != [0, 0, 1, 1] { drawn.ink = f }
            }
            let content = Graphics.content(drawn, job: job, renderer: renderer)
            let (w, h) = drawn.baseSize(width: job.width, height: job.height, content: content)
            let (cx, cy) = drawn.centre(width: job.width, height: job.height)
            var size = [w * drawn.scale, h * drawn.scale], center = [cx, cy]
            // Pictures with transparent margins: the visible part.
            if drawn.ink != nil, drawn.rotation == 0 {
                let b = drawn.box(width: job.width, height: job.height, content: content)
                size = [b[2], b[3]]; center = [b[0] + b[2] / 2, b[1] + b[3] / 2]
            }
            var scale = clip?.transform?.scale ?? 1
            if fill { scale = 1 } else if let base = clip?.boxBase, let bw = drawn.placement?.width { scale = bw / max(base.width, 1e-9) }
            var e = CanvasElement(kind: kind, trackID: drawn.trackID, clipID: drawn.clipID, chunk: nil, text: clip?.title?.text,
                                  box: drawn.box(width: job.width, height: job.height, content: content), center: center, size: size,
                                  rotation: drawn.rotation, scale: scale, manual: manual)
            // A stream with transparency over the whole frame, whose visible part is unknown: hit only where nothing else is.
            e.background = fill && asset?.video?.alpha == true && asset?.image == nil
            out.append(e)
        }
        if let captions = job.captions, let track = project.tracks.last(where: { $0.kind == .caption && !$0.hidden && $0.captions != nil }),
           let ci = captions.chunk(at: t) {
            // Only that chunk is laid out (its geometry depends on its own fields and the track's, not on the others).
            var one = job, only = captions
            only.chunks = [captions.chunks[ci]]
            one.captions = only
            if let line = CaptionPlacement.wordBoxes(one, renderer: renderer).first.flatMap(FaceFraming.union) {
                out.append(CanvasElement(kind: .caption, trackID: track.id, clipID: nil, chunk: ci, text: captions.chunks[ci].text, box: line,
                                         center: [line[0] + line[2] / 2, line[1] + line[3] / 2], size: [line[2], line[3]], rotation: 0,
                                         scale: captions.scale(chunk: ci), manual: captions.isManual(chunk: ci)))
            }
        }
        return out
    }

    /// Where a callout, progress bar, status row or meters are drawn [x, y, w, h], output pixels: their rectangle (an
    /// arrow: from its tail to its head), with the stroke, the arrowhead, the circle's overshoot and the underline's line.
    public static func shapeBox(_ s: ShapeLayer, width: Int, height: Int, offset: (Double, Double) = (0, 0)) -> [Double] {
        let W = Double(width), H = Double(height), k = W / SafeZones.referenceWidth
        var x = s.rect[0] * W, y = s.rect[1] * H, w = s.rect[2] * W, h = s.rect[3] * H
        if w < 0 { x += w; w = -w }
        if h < 0 { y += h; h = -h }
        var pad = max(s.width * k, 1) / 2 + 2 * k
        switch s.kind {
        case .arrow: pad += 24 * k
        case .circle: x -= w * 0.08; w *= 1.16; y -= h * 0.1; h *= 1.2
        case .underline: h += max(6, h * 0.08) + h * 0.04
        case .progressBar: h = max(s.width * k, 1)
        case .box, .highlight, .halo, .statusBar, .audioMeters: break
        }
        return [x - pad + offset.0 * W, y - pad + offset.1 * H, w + 2 * pad, h + 2 * pad]
    }

    /// The topmost element under a frame point (a few pixels of margin make thin text easy to grab); a background
    /// element (a motion template over the whole frame) only where nothing else is.
    public static func hit(_ elements: [CanvasElement], at p: (x: Double, y: Double), margin: Double = 0) -> CanvasElement? {
        elements.last { !$0.background && $0.contains(p, margin: margin) } ?? elements.last { $0.background && $0.contains(p, margin: margin) }
    }
}

/// Where the output frame lands inside a monitor view: aspect-fit, centred (like `FrameView.pictureRect`).
public struct PreviewMapping: Hashable, Sendable {
    public var frameWidth: Double
    public var frameHeight: Double
    /// The picture's rectangle in the view, view points [x, y, w, h], top-left origin.
    public var picture: [Double]

    public init(viewWidth: Double, viewHeight: Double, frameWidth: Int, frameHeight: Int) {
        self.frameWidth = Double(frameWidth)
        self.frameHeight = Double(frameHeight)
        let aspect = self.frameWidth / max(self.frameHeight, 1)
        let w = min(viewWidth, viewHeight * aspect), h = w / aspect
        picture = [(viewWidth - w) / 2, (viewHeight - h) / 2, w, h]
    }

    /// View points per frame pixel.
    public var scale: Double { picture[2] / max(frameWidth, 1) }

    public func toFrame(_ p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        ((p.x - picture[0]) / scale, (p.y - picture[1]) / scale)
    }

    public func toView(_ p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        (picture[0] + p.x * scale, picture[1] + p.y * scale)
    }

    /// A frame box [x, y, w, h] in view points.
    public func toView(box b: [Double]) -> [Double] {
        let o = toView((b[0], b[1]))
        return [o.x, o.y, b[2] * scale, b[3] * scale]
    }
}

/// Snap guides while dragging: the frame's centre lines and thirds, and the edges and centres of the other elements.
public enum Snapper {
    public struct Guide: Hashable, Sendable {
        public enum Kind: String, Sendable { case center, third, element }
        /// true: a vertical line at x = position; false: a horizontal line at y = position (frame pixels).
        public var vertical: Bool
        public var position: Double
        public var kind: Kind
    }

    /// Lines a box can snap to on a `width`×`height` frame, with the boxes of the other elements.
    public static func targets(width: Int, height: Int, others: [[Double]]) -> [Guide] {
        let W = Double(width), H = Double(height)
        var g: [Guide] = [Guide(vertical: true, position: W / 2, kind: .center), Guide(vertical: false, position: H / 2, kind: .center)]
        g += [1.0 / 3, 2.0 / 3].flatMap { f in [Guide(vertical: true, position: W * f, kind: .third), Guide(vertical: false, position: H * f, kind: .third)] }
        for b in others {
            g += [b[0], b[0] + b[2] / 2, b[0] + b[2]].map { Guide(vertical: true, position: $0, kind: .element) }
            g += [b[1], b[1] + b[3] / 2, b[1] + b[3]].map { Guide(vertical: false, position: $0, kind: .element) }
        }
        return g
    }

    /// Moves `box` [x, y, w, h] onto the nearest guide within `threshold` (frame pixels) on each axis: its left edge,
    /// centre or right edge (top, centre, bottom). Returns the shift and the guides it now touches.
    public static func snap(_ box: [Double], to guides: [Guide], threshold: Double) -> (dx: Double, dy: Double, guides: [Guide]) {
        func best(_ vertical: Bool, _ edges: [Double]) -> (Double, Guide)? {
            var found: (Double, Guide)?
            for g in guides where g.vertical == vertical {
                for e in edges {
                    let d = g.position - e
                    // Equal distance: the frame's own lines win over the other elements' edges.
                    if abs(d) <= threshold, found == nil || abs(d) < abs(found!.0) - 1e-9 { found = (d, g) }
                }
            }
            return found
        }
        let x = best(true, [box[0], box[0] + box[2] / 2, box[0] + box[2]])
        let y = best(false, [box[1], box[1] + box[3] / 2, box[1] + box[3]])
        let dx = x?.0 ?? 0, dy = y?.0 ?? 0
        let moved = [box[0] + dx, box[1] + dy, box[2], box[3]]
        // Every guide the moved box lies on (several can coincide).
        let touching = guides.filter { g in
            let edges = g.vertical ? [moved[0], moved[0] + moved[2] / 2, moved[0] + moved[2]] : [moved[1], moved[1] + moved[3] / 2, moved[1] + moved[3]]
            return (g.vertical ? x != nil : y != nil) && edges.contains { abs($0 - g.position) < 0.5 }
        }
        return (dx, dy, Array(Set(touching)))
    }
}
