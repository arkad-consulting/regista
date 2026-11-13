import Foundation

enum MediaImport: Command {
    static let id = "media.import"
    static let summary = "Add a media file (from media.list) to the project before using it: reads duration, fps, size, rotation and audio with ffprobe; the file is never modified. A teleprompter recording's live take markers (<name>.takes.json next to it) come along for takes.list. A picture (PNG, JPEG, HEIC, WebP, SVG rasterized) becomes a still image asset, placed as an overlay (overlay.add) or on a track (timeline.place: 5 s by default). Importing the same path twice returns the existing asset. Returns the asset (its id, e.g. a1, is what the other tools take)."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("path", .string, "Absolute path of the video, audio or image file (~ is expanded)."),
        .optional("name", .string, "Display name (default: file name)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let url = URL(fileURLWithPath: (p.requiredString("path") as NSString).expandingTildeInPath).standardizedFileURL
        if let existing = project.assets.first(where: { $0.path == url.path }) {
            return ["asset": ProjectState.summary(of: existing), "existing": true]
        }
        guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError.notFound("media.import: no file at \(url.path)") }
        // Pictures are stills drawn from the file by the compositor, as overlay.add imports them.
        let ext = url.pathExtension.lowercased()
        if Graphics.imageExtensions.contains(ext) || ext == "svg" {
            let assetID = try Graphics.importVisual(url.path, into: &project, &ctx, command: id)
            if let n = p.string("name"), let i = project.assets.firstIndex(where: { $0.id == assetID }) { project.assets[i].name = n }
            ctx.project = project
            return ["asset": ProjectState.summary(of: project.asset(assetID)!), "existing": false, "liveTakeMarkers": .null]
        }
        let info = try ctx.prober.probe(url)
        var asset = MediaAsset(id: project.makeID("a"), name: p.string("name") ?? url.lastPathComponent, path: url.path,
                               duration: info.duration, video: info.video, audio: info.audio)
        // A teleprompter recording brings its live take markers along.
        let live = try? LiveTakeLog.read(LiveTakeLog.sidecar(for: url))
        if let live { asset.analysis = AssetAnalysis(); asset.analysis?.liveTakes = live }
        project.assets.append(asset)
        ctx.project = project
        return ["asset": ProjectState.summary(of: asset), "existing": false, "liveTakeMarkers": live.map { .number(Double($0.markers.count)) } ?? .null]
    }
}

enum TrackAdd: Command {
    static let id = "track.add"
    static let summary = "Add a video, audio, caption or overlay track (edit.autoCut and captions.generate create theirs, so you rarely need this). Tracks stack bottom to top: a later video/overlay track is drawn above earlier ones. Returns the track id."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("kind", .oneOf(TrackKind.allCases.map(\.rawValue)), "Track kind."),
        .optional("name", .string, "Track name (default V1, A1, C1, O1… by kind)."),
        .optional("index", .integer, "Position in the stack, 0 = bottom (default: top)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let kind = TrackKind(rawValue: p.requiredString("kind"))!
        let sameKind = project.tracks.filter { $0.kind == kind }.count
        let track = Track(id: project.makeID("t"), kind: kind, name: p.string("name") ?? "\(kind.namePrefix)\(sameKind + 1)")
        let index = p.int("index") ?? project.tracks.count
        guard (0...project.tracks.count).contains(index) else {
            throw CommandError.invalid("track.add: index \(index) out of 0...\(project.tracks.count)")
        }
        project.tracks.insert(track, at: index)
        ctx.project = project
        return ["track": ProjectState.summary(of: track), "index": .number(Double(index))]
    }
}

enum TrackDelete: Command {
    static let id = "track.delete"
    static let summary = "Remove a track. A track that still holds clips needs force: true (its clips go with it; links to clips on other tracks are dropped). One undo step. Returns the removed track."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("trackId", .string, "Track id."),
        .optional("force", .boolean, "Also remove the clips on it (default false: refuse when the track is not empty)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let t = try Timeline.trackIndex(p.requiredString("trackId"), in: project, editable: false)
        let track = project.tracks[t]
        if !track.clips.isEmpty, p.bool("force") != true {
            throw CommandError.conflict("\(id): track \(track.name) holds \(track.clips.count) clips; pass force: true to remove them too")
        }
        project.tracks.remove(at: t)
        // A link group left with one clip is no longer a link.
        let remaining = Dictionary(grouping: project.tracks.flatMap(\.clips).compactMap(\.link), by: { $0 }).mapValues(\.count)
        for ti in project.tracks.indices {
            for ci in project.tracks[ti].clips.indices {
                if let l = project.tracks[ti].clips[ci].link, (remaining[l] ?? 0) < 2 { project.tracks[ti].clips[ci].link = nil }
            }
        }
        ctx.project = project
        return ["track": ProjectState.summary(of: track), "removedClips": .number(Double(track.clips.count))]
    }
}

enum TrackSet: Command {
    static let id = "track.set"
    static let summary = "Rename a track or change its locked / muted / hidden flags (locked tracks refuse edits; muted audio is left out of the export mix; hidden video is not drawn). Returns the track."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("trackId", .string, "Track id."),
        .optional("name", .string, "New name."),
        .optional("locked", .boolean, "Lock or unlock."),
        .optional("muted", .boolean, "Mute or unmute (audio)."),
        .optional("hidden", .boolean, "Hide or show (video)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let t = try Timeline.trackIndex(p.requiredString("trackId"), in: project, editable: false)
        if let v = p.string("name") { project.tracks[t].name = v }
        if let v = p.bool("locked") { project.tracks[t].locked = v }
        if let v = p.bool("muted") { project.tracks[t].muted = v }
        if let v = p.bool("hidden") { project.tracks[t].hidden = v }
        ctx.project = project
        return ["track": ProjectState.summary(of: project.tracks[t])]
    }
}
