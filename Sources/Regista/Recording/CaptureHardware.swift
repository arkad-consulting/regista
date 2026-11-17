import AVFoundation
import RegistaCore
import RegistaEngines
import ScreenCaptureKit

/// Everything the recorder asks of macOS and of the capture devices (#35): permissions and their prompts, the devices,
/// the capture session that opens them, the movie file, the screen's shareable content and on-device speech for the
/// teleprompter, and the screen recording session. The app's recorder uses the Mac's (`MacCapture`); a test gives one
/// that opens nothing.
@MainActor
protocol CaptureHardware: AnyObject {
    /// macOS's decision for the camera or the microphone, without asking.
    func permission(_ type: AVMediaType) -> CapturePermission
    /// Asks macOS for the camera or the microphone (its prompt when undecided).
    func requestAccess(_ type: AVMediaType) async
    /// Screen recording is allowed for this process (never asks).
    func screenAllowed() -> Bool
    /// Asks macOS for screen recording (its prompt, or a new entry in System Settings).
    func requestScreen()
    /// The connected cameras or microphones.
    func devices(_ type: AVMediaType) -> [AVCaptureDevice]
    /// Runs the capture session's setup, which opens the chosen devices.
    func openDevices(_ setup: @escaping @Sendable () -> Void)
    /// Starts writing a movie-file take; `delegate` hears when it ends.
    func startMovie(_ output: AVCaptureMovieFileOutput, to url: URL, delegate: AVCaptureFileOutputRecordingDelegate)
    /// Ends the movie-file take (its delegate is told).
    func stopMovie(_ output: AVCaptureMovieFileOutput)
    /// Pauses / resumes the movie-file take: nothing is written meanwhile, and the file goes on with no gap (#19).
    func pauseMovie(_ output: AVCaptureMovieFileOutput)
    func resumeMovie(_ output: AVCaptureMovieFileOutput)
    /// The displays and windows that can be recorded.
    func shareableContent() async throws -> (displays: [CGDirectDisplayID], windows: [SCWindow])
    /// The connected displays as macOS arranges them (no permission needed): the map of Registra's Schermo row.
    func connectedDisplays() -> [DisplayInfo]
    /// Outlines a display on its own screen for a moment, so the person sees which one a tile is (#50).
    func outline(_ display: DisplayInfo)
    /// The session that records the screen (and the camera and microphone beside it) into `folder`.
    func screenSession(folder: URL, layout: LayoutSpec, systemAudio: Bool, cursorInVideo: Bool) -> ScreenRecording
    /// Starts on-device speech recognition for the teleprompter (it hears the microphone buffers the recorder gives it).
    func listen(locale: Locale, contextualStrings: [String], emit: @escaping @Sendable (SpeechHypothesis) -> Void) async throws -> LiveSpeechSession
}

/// The Mac's capture hardware.
@MainActor
final class MacCapture: CaptureHardware {
    private let queue: DispatchQueue

    init(queue: DispatchQueue = DispatchQueue(label: "regista.capture")) {   // l10n-ignore
        self.queue = queue
    }

    func permission(_ type: AVMediaType) -> CapturePermission {
        switch AVCaptureDevice.authorizationStatus(for: type) {
        case .authorized: .granted
        case .notDetermined: .undetermined
        default: .denied
        }
    }

    func requestAccess(_ type: AVMediaType) async { _ = await AVCaptureDevice.requestAccess(for: type) }

    func screenAllowed() -> Bool { CGPreflightScreenCaptureAccess() }

    func connectedDisplays() -> [DisplayInfo] { DisplayInfo.connected() }

    func outline(_ display: DisplayInfo) { ScreenOutline.flash(display) }

    func requestScreen() { CGRequestScreenCaptureAccess() }

    func devices(_ type: AVMediaType) -> [AVCaptureDevice] {
        let kinds: [AVCaptureDevice.DeviceType] = type == .video ? [.builtInWideAngleCamera, .external, .continuityCamera] : [.microphone, .external]
        return AVCaptureDevice.DiscoverySession(deviceTypes: kinds, mediaType: type, position: .unspecified).devices
    }

    func openDevices(_ setup: @escaping @Sendable () -> Void) { queue.async(execute: setup) }

    func startMovie(_ output: AVCaptureMovieFileOutput, to url: URL, delegate: AVCaptureFileOutputRecordingDelegate) {
        nonisolated(unsafe) let delegate = delegate
        queue.async { output.startRecording(to: url, recordingDelegate: delegate) }
    }

    func stopMovie(_ output: AVCaptureMovieFileOutput) { queue.async { output.stopRecording() } }

    // AVCaptureFileOutput's own pause: no sample is written while paused, the next ones follow the last ones with no gap
    // in the file's timestamps (picture and sound alike, so they stay in sync).
    func pauseMovie(_ output: AVCaptureMovieFileOutput) { queue.async { output.pauseRecording() } }

    func resumeMovie(_ output: AVCaptureMovieFileOutput) { queue.async { output.resumeRecording() } }

    func shareableContent() async throws -> (displays: [CGDirectDisplayID], windows: [SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return (content.displays.map(\.displayID), content.windows)
    }

    func screenSession(folder: URL, layout: LayoutSpec, systemAudio: Bool, cursorInVideo: Bool) -> ScreenRecording {
        ScreenSession(folder: folder, layout: layout, systemAudio: systemAudio, cursorInVideo: cursorInVideo)
    }

    func listen(locale: Locale, contextualStrings: [String], emit: @escaping @Sendable (SpeechHypothesis) -> Void) async throws -> LiveSpeechSession {
        let s = LiveSpeechSession(locale: locale, contextualStrings: contextualStrings, onUpdate: emit)
        try await s.start()
        return s
    }
}

/// A screen recording session as the recorder drives it (`ScreenSession` on the Mac): the preview stream, the take with
/// its pauses, the clicks, keys and cursor on the session clock, the camera and microphone buffers, and session.json at
/// the end.
protocol ScreenRecording: AnyObject, Sendable {
    var folder: URL { get }
    var cameraName: String? { get set }
    var micName: String? { get set }
    var onPreviewFrame: ((IOSurface) -> Void)? { get set }
    var onStreamError: ((String) -> Void)? { get set }
    func start(target: ScreenTarget) async throws
    func stopStream() async
    func beginRecording()
    func pause()
    func resume()
    func click(kind: String, at p: CGPoint, host: Double)
    func mouseUp(at p: CGPoint, host: Double)
    func key(_ text: String, host: Double)
    func cursorMoved(to p: CGPoint, kind: CursorKind, down: Bool, host: Double)
    func setLayout(_ spec: LayoutSpec)
    func capture(_ buffer: CMSampleBuffer, camera: Bool, clock: CMClock?)
    /// Stops recording, finishes the files and writes session.json; returns its URL.
    func finish() async throws -> URL
}

extension ScreenSession: ScreenRecording {}
