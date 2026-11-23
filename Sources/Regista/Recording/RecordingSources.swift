import CoreGraphics
import CryptoKit
import Foundation
import RegistaCore
import Security

/// What the Registra screen records (issue #50): one switch per source, the device each one uses — kept while the
/// source is off, so turning it back on restores it — the screen target, the face layout and the screen options.
/// A pure value: the Recorder owns one, persists it on every change and turns it into capture inputs.
struct RecordingSources: Codable, Equatable {
    enum Source: String, CaseIterable, Codable {
        case screen, camera, microphone, systemAudio, prompter
    }

    /// The four starting points above the rows. A preset only sets the screen / camera / microphone switches.
    enum Preset: String, CaseIterable, Identifiable {
        case screenOnly = "screen-only", screenFace = "screen-face", face, voice
        var id: String { rawValue }

        var switches: Switches {
            switch self {
            case .screenOnly: Switches(screen: true, camera: false, microphone: false)
            case .screenFace: Switches(screen: true, camera: true, microphone: true)
            case .face: Switches(screen: false, camera: true, microphone: true)
            case .voice: Switches(screen: false, camera: false, microphone: true)
            }
        }

        /// Italian key (the UI looks it up).
        var title: String {
            switch self {
            case .screenOnly: "Solo schermo"
            case .screenFace: "Schermo + volto"
            case .face: "Solo volto"
            case .voice: "Solo voce"
            }
        }

        var symbol: String {
            switch self {
            case .screenOnly: "display"
            case .screenFace: "inset.filled.bottomtrailing.rectangle"
            case .face: "person.crop.rectangle"
            case .voice: "waveform"
            }
        }
    }

    struct Switches: Equatable {
        var screen: Bool
        var camera: Bool
        var microphone: Bool
    }

    var screen = false
    var camera = true
    var microphone = true
    /// The Mac's own sound; recorded only while the screen is on.
    var systemAudio = false
    /// The teleprompter window opens and starts with the recording.
    var prompter = true
    /// Last camera / microphone picked (nil: the system default). Never cleared by turning the source off.
    var cameraID: String?
    var microphoneID: String?
    var target: ScreenTarget?
    /// Record the screen without the system cursor: the editor draws it (issue #42).
    var hideCursor = true
    var layout = LayoutSpec(kind: .bubble)
    /// The video's format chosen on Registra (#153): a preset id (9:16, 16:9, 4:5, 1:1); nil = as the camera for a camera
    /// take, 16:9 for a screen session.
    var videoFormat: String?

    var switches: Switches {
        get { Switches(screen: screen, camera: camera, microphone: microphone) }
        set { screen = newValue.screen; camera = newValue.camera; microphone = newValue.microphone }
    }

    /// The preset these switches match, nil for a custom combination.
    var preset: Preset? { Preset.allCases.first { $0.switches == switches } }

    mutating func apply(_ preset: Preset) { switches = preset.switches }

    func isOn(_ s: Source) -> Bool {
        switch s {
        case .screen: screen
        case .camera: camera
        case .microphone: microphone
        case .systemAudio: systemAudio
        case .prompter: prompter
        }
    }

    mutating func set(_ s: Source, _ on: Bool) {
        switch s {
        case .screen: screen = on
        case .camera: camera = on
        case .microphone: microphone = on
        case .systemAudio: systemAudio = on
        case .prompter: prompter = on
        }
    }

    /// At least one of screen, camera and microphone.
    var hasSomethingToRecord: Bool { screen || camera || microphone }
    var recordsSystemAudio: Bool { screen && systemAudio }
    /// The face layout matters only with both the screen and the camera.
    var showsFaceLayout: Bool { screen && camera }
    /// The layout written into the session: without a camera the screen fills the frame.
    var effectiveLayout: LayoutSpec { camera ? layout : LayoutSpec(kind: .screen) }

    /// The format the take's project gets (#153): a preset id, or nil for the camera's own size (a camera take as the camera).
    var takeFormat: String? { screen ? (videoFormat ?? "16:9") : videoFormat }

    /// The choice as the menu shows it: «camera» for the camera's own format.
    var formatChoice: String { screen ? (videoFormat ?? "16:9") : (videoFormat ?? Self.cameraFormat) }
    static let cameraFormat = "camera"

    /// The aspect of the guide drawn on the camera preview: a chosen format other than the camera's (its preview is 16:9),
    /// while the camera shows alone. nil: no guide.
    var guideAspect: Double? {
        guard camera, !screen, let id = videoFormat, let p = ExportPreset.all.first(where: { $0.id == id }) else { return nil }
        let a = Double(p.width) / Double(p.height)
        return abs(a - 16.0 / 9) > 0.01 ? a : nil
    }

    /// The device a source that is on uses: the remembered one while it is connected, else the system default, else
    /// the first one. The remembered choice is not overwritten: when that device comes back it is used again.
    static func device(remembered: String?, available: [String], systemDefault: String?) -> String? {
        if let r = remembered, available.contains(r) { return r }
        if let d = systemDefault, available.contains(d) { return d }
        return available.first
    }

    /// The screen to record: the stored target while it still exists, else the main display (else the first one).
    static func resolve(_ stored: ScreenTarget?, displays: [CGDirectDisplayID], windows: [CGWindowID],
                        main: CGDirectDisplayID?) -> ScreenTarget? {
        switch stored {
        case .display(let id) where displays.contains(id): return stored
        case .area(let id, _) where displays.contains(id): return stored
        case .window(let id) where windows.contains(id): return stored
        default:
            if let m = main, displays.contains(m) { return .display(m) }
            return displays.first.map { .display($0) }
        }
    }

    // MARK: Persistence

    static let defaultsKey = "recorder.sources"

    /// The stored choices; the first time, the settings of the previous Registra screen (camera / microphone
    /// "none", hidden cursor, teleprompter with the recording).
    static func load(from d: UserDefaults) -> RecordingSources {
        if let data = d.data(forKey: defaultsKey), let s = try? JSONDecoder().decode(RecordingSources.self, from: data) { return s }
        var s = RecordingSources()
        let none = "none"
        if let cam = d.string(forKey: "recorder.cameraID") {
            s.camera = cam != none
            s.cameraID = cam == none || cam.isEmpty ? nil : cam
        }
        if let mic = d.string(forKey: "recorder.microphoneID") {
            s.microphone = mic != none
            s.microphoneID = mic == none || mic.isEmpty ? nil : mic
        }
        if let hide = d.object(forKey: "recorder.hideCursor") as? Bool { s.hideCursor = hide }
        if let p = d.object(forKey: Prefs.startPrompterKey) as? Bool { s.prompter = p }
        return s
    }

    func save(to d: UserDefaults) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.defaultsKey) }
    }
}

/// The macOS privacy permission behind a source.
enum CapturePermission: String {
    case granted, undetermined, denied

    /// The System Settings pane where the user allows Regista.
    static func settingsURL(_ source: RecordingSources.Source) -> URL? {
        let pane = switch source {
        case .camera: "Privacy_Camera"   // l10n-ignore
        case .microphone: "Privacy_Microphone"   // l10n-ignore
        case .screen, .systemAudio: "Privacy_ScreenCapture"   // l10n-ignore
        case .prompter: "Privacy_SpeechRecognition"   // l10n-ignore
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

/// What to do about the screen-recording permission (issue #67). macOS shows its prompt once per code signature; a
/// grant takes effect only after the app is reopened. So the automatic paths (opening Registra, switching the screen
/// on, coming back to the app) trigger the prompt at most once per signature; afterwards the row explains what to do,
/// and "Riprova" asks macOS again because the user pressed it.
enum ScreenAccess: Equatable {
    /// The permission is in effect: list displays and windows, start the preview.
    case proceed
    /// Call CGRequestScreenCaptureAccess: never asked for this signature, or the user pressed "Riprova". It shows the
    /// prompt when macOS has not decided for this signature, and registers Regista again in the list after a reset.
    case ask
    /// Asked before for this signature and still not in effect: call nothing that can prompt, show the guidance.
    case guide

    static func decide(preflight: Bool, askedForThisSignature: Bool, userClicked: Bool) -> ScreenAccess {
        if preflight { return .proceed }
        return userClicked || !askedForThisSignature ? .ask : .guide
    }

    /// The plain-words guidance shown on the Schermo row and the preview (Italian keys, looked up by `lookup`).
    /// `promptShown`: Regista has just asked macOS in this session (the system window may be open).
    static func guidance(promptShown: Bool = false, lookup: (String) -> String = { $0 }) -> String {
        promptShown
            ? lookup("Regista ha chiesto il permesso a macOS: consentilo nella finestra di macOS o in Impostazioni › Registrazione schermo, poi premi «Riapri Regista».")
            : lookup("Consenti Regista in Impostazioni › Registrazione schermo, poi riapri Regista: il permesso vale solo dopo la riapertura. Se Regista è già acceso nell'elenco, spegnilo e riaccendilo, poi riapri.")
    }

    /// Why "Riapri Regista" cannot relaunch now (nil: it can).
    static func relaunchBlock(recording: Bool, unsaved: Bool, lookup: (String) -> String = { $0 }) -> String? {
        if recording { return lookup("Ferma prima la registrazione, poi riapri Regista") }
        if unsaved { return lookup("Salva prima il progetto (⌘S), poi riapri Regista") }
        return nil
    }
}

/// A connected display as the Registra picker draws it (issue #50): `frame` in global display points with a top-left
/// origin (CGDisplayBounds), the arrangement of macOS Displays settings.
struct DisplayInfo: Equatable, Identifiable {
    let id: CGDirectDisplayID
    var name: String
    var frame: CGRect
    var main: Bool

    /// Four sample displays for renders: a laptop (the main display) under a large display, one display on each side.
    static let samples: [DisplayInfo] = [
        // l10n-ignore-begin (sample display names, data)
        DisplayInfo(id: 1, name: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), main: true),
        DisplayInfo(id: 2, name: "Studio Display", frame: CGRect(x: -524, y: -1440, width: 2560, height: 1440), main: false),
        DisplayInfo(id: 3, name: "DELL U2723QE", frame: CGRect(x: -2444, y: -1080, width: 1920, height: 1080), main: false),
        DisplayInfo(id: 4, name: "LG HDR 4K", frame: CGRect(x: 2036, y: -1080, width: 1920, height: 1080), main: false),
        // l10n-ignore-end
    ]

    /// One tile per display (same order) in the macOS arrangement, scaled to fit `width` × `maxHeight` and centred
    /// horizontally; nil when a tile would be smaller than `minTile` (a very wide setup: the picker uses a grid).
    static func arrangement(_ displays: [DisplayInfo], width: CGFloat, maxHeight: CGFloat, minTile: CGSize) -> [CGRect]? {
        guard let first = displays.first else { return nil }
        let union = displays.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        guard union.width > 0, union.height > 0 else { return nil }
        let scale = min(width / union.width, maxHeight / union.height)
        let dx = (width - union.width * scale) / 2
        let tiles = displays.map { d in
            CGRect(x: dx + (d.frame.minX - union.minX) * scale, y: (d.frame.minY - union.minY) * scale,
                   width: d.frame.width * scale, height: d.frame.height * scale)
        }
        return tiles.allSatisfy { $0.width >= minTile.width && $0.height >= minTile.height } ? tiles : nil
    }

    /// The display a target records (an area's display too); nil for a window. No target yet: the main display.
    static func selected(_ target: ScreenTarget?, main: CGDirectDisplayID) -> CGDirectDisplayID? {
        switch target {
        case .display(let id): id
        case .area(let id, _): id
        case .window: nil
        case nil: main
        }
    }
}

/// "macOS was asked for the screen" remembered per code signature (issue #67): TCC keys its answer to the app's
/// designated requirement, so a new signature (a new certificate, an ad-hoc or unsigned build) or a `tccutil reset`
/// must not inherit an old "asked". The stored value is the fingerprint of the signature it was asked for.
struct ScreenAskMemory {
    static let key = "recorder.askedScreenSignature"
    /// The boolean of 25d1042: it does not say for which signature, so it counts as never asked.
    static let legacyKey = "recorder.askedScreen"
    let defaults: UserDefaults
    /// CodeSignature.fingerprint of the running app.
    let signature: String

    /// Removes the old boolean (whatever its value, the current signature counts as never asked).
    func migrate() { defaults.removeObject(forKey: Self.legacyKey) }
    var askedForThisSignature: Bool { defaults.string(forKey: Self.key) == signature }
    func remember() { defaults.set(signature, forKey: Self.key) }
}

/// The running app's code signature as a short stable value: SHA-256 (hex) of its designated requirement — what TCC
/// stores with a permission. "none" when it has none (an unsigned run).
enum CodeSignature {
    static let current = fingerprint(requirement: designatedRequirement())

    static func fingerprint(requirement: String?) -> String {
        guard let requirement, !requirement.isEmpty else { return "none" }
        return SHA256.hash(data: Data(requirement.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The designated requirement's text, e.g. `identifier "com.arkad.regista" and certificate leaf = H"…"`, or
    /// `cdhash H"…"` for an ad-hoc build.
    static func designatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }
}

/// What a source row shows, computed from the sources, the devices and the permissions (the view draws it and
/// ui.screenshot describes it, so the render and its description cannot disagree).
struct SourceRowInfo: Equatable {
    var source: RecordingSources.Source
    var on: Bool
    /// Italian key.
    var title: String
    var symbol: String
    /// The current choice, already localized.
    var detail: String
    var enabled = true
    /// Why the switch cannot be used (localized), when `enabled` is false.
    var disabledReason: String?
    var permission: CapturePermission = .granted
    /// The row opens a list of choices.
    var hasChoices = true

    /// The permission is missing for a source that is on.
    var blocked: Bool { on && permission == .denied }
}

/// The facts the rows are computed from: device names, current choices and permissions.
struct RecordingEnvironment {
    var cameraName: String?
    var microphoneName: String?
    var targetName: String?
    var camera: CapturePermission = .granted
    var microphone: CapturePermission = .granted
    var screen: CapturePermission = .granted
    var prompterSummary: String = ""

    func permission(_ s: RecordingSources.Source) -> CapturePermission {
        switch s {
        case .camera: camera
        case .microphone: microphone
        case .screen, .systemAudio: screen
        case .prompter: .granted
        }
    }
}

extension RecordingSources {
    /// The five rows, in screen order. `lookup` localizes (loc in the app, identity in tests).
    func rows(_ env: RecordingEnvironment, lookup: (String) -> String = { $0 }) -> [SourceRowInfo] {
        let off = lookup("spento")
        func detail(_ on: Bool, _ choice: String?, missing: String) -> String { on ? (choice ?? lookup(missing)) : off }
        var rows = [
            SourceRowInfo(source: .screen, on: screen, title: "Schermo", symbol: "display",
                          detail: detail(screen, env.targetName, missing: "Schermo principale")),
            SourceRowInfo(source: .camera, on: camera, title: "Camera", symbol: "video",
                          detail: detail(camera, env.cameraName, missing: "Nessuna camera collegata")),
            SourceRowInfo(source: .microphone, on: microphone, title: "Microfono", symbol: "mic",
                          detail: detail(microphone, env.microphoneName, missing: "Nessun microfono collegato")),
            SourceRowInfo(source: .systemAudio, on: systemAudio, title: "Audio del Mac", symbol: "speaker.wave.2",
                          detail: systemAudio && screen ? lookup("Il suono delle app, senza la voce") : off, hasChoices: false),
            SourceRowInfo(source: .prompter, on: prompter, title: "Gobbo", symbol: "text.alignleft",
                          detail: prompter ? env.prompterSummary : off, hasChoices: false),
        ]
        for i in rows.indices {
            rows[i].permission = env.permission(rows[i].source)
            if rows[i].source == .systemAudio, !screen {
                rows[i].enabled = false
                rows[i].disabledReason = lookup("Si registra insieme allo schermo: accendi lo Schermo")
            }
        }
        return rows
    }

    /// Why recording cannot start (localized), nil when it can.
    func blockReason(_ env: RecordingEnvironment, lookup: (String) -> String = { $0 }) -> String? {
        if !hasSomethingToRecord { return lookup("Accendi almeno lo schermo, la camera o il microfono") }
        let denied = rows(env, lookup: lookup).filter { $0.blocked && $0.source != .systemAudio }
        if let r = denied.first {
            return String(format: lookup("%@: manca il permesso di macOS. Consentilo o spegni la sorgente"), lookup(r.title))
        }
        return nil
    }
}
