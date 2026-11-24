import Foundation

// Where the face goes in a screen recording (issue #6): presets turned into ordinary clip properties — the
// screen and camera clips get a placement (fill, or a box of the frame), a crop of the camera around the face
// and a mask (circle, rounded square, person cut-out). Everything stays editable with clip.set / clip.keyframe;
// layout.apply writes it on a time range. Pure geometry, unit-tested.

/// A layout preset with its options, as stored in session.json and in the project.
public struct LayoutSpec: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// Face in a bubble in a corner over the full screen.
        case bubble
        /// Side by side: screen 2/3, face 1/3 (landscape outputs).
        case split
        /// Vertical stack: screen on top, face below (9:16 reels).
        case stack
        /// The face full screen (the screen hidden).
        case face
        /// The person without background over the screen (Vision person matte, matte.track).
        case cutout
        /// The screen alone (the camera hidden).
        case screen
    }

    public static let corners = ["topLeft", "topRight", "bottomLeft", "bottomRight"]
    public static let shapes = ["circle", "rounded"]
    public static let sizes = ["S", "M", "L"]
    public static let sides = ["left", "right", "top", "bottom"]

    public var kind: Kind
    /// bubble: topLeft | topRight | bottomLeft | bottomRight; cutout: bottomLeft | bottomRight. Default bottomRight.
    public var corner: String?
    /// bubble: circle | rounded (rounded square). Default circle.
    public var shape: String?
    /// bubble, cutout: S | M | L. Default M.
    public var size: String?
    /// split: side of the face, right | left (default right); stack: face bottom | top (default bottom).
    public var side: String?
    /// screen, bubble: the whole screen on a styled background with padding, rounded corners and a shadow (issue #44).
    public var frame: ScreenFrame?

    /// Layouts that take a styled frame.
    public static let framed: Set<Kind> = [.screen, .bubble]

    public init(kind: Kind, corner: String? = nil, shape: String? = nil, size: String? = nil, side: String? = nil, frame: ScreenFrame? = nil) {
        self.kind = kind
        self.corner = corner
        self.shape = shape
        self.size = size
        self.side = side
        self.frame = frame
    }

    /// Short human description ("bubble bottomRight circle M").
    public var label: String {
        var parts = [kind.rawValue]
        switch kind {
        case .bubble: parts += [corner ?? "bottomRight", shape ?? "circle", size ?? "M"]
        case .cutout: parts += [corner ?? "bottomRight", size ?? "M"]
        case .split: parts += ["face " + (side ?? "right")]
        case .stack: parts += ["face " + (side ?? "bottom")]
        case .face, .screen: break
        }
        if let f = frame { parts += ["framed", f.background?.preset ?? (f.background.map(\.label) ?? "default")] }
        return parts.joined(separator: " ")
    }

    /// Whether a layout of `kind` lays out in a frame of `aspect` (width / height): side by side needs width, so not in a
    /// portrait frame; the vertical stack needs height, so not in a landscape one.
    public static func applies(_ kind: Kind, aspect: Double) -> Bool {
        !(aspect < 1 && kind == .split) && !(aspect > 1 && kind == .stack)
    }

    /// The layout a frame of `aspect` gives (project.format, Registra's preview): side by side becomes the vertical stack
    /// in a portrait frame and back in a landscape one, the face on the same side; the others stay as they are.
    public func fitted(aspect: Double) -> LayoutSpec {
        if aspect < 1, kind == .split { return LayoutSpec(kind: .stack, side: side == "left" ? "top" : nil) }
        if aspect > 1, kind == .stack { return LayoutSpec(kind: .split, side: side == "top" ? "left" : nil) }
        return self
    }

    /// Checks the options against the kind.
    public func validate() throws {
        if let c = corner {
            guard Self.corners.contains(c) else { throw CommandError.invalid("layout: corner must be one of \(Self.corners.joined(separator: ", "))") }
            if kind == .cutout, c.hasPrefix("top") { throw CommandError.invalid("layout: the cut-out stands on the bottom edge: corner bottomLeft or bottomRight") }
        }
        if let s = shape, !Self.shapes.contains(s) { throw CommandError.invalid("layout: shape must be circle or rounded") }
        if let s = size, !Self.sizes.contains(s) { throw CommandError.invalid("layout: size must be S, M or L") }
        if let s = side {
            let ok = kind == .stack ? ["top", "bottom"] : ["left", "right"]
            guard ok.contains(s) else { throw CommandError.invalid("layout: side for \(kind.rawValue) must be \(ok.joined(separator: " or "))") }
        }
        if let f = frame {
            guard Self.framed.contains(kind) else { throw CommandError.invalid("layout: the styled frame is for the screen and bubble layouts, not \(kind.rawValue)") }
            try f.validate()
        }
    }
}

/// What a layout does to one of the two layers.
public struct LayerLayout: Hashable, Sendable {
    /// nil: fill the frame.
    public var placement: Placement?
    /// Source pixels [w, h, x, y] (camera: around the face); nil keeps the clip's own crop (screen).
    public var crop: [Double]?
    public var mask: LayerMask?
    /// false: the layer is not drawn (opacity 0).
    public var visible = true

    public init(placement: Placement? = nil, crop: [Double]? = nil, mask: LayerMask? = nil, visible: Bool = true) {
        self.placement = placement
        self.crop = crop
        self.mask = mask
        self.visible = visible
    }

    /// Output-pixel size of the box this layer is drawn into (the whole frame for fill layers).
    public func boxSize(width W: Int, height H: Int) -> (Double, Double) {
        guard let p = placement, p.fit == .box else { return (Double(W), Double(H)) }
        return ((p.width ?? 1) * Double(W), (p.height ?? 1) * Double(H))
    }
}

public struct LayoutGeometry: Hashable, Sendable {
    public var screen: LayerLayout
    public var camera: LayerLayout
    /// Frame background shown around boxed layers (nil: black).
    public var background: String?
}

public enum Layouts {
    /// Dark backdrop of the layouts that do not cover the frame (split).
    public static let backdrop = "#0F1013"

    /// Face box [x, y, w, h] in camera pixels assumed when the camera was never face-tracked: a webcam or phone
    /// framing with the head centred in the upper part.
    public static func defaultFace(cameraWidth w: Double, cameraHeight h: Double) -> [Double] {
        let side = 0.26 * min(w, h)
        let cy = h > w ? 0.34 * h : 0.42 * h
        return [w / 2 - side / 2, cy - side / 2, side, side * 1.15]
    }

    /// Largest crop of `aspect` (w/h) whose height is `faceHeights` face heights (or what fits), with the face
    /// centre `faceAt` of the way down from its top, clamped inside the source. [w, h, x, y].
    public static func cropAround(face f: [Double], aspect: Double, faceHeights: Double, faceAt: Double,
                                  source: (Double, Double)) -> [Double] {
        var h = f[3] * faceHeights, w = h * aspect
        if w > source.0 { w = source.0; h = w / aspect }
        if h > source.1 { h = source.1; w = h * aspect }
        let cx = f[0] + f[2] / 2, cy = f[1] + f[3] / 2
        let x = min(max(cx - w / 2, 0), source.0 - w)
        let y = min(max(cy - faceAt * h, 0), source.1 - h)
        return [w, h, x, y]
    }

    /// Diameter of a bubble, fraction of the shorter output side.
    static func bubbleFraction(_ size: String?) -> Double {
        switch size {
        case "S": 0.22
        case "L": 0.40
        default: 0.30
        }
    }

    /// Height of the cut-out box, fraction of the output height.
    static func cutoutFraction(_ size: String?, portrait: Bool) -> Double {
        switch size {
        case "S": portrait ? 0.40 : 0.55
        case "L": portrait ? 0.60 : 0.85
        default: portrait ? 0.50 : 0.70
        }
    }

    /// A box placement from output pixels (centre and size).
    static func box(cx: Double, cy: Double, w: Double, h: Double, W: Double, H: Double) -> Placement {
        var p = Placement(fit: .box, x: cx / W, y: cy / H)
        p.width = w / W
        p.height = h / H
        return p
    }

    /// The geometry of `spec` for a `width`×`height` output, a `screen` source and a `camera` source (display pixels)
    /// whose face box is `face` (camera pixels; nil: `defaultFace`).
    public static func geometry(_ spec: LayoutSpec, width: Int, height: Int, screen: (Int, Int), camera: (Int, Int),
                                face: [Double]? = nil) -> LayoutGeometry {
        let W = Double(width), H = Double(height), S = min(W, H)
        let cam = (Double(camera.0), Double(camera.1)), scr = (Double(screen.0), Double(screen.1))
        let f = face ?? defaultFace(cameraWidth: cam.0, cameraHeight: cam.1)
        let portrait = H > W
        switch spec.kind {
        case .bubble:
            let d = (bubbleFraction(spec.size) * S).rounded(), m = (0.045 * S).rounded()
            let corner = spec.corner ?? "bottomRight"
            var cx = corner.hasSuffix("Left") ? m + d / 2 : W - m - d / 2
            var cy = corner.hasPrefix("top") ? m + d / 2 : H - m - d / 2
            var screenLayer = LayerLayout()
            if let f = spec.frame {
                var b = f.screenBox(width: W, height: H, screen: scr)
                if (H - b[3]) / 2 >= d / 2 + m {
                    // A framed screen that leaves room above or below it (portrait, 4:5, square): the bubble stays with the
                    // screen, straddling its edge in the chosen corner, and the pair is centred as a group.
                    let top = corner.hasPrefix("top")
                    b[1] += top ? d / 4 : -d / 4
                    let inset = 0.6 * m
                    cx = corner.hasSuffix("Left") ? b[0] - b[2] / 2 + inset + d / 2 : b[0] + b[2] / 2 - inset - d / 2
                    cy = top ? b[1] - b[3] / 2 : b[1] + b[3] / 2
                }
                screenLayer = LayerLayout(placement: box(cx: b[0], cy: b[1], w: b[2], h: b[3], W: W, H: H), mask: f.mask(box: b, width: W, height: H))
            }
            let circle = (spec.shape ?? "circle") == "circle"
            var mask = LayerMask(shape: circle ? .circle : .rounded)
            if !circle { mask.radius = 0.22 }
            mask.borderColor = "#FFFFFF"
            mask.borderWidth = 3
            mask.borderOpacity = 0.85
            mask.shadow = 0.35
            return LayoutGeometry(
                screen: screenLayer,
                camera: LayerLayout(placement: box(cx: cx, cy: cy, w: d, h: d, W: W, H: H),
                                    crop: cropAround(face: f, aspect: 1, faceHeights: 2.7, faceAt: 0.52, source: cam), mask: mask),
                background: nil)
        case .split:
            // Two cards of the same height side by side on a dark backdrop: the screen contained (never cropped) in
            // two thirds, the face in the last third.
            let g = (0.035 * H).rounded()
            let faceRight = (spec.side ?? "right") == "right"
            let columnW = (W - 3 * g) / 3
            let regionW = 2 * columnW, regionH = H - 2 * g
            let a = scr.0 / max(scr.1, 1)
            var sw = regionW, sh = regionW / a
            if sh > regionH { sh = regionH; sw = sh * a }
            let fw = columnW, fh = sh
            // The pair is centred as a group.
            let total = sw + g + fw
            let x0 = (W - total) / 2
            let screenCX = faceRight ? x0 + sw / 2 : x0 + fw + g + sw / 2
            let faceCX = faceRight ? x0 + sw + g + fw / 2 : x0 + fw / 2
            var screenMask = LayerMask(shape: .rounded)
            screenMask.radius = 0.035
            screenMask.shadow = 0.3
            var faceMask = screenMask
            faceMask.radius = 0.035 * sh / min(fw, fh)
            return LayoutGeometry(
                screen: LayerLayout(placement: box(cx: screenCX, cy: H / 2, w: sw, h: sh, W: W, H: H), mask: screenMask),
                camera: LayerLayout(placement: box(cx: faceCX, cy: H / 2, w: fw, h: fh, W: W, H: H),
                                    crop: cropAround(face: f, aspect: fw / fh, faceHeights: 3.6, faceAt: 0.5, source: cam), mask: faceMask),
                background: backdrop)
        case .stack:
            let faceTop = spec.side == "top"
            let hs = (H / 2).rounded(), hf = H - hs
            let screenCY = faceTop ? hf + hs / 2 : hs / 2
            let faceCY = faceTop ? hf / 2 : hs + hf / 2
            return LayoutGeometry(
                screen: LayerLayout(placement: box(cx: W / 2, cy: screenCY, w: W, h: hs, W: W, H: H)),
                camera: LayerLayout(placement: box(cx: W / 2, cy: faceCY, w: W, h: hf, W: W, H: H),
                                    crop: cropAround(face: f, aspect: W / hf, faceHeights: 3.6, faceAt: 0.5, source: cam)),
                background: nil)
        case .face:
            return LayoutGeometry(
                screen: LayerLayout(visible: false),
                camera: LayerLayout(crop: cropAround(face: f, aspect: W / H, faceHeights: portrait ? 6 : 3.8, faceAt: 0.48, source: cam)),
                background: nil)
        case .cutout:
            let crop = cropAround(face: f, aspect: 0.8, faceHeights: 5.2, faceAt: 0.24, source: cam)
            let bh = (cutoutFraction(spec.size, portrait: portrait) * H).rounded()
            let bw = (bh * crop[0] / crop[1]).rounded()
            let m = (0.03 * S).rounded()
            let left = spec.corner == "bottomLeft"
            let cx = left ? m + bw / 2 : W - m - bw / 2
            var mask = LayerMask(shape: .rect)
            mask.cutout = true
            mask.shadow = 0.3
            return LayoutGeometry(
                screen: LayerLayout(),
                camera: LayerLayout(placement: box(cx: cx, cy: H - bh / 2, w: bw, h: bh, W: W, H: H), crop: crop, mask: mask),
                background: nil)
        case .screen:
            return LayoutGeometry(screen: spec.frame.map { framedScreen($0, W: W, H: H, screen: scr) } ?? LayerLayout(),
                                  camera: LayerLayout(visible: false), background: nil)
        }
    }

    /// The screen layer inside a styled frame: a box of the screen's own aspect, rounded and floating.
    static func framedScreen(_ frame: ScreenFrame, W: Double, H: Double, screen: (Double, Double)) -> LayerLayout {
        let b = frame.screenBox(width: W, height: H, screen: screen)
        return LayerLayout(placement: box(cx: b[0], cy: b[1], w: b[2], h: b[3], W: W, H: H), mask: frame.mask(box: b, width: W, height: H))
    }

    /// Median face box of a face track over the source window [from, to) (smoothed boxes), nil without detections.
    public static func medianFace(_ track: FaceTrack, from: Double, to: Double) -> [Double]? {
        let boxes = track.frames.filter { $0.t >= from && $0.t < to }.compactMap { $0.smooth ?? $0.raw }
        let all = boxes.isEmpty ? track.frames.compactMap { $0.smooth ?? $0.raw } : boxes
        guard !all.isEmpty else { return nil }
        func median(_ k: Int) -> Double {
            let v = all.map { $0[k] }.sorted()
            return v[v.count / 2]
        }
        return [median(0), median(1), median(2), median(3)]
    }
}
