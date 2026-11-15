import AVFoundation
import RegistaCore
import RegistaEngines
import ScreenCaptureKit

/// Everything the recorder asks of macOS and of the capture devices (#35): permissions and their prompts, the devices,
/// the capture session that opens them, the movie file, the screen's shareable content and on-device speech for the
/// teleprompter. The app's recorder uses the Mac's (`MacCapture`); a test gives one that opens nothing.
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
    /// The displays and windows that can be recorded.
    func shareableContent() async throws -> (displays: [SCDisplay], windows: [SCWindow])
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

    func shareableContent() async throws -> (displays: [SCDisplay], windows: [SCWindow]) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return (content.displays, content.windows)
    }

    func listen(locale: Locale, contextualStrings: [String], emit: @escaping @Sendable (SpeechHypothesis) -> Void) async throws -> LiveSpeechSession {
        let s = LiveSpeechSession(locale: locale, contextualStrings: contextualStrings, onUpdate: emit)
        try await s.start()
        return s
    }
}
