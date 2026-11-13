import AVFoundation
import CoreImage
import Foundation
import ImageIO
import RegistaCore
import UniformTypeIdentifiers
import Vision

/// Person mattes with Apple Vision (`VNGeneratePersonSegmentationRequest`, quality balanced: Apple's on-device model,
/// fine on the Base tier). Frames are decoded at half resolution and oriented for display before segmentation, so
/// the masks are upright. Each written matte is the [¼, ½, ¼] average of the frame and its two neighbours (less
/// edge flicker, no lag), as an 8-bit grey PNG named by source frame index.
public struct VisionPersonSegmenter: PersonSegmenter {
    public init() {}

    public static let engine = "Apple Vision VNGeneratePersonSegmentationRequest (balanced), [1 2 1]/4 temporal smoothing"

    public func segment(_ r: MatteRequest) throws -> MatteReport {
        let fm = FileManager.default
        try fm.createDirectory(at: r.directory, withIntermediateDirectories: true)
        func file(_ i: Int) -> URL { r.directory.appendingPathComponent(String(format: "%06d.png", i)) }
        let wanted = Set(r.frames.filter { !fm.fileExists(atPath: file($0).path) })
        guard !wanted.isEmpty else {
            let size = r.frames.first.flatMap { CGImageSourceCreateWithURL(file($0) as CFURL, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            return MatteReport(width: size?.width ?? 0, height: size?.height ?? 0, segmented: 0, coverage: 0, engine: Self.engine)
        }
        let needed = Set(wanted.flatMap { [$0 - 1, $0, $0 + 1] })

        let asset = AVURLAsset(url: r.video)
        guard let vt = VisionFaceTracker.load({ try await asset.loadTracks(withMediaType: .video) })?.first else {
            throw CommandError(.io, "matte.track: no video track in \(r.video.lastPathComponent)")
        }
        let natural = VisionFaceTracker.load({ try await vt.load(.naturalSize) }) ?? .zero
        let orientation = VisionFaceTracker.orientation(VisionFaceTracker.load({ try await vt.load(.preferredTransform) }) ?? .identity)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: vt, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(natural.width / 2),
            kCVPixelBufferHeightKey as String: Int(natural.height / 2),
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let lo = Double(needed.min()! ) / r.frameRate - 0.5 / r.frameRate, hi = Double(needed.max()! + 1) / r.frameRate
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(lo, 0), preferredTimescale: 600_000),
                                       end: CMTime(seconds: hi + 0.5 / r.frameRate, preferredTimescale: 600_000))
        guard reader.startReading() else {
            throw CommandError(.io, "matte.track: cannot decode \(r.video.lastPathComponent): \(reader.error?.localizedDescription ?? "?")")
        }

        typealias Mask = (index: Int, width: Int, height: Int, pixels: [UInt8])
        var prev: Mask?, cur: Mask?
        var written = 0, coverage = 0.0, size = (0, 0)
        func emit(_ c: Mask, left: Mask?, right: Mask?) throws {
            guard wanted.contains(c.index) else { return }
            var out = [UInt8](repeating: 0, count: c.pixels.count)
            let l = left.flatMap { $0.index == c.index - 1 && $0.pixels.count == c.pixels.count ? $0.pixels : nil }
            let rr = right.flatMap { $0.index == c.index + 1 && $0.pixels.count == c.pixels.count ? $0.pixels : nil }
            var sum = 0
            c.pixels.withUnsafeBufferPointer { m in
                for k in 0..<m.count {
                    var v = 2 * Int(m[k]), w = 2
                    if let l { v += Int(l[k]); w += 1 }
                    if let rr { v += Int(rr[k]); w += 1 }
                    let x = (v + w / 2) / w
                    out[k] = UInt8(x)
                    sum += x
                }
            }
            try Self.writeGray(out, width: c.width, height: c.height, to: file(c.index))
            written += 1
            coverage += Double(sum) / Double(255 * max(out.count, 1))
            size = (c.width, c.height)
        }

        // One request and one sequence handler for the whole run: a new request per frame reloads the model.
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNSequenceRequestHandler()
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let index = Int((CMSampleBufferGetPresentationTimeStamp(sample).seconds * r.frameRate).rounded())
            guard needed.contains(index) else { continue }
            try handler.perform([request], on: pixels, orientation: orientation)
            guard let mask = request.results?.first?.pixelBuffer else { continue }
            let n: Mask = Self.read(mask, index: index)
            if let c = cur { try emit(c, left: prev, right: n) }
            prev = cur
            cur = n
        }
        if let c = cur { try emit(c, left: prev, right: nil) }
        if reader.status == .failed { throw CommandError(.io, "matte.track: decoding failed: \(reader.error?.localizedDescription ?? "?")") }
        return MatteReport(width: size.0, height: size.1, segmented: written, coverage: written > 0 ? coverage / Double(written) : 0, engine: Self.engine)
    }

    static func read(_ buffer: CVPixelBuffer, index: Int) -> (index: Int, width: Int, height: Int, pixels: [UInt8]) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), row = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { pixels[y * w + x] = base[y * row + x] } }
        return (index, w, h, pixels)
    }

    static func writeGray(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CommandError(.io, "matte.track: cannot write \(url.path)")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CommandError(.io, "matte.track: cannot write \(url.path)") }
    }
}
