import Foundation

// The checks of a faceless reel (#145): a frame that stays nearly still too long and the same composition on both sides
// of a cut, measured on the render of this very edit (small grey copies of its frames), and the generated voice read back:
// its clips transcribed and compared with the text it was asked to say.

/// Small grey copies of a video's frames, for the checks that compare pictures: every frame at the video's own rate,
/// `width`×`height`, 8-bit grey, top-left origin, one array per frame.
public protocol FrameSampler {
    func greyFrames(of video: URL, width: Int, height: Int) throws -> [[UInt8]]
}

/// ffmpeg decodes and scales (area average) the frames.
struct FFmpegFrames: FrameSampler {
    let ffmpeg: URL

    func greyFrames(of video: URL, width: Int, height: Int) throws -> [[UInt8]] {
        let r = try Subprocess.check(ffmpeg, ["-nostdin", "-v", "error", "-i", video.path, "-vf", "scale=\(width):\(height):flags=area,format=gray",
                                              "-f", "rawvideo", "-"])
        let bytes = [UInt8](r.stdout), n = width * height
        guard n > 0 else { return [] }
        return stride(from: 0, to: bytes.count - n + 1, by: n).map { Array(bytes[$0..<($0 + n)]) }
    }
}

extension EngineServices {
    /// The frame sampler of the picture checks: the host's, else ffmpeg's.
    var pictureFrames: FrameSampler { frames ?? FFmpegFrames(ffmpeg: config.url(config.ffmpeg)) }
}

extension RuleCheck {
    /// Width of the grey copies the picture checks compare (height from the frame's aspect).
    static let sampleWidth = 48
    /// Frames per second the still-stretch check looks at.
    static let stillRate = 4.0
    /// Mean difference of grey (0–255) between two frames a quarter of a second apart under which the picture counts as
    /// still. Footage that moves, a camera that breathes, a title that slides in or types on are well above it; a still
    /// image, a frozen frame or a slow fade on a still are under it.
    static let stillDifference = 1.0
    /// Mean difference of grey (0–255) between the last frame before a cut and the first after it under which both sides
    /// show the same composition (a jump cut). Two different shots differ by tens.
    static let jumpDifference = 8.0

    /// Mean absolute difference of two grey frames of the same size.
    static func difference(_ a: [UInt8], _ b: [UInt8]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        var sum = 0
        for i in a.indices { sum += abs(Int(a[i]) - Int(b[i])) }
        return Double(sum) / Double(a.count)
    }

    /// The stretches longer than `limit` seconds where the picture stays still, from frames at `fps`: (start, seconds).
    static func stillStretches(_ frames: [[UInt8]], fps: Double, limit: Double) -> [(start: Double, seconds: Double)] {
        guard fps > 0, frames.count > 1 else { return [] }
        let step = max(1, Int((fps / stillRate).rounded()))
        let samples = Array(stride(from: 0, to: frames.count, by: step))
        var out: [(Double, Double)] = []
        var runStart: Int?
        func close(_ endSample: Int) {
            guard let s = runStart else { return }
            let seconds = Double(samples[endSample] - samples[s]) / fps
            if seconds > limit + 1e-6 { out.append((Double(samples[s]) / fps, seconds)) }
            runStart = nil
        }
        for k in 1..<samples.count {
            if difference(frames[samples[k - 1]], frames[samples[k]]) < stillDifference {
                if runStart == nil { runStart = k - 1 }
            } else {
                close(k - 1)
            }
        }
        close(samples.count - 1)
        return out
    }
}

extension RuleCheck.Scene {
    /// The cuts of the picture: where a clip of a video track starts right where the one before it ends (no transition there).
    func cuts() -> [MediaTime] {
        var out: Set<MediaTime> = []
        let half = MediaTime(ticks: frame.ticks / 2)
        for track in project.tracks where track.kind == .video && !track.hidden {
            let clips = track.clips.sorted { $0.start < $1.start }
            for (a, b) in zip(clips, clips.dropFirst()) where abs((b.start - a.end).ticks) <= half.ticks && b.start > .zero {
                guard !(project.transitions ?? []).contains(where: { abs(($0.at - b.start).ticks) <= frame.ticks }) else { continue }
                out.insert(b.start)
            }
        }
        return out.sorted()
    }

    /// The render's frames, grey and small, with its rate; or why there are none.
    func renderedFrames() -> (frames: [[UInt8]], fps: Double)?? {
        guard let c = context, let render = c.services.memory.render(of: project) else { return nil }
        let w = RuleCheck.sampleWidth
        let h = max(2, Int((Double(w) * Double(render.height) / Double(max(render.width, 1))).rounded()))
        do {
            let frames = try c.services.memory.remember("frames|\(RuleMemory.stamp(render.url))|\(w)x\(h)") {
                try c.services.pictureFrames.greyFrames(of: render.url, width: w, height: h)
            }
            return .some((frames, render.frameRate))
        } catch {
            return .some(nil)
        }
    }

    func stillStretch(_ limit: Double) -> ([RuleViolation], RuleText?) {
        guard let sampled = renderedFrames() else { return ([], RuleCheck.renderFirst()) }
        guard let read = sampled else { return ([], RuleText(rulePhrase("The render's frames could not be read."))) }
        let (frames, fps) = read
        return (RuleCheck.stillStretches(frames, fps: fps, limit: limit).map { s in
            RuleViolation(check: "still-stretch", severity: .warn,
                          text: RuleText(rulePhrase("The picture stays nearly still for %1$@ s (from %2$@ s): at most %3$@ s."),
                                         RuleText.s(s.seconds), RuleText.s(s.start), RuleText.s(limit)),
                          time: MediaTime(seconds: s.start).snapped(to: project.settings.frameRate), clipID: nil, fix: nil)
        }, nil)
    }

    func jumpCut() -> ([RuleViolation], RuleText?) {
        let cuts = cuts()
        guard !cuts.isEmpty else { return ([], nil) }
        guard let sampled = renderedFrames() else { return ([], RuleCheck.renderFirst()) }
        guard let read = sampled else { return ([], RuleText(rulePhrase("The render's frames could not be read."))) }
        let (frames, fps) = read
        return (cuts.compactMap { t in
            let after = Int((t.seconds * fps).rounded())
            guard after >= 1, after < frames.count, RuleCheck.difference(frames[after - 1], frames[after]) < RuleCheck.jumpDifference else { return nil }
            return RuleViolation(check: "jump-cut", severity: .warn,
                                 text: RuleText(rulePhrase("The same picture on both sides of the cut at %1$@ s: a jump cut."), RuleText.s(t)),
                                 time: t, clipID: nil, fix: nil)
        }, nil)
    }
}

/// The generated voice read back (#145): what the voice says, word by word, against the text it was asked to say.
enum VoiceReadBack {
    /// One word that differs: what was heard (nil: a script word not heard), the script's word (nil: a word not in the
    /// script) and when, seconds into the clip's file.
    struct Difference: Equatable {
        var heard: String?
        var script: String?
        var time: Double
    }

    /// The script's words against the heard ones, aligned on the words that match (recognition slips in long words
    /// tolerated, as the voice's word timings are matched): a heard word in place of a script word, a script word not
    /// heard, a heard word the script does not have.
    static func differences(script: String, heard: [Word]) -> [Difference] {
        let tokens = script.split(whereSeparator: \.isWhitespace).map(String.init).filter { !ScriptAligner.normalize($0).isEmpty }
        let words = heard.filter { !ScriptAligner.normalize($0.text).isEmpty }
        let a = tokens.map(ScriptAligner.normalize), b = words.map { ScriptAligner.normalize($0.text) }
        func same(_ i: Int, _ j: Int) -> Bool { ScriptAligner.similarity(a[i], b[j]) >= 0.75 }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in 1...a.count { for j in 1...b.count { dp[i][j] = same(i - 1, j - 1) ? dp[i - 1][j - 1] + 1 : max(dp[i - 1][j], dp[i][j - 1]) } }
        }
        // The matched pairs, in order.
        var pairs: [(Int, Int)] = []
        var i = a.count, j = b.count
        while i > 0, j > 0 {
            if same(i - 1, j - 1), dp[i][j] == dp[i - 1][j - 1] + 1 { pairs.append((i - 1, j - 1)); i -= 1; j -= 1 }
            else if dp[i - 1][j] >= dp[i][j - 1] { i -= 1 } else { j -= 1 }
        }
        pairs.reverse()
        var out: [Difference] = []
        var (si, hi) = (0, 0)
        for (ps, ph) in pairs + [(a.count, b.count)] {
            let scriptRun = Array(si..<ps), heardRun = Array(hi..<ph)
            let before = hi > 0 ? words[hi - 1].end.seconds : (words.first?.start.seconds ?? 0)
            for k in 0..<max(scriptRun.count, heardRun.count) {
                let s = k < scriptRun.count ? tokens[scriptRun[k]] : nil
                let h = k < heardRun.count ? words[heardRun[k]] : nil
                out.append(Difference(heard: h?.text, script: s, time: h?.start.seconds ?? before))
            }
            (si, hi) = (ps + 1, ph + 1)
        }
        return out
    }

    /// The word as a message quotes it: without the punctuation around it.
    static func bare(_ word: String) -> String { word.trimmingCharacters(in: .punctuationCharacters.union(.symbols).union(.whitespaces)) }
}

extension RuleCheck.Scene {
    /// Each generated voice clip on a track that plays, transcribed (once per file) and compared with its text; each
    /// word that differs with its time on the timeline. Without a transcription engine: «not checked».
    func voiceReadBack() -> ([RuleViolation], RuleText?) {
        let voiced = project.tracks.filter { $0.kind == .audio && !$0.muted }.flatMap { t in t.clips.map { (t, $0) } }
            .filter { project.asset($0.1.assetID)?.generated?.kind == .voice }
        guard !voiced.isEmpty else { return ([], nil) }
        guard let c = context else { return ([], RuleText(rulePhrase("No transcription engine here."))) }
        let s = c.services
        var engine = s.tier.defaultTranscriber(s.config)
        if s.transcribers[engine]?.unavailableReason() != nil { engine = WhisperCppTranscriber.engineID }
        guard let transcriber = s.transcribers[engine] else { return ([], RuleText(rulePhrase("No transcription engine here."))) }
        if let why = transcriber.unavailableReason() {
            return ([], RuleText(rulePhrase("No transcription engine: %1$@"), .text(why)))
        }
        var out: [RuleViolation] = []
        for (_, clip) in voiced {
            guard let asset = project.asset(clip.assetID), let script = asset.generated?.prompt else { continue }
            let language = asset.analysis?.transcript?.language ?? "it"
            var used = transcriber
            if let wx = transcriber as? WhisperXTranscriber, wx.alignerReason(language) != nil {
                guard let cpp = s.transcribers[WhisperCppTranscriber.engineID], cpp.unavailableReason() == nil else { continue }
                used = cpp
            }
            let heard: [Word]
            do {
                heard = try s.memory.remember("readback|\(used.id)|\(used.model)|\(language)|\(RuleMemory.stamp(URL(fileURLWithPath: asset.path)))") {
                    let dir = TemporaryFolder.url.appendingPathComponent("regista-readback-\(UUID().uuidString.prefix(8))")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: dir) }
                    let speech = dir.appendingPathComponent("speech.wav")
                    try s.audio.extractAudio(from: URL(fileURLWithPath: asset.path), channels: 1, speech: speech, working: dir.appendingPathComponent("working.wav"))
                    return try used.transcribe(speech, language: language).words
                }
            } catch { return ([], RuleCheck.notMeasured(error)) }
            for d in VoiceReadBack.differences(script: script, heard: heard) {
                let inside = d.time >= clip.sourceIn.seconds - 0.05 && d.time <= clip.sourceOut.seconds + 0.05
                guard inside else { continue }
                let t = (clip.start + MediaTime(seconds: max(0, d.time - clip.sourceIn.seconds))).snapped(to: project.settings.frameRate)
                let text: RuleText
                switch (d.heard.map(VoiceReadBack.bare), d.script.map(VoiceReadBack.bare)) {
                case let (h?, s?):
                    text = RuleText(rulePhrase("The voice says «%1$@» where the script has «%2$@» (at %3$@ s): voice.lexicon sets how a word is said."),
                                    .text(h), .text(s), RuleText.s(t))
                case let (nil, s?):
                    text = RuleText(rulePhrase("The voice leaves out «%1$@» of the script (at %2$@ s): voice.lexicon sets how a word is said."), .text(s), RuleText.s(t))
                case let (h?, nil):
                    text = RuleText(rulePhrase("The voice says «%1$@», which is not in the script (at %2$@ s)."), .text(h), RuleText.s(t))
                case (nil, nil): continue
                }
                out.append(RuleViolation(check: "voice-read-back", severity: .warn, text: text, time: t, clipID: clip.id, fix: nil))
            }
        }
        return (out, nil)
    }
}
