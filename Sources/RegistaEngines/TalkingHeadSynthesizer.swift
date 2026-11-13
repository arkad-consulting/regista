import AVFoundation
import CoreGraphics
import Foundation
import RegistaCore

// The synthetic talking head of media.synthesize (issue #22): a warm wall with a window, a speaker silhouette (dark
// top, skin-tone head with hair) that sways and nods, and the exact person matte of every frame.

extension CGScreenSynthesizer {
    public func writeTalkingHead(_ s: SyntheticTalkingHead) throws {
        try? FileManager.default.removeItem(at: s.output)
        try FileManager.default.createDirectory(at: s.matteDirectory, withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: s.output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: s.width, AVVideoHeightKey: s.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000, AVVideoExpectedSourceFrameRateKey: s.fps],
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: s.width, kCVPixelBufferHeightKey as String: s.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw CommandError(.io, "media.synthesize: cannot write \(s.output.lastPathComponent)") }
        writer.startSession(atSourceTime: .zero)
        let W = Double(s.width), H = Double(s.height)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let mw = s.width / s.matteScale, mh = s.height / s.matteScale
        for i in 0..<s.frames {
            let t = Double(i) / Double(s.fps)
            let person = Self.person(t: t, W: W, H: H)
            while !input.isReadyForMoreMediaData { usleep(500) }
            guard let pool = adaptor.pixelBufferPool else { throw CommandError(.io, "media.synthesize: no pixel buffer pool") }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let buffer = pb else { throw CommandError(.io, "media.synthesize: no pixel buffer") }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: s.width, height: s.height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)
            // Wall: a soft vertical gradient, a bright window on the left, a shelf line.
            let wall = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 0.86, green: 0.83, blue: 0.79, alpha: 1),
                                                                 CGColor(srgbRed: 0.72, green: 0.69, blue: 0.65, alpha: 1)] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(wall, start: .zero, end: CGPoint(x: 0, y: H), options: [])
            ctx.setFillColor(CGColor(srgbRed: 0.95, green: 0.96, blue: 0.97, alpha: 1)); ctx.fill(CGRect(x: 0.03 * W, y: 0.17 * H, width: 0.17 * W, height: 0.4 * H))
            ctx.setFillColor(CGColor(srgbRed: 0.58, green: 0.66, blue: 0.62, alpha: 1)); ctx.fill(CGRect(x: 0.8 * W, y: 0.18 * H, width: 0.16 * W, height: 0.38 * H))
            ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.45, blue: 0.4, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0.6 * H, width: W, height: 0.006 * H))
            // The person.
            ctx.addPath(person.body); ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.13, blue: 0.17, alpha: 1)); ctx.fillPath()
            ctx.addPath(person.neck); ctx.setFillColor(CGColor(srgbRed: 0.78, green: 0.6, blue: 0.5, alpha: 1)); ctx.fillPath()
            ctx.addPath(person.head); ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.66, blue: 0.55, alpha: 1)); ctx.fillPath()
            ctx.addPath(person.hair); ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.15, blue: 0.12, alpha: 1)); ctx.fillPath()
            for e in person.eyes { ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillEllipse(in: e) }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(s.fps))) else {
                throw CommandError(.io, "media.synthesize: encoding failed at frame \(i)")
            }
            // The exact matte at a quarter size.
            let m = CGContext(data: nil, width: mw, height: mh, bitsPerComponent: 8, bytesPerRow: mw, space: CGColorSpaceCreateDeviceGray(),
                              bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            m.translateBy(x: 0, y: Double(mh)); m.scaleBy(x: 1 / Double(s.matteScale), y: -1 / Double(s.matteScale))
            m.setFillColor(gray: 1, alpha: 1)
            for path in [person.body, person.neck, person.head, person.hair] { m.addPath(path); m.fillPath() }
            let px = Array(UnsafeBufferPointer(start: m.data!.assumingMemoryBound(to: UInt8.self), count: mw * mh))
            try VisionPersonSegmenter.writeGray(px, width: mw, height: mh, to: s.matteDirectory.appendingPathComponent(String(format: "%06d.png", i)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw CommandError(.io, "media.synthesize: \(writer.error?.localizedDescription ?? "writing failed")") }
    }

    /// Head and shoulders at time t (top-left origin pixels): a slow sway and a small nod.
    static func person(t: Double, W: Double, H: Double) -> (body: CGPath, neck: CGPath, head: CGPath, hair: CGPath, eyes: [CGRect]) {
        let sway = 0.025 * W * sin(t * 1.3), nod = 0.006 * H * sin(t * 2.7 + 0.4)
        let cx = W / 2 + sway, headY = 0.43 * H + nod
        let hw = 0.27 * W, hh = 0.36 * W
        let head = CGPath(ellipseIn: CGRect(x: cx - hw / 2, y: headY - hh / 2, width: hw, height: hh), transform: nil)
        let hair = CGMutablePath()
        hair.addEllipse(in: CGRect(x: cx - hw * 0.53, y: headY - hh * 0.58, width: hw * 1.06, height: hh * 0.5))
        let neck = CGPath(rect: CGRect(x: cx - 0.06 * W, y: headY + hh * 0.38, width: 0.12 * W, height: 0.08 * H), transform: nil)
        let body = CGMutablePath()
        let top = headY + hh / 2 + 0.03 * H
        body.move(to: CGPoint(x: cx - 0.46 * W, y: H))
        body.addCurve(to: CGPoint(x: cx - 0.12 * W, y: top), control1: CGPoint(x: cx - 0.46 * W, y: top + 0.08 * H), control2: CGPoint(x: cx - 0.36 * W, y: top))
        body.addLine(to: CGPoint(x: cx + 0.12 * W, y: top))
        body.addCurve(to: CGPoint(x: cx + 0.46 * W, y: H), control1: CGPoint(x: cx + 0.36 * W, y: top), control2: CGPoint(x: cx + 0.46 * W, y: top + 0.08 * H))
        body.closeSubpath()
        let eyes = [-1.0, 1.0].map { s in CGRect(x: cx + s * hw * 0.2 - 0.012 * W, y: headY - 0.005 * H, width: 0.024 * W, height: 0.012 * H) }
        return (body, neck, head, hair, eyes)
    }
}
