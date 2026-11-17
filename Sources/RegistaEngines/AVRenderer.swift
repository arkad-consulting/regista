import AVFoundation
import CoreImage
import Foundation
import RegistaCore

/// `VideoRenderer` on AVFoundation: the timeline becomes an AVMutableComposition (one composition
/// track per visual track) read through an AVVideoComposition whose custom compositor is
/// `TimelineCompositor`. Export pulls frames with AVAssetReaderVideoCompositionOutput into an
/// AVAssetWriter (H.264 High, BT.709, faststart) together with the AAC-encoded mix; frame.render pulls
/// single frames through the very same reader and compositor. Headless: no window, no preview layer.
public struct AVRenderer: VideoRenderer {
    /// An export that delivers no frame (and no audio) for this many seconds is stopped with an error instead of waiting
    /// forever (#71): the reader and writer are cancelled and the partial file removed.
    public var stallTimeout: TimeInterval

    public init(stallTimeout: TimeInterval = 60) { self.stallTimeout = stallTimeout }

    /// Exact CMTime in a small time scale when one fits (AVFoundation dislikes the 705 600 000 tick scale).
    static func cm(_ t: MediaTime) -> CMTime {
        for scale: Int64 in [600, 30000, 48000, 90000] where t.ticks % (MediaTime.ticksPerSecond / scale) == 0 {
            return CMTime(value: t.ticks / (MediaTime.ticksPerSecond / scale), timescale: CMTimeScale(scale))
        }
        return CMTime(value: t.ticks, timescale: CMTimeScale(MediaTime.ticksPerSecond))
    }

    static func frameDuration(_ rate: Rational) -> CMTime { CMTime(value: rate.den, timescale: CMTimeScale(rate.num)) }

    /// Output frames are BT.709 video range once encoded: say so on the buffers.
    static func tag709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    struct Built {
        var composition: AVMutableComposition
        var videoComposition: AVMutableVideoComposition
        var tracks: [AVCompositionTrack]
        var drawer: FrameDrawer
        /// Source assets, kept alive while the composition reads them.
        var sources: [AVURLAsset]
    }

    func build(_ job: RenderJob) throws -> Built {
        let composition = AVMutableComposition()
        var assets: [String: (asset: AVURLAsset, track: AVAssetTrack, orientation: CGImagePropertyOrientation)] = [:]
        var trackIDs: [String: CMPersistentTrackID] = [:]
        var clipOrientations: [String: CGImagePropertyOrientation] = [:]
        var proxies: [AVURLAsset] = []
        let end = Self.cm(job.duration)
        for track in job.visualTracks {
            // Titles and image files (stills, PNG sequences) are drawn from memory, not read through AVFoundation.
            let streamed = track.clips.filter { c in !c.isGenerated && job.project.asset(c.assetID).map { $0.image == nil && $0.video != nil } == true }
            guard !streamed.isEmpty else { continue }
            guard let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CommandError(.io, "render: cannot create a composition track")
            }
            var cursor = CMTime.zero
            for clip in streamed {
                guard let asset = job.project.asset(clip.assetID) else { continue }
                if assets[asset.id] == nil {
                    let av = AVURLAsset(url: URL(fileURLWithPath: asset.path))
                    guard let vt = VisionFaceTracker.load({ try await av.loadTracks(withMediaType: .video) })?.first else {
                        throw CommandError(.io, "render: no video track in \(asset.path)")
                    }
                    let transform = VisionFaceTracker.load({ try await vt.load(.preferredTransform) }) ?? .identity
                    assets[asset.id] = (av, vt, VisionFaceTracker.orientation(transform))   // the track does not retain its asset
                }
                let start = Self.cm(clip.start)
                if start > cursor { ct.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start)) }
                var source = assets[asset.id]!.track
                if clip.speed?.reverse == true {
                    // A reversed clip reads its reversed proxy (made by clip.speed), upright after ffmpeg's autorotate.
                    guard let proxy = clip.speed?.proxy, FileManager.default.fileExists(atPath: proxy) else {
                        throw CommandError(.io, "render: clip \(clip.id) is reversed but its proxy is missing (run clip.speed again)")
                    }
                    let av = AVURLAsset(url: URL(fileURLWithPath: proxy))
                    guard let vt = VisionFaceTracker.load({ try await av.loadTracks(withMediaType: .video) })?.first else {
                        throw CommandError(.io, "render: no video track in \(proxy)")
                    }
                    let transform = VisionFaceTracker.load({ try await vt.load(.preferredTransform) }) ?? .identity
                    clipOrientations[clip.id] = VisionFaceTracker.orientation(transform)
                    proxies.append(av)
                    source = vt
                }
                do { try Self.insert(clip, from: source, into: ct, frameRate: job.frameRate) }
                catch { throw CommandError(.io, "render: cannot insert clip \(clip.id) (\(clip.sourceIn.displaySeconds)–\(clip.sourceOut.displaySeconds)s of \(asset.name)): \(error.localizedDescription)") }
                cursor = Self.cm(clip.end)
            }
            if cursor < end { ct.insertEmptyTimeRange(CMTimeRange(start: cursor, end: end)) }
            trackIDs[track.id] = ct.trackID
        }
        if trackIDs.isEmpty {
            // Nothing is streamed (a voice-only project, or only titles and stills): one empty composition track drives
            // the compositor, which draws the background and every layer from memory (#72).
            guard let ct = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CommandError(.io, "render: cannot create a composition track")
            }
            ct.insertEmptyTimeRange(CMTimeRange(start: .zero, end: end))
        }
        let drawer = try FrameDrawer(job: job, trackIDs: trackIDs,
                                     orientations: assets.mapValues(\.orientation).merging(clipOrientations) { a, _ in a })
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = TimelineCompositor.self
        vc.renderSize = CGSize(width: job.width, height: job.height)
        vc.frameDuration = Self.frameDuration(job.frameRate)
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        vc.instructions = [TimelineInstruction(timeRange: CMTimeRange(start: .zero, end: end), trackIDs: Array(trackIDs.values), drawer: drawer)]
        let tracks = composition.tracks.filter { $0.mediaType == .video }
        return Built(composition: composition, videoComposition: vc, tracks: tracks, drawer: drawer, sources: assets.values.map(\.asset) + proxies)
    }

    /// A time in a 90 kHz scale (source times of retimed pieces are not on the frame grid).
    static func cm(seconds: Double) -> CMTime { CMTime(value: Int64((seconds * 90_000).rounded()), timescale: 90_000) }

    /// Inserts a clip's source at its start on a composition track, retimed: constant rate = one scaled range, ramp =
    /// a scaled range every two frames, freeze = one frame stretched, reverse = the proxy's range (`source`).
    /// Audio composition tracks use it too (the preview), with `step` ~0.1 s.
    static func insert(_ clip: Clip, from source: AVAssetTrack, into ct: AVMutableCompositionTrack, frameRate: Rational, step: Double? = nil) throws {
        let start = cm(clip.start)
        guard let speed = clip.speed else {
            try ct.insertTimeRange(CMTimeRange(start: cm(clip.sourceIn), end: cm(clip.sourceOut)), of: source, at: start)
            return
        }
        let span = clip.sourceDuration.seconds
        let base = speed.reverse == true ? speed.proxyStart ?? 0 : clip.sourceIn.seconds
        if speed.freeze == true {
            let frame = frameDuration(frameRate)
            try ct.insertTimeRange(CMTimeRange(start: cm(clip.sourceIn), duration: frame), of: source, at: start)
            ct.scaleTimeRange(CMTimeRange(start: start, duration: frame), toDuration: cm(clip.duration))
            return
        }
        let pieces = speed.pieces(span: span, step: step ?? 2 / frameRate.doubleValue)
        var at = start
        for piece in pieces {
            // Reversed (constant rate only): the proxy plays the range backwards from its own time 0.
            let s0 = base + piece.s0, s1 = base + piece.s1
            let src = CMTimeRange(start: cm(seconds: s0), end: cm(seconds: s1))
            guard src.duration > .zero else { continue }
            try ct.insertTimeRange(src, of: source, at: at)
            let target = (pieces.count == 1 ? cm(clip.end) : cm(seconds: clip.start.seconds + piece.t1)) - at
            ct.scaleTimeRange(CMTimeRange(start: at, duration: src.duration), toDuration: target)
            at = at + target
        }
    }

    func reader(_ b: Built, range: CMTimeRange) throws -> ReaderGate {
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: b.composition) } catch { throw CommandError(.io, "render: reader: \(error)") }
        let out = AVAssetReaderVideoCompositionOutput(videoTracks: b.tracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        out.videoComposition = b.videoComposition
        out.alwaysCopiesSampleData = false
        reader.add(out)
        reader.timeRange = range
        guard reader.startReading() else { throw CommandError(.io, "render: \(reader.error?.localizedDescription ?? "cannot start reading")") }
        return ReaderGate(reader, out, keeping: b)
    }

    /// One reader and its output, read and cancelled only through here. AVAssetReaderOutput crashes (EXC_BAD_ACCESS in
    /// FigVisualContextGetEarliestSequentialImageTime, the signal 11 of the test runner, #19) when copyNextSampleBuffer
    /// runs on a reader that was cancelled or is being cancelled, or wakes up in one; so a cancel never runs while a read
    /// is in flight. `cancel` stops new reads at once (`next` then answers nil without touching the reader) and cancels
    /// the reader right away when no read is in flight, else when that read returns, on its thread. A read that never
    /// returns (a stuck compositor, #71) keeps its reader, and what it reads from, alive instead of crashing later.
    final class ReaderGate: @unchecked Sendable {
        let reader: AVAssetReader
        private let output: AVAssetReaderOutput
        private let lock = NSLock()
        private var reading = false, cancelled = false, cancelPending = false
        /// What the reader reads from (composition, source assets, compositor drawer): alive as long as the reader.
        private let keeping: Any?

        init(_ reader: AVAssetReader, _ output: AVAssetReaderOutput, keeping: Any? = nil) {
            self.reader = reader
            self.output = output
            self.keeping = keeping
        }

        /// The next sample; nil at the end or once cancelled.
        func next() -> CMSampleBuffer? {
            lock.lock()
            guard !cancelled else { lock.unlock(); return nil }
            reading = true
            lock.unlock()
            let sample = output.copyNextSampleBuffer()
            lock.lock()
            reading = false
            let stopNow = cancelPending, stopped = cancelled
            cancelPending = false
            lock.unlock()
            if stopNow { reader.cancelReading() }
            return stopped ? nil : sample
        }

        /// Stops reading (idempotent): now when no read is in flight, else as soon as it returns.
        func cancel() {
            lock.lock()
            guard !cancelled else { lock.unlock(); return }
            cancelled = true
            let now = !reading
            if !now { cancelPending = true }
            lock.unlock()
            if now { reader.cancelReading() }
        }

        /// Whether a cancel waits for a read in flight.
        var isWaitingForARead: Bool { lock.lock(); defer { lock.unlock() }; return cancelPending }
    }

    public func export(_ job: RenderJob, audio: URL?, to output: URL, bitrate: Int) throws -> ExportReport {
        let started = Date()
        let b = try build(job)
        let video = try reader(b, range: CMTimeRange(start: .zero, end: Self.cm(job.duration)))
        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true   // moov first: faststart
        let rate = job.frameRate.doubleValue
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: job.width, AVVideoHeightKey: job.height,
            AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoH264EntropyModeKey: AVVideoH264EntropyModeCABAC,
                AVVideoExpectedSourceFrameRateKey: rate,
                AVVideoMaxKeyFrameIntervalKey: Int(rate * 2),
                AVVideoAllowFrameReorderingKey: true,
            ],
        ])
        videoIn.expectsMediaDataInRealTime = false
        writer.add(videoIn)

        var audioGate: ReaderGate?
        var audioIn: AVAssetWriterInput?
        if let audio {
            let asset = AVURLAsset(url: audio)
            guard let at = VisionFaceTracker.load({ try await asset.loadTracks(withMediaType: .audio) })?.first else {
                throw CommandError(.io, "render: unreadable mix \(audio.path)")
            }
            let r = try AVAssetReader(asset: asset)
            let o = AVAssetReaderTrackOutput(track: at, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            r.add(o)
            guard r.startReading() else { throw CommandError(.io, "render: \(r.error?.localizedDescription ?? "cannot read the mix")") }
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: job.project.settings.sampleRate, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000, AVEncoderBitRateStrategyKey: AVAudioBitRateStrategy_Constant,
            ])
            i.expectsMediaDataInRealTime = false
            writer.add(i)
            (audioGate, audioIn) = (ReaderGate(r, o, keeping: asset), i)
        }

        guard writer.startWriting() else { throw CommandError(.io, "render: \(writer.error?.localizedDescription ?? "cannot write \(output.path)")") }
        writer.startSession(atSourceTime: .zero)
        var pumps = [Pump(input: videoIn, next: video.next, label: "video", countsFrames: true)]
        if let audioIn, let audioGate { pumps.append(Pump(input: audioIn, next: audioGate.next, label: "audio", countsFrames: false)) }
        let frames: Int
        do {
            // Finishing rewrites the file with the index first (faststart): allow a second per second of video.
            frames = try Self.drive(writer, pumps, stallTimeout: stallTimeout, finishTimeout: max(stallTimeout, job.duration.seconds),
                                    frameCount: job.frameCount) {
                video.cancel()
                audioGate?.cancel()
            }
        } catch let e as CommandError {   // cancelled (the app's job): the partial file goes
            try? FileManager.default.removeItem(at: output)
            throw e
        } catch let stall as ExportStall {
            try? FileManager.default.removeItem(at: output)
            let at = Double(stall.frames) / rate
            throw CommandError(.io, "render: stopped at frame \(stall.frames) of \(job.frameCount) (\(String(format: "%.2f", at)) s): nothing moved for "
                + "\(Int(stall.waited)) s while \(stall.phase); the reader and the writer were cancelled. Run the export again; "
                + "if it stops at the same frame, that frame's layers are the cause.")
        }
        if video.reader.status == .failed { throw CommandError(.io, "render: \(video.reader.error?.localizedDescription ?? "reading failed")") }
        if audioGate?.reader.status == .failed { throw CommandError(.io, "render: mix: \(audioGate?.reader.error?.localizedDescription ?? "")") }
        guard writer.status == .completed else { throw CommandError(.io, "render: \(writer.error?.localizedDescription ?? "writing failed")") }
        return ExportReport(frames: frames, seconds: Date().timeIntervalSince(started))
    }

    /// One writer input fed from a sample source (a reader output).
    struct Pump {
        var input: AVAssetWriterInput
        var next: () -> CMSampleBuffer?
        var label: String
        var countsFrames: Bool
    }

    /// Thrown by `drive` when nothing moved for `stallTimeout` seconds.
    struct ExportStall: Error {
        var frames: Int
        /// "reading frames" or "finishing the file".
        var phase: String
        /// Seconds waited before stopping.
        var waited: TimeInterval
    }

    /// Feeds every input from its source until all are drained, then finishes the file; returns the frames written.
    /// A watchdog stops it when no input appends a sample for `stallTimeout` seconds (a reader whose
    /// copyNextSampleBuffer never returns, #71) or when finishing takes longer than `finishTimeout`: `cancelSources` cancels the
    /// readers, the writer is cancelled, and `ExportStall` is thrown. After a stop, a source call still blocked inside
    /// AVFoundation can return later: the pumps then drop its sample and never touch the cancelled writer.
    /// Inside a `CommandJob` it reports the frames written out of `frameCount` and stops (cancelled) when the job is.
    static func drive(_ writer: AVAssetWriter, _ pumps: [Pump], stallTimeout: TimeInterval, finishTimeout: TimeInterval,
                      frameCount: Int = 0, cancelSources: @escaping () -> Void) throws -> Int {
        let job = CommandJob.current
        let state = DriveState()
        let group = DispatchGroup()
        for pump in pumps {
            group.enter()
            let input = pump.input, next = pump.next, counts = pump.countsFrames
            let done = Flag()
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "regista.export.\(pump.label)")) {
                while !done.on, input.isReadyForMoreMediaData {
                    let sample = next()
                    // Appending and finishing hold the lock, so the watchdog never cancels the writer in the middle of one.
                    state.lock.lock()
                    if state.stopped { done.on = true }
                    else if let sample {
                        if input.append(sample) { state.progress(frame: counts) }
                        else { done.on = true; input.markAsFinished() }
                    } else {
                        done.on = true
                        input.markAsFinished()
                    }
                    state.lock.unlock()
                    if done.on { group.leave() }
                }
            }
        }
        func stop(_ phase: String, after waited: TimeInterval) -> ExportStall {
            // A writer call that never returns would hold the lock: then give up on cancelling the writer, still throw.
            let locked = state.lock.lock(before: Date().addingTimeInterval(5))
            state.stopped = true
            if locked { state.lock.unlock() }
            // Cancelling a reader can itself wait for the request that never finishes: cancel on another thread and
            // wait a few seconds at most. A private queue gets its own thread: blocking calls on the shared global
            // queues starve everything else that runs on them.
            let cancelled = DispatchSemaphore(value: 0)
            DispatchQueue(label: "regista.export.cancel").async {
                cancelSources()
                if locked { writer.cancelWriting() }
                cancelled.signal()
            }
            _ = cancelled.wait(timeout: .now() + 5)
            return ExportStall(frames: state.frames, phase: phase, waited: waited)
        }
        while group.wait(timeout: .now() + min(job == nil ? 1 : 0.25, stallTimeout / 4)) == .timedOut {
            if job?.isCancelled == true {
                _ = stop("cancelled", after: 0)
                throw CommandJob.cancelledError("export.render")
            }
            if frameCount > 0 { job?.report(Double(state.frames) / Double(frameCount)) }
            if state.idle > stallTimeout { throw stop("reading frames", after: stallTimeout) }
        }
        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        if finished.wait(timeout: .now() + finishTimeout) == .timedOut { throw stop("finishing the file", after: finishTimeout) }
        return state.frames
    }

    /// The pumps' shared progress and stop flag. `lock` guards the writer calls and `stopped`; the progress has its own
    /// lock so the watchdog can read it while a writer call is blocked.
    final class DriveState: @unchecked Sendable {
        let lock = NSLock()
        var stopped = false
        private let clock = NSLock()
        private var count = 0
        private var last = DispatchTime.now()
        func progress(frame: Bool) {
            clock.lock(); defer { clock.unlock() }
            if frame { count += 1 }
            last = .now()
        }
        var frames: Int { clock.lock(); defer { clock.unlock() }; return count }
        /// Seconds since the last appended sample.
        var idle: TimeInterval {
            clock.lock(); defer { clock.unlock() }
            return Double(DispatchTime.now().uptimeNanoseconds - last.uptimeNanoseconds) / 1e9
        }
    }

    final class Flag: @unchecked Sendable { var on = false }

    /// The decoded frame closest to the asked time.
    final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var pick: (CVPixelBuffer, Double)?
        func offer(_ px: CVPixelBuffer, _ d: Double) {
            lock.lock(); defer { lock.unlock() }
            if pick == nil || d < pick!.1 { pick = (px, d) }
        }
        var best: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return pick?.0 }
    }

    public func renderFrames(_ job: RenderJob, at times: [MediaTime], to outputs: [URL]) throws {
        let images = try renderImages(job, at: times)
        for (cg, url) in zip(images, outputs) { try CaptionRasterizer.writePNG(cg, to: url) }
    }

    /// Frames as images (the app's effect previews): the same reader and compositor as renderFrames.
    public func renderImages(_ job: RenderJob, at times: [MediaTime]) throws -> [CGImage] {
        let b = try build(job)
        let fd = Self.frameDuration(job.frameRate)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var images: [CGImage] = []
        for t in times {
            let start = Self.cm(t)
            let gate = try reader(b, range: CMTimeRange(start: start, duration: fd))
            // Read on another thread so a frame that never arrives (#71) fails after the stall timeout instead of hanging;
            // a private queue, so the blocking read never holds one of the shared global queues' few threads.
            let found = Found()
            let read = DispatchSemaphore(value: 0)
            DispatchQueue(label: "regista.frame.read").async {
                while let sample = gate.next() {
                    guard let px = CMSampleBufferGetImageBuffer(sample) else { continue }
                    let d = abs(CMSampleBufferGetPresentationTimeStamp(sample).seconds - t.seconds)
                    found.offer(px, d)
                }
                read.signal()
            }
            if read.wait(timeout: .now() + stallTimeout) == .timedOut {
                gate.cancel()   // when the stuck read returns, if ever
                throw CommandError(.io, "frame.render: no frame at \(t.displaySeconds)s after \(Int(stallTimeout)) s; the reader was cancelled. Try again.")
            }
            gate.cancel()
            guard let px = found.best else { throw CommandError(.io, "frame.render: no frame at \(t.displaySeconds)s") }
            let image = CIImage(cvPixelBuffer: px)
            guard let cg = b.drawer.context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: sRGB) else {
                throw CommandError(.io, "frame.render: cannot read the frame")
            }
            images.append(cg)
        }
        return images
    }

    public func captionLayout(_ job: RenderJob) throws -> [[[Double]]] {
        guard job.captions != nil else { return [] }
        let bands = try CaptionBands(job: job)
        return bands.captions.chunks.indices.map(bands.wordBoxes)
    }

    public func captionBands(_ job: RenderJob) throws -> [[Double]] {
        guard job.captions != nil else { return [] }
        let bands = try CaptionBands(job: job)
        return bands.captions.chunks.indices.map { i in
            let o = bands.origin(chunk: i), r = bands.rasterizer(chunk: i)
            return [o.x, o.y, Double(r.bandWidth), Double(r.bandHeight)]
        }
    }

    public func captionStates(_ job: RenderJob, downscale k: Int) throws -> [CaptionRaster] {
        guard let captions = job.captions else { return [] }
        let bands = try CaptionBands(job: job)
        return captions.states.map { s in
            let r = bands.rasterizer(chunk: s.chunk)
            let c = CaptionRasterizer.context(r.bandWidth, r.bandHeight)
            c.draw(r.state(captions.chunks[s.chunk], count: s.count), in: CGRect(x: 0, y: 0, width: r.bandWidth, height: r.bandHeight))
            let p = c.data!.bindMemory(to: UInt8.self, capacity: c.bytesPerRow * c.height)
            let w = r.bandWidth / k, h = r.bandHeight / k
            var luma = [UInt8](repeating: 0, count: w * h), alpha = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                for x in 0..<w {
                    var l = 0.0, a = 0.0, opaque = true
                    for dy in 0..<k {
                        for dx in 0..<k {
                            let o = (y * k + dy) * c.bytesPerRow + 4 * (x * k + dx)   // premultiplied RGBA, row 0 = top
                            l += 0.2126 * Double(p[o]) + 0.7152 * Double(p[o + 1]) + 0.0722 * Double(p[o + 2])
                            a += Double(p[o + 3])
                            opaque = opaque && p[o + 3] == 255
                        }
                    }
                    luma[y * w + x] = UInt8(min(l / Double(k * k), 255))
                    alpha[y * w + x] = opaque ? 255 : UInt8(a / Double(k * k) * 0.5)
                }
            }
            return CaptionRaster(width: w, height: h, luma: luma, alpha: alpha)
        }
    }

    public func writeCaptionImages(_ job: RenderJob, to directory: URL) throws -> [URL] {
        guard let captions = job.captions else { return [] }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bands = try CaptionBands(job: job)
        return try captions.states.enumerated().map { k, s in
            let o = bands.origin(chunk: s.chunk)
            let top = Int(o.y.rounded()), dx = Int(o.x.rounded())
            let image = bands.state(s.chunk, count: s.count)
            let frame = CaptionRasterizer.context(job.width, job.height)
            frame.draw(image, in: CGRect(x: dx, y: job.height - top - image.height, width: image.width, height: image.height))
            let url = directory.appendingPathComponent(String(format: "cap%04d.png", k))
            try CaptionRasterizer.writePNG(frame.makeImage()!, to: url)
            return url
        }
    }

    public func titleBox(_ title: Title, outputWidth: Int) throws -> (width: Double, height: Double) {
        let r = try TitleRasterizer.render(title, outputWidth: outputWidth)
        return (r.box.width, r.box.height)
    }

    public func writeLayerImage(_ job: RenderJob, clipID: String, at time: MediaTime, to url: URL) throws {
        let drawer = try FrameDrawer(job: job, trackIDs: [:], orientations: [:])
        guard var layer = job.layers(at: time).first(where: { $0.clipID == clipID }) else {
            throw CommandError(.notFound, "no layer of clip \(clipID) at \(time.displaySeconds)s")
        }
        // A split motion template as one picture: both halves.
        if case .motion(let m, let t, let d, _) = layer.source { layer.source = .motion(m, time: t, duration: d, part: .whole) }
        guard let image = drawer.picture(layer, source: { _ in nil }) else { throw CommandError(.io, "cannot draw clip \(clipID)") }
        let canvas = CGRect(x: 0, y: 0, width: job.width, height: job.height)
        let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        guard let cg = ctx.createCGImage(image.cropped(to: canvas), from: canvas, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else {
            throw CommandError(.io, "cannot draw clip \(clipID)")
        }
        try CaptionRasterizer.writePNG(cg, to: url)
    }

    /// The box of one layer's visible pixels at `time` (alpha above 2 %), measured on a quarter-size drawing.
    public func layerBox(_ job: RenderJob, clipID: String, at time: MediaTime) throws -> [Double]? {
        let drawer = try FrameDrawer(job: job, trackIDs: [:], orientations: [:])
        guard var layer = job.layers(at: time).first(where: { $0.clipID == clipID }) else { return nil }
        if case .motion(let m, let t, let d, _) = layer.source { layer.source = .motion(m, time: t, duration: d, part: .whole) }
        guard let image = drawer.picture(layer, source: { _ in nil }) else { return nil }
        let k = 0.25
        let w = max(Int((Double(job.width) * k).rounded()), 1), h = max(Int((Double(job.height) * k).rounded()), 1)
        let small = image.cropped(to: CGRect(x: 0, y: 0, width: job.width, height: job.height)).transformed(by: CGAffineTransform(scaleX: k, y: k))
        let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        guard let cg = ci.createCGImage(small.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!),
              let bitmap = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { bitmap.draw(cg, in: rect); return bitmap.data }() else { return nil }
        // A bitmap context's memory starts with the top row.
        let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h {
            for x in 0..<w where pixels[(y * w + x) * 4 + 3] > 5 {
                x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
            }
        }
        guard x1 >= x0 else { return nil }
        let top = Double(y0), bottom = Double(y1 + 1)
        return [Double(x0) / k, top / k, Double(x1 - x0 + 1) / k, (bottom - top) / k]
    }

}

extension EngineServices {
    /// The standard process engines plus Apple Vision, the AVFoundation compositor and the Core Graphics image
    /// toolkit: what regista-engine and regista-mcp use.
    public static func live(library: MediaLibrary = MediaLibrary()) -> EngineServices {
        MotionLibrary.registerAll()
        var s = EngineServices.standard(faces: VisionFaceTracker(), renderer: AVRenderer(), images: CGImageToolkit(), library: library)
        s.segmenter = VisionPersonSegmenter()
        s.hands = VisionHandTracker()
        s.screenSynth = CGScreenSynthesizer()
        s.speech = AppleSpeechStreamer()
        return s
    }
}
