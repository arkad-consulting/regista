import Foundation

// Speaker layouts for any project (issue #22, round 2–3): the talking head boxed into a letterbox band, a side card,
// a corner bubble over B-roll or a styled inset card — written as the same clip properties the screen-recording
// layouts use (`Placement.box`, a crop around the face, `LayerMask`), so they stay editable with clip.set. Pure
// geometry here; layout.speaker writes it.

public enum SpeakerLayout: String, CaseIterable, Sendable {
    /// 9:16 frame: a band on top with a persistent headline, the 16:9 picture in the middle, an empty bottom band.
    case letterboxHeadline = "letterbox-headline"
    /// The speaker in a rounded card on one side, the other side free for a graphic.
    case splitCard = "split-card"
    /// The speaker in a circle in a corner over a full-frame graphic or B-roll.
    case pipBubble = "pip-bubble"
    /// The whole shot scaled into a styled card (neon, glass, plain) on a backdrop; animates in from full frame.
    case insetFrame = "inset-frame"
    /// Back to the full frame (removes the layout).
    case full

    public static let names = allCases.map(\.rawValue)

    public static let positions = ["center", "topLeft", "left"]
}

/// Where the speaker goes for one layout on a `W`×`H` output.
public struct SpeakerGeometry: Sendable {
    /// nil: fill the frame.
    public var placement: Placement?
    /// Source pixels [w, h, x, y] of the speaker; nil = the whole frame.
    public var crop: [Double]?
    public var mask: LayerMask?
    /// Frame background around the box (nil: leave it).
    public var background: String?
    /// letterbox-headline: centre of the headline, output pixels.
    public var headline: (x: Double, y: Double)?
    /// The free area beside the box [x, y, w, h], output pixels (split-card, inset-frame topLeft/left): where a graphic goes.
    public var free: [Double]?
}

extension SpeakerLayout {
    public struct Options: Sendable {
        /// split-card: left | right (side of the card); pip-bubble: corner topLeft | topRight | bottomLeft | bottomRight.
        public var side: String?
        public var corner: String?
        /// pip-bubble: S | M | L.
        public var size: String?
        /// inset-frame: center | topLeft | left; frame neon | glass | plain; chip texts; glow colour.
        public var position: String?
        public var frame: String?
        public var label: String?
        public var badge: String?
        public var accent: String
        public var background: String?

        public init(side: String? = nil, corner: String? = nil, size: String? = nil, position: String? = nil, frame: String? = nil,
                    label: String? = nil, badge: String? = nil, accent: String = "#FF7A1A", background: String? = nil) {
            self.side = side
            self.corner = corner
            self.size = size
            self.position = position
            self.frame = frame
            self.label = label
            self.badge = badge
            self.accent = accent
            self.background = background
        }
    }

    /// The geometry for a `width`×`height` output and a `source` (display pixels) whose face box is `face` (source
    /// pixels; nil: a centred upper framing is assumed).
    public func geometry(width: Int, height: Int, source: (Int, Int), face: [Double]?, options o: Options) -> SpeakerGeometry {
        let W = Double(width), H = Double(height), S = min(W, H)
        let src = (Double(source.0), Double(source.1))
        // Untracked: a selfie framing, the face about the middle of a vertical shot.
        let f = face ?? {
            var d = Layouts.defaultFace(cameraWidth: src.0, cameraHeight: src.1)
            if src.1 > src.0 { d[1] = 0.48 * src.1 - d[3] / 2 }
            return d
        }()
        let portrait = H > W
        let kx = W / SafeZones.referenceWidth, ky = H / SafeZones.referenceHeight
        func box(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> Placement { Layouts.box(cx: cx, cy: cy, w: w, h: h, W: W, H: H) }
        switch self {
        case .letterboxHeadline:
            // The 16:9 band a little above the middle; the headline sits in the lower part of the top band.
            let bw = W, bh = min((W * 9 / 16).rounded(), 0.6 * H)
            let cy = (portrait ? 0.45 * H : 0.55 * H).rounded()
            var mask = LayerMask(shape: .rect)
            mask.shadow = nil
            let top = cy - bh / 2
            return SpeakerGeometry(placement: box(W / 2, cy, bw, bh),
                                   crop: Layouts.cropAround(face: f, aspect: bw / bh, faceHeights: 3.6, faceAt: 0.56, source: src),
                                   mask: mask, background: o.background ?? "#000000",
                                   headline: (W / 2, max(top - 0.06 * H, (SafeZones.topLimit + 60) * ky)), free: nil)
        case .splitCard:
            let cw = (0.46 * W).rounded(), ch = (cw * (portrait ? 1.25 : 1.15)).rounded()
            let m = (0.06 * W).rounded()
            let left = (o.side ?? "left") == "left"
            let cx = left ? m + cw / 2 : W - m - cw / 2, cy = (portrait ? 0.45 * H : 0.5 * H).rounded()
            var mask = LayerMask(shape: .rounded)
            mask.radius = 0.06
            mask.borderColor = "#FFFFFF"
            mask.borderWidth = 3
            mask.borderOpacity = 0.9
            mask.shadow = 0.28
            let freeX = left ? cx + cw / 2 + m / 2 : m / 2
            return SpeakerGeometry(placement: box(cx, cy, cw, ch),
                                   crop: Layouts.cropAround(face: f, aspect: cw / ch, faceHeights: 3.4, faceAt: 0.42, source: src),
                                   mask: mask, background: o.background ?? "#F4F2EE",
                                   free: [freeX, cy - ch / 2, W - cw - 2.5 * m, ch])
        case .pipBubble:
            let d = (Layouts.bubbleFraction(o.size) * S).rounded()
            let corner = o.corner ?? "bottomRight"
            let right = corner.hasSuffix("Right"), topCorner = corner.hasPrefix("top")
            let cx: Double, cy: Double
            if portrait {
                // Clear of the Instagram rail and bars and of the caption band (the bubble sits just above it).
                cx = right ? W - (SafeZones.rightMargin + 24) * kx - d / 2 : 48 * kx + d / 2
                cy = topCorner ? (SafeZones.topLimit + 48) * ky + d / 2 : (SafeZones.caption.0 - 28) * ky - d / 2
            } else {
                let m = (0.045 * S).rounded()
                cx = right ? W - m - d / 2 : m + d / 2
                cy = topCorner ? m + d / 2 : H - m - d / 2
            }
            var mask = LayerMask(shape: .circle)
            mask.borderColor = "#FFFFFF"
            mask.borderWidth = 3
            mask.borderOpacity = 0.85
            mask.shadow = 0.35
            return SpeakerGeometry(placement: box(cx, cy, d, d),
                                   crop: Layouts.cropAround(face: f, aspect: 1, faceHeights: 2.7, faceAt: 0.52, source: src), mask: mask)
        case .insetFrame:
            // The card keeps the frame's aspect, so the whole shot shows and the zoom from full frame is exact.
            let position = o.position ?? "center"
            let aspect = W / H
            // Portrait: half the width, the top under the status-bar row, the bottom above the caption band.
            let cw = ((portrait ? (position == "center" ? 0.5 : 0.47) : (position == "center" ? 0.62 : 0.5)) * W).rounded()
            let ch = (cw / aspect).rounded()
            let cx = position == "center" ? W / 2 : (0.08 * W + cw / 2).rounded()
            let top = portrait ? (SafeZones.topLimit + 130) * ky : 0.12 * H
            let cy = position == "left" ? (portrait ? 0.4 * H : 0.5 * H).rounded() : (top + ch / 2).rounded()
            var mask = LayerMask(shape: .rounded)
            mask.radius = 0.05
            mask.frame = o.frame ?? "neon"
            mask.glowColor = o.accent
            mask.label = o.label
            mask.badge = o.badge
            switch mask.frame {
            case "glass":
                mask.borderColor = "#FFFFFF"; mask.borderWidth = 2; mask.borderOpacity = 0.45; mask.shadow = 0.4
            case "plain":
                mask.borderColor = "#FFFFFF"; mask.borderWidth = 2; mask.borderOpacity = 0.25; mask.shadow = 0.35
            default:
                mask.borderColor = o.accent; mask.borderWidth = 4; mask.borderOpacity = 1; mask.shadow = 0.25
            }
            let free: [Double]? = position == "center" ? nil : [cx + cw / 2 + 0.04 * W, cy - ch / 2, W - (cx + cw / 2) - 0.04 * W - 0.06 * W, ch]
            return SpeakerGeometry(placement: box(cx, cy, cw, ch), crop: nil, mask: mask, background: o.background ?? "#0C0C0E", free: free)
        case .full:
            return SpeakerGeometry()
        }
    }
}
