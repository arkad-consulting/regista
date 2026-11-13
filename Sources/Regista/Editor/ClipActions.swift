import AppKit
import Foundation
import RegistaCore

// The basic gestures on timeline clips (E1 #53): the context menu, copy / paste / duplicate, and placing media dragged
// from the Media panel or the Finder. Each one is commands through the tab's store.

/// What the context menu of a clip can do.
enum ClipAction: Equatable {
    case cutAtPlayhead, splitHere(Double), delete, rippleDelete, duplicate, unlink, link, speed(Double)
    case showInInspector, revealInMedia, showInFinder

    /// The command it runs on `clip` (with the selection it belongs to), nil for the actions that only show something.
    static func command(_ a: ClipAction, clip: Clip, selection: Set<String>, playhead: Double, in p: Project) -> InspectorCommand? {
        let group = selection.contains(clip.id) ? selection : [clip.id]
        let ids = JSONValue.array(group.sorted().map { .string($0) })
        let fps = p.settings.frameRate.doubleValue
        func snap(_ t: Double) -> Double { max(0, (t * fps).rounded() / fps) }
        switch a {
        case .cutAtPlayhead: return InspectorCommand(id: "timeline.cut", params: ["at": .number(snap(playhead))])
        case .splitHere(let t): return InspectorCommand(id: "timeline.cut", params: ["at": .number(snap(t)), "clipId": .string(clip.id)])
        case .delete: return InspectorCommand(id: "timeline.delete", params: ["clipIds": ids, "ripple": false])
        case .rippleDelete: return InspectorCommand(id: "timeline.delete", params: ["clipIds": ids, "ripple": true])
        case .duplicate: return InspectorCommand(id: "timeline.duplicate", params: ["clipIds": ids])
        case .unlink:
            let partners = p.tracks.flatMap(\.clips).filter { clip.link != nil && $0.link == clip.link }.map(\.id)
            return InspectorCommand(id: "timeline.link", params: ["clipIds": .array(partners.sorted().map { .string($0) }), "unlink": true])
        case .link: return InspectorCommand(id: "timeline.link", params: ["clipIds": ids])
        case .speed(let r): return InspectorCommand(id: "clip.speed", params: ["clipId": .string(clip.id), "rate": .number(r)])
        case .showInInspector, .revealInMedia, .showInFinder: return nil
        }
    }
}

/// Media dragged onto the timeline: where it lands and on which tracks.
enum MediaDrop {
    /// A track row of the timeline, the empty slot of a standard track, the empty space under the tracks (a new track
    /// of the right kind), or `auto` (the first free track of the right kind, created if none).
    enum Target: Equatable {
        case track(String)
        case slot(TrackKind)
        case below
        case auto
    }

    /// How long a still image dropped on the timeline stays (overlay.add `duration`).
    static let stillSeconds = 5.0
    /// Text payload of a Media tile being dragged (`regista-asset:a3`).
    static let assetPrefix = "regista-asset:"

    /// `t` moved to the playhead or a clip edge within `tolerance` seconds, then to the frame grid.
    static func snap(_ t: Double, project: Project, playhead: Double, tolerance: Double) -> Double {
        let edges: [Double] = [0, playhead] + project.tracks.flatMap(\.clips).flatMap { [$0.start.seconds, $0.end.seconds] }
        let near = edges.min { abs($0 - t) < abs($1 - t) }
        let s = near.flatMap { abs($0 - t) <= tolerance ? $0 : nil } ?? t
        let fps = project.settings.frameRate.doubleValue
        return max(0, (s * fps).rounded() / fps)
    }

    /// Places asset `id` at `time`: a picture as an overlay of 5 s (overlay.add), a video on a video track with its sound
    /// on an audio track, linked, an audio file on an audio track. Missing tracks are created (track.add). `run` executes
    /// one command and returns its result (the store's `perform`, or an engine in tests). Returns the new clip ids.
    @discardableResult
    static func place(_ id: String, at time: Double, on target: Target, project start: Project,
                      run: (String, JSONValue) async throws -> JSONValue, latest current: () -> Project?) async throws -> [String] {
        guard let asset = start.asset(id) else { return [] }
        let t = JSONValue.number(time)
        let targetTrack: Track? = { if case .track(let tid) = target { return start.tracks.first { $0.id == tid } }; return nil }()
        if let im = asset.image {
            var params: [String: JSONValue] = ["path": .string(asset.path), "start": t, "fit": "contain"]
            if im.kind == .still { params["duration"] = .number(stillSeconds) }
            if let tr = targetTrack, tr.kind == .video || tr.kind == .overlay { params["trackId"] = .string(tr.id) }
            let r = try await run("overlay.add", .object(params))
            return [r.value(at: "clip.id")?.stringValue].compactMap { $0 }
        }
        func free(_ tr: Track, for seconds: Double) -> Bool {
            !tr.locked && !tr.clips.contains { $0.start.seconds < time + seconds - 1e-6 && time < $0.end.seconds - 1e-6 }
        }
        let length = asset.duration.seconds
        func track(_ kind: TrackKind, preferred: Track?) async throws -> String {
            if let tr = preferred, tr.kind == kind || (kind == .video && tr.kind == .overlay) { return tr.id }
            if case .slot(let k) = target, k == kind || (kind == .video && k == .overlay) {
                return try await run("track.add", ["kind": .string(k.rawValue)]).value(at: "track.id")?.stringValue ?? ""
            }
            let p = current() ?? start
            if target != .below, let tr = p.tracks.first(where: { $0.kind == kind && ($0.role == nil || $0.role == "voice") && free($0, for: length) }) { return tr.id }
            return try await run("track.add", ["kind": .string(kind.rawValue)]).value(at: "track.id")?.stringValue ?? ""
        }
        var placed: [String] = []
        var picture: String?
        if asset.video != nil {
            let tid = try await track(.video, preferred: targetTrack)
            picture = try await run("timeline.place", ["assetId": .string(id), "trackId": .string(tid), "start": t]).value(at: "clip.id")?.stringValue
            if let picture { placed.append(picture) }
        }
        if asset.audio != nil {
            let preferred = targetTrack?.kind == .audio ? targetTrack : nil
            let tid = try await track(.audio, preferred: preferred)
            var params: [String: JSONValue] = ["assetId": .string(id), "trackId": .string(tid), "start": t]
            if let picture { params["linkTo"] = .string(picture) }
            if let c = try await run("timeline.place", .object(params)).value(at: "clip.id")?.stringValue { placed.append(c) }
        }
        return placed
    }
}

extension EditorStore {
    func copySelection() -> Bool {
        guard !selection.isEmpty else { return false }
        clipboard = selection.sorted()
        return true
    }

    func pasteAtPlayhead() -> Bool {
        let ids = clipboard.filter { id in project?.locate(clip: id) != nil }
        guard !ids.isEmpty else { return false }
        run("timeline.duplicate", ["clipIds": .array(ids.map { .string($0) }), "start": .number(preview.time)])
        return true
    }

    func duplicateSelection() -> Bool {
        guard !selection.isEmpty else { return false }
        run("timeline.duplicate", ["clipIds": .array(selection.sorted().map { .string($0) })])
        return true
    }

    /// A context-menu action on `clip`.
    func perform(_ a: ClipAction, on clip: Clip) {
        guard let p = project else { return }
        switch a {
        case .showInInspector:
            if !selection.contains(clip.id) { selection = [clip.id] }
            captionPick = nil
            nav.rightTab = .inspector
        case .revealInMedia:
            sourceAssetID = clip.assetID
            if nav.activity != .media { select(.media) }
        case .showInFinder:
            if let a = p.asset(clip.assetID) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }
        default:
            guard let cmd = ClipAction.command(a, clip: clip, selection: selection, playhead: preview.time, in: p) else { return }
            if a == .delete || a == .rippleDelete { selection = [] }
            run(cmd.id, cmd.params)
        }
    }

    /// Media dropped on the timeline: asset ids from the Media panel, or files from the Finder (imported first).
    func dropMedia(assets: [String], files: [URL], at time: Double, on target: MediaDrop.Target) {
        Task {
            do {
                var ids = assets
                for url in files {
                    if let id = try await perform("media.import", ["path": .string(url.path)]).value(at: "asset.id")?.stringValue { ids.append(id) }
                }
                var at = time
                for id in ids {
                    guard let p = project, let asset = p.asset(id) else { continue }
                    let placed = try await MediaDrop.place(id, at: at, on: target, project: p, run: { try await self.perform($0, $1) },
                                                           latest: { self.project })
                    if !placed.isEmpty { selection = Set(placed) }
                    at += asset.image?.kind == .still ? MediaDrop.stillSeconds : asset.duration.seconds
                }
            } catch {
                errorMessage = loc("Il file non si è potuto mettere nella timeline: %@", "\(error)")
            }
        }
    }
}
