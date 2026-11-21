import Accelerate
import Foundation

// Music bed with ducking, sound effects, and the checks for both (issue #5, X1 audio).

enum AudioTracks {
    /// The speech track: the first unmuted audio track that is not music or SFX.
    static func voice(_ project: Project) -> Track? {
        project.tracks.first { $0.kind == .audio && $0.role == nil && !$0.clips.isEmpty }
    }

    /// An audio track with `role` free over [start, end), created (named `name`) when none is.
    static func track(_ role: String, name: String, in project: inout Project, start: MediaTime, end: MediaTime) -> Int {
        if let t = project.tracks.firstIndex(where: { $0.kind == .audio && $0.role == role && !$0.locked && $0.overlap(start: start, end: end) == nil }) {
            return t
        }
        let count = project.tracks.filter { $0.role == role }.count
        var track = Track(id: project.makeID("t"), kind: .audio, name: count == 0 ? name : "\(name) \(count + 1)")
        track.role = role
        project.tracks.append(track)
        return project.tracks.count - 1
    }

    /// Imports an audio file (or reuses its asset).
    static func importAudio(_ path: String, into project: inout Project, _ ctx: CommandContext, command: String) throws -> MediaAsset {
        let url = URL(fileURLWithPath: EngineConfig.expand(path)).standardizedFileURL
        if let a = project.assets.first(where: { $0.path == url.path }) { return a }
        guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError.notFound("\(command): no file at \(url.path)") }
        let info = try ctx.prober.probe(url)
        guard info.audio != nil else { throw CommandError.conflict("\(command): \(url.lastPathComponent) has no audio") }
        let asset = MediaAsset(id: project.makeID("a"), name: url.lastPathComponent, path: url.path, duration: info.duration, video: nil, audio: info.audio)
        project.assets.append(asset)
        return asset
    }

    static func db(_ x: Double) -> JSONValue { .number((x * 10).rounded() / 10) }
}

/// One sound effect: from the bank shipped with Regista (`Resources/SFX`, rendered from earshot, MIT) or from the user's
/// own folder (`sfxLibrary` in engines.json: mp3 / wav files + an optional manifest.json).
public struct SoundEffect: Sendable, Hashable {
    /// The id sfx.add takes: "whoosh_fast/crisp" in the bank, the file's name in the user's folder.
    public let name: String
    public let path: String
    public let duration: Double?
    public let description: String?
    /// The bank's group (whoosh, ui, pop, impact, rise, chime, logo, glitch, typing); nil for the user's sounds.
    public let group: String?
    /// earshot's category (whoosh_fast, pro_click …); nil for the user's sounds.
    public let category: String?
    /// Seconds from the start of the file to the first sound and to the loudest moment (bank only).
    public let onset: Double?
    public let peak: Double?
    /// "bank" or "user".
    public let source: String
}

public enum SoundLibrary {
    /// The bank's groups, in the browser's order.
    public static let groups = ["whoosh", "ui", "pop", "impact", "rise", "chime", "logo", "glitch", "typing"]

    /// The shipped bank's folder (in the app bundle, else in the source tree).
    public static var bankDirectory: URL { URL(fileURLWithPath: BrandKit.bundled("SFX")) }

    private static let cache = BankCache()

    /// The shipped bank: every sound of Resources/SFX/manifest.json whose file is there.
    public static func bank() -> [SoundEffect] { cache.load(bankDirectory) }

    /// The user's own folder (empty when there is none).
    public static func user(_ config: EngineConfig) -> [SoundEffect] {
        let dir = config.url(config.sfxLibrary)
        var out: [SoundEffect] = []
        if let data = FileManager.default.contents(atPath: dir.appendingPathComponent("manifest.json").path),
           let manifest = try? JSONValue.parse(data).objectValue {
            for (name, v) in manifest.sorted(by: { $0.key < $1.key }) {
                guard let file = v["file"]?.stringValue else { continue }
                out.append(SoundEffect(name: name, path: dir.appendingPathComponent(file).path, duration: v["duration"]?.doubleValue,
                                       description: v["description"]?.stringValue, group: nil, category: nil, onset: nil, peak: nil,
                                       source: "user"))
            }
        }
        if out.isEmpty {
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { [".mp3", ".wav", ".m4a", ".flac"].contains(where: $0.hasSuffix) }
            out = files.sorted().map {
                SoundEffect(name: URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent, path: dir.appendingPathComponent($0).path,
                            duration: nil, description: nil, group: nil, category: nil, onset: nil, peak: nil, source: "user")
            }
        }
        return out
    }

    /// The user's sounds first (a name of theirs hides a bank sound with the same name), then the bank.
    public static func all(_ config: EngineConfig) -> [SoundEffect] {
        let mine = user(config)
        let names = Set(mine.map(\.name))
        return mine + bank().filter { !names.contains($0.name) }
    }

    /// Reads a bank manifest once per folder.
    private final class BankCache: @unchecked Sendable {
        private let lock = NSLock()
        private var loaded: [String: [SoundEffect]] = [:]

        func load(_ dir: URL) -> [SoundEffect] {
            lock.lock(); defer { lock.unlock() }
            if let hit = loaded[dir.path] { return hit }
            var out: [(SoundEffect, Int)] = []
            if let data = FileManager.default.contents(atPath: dir.appendingPathComponent("manifest.json").path),
               let sounds = (try? JSONValue.parse(data))?["sounds"]?.objectValue {
                for (name, v) in sounds {
                    guard let file = v["file"]?.stringValue else { continue }
                    let path = dir.appendingPathComponent(file).path
                    guard FileManager.default.fileExists(atPath: path) else { continue }
                    out.append((SoundEffect(name: name, path: path, duration: v["duration"]?.doubleValue, description: v["description"]?.stringValue,
                                           group: v["group"]?.stringValue, category: v["category"]?.stringValue,
                                           onset: v["onset"]?.doubleValue, peak: v["peak"]?.doubleValue, source: "bank"),
                               Int(v["order"]?.doubleValue ?? 99)))
                }
            }
            // By group, then the category order the manifest gives (the common sounds first), then by name.
            let groupOrder = Dictionary(uniqueKeysWithValues: SoundLibrary.groups.enumerated().map { ($1, $0) })
            out.sort { (groupOrder[$0.0.group ?? ""] ?? 99, $0.1, $0.0.name) < (groupOrder[$1.0.group ?? ""] ?? 99, $1.1, $1.0.name) }
            let sounds = out.map(\.0)
            loaded[dir.path] = sounds
            return sounds
        }
    }
}

enum AudioAddMusic: Command {
    static let id = "audio.addMusic"
    static let summary = "Lay a music bed on its own track (Music, A2), levelled to a loudness (default −22 LUFS un-ducked), looped to the end if short, faded in/out, and ducked automatically under the voice: the speech regions of the voice track (its words) lower it by `duck` dB (default −12, so the music sits ~19 dB under a −15 LUFS voice while someone speaks) with smooth attack/release. House rule: no music unless asked (Instagram trending audio is added in the app); when used, keep it subtle. Returns the track, clips, gain and the expected level under speech."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("path", .string, "Music file (wav/flac/mp3/m4a)."),
        .optional("start", .time, "Timeline start (default 0)."),
        .optional("end", .time, "Timeline end (default: the end of the timeline)."),
        .optional("sourceIn", .time, "Start inside the music (default 0)."),
        .optional("level", .number, "Loudness of the bed without ducking, LUFS (default -22)."),
        .optional("duck", .number, "Gain under speech, dB (default -12; 0 = no ducking)."),
        .optional("attack", .number, "Seconds to go down before a phrase (default 0.15)."),
        .optional("release", .number, "Seconds to come back after it (default 0.45)."),
        .optional("mergeGap", .number, "Pauses shorter than this stay ducked, seconds (default 0.7)."),
        .optional("voiceTrackId", .string, "Track that triggers the ducking (default: the voice track)."),
        .optional("fadeIn", .time, "Fade-in seconds (default 0.5)."),
        .optional("fadeOut", .time, "Fade-out seconds at the end (default 1.5)."),
        .optional("loop", .boolean, "Repeat the music to fill the range (default true)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let rate = project.settings.frameRate
        let asset = try AudioTracks.importAudio(p.requiredString("path"), into: &project, ctx, command: id)
        let start = (p.time("start") ?? .zero).snapped(to: rate)
        let end = (p.time("end") ?? (project.pictureEnd > .zero ? project.pictureEnd : project.duration)).snapped(to: rate)
        guard end > start else { throw CommandError.invalid("\(id): the range is empty (is the timeline empty?)") }
        let sourceIn = p.time("sourceIn") ?? .zero
        guard sourceIn < asset.duration else { throw CommandError.invalid("\(id): sourceIn is past the end of the music") }
        let measured = try ctx.services.audio.loudness(of: [AudioSpan(url: URL(fileURLWithPath: asset.path), start: sourceIn,
                                                                      channels: asset.audio?.channels ?? 2)])
        let level = p.number("level") ?? -22
        let gain = measured.integrated.isFinite ? level - measured.integrated : 0

        var voiceID = p.string("voiceTrackId")
        if voiceID == nil { voiceID = AudioTracks.voice(project)?.id }
        let t = AudioTracks.track("music", name: "Music", in: &project, start: start, end: end)
        // Fill [start, end): copies back to back, 30 ms fades at the seams.
        var clips: [Clip] = []
        var cursor = start, src = sourceIn
        let seam = MediaTime(seconds: 0.03)
        while cursor < end {
            let length = min(asset.duration - src, end - cursor)
            guard length > MediaTime(seconds: 0.1) else { break }
            var c = Clip(id: project.makeID("c"), assetID: asset.id, sourceIn: src, sourceOut: src + length, start: cursor)
            c.gain = gain
            c.fadeIn = clips.isEmpty ? (p.time("fadeIn") ?? MediaTime(seconds: 0.5)) : seam
            c.fadeOut = seam
            clips.append(c)
            cursor += length
            src = .zero
            if !(p.bool("loop") ?? true) { break }
        }
        guard !clips.isEmpty else { throw CommandError.invalid("\(id): nothing of the music fits the range") }
        clips[clips.count - 1].fadeOut = min(p.time("fadeOut") ?? MediaTime(seconds: 1.5), clips[clips.count - 1].duration)
        for c in clips { try Timeline.checkFree(project.tracks[t], start: c.start, end: c.end) }
        project.tracks[t].clips += clips
        project.tracks[t].sortClips()
        let duck = p.number("duck") ?? -12
        var regions = 0
        if duck < 0, let v = voiceID {
            guard let source = project.tracks.first(where: { $0.id == v }) else { throw CommandError.notFound("\(id): no track \(v)") }
            var d = Ducking(sourceTrack: v, depth: duck)
            if let a = p.number("attack") { d.attack = max(a, 0.01) }
            if let r = p.number("release") { d.release = max(r, 0.01) }
            if let g = p.number("mergeGap") { d.mergeGap = max(g, 0) }
            project.tracks[t].ducking = d
            regions = DuckingEnvelope.regions(of: source, in: project, mergeGap: d.mergeGap).count
        }
        ctx.project = project
        return ["trackId": .string(project.tracks[t].id), "clips": .array(clips.map(ProjectState.summary(of:))),
                "measuredLUFS": AudioTracks.db(measured.integrated), "gain": AudioTracks.db(gain), "level": AudioTracks.db(level),
                "duck": AudioTracks.db(duck), "speechRegions": .number(Double(regions)),
                "underSpeechLUFS": AudioTracks.db(level + min(duck, 0))]
    }
}

enum AudioDuck: Command {
    static let id = "audio.duck"
    static let summary = "Change (or remove) the automatic ducking of an audio track: which track triggers it, depth, attack, release, merge gap. Returns the track."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("trackId", .string, "The track to duck (the music)."),
        .optional("voiceTrackId", .string, "Trigger track (default: the current one, or the voice track)."),
        .optional("duck", .number, "Gain under speech, dB (0 removes the ducking)."),
        .optional("attack", .number, "Seconds."),
        .optional("release", .number, "Seconds."),
        .optional("mergeGap", .number, "Seconds."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let t = try Timeline.trackIndex(p.requiredString("trackId"), in: project)
        guard project.tracks[t].kind == .audio else { throw CommandError.conflict("\(id): \(project.tracks[t].name) is not an audio track") }
        guard let source = p.string("voiceTrackId") ?? project.tracks[t].ducking?.sourceTrack ?? AudioTracks.voice(project)?.id else {
            throw CommandError.conflict("\(id): no voice track to follow")
        }
        var d = project.tracks[t].ducking ?? Ducking(sourceTrack: source)
        d.sourceTrack = source
        if let v = p.number("duck") { d.depth = v }
        if let v = p.number("attack") { d.attack = max(v, 0.01) }
        if let v = p.number("release") { d.release = max(v, 0.01) }
        if let v = p.number("mergeGap") { d.mergeGap = max(v, 0) }
        project.tracks[t].ducking = d.depth < 0 ? d : nil
        ctx.project = project
        return ["track": ProjectState.summary(of: project.tracks[t])]
    }
}

enum SFXLibrary: Command {
    static let id = "sfx.library"
    static let summary = "List the sound effects: the bank shipped with Regista (185 sounds made in code by earshot, MIT: whooshes, UI clicks and taps, pops, impacts and sub drops, risers, chimes and dings, logo stings, glitches, key presses), grouped by use, plus the user's own folder (sfxLibrary in engines.json). Each has a name for sfx.add, its length and what it is for; bank sounds also give the onset and the loudest moment (seconds into the file: put a whoosh's peak on the cut). Taste: sparse, on beats and on-screen events, low volume (0.2–0.3). Returns the effects."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("query", .string, "Only names or descriptions containing this word."),
        .optional("group", .oneOf(SoundLibrary.groups + ["user"]), "Only one group of the bank, or \"user\" for your own folder."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let q = p.string("query")?.lowercased()
        let group = p.string("group")
        let items = SoundLibrary.all(ctx.services.config).filter { i in
            (q == nil || i.name.lowercased().contains(q!) || (i.description ?? "").lowercased().contains(q!))
                && (group == nil || (group == "user" ? i.source == "user" : i.group == group))
        }
        func num(_ v: Double?) -> JSONValue { v.map { .number($0) } ?? .null }
        return ["directory": .string(EngineConfig.expand(ctx.services.config.sfxLibrary)),
                "bank": ["directory": .string(SoundLibrary.bankDirectory.path), "sounds": .number(Double(SoundLibrary.bank().count)),
                         "licence": "MIT (earshot 0.3.0; the fitted sounds from CC0 recordings)"],
                "groups": .array(SoundLibrary.groups.map { .string($0) }),
                "effects": .array(items.map { i in
                    ["name": .string(i.name), "path": .string(i.path), "duration": num(i.duration),
                     "description": i.description.map { .string($0) } ?? .null, "source": .string(i.source),
                     "group": i.group.map { .string($0) } ?? .null, "onset": num(i.onset), "peak": num(i.peak)]
                })]
    }
}

enum SFXAdd: Command {
    static let id = "sfx.add"
    static let summary = "Place a sound effect at a timeline time on an SFX track (A3; another SFX track is added when effects overlap), by library name (sfx.library: the shipped bank or your folder) or file path, with a volume. Put it on the frame of the visual event (a title landing, a cut, a card pop). Returns the clip and track."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("at", .time, "Timeline time of the effect's start."),
        .optional("name", .string, "Library name from sfx.library (e.g. whoosh_fast/crisp, pro_pop_in/round, click/soft)."),
        .optional("path", .string, "Audio file instead of a library name."),
        .optional("volume", .number, "Linear gain (default 0.3; 0.2–0.3 sits under the voice)."),
        .optional("gain", .number, "Gain in dB instead of volume."),
        .optional("duration", .time, "Cut the effect after this many seconds (fades out the last 30 ms). Effects are always cut at the end of the picture."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let path: String
        if let file = p.string("path") { path = file }
        else if let name = p.string("name") {
            let lib = SoundLibrary.all(ctx.services.config)
            guard let item = lib.first(where: { $0.name == name }) else {
                let word = name.split(separator: "/").first.map(String.init) ?? name
                let near = lib.map(\.name).filter { $0.contains(word) }.prefix(8)
                throw CommandError.notFound("\(id): no effect \"\(name)\" in the library (\(near.isEmpty ? "sfx.library lists \(lib.count)" : "close: " + near.joined(separator: ", ")))")
            }
            path = item.path
        } else { throw CommandError.invalid("\(id): pass name or path") }
        let asset = try AudioTracks.importAudio(path, into: &project, ctx, command: id)
        // Sample-accurate placement: SFX are not snapped to the frame grid.
        let at = p.requiredTime("at")
        var length = asset.duration
        if let d = p.time("duration") { length = min(d, length) }
        // A tail past the end of the picture would lengthen the reel: cut it there (with a short fade).
        let pictureEnd = project.pictureEnd
        let cut = pictureEnd > at && at + length > pictureEnd
        if cut { length = pictureEnd - at }
        guard length > .zero else { throw CommandError.invalid("\(id): empty effect") }
        let t = AudioTracks.track("sfx", name: "SFX", in: &project, start: at, end: at + length)
        var clip = Clip(id: project.makeID("c"), assetID: asset.id, sourceIn: .zero, sourceOut: length, start: at)
        let gain = p.number("gain") ?? 20 * log10(max(p.number("volume") ?? 0.3, 1e-4))
        clip.gain = gain
        if p.has("duration") || cut { clip.fadeOut = min(MediaTime(seconds: cut ? 0.1 : 0.03), length) }
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        return ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id), "gain": AudioTracks.db(gain)]
    }
}

enum SFXOnCuts: Command {
    static let id = "sfx.onCuts"
    static let summary = "Sound effects in one switch: a soft whoosh (from the shipped bank) on the cuts of the main video track, its loudest moment on the cut, at least 3 s apart and at most 6, quiet (volume 0.2); remove: true takes every sound effect off instead. One undo step either way; running it again on a reel that already has effects changes nothing. Returns the effects placed or removed."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("remove", .boolean, "Remove every sound effect (the clips of the SFX tracks)."),
        .optional("name", .string, "Library name of the sound (default whoosh_fast/crisp)."),
        .optional("volume", .number, "Linear gain (default 0.2)."),
    ]

    static func clips(_ project: Project) -> [String] { project.tracks.filter { $0.role == "sfx" }.flatMap(\.clips).map(\.id) }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        var log: [JSONValue] = []
        let existing = clips(project)
        if p.bool("remove") == true {
            if !existing.isEmpty { try ctx.perform(TimelineDelete.self, ["clipIds": .array(existing.map { .string($0) }), "linked": false], log: &log) }
            return ["removed": .number(Double(existing.count)), "commands": .array(log)]
        }
        guard existing.isEmpty else { return ["placed": 0, "existing": .number(Double(existing.count)), "commands": []] }
        guard let main = project.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }) else {
            throw CommandError.conflict("\(id): no video on the timeline")
        }
        let name = p.string("name") ?? "whoosh_fast/crisp"
        guard let sound = SoundLibrary.all(ctx.services.config).first(where: { $0.name == name }) else {
            throw CommandError.notFound("\(id): no effect \"\(name)\" in the library (sfx.library)")
        }
        let peak = sound.peak ?? 0.1
        var last = -10.0, at: [Double] = []
        for cut in main.clips.dropFirst().map(\.start.seconds) where cut - last >= 3 && at.count < 6 {
            at.append(max(cut - peak, 0))
            last = cut
        }
        guard !at.isEmpty else { throw CommandError.conflict("\(id): no cuts at least 3 s apart (cut the pauses first)") }
        for t in at {
            try ctx.perform(SFXAdd.self, ["name": .string(name), "at": .number((t * 1000).rounded() / 1000), "volume": .number(p.number("volume") ?? 0.2)], log: &log)
        }
        return ["placed": .number(Double(at.count)), "at": .array(at.map { .number($0) }), "commands": .array(log)]
    }
}

enum AudioCheckDucking: Command {
    static let id = "audio.checkDucking"
    static let summary = "Measure the music under the voice: renders the voice and the music stems through the export mix (gains, fades, ducking envelope) and compares their loudness while someone speaks (inside the speech regions) and in the longer pauses. Pass: music at least minUnder dB (default 15) under the voice during speech. Returns both levels and the difference."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Music track (default: the music track)."),
        .optional("minUnder", .number, "Required dB under the voice during speech (default 15)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let music: Track
        if let tid = p.string("trackId") { music = project.tracks[try Timeline.trackIndex(tid, in: project, editable: false)] }
        else {
            guard let m = project.tracks.first(where: { $0.role == "music" && !$0.clips.isEmpty }) else { throw CommandError.conflict("\(id): no music track") }
            music = m
        }
        guard let voice = project.tracks.first(where: { $0.id == (music.ducking?.sourceTrack ?? AudioTracks.voice(project)?.id) }) else {
            throw CommandError.conflict("\(id): no voice track")
        }
        let rate = project.settings.sampleRate
        let length = Int((project.duration.seconds * Double(rate)).rounded())
        let dir = TemporaryFolder.url.appendingPathComponent("regista-duck-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let envelopes = try AudioPlan.writeEnvelopes(project, rate: rate, to: dir)
        func stem(_ t: Track) throws -> [Float] {
            let url = dir.appendingPathComponent("\(t.id).wav")
            try ctx.services.audio.mix(AudioPlan.clips(project, rate: rate, tracks: [t.id], envelopes: envelopes), length: length, rate: rate,
                                       gain: 0, ceiling: 0, to: url)
            return try WAVAudio.read(url).mono()
        }
        let v = try stem(voice), m = try stem(music)
        let regions = DuckingEnvelope.regions(of: voice, in: project, mergeGap: music.ducking?.mergeGap ?? 0.7)
        var gaps: [(Double, Double)] = []
        var last = 0.0
        let release = music.ducking?.release ?? 0.45, attack = music.ducking?.attack ?? 0.15
        for r in regions + [(project.duration.seconds + attack, project.duration.seconds + attack)] {
            if r.0 - attack - (last + release) > 0.5 { gaps.append((last + release, r.0 - attack)) }
            last = r.1
        }
        func loudness(_ x: [Float], _ ranges: [(Double, Double)], name: String) throws -> Double {
            var cut: [Float] = []
            for (a, b) in ranges {
                let lo = max(Int(a * Double(rate)), 0), hi = min(Int(b * Double(rate)), x.count)
                if hi > lo { cut += x[lo..<hi] }
            }
            guard cut.count > rate / 2 else { return -.infinity }
            let url = dir.appendingPathComponent("\(name).wav")
            try WAVAudio(sampleRate: rate, channels: 1, samples: cut).writeFloat(to: url)
            return try ctx.services.audio.loudness(of: [AudioSpan(url: url, channels: 1)]).integrated
        }
        let voiceSpeech = try loudness(v, regions, name: "v-speech"), musicSpeech = try loudness(m, regions, name: "m-speech")
        let musicGaps = try loudness(m, gaps, name: "m-gaps")
        let under = voiceSpeech - musicSpeech
        let minUnder = p.number("minUnder") ?? 15
        return ["pass": .bool(under >= minUnder), "voiceLUFS": AudioTracks.db(voiceSpeech), "musicUnderSpeechLUFS": AudioTracks.db(musicSpeech),
                "underDB": AudioTracks.db(under), "musicInPausesLUFS": musicGaps.isFinite ? AudioTracks.db(musicGaps) : .null,
                "speechRegions": .number(Double(regions.count)), "pauses": .number(Double(gaps.count)), "minUnder": .number(minUnder)]
    }
}

enum SFXCheckOnsets: Command {
    static let id = "sfx.checkOnsets"
    static let summary = "Verify that every sound effect lands on its time in a rendered file: the rest of the mix (voice, music and any other effect sounding in the window: same mixer) is subtracted from the render's sound around each effect, then the effect's first 300 ms from its own onset are matched against that residual (normalized cross-correlation, ±80 ms) at the expected position. Pass: every effect found (correlation ≥ minCorrelation) and within `tolerance` frames (default 1). Returns per-effect lag (ms, frames) and correlation."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .required("path", .string, "Rendered video or audio."),
        .optional("tolerance", .number, "Frames (default 1)."),
        .optional("minCorrelation", .number, "An effect whose best match is below this is undetected and fails the check (default 0.5)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let url = try MediaCheck.file(p, "path", command: id)
        let rate = 48000
        let dir = TemporaryFolder.url.appendingPathComponent("regista-onsets-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ffmpeg = MediaCheck.ffmpeg(ctx)
        func decode(_ path: String, _ name: String) throws -> [Float] {
            let wav = dir.appendingPathComponent("\(name).wav")
            try Subprocess.check(ffmpeg, FFmpegAudio.quiet + ["-i", path, "-map", "0:a:0", "-af", "aresample=\(rate)", "-ac", "1",
                                                             "-ar", String(rate), "-c:a", "pcm_f32le", wav.path])
            return try WAVAudio.read(wav).mono()
        }
        let render = try decode(url.path, "render")
        // Everything but the effect, through the same mix (no limiter at 0 dBFS): subtracted around each effect so the
        // voice, the music and the tails of other effects do not mask a quiet click.
        let envelopes = try AudioPlan.writeEnvelopes(project, rate: rate, to: dir)
        func mix(_ q: Project, tracks: Set<String>, _ name: String) throws -> [Float] {
            guard !tracks.isEmpty else { return [Float](repeating: 0, count: render.count) }
            let out = dir.appendingPathComponent("\(name).wav")
            try ctx.services.audio.mix(AudioPlan.clips(q, rate: rate, tracks: tracks, envelopes: envelopes), length: render.count,
                                       rate: rate, gain: 0, ceiling: 0, to: out)
            return try WAVAudio.read(out).mono()
        }
        let sfxTracks = project.tracks.filter { $0.role == "sfx" && !$0.muted }
        let bed = try mix(project, tracks: Set(project.tracks.filter { $0.kind == .audio && $0.role != "sfx" }.map(\.id)), "bed")
        var cache: [String: [Float]] = [:]
        let fps = project.settings.frameRate.doubleValue
        let tolerance = p.number("tolerance") ?? 1
        let minCorrelation = p.number("minCorrelation") ?? 0.5
        var rows: [JSONValue] = []
        var worst = 0.0, minCorr = 1.0, undetected = 0
        let clips = sfxTracks.flatMap(\.clips).sorted { $0.start < $1.start }
        guard !clips.isEmpty else { throw CommandError.conflict("\(id): no SFX clips") }
        for c in clips {
            guard let asset = project.asset(c.assetID) else { continue }
            if cache[asset.path] == nil { cache[asset.path] = try decode(asset.path, "sfx\(cache.count)") }
            let src = cache[asset.path]!
            let s0 = Int(c.sourceIn.seconds * Double(rate)), s1 = min(Int(c.sourceOut.seconds * Double(rate)), src.count)
            guard s1 > s0 else { continue }
            let peak = src[s0..<s1].map { abs($0) }.max() ?? 0
            guard peak > 0 else { continue }
            let onset = (s0..<s1).first { abs(src[$0]) > 0.1 * peak } ?? s0
            let a = max(onset - rate / 200, s0), n = min(rate * 3 / 10, s1 - a)
            let template = Array(src[a..<(a + n)])
            let expected = Int((c.start.seconds * Double(rate)).rounded()) + (a - s0)
            let maxLag = rate * 8 / 100
            let lo = max(expected - maxLag, 0), hi = min(expected + maxLag + n, render.count)
            guard hi - lo >= n else { continue }
            // Other effects sounding in the window (a bass tail under a click) join the bed.
            let window = (MediaTime(seconds: Double(lo) / Double(rate)), MediaTime(seconds: Double(hi) / Double(rate)))
            var q = project
            var overlapping = 0
            for t in q.tracks.indices where q.tracks[t].role == "sfx" {
                q.tracks[t].clips.removeAll { $0.id == c.id || $0.end <= window.0 || $0.start >= window.1 }
                overlapping += q.tracks[t].clips.count
            }
            var others = bed
            if overlapping > 0 {
                let extra = try mix(q, tracks: Set(sfxTracks.map(\.id)), "others-\(c.id)")
                for i in lo..<hi { others[i] += extra[i] }
            }
            // Residual of the render around the effect: render − k·others, k fitted on the window (master gain, limiter).
            var rb = 0.0, bb = 0.0
            for i in lo..<hi { rb += Double(render[i]) * Double(others[i]); bb += Double(others[i]) * Double(others[i]) }
            let k = bb > 0 ? rb / bb : 0
            let residual = (lo..<hi).map { Float(Double(render[$0]) - k * Double(others[$0])) }
            // Normalized cross-correlation for every lag: vDSP for the dot products, running sums for the energies.
            let lags = residual.count - n + 1
            var dots = [Float](repeating: 0, count: lags)
            vDSP_conv(residual, 1, template, 1, &dots, 1, vDSP_Length(lags), vDSP_Length(n))
            var energy = (0..<n).reduce(0.0) { $0 + Double(residual[$1]) * Double(residual[$1]) }
            let tn = template.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot()
            var best = (lag: 0, corr: -2.0)
            for o in 0..<lags {
                if o > 0 { energy += Double(residual[o + n - 1]) * Double(residual[o + n - 1]) - Double(residual[o - 1]) * Double(residual[o - 1]) }
                let lag = o + lo - expected
                guard abs(lag) <= maxLag else { continue }
                let corr = energy > 1e-12 && tn > 0 ? Double(dots[o]) / (tn * energy.squareRoot()) : 0
                if corr > best.corr { best = (lag, corr) }
            }
            let ms = Double(best.lag) / Double(rate) * 1000
            let found = best.corr >= minCorrelation
            if found { worst = max(worst, abs(ms)) } else { undetected += 1 }
            minCorr = min(minCorr, best.corr)
            rows.append(["clipId": .string(c.id), "file": .string(asset.name), "at": ProjectState.seconds(c.start),
                         "lagMs": .number((ms * 10).rounded() / 10), "lagFrames": .number((ms / 1000 * fps * 100).rounded() / 100),
                         "correlation": .number((best.corr * 1000).rounded() / 1000), "found": .bool(found),
                         "overlapping": .number(Double(overlapping))])
        }
        let worstFrames = worst / 1000 * fps
        return ["pass": .bool(worstFrames <= tolerance && undetected == 0), "effects": .number(Double(rows.count)),
                "undetected": .number(Double(undetected)), "minCorrelation": .number((minCorr * 1000).rounded() / 1000),
                "maxAbsLagMs": .number((worst * 10).rounded() / 10), "maxAbsLagFrames": .number((worstFrames * 100).rounded() / 100),
                "onsets": .array(rows)]
    }
}
