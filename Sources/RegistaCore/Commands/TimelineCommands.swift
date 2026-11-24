import Foundation

/// Lookups and rules shared by the timeline commands. Timeline times are snapped to the
/// project frame grid; clips on one track never overlap.
enum Timeline {
    static func trackIndex(_ id: String, in project: Project, editable: Bool = true) throws -> Int {
        guard let t = project.trackIndex(id) else {
            let ids = project.tracks.map(\.id).joined(separator: ", ")
            throw CommandError.notFound("No track '\(id)' (tracks: \(ids.isEmpty ? "none" : ids))")
        }
        if editable, project.tracks[t].locked { throw CommandError.conflict("Track \(project.tracks[t].name) (\(id)) is locked") }
        return t
    }

    static func locate(clip id: String, in project: Project) throws -> (track: Int, clip: Int) {
        guard let loc = project.locate(clip: id) else { throw CommandError.notFound("No clip '\(id)'") }
        if project.tracks[loc.track].locked {
            throw CommandError.conflict("Clip \(id) is on locked track \(project.tracks[loc.track].name)")
        }
        return loc
    }

    /// Can this asset go on this kind of track?
    static func checkCompatible(_ asset: MediaAsset, _ track: Track) throws {
        switch track.kind {
        case .video, .overlay:
            guard asset.video != nil else { throw CommandError.conflict("\(asset.name) has no video: it cannot go on \(track.kind.rawValue) track \(track.name)") }
        case .audio:
            guard asset.audio != nil else { throw CommandError.conflict("\(asset.name) has no audio: it cannot go on audio track \(track.name)") }
        case .caption:
            throw CommandError.conflict("Caption track \(track.name) holds captions, not media clips")
        }
    }

    static func checkFree(_ track: Track, start: MediaTime, end: MediaTime, except: String? = nil) throws {
        guard start >= .zero else { throw CommandError.conflict("Clips cannot start before 0 (got \(start.displaySeconds)s)") }
        if let other = track.overlap(start: start, end: end, except: except) {
            throw CommandError.conflict("\(track.name) is occupied by clip \(other.id) from \(other.start.displaySeconds)s to \(other.end.displaySeconds)s")
        }
    }

    /// Shifts clips of a track starting at or after `from` by `delta` (ripple).
    static func shift(_ track: inout Track, from: MediaTime, by delta: MediaTime, except: String? = nil) {
        for i in track.clips.indices where track.clips[i].id != except && track.clips[i].start >= from {
            track.clips[i].start += delta
        }
    }

    /// Other clips sharing `clip`'s link (on any track), as (track, clip) positions.
    static func partners(of clip: Clip, in project: Project) -> [(track: Int, clip: Int)] {
        guard let link = clip.link else { return [] }
        var out: [(Int, Int)] = []
        for (t, track) in project.tracks.enumerated() {
            for (c, other) in track.clips.enumerated() where other.link == link && other.id != clip.id { out.append((t, c)) }
        }
        return out
    }

    static let linkedParam = ParamSpec.optional("linked", .boolean, "Also act on the clips linked to it (picture/sound of the same take), default true.")

    /// How long a still image placed without a source range stays on screen.
    static let stillDuration = MediaTime(seconds: 5)

    /// Source times snap to the asset's own frames when it has video.
    static func sourceTime(_ p: CommandParams, _ name: String, _ asset: MediaAsset) -> MediaTime? {
        guard let t = p.time(name) else { return nil }
        return asset.video.map { t.snapped(to: $0.frameRate) } ?? t
    }
}

enum TimelinePlace: Command {
    static let id = "timeline.place"
    static let summary = "Manual editing: place an asset (or a source range of it) on a track as a new clip at a timeline time, optionally linked to another clip. Fails if the spot is occupied. With frameOnFace, a camera video of another aspect than the project's is framed on its face as project.format frames it (its faces tracked first when it has no face track: faces.track, local Apple Vision, no cost), in the same undo step. Returns the new clip id and, with frameOnFace, the assets tracked and the clips framed."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Asset id from media.import."),
        .required("trackId", .string, "Target track id."),
        .optional("start", .time, "Timeline position (default: end of the track)."),
        .optional("sourceIn", .time, "Start inside the source media (default 0)."),
        .optional("sourceOut", .time, "End inside the source media (default: end of the media; a still image lasts 5 s)."),
        .optional("linkTo", .string, "Link the new clip to this clip (e.g. the sound of a picture clip): they then move, trim, cut and delete together."),
        .optional("frameOnFace", .boolean, "Frame a full-frame camera video of another aspect on its face, tracking the faces first when needed (default false: the picture is cropped around its centre). Import a camera clip into a project of another format with it."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let assetID = p.requiredString("assetId")
        guard let asset = project.asset(assetID) else { throw CommandError.notFound("timeline.place: no asset '\(assetID)'") }
        let t = try Timeline.trackIndex(p.requiredString("trackId"), in: project)
        try Timeline.checkCompatible(asset, project.tracks[t])

        let sourceIn = Timeline.sourceTime(p, "sourceIn", asset) ?? .zero
        let sourceOut = Timeline.sourceTime(p, "sourceOut", asset) ?? (asset.image?.kind == .still ? sourceIn + Timeline.stillDuration : asset.duration)
        guard sourceIn < sourceOut, sourceOut <= asset.duration else {
            throw CommandError.invalid("timeline.place: need 0 ≤ sourceIn < sourceOut ≤ \(asset.duration.displaySeconds)s (asset duration)")
        }
        let start = ctx.timelineTime(p, "start", in: project) ?? project.tracks[t].end
        var clip = Clip(id: project.makeID("c"), assetID: asset.id, sourceIn: sourceIn, sourceOut: sourceOut, start: start)
        try Timeline.checkFree(project.tracks[t], start: clip.start, end: clip.end)
        if let other = p.string("linkTo") {
            let (lt, lc) = try Timeline.locate(clip: other, in: project)
            let link = project.tracks[lt].clips[lc].link ?? project.makeID("l")
            project.tracks[lt].clips[lc].link = link
            clip.link = link
        }
        project.tracks[t].clips.append(clip)
        project.tracks[t].sortClips()
        ctx.project = project
        var result: [String: JSONValue] = ["clip": ProjectState.summary(of: clip), "trackId": .string(project.tracks[t].id)]
        if p.bool("frameOnFace") == true { try frameOnFace(clip.id, into: &result, &ctx) }
        return .object(result)
    }

    /// The placed clip framed on its face for the project's aspect (#154), as a take joining a project is: its faces
    /// tracked first when the asset has no face track (a face engine permitting), then FaceReframe at the zoom it has.
    /// Nothing to do for a clip that shows its whole source at the project's aspect, or that is no camera picture.
    static func frameOnFace(_ clipID: String, into result: inout [String: JSONValue], _ ctx: inout CommandContext) throws {
        var project = try ctx.requireProject()
        let aspect = Double(project.settings.width) / Double(max(project.settings.height, 1))
        guard let at = FaceReframe.candidates(project, aspect: aspect).first(where: { project.tracks[$0.track].clips[$0.clip].id == clipID })
        else { return }
        let aid = project.tracks[at.track].clips[at.clip].assetID
        var log: [JSONValue] = [], tracked: [JSONValue] = [], warnings: [JSONValue] = []
        if project.asset(aid)?.analysis?.faces == nil {
            if ctx.services.faces == nil {
                warnings.append("no face engine in this host: the clip is cropped around its centre")
            } else {
                do {
                    try ctx.perform(FacesTrack.self, ["assetId": .string(aid)], log: &log)
                    tracked.append(.string(aid))
                } catch {
                    warnings.append(.string("faces of \(aid) not tracked (\((error as? CommandError)?.message ?? "\(error)")): the clip is cropped around its centre"))
                }
                project = try ctx.requireProject()
            }
        }
        var cache: [String: FaceTrack] = [:]
        let framed = FaceReframe.apply(&project, from: aspect, to: aspect, only: [clipID]) { FaceReframe.track($0, cache: &cache) }
        ctx.project = project
        result["tracked"] = .array(tracked)
        result["reframed"] = .array(framed.map(\.json))
        if !warnings.isEmpty { result["warnings"] = .array(warnings) }
        if !log.isEmpty { result["commands"] = .array(log) }
    }
}

enum TimelineCut: Command {
    static let id = "timeline.cut"
    static let summary = "Razor: split clips at a timeline time (e.g. before deleting a piece). The left part keeps the clip id, the right part gets a new id (right parts of linked clips stay linked together). Without clipId/trackId, cuts every unlocked track that has a clip there; with them, the linked clips are cut too. Returns the new clip ids."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("at", .time, "Timeline time of the cut."),
        .optional("clipId", .string, "Only cut this clip (and its linked clips)."),
        .optional("trackId", .string, "Only cut the clip of this track (and its linked clips)."),
        Timeline.linkedParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let at = ctx.timelineTime(p, "at", in: project) ?? .zero
        let inside = { (c: Clip) in c.start < at && at < c.end }

        var targets: [(track: Int, clip: Int)] = []
        if let clipID = p.string("clipId") {
            let loc = try Timeline.locate(clip: clipID, in: project)
            guard inside(project.tracks[loc.track].clips[loc.clip]) else {
                throw CommandError.invalid("timeline.cut: \(at.displaySeconds)s is not strictly inside clip \(clipID)")
            }
            targets = [loc]
        } else if let trackID = p.string("trackId") {
            let t = try Timeline.trackIndex(trackID, in: project)
            guard let c = project.tracks[t].clips.firstIndex(where: inside) else {
                throw CommandError.invalid("timeline.cut: no clip of \(trackID) spans \(at.displaySeconds)s")
            }
            targets = [(t, c)]
        } else {
            for (t, track) in project.tracks.enumerated() where !track.locked {
                if let c = track.clips.firstIndex(where: inside) { targets.append((t, c)) }
            }
            guard !targets.isEmpty else { throw CommandError.invalid("timeline.cut: no clip spans \(at.displaySeconds)s") }
        }
        if p.bool("linked") ?? true {
            for (t, c) in targets {
                for q in Timeline.partners(of: project.tracks[t].clips[c], in: project)
                where inside(project.tracks[q.track].clips[q.clip]) && !project.tracks[q.track].locked
                    && !targets.contains(where: { $0 == q }) {
                    targets.append(q)
                }
            }
        }

        var cuts: [JSONValue] = []
        var rightLinks: [String: String] = [:]
        for (t, c) in targets {
            let original = project.tracks[t].clips[c]
            var (left, right) = original.split(at: at - original.start, rightID: project.makeID("c"))
            if let link = left.link {
                if rightLinks[link] == nil { rightLinks[link] = project.makeID("l") }
                right.link = rightLinks[link]
            }
            project.tracks[t].clips[c] = left
            project.tracks[t].clips.insert(right, at: c + 1)
            cuts.append(["trackId": .string(project.tracks[t].id), "left": .string(left.id), "right": .string(right.id)])
        }
        ctx.project = project
        return ["at": ProjectState.seconds(at), "cuts": .array(cuts)]
    }
}

enum TimelineTrim: Command {
    static let id = "timeline.trim"
    static let summary = "Move the start or end edge of a clip to a timeline time, revealing or hiding source media (tighten a pause, restore a clipped word). Linked clips whose same edge sits at the same time follow. With ripple, later clips on the track shift to keep their distance. Returns the changed clips."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipId", .string, "Clip id."),
        .required("edge", .oneOf(["start", "end"]), "Which edge to move."),
        .required("to", .time, "New timeline time of that edge."),
        .optional("ripple", .boolean, "Shift the following clips of the track by the change (default false). A rippled start trim keeps the clip's start in place."),
        Timeline.linkedParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let clipID = p.requiredString("clipId")
        let (t, c) = try Timeline.locate(clip: clipID, in: project)
        let to = ctx.timelineTime(p, "to", in: project) ?? .zero
        let ripple = p.bool("ripple") ?? false
        let startEdge = p.requiredString("edge") == "start"
        let clip = project.tracks[t].clips[c]
        var ids = [clipID]
        if p.bool("linked") ?? true {
            ids += Timeline.partners(of: clip, in: project).map { project.tracks[$0.track].clips[$0.clip] }
                .filter { startEdge ? $0.start == clip.start : $0.end == clip.end }.map(\.id)
        }
        var trimmed = clip
        for id in ids {
            let r = try trim(id, startEdge: startEdge, to: to, ripple: ripple, in: &project)
            if id == clipID { trimmed = r }
        }
        ctx.project = project
        return ["clip": ProjectState.summary(of: trimmed), "linked": .array(ids.dropFirst().map { .string($0) })]
    }

    static func trim(_ clipID: String, startEdge: Bool, to: MediaTime, ripple: Bool, in project: inout Project) throws -> Clip {
        let (t, c) = try Timeline.locate(clip: clipID, in: project)
        var track = project.tracks[t]
        var clip = track.clips[c]
        let oldEnd = clip.end
        // A title has no media: its "source" never ends.
        guard let sourceDuration = project.asset(clip.assetID)?.duration ?? (clip.isGenerated ? MediaTime(seconds: 86_400) : nil) else {
            throw CommandError.notFound("Asset \(clip.assetID) missing")
        }

        // A constant-speed clip trims through its rate; ramps, reversed and frozen clips are retimed after trimming.
        let rate = clip.speed?.rate ?? 1
        if let sp = clip.speed, sp.isRamp || sp.reverse == true || sp.freeze == true {
            throw CommandError.conflict("timeline.trim: \(clipID) has a speed ramp, reverse or freeze: reset it (clip.speed rate 1), trim, then retime")
        }
        func source(_ t: MediaTime) -> MediaTime { rate == 1 ? t : MediaTime(seconds: t.seconds * rate) }
        func timeline(_ s: MediaTime) -> MediaTime { rate == 1 ? s : MediaTime(seconds: s.seconds / rate) }
        if startEdge {
            let earliest = clip.start - timeline(clip.sourceIn)   // where source time 0 would sit
            guard to >= earliest, to < clip.end else {
                throw CommandError.invalid("timeline.trim: start of \(clipID) must be in [\(earliest.displaySeconds), \(clip.end.displaySeconds))s")
            }
            if clip.speed != nil {
                clip.speed!.duration = clip.end - to
                clip.sourceIn = max(clip.sourceOut - source(clip.speed!.duration), .zero)
            } else {
                clip.sourceIn += to - clip.start
            }
            if ripple {
                // The clip keeps its start; everything after moves by the length change.
                track.clips[c] = clip
                Timeline.shift(&track, from: oldEnd, by: clip.end - oldEnd, except: clip.id)
            } else {
                clip.start = to
                try Timeline.checkFree(track, start: clip.start, end: clip.end, except: clip.id)
                track.clips[c] = clip
            }
        } else {
            let latest = clip.start + timeline(sourceDuration - clip.sourceIn)   // where the source ends
            guard to > clip.start, to <= latest else {
                throw CommandError.invalid("timeline.trim: end of \(clipID) must be in (\(clip.start.displaySeconds), \(latest.displaySeconds)]s")
            }
            if clip.speed != nil {
                clip.speed!.duration = to - clip.start
                clip.sourceOut = min(clip.sourceIn + source(clip.speed!.duration), sourceDuration)
            } else {
                clip.sourceOut += to - clip.end
            }
            track.clips[c] = clip
            if ripple {
                Timeline.shift(&track, from: oldEnd, by: clip.end - oldEnd, except: clip.id)
            } else {
                try Timeline.checkFree(track, start: clip.start, end: clip.end, except: clip.id)
            }
        }
        track.sortClips()
        project.tracks[t] = track
        return clip
    }
}

enum TimelineMove: Command {
    static let id = "timeline.move"
    static let summary = "Move a clip to another time and optionally another track of a compatible kind; linked clips move by the same amount on their own tracks. Fails if a spot is occupied. Returns the moved clips."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipId", .string, "Clip id."),
        .required("start", .time, "New timeline start."),
        .optional("trackId", .string, "Destination track (default: same track)."),
        Timeline.linkedParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let (t, c) = try Timeline.locate(clip: p.requiredString("clipId"), in: project)
        let clip = project.tracks[t].clips[c]
        let dest = try p.string("trackId").map { try Timeline.trackIndex($0, in: project) } ?? t
        if dest != t, let asset = project.asset(clip.assetID) { try Timeline.checkCompatible(asset, project.tracks[dest]) }
        let delta = (ctx.timelineTime(p, "start", in: project) ?? .zero) - clip.start

        var moving = [(track: t, dest: dest, clip: clip)]
        if p.bool("linked") ?? true {
            for q in Timeline.partners(of: clip, in: project) {
                if project.tracks[q.track].locked { throw CommandError.conflict("Linked clip \(project.tracks[q.track].clips[q.clip].id) is on locked track \(project.tracks[q.track].name)") }
                moving.append((q.track, q.track, project.tracks[q.track].clips[q.clip]))
            }
        }
        let ids = Set(moving.map(\.clip.id))
        for i in project.tracks.indices { project.tracks[i].clips.removeAll { ids.contains($0.id) } }
        for m in moving {
            var moved = m.clip
            moved.start += delta
            try Timeline.checkFree(project.tracks[m.dest], start: moved.start, end: moved.end)
            project.tracks[m.dest].clips.append(moved)
            project.tracks[m.dest].sortClips()
        }
        var result = clip
        result.start += delta
        ctx.project = project
        return ["clip": ProjectState.summary(of: result), "trackId": .string(project.tracks[dest].id),
                "linked": .array(moving.dropFirst().map { .string($0.clip.id) })]
    }
}

enum TimelineDelete: Command {
    static let id = "timeline.delete"
    static let summary = "Remove clips and the clips linked to them. With ripple, the following clips of each affected track move left to close the gap (other tracks are not touched). For removing words prefer transcript.deleteWords. Returns what was removed."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("clipId", .string, "One clip id."),
        .optional("clipIds", .array(.string), "Several clip ids."),
        .optional("ripple", .boolean, "Close the gap left by each clip (default false)."),
        Timeline.linkedParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        var ids = p.strings("clipIds") ?? []
        if let one = p.string("clipId") { ids.append(one) }
        guard !ids.isEmpty else { throw CommandError.invalid("timeline.delete: pass clipId or clipIds") }
        let ripple = p.bool("ripple") ?? false

        // Validate everything first, then delete from the right so ripples don't interfere.
        var doomed: [(track: Int, clip: Clip)] = []
        for id in Set(ids) {
            let loc = try Timeline.locate(clip: id, in: project)
            doomed.append((loc.track, project.tracks[loc.track].clips[loc.clip]))
        }
        if p.bool("linked") ?? true {
            for d in doomed {
                for q in Timeline.partners(of: d.clip, in: project) where !doomed.contains(where: { $0.clip.id == project.tracks[q.track].clips[q.clip].id }) {
                    let other = project.tracks[q.track].clips[q.clip]
                    if project.tracks[q.track].locked { throw CommandError.conflict("Linked clip \(other.id) is on locked track \(project.tracks[q.track].name)") }
                    doomed.append((q.track, other))
                }
            }
        }
        for (t, clip) in doomed.sorted(by: { $0.clip.start > $1.clip.start }) {
            project.tracks[t].clips.removeAll { $0.id == clip.id }
            if ripple { Timeline.shift(&project.tracks[t], from: clip.end, by: MediaTime.zero - clip.duration) }
        }
        ctx.project = project
        return ["deleted": .array(doomed.map { .string($0.clip.id) }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") }),
                "ripple": .bool(ripple)]
    }
}

enum TimelineLink: Command {
    static let id = "timeline.link"
    static let summary = "Link clips (e.g. a picture clip and its sound) so place/move/trim/cut/delete act on all of them, or unlink them to edit picture and sound separately. Returns the link id."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipIds", .array(.string), "Clips to link together (or to unlink)."),
        .optional("unlink", .boolean, "Remove these clips from their link instead (default false)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let ids = p.strings("clipIds") ?? []
        let unlink = p.bool("unlink") ?? false
        guard unlink ? !ids.isEmpty : ids.count >= 2 else { throw CommandError.invalid("\(id): pass at least \(unlink ? 1 : 2) clip ids") }
        let locs = try ids.map { try Timeline.locate(clip: $0, in: project) }
        let link: String? = unlink ? nil : (locs.lazy.compactMap { project.tracks[$0.track].clips[$0.clip].link }.first ?? project.makeID("l"))
        for l in locs { project.tracks[l.track].clips[l.clip].link = link }
        ctx.project = project
        return ["clipIds": .array(ids.map { .string($0) }), "link": link.map { .string($0) } ?? .null]
    }
}

enum TimelineDuplicate: Command {
    static let id = "timeline.duplicate"
    static let summary = "Copy clips to another time on their own tracks (duplicate, or copy and paste at the playhead): every property comes along (position, grade, effects, speed, fades, gain, a title's text, a motion template's fields), the copies get new ids, and copies of clips linked together are linked together. Linked clips come along unless linked: false. Fails if a spot is occupied. Returns the new clips."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("clipIds", .array(.string), "Clips to copy."),
        .optional("start", .time, "Where the earliest copy begins (default: right after the last of the clips, or after the end of their tracks when that spot is taken)."),
        Timeline.linkedParam,
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let ids = p.strings("clipIds") ?? []
        guard !ids.isEmpty else { throw CommandError.invalid("\(id): pass clipIds") }
        var sources: [(track: Int, clip: Clip)] = []
        for cid in ids where !sources.contains(where: { $0.clip.id == cid }) {
            let loc = try Timeline.locate(clip: cid, in: project)
            sources.append((loc.track, project.tracks[loc.track].clips[loc.clip]))
        }
        let linked = p.bool("linked") ?? true
        if linked {
            for s in sources {
                for q in Timeline.partners(of: s.clip, in: project) where !sources.contains(where: { $0.clip.id == project.tracks[q.track].clips[q.clip].id }) {
                    sources.append((q.track, project.tracks[q.track].clips[q.clip]))
                }
            }
        }
        let first = sources.map(\.clip.start).min()!, last = sources.map(\.clip.end).max()!
        // Default: right after the clips, or after the end of their tracks when that spot is taken.
        let fits: (MediaTime) -> Bool = { at in
            sources.allSatisfy { project.tracks[$0.track].overlap(start: $0.clip.start + (at - first), end: $0.clip.end + (at - first)) == nil }
        }
        let target = ctx.timelineTime(p, "start", in: project)
            ?? (fits(last) ? last : Set(sources.map(\.track)).map { project.tracks[$0].end }.max()!)
        let offset = target - first
        var links: [String: String] = [:]
        var copies: [JSONValue] = []
        for (t, original) in sources.sorted(by: { ($0.clip.start, $0.track) < ($1.clip.start, $1.track) }) {
            guard !project.tracks[t].locked else { throw CommandError.conflict("\(id): track \(project.tracks[t].name) is locked") }
            var clip = original
            clip.id = project.makeID("c")
            clip.start = original.start + offset
            if let l = original.link, linked {
                if links[l] == nil { links[l] = project.makeID("l") }
                clip.link = links[l]
            } else {
                clip.link = nil
            }
            try Timeline.checkFree(project.tracks[t], start: clip.start, end: clip.end)
            project.tracks[t].clips.append(clip)
            project.tracks[t].sortClips()
            copies.append(["clip": ProjectState.summary(of: clip), "from": .string(original.id), "trackId": .string(project.tracks[t].id)])
        }
        ctx.project = project
        return ["clips": .array(copies), "offset": ProjectState.seconds(offset)]
    }
}
