import Foundation

// Motion blur on camera moves (issue #43): while a zoom or pan moves the crop, the picture is smeared along the move
// as a camera with an open shutter would, proportionally to the crop's speed in output pixels, nothing when the
// camera is still. A crop change between two instants is a uniform scale plus a shift of the drawn picture (a zoom
// about some point, or a pure pan), so the blur is described by the two maps at the shutter's edges.

/// The smear of one layer at one frame: where a point of the drawn crop (fractions of it, top-left origin) is at
/// the shutter's opening (`back`) and closing (`forward`): u → u·scale + offset.
public struct CameraBlur: Hashable, Sendable {
    public struct Map: Hashable, Sendable {
        public var scale: Double
        public var dx: Double
        public var dy: Double

        public init(scale: Double, dx: Double, dy: Double) {
            self.scale = scale
            self.dx = dx
            self.dy = dy
        }

        public static let identity = Map(scale: 1, dx: 0, dy: 0)

        /// The map from the crop `from` to the crop `to` ([w, h, x, y], same aspect): where a point of `from` lands in `to`.
        public static func between(_ from: [Double], _ to: [Double]) -> Map {
            Map(scale: from[0] / max(to[0], 1e-9), dx: (from[2] - to[2]) / max(to[0], 1e-9), dy: (from[3] - to[3]) / max(to[1], 1e-9))
        }

        /// Part `f` of the way from the identity to this map.
        public func scaled(_ f: Double) -> Map { Map(scale: 1 + (scale - 1) * f, dx: dx * f, dy: dy * f) }

        /// Longest displacement of the picture's corners, pixels of a `width`×`height` drawing.
        public func length(width: Double, height: Double) -> Double {
            var m = 0.0
            for u in [0.0, 1.0] { for v in [0.0, 1.0] { m = max(m, hypot((u * (scale - 1) + dx) * width, (v * (scale - 1) + dy) * height)) } }
            return m
        }
    }

    public var back: Map
    public var forward: Map
    /// Longest smear across the shutter, pixels of the drawing the maps were made for.
    public var length: Double

    /// Below this smear (pixels) nothing is drawn.
    public static let threshold = 0.75
    /// Longest smear at amount 1, fraction of the drawing's width (amount 0.5: 3 %, ~58 px across 1920).
    public static let maxLength = 0.06

    /// The blur of a crop seen at `before` and `after` around the frame (crops at ∓ half a frame), with the shutter
    /// open for `amount` of the frame, drawn at `width`×`height`; nil when the smear is under a pixel.
    public static func make(crop: [Double], before: [Double], after: [Double], amount: Double, width: Double, height: Double) -> CameraBlur? {
        guard amount > 0, crop[0] > 0, crop[1] > 0 else { return nil }
        // The crop at the shutter's edges, linearly between the neighbouring instants.
        func at(_ other: [Double]) -> [Double] { (0..<4).map { crop[$0] + (other[$0] - crop[$0]) * min(amount, 1) } }
        var back = Map.between(crop, at(before)), forward = Map.between(crop, at(after))
        var length = back.length(width: width, height: height) + forward.length(width: width, height: height)
        guard length >= threshold else { return nil }
        let cap = maxLength * width * min(amount, 1)
        if length > cap {
            back = back.scaled(cap / length)
            forward = forward.scaled(cap / length)
            length = cap
        }
        return CameraBlur(back: back, forward: forward, length: length)
    }
}
