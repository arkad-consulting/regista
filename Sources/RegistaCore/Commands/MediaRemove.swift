import Foundation

/// A file taken out of the project (#142): the asset and every clip that uses it, on any track, with the clips linked to
/// them (its sound). The gaps stay; the file itself is never touched.
enum MediaRemove: Command {
    static let id = "media.remove"
    static let summary = "Remove a media file from the project: the asset and every clip that uses it on any track, with the clips linked to them (its sound), leaving the gaps where they were. The file itself is never deleted or moved. One undo step. Returns the asset's name and how many clips were removed."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Asset id (project.state lists them)."),
    ]

    /// The clips that go with `assetID`: those that use it and the clips linked to them, as (track index, clip).
    static func clips(of assetID: String, in project: Project) -> [(track: Int, clip: Clip)] {
        var out: [(track: Int, clip: Clip)] = []
        for (t, track) in project.tracks.enumerated() {
            for clip in track.clips where clip.assetID == assetID { out.append((t, clip)) }
        }
        for using in out {
            for q in Timeline.partners(of: using.clip, in: project) {
                let other = project.tracks[q.track].clips[q.clip]
                if !out.contains(where: { $0.clip.id == other.id }) { out.append((q.track, other)) }
            }
        }
        return out
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        var project = try ctx.requireProject()
        let assetID = p.requiredString("assetId")
        guard let asset = project.asset(assetID) else {
            throw CommandError.notFound("\(id): no asset \(assetID) in the project (project.state lists them)")
        }
        let doomed = clips(of: assetID, in: project)
        if let locked = doomed.first(where: { project.tracks[$0.track].locked }) {
            throw CommandError.conflict("\(id): clip \(locked.clip.id) is on locked track \(project.tracks[locked.track].name); unlock it first (track.set locked: false)")
        }
        let ids = Set(doomed.map(\.clip.id))
        for t in project.tracks.indices { project.tracks[t].clips.removeAll { ids.contains($0.id) } }
        // A link group left with one clip is no longer a link.
        let remaining = Dictionary(grouping: project.tracks.flatMap(\.clips).compactMap(\.link), by: { $0 }).mapValues(\.count)
        for t in project.tracks.indices {
            for c in project.tracks[t].clips.indices {
                if let l = project.tracks[t].clips[c].link, (remaining[l] ?? 0) < 2 { project.tracks[t].clips[c].link = nil }
            }
        }
        project.assets.removeAll { $0.id == assetID }
        // What was found for this asset alone goes with it: its takes, a screen session none of whose files is left.
        if project.takes?.assetID == assetID { project.takes = nil }
        if let links = project.recordings {
            let paths = Set(project.assets.map(\.path))
            let kept = links.filter { l in
                let files = [l.screen, l.camera, l.mic, l.system].compactMap { $0 }
                return !files.contains(asset.path) || files.contains(where: paths.contains)
            }
            project.recordings = kept.isEmpty ? nil : kept
        }
        ctx.project = project
        return ["assetId": .string(assetID), "name": .string(asset.name), "path": .string(asset.path),
                "removedClips": .number(Double(doomed.count)), "clipIds": .array(doomed.map { .string($0.clip.id) }.sorted { ($0.stringValue ?? "") < ($1.stringValue ?? "") })]
    }
}

extension Project {
    /// The clips media.remove would take with `assetID`: those that use it and the clips linked to them (the app's
    /// alert counts them before asking).
    public func clips(removedWith assetID: String) -> [Clip] { MediaRemove.clips(of: assetID, in: self).map(\.clip) }
}
