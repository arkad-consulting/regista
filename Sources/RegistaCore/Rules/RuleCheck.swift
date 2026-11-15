import Foundation

// The checks the rule sheets switch (#31), measured on the edit itself (no render): captions against the opening title
// and the closing logo, the pause before the logo, where logos are, titles and logos against the speaker's face (the
// face track through the crops, as captions.checkFaces does), and text sizes. Each violation has a time to go to and,
// where a safe one exists, a fix that is one command and one undo step.

/// A fix: one command call.
public struct RuleFix: Hashable, Sendable {
    public var command: String
    public var params: JSONValue
    public var label: RuleText

    public var json: JSONValue {
        var o = label.json.objectValue!
        o["command"] = .string(command)
        o["params"] = params
        return .object(o)
    }
}

public struct RuleViolation: Hashable, Sendable {
    public enum Severity: String, Sendable { case fail, warn }
    public var check: String
    public var severity: Severity
    public var text: RuleText
    /// Where to look on the timeline.
    public var time: MediaTime
    public var clipID: String?
    public var fix: RuleFix?

    public var json: JSONValue {
        var o = text.json.objectValue!
        o["check"] = .string(check)
        o["severity"] = .string(severity.rawValue)
        o["time"] = ProjectState.seconds(time)
        o["clipId"] = clipID.map { .string($0) } ?? .null
        o["fix"] = fix?.json ?? .null
        return .object(o)
    }

    /// One line for an agent: "logo-pause at 12.40 s: … — fix: timeline.move {…}".
    public var line: String {
        "\(check) at \(RuleText.s(time)) s: \(text.english)" + (fix.map { " — fix: \($0.command) \($0.params.text())" } ?? " — no automatic fix")
    }
}

public struct RuleReport: Sendable {
    public struct Row: Sendable {
        public var state: RuleBook.CheckState
        /// Why the check could not be measured on this edit (nil: it ran, or it is off).
        public var skipped: RuleText?
    }

    public var kind: String
    public var kindTitle: String
    public var kindSource: String
    public var note: RuleText?
    public var rows: [Row]
    public var violations: [RuleViolation]
    public var problems: [(sheet: String, problem: RuleSheetText.Problem)]

    public var failures: [RuleViolation] { violations.filter { $0.severity == .fail } }
    public var pass: Bool { failures.isEmpty }

    public var json: JSONValue {
        [
            "kind": .string(kind), "kindTitle": .string(kindTitle), "kindSource": .string(kindSource), "note": note?.json ?? .null,
            "pass": .bool(pass), "failures": .number(Double(failures.count)),
            "warnings": .number(Double(violations.count - failures.count)),
            "violations": .array(violations.map(\.json)),
            "checks": .array(rows.map { r in
                var o = r.state.json.objectValue!
                o["ran"] = .bool(r.state.on && r.skipped == nil)
                o["skipped"] = r.skipped?.json ?? .null
                o["violations"] = .number(Double(violations.filter { $0.check == r.state.spec.id }.count))
                return .object(o)
            }),
            "sheetProblems": .array(problems.map { p in
                var o = p.problem.json.objectValue!
                o["sheet"] = .string(p.sheet)
                return .object(o)
            }),
        ]
    }
}

enum RuleCheck {
    /// A title counts as the opening title when it starts this early.
    static let openingWindow = MediaTime(seconds: 1)
    /// A logo that reaches the end and starts at most this long before the last word ends is the closing logo (a fix
    /// can move it); one that starts earlier is a logo across the video.
    static let closingLead = MediaTime(seconds: 3)

    static func run(_ project: Project, book: RuleBook, language: String, renderer: VideoRenderer?) -> RuleReport {
        let (kind, source, note) = book.kind(of: project)
        let states = book.checks(kind, language: language)
        let scene = Scene(project)
        var rows: [RuleReport.Row] = []
        var violations: [RuleViolation] = []
        for state in states {
            guard state.on else { rows.append(.init(state: state, skipped: nil)); continue }
            let (found, skipped) = scene.check(state.spec.id, value: state.value ?? state.spec.number?.defaultValue ?? 0, renderer: renderer)
            violations += found
            rows.append(.init(state: state, skipped: skipped))
        }
        violations.sort { ($0.time, $0.check) < ($1.time, $1.check) }
        return RuleReport(kind: kind, kindTitle: book.title(kind, language: language), kindSource: source, note: note, rows: rows,
                          violations: violations, problems: book.problems(kind, language: language))
    }

    /// The edit as the checks see it.
    struct Scene {
        typealias Item = (track: Track, clip: Clip)
        let project: Project
        let frame: MediaTime
        let end: MediaTime
        var logos: [Item] = []
        var titles: [Item] = []
        /// The last spoken word on the timeline (nil: no transcript).
        var lastWord: (start: MediaTime, end: MediaTime)?
        var captions: [(track: Track, captions: Captions)] = []

        init(_ project: Project) {
            self.project = project
            frame = MediaTime.frameDuration(at: project.settings.frameRate)
            end = project.pictureEnd
            let kit = project.brand
            let logoFiles = Set(((kit?.logos.map { Array($0.values) } ?? []) + (kit?.logo.map { [$0] } ?? []))
                .compactMap { kit?.assetPath($0) }.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
            for track in project.tracks where !track.hidden && (track.kind == .overlay || track.kind == .video) {
                for clip in track.clips {
                    let path = project.asset(clip.assetID).map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }
                    if track.role == "logo" || path.map(logoFiles.contains) == true || (clip.effects ?? []).contains(where: { $0.id.hasPrefix("logo-") }) {
                        logos.append((track, clip))
                    } else if track.role != Recording.keysTrackRole,
                              clip.title != nil || track.role == "titles" || path?.contains("/graphics/blender-") == true {
                        // A text layer, anything on a titles track, or a 3D title (graphics.blenderTitle's frames).
                        titles.append((track, clip))
                    }
                }
            }
            var words: [(MediaTime, MediaTime)] = []
            if let t = TimelineTranscript.defaultTrack(in: project) {
                words += TimelineTranscript.words(of: t, in: project).map { ($0.start, $0.end) }
            }
            for track in project.tracks where track.kind == .caption && !track.hidden {
                guard let c = track.captions else { continue }
                captions.append((track, c))
                words += c.chunks.flatMap { $0.words.map { ($0.start, $0.end) } }
            }
            if let last = words.max(by: { $0.1 < $1.1 }) { lastWord = (last.0, last.1) }
        }

        func name(_ item: Item) -> String {
            if let t = item.clip.title { return t.text.components(separatedBy: "\n").first ?? t.text }
            return project.asset(item.clip.assetID)?.name ?? item.clip.id
        }

        /// The caption chunks shown in [from, to): (chunk index, first shown, end).
        func chunks(_ c: Captions, from: MediaTime, to: MediaTime) -> [(Int, MediaTime, MediaTime)] {
            c.chunks.enumerated().compactMap { i, ch in
                let s = ch.words.first?.start ?? ch.end
                return s < to && from < ch.end ? (i, s, ch.end) : nil
            }
        }

        func isClosing(_ clip: Clip) -> Bool {
            guard clip.end + frame > end else { return false }
            if let w = lastWord { return clip.start + closingLead >= w.end }
            return clip.start > .zero && clip.start.seconds >= end.seconds / 2
        }

        func check(_ id: String, value: Double, renderer: VideoRenderer?) -> ([RuleViolation], RuleText?) {
            switch id {
            case "title-captions": return (titleCaptions(), nil)
            case "logo-captions": return (logoCaptions(), nil)
            case "logo-pause": return logoPause(value)
            case "logo-end": return (logoEnd(), nil)
            case "face-clear": return faceClear(renderer)
            case "text-size": return (textSize(value), nil)
            default: return ([], nil)
            }
        }

        func clear(_ track: Track, _ from: MediaTime, _ to: MediaTime, _ label: RuleText) -> RuleFix {
            RuleFix(command: "captions.clear", params: ["trackId": .string(track.id), "from": ProjectState.seconds(from), "to": ProjectState.seconds(to)],
                    label: label)
        }

        func titleCaptions() -> [RuleViolation] {
            var out: [RuleViolation] = []
            for title in titles where title.clip.start < openingWindow {
                for (track, c) in captions {
                    let shown = chunks(c, from: title.clip.start, to: title.clip.end)
                    guard let first = shown.first else { continue }
                    out.append(RuleViolation(
                        check: "title-captions", severity: .fail,
                        text: RuleText(rulePhrase("Captions show while the opening title is on screen (%1$@–%2$@ s)."), RuleText.s(title.clip.start), RuleText.s(title.clip.end)),
                        time: max(first.1, title.clip.start), clipID: title.clip.id,
                        fix: clear(track, title.clip.start, title.clip.end, RuleText(rulePhrase("Start the captions when the title leaves")))))
                }
            }
            return out
        }

        func logoCaptions() -> [RuleViolation] {
            var out: [RuleViolation] = []
            for logo in logos where isClosing(logo.clip) {
                for (track, c) in captions {
                    guard let first = chunks(c, from: logo.clip.start, to: logo.clip.end).first else { continue }
                    out.append(RuleViolation(
                        check: "logo-captions", severity: .fail,
                        text: RuleText(rulePhrase("Captions show on the closing logo (from %1$@ s)."), RuleText.s(max(first.1, logo.clip.start))),
                        time: max(first.1, logo.clip.start), clipID: logo.clip.id,
                        fix: clear(track, logo.clip.start, logo.clip.end, RuleText(rulePhrase("End the captions before the logo")))))
                }
            }
            return out
        }

        func logoPause(_ minimum: Double) -> ([RuleViolation], RuleText?) {
            let closing = logos.filter { isClosing($0.clip) }
            guard !closing.isEmpty else { return ([], nil) }
            guard let word = lastWord else {
                return ([], RuleText(rulePhrase("No transcript: the pause after the last word cannot be measured.")))
            }
            let rate = project.settings.frameRate
            var target = (word.end + MediaTime(seconds: minimum + 0.1)).snapped(to: rate)
            if target < word.end + MediaTime(seconds: minimum) { target = target + frame }
            let longest = minimum + 0.3
            return (closing.compactMap { logo in
                let gap = (logo.clip.start - word.end).seconds
                let fix = RuleFix(command: "timeline.move", params: ["clipId": .string(logo.clip.id), "start": ProjectState.seconds(target)],
                                  label: RuleText(rulePhrase("Move the logo to %1$@ s"), RuleText.s(target)))
                if gap < minimum - 0.0005 {
                    let text = gap >= 0
                        ? RuleText(rulePhrase("The logo enters %1$@ s after the last spoken word: the pause must be at least %2$@ s."), RuleText.s(gap), RuleText.s(minimum))
                        : RuleText(rulePhrase("The logo enters %1$@ s before the last spoken word ends: the pause must be at least %2$@ s."), RuleText.s(-gap), RuleText.s(minimum))
                    return RuleViolation(check: "logo-pause", severity: .fail, text: text, time: logo.clip.start, clipID: logo.clip.id, fix: fix)
                }
                if gap > longest + 0.0005 {
                    return RuleViolation(check: "logo-pause", severity: .warn,
                                         text: RuleText(rulePhrase("A long pause before the logo: %1$@ s after the last spoken word (more than %2$@ s)."),
                                                        RuleText.s(gap), RuleText.s(longest)),
                                         time: word.end, clipID: logo.clip.id, fix: fix)
                }
                return nil
            }, nil)
        }

        func logoEnd() -> [RuleViolation] {
            logos.filter { !isClosing($0.clip) }.map { logo in
                let c = logo.clip
                let text: RuleText
                if c.duration.seconds >= end.seconds / 2 {
                    text = RuleText(rulePhrase("A logo across the video (%1$@–%2$@ s): the logo goes only at the end."), RuleText.s(c.start), RuleText.s(c.end))
                } else if c.start.seconds < max(2, end.seconds / 10) {
                    text = RuleText(rulePhrase("A logo at the start of the video (%1$@ s): the logo goes only at the end."), RuleText.s(c.start))
                } else {
                    text = RuleText(rulePhrase("A logo in the middle of the video (%1$@ s): the logo goes only at the end."), RuleText.s(c.start))
                }
                return RuleViolation(check: "logo-end", severity: .fail, text: text, time: c.start, clipID: c.id, fix: nil)
            }
        }

        func faceClear(_ renderer: VideoRenderer?) -> ([RuleViolation], RuleText?) {
            let items = logos + titles
            guard !items.isEmpty else { return ([], nil) }
            var faces = OutputFaces(job: RenderJob(project: project, preset: ExportPreset.named(nil, project: project)))
            guard faces.available else { return ([], RuleText(rulePhrase("No face track on the picture: run faces.track to check the face."))) }
            let step = MediaTime(ticks: frame.ticks * 3)
            var out: [RuleViolation] = []
            for item in items {
                var t = item.clip.start
                while t < item.clip.end {
                    defer { t = t + step }
                    if item.clip.isBehindSubject(at: t - item.clip.start) { continue }
                    let heads = faces.boxes(at: t).map(FaceFraming.head)
                    guard !heads.isEmpty,
                          let box = CanvasLayout.elements(project, at: t, renderer: renderer).first(where: { $0.clipID == item.clip.id })?.box,
                          heads.contains(where: { FaceFraming.intersects($0, box) }) else { continue }
                    let isLogo = logos.contains { $0.clip.id == item.clip.id }
                    let text = isLogo
                        ? RuleText(rulePhrase("The logo covers the speaker's face at %1$@ s."), RuleText.s(t))
                        : RuleText(rulePhrase("The title «%1$@» covers the speaker's face at %2$@ s."), name(item), RuleText.s(t))
                    out.append(RuleViolation(check: "face-clear", severity: .fail, text: text, time: t, clipID: item.clip.id, fix: nil))
                    break
                }
            }
            return (out, nil)
        }

        func textSize(_ minimum: Double) -> [RuleViolation] {
            let W = Double(project.settings.width), H = Double(project.settings.height)
            let floor = minimum * min(W, H) / SafeZones.referenceWidth
            func px(_ v: Double) -> String { String(Int(v.rounded())) }
            var out: [RuleViolation] = []
            for item in titles + logos {
                guard let title = item.clip.title else { continue }
                let scale = item.clip.transform(at: MediaTime(ticks: item.clip.duration.ticks / 2)).scale
                let drawn = title.size * scale * W / SafeZones.referenceWidth
                guard drawn + 0.05 < floor else { continue }
                out.append(RuleViolation(check: "text-size", severity: .fail,
                                         text: RuleText(rulePhrase("The title «%1$@» is %2$@ px on this frame: at least %3$@ px."), name(item), px(drawn), px(floor)),
                                         time: item.clip.start, clipID: item.clip.id, fix: nil))
            }
            for (_, c) in captions {
                for (i, ch) in c.chunks.enumerated() {
                    let drawn = c.style.fontSize * c.scale(chunk: i) * W / c.style.referenceWidth
                    guard drawn + 0.05 < floor else { continue }
                    out.append(RuleViolation(check: "text-size", severity: .fail,
                                             text: RuleText(rulePhrase("The captions are %1$@ px on this frame: at least %2$@ px."), px(drawn), px(floor)),
                                             time: ch.words.first?.start ?? ch.end, clipID: nil, fix: nil))
                    break
                }
            }
            return out
        }
    }
}
