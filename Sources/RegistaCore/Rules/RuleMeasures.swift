import CryptoKit
import Foundation

// The «always» measures inside the regia (#145): captions off the face (captions.checkFaces), captions gone with their
// words (captions.checkTiming on the render), music under the voice (audio.checkDucking) and the voice's loudness (the
// voice mix through the audio toolkit, as media.measureLoudness measures). The commands stay as they are; the checks call
// the same code. A check whose engine or render is missing says «not checked» and why: it never blocks the export and
// never passes. What a measure costs is paid once per state: RuleMemory keeps it until what it measured changes.

/// What the measured checks keep between two runs of rules.check (the Export card runs it after each change): the renders
/// export.render wrote, by the edit they show, and measures taken on an edit or a file that has not changed since.
public final class RuleMemory: @unchecked Sendable {
    /// A render of one state of the edit: the file, its preset, whether the captions are drawn, the file's date then.
    public struct Render: Sendable {
        public var url: URL
        public var preset: String
        public var captions: Bool
        public var frameRate: Double
        public var width: Int
        public var height: Int
        var modified: Date? = nil
    }

    private let lock = NSLock()
    private var renders: [String: Render] = [:]
    private var values: [String: Any] = [:]
    /// Measures kept at most: the oldest go first.
    static let capacity = 64
    private var order: [String] = []

    public init() {}

    /// The edit as a render shows it: everything but its name, kind and choices, its script, takes and generation log.
    static func signature(_ project: Project) -> String {
        var p = project
        p.name = ""
        p.kind = nil
        p.choices = nil
        p.script = nil
        p.takes = nil
        p.generations = nil
        p.markers = []
        return digest(p)
    }

    static func digest<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(value)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A file as a key: its path, size and date (a file written again is another file).
    static func stamp(_ url: URL) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return "\(url.path)|\((a?[.size] as? NSNumber)?.intValue ?? -1)|\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    static func modified(_ url: URL) -> Date? { (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date }

    /// export.render wrote `render` from `project`.
    public func recordRender(_ project: Project, _ render: Render) {
        var r = render
        r.modified = Self.modified(r.url)
        let key = Self.signature(project)
        lock.lock(); defer { lock.unlock() }
        renders[key] = r
    }

    /// The render of this very edit, when its file is still the one written.
    public func render(of project: Project) -> Render? {
        let key = Self.signature(project)
        lock.lock()
        let r = renders[key]
        lock.unlock()
        guard let r, FileManager.default.fileExists(atPath: r.url.path), Self.modified(r.url) == r.modified else { return nil }
        return r
    }

    /// The value measured under `key`, measured now when there is none. A measure that throws is not kept.
    func remember<T>(_ key: String, _ measure: () throws -> T) rethrows -> T {
        lock.lock()
        if let v = values[key] as? T { lock.unlock(); return v }
        lock.unlock()
        let v = try measure()
        lock.lock(); defer { lock.unlock() }
        if values[key] == nil { order.append(key) }
        values[key] = v
        while order.count > Self.capacity { values[order.removeFirst()] = nil }
        return v
    }
}

extension RuleCheck {
    /// LU the voice may be away from its target.
    static let voiceTolerance = LoudnessTarget.tolerance
    /// The highest true peak of the voice, dBTP.
    static let voicePeak = LoudnessTarget.truePeak
    /// How far under the voice the music must be while it speaks, dB (audio.checkDucking's default).
    static let musicUnder = 15.0

    static func renderFirst() -> RuleText {
        RuleText(rulePhrase("No render of this edit yet: export it, then check again."))
            .forApp(rulePhrase("It is measured on the exported video: export it, then it is checked."), action: "export")
    }

    /// No face track: Claude runs faces.track, the person «Trova il volto» (#166).
    static func faceFirst() -> RuleText {
        RuleText(rulePhrase("No face track on the picture: run faces.track to check the face."))
            .forApp(rulePhrase("The face has not been found yet: «Find the face» finds it, then it is checked."), action: "faces")
    }

    static func notMeasured(_ error: Error) -> RuleText {
        let message = (error as? CommandError)?.message ?? error.localizedDescription
        return RuleText(rulePhrase("It could not be measured: %1$@"), .text(message))
    }
}

extension RuleCheck.Scene {
    /// The caption tracks that show.
    var captionTracks: [Track] { project.tracks.filter { $0.kind == .caption && !$0.hidden && !($0.captions?.chunks.isEmpty ?? true) } }

    /// Runs a measuring command on this edit, as an agent would (or its stand-in, when the host gives one).
    func measure(_ command: any Command.Type, _ params: [String: JSONValue]) throws -> JSONValue {
        guard var c = context else { throw CommandError(.io, "\(command.id): no engine here") }
        if let standIn = c.services.ruleMeasures[command.id] { return try standIn(params) }
        c.project = project
        return try Nested.run(command, params, &c)
    }

    /// No caption over a face: captions.checkFaces on each caption track.
    func captionsFaces() -> ([RuleViolation], RuleText?) {
        var out: [RuleViolation] = []
        for track in captionTracks {
            let r: JSONValue
            do { r = try measure(CaptionsCheckFaces.self, ["trackId": .string(track.id)]) } catch {
                if (error as? CommandError)?.message.contains("faces.track") == true {
                    return ([], RuleCheck.faceFirst())
                }
                return ([], RuleCheck.notMeasured(error))
            }
            for o in r["overlaps"]?.arrayValue ?? [] {
                let t = MediaTime(seconds: o["time"]?.doubleValue ?? 0)
                out.append(RuleViolation(check: "captions-faces", severity: .fail,
                                         text: RuleText(rulePhrase("The caption «%1$@» covers a face at %2$@ s."), .text(Self.quote(o["text"]?.stringValue ?? "")), RuleText.s(t)),
                                         time: t, clipID: nil, fix: nil))
            }
        }
        return (out, nil)
    }

    /// The captions on the render appear with their words and stay in their band: captions.checkTiming on the render of
    /// this very edit, else «not checked».
    func captionsTiming() -> ([RuleViolation], RuleText?) {
        let tracks = captionTracks
        guard !tracks.isEmpty else { return ([], nil) }
        guard let memory = context?.services.memory, let render = memory.render(of: project), render.captions else {
            return ([], RuleCheck.renderFirst())
        }
        var out: [RuleViolation] = []
        for track in tracks {
            let r: JSONValue
            do {
                r = try memory.remember("timing|\(RuleMemory.stamp(render.url))|\(render.preset)|\(RuleMemory.digest(track))") {
                    try measure(CaptionsCheckTiming.self, ["path": .string(render.url.path), "trackId": .string(track.id), "preset": .string(render.preset)])
                }
            } catch { return ([], RuleCheck.notMeasured(error)) }
            let first = MediaTime(seconds: track.captions?.chunks.first?.words.first?.start.seconds ?? 0)
            let off = r["outliers"]?.arrayValue ?? []
            if let o = off.first {
                let t = MediaTime(seconds: (o["expected"]?.doubleValue ?? 0) / max(render.frameRate, 1))
                out.append(RuleViolation(check: "captions-timing", severity: .fail,
                                         text: RuleText(rulePhrase("%1$@ caption words are not on screen with the voice in the render (the first, «%2$@», at %3$@ s)."),
                                                        RuleText.n(off.count), .text(o["word"]?.stringValue ?? ""), RuleText.s(t)),
                                         time: t, clipID: nil, fix: nil))
            }
            if r["band"]?["inside"]?.boolValue == false {
                out.append(RuleViolation(check: "captions-timing", severity: .fail,
                                         text: RuleText(rulePhrase("The captions leave their band in the render.")), time: first, clipID: nil, fix: nil))
            }
        }
        return (out, nil)
    }

    /// The music under the voice while it speaks: audio.checkDucking. No music or no voice: nothing to measure.
    func musicDucked() -> ([RuleViolation], RuleText?) {
        guard let music = project.tracks.first(where: { $0.kind == .audio && $0.role == "music" && !$0.muted && !$0.clips.isEmpty }),
              AudioTracks.voice(project) != nil, let memory = context?.services.memory else { return ([], nil) }
        let audio = project.tracks.filter { $0.kind == .audio }
        let files = audio.flatMap(\.clips).compactMap { project.asset($0.assetID) }.map { RuleMemory.stamp(URL(fileURLWithPath: $0.path)) }
        let r: JSONValue
        do {
            r = try memory.remember("ducking|\(RuleMemory.digest(audio))|\(files.joined(separator: ","))|\(project.duration.ticks)") {
                try measure(AudioCheckDucking.self, ["trackId": .string(music.id)])
            }
        } catch { return ([], RuleCheck.notMeasured(error)) }
        guard r["pass"]?.boolValue == false else { return ([], nil) }
        let under = r["underDB"]?.doubleValue ?? 0
        let depth = ((music.ducking?.depth ?? 0) - (RuleCheck.musicUnder - under) - 1).rounded()
        let fix = depth >= -40 ? RuleFix(command: "audio.duck", params: ["trackId": .string(music.id), "duck": .number(depth)],
                                          label: RuleText(rulePhrase("Lower the music under the voice to %1$@ dB"), RuleText.n(depth))) : nil
        return ([RuleViolation(check: "music-ducked", severity: .fail,
                               text: RuleText(rulePhrase("The music is %1$@ dB under the voice while it speaks: at least %2$@ dB."),
                                              .number((under * 10).rounded() / 10, decimals: 1), RuleText.n(RuleCheck.musicUnder)),
                               time: music.clips.map(\.start).min() ?? .zero, clipID: music.clips.first?.id, fix: fix)], nil)
    }

    /// The voice as the export makes it: the voice track through the export's mixer (gains and fades); when the export
    /// brings the whole mix to a loudness (`levelledTo`: the app's export and export.render {loudness} do), the voice
    /// moves with it by that mix's distance from it, and the export's limiter holds the peak: then at least the target
    /// −1 LU. Not levelled: at the target ±1 LU, its true peak at most −1.5 dBTP. No voice: nothing to measure.
    func voiceLoudness(_ target: Double) -> ([RuleViolation], RuleText?) {
        guard let voice = AudioTracks.voice(project), !voice.muted, let c = context else { return ([], nil) }
        let rate = project.settings.sampleRate
        let files = voice.clips.compactMap { project.asset($0.assetID) }.map { RuleMemory.stamp(URL(fileURLWithPath: $0.path)) }
        let audio = project.tracks.filter { $0.kind == .audio && !$0.muted }
        let allFiles = audio.flatMap(\.clips).compactMap { project.asset($0.assetID) }.map { RuleMemory.stamp(URL(fileURLWithPath: $0.path)) }
        /// The loudness of `tracks` (nil: every track that plays) through the export's mixer, ducking included.
        func mixed(_ name: String, _ tracks: Set<String>?, key: String) throws -> Loudness {
            try c.services.memory.remember(key) {
                let dir = TemporaryFolder.url.appendingPathComponent("regista-voice-\(UUID().uuidString.prefix(8))")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                let length = Int((project.duration.seconds * Double(rate)).rounded())
                let envelopes = try AudioPlan.writeEnvelopes(project, rate: rate, to: dir)
                let wav = dir.appendingPathComponent("\(name).wav")
                try c.services.audio.mix(AudioPlan.clips(project, rate: rate, tracks: tracks, envelopes: envelopes), length: length, rate: rate,
                                         gain: 0, ceiling: 0, to: wav)
                return try c.services.audio.loudness(of: [AudioSpan(url: wav, channels: 2)])
            }
        }
        var level: Double, peak: Double?
        do {
            let measured = try mixed("voice", [voice.id], key: "voice|\(RuleMemory.digest(voice))|\(files.joined(separator: ","))")
            level = measured.integrated.isFinite ? measured.integrated : -70
            peak = measured.truePeak
            if let levelledTo {
                let all = audio.count == 1 ? measured
                    : try mixed("mix", nil, key: "mix|\(RuleMemory.digest(audio))|\(allFiles.joined(separator: ","))|\(project.duration.ticks)")
                if all.integrated.isFinite {
                    level += levelledTo - all.integrated
                    peak = nil
                }
            }
        } catch { return ([], RuleCheck.notMeasured(error)) }
        // Levelled with the whole mix, a voice a little over the target comes from the quieter stretches of the rest (music
        // alone) that the levelling lifts too, and the export's limiter holds its peak: only a voice the rest drowns fails.
        let off = peak == nil ? target - level : abs(level - target)
        guard off > RuleCheck.voiceTolerance + 0.05 || (peak ?? -.infinity) > RuleCheck.voicePeak + 0.05 else { return ([], nil) }
        func db(_ v: Double) -> RuleText.Arg { .number((v * 10).rounded() / 10, decimals: 1) }
        let text = if let peak {
            RuleText(rulePhrase("The voice is at %1$@ LUFS with a true peak of %2$@ dBTP: it must be at %3$@ LUFS ±1, its peak at most −1.5 dBTP."),
                     db(level), db(peak), db(target))
        } else {
            RuleText(rulePhrase("In the export, with the mix brought to %1$@ LUFS, the voice is at %2$@ LUFS: at least %3$@ LUFS (the rest of the mix is too loud beside it)."),
                     db(levelledTo ?? target), db(level), db(target - RuleCheck.voiceTolerance))
        }
        return ([RuleViolation(check: "voice-loudness", severity: .fail, text: text,
                               time: voice.clips.map(\.start).min() ?? .zero, clipID: voice.clips.first?.id, fix: nil)], nil)
    }
}
