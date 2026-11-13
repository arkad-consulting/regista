import AVFoundation
import CoreImage
import Foundation
import RegistaCore
import Vision

/// Face boxes with Apple Vision on every decoded frame (AVAssetReader, half resolution). The box is
/// the extent of the face landmarks (`VNDetectFaceLandmarksRequest`, brow to chin, like MediaPipe's
/// landmark box): on the test take its frame-to-frame shake is half that of the detector's own
/// bounding box (4.8 vs 11 px RMS). The detector box is the fallback when landmarks are missing.
/// Boxes are in display pixels of the full-size video (rotation applied, origin top-left); the
/// largest face wins. Shot cuts (big thumbnail change, or a face size jump > 7%) are reported so
/// smoothing restarts there. Every other face of the frame (confidence ≥ 0.5) is kept in `others`,
/// so crops and captions can keep clear of all of them.
public struct VisionFaceTracker: FaceTracker {
    public init() {}

    public func track(_ video: URL, options: FaceTrackOptions) throws -> FaceTrack {
        let asset = AVURLAsset(url: video)
        guard let vt = Self.load({ try await asset.loadTracks(withMediaType: .video) })?.first else {
            throw CommandError(.io, "faces.track: no video track in \(video.lastPathComponent)")
        }
        let natural = Self.load({ try await vt.load(.naturalSize) }) ?? .zero
        let transform = Self.load({ try await vt.load(.preferredTransform) }) ?? .identity
        let fps = Double(Self.load({ try await vt.load(.nominalFrameRate) }) ?? 30)
        let orientation = Self.orientation(transform)
        let rotated = orientation == .right || orientation == .left
        let width = Int(rotated ? natural.height : natural.width), height = Int(rotated ? natural.width : natural.height)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(natural.width / 2),
            kCVPixelBufferHeightKey as String: Int(natural.height / 2),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else {
            throw CommandError(.io, "faces.track: cannot decode \(video.lastPathComponent): \(reader.error?.localizedDescription ?? "?")")
        }

        var frames: [FaceTrack.Frame] = []
        var cuts: [Int] = []
        var previousThumb: [Float]?
        var previousWidth: Double?
        let context = CIContext(options: [.useSoftwareRenderer: false])
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let index = frames.count

            let thumb = Self.thumbnail(pixels, orientation: orientation, context: context)
            var cut = false
            if let prev = previousThumb, prev.count == thumb.count {
                var diff: Float = 0
                for k in thumb.indices { diff += abs(thumb[k] - prev[k]) }
                cut = diff / Float(thumb.count) > 10
            }
            previousThumb = thumb

            let request = VNDetectFaceLandmarksRequest()
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([request])
            var raw: [Double]?
            var points: [String: [Double]]?
            var others: [[Double]]?
            let faces = (request.results ?? [])
                .sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }
            /// Landmark extent of a face in display pixels (the detector box when landmarks are missing).
            func box(_ face: VNFaceObservation) -> [Double] {
                let b = face.boundingBox   // normalized, origin bottom-left, in the oriented image
                var r: [Double]
                if let all = face.landmarks?.allPoints, all.pointCount > 0 {
                    // Landmark points are normalized to the face box.
                    let pts = all.normalizedPoints.map { p in
                        ((b.minX + Double(p.x) * b.width) * Double(width), (1 - (b.minY + Double(p.y) * b.height)) * Double(height))
                    }
                    let x0 = pts.map(\.0).min()!, x1 = pts.map(\.0).max()!, y0 = pts.map(\.1).min()!, y1 = pts.map(\.1).max()!
                    r = [x0, y0, x1 - x0, y1 - y0]
                } else {
                    r = [b.minX * Double(width), (1 - b.maxY) * Double(height), b.width * Double(width), b.height * Double(height)]
                }
                return r.map { ($0 * 100).rounded() / 100 }
            }
            let rest = faces.dropFirst().filter { $0.confidence >= 0.5 }
            if !rest.isEmpty { others = rest.map(box) }
            if let face = faces.first {
                let b = face.boundingBox
                func pixel(_ p: CGPoint) -> (x: Double, y: Double) {
                    ((b.minX + Double(p.x) * b.width) * Double(width), (1 - (b.minY + Double(p.y) * b.height)) * Double(height))
                }
                raw = box(face)
                if let pw = previousWidth, !cut, pw > 0, abs(raw![2] - pw) / pw > 0.07 { cut = true }
                previousWidth = raw![2]
                if options.landmarks, let lm = face.landmarks {
                    points = [:]
                    let named: [(String, VNFaceLandmarkRegion2D?)] = [("leftEye", lm.leftEye), ("rightEye", lm.rightEye),
                                                                       ("nose", lm.nose), ("mouth", lm.outerLips)]
                    for (name, region) in named {
                        guard let region, region.pointCount > 0 else { continue }
                        let pts = region.normalizedPoints.map { pixel($0) }
                        let x = pts.map(\.x).reduce(0, +) / Double(pts.count), y = pts.map(\.y).reduce(0, +) / Double(pts.count)
                        points?[name] = [(x * 10).rounded() / 10, (y * 10).rounded() / 10]
                    }
                }
            }
            if cut, index > 0 { cuts.append(index) }
            frames.append(FaceTrack.Frame(t: (t * 1000).rounded() / 1000, raw: raw, points: points, others: others))
        }
        if reader.status == .failed {
            throw CommandError(.io, "faces.track: decoding failed: \(reader.error?.localizedDescription ?? "?")")
        }
        return FaceTrack(video: video.path, engine: "Apple Vision VNDetectFaceLandmarksRequest (landmark extent)", width: width, height: height,
                         fps: fps, minCutoff: options.minCutoff, beta: options.beta, cuts: cuts, frames: frames)
    }

    /// 54×96 (or 96×54) grayscale thumbnail, 0…255, for cut detection.
    static func thumbnail(_ pixels: CVPixelBuffer, orientation: CGImagePropertyOrientation, context: CIContext) -> [Float] {
        let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        let target = image.extent.width < image.extent.height ? CGSize(width: 54, height: 96) : CGSize(width: 96, height: 54)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: target.width / image.extent.width,
                                                             y: target.height / image.extent.height))
        let w = Int(target.width), h = Int(target.height)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        context.render(scaled, toBitmap: &rgba, rowBytes: w * 4, bounds: CGRect(origin: scaled.extent.origin, size: target),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (0..<w * h).map { i in 0.299 * Float(rgba[4 * i]) + 0.587 * Float(rgba[4 * i + 1]) + 0.114 * Float(rgba[4 * i + 2]) }
    }

    /// Display orientation from the track's preferred transform (iPhone portrait = .right).
    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a, t.b, t.c, t.d) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }

    /// Bridges AVFoundation's async loaders into this synchronous engine call, off Swift's cooperative pool (#80:
    /// `BlockingBridge` says why); nil when the load fails.
    static func load<T>(_ body: @escaping () async throws -> T) -> T? {
        try? BlockingBridge.run("regista.av-load", body).get()
    }
}
