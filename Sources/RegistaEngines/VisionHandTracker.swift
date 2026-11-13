import AVFoundation
import Foundation
import RegistaCore
import Vision

/// Hand poses with Apple Vision (`VNDetectHumanHandPoseRequest`) on every decoded frame of a source range (half
/// resolution, oriented for display like the face tracker). Per hand: palm centre (wrist + the four knuckles), wrist,
/// index tip, the box of its confident joints, how open it is and its chirality. Display pixels of the full-size video.
public struct VisionHandTracker: HandTracker {
    public init() {}

    public static let engine = "Apple Vision VNDetectHumanHandPoseRequest"

    public func track(_ video: URL, from: Double, to: Double, maxHands: Int) throws -> HandTrack {
        let asset = AVURLAsset(url: video)
        guard let vt = VisionFaceTracker.load({ try await asset.loadTracks(withMediaType: .video) })?.first else {
            throw CommandError(.io, "hands.track: no video track in \(video.lastPathComponent)")
        }
        let natural = VisionFaceTracker.load({ try await vt.load(.naturalSize) }) ?? .zero
        let fps = Double(VisionFaceTracker.load({ try await vt.load(.nominalFrameRate) }) ?? 30)
        let orientation = VisionFaceTracker.orientation(VisionFaceTracker.load({ try await vt.load(.preferredTransform) }) ?? .identity)
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
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(from, 0), preferredTimescale: 600_000),
                                       end: CMTime(seconds: to, preferredTimescale: 600_000))
        guard reader.startReading() else {
            throw CommandError(.io, "hands.track: cannot decode \(video.lastPathComponent): \(reader.error?.localizedDescription ?? "?")")
        }
        var frames: [HandTrack.Frame] = []
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = max(maxHands, 1)
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([request])
            let hands = (request.results ?? []).compactMap { Self.hand($0, width: Double(width), height: Double(height)) }
            frames.append(HandTrack.Frame(t: (t * 1000).rounded() / 1000, hands: hands))
        }
        if reader.status == .failed {
            throw CommandError(.io, "hands.track: decoding failed: \(reader.error?.localizedDescription ?? "?")")
        }
        return HandTrack(video: video.path, engine: Self.engine, width: width, height: height, fps: fps, from: from, to: to, frames: frames)
    }

    static func hand(_ o: VNHumanHandPoseObservation, width W: Double, height H: Double) -> HandTrack.Hand? {
        guard let points = try? o.recognizedPoints(.all) else { return nil }
        let good = points.filter { $0.value.confidence > 0.3 }
        guard good.count >= 6, let wrist = good[.wrist] else { return nil }
        func px(_ p: VNRecognizedPoint) -> [Double] { [(p.location.x * W * 100).rounded() / 100, ((1 - p.location.y) * H * 100).rounded() / 100] }
        let knuckles: [VNHumanHandPoseObservation.JointName] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let palmPts = ([wrist] + knuckles.compactMap { good[$0] }).map(px)
        guard palmPts.count >= 3 else { return nil }
        let palm = [palmPts.map { $0[0] }.reduce(0, +) / Double(palmPts.count), palmPts.map { $0[1] }.reduce(0, +) / Double(palmPts.count)]
        let w = px(wrist)
        let all = good.values.map(px)
        let x0 = all.map { $0[0] }.min()!, x1 = all.map { $0[0] }.max()!, y0 = all.map { $0[1] }.min()!, y1 = all.map { $0[1] }.max()!
        // Open: mean fingertip distance from the wrist over the palm length (wrist → middle knuckle); ~1 fist, ~2 open.
        let tips: [VNHumanHandPoseObservation.JointName] = [.indexTip, .middleTip, .ringTip, .littleTip]
        let palmLength = good[.middleMCP].map { hypot(px($0)[0] - w[0], px($0)[1] - w[1]) } ?? max(x1 - x0, y1 - y0) / 2
        let reach = tips.compactMap { good[$0] }.map { hypot(px($0)[0] - w[0], px($0)[1] - w[1]) }
        let ratio = reach.isEmpty ? 1 : reach.reduce(0, +) / Double(reach.count) / max(palmLength, 1)
        let open = min(max((ratio - 1.1) / 0.8, 0), 1)
        let chirality: String = switch o.chirality {
        case .left: "left"
        case .right: "right"
        default: "?"
        }
        let index = good[.indexTip].map(px) ?? palm
        let confidence = Double(good.values.map(\.confidence).reduce(0, +)) / Double(good.count)
        return HandTrack.Hand(chirality: chirality, palm: palm.map { ($0 * 100).rounded() / 100 }, wrist: w, index: index,
                              box: [x0, y0, x1 - x0, y1 - y0], open: (open * 100).rounded() / 100, confidence: (confidence * 100).rounded() / 100)
    }
}
