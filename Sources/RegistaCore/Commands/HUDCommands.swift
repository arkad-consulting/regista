import Foundation

enum StatusAdd: Command {
    static let id = "status.add"
    static let summary = "The 'live editing' status row at the top of a reel (round-3 reference ad): on the left a pill with a pulsing REC dot, a label (\"EDITING LIVE\") and a running timer; on the right a numbered chapter badge (\"02 EFFECTS\") that slides in at each chapter. Chapters come from you — one per section of the script, at the second the section starts. timerRate > 1 makes a fast 'session clock' (e.g. 8 = the timer runs 8× real time). Mono type, dark glass pills, brand accent. Returns the clip."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("label", .string, "Text after the REC dot (default EDITING LIVE; keep it 1–3 words, the reel's language)."),
        .optional("chapters", .array(.object), "[{at: timeline seconds, label: \"EFFECTS\"}, …] — numbered 01, 02… in order."),
        .optional("start", .time, "Timeline start (default 0)."),
        .optional("end", .time, "Timeline end (default: the end of the picture)."),
        .optional("timerStart", .number, "Seconds the timer shows at the start (default 0)."),
        .optional("timerRate", .number, "Timer seconds per real second (default 1)."),
        .optional("color", .string, "Accent (#RRGGBB or a brand role; default the kit's highlight, else #FF7A1A)."),
        .optional("y", .number, "Top of the row, px on a 1080×1920 frame (default 128, just under Instagram's account bar)."),
        .optional("trackId", .string, "Overlay track (default: a free one)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let rate = project.settings.frameRate
        let start = (p.time("start") ?? .zero).snapped(to: rate)
        let end = (p.time("end") ?? project.pictureEnd).snapped(to: rate)
        guard end > start else { throw CommandError.invalid("\(id): end must be after start (is there a picture on the timeline?)") }
        let brand = project.brand
        let color = p.string("color").map { brand?.color($0) ?? $0 } ?? brand?.colors["highlight"] ?? "#FF7A1A"
        var chapters: [ShapeChapter] = []
        for row in p.json("chapters")?.arrayValue ?? [] {
            guard let at = row["at"]?.doubleValue, let label = row["label"]?.stringValue else {
                throw CommandError.invalid("\(id): each chapter needs at (seconds) and label")
            }
            chapters.append(ShapeChapter(at: max(at - start.seconds, 0), label: label))
        }
        chapters.sort { $0.at < $1.at }
        // The row stays left of Instagram's action rail.
        let y = (p.number("y") ?? 128) / SafeZones.referenceHeight
        var shape = ShapeLayer(kind: .statusBar, rect: [0.04, y, 1 - 0.04 - (SafeZones.rightMargin + 40) / SafeZones.referenceWidth, 0.035], color: color, width: 0, drawOn: 0)
        shape.label = p.string("label") ?? "EDITING LIVE"
        shape.chapters = chapters.isEmpty ? nil : chapters
        shape.timerStart = p.number("timerStart")
        shape.timerRate = p.number("timerRate")
        let t = try Graphics.track("overlays", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: end - start, start: start)
        clip.shape = shape
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        return ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id),
                "chapters": .array(chapters.enumerated().map { i, c in
                    ["number": .string(String(format: "%02d", i + 1)), "label": .string(c.label), "at": .number(c.at + start.seconds)]
                })]
    }
}

enum MetersAdd: Command {
    static let id = "meters.add"
    static let summary = "Stereo L/R level meters (segmented bars, green → yellow → accent at the top, a falling peak-hold tick) driven by the real sound of the edit: the audio tracks are mixed and measured every 1/30 s (RMS and peak, −48…0 dBFS). Default placement: one pair on each side of the speaker's card when a layout box is on screen (layout.speaker inset-frame), else at the frame's left and right margins mid-height. Use it on a sound beat (music, an effect, 'listen to this'), a few seconds, not the whole reel. Returns the clip and the loudest moment."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("start", .time, "Timeline start (default 0)."),
        .optional("end", .time, "Timeline end (default start + 6 s, at most the end of the picture)."),
        .optional("rect", .array(.number), "[x, y, w, h] px on a 1080×1920 frame: the left pair at x, the right pair at x + w (default: beside the speaker's card)."),
        .optional("color", .string, "Top segments (#RRGGBB or a brand role; default the kit's highlight, else #FF7A1A)."),
        .optional("trackId", .string, "Overlay track (default: a free one)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let rate = project.settings.frameRate
        let start = (p.time("start") ?? .zero).snapped(to: rate)
        let end = min(p.time("end") ?? start + MediaTime(seconds: 6), project.pictureEnd).snapped(to: rate)
        guard end > start else { throw CommandError.invalid("\(id): end must be after start") }
        guard project.tracks.contains(where: { $0.kind == .audio && !$0.muted && !$0.clips.isEmpty }) else {
            throw CommandError.conflict("\(id): no sound on the timeline (the meters read the audio tracks)")
        }
        // Mix the audio tracks over the window, then RMS / peak per channel every 1/30 s.
        let sampleRate = 24_000
        let length = Int((project.duration.seconds * Double(sampleRate)).rounded())
        let wav = try ctx.mediaDirectory().appendingPathComponent("meters-\(UUID().uuidString.prefix(6)).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let audioTracks = Set(project.tracks.filter { $0.kind == .audio && !$0.muted }.map(\.id))
        try ctx.services.audio.mix(AudioPlan.clips(project, rate: sampleRate, tracks: audioTracks), length: length, rate: sampleRate, gain: 0, ceiling: 0, to: wav)
        let audio = try WAVAudio.read(wav)
        let levelRate = 30.0
        let ch = max(audio.channels, 1)
        let window = Int(Double(audio.sampleRate) / levelRate)
        func db(_ v: Double) -> Double { min(max((20 * log10(max(v, 1e-6)) + 48) / 48, 0), 1) }
        var levels: [[Double]] = []
        var loudest = (t: start.seconds, v: 0.0)
        var i0 = Int(start.seconds * Double(audio.sampleRate))
        let i1 = min(Int(end.seconds * Double(audio.sampleRate)), audio.frameCount)
        while i0 < i1 {
            var sum = [0.0, 0.0], peak = [0.0, 0.0]
            let n = min(window, i1 - i0)
            for f in i0..<(i0 + n) {
                for c in 0..<2 {
                    let v = Double(audio.samples[f * ch + min(c, ch - 1)])
                    sum[c] += v * v
                    peak[c] = max(peak[c], abs(v))
                }
            }
            let rms = sum.map { ($0 / Double(max(n, 1))).squareRoot() }
            // RMS reads ~10 dB under the peak: a small lift so speech fills the green part.
            let row = [db(rms[0] * 2), db(rms[1] * 2), db(peak[0]), db(peak[1])].map { ($0 * 100).rounded() / 100 }
            if row[0] > loudest.v { loudest = (Double(i0) / Double(audio.sampleRate), row[0]) }
            levels.append(row)
            i0 += window
        }
        // Placement: beside the speaker's card when one is on screen, else the frame margins.
        let W = Double(project.settings.width), H = Double(project.settings.height)
        let kx = W / SafeZones.referenceWidth, ky = H / SafeZones.referenceHeight
        var rect: [Double]
        if let r = p.numbers("rect"), r.count == 4 { rect = [r[0] * kx / W, r[1] * ky / H, r[2] * kx / W, r[3] * ky / H] }
        else {
            let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
            let mid = (start + MediaTime(seconds: (end - start).seconds / 2)).snapped(to: rate)
            if let card = job.layers(at: mid).last(where: { $0.placement?.fit == .box && $0.source == .video })?.box(width: Int(W), height: Int(H)) {
                let pairW = 74 * kx, gap = 26 * kx
                let x = max(card[0] - gap - pairW, 16 * kx), right = min(card[0] + card[2] + gap + pairW, W - 16 * kx)
                rect = [x / W, (card[1] + 0.12 * card[3]) / H, (right - x) / W, 0.55 * card[3] / H]
            } else {
                rect = [40 * kx / W, 0.32, (W - SafeZones.rightMargin * kx - 60 * kx) / W, 0.3]
            }
        }
        let brand = project.brand
        let color = p.string("color").map { brand?.color($0) ?? $0 } ?? brand?.colors["highlight"] ?? "#FF7A1A"
        var shape = ShapeLayer(kind: .audioMeters, rect: rect, color: color, width: 0, drawOn: 0)
        shape.levels = levels
        shape.levelRate = levelRate
        let t = try Graphics.track("overlays", in: &project, start: start, end: end, preferred: p.string("trackId"))
        var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: end - start, start: start)
        clip.shape = shape
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        return ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id), "samples": .number(Double(levels.count)),
                "channels": .number(Double(audio.channels)), "loudestAt": .number((loudest.t * 100).rounded() / 100),
                "rect": .array(rect.enumerated().map { i, v in .number((v * (i % 2 == 0 ? SafeZones.referenceWidth : SafeZones.referenceHeight)).rounded()) })]
    }
}
