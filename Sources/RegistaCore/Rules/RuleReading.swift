import Foundation

// Reading time and text in frame (#145): every title, card, motion-template text and HyperFrames scene text stays on
// screen the time it takes to read, and its box stays inside the frame and the platform's zones. Word-synced captions are
// not texts of this kind (their words leave with the voice), nor a scrolling wall (marquee rows: not meant to be read in
// full), nor a text under 3 letters (a number badge).

extension RuleCheck {
    /// Seconds any text needs, however short.
    static let readingBase = 0.6
    /// Letters (or digits) read per second in a Latin-type script.
    static let lettersPerSecond = 12.0
    /// Characters read per second in a dense script (Chinese, Japanese, Korean).
    static let denseCharactersPerSecond = 6.0
    /// A text with fewer letters than this is not read but seen (a number badge, an emoji): exempt.
    static let readingMinimumLetters = 3

    /// The seconds `text` needs on screen: the base plus its letters at the reading pace; nil when it is exempt.
    static func readingSeconds(_ text: String) -> Double? {
        var latin = 0, dense = 0
        for ch in text where ch.isLetter || ch.isNumber {
            if ch.unicodeScalars.contains(where: isDense) { dense += 1 } else { latin += 1 }
        }
        guard latin + dense >= readingMinimumLetters else { return nil }
        return readingBase + Double(latin) / lettersPerSecond + Double(dense) / denseCharactersPerSecond
    }

    /// Han, kana and Hangul: one character carries what a Latin word does.
    static func isDense(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FFFF: true
        default: false
        }
    }

    /// The file beside a HyperFrames render with the visible text of its composition (graphics.hyperframes writes it).
    static let sceneTextFile = "scene-text.txt"
}

extension RuleCheck.Scene {
    /// A text on screen the reading-time check measures.
    struct Reading {
        enum Kind { case title, sticker, motion, scene }
        let track: Track
        let clip: Clip
        let kind: Kind
        let text: String
    }

    /// The texts of the edit, in timeline order: titles (cards are titles with a background), emoji stickers, motion
    /// templates (their text and list fields; a scrolling one is exempt) and HyperFrames scenes (the text beside the render).
    func readings() -> [Reading] {
        var out: [Reading] = []
        for track in project.tracks where !track.hidden && (track.kind == .overlay || track.kind == .video) && track.role != Recording.keysTrackRole {
            for clip in track.clips {
                if let t = clip.title {
                    out.append(Reading(track: track, clip: clip, kind: .title, text: t.text))
                } else if let s = clip.sticker, s.kind == .emoji {
                    out.append(Reading(track: track, clip: clip, kind: .sticker, text: s.value))
                } else if let m = clip.motion, let spec = MotionRegistry.spec(m.template), !spec.scrolls {
                    let words = spec.fields.flatMap { f -> [String] in
                        switch f.type {
                        case "text": [m.string(f.name)]
                        case "list": m.strings(f.name)
                        default: []
                        }
                    }
                    out.append(Reading(track: track, clip: clip, kind: .motion, text: words.filter { !$0.isEmpty }.joined(separator: " ")))
                } else if let asset = project.asset(clip.assetID) {
                    let folder = URL(fileURLWithPath: asset.path).deletingLastPathComponent()
                    guard folder.lastPathComponent.hasPrefix("hyperframes-"),
                          let data = FileManager.default.contents(atPath: folder.appendingPathComponent(RuleCheck.sceneTextFile).path) else { continue }
                    out.append(Reading(track: track, clip: clip, kind: .scene, text: String(decoding: data, as: UTF8.self)))
                }
            }
        }
        return out.sorted { $0.clip.start < $1.clip.start }
    }

    /// The text as a message quotes it: its first line, cut after 40 characters.
    static func quote(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count > 40 ? String(line.prefix(39)) + "…" : line
    }

    func readingTime() -> [RuleViolation] {
        let rate = project.settings.frameRate
        let W = Double(project.settings.width), H = Double(project.settings.height)
        var out: [RuleViolation] = []
        for r in readings() {
            guard let need = RuleCheck.readingSeconds(r.text) else { continue }
            let quote = Self.quote(r.text)
            let shown = r.clip.duration.seconds
            // Half a frame of slack: a clip ends on the frame grid.
            if shown + frame.seconds / 2 < need {
                let missing = need - shown
                var to = (r.clip.end + MediaTime(seconds: missing)).snapped(to: rate)
                if to < r.clip.end + MediaTime(seconds: missing) - MediaTime(ticks: frame.ticks / 2) { to = to + frame }
                let fix = room(after: r) >= to ? RuleFix(command: "timeline.trim",
                                                          params: ["clipId": .string(r.clip.id), "edge": "end", "to": ProjectState.seconds(to)],
                                                          label: RuleText(rulePhrase("Keep it on screen until %1$@ s"), RuleText.s(to))) : nil
                let text = fix != nil
                    ? RuleText(rulePhrase("«%1$@» is on screen %2$@ s and needs %3$@ s to be read: %4$@ s missing."),
                               .text(quote), RuleText.s(shown), RuleText.s(need), RuleText.s(missing))
                    : RuleText(rulePhrase("«%1$@» is on screen %2$@ s and needs %3$@ s to be read: %4$@ s missing, and what follows leaves no room. The text is too long: shorten it."),
                               .text(quote), RuleText.s(shown), RuleText.s(need), RuleText.s(missing))
                out.append(RuleViolation(check: "reading-time", severity: .fail, text: text, time: r.clip.start, clipID: r.clip.id, fix: fix))
            }
            // The box, once the entrance is over: the middle of the clip. A motion template draws over the whole frame by
            // its own layout, so only its time is measured.
            guard r.kind != .motion else { continue }
            let mid = r.clip.start + MediaTime(ticks: r.clip.duration.ticks / 2)
            guard let box = CanvasLayout.elements(project, at: mid, renderer: renderer).first(where: { $0.clipID == r.clip.id })?.box else { continue }
            let over = max(-box[0], -box[1], box[0] + box[2] - W, box[1] + box[3] - H)
            if over > 0.5 {
                out.append(RuleViolation(check: "reading-time", severity: .fail,
                                         text: RuleText(rulePhrase("«%1$@» goes out of the frame by %2$@ px."), .text(quote), RuleText.n(over)),
                                         time: r.clip.start, clipID: r.clip.id, fix: nil))
                continue
            }
            // The platform's zones of a vertical frame (graphics.checkLayout's): the account bar, the buttons and the post's
            // caption at the bottom, the action rail on the right. A text drawn there is covered on the phone.
            guard H > W, r.kind != .scene else { continue }
            let k = H / SafeZones.referenceHeight, top = SafeZones.topLimit * k, bottom = SafeZones.bottomLimit * k
            let right = W - SafeZones.rightMargin * W / SafeZones.referenceWidth
            let zone: RuleText? = if box[1] < top - 0.5 {
                RuleText(rulePhrase("«%1$@» is under the platform's top bar (above %2$@ px)."), .text(quote), RuleText.n(top))
            } else if box[1] + box[3] > bottom + 0.5 {
                RuleText(rulePhrase("«%1$@» is under the platform's buttons at the bottom (below %2$@ px)."), .text(quote), RuleText.n(bottom))
            } else if box[0] + box[2] > right + 0.5 {
                RuleText(rulePhrase("«%1$@» is under the platform's buttons on the right (past %2$@ px)."), .text(quote), RuleText.n(right))
            } else { nil }
            if let zone {
                out.append(RuleViolation(check: "reading-time", severity: .fail, text: zone, time: r.clip.start, clipID: r.clip.id, fix: nil))
            }
        }
        return out
    }

    /// How far the clip's end can go: to the next clip of its track, the end of the main video, and the end of its source
    /// (a title or a template has none).
    func room(after r: Reading) -> MediaTime {
        var limit = project.videoEnd ?? end
        if let next = r.track.clips.filter({ $0.id != r.clip.id && $0.start >= r.clip.end - MediaTime(ticks: frame.ticks / 2) }).map(\.start).min() {
            limit = min(limit, next)
        }
        if !r.clip.isGenerated, r.clip.speed == nil, let asset = project.asset(r.clip.assetID) {
            limit = min(limit, r.clip.end + (asset.duration - r.clip.sourceOut))
        }
        return limit
    }
}
