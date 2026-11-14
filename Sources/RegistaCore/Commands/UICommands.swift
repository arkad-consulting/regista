import Foundation

/// What only the running Regista app can do: draw its own window and pull frames from its live preview
/// player. Headless hosts (regista-engine, a regista-mcp that did not find the app) leave it nil.
public protocol UIHost {
    /// Renders the main window showing `workspace` (an activity such as "home", "record", "media", "export", or the
    /// editor "edit-pro" / "edit-semplice"; nil = the current one)
    /// at `width`×`height` points (nil = the current window size) to a PNG. Returns the pixel size and what the
    /// window shows (workspace, timeline lanes with their clip counts, agent connection) as JSON.
    /// `canvas`: a selection or drag drawn on the Program monitor / Semplice monitor without a mouse (ui.screenshot `canvas`).
    /// `record`: the Registra screen in a given state (preset, open row…), drawn without changing the recorder.
    /// `voice`: the voice screens (Voce panel, recording flow, Settings › Profilo e voce) in a given state, from a value.
    /// `tabs`: draw that many project tabs (the active one, then sample ones) instead of the open tabs.
    /// `inspector`: the Ispettore tab showing a given selection (a clip, the first video / audio / overlay clip, the
    /// captions, several clips, nothing), optionally of a project file opened for the render only.
    /// `texts`: the Testi e sottotitoli steps in a given state, from sample data; `jobs`: sample jobs in the status bar,
    /// the jobs list open or not. `audio`: the Audio activity's sub-tab, open group and sample level / ducking check.
    /// `simple`: the Semplice level's steps in a given state (sample data) and the step open.
    func screenshot(workspace: String?, width: Int?, height: Int?, canvas: JSONValue?, record: JSONValue?, voice: JSONValue?, tabs: Int?,
                    inspector: JSONValue?, texts: JSONValue?, jobs: JSONValue?, audio: JSONValue?, simple: JSONValue?,
                    to output: URL) throws -> (width: Int, height: Int, shown: JSONValue)
    /// Captures the real main window as it is on screen, native title bar included (ScreenCaptureKit, only when the
    /// Screen Recording permission is already in effect: never asks), to a PNG. `shown` reports the window's geometry.
    func captureWindow(to output: URL) throws -> (width: Int, height: Int, shown: JSONValue)
    /// The frame the preview player shows at timeline time `time`, written as a PNG at full output size.
    func previewFrame(at time: MediaTime, to output: URL) throws -> (width: Int, height: Int)
}

public extension UIHost {
    func captureWindow(to output: URL) throws -> (width: Int, height: Int, shown: JSONValue) {
        throw CommandError(.io, "ui.screenshot: real needs the Regista app window")
    }
}

enum UIRequire {
    static func host(_ ctx: CommandContext, command: String) throws -> UIHost {
        guard let ui = ctx.services.ui else {
            throw CommandError(.io, "\(command): needs the Regista app — open Regista.app and call it again (regista-mcp attaches to the running app by itself)")
        }
        return ui
    }
}

enum UIScreenshot: Command {
    static let id = "ui.screenshot"
    static let summary = "See the Regista app the way the user sees it: renders the app window (an activity of its left bar, or the editor: \"edit-pro\" = monitors and timeline, \"edit-semplice\" = the guided steps of the simple level) to a PNG, returned as an image. Only when the app is running. Returns the path, size and what the window shows (timeline lanes and clip counts)."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("workspace", .oneOf(["home", "record", "media", "texts", "audio", "voice", "graphics", "generate", "export", "edit-pro", "edit-semplice", "pro", "semplice", "panel-prompter", "panel-claude", "panel-inspector", "settings", "teleprompter", "teleprompter-mirror", "brand-picker", "pro-fullscreen", "graphics-filters", "graphics-adjust", "graphics-effects", "graphics-styles", "graphics-motion", "graphics-logo", "voice-setup", "settings-voice", "settings-general", "settings-engines", "settings-engines-base", "settings-engines-medium", "settings-engines-pro", "settings-brand", "settings-claude", "settings-shortcuts"]), "Workspace to show (default: the current one; the app switches back afterwards). The window is an activity bar on the left (home = Inizio: ways in, recent projects; record = Registra; media, texts, audio, voice, graphics, generate = the editor with that library activity in the side panel; export = Esporta), project tabs on top, and a right panel (Gobbo, Claude, Ispettore). edit-pro (also pro, pro-fullscreen) = the editor at the Pro level, edit-semplice (also semplice) = its simple level: six guided steps (cut and takes, captions, look, music and sounds, voice, graphics) beside one monitor; panel-prompter / panel-claude / panel-inspector = edit-pro with that right-panel tab; settings = the Settings window (720×600) on its Generale tab; settings-general / settings-engines / settings-voice / settings-brand (the brand kit editor) / settings-claude / settings-shortcuts = that tab; settings-engines-base / -medium / -pro = the Motori tab as on that tier (the Mac's real engine states, the tier only for the render: engines.json is not touched; shown reports the tier, the rows that need a higher tier and the installable ones). teleprompter / teleprompter-mirror render the speaker's teleprompter window (normally invisible to screen capture) with the project script, default 640×360. brand-picker = the Marca picker (the one place that picks the project's kit; 300 wide). graphics-filters / -adjust / -effects / -styles / -motion / -logo = the Graphics activity on that section of its panel (looks, adjustments, effects, one-click styles, motion templates, logo), the editor in the main area. voice = the editor with the Voce activity, voice-setup = the voice recording flow (880×620), settings-voice = Settings › Profilo e voce (720×600): all three drawn from `voice` (sample data, never the real profile) or, without it, from the live state."),
        .optional("size", .array(.integer), "Window size in points [width, height], e.g. [1440, 900] (default: the current size)."),
        .optional("path", .string, "Output .png (default: a temporary file)."),
        .optional("canvas", .object, "Show a selection on the preview as if clicked/dragged (pro or semplice, at the playhead — preview.frame moves it): {select: \"caption\" | <clipId>, drag?: [dx, dy] frame pixels (snap guides and the red Instagram zones show), scale?: factor, scope?: \"all\" | \"one\"}."),
        .optional("voice", .object, "With workspace voice / voice-setup / settings-voice: draw that screen from sample data, for the render only: {state: panel \"engine-missing\" | \"no-profile\" | \"no-voice\" | \"ready\" | \"rendering\" | \"placed\" | \"lexicon\"; flow \"profile\" | \"language\" | \"consent\" | \"record\" | \"check-good\" | \"check-poor\" | \"train\" | \"train-low-ram\" | \"training\"; settings: any panel state, tier?: \"base\" | \"medium\" | \"pro\" (forced RAM tier)}."),
        .optional("real", .boolean, "true: capture the real window as it is on screen, the native title bar and traffic lights included (ScreenCaptureKit; needs the Screen Recording permission already granted to Regista — it never asks, it fails with an error instead). Not combinable with workspace, size, canvas, record or voice. shown reports windowHeight, titleRowHeight (the native toolbar band), the three trafficLightButtons frames, contentTop (where the activity bar, side panel and project tabs begin) and titleItems (the toolbar item with Claude's status and the panel toggles)."),
        .optional("inspector", .object, "Show the Ispettore tab of the right panel (with the Pro editor unless workspace says otherwise) for a selection, drawn without clicking and without changing the real selection: {select: <clipId> | \"first-video\" | \"first-audio\" | \"first-music\" | \"first-overlay\" | \"captions\" | \"multi\" (the first two video clips) | \"none\", project?: path of a .regista folder opened for this render only (a scratch copy: the open tabs and their projects are not touched)}. shown.inspector reports what the panel shows (kind, clips, sections)."),
        .optional("texts", .object, "With workspace \"texts\": draw the Passi of Testi e sottotitoli (from an imported clip to captions) from sample data, for the render only: {state: \"fresh\" | \"transcribing\" | \"transcribed\" | \"cut\" | \"keywords\" | \"captions\" | \"stale\" | \"doall\" | \"failed\", tier?: \"base\" | \"medium\" | \"pro\"}. shown.steps reports each step's status."),
        .optional("simple", .object, "With workspace \"edit-semplice\": the Semplice level's six steps, for the render only: {step?: \"cut\" | \"captions\" | \"look\" | \"sound\" | \"voice\" | \"graphics\" (the step open; default the next one to do), state?: \"midway\" (cut and captions done, two lines with retakes) | \"done\" (every step in place) | \"doall\" (Fai tutto running on its third step) — sample states drawn over the project shown; without state, the project's real states}. shown.simple reports each step's status and the step open."),
        .optional("jobs", .object, "Draw sample jobs in the status bar's jobs item (a transcription, an export, a \"Fai tutto\" with sub-steps, a failed and a finished job, in two tabs): {open?: true (default) | false — the jobs list drawn open above the item}."),
        .optional("audio", .object, "With workspace \"audio\": draw the Audio activity for the render only: {tab?: \"mix\" | \"sfx\" (the sound-effect browser), group?: whoosh | ui | pop | impact | rise | chime | logo | glitch | typing | user | all (the open group), query?: a search, loudness?: [integrated LUFS, true peak dBTP] (sample level instead of the meter's), check?: {pass, underDB, minUnder} (a sample ducking check), playing?: a sound name drawn as playing}. Combine with inspector.project to draw a project opened for the render only."),
        .optional("tabs", .integer, "Draw this many project tabs on top of the main area (1–6): the active tab, then sample tabs (unsaved, recording, saved), to see the tab strip without opening other projects. Default: the tabs open in the app."),
        .optional("record", .object, "With workspace \"record\": draw the Registra screen in this state for the render only (the recorder and the saved choices do not change): {preset?: \"screen-only\" | \"screen-face\" | \"face\" | \"voice\", screen?, camera?, microphone?, systemAudio?, prompter?: booleans (after the preset), open?: \"screen\" | \"camera\" | \"microphone\" (that row's choices open), layout?: bubble | split | stack | face | cutout | screen, corner?, size?, shape?, permissions?: \"actual\" (default) | \"granted\" (as if macOS allowed camera, microphone and screen), displays?: 1–4 (sample displays instead of the connected ones, the first one main and the second one selected: with two or more the display picker shows under the Schermo row)}. shown.record reports the preset, the switches and each row as drawn."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let ui = try UIRequire.host(ctx, command: id)
        if p.bool("real") == true {
            let other = ["workspace", "size", "canvas", "record", "voice", "tabs", "inspector", "texts", "jobs", "audio", "simple"].filter { p.json($0) != nil }
            guard other.isEmpty else { throw CommandError.invalid("\(id): real captures the window as it is: drop \(other.joined(separator: ", "))") }
            let output: URL
            if let path = p.string("path") { output = try Render.output(path, command: id) }
            else { output = try Previews.directory().appendingPathComponent("ui-real-\(UUID().uuidString.prefix(8)).png") }
            let px = try ui.captureWindow(to: output)
            return ["path": .string(output.path), "width": .number(Double(px.width)), "height": .number(Double(px.height)),
                    "host": "app", "real": true, "shown": px.shown, "images": [["path": .string(output.path), "mimeType": "image/png",
                                               "width": .number(Double(px.width)), "height": .number(Double(px.height))]]]
        }
        let size = p.numbers("size")
        if let size, size.count != 2 || size.contains(where: { $0 < 320 || $0 > 4096 }) {
            throw CommandError.invalid("\(id): size is [width, height] in points, each 320…4096")
        }
        if let n = p.int("tabs"), !(1...6).contains(n) { throw CommandError.invalid("\(id): tabs is 1…6") }
        let output: URL
        if let path = p.string("path") { output = try Render.output(path, command: id) }
        else { output = try Previews.directory().appendingPathComponent("ui-\(UUID().uuidString.prefix(8)).png") }
        let px = try ui.screenshot(workspace: p.string("workspace"), width: size.map { Int($0[0]) }, height: size.map { Int($0[1]) },
                                   canvas: p.json("canvas"), record: p.json("record"), voice: p.json("voice"), tabs: p.int("tabs"),
                                   inspector: p.json("inspector"), texts: p.json("texts"), jobs: p.json("jobs"), audio: p.json("audio"),
                                   simple: p.json("simple"), to: output)
        return ["path": .string(output.path), "width": .number(Double(px.width)), "height": .number(Double(px.height)),
                "host": "app", "shown": px.shown, "images": [["path": .string(output.path), "mimeType": "image/png",
                                           "width": .number(Double(px.width)), "height": .number(Double(px.height))]]]
    }
}

enum PreviewFrame: Command {
    static let id = "preview.frame"
    static let summary = "The frame the app's live preview player shows at a timeline time (AVPlayer through the export compositor), as a PNG at the output size — to check that preview = export against frame.render. Only when the app is running. Returns the path."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("time", .time, "Timeline time (snapped to the frame grid)."),
        .required("path", .string, "Output .png."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let ui = try UIRequire.host(ctx, command: id)
        let rate = project.settings.frameRate
        let last = max(project.duration - MediaTime.frameDuration(at: rate), .zero)
        let time = min(p.requiredTime("time").snapped(to: rate), last)
        let output = try Render.output(p.requiredString("path"), command: id)
        let px = try ui.previewFrame(at: time, to: output)
        return ["path": .string(output.path), "time": ProjectState.seconds(time),
                "width": .number(Double(px.width)), "height": .number(Double(px.height))]
    }
}
