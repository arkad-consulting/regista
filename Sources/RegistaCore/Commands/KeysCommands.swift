import Foundation

// keys.overlay (issue #44): the keystrokes logged while recording become key badges on an overlay track, timed
// through the screen clips (cuts, trims and speed changes respected, keys of cut-out moments dropped).

enum KeysOverlay: Command {
    static let id = "keys.overlay"
    static let summary = "Show the keyboard shortcuts pressed during a screen recording as on-screen key badges (⇧⌘K, ⌘Z ×3) — from the keystrokes Regista logged while recording. Only shortcuts (⌘/⌃/⌥ combinations, F-keys) by default; allKeys also shows special keys (↩ ⎋ ⇥ arrows) and typing, each run of typed characters collapsed into one badge of the text. Badges sit bottom-centre (above the caption band in a 9:16 reel) on a 'Tasti' overlay track, styled from the brand kit (ink chip, paper text, the kit's bold face), timed through the screen clips: cuts, trims and speed changes are followed and keys of cut-out moments are dropped. Re-running replaces the badges (one undo step); clear: true removes them. Returns the badges with their timeline times."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("allKeys", .boolean, "Also special keys and typing (runs of typed characters collapsed into one badge); default false: shortcuts only."),
        .optional("position", .oneOf(["bottom", "top"]), "bottom (default: bottom-centre, above the caption band in a 9:16 reel) or top."),
        .optional("hold", .number, "Seconds a badge stays after its last key (default 1.0)."),
        .optional("size", .number, "Font size, px per 1080 of the output width (default: ~3.8% of the frame's shorter side)."),
        .optional("from", .time, "Only keys from this timeline time (default 0)."),
        .optional("to", .time, "Only keys before this timeline time (default: the end)."),
        .optional("clear", .boolean, "Remove the key badges (and their track) instead."),
        Recording.recordingParam,
    ]

    static let role = Recording.keysTrackRole

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let (linkIndex, link) = try Recording.link(p, project, command: id)
        let existing = project.tracks.firstIndex { $0.role == role && $0.kind == .overlay }
        if p.bool("clear") == true {
            if let t = existing { project.tracks.remove(at: t) }
            project.recordings![linkIndex].keys = nil
            ctx.project = project
            return ["cleared": .bool(existing != nil), "badges": .array([])]
        }
        guard let screenID = link.screen else { throw CommandError.conflict("\(id): the recording has no screen") }
        let session = try RecordingSession.load(URL(fileURLWithPath: link.session))
        var o = KeyOverlay.Options()
        o.allKeys = p.bool("allKeys") ?? false
        if let h = p.number("hold") { guard h >= 0, h <= 10 else { throw CommandError.invalid("\(id): hold must be 0…10 s") }; o.hold = h }
        let badges = KeyOverlay.badges(session.events, o)
        let keyCount = session.events.filter { $0.kind == "key" }.count

        // Session time → timeline through the screen clips (speed-aware); a badge ends at the end of its clip.
        let offset = link.offsets["screen"] ?? 0
        let rate = project.settings.frameRate
        let screenClips = Recording.clips(of: screenID, in: project).map { project.tracks[$0.track].clips[$0.clip] }
        let from = p.time("from") ?? .zero, to = p.time("to") ?? project.duration
        var placed: [(badge: KeyBadge, start: MediaTime, end: MediaTime)] = []
        var dropped = 0
        for b in badges {
            let u = MediaTime(seconds: b.start - offset)
            guard let clip = screenClips.first(where: { $0.sourceIn <= u && u < $0.sourceOut }), let start = clip.timelineTime(ofSource: u) else {
                dropped += 1
                continue
            }
            let uEnd = min(MediaTime(seconds: b.end - offset), clip.sourceOut)
            let end = min(clip.timelineTime(ofSource: uEnd) ?? clip.end, clip.end)
            let s = start.snapped(to: rate), e = end.snapped(to: rate)
            guard s >= from, s < to else { continue }
            // Under a quarter of a second the badge cannot be read: its moment was mostly cut.
            guard (e - s).seconds >= 0.25 else { dropped += 1; continue }
            placed.append((b, s, e))
        }
        for i in placed.indices.dropLast() where placed[i].end > placed[i + 1].start { placed[i].end = placed[i + 1].start }

        // The track: replaced wholesale on every run.
        let t: Int
        if let e = existing {
            t = e
            project.tracks[t].clips.removeAll()
        } else {
            let track = Track(id: project.makeID("t"), kind: .overlay, name: "Tasti", role: role)
            t = project.tracks.firstIndex { $0.role == "titles" } ?? project.tracks.count
            project.tracks.insert(track, at: t)
        }
        let W = project.settings.width, H = project.settings.height
        let size = p.number("size") ?? KeyOverlay.size(width: W, height: H)
        guard size > 0 else { throw CommandError.invalid("\(id): size must be > 0") }
        let position = p.string("position") ?? "bottom"
        let badgeHeight = KeyOverlay.badgeHeight(size: size, width: W)
        // Where the screen is when each badge appears (a boxed screen keeps its badges inside it).
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false)
        let measure = ctx.services.renderer ?? EstimateRenderer()
        var rows: [JSONValue] = []
        for (b, s, e) in placed where e > s {
            let layers = job.layers(at: s)
            let screenBox = layers.first { $0.assetID == screenID && $0.opacity > 0.01 && $0.placement?.fit == .box }?.box(width: W, height: H)
            let cameraBox = layers.first { $0.assetID == link.camera && $0.opacity > 0.01 && $0.placement?.fit == .box }?.box(width: W, height: H)
            let title = KeyOverlay.title(b.text(), kind: b.kind, size: size, kit: project.brand)
            let badgeWidth = (try? measure.titleBox(title, outputWidth: W).width) ?? Double(b.text().count) * size * 0.6
            let y = KeyOverlay.centreY(position: position, width: W, height: H, screenBox: screenBox, badge: badgeHeight)
            let x = KeyOverlay.centreX(span: screenBox.map { ($0[0], $0[0] + $0[2]) } ?? (0, Double(W)), width: badgeWidth, y: y,
                                       height: badgeHeight, avoid: cameraBox)
            var clip = Clip(id: project.makeID("c"), assetID: "", sourceIn: .zero, sourceOut: e - s, start: s)
            clip.title = title
            clip.placement = Placement(fit: .native, x: x / Double(W), y: y / Double(H))
            clip.keyframes = AnimationPreset.combined(in: .pop, out: .fade, rest: Transform(), duration: e - s,
                                                      inDuration: min(0.18, (e - s).seconds / 3), outDuration: min(0.2, (e - s).seconds / 3))
            project.tracks[t].clips.append(clip)
            rows.append(["text": .string(b.text()), "kind": .string(b.kind.rawValue), "start": ProjectState.seconds(s), "end": ProjectState.seconds(e),
                         "clipId": .string(clip.id)])
        }
        project.tracks[t].sortClips()
        // The options, so a new layout or format puts the badges back the same way (size only when asked: it follows the frame).
        let kept = p.values.filter { ["allKeys", "position", "hold", "size"].contains($0.key) }
        project.recordings![linkIndex].keys = kept.isEmpty ? nil : kept
        ctx.project = project
        var warnings: [JSONValue] = []
        if keyCount == 0 { warnings.append("no keystrokes in this recording (the app logs them only with the Accessibility permission)") }
        else if badges.isEmpty { warnings.append(.string("\(keyCount) keystrokes but no shortcut among them: allKeys: true shows the typing too")) }
        return ["trackId": .string(project.tracks[t].id), "badges": .array(rows), "keys": .number(Double(keyCount)),
                "dropped": .number(Double(dropped)), "allKeys": .bool(o.allKeys), "warnings": .array(warnings)]
    }

    /// Restyles the badges in a newly applied brand kit (brandkit.apply).
    static func restyle(_ project: inout Project) {
        for t in project.tracks.indices where project.tracks[t].role == role {
            for c in project.tracks[t].clips.indices {
                guard let old = project.tracks[t].clips[c].title else { continue }
                let kind: KeyBadge.Kind = old.tracking == 0 ? .typing : .shortcut
                project.tracks[t].clips[c].title = KeyOverlay.title(old.text, kind: kind, size: old.size, kit: project.brand)
            }
        }
    }
}
