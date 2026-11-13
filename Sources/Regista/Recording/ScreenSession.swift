import AVFoundation
import CoreGraphics
import Foundation
import RegistaCore
import ScreenCaptureKit

/// One AVAssetWriter fed with retimed sample buffers: created on the first sample (size and audio format come from
/// it), its session starts at that sample, so the file's local time 0 sits at `firstTime` on the host clock.
final class TrackWriter: @unchecked Sendable {
    enum Kind { case screen, camera, audio }
    let url: URL
    let kind: Kind
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let lock = NSLock()
    /// Host-clock seconds (pauses removed) of the first sample written.
    private(set) var firstTime: Double?
    private(set) var size: (Int, Int)?
    private(set) var sampleRate: Int?
    private(set) var channels: Int?
    private(set) var failure: String?

    init(url: URL, kind: Kind) {
        self.url = url
        self.kind = kind
    }

    /// Appends `buffer` shifted `shift` seconds earlier (the pauses so far).
    func append(_ buffer: CMSampleBuffer, shift: Double) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, CMSampleBufferDataIsReady(buffer) else { return }
        guard let retimed = Self.retime(buffer, by: shift) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(retimed)
        if writer == nil {
            do { try open(with: retimed) } catch { failure = error.localizedDescription; return }
            writer!.startSession(atSourceTime: pts)
            firstTime = pts.seconds
        }
        guard let input, input.isReadyForMoreMediaData else { return }   // real time: drop rather than block
        if !input.append(retimed) { failure = writer?.error?.localizedDescription ?? "append failed" }   // l10n-ignore
    }

    private func open(with sample: CMSampleBuffer) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = CMSampleBufferGetFormatDescription(sample) else { throw RegistaError(loc("formato sconosciuto")) }
        let w: AVAssetWriter
        let i: AVAssetWriterInput
        switch kind {
        case .screen, .camera:
            let d = CMVideoFormatDescriptionGetDimensions(format)
            let (width, height) = (Int(d.width) / 2 * 2, Int(d.height) / 2 * 2)
            size = (width, height)
            let fps = kind == .screen ? 60 : 30
            // H.264 stops at 4096 px wide: bigger displays (5K, 6K) go to HEVC.
            let codec: AVVideoCodecType = width > 4096 || height > 4096 ? .hevc : .h264
            w = try AVAssetWriter(outputURL: url, fileType: .mov)
            i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(width * height * fps / (kind == .screen ? 10 : 6), 4_000_000),
                                                  AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2],
            ])
        case .audio:
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
            let rate = Int(asbd?.mSampleRate ?? 48000), ch = Int(asbd?.mChannelsPerFrame ?? 1)
            sampleRate = rate
            channels = ch
            w = try AVAssetWriter(outputURL: url, fileType: .wav)
            i = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: ch, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
        }
        i.expectsMediaDataInRealTime = true
        guard w.canAdd(i) else { throw RegistaError(loc("impossibile scrivere %@", url.lastPathComponent)) }
        w.add(i)
        guard w.startWriting() else { throw w.error ?? RegistaError(loc("impossibile scrivere %@", url.lastPathComponent)) }
        writer = w
        input = i
    }

    /// Finishes the file; false when nothing was written.
    func finish() async -> Bool {
        let (w, i): (AVAssetWriter?, AVAssetWriterInput?) = lock.withLock { (writer, input) }
        guard let w, let i else { return false }
        i.markAsFinished()
        await w.finishWriting()
        return w.status == .completed
    }

    static func retime(_ buffer: CMSampleBuffer, by shift: Double) -> CMSampleBuffer? {
        guard shift > 0 else { return buffer }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        let delta = CMTime(seconds: shift, preferredTimescale: 1_000_000_000)
        for k in timing.indices {
            if timing[k].presentationTimeStamp.isValid { timing[k].presentationTimeStamp = timing[k].presentationTimeStamp - delta }
            if timing[k].decodeTimeStamp.isValid { timing[k].decodeTimeStamp = timing[k].decodeTimeStamp - delta }
        }
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}

/// What the screen recorder captures: a whole display, one window, or an area of a display (points, display-local,
/// top-left origin).
enum ScreenTarget: Hashable, Codable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
    case area(CGDirectDisplayID, CGRect)
}

/// A screen recording session: ScreenCaptureKit for the screen (cursor drawn unless hidden for the compositor's drawn
/// cursor, issue #42; Regista's own windows — the
/// teleprompter included — left out, system audio optional), the camera and the mic from the app's capture
/// session, each into its own file, all on the host clock; clicks, keys and cursor positions on the same clock;
/// pause/resume; session.json at the end. The stream also runs before recording, for the live preview.
final class ScreenSession: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let folder: URL
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "regista.screen")   // l10n-ignore
    private let lock = NSLock()
    private var screenWriter: TrackWriter, cameraWriter: TrackWriter, micWriter: TrackWriter, systemWriter: TrackWriter
    private var recording = false
    private var paused = false
    private var pauseStarted = 0.0
    private var pausedTotal = 0.0
    private var pauses: [RecordingSession.Pause] = []
    /// Host-clock seconds when recording started.
    private var t0 = 0.0
    private var events: [RecordingSession.Event] = []
    private var cursor: [RecordingSession.CursorSample] = []
    private var layout: LayoutSpec
    private var layoutChanges: [RecordingSession.LayoutChange] = []
    /// Captured rectangle in global points (top-left origin) and pixels per point.
    private(set) var region = CGRect.zero
    private(set) var scale = 2.0
    private(set) var targetName = ""
    let systemAudio: Bool
    /// The system cursor is captured in screen.mov (false: hidden, the compositor draws it from the log).
    let cursorInVideo: Bool
    var cameraName: String?
    var micName: String?
    /// Latest screen frame for the preview (called on the screen queue).
    var onPreviewFrame: ((IOSurface) -> Void)?
    var onStreamError: ((String) -> Void)?

    init(folder: URL, layout: LayoutSpec, systemAudio: Bool, cursorInVideo: Bool) {
        self.folder = folder
        self.layout = layout
        self.systemAudio = systemAudio
        self.cursorInVideo = cursorInVideo
        screenWriter = TrackWriter(url: folder.appendingPathComponent("screen.mov"), kind: .screen)
        cameraWriter = TrackWriter(url: folder.appendingPathComponent("camera.mov"), kind: .camera)
        micWriter = TrackWriter(url: folder.appendingPathComponent("mic.wav"), kind: .audio)
        systemWriter = TrackWriter(url: folder.appendingPathComponent("system.wav"), kind: .audio)
    }

    static var hostNow: Double { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

    /// Starts the ScreenCaptureKit stream on `target` (throws with an Italian explanation when screen recording is
    /// not allowed).
    func start(target: ScreenTarget) async throws {
        let content: SCShareableContent
        do { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw RegistaError(Self.permissionHint) }
        // Our own windows (editor, teleprompter, area picker) never end up in the recording.
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        switch target {
        case .display(let id), .area(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                throw RegistaError(loc("Nessuno schermo da registrare."))
            }
            filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let bounds = CGDisplayBounds(display.displayID)
            let mode = CGDisplayCopyDisplayMode(display.displayID)
            scale = Double(mode?.pixelWidth ?? Int(bounds.width * 2)) / max(Double(bounds.width), 1)
            if case .area(_, let rect) = target {
                config.sourceRect = rect
                region = CGRect(x: bounds.minX + rect.minX, y: bounds.minY + rect.minY, width: rect.width, height: rect.height)
                targetName = loc("Area di %@×%@", String(display.width), String(display.height))
            } else {
                region = bounds
                targetName = loc("Schermo %@×%@", String(display.width), String(display.height))
            }
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RegistaError(loc("La finestra scelta non è più aperta.")) }
            filter = SCContentFilter(desktopIndependentWindow: window)
            region = window.frame
            scale = Double(filter.pointPixelScale)
            targetName = loc("Finestra: %@", [window.owningApplication?.applicationName, window.title].compactMap { $0 }.joined(separator: " "))
                .trimmingCharacters(in: .whitespaces)
        }
        config.width = Int(region.width * scale) / 2 * 2
        config.height = Int(region.height * scale) / 2 * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = cursorInVideo
        config.queueDepth = 8
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if systemAudio { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        do { try await s.startCapture() } catch { throw RegistaError(Self.permissionHint + " (" + error.localizedDescription + ")") }
        stream = s
    }

    static var permissionHint: String { loc("Consenti a Regista di registrare lo schermo: Impostazioni di Sistema → Privacy e sicurezza → Registrazione schermo e audio di sistema → attiva Regista, poi chiudi e riapri Regista.") }

    func stopStream() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    // MARK: Recording

    func beginRecording() {
        lock.withLock {
            t0 = Self.hostNow
            recording = true
            paused = false
            pausedTotal = 0
        }
    }

    var isPaused: Bool { lock.withLock { paused } }

    func pause() {
        lock.withLock {
            guard recording, !paused else { return }
            paused = true
            pauseStarted = Self.hostNow
        }
    }

    func resume() {
        lock.withLock {
            guard recording, paused else { return }
            let d = Self.hostNow - pauseStarted
            pauses.append(RecordingSession.Pause(at: pauseStarted - t0 - pausedTotal, duration: d))
            pausedTotal += d
            paused = false
        }
    }

    /// Session time of a host-clock instant, nil while paused or not recording.
    private func sessionTime(_ host: Double) -> Double? {
        guard recording, !paused else { return nil }
        return host - t0 - pausedTotal
    }

    /// Screen pixels of a global point (top-left origin).
    private func pixels(_ p: CGPoint) -> (Double, Double) {
        ((p.x - region.minX) * scale, (p.y - region.minY) * scale)
    }

    func click(kind: String, at p: CGPoint, host: Double) {
        lock.withLock {
            guard let t = sessionTime(host), region.contains(p) else { return }
            let (x, y) = pixels(p)
            events.append(RecordingSession.Event(kind: kind, t: t, x: x.rounded(), y: y.rounded()))
        }
    }

    /// Left button released (anywhere: a drag may end outside the captured area).
    func mouseUp(at p: CGPoint, host: Double) {
        lock.withLock {
            guard let t = sessionTime(host) else { return }
            let (x, y) = pixels(p)
            events.append(RecordingSession.Event(kind: "mouseUp", t: t, x: x.rounded(), y: y.rounded()))
        }
    }

    func key(_ text: String, host: Double) {
        lock.withLock {
            guard let t = sessionTime(host) else { return }
            events.append(RecordingSession.Event(kind: "key", t: t, key: text))
        }
    }

    /// A cursor sample: position, shape (nil = arrow) and left button held.
    func cursorMoved(to p: CGPoint, kind: CursorKind, down: Bool, host: Double) {
        lock.withLock {
            guard let t = sessionTime(host) else { return }
            let (x, y) = pixels(p)
            cursor.append(RecordingSession.CursorSample(t: (t * 1000).rounded() / 1000, x: (x * 10).rounded() / 10, y: (y * 10).rounded() / 10,
                                                        kind: kind == .arrow ? nil : kind.rawValue, down: down ? true : nil))
        }
    }

    func setLayout(_ spec: LayoutSpec) {
        lock.withLock {
            if recording, let t = sessionTime(Self.hostNow) { layoutChanges.append(RecordingSession.LayoutChange(t: t, layout: spec)) } else { layout = spec }
        }
    }

    /// Writes a camera or mic buffer (captured on `clock`, the capture session's clock).
    func capture(_ buffer: CMSampleBuffer, camera: Bool, clock: CMClock?) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        let host = clock.map { CMSyncConvertTime(pts, from: $0, to: CMClockGetHostTimeClock()) } ?? pts
        let shift: Double? = lock.withLock { recording && !paused ? pausedTotal : nil }
        guard let shift else { return }
        var b = buffer
        if host != pts, let moved = TrackWriter.retime(buffer, by: (pts - host).seconds) { b = moved }
        (camera ? cameraWriter : micWriter).append(b, shift: shift)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard buffer.isValid else { return }
        switch type {
        case .screen:
            guard let info = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if let pixels = CMSampleBufferGetImageBuffer(buffer), let ref = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() {
                onPreviewFrame?(unsafeBitCast(ref, to: IOSurface.self))
            }
            let shift: Double? = lock.withLock { recording && !paused ? pausedTotal : nil }
            if let shift { screenWriter.append(buffer, shift: shift) }
        case .audio:
            let shift: Double? = lock.withLock { recording && !paused ? pausedTotal : nil }
            if let shift { systemWriter.append(buffer, shift: shift) }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(loc("La registrazione dello schermo si è interrotta: %@", error.localizedDescription))
    }

    // MARK: Stop

    /// Stops recording, finishes the files and writes session.json. Returns its URL.
    func finish() async throws -> URL {
        let end = Self.hostNow
        lock.withLock {
            if paused { pausedTotal += end - pauseStarted; paused = false }
            recording = false
        }
        await stopStream()
        var sources: [RecordingSession.Source] = []
        for (id, w) in [("screen", screenWriter), ("camera", cameraWriter), ("mic", micWriter), ("system", systemWriter)] {
            guard await w.finish(), let first = w.firstTime else { continue }
            var s = RecordingSession.Source(id: id, file: w.url.lastPathComponent, offset: ((first - t0) * 1_000_000).rounded() / 1_000_000)
            switch id {
            case "screen":
                s.device = targetName; s.width = w.size?.0; s.height = w.size?.1; s.fps = 60
                s.region = [region.minX, region.minY, region.width, region.height]; s.scale = scale
            case "camera":
                s.device = cameraName; s.width = w.size?.0; s.height = w.size?.1; s.fps = 30
            default:
                s.device = id == "mic" ? micName : loc("Audio di sistema"); s.sampleRate = w.sampleRate; s.channels = w.channels
            }
            sources.append(s)
        }
        if let f = [screenWriter, cameraWriter, micWriter, systemWriter].compactMap(\.failure).first, sources.isEmpty {
            throw RegistaError(loc("Registrazione non riuscita: %@", f))
        }
        guard !sources.isEmpty else { throw RegistaError(loc("Nessun file registrato: controlla i permessi di schermo, camera e microfono.")) }
        let duration = end - t0 - pausedTotal
        var session = lock.withLock {
            RecordingSession(app: "Regista \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")",   // l10n-ignore
                             created: ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -(end - t0))),
                             duration: (duration * 1000).rounded() / 1000, sources: sources, events: events)
        }
        lock.withLock {
            session.cursor = cursor
            session.cursorInVideo = cursorInVideo
            session.pauses = pauses.isEmpty ? nil : pauses
            session.layout = layout
            session.layoutChanges = layoutChanges.isEmpty ? nil : layoutChanges
        }
        let url = folder.appendingPathComponent(RecordingSession.fileName)
        try session.write(to: url)
        return url
    }
}
