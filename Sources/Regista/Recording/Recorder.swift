import AVFoundation
import RegistaCore
import RegistaEngines
import ScreenCaptureKit
import SwiftUI
import Vision

/// Registrazione: screen, camera, microphone (also an iPhone as Continuity Camera), the Mac's sound and the teleprompter,
/// each with its own switch (`sources`, issue #50). Without the screen: one movie file (camera and/or microphone; the
/// auto-edit flow). With the screen on: a session folder of separate synced files (screen.mov, camera.mov, mic.wav,
/// system.wav) plus session.json (ScreenSession), imported with recording.import.
@MainActor
final class Recorder: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "regista.capture")   // l10n-ignore
    /// The Mac's permissions and devices, or a test's stand-in that opens nothing (#35).
    let hardware: CaptureHardware
    /// Live microphone buffers (the teleprompter listens here while recording).
    let audioTap = AudioTap()
    /// The teleprompter's speech recognizer: gets every microphone buffer while the capture session runs, in camera-only
    /// and screen recordings alike (the same buffers the session's mic.wav is written from).
    var speechSink: SpeechAudioSink? {
        get { audioTap.sink }
        set { audioTap.sink = newValue }
    }
    private let cameraTap = CameraTap()
    /// The microphone level (its own object: twenty updates a second do not redraw the whole screen).
    let level = MicLevel()
    private let defaults: UserDefaults
    /// Whether macOS was already asked for the screen, for this code signature (issue #67).
    private let screenAsk: ScreenAskMemory

    @Published private(set) var cameras: [AVCaptureDevice] = []
    @Published private(set) var microphones: [AVCaptureDevice] = []
    /// Every choice of the Registra screen; saved on each change.
    @Published var sources: RecordingSources {
        didSet { sourcesChanged(from: oldValue) }
    }
    @Published private(set) var cameraPermission = CapturePermission.undetermined
    @Published private(set) var microphonePermission = CapturePermission.undetermined
    @Published private(set) var screenPermission = CapturePermission.undetermined
    /// Regista asked macOS for the screen in this session: the row says to allow it, then reopen.
    @Published private(set) var screenPromptShown = false
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    /// Whether the teleprompter ran with the current (or last) take: only then is its text the take's script.
    private(set) var promptedTake = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var errorMessage: String?

    @Published private(set) var displays: [CGDirectDisplayID] = []
    @Published private(set) var windows: [SCWindow] = []
    /// What the live preview draws, observed on its own (#162): the screen's frames (thirty to sixty a second) and the
    /// face's place (four a second) were published here, and each one drew every view of the recorder again — the
    /// Registra screen and the menu bar — and each drawing asked the capture system for its devices.
    let previewFeed = PreviewFeed()
    /// Latest screen frame for the live preview.
    private(set) var screenFrame: IOSurface? {
        get { previewFeed.surface }
        set { if previewFeed.surface !== newValue { previewFeed.surface = newValue } }
    }
    /// Where the face is across the camera preview (0…1, as the preview shows it), while the format guide follows it
    /// (#153); nil when no face is seen or nobody asks.
    private(set) var faceX: Double? {
        get { previewFeed.faceX }
        set { if previewFeed.faceX != newValue { previewFeed.faceX = newValue } }
    }
    /// The system's default camera and microphone, read when the devices are listed (#162), never while drawing:
    /// AVCaptureDevice.default waits on the capture system, which is busy while a session starts.
    private var defaultCameraID: String?
    private var defaultMicrophoneID: String?

    /// The format guide on the camera preview follows the face (#153): a few face detections a second on the camera's
    /// frames (Apple Vision, on this Mac), only while it is on.
    func followFace(_ on: Bool) {
        guard on else {
            cameraTap.onFace = nil
            if faceX != nil { faceX = nil }
            return
        }
        guard cameraTap.onFace == nil else { return }
        let session = session
        cameraTap.onFace = { [weak self] x in
            // The preview shows the picture mirrored when its connection says so.
            let mirrored = session.connections.first { $0.videoPreviewLayer != nil }?.isVideoMirrored ?? false
            let shown = x.map { mirrored ? 1 - $0 : $0 }
            DispatchQueue.main.async { MainActor.assumeIsolated { if self?.faceX != shown { self?.faceX = shown } } }
        }
    }

    var onFinished: ((URL) -> Void)?
    /// Takes the next finished movie-file take instead of `onFinished` (the voice recording flow keeps its takes out
    /// of the edit), then clears itself.
    var nextTakeHandler: ((URL) -> Void)?
    /// session.json of a finished screen recording.
    var onSessionFinished: ((URL) -> Void)?
    private var startDate: Date?
    private var pausedSeconds: TimeInterval = 0
    private var pauseDate: Date?
    private var clock: Timer?
    private var screen: ScreenRecording?
    /// The take in progress records the screen (a session folder) rather than one movie file.
    private var recordingScreen = false
    private var monitors: [Any] = []
    /// didBecomeActive: the silent permission re-check (issue #67).
    private var activeObserver: Any?
    private var cursorTimer: Timer?
    private let cursorKind = CursorKindProbe()

    /// `hardware`: the Mac's capture hardware (a test gives a stand-in).
    init(defaults: UserDefaults = .standard, hardware: CaptureHardware? = nil) {
        self.defaults = defaults
        self.hardware = hardware ?? MacCapture(queue: queue)
        screenAsk = ScreenAskMemory(defaults: defaults, signature: CodeSignature.current)
        screenAsk.migrate()
        sources = RecordingSources.load(from: defaults)
        super.init()
        audioTap.onLevel = { [weak level] peak in
            Task { @MainActor in level?.push(peak) }
        }
        refreshPermissions()
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appBecameActive() }
        }
    }

    // MARK: Devices

    /// The camera in use: the one picked last while it is connected, else the system default (nil when off).
    var cameraDevice: AVCaptureDevice? {
        guard sources.camera, cameraPermission != .denied else { return nil }
        let id = RecordingSources.device(remembered: sources.cameraID, available: cameras.map(\.uniqueID),
                                         systemDefault: defaultCameraID)
        return cameras.first { $0.uniqueID == id }
    }

    var microphoneDevice: AVCaptureDevice? {
        guard sources.microphone, microphonePermission != .denied else { return nil }
        let id = RecordingSources.device(remembered: sources.microphoneID, available: microphones.map(\.uniqueID),
                                         systemDefault: defaultMicrophoneID)
        return microphones.first { $0.uniqueID == id }
    }

    var hasCamera: Bool { cameraDevice != nil }
    var hasMicrophone: Bool { microphoneDevice != nil }
    /// Without a camera the screen fills the frame whatever face layout was picked.
    var effectiveLayout: LayoutSpec { hasCamera ? sources.layout : LayoutSpec(kind: .screen) }
    /// Keystrokes are logged only with the Accessibility permission (clicks always are).
    var logsKeys: Bool { AXIsProcessTrusted() }

    /// The camera / microphone `sources` points at (the remembered one, else the default), on or off.
    func deviceID(_ source: RecordingSources.Source, in sources: RecordingSources) -> String? {
        switch source {
        case .camera:
            RecordingSources.device(remembered: sources.cameraID, available: cameras.map(\.uniqueID),
                                    systemDefault: defaultCameraID)
        case .microphone:
            RecordingSources.device(remembered: sources.microphoneID, available: microphones.map(\.uniqueID),
                                    systemDefault: defaultMicrophoneID)
        default: nil
        }
    }

    /// The camera / microphone names (the remembered device even while the source is off).
    func deviceName(_ source: RecordingSources.Source) -> String? {
        switch source {
        case .camera:
            let id = RecordingSources.device(remembered: sources.cameraID, available: cameras.map(\.uniqueID),
                                             systemDefault: defaultCameraID)
            return cameras.first { $0.uniqueID == id }?.localizedName
        case .microphone:
            let id = RecordingSources.device(remembered: sources.microphoneID, available: microphones.map(\.uniqueID),
                                             systemDefault: defaultMicrophoneID)
            return microphones.first { $0.uniqueID == id }?.localizedName
        default: return nil
        }
    }

    /// The connected displays (the hardware's: macOS's, or the test rig's).
    func connectedDisplays() -> [DisplayInfo] { hardware.connectedDisplays() }

    /// Outlines a display on its own screen for a moment (#50).
    func outline(_ display: DisplayInfo) { hardware.outline(display) }

    /// "Built-in Retina Display · 1512×982 · schermo principale", "Finestra: Safari — Apple", "Area 800×600".
    func targetName(_ target: ScreenTarget?) -> String? {
        switch target {
        case .display(let id):
            // The display by its name, size and role, as the row's line names it (#52).
            if let d = hardware.connectedDisplays().first(where: { $0.id == id }) { return d.line }
            let b = CGDisplayBounds(id)
            return String(format: loc("Schermo intero %d×%d"), Int(b.width), Int(b.height))
        case .window(let id):
            guard let w = windows.first(where: { $0.windowID == id }) else { return loc("Finestra") }
            return [w.owningApplication?.applicationName, w.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
        case .area(_, let r):
            return String(format: loc("Area %d×%d"), Int(r.width), Int(r.height))
        case nil:
            return nil
        }
    }

    /// The facts the source rows are drawn from.
    func environment(prompterSummary: String = "") -> RecordingEnvironment {
        RecordingEnvironment(cameraName: deviceName(.camera), microphoneName: deviceName(.microphone),
                             targetName: targetName(sources.target ?? RecordingSources.resolve(nil, displays: [CGMainDisplayID()], windows: [], main: CGMainDisplayID())),
                             camera: cameraPermission, microphone: microphonePermission, screen: screenPermission,
                             prompterSummary: prompterSummary)
    }

    /// Why the Record button is disabled (localized), nil when a take can start.
    var blockReason: String? {
        if let r = sources.blockReason(environment(), lookup: loc) { return r }
        if !sources.screen, !hasCamera, !hasMicrophone { return loc("Nessuna camera o microfono collegato") }
        return nil
    }

    func refreshPermissions() {
        cameraPermission = hardware.permission(.video)
        microphonePermission = hardware.permission(.audio)
        screenPermission = hardware.screenAllowed() ? .granted : (screenAsk.askedForThisSignature ? .denied : .undetermined)
    }

    func prepare() async {
        guard !isReady else { return }
        // Ask only for what is switched on: a screen-only take never asks for the camera.
        if sources.camera, hardware.permission(.video) == .undetermined { await hardware.requestAccess(.video) }
        if sources.microphone, hardware.permission(.audio) == .undetermined { await hardware.requestAccess(.audio) }
        refreshPermissions()
        refreshDevices()
        isReady = true
        configure()
        if sources.screen { await refreshScreen() }
    }

    func refreshDevices() {
        cameras = hardware.devices(.video)
        microphones = hardware.devices(.audio)
        defaultCameraID = hardware.defaultDevice(.video)
        defaultMicrophoneID = hardware.defaultDevice(.audio)
        refreshPermissions()
        configure()
    }

    /// Opens the System Settings pane where `source` is allowed.
    func openSettings(for source: RecordingSources.Source) {
        if let url = CapturePermission.settingsURL(source) { NSWorkspace.shared.open(url) }
    }

    private func sourcesChanged(from old: RecordingSources) {
        guard sources != old else { return }
        sources.save(to: defaults)
        let cameraChanged = old.camera != sources.camera || old.cameraID != sources.cameraID
        let micChanged = old.microphone != sources.microphone || old.microphoneID != sources.microphoneID
        if cameraChanged || micChanged {
            if isReady {
                Task {
                    // Turned on for the first time: macOS asks now, not at launch.
                    if sources.camera, hardware.permission(.video) == .undetermined { await hardware.requestAccess(.video) }
                    if sources.microphone, hardware.permission(.audio) == .undetermined { await hardware.requestAccess(.audio) }
                    refreshPermissions()
                    configure()
                }
            }
        }
        if cameraChanged || old.layout != sources.layout { screen?.setLayout(effectiveLayout) }
        if old.screen != sources.screen {
            if isReady || !sources.screen { Task { await refreshScreen() } }
        } else if old.target != sources.target || old.systemAudio != sources.systemAudio || old.hideCursor != sources.hideCursor {
            Task { await restartPreview() }
        }
    }

    private func configure() {
        guard isReady, !isRecording else { return }
        let cam = cameraDevice
        let mic = microphoneDevice
        if mic == nil { level.reset() }
        let session = self.session
        let output = self.output
        let audioOutput = self.audioOutput
        let videoOutput = self.videoOutput
        let audioTap = self.audioTap
        let cameraTap = self.cameraTap
        hardware.openDevices {
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            if let cam, let input = try? AVCaptureDeviceInput(device: cam), session.canAddInput(input) {
                session.addInput(input)
            }
            if let mic, let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            } else {
                session.sessionPreset = .high
            }
            if !session.outputs.contains(output), session.canAddOutput(output) {
                session.addOutput(output)
            }
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(audioTap, queue: audioTap.queue)
                session.addOutput(audioOutput)
            }
            // Camera frames for screen sessions (camera.mov is written next to screen.mov, same clock).
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                videoOutput.alwaysDiscardsLateVideoFrames = false
                videoOutput.setSampleBufferDelegate(cameraTap, queue: cameraTap.queue)
                session.addOutput(videoOutput)
            }
            session.commitConfiguration()
            if !session.isRunning { session.startRunning() }
        }
    }

    // MARK: Screen

    /// Lists displays and windows (asks for the screen-recording permission the first time for this signature, or
    /// when `userClicked` "Riprova") and starts the preview on the stored target, or on the main display when that
    /// target is gone.
    func refreshScreen(userClicked: Bool = false) async {
        guard sources.screen else {
            await screen?.stopStream()
            screen = nil
            screenFrame = nil
            return
        }
        // Issue #67: the automatic paths ask macOS once per code signature; afterwards only "Riprova" asks again.
        switch ScreenAccess.decide(preflight: hardware.screenAllowed(), askedForThisSignature: screenAsk.askedForThisSignature,
                                   userClicked: userClicked) {
        case .guide:
            screenPermission = .denied
            screenFrame = nil
            return
        case .ask:
            screenAsk.remember()
            screenPermission = .denied
            screenFrame = nil
            screenPromptShown = true
            hardware.requestScreen()
            return
        case .proceed:
            break
        }
        do {
            let content = try await hardware.shareableContent()
            let me = ProcessInfo.processInfo.processIdentifier
            displays = content.displays
            windows = content.windows.filter {
                $0.owningApplication?.processID != me && $0.isOnScreen && $0.frame.width > 200 && $0.frame.height > 150 && $0.windowLayer == 0
            }
            screenPermission = .granted
            errorMessage = nil
            let target = RecordingSources.resolve(sources.target, displays: displays, windows: windows.map(\.windowID),
                                                  main: hardware.connectedDisplays().first(where: \.main)?.id ?? CGMainDisplayID())
            if target != sources.target { sources.target = target } else { await restartPreview() }
        } catch {
            // The source stays on: its row says what to do. Never prompt again from here (issue #67).
            screenAsk.remember()
            screenPermission = .denied
            screenFrame = nil
        }
    }

    /// Back in the app (maybe from System Settings): re-read the permissions without prompting, and start the screen
    /// preview when the screen permission is now in effect.
    private func appBecameActive() {
        let before = screenPermission
        refreshPermissions()
        if isReady, sources.screen, before != .granted, screenPermission == .granted, !isRecording { Task { await refreshScreen() } }
    }

    /// "Riprova" on the Schermo row, an explicit user action: asks macOS again (the prompt when this signature is
    /// undecided, a new entry in the list after a reset, nothing when denied), then checks again.
    func retryScreen() {
        refreshPermissions()
        Task { await refreshScreen(userClicked: true) }
    }

    /// "Riapri Regista": quits and opens this copy again (a screen permission takes effect only then). Refused while a
    /// take runs or the project has unsaved changes (`blocked`, from ScreenAccess.relaunchBlock).
    func relaunchApp(blocked: String?) {
        if let blocked { errorMessage = blocked; return }
        let app = Bundle.main.bundleURL.path
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app]   // l10n-ignore
        do { try p.run() } catch { errorMessage = loc("Regista non si riapre da solo: %@", error.localizedDescription); return }
        NSApp.terminate(nil)
    }

    /// (Re)starts the screen stream for the preview on the chosen target (a new session folder each time).
    private func restartPreview() async {
        guard sources.screen, !isRecording, let target = sources.target, screenPermission == .granted else { return }
        await screen?.stopStream()
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let folder = Paths.recordings.appendingPathComponent(loc("Sessione %@", f.string(from: Date())), isDirectory: true)
        let s = hardware.screenSession(folder: folder, layout: effectiveLayout, systemAudio: sources.recordsSystemAudio, cursorInVideo: !sources.hideCursor)
        s.onPreviewFrame = { [weak self] surface in
            Task { @MainActor in self?.screenFrame = surface }
        }
        s.onStreamError = { [weak self] message in
            Task { @MainActor in self?.errorMessage = message }
        }
        do {
            try await s.start(target: target)
            screen = s
        } catch {
            errorMessage = loc("L'anteprima dello schermo non parte: %@", error.localizedDescription)
            screen = nil
        }
    }

    // MARK: Record

    func toggleRecording() { isRecording ? stop() : start() }

    func start() {
        guard isReady, !isRecording else { return }
        errorMessage = nil
        if let reason = blockReason {
            errorMessage = reason
            return
        }
        if sources.screen {
            guard let s = screen else {
                errorMessage = loc("Lo schermo non è pronto: scegli cosa registrare (o consenti la registrazione dello schermo).")
                return
            }
            do { try FileManager.default.createDirectory(at: s.folder, withIntermediateDirectories: true) }
            catch { errorMessage = loc("La cartella della registrazione non si crea: %@", error.localizedDescription); return }
            s.cameraName = cameraDevice?.localizedName
            s.micName = microphoneDevice?.localizedName
            let clock = session.synchronizationClock
            cameraTap.handler = { [weak s] b in s?.capture(b, camera: true, clock: clock) }
            audioTap.recorder = { [weak s] b in s?.capture(b, camera: false, clock: clock) }
            s.beginRecording()
            startEventMonitors(s)
            recordingScreen = true
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let url = Paths.recordings.appendingPathComponent(loc("Registrazione %@", f.string(from: Date())) + ".mov")
            hardware.startMovie(output, to: url, delegate: self)
            recordingScreen = false
        }

        isRecording = true
        isPaused = false
        startDate = Date()
        pausedSeconds = 0
        elapsed = 0
        clock = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let s = self.startDate, !self.isPaused else { return }
                self.elapsed = Date().timeIntervalSince(s) - self.pausedSeconds
            }
        }

        promptedTake = sources.prompter
        if sources.prompter {
            let p = TeleprompterController.shared
            p.restart()
            p.show()
            p.play()
        }
    }

    /// Pause / resume, with or without the screen (#19): a screen session shifts what follows a pause back (the pause is
    /// noted in session.json), a camera or voice take pauses its movie file; either way nothing is written meanwhile and
    /// the files have no gap. The clock stops, the teleprompter pauses with the take and its markers skip the pause.
    func togglePause() {
        guard isRecording else { return }
        if recordingScreen, screen == nil { return }
        if isPaused {
            if recordingScreen { screen?.resume() } else { hardware.resumeMovie(output) }
            if let d = pauseDate { pausedSeconds += Date().timeIntervalSince(d) }
            pauseDate = nil
            isPaused = false
            TeleprompterController.shared.recordingResumed()
        } else {
            if recordingScreen { screen?.pause() } else { hardware.pauseMovie(output) }
            pauseDate = Date()
            isPaused = true
            TeleprompterController.shared.recordingPaused()
        }
    }

    func stop() {
        guard isRecording else { return }
        clock?.invalidate()
        clock = nil
        TeleprompterController.shared.pause()
        if recordingScreen, let s = screen {
            stopEventMonitors()
            cameraTap.handler = nil
            audioTap.recorder = nil
            screen = nil
            Task {
                do {
                    let url = try await s.finish()
                    isRecording = false
                    isPaused = false
                    onSessionFinished?(url)
                } catch {
                    isRecording = false
                    errorMessage = loc("La registrazione non si è chiusa bene: %@", error.localizedDescription)
                }
                await restartPreview()
            }
        } else {
            hardware.stopMovie(output)
        }
    }

    // MARK: Clicks, keys, cursor

    private func startEventMonitors(_ s: ScreenRecording) {
        let offset = ScreenSession.hostNow - ProcessInfo.processInfo.systemUptime
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        /// Cocoa global point (bottom-left origin) → global point with a top-left origin, like the capture region.
        let global: @Sendable (NSPoint) -> CGPoint = { p in CGPoint(x: p.x, y: primaryHeight - p.y) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in
            s.click(kind: e.type == .rightMouseDown ? "rightClick" : "click", at: global(NSEvent.mouseLocation), host: e.timestamp + offset)
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { e in
            s.mouseUp(at: global(NSEvent.mouseLocation), host: e.timestamp + offset)
        }) { monitors.append(m) }
        if AXIsProcessTrusted(), let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { e in
            var mods: [String] = []
            if e.modifierFlags.contains(.command) { mods.append("cmd") }
            if e.modifierFlags.contains(.control) { mods.append("ctrl") }
            if e.modifierFlags.contains(.option) { mods.append("alt") }
            if e.modifierFlags.contains(.shift) { mods.append("shift") }
            let key = (e.charactersIgnoringModifiers ?? "").lowercased()
            s.key((mods + [key.isEmpty ? "k\(e.keyCode)" : key]).joined(separator: "+"), host: e.timestamp + offset)
        }) { monitors.append(m) }
        let probe = cursorKind
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            MainActor.assumeIsolated {
                s.cursorMoved(to: global(NSEvent.mouseLocation), kind: probe.current(), down: NSEvent.pressedMouseButtons & 1 != 0,
                              host: ScreenSession.hostNow)
            }
        }
    }

    private func stopEventMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        cursorTimer?.invalidate()
        cursorTimer = nil
    }
}

/// What the live preview draws (#162): the latest screen frame (an IOSurface from ScreenCaptureKit) and the face's place
/// for the format guide. Only the picture and the guide observe it.
@MainActor
final class PreviewFeed: ObservableObject {
    @Published var surface: IOSurface?
    @Published var faceX: Double?
}

/// The microphone's level, 0…1 on a −60…0 dBFS scale, with a quick rise and a slower fall.
@MainActor
final class MicLevel: ObservableObject {
    @Published private(set) var value: Double = 0

    func push(_ peak: Float) {
        let db = 20 * log10(Double(max(peak, 1e-5)))
        let v = min(max((db + 60) / 60, 0), 1)
        value = max(v, value * 0.8)
    }

    func reset() { value = 0 }
}

extension Recorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        var ok = true
        if let e = error as NSError? {
            ok = (e.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        }
        let message = error.map { loc("La registrazione non è riuscita: %@", $0.localizedDescription) }
        Task { @MainActor in
            self.isRecording = false
            self.isPaused = false
            let claimed = self.nextTakeHandler
            self.nextTakeHandler = nil
            if ok, let claimed {
                claimed(outputFileURL)
            } else if ok {
                self.onFinished?(outputFileURL)
            } else {
                self.errorMessage = message
            }
        }
    }
}

/// Forwards microphone sample buffers to whoever is listening: the teleprompter (`sink`, or a plain `handler`) and a
/// screen recording session (`recorder`).
final class AudioTap: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "regista.audio-tap")   // l10n-ignore
    private let lock = NSLock()
    private var _handler: ((CMSampleBuffer) -> Void)?
    private var _recorder: ((CMSampleBuffer) -> Void)?
    private weak var _sink: SpeechAudioSink?

    var sink: SpeechAudioSink? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    var handler: ((CMSampleBuffer) -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    var recorder: ((CMSampleBuffer) -> Void)? {
        get { lock.withLock { _recorder } }
        set { lock.withLock { _recorder = newValue } }
    }

    /// The peak of the last ~50 ms of microphone audio (0…1), about twenty times a second.
    var onLevel: (@Sendable (Float) -> Void)? {
        get { lock.withLock { _onLevel } }
        set { lock.withLock { _onLevel = newValue } }
    }
    private var _onLevel: (@Sendable (Float) -> Void)?
    private var levelPeak: Float = 0
    private var levelSince = 0.0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler?(sampleBuffer)
        sink?.speechAudio(sampleBuffer)
        recorder?(sampleBuffer)
        if let onLevel { measure(sampleBuffer, report: onLevel) }
    }

    /// Called on `queue` only.
    private func measure(_ buffer: CMSampleBuffer, report: (Float) -> Void) {
        guard let pcm = LiveSpeechSession.pcm(from: buffer) else { return }
        let n = Int(pcm.frameLength)
        var peak: Float = 0
        if let ch = pcm.floatChannelData {
            for c in 0..<Int(pcm.format.channelCount) { for i in 0..<n { peak = max(peak, abs(ch[c][i])) } }
        } else if let ch = pcm.int16ChannelData {
            for c in 0..<Int(pcm.format.channelCount) { for i in 0..<n { peak = max(peak, abs(Float(ch[c][i]) / 32768)) } }
        } else if let ch = pcm.int32ChannelData {
            for c in 0..<Int(pcm.format.channelCount) { for i in 0..<n { peak = max(peak, abs(Float(ch[c][i]) / 2147483648)) } }
        }
        levelPeak = max(levelPeak, peak)
        let now = CACurrentMediaTime()
        if now - levelSince >= 0.05 {
            report(levelPeak)
            levelPeak = 0
            levelSince = now
        }
    }
}

/// Camera frames for a screen recording session.
final class CameraTap: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "regista.camera-tap")   // l10n-ignore
    private let lock = NSLock()
    private var _handler: ((CMSampleBuffer) -> Void)?

    var handler: ((CMSampleBuffer) -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    /// The face's centre across the frame (0…1, nil: none), a few times a second while set (#153).
    var onFace: (@Sendable (Double?) -> Void)? {
        get { lock.withLock { _onFace } }
        set { lock.withLock { _onFace = newValue } }
    }
    private var _onFace: (@Sendable (Double?) -> Void)?
    private var faceAt = 0.0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        handler?(sampleBuffer)
        if let onFace { detectFace(sampleBuffer, report: onFace) }
    }

    /// Called on `queue` only: the largest face of the frame, at most four times a second.
    private func detectFace(_ buffer: CMSampleBuffer, report: (Double?) -> Void) {
        let now = CACurrentMediaTime()
        guard now - faceAt >= 0.25, let pixels = CMSampleBufferGetImageBuffer(buffer) else { return }
        faceAt = now
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixels, options: [:]).perform([request])
        let face = request.results?.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }
        report(face.map { Double($0.boundingBox.midX) })
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = gravity
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView.layer as? AVCaptureVideoPreviewLayer)?.videoGravity = gravity
    }
}

/// The latest screen frame (an IOSurface from ScreenCaptureKit) as layer contents.
struct ScreenPreview: NSViewRepresentable {
    let surface: IOSurface?
    var gravity: CALayerContentsGravity = .resizeAspect

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.contentsGravity = gravity
        view.layer?.backgroundColor = NSColor.black.cgColor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.layer?.contentsGravity = gravity
        nsView.layer?.contents = surface
    }
}

/// A full-screen transparent window where the person drags the area to record (Esc cancels). The rect comes back
/// in display points with a top-left origin, as ScreenCaptureKit's `sourceRect` wants it.
@MainActor
enum AreaPicker {
    private static var window: NSWindow?

    static func pick(on screen: NSScreen, done: @escaping (CGRect?) -> Void) {
        let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.25)
        w.sharingType = .none
        let view = AreaView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.done = { rect in
            w.orderOut(nil)
            window = nil
            done(rect.map { CGRect(x: $0.minX, y: screen.frame.height - $0.maxY, width: $0.width, height: $0.height) })
        }
        w.contentView = view
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        window = w
    }

    final class AreaView: NSView {
        var done: ((CGRect?) -> Void)?
        private var start: CGPoint?
        private var rect: CGRect?

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil) }

        override func mouseDragged(with e: NSEvent) {
            guard let s = start else { return }
            let p = convert(e.locationInWindow, from: nil)
            rect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            needsDisplay = true
        }

        override func mouseUp(with e: NSEvent) {
            guard let r = rect, r.width > 80, r.height > 60 else { rect = nil; needsDisplay = true; return }
            done?(r.integral)
        }

        override func keyDown(with e: NSEvent) {
            if e.keyCode == 53 { done?(nil) } else { super.keyDown(with: e) }
        }

        override func draw(_ dirtyRect: NSRect) {
            let hint = loc("Trascina per scegliere l'area da registrare · Esc per annullare") as NSString
            hint.draw(at: CGPoint(x: 40, y: bounds.height - 60), withAttributes: [.foregroundColor: NSColor.white, .font: Ed.overlayFont(18, .medium)])
            guard let r = rect else { return }
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.white.withAlphaComponent(0.9).setStroke()
            let path = NSBezierPath(rect: r)
            path.lineWidth = 2
            path.setLineDash([8, 5], count: 2, phase: 0)
            path.stroke()
            ("\(Int(r.width))×\(Int(r.height))" as NSString).draw(at: CGPoint(x: r.minX + 8, y: r.maxY + 8),
                                                                  withAttributes: [.foregroundColor: NSColor.white, .font: Ed.overlayFont(14, .regular, digits: true)])
        }
    }
}
