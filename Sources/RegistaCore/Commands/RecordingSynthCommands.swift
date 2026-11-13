import Foundation

enum RecordingSynthesize: Command {
    static let id = "recording.synthesize"
    static let summary = "Write a synthetic screen-recording session for tests, in exactly the format of a real Registra recording: screen.mov (an animated desktop with an editor and a browser window, the session clock, a moving cursor and click ripples), camera.mov (a stretch of a real camera take), mic.wav (its sound), session.json with sources and their offsets on the common clock, clicks, a keystroke, cursor samples, a pause entry and sync slates (white screen frames, a camera flash frame and a 1 kHz beep at the same session instants). Offsets default to screen 0, camera 0.25 s (7.5 frames: sub-frame on purpose), mic 0.18 s. cursor: false records the take as Registra does with the system cursor hidden: no cursor or ripples in screen.mov, cursorInVideo false, a mouseUp after each click, one drag (press 6.2 s, release 7.0 s) and the cursor kind per sample (pointingHand over the buttons), so the compositor draws the cursor (cursor.style). sources: [\"screen\"] writes a screen-only take (no camera.mov, no mic.wav: Registra with the camera and microphone switched off). Returns the session path and what it contains."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("directory", .string, "Folder to write the session into (created; existing files are replaced)."),
        .optional("camera", .string, "A camera take with sound (video + audio), e.g. a talking-head .MOV. Required when sources include camera or mic."),
        .optional("sources", .array(.string), "Which sources the session holds: screen, camera, mic (default all three; screen is always there)."),
        .optional("cameraIn", .time, "Where the camera stretch starts in the take, seconds (default 0)."),
        .optional("duration", .number, "Session length, seconds (default 14)."),
        .optional("screenSize", .array(.integer), "[width, height] of screen.mov (default [1920, 1080])."),
        .optional("fps", .integer, "Screen frame rate (default 60)."),
        .optional("screenOffset", .number, "Session time of the first screen frame (default 0)."),
        .optional("cameraOffset", .number, "Session time of the first camera frame (default 0.25)."),
        .optional("micOffset", .number, "Session time of the first mic sample (default 0.18)."),
        .optional("syncMarks", .integer, "Number of sync slates (default 3)."),
        .optional("cursor", .boolean, "Draw the cursor into screen.mov (default true; false = recorded without the system cursor)."),
    ]

    static let cameraFPS = 30.0

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        guard let synth = ctx.services.screenSynth else {
            throw CommandError(.io, "\(id): this host cannot draw the synthetic screen (use regista-engine / regista-mcp)")
        }
        let dir = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("directory"))).standardizedFileURL
        let ids = p.strings("sources") ?? ["screen", "camera", "mic"]
        guard ids.contains("screen"), Set(ids).isSubset(of: ["screen", "camera", "mic"]) else {
            throw CommandError.invalid("\(id): sources is a list of screen, camera, mic and always holds screen")
        }
        let withCamera = ids.contains("camera"), withMic = ids.contains("mic")
        let take = URL(fileURLWithPath: EngineConfig.expand(p.string("camera") ?? "")).standardizedFileURL
        if withCamera || withMic {
            guard p.string("camera") != nil else { throw CommandError.invalid("\(id): camera (a take with sound) is needed for the camera and mic sources") }
            guard FileManager.default.fileExists(atPath: take.path) else { throw CommandError.notFound("\(id): no camera take at \(take.path)") }
        }
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw CommandError(.io, "\(id): cannot create \(dir.path): \(error.localizedDescription)") }
        let duration = p.number("duration") ?? 14
        guard duration >= 4, duration <= 600 else { throw CommandError.invalid("\(id): duration must be 4…600 s") }
        let size = p.numbers("screenSize") ?? [1920, 1080]
        guard size.count == 2, size[0] >= 320, size[1] >= 240 else { throw CommandError.invalid("\(id): screenSize must be [w, h] ≥ [320, 240]") }
        let (sw, sh) = (Int(size[0]) / 2 * 2, Int(size[1]) / 2 * 2)
        let fps = p.int("fps") ?? 60
        guard [24, 25, 30, 50, 60].contains(fps) else { throw CommandError.invalid("\(id): fps must be 24, 25, 30, 50 or 60") }
        let oS = p.number("screenOffset") ?? 0, oC = p.number("cameraOffset") ?? 0.25, oM = p.number("micOffset") ?? 0.18
        guard [oS, oC, oM].allSatisfy({ $0 >= 0 && $0 < duration / 2 }) else { throw CommandError.invalid("\(id): offsets must be ≥ 0 and well inside the duration") }
        let cameraIn = ((p.time("cameraIn")?.seconds ?? 0) * cameraFPS).rounded() / cameraFPS
        guard !withMic || cameraIn + oM - oC >= 0 else { throw CommandError.invalid("\(id): cameraIn must be ≥ cameraOffset − micOffset (the mic starts earlier)") }
        let ffmpeg = ctx.services.config.url(ctx.services.config.ffmpeg)

        // Clicks (session time, pixels) and sync slates on camera frames (so every source can show them exactly).
        let clicks = SyntheticSession.defaultClicks.filter { $0.t < duration - 1.6 }
        let clickPx = clicks.map { (t: $0.t, x: ($0.x * Double(sw)).rounded(), y: ($0.y * Double(sh)).rounded()) }
        let drawsCursor = p.bool("cursor") ?? true
        let d = SyntheticSession.defaultDrag
        let drags = drawsCursor || d.t1 > duration - 1.6 ? [] : [(t0: d.t0, t1: d.t1, x0: (d.x0 * Double(sw)).rounded(), y0: (d.y0 * Double(sh)).rounded(),
                                                                  x1: (d.x1 * Double(sw)).rounded(), y1: (d.y1 * Double(sh)).rounded())]
        let markCount = max(p.int("syncMarks") ?? 3, 0)
        let markTargets: [Double] = markCount == 0 ? [] : (0..<markCount).map { k in
            markCount == 1 ? oC + 1 : oC + 0.8 + (duration - oC - 2.8) * Double(k) / Double(markCount - 1)
        }
        let markFrames = markTargets.map { Int((($0 - oC) * cameraFPS).rounded()) }
        let marks = markFrames.map { oC + Double($0) / cameraFPS }

        // screen.mov.
        let frames = Int(((duration - oS) * Double(fps)).rounded(.down))
        let perFlash = max(fps / 30, 1)
        var flashes = Set<Int>()
        for s in marks {
            let g0 = Int(((s - oS) * Double(fps) - 1e-6).rounded(.up))
            for k in 0..<perFlash { flashes.insert(g0 + k) }
        }
        let cursor = (0..<frames).map {
            SyntheticSession.cursor(at: oS + Double($0) / Double(fps), clicks: clickPx, width: Double(sw), height: Double(sh), drags: drags)
        }
        let buttons = zip(clicks, clickPx).compactMap { c, px in c.label.map { SyntheticScreen.Button(x: px.x, y: px.y, label: $0) } }
        let screenURL = dir.appendingPathComponent("screen.mov")
        var screenDesc = SyntheticScreen(width: sw, height: sh, fps: fps, frames: frames, cursor: cursor,
                                         clicks: clickPx.map { ZoomClick(t: $0.t - oS, x: $0.x, y: $0.y) }, buttons: buttons,
                                         flashes: flashes, clockOffset: oS, output: screenURL)
        screenDesc.drawsCursor = drawsCursor
        try synth.write(screenDesc)

        // camera.mov: the take from cameraIn, constant 30 fps, a brightness flash on each slate frame, no sound.
        let cameraURL = dir.appendingPathComponent("camera.mov")
        let micURL = dir.appendingPathComponent("mic.wav")
        for (on, url) in [(withCamera, cameraURL), (withMic, micURL)] where !on { try? FileManager.default.removeItem(at: url) }
        if withCamera {
            let enable = markFrames.map { "eq(n\\,\($0))" }.joined(separator: "+")
            let flash = markFrames.isEmpty ? "" : ",eq=brightness=0.45:enable='\(enable)'"
            try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-ss", String(format: "%.6f", cameraIn), "-i", take.path, "-t", String(format: "%.6f", duration - oC),
                                                              "-an", "-vf", "fps=\(Int(cameraFPS))\(flash),format=yuv420p", "-c:v", "libx264",
                                                              "-preset", "veryfast", "-crf", "17", "-movflags", "+faststart", cameraURL.path])
        }
        if withMic {
            // mic.wav: the take's sound in sync with the camera stretch (it starts earlier by cameraOffset − micOffset), beeps on the slates.
            let raw = dir.appendingPathComponent("mic-raw.wav")
            defer { try? FileManager.default.removeItem(at: raw) }
            try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-ss", String(format: "%.6f", cameraIn + oM - oC), "-i", take.path, "-t", String(format: "%.6f", duration - oM),
                                                              "-vn", "-ac", "1", "-ar", "48000", "-c:a", "pcm_s16le", raw.path])
            var mic = try WAVAudio.read(raw)
            for s in marks { beep(&mic.samples, at: Int(((s - oM) * 48000).rounded()), rate: 48000) }
            try mic.write16(to: micURL)
        }

        // session.json.
        var screen = RecordingSession.Source(id: "screen", file: "screen.mov", offset: oS)
        screen.device = "Schermo sintetico"; screen.width = sw; screen.height = sh; screen.fps = Double(fps)
        screen.region = [0, 0, Double(sw) / 2, Double(sh) / 2]; screen.scale = 2
        var camera = RecordingSession.Source(id: "camera", file: "camera.mov", offset: oC)
        camera.device = take.lastPathComponent; camera.fps = cameraFPS
        var micSource = RecordingSession.Source(id: "mic", file: "mic.wav", offset: oM)
        micSource.device = "Microfono (dal take)"; micSource.sampleRate = 48000; micSource.channels = 1
        let iso = ISO8601DateFormatter()
        var session = RecordingSession(app: "regista-engine recording.synthesize", created: iso.string(from: Date()), duration: duration,
                                       sources: [screen] + (withCamera ? [camera] : []) + (withMic ? [micSource] : []))
        session.synthetic = true
        session.events = clickPx.map { RecordingSession.Event(kind: "click", t: $0.t, x: $0.x, y: $0.y) }
            + [RecordingSession.Event(kind: "key", t: min(5.2, duration - 1), key: "cmd+s")]
        // Presses: (down, up) in session time; without the cursor in the video the take logs mouse-ups, the button state
        // and the cursor kind, like Registra with the cursor hidden.
        let presses = drawsCursor ? [] : clickPx.map { (t0: $0.t, t1: $0.t + 0.09) } + drags.map { (t0: $0.t0, t1: $0.t1) }
        if !drawsCursor {
            session.cursorInVideo = false
            session.events += drags.map { RecordingSession.Event(kind: "click", t: $0.t0, x: $0.x0, y: $0.y0) }
            session.events += presses.map { p in
                let at = SyntheticSession.cursor(at: p.t1, clicks: clickPx, width: Double(sw), height: Double(sh), drags: drags)
                return RecordingSession.Event(kind: "mouseUp", t: p.t1, x: at[0].rounded(), y: at[1].rounded())
            }
        }
        session.events.sort { $0.t < $1.t }
        let hand = 70.0 * Double(sw) / 1920
        session.cursor = stride(from: 0, to: frames, by: max(fps / 30, 1)).map { i in
            let t = oS + Double(i) / Double(fps)
            var sample = RecordingSession.CursorSample(t: t, x: (cursor[i][0] * 10).rounded() / 10, y: (cursor[i][1] * 10).rounded() / 10)
            if !drawsCursor {
                if buttons.contains(where: { hypot($0.x - cursor[i][0], $0.y - cursor[i][1]) < hand }) { sample.kind = CursorKind.pointingHand.rawValue }
                if presses.contains(where: { t >= $0.t0 && t < $0.t1 }) { sample.down = true }
            }
            return sample
        }
        session.pauses = [RecordingSession.Pause(at: duration / 2, duration: 2.4)]
        session.layout = LayoutSpec(kind: .bubble)
        session.syncMarks = marks
        let sessionURL = dir.appendingPathComponent(RecordingSession.fileName)
        try session.write(to: sessionURL)
        return ["session": .string(sessionURL.path), "directory": .string(dir.path), "duration": .number(duration),
                "files": .object(["screen": .string(screenURL.path), "camera": withCamera ? .string(cameraURL.path) : nil,
                                  "mic": withMic ? .string(micURL.path) : nil].compactMapValues { $0 }),
                "sources": .array(session.sources.map { .string($0.id) }),
                "screen": ["width": .number(Double(sw)), "height": .number(Double(sh)), "fps": .number(Double(fps)), "frames": .number(Double(frames))],
                "offsets": ["screen": .number(oS), "camera": .number(oC), "mic": .number(oM)],
                "clicks": .array(clickPx.map { ["t": .number($0.t), "x": .number($0.x), "y": .number($0.y)] }),
                "cursorInVideo": .bool(drawsCursor), "drags": .number(Double(session.drags.count)),
                "syncMarks": .array(marks.map { Analysis.seconds($0, places: 1_000_000) })]
    }

    /// A 80 ms 1 kHz tone at −6 dBFS with 2 ms ramps, added at sample `at`.
    static func beep(_ x: inout [Float], at: Int, rate: Int) {
        let n = rate * 80 / 1000, ramp = rate * 2 / 1000
        for i in 0..<n where at + i >= 0 && at + i < x.count {
            let env = Float(min(1, Double(min(i, n - 1 - i)) / Double(ramp)))
            x[at + i] = max(-1, min(1, x[at + i] * 0.3 + 0.5 * env * Float(sin(2 * Double.pi * 1000 * Double(i) / Double(rate)))))
        }
    }
}
