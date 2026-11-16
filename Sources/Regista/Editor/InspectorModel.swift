import Foundation
import RegistaCore

// The clip inspector (E1 #53) without SwiftUI: what is selected, which fields it shows, and the command each field runs.
// Every edit goes through an existing command (clip.set, clip.place, clip.speed, timeline.move / trim, look.apply,
// effect.remove, audio.duck, track.set, captions.*, transcript.editText), so it is logged, undoable and what an agent
// would do over MCP.

/// What the inspector is asked to show: clips, or one caption block.
struct InspectorSelection: Equatable {
    var clips: Set<String> = []
    var caption: CaptionPick?
}

/// One caption block of a caption track (a click on the captions lane).
struct CaptionPick: Equatable, Hashable {
    var trackID: String
    var chunk: Int
}

/// The selection resolved against the project.
struct InspectorTarget {
    enum Kind: String {
        case none, video, audio, image, title, sticker, motion, graphic, captions, multi
    }

    struct Item {
        var track: Track
        var clip: Clip
    }

    var kind: Kind
    var items: [Item] = []
    var captionTrack: Track?
    var chunk: Int?

    var item: Item? { items.count == 1 ? items[0] : nil }
    var clipIDs: [String] { items.map(\.clip.id).sorted() }

    static func resolve(_ sel: InspectorSelection, in project: Project?) -> InspectorTarget {
        guard let p = project else { return InspectorTarget(kind: .none) }
        if let pick = sel.caption, let t = p.tracks.first(where: { $0.id == pick.trackID }), let caps = t.captions {
            return InspectorTarget(kind: .captions, captionTrack: t, chunk: caps.chunks.indices.contains(pick.chunk) ? pick.chunk : nil)
        }
        let items = p.tracks.flatMap { t in t.clips.filter { sel.clips.contains($0.id) }.map { Item(track: t, clip: $0) } }
        if items.isEmpty { return InspectorTarget(kind: .none) }
        if items.count > 1 { return InspectorTarget(kind: .multi, items: items) }
        return InspectorTarget(kind: kind(of: items[0], in: p), items: items)
    }

    static func kind(of it: Item, in p: Project) -> Kind {
        let c = it.clip
        if c.title != nil { return .title }
        if c.motion != nil { return .motion }
        if c.sticker != nil { return .sticker }
        if c.shape != nil { return .graphic }
        if it.track.kind == .audio { return .audio }
        if p.asset(c.assetID)?.image != nil { return .image }
        return .video
    }

    /// The sections drawn for this target, in order (also reported by ui.screenshot `inspector`).
    func sections(in p: Project?) -> [InspectorPart] {
        // A clip (or nothing selected) of a screen recording: the Schermo section (R2 #51).
        let screen = p.flatMap { ScreenLook.target(self, in: $0) } != nil
        switch kind {
        case .none: return screen ? [.project, .screen] : [.project]
        case .captions: return [.captionStyle, .captionText]
        case .multi:
            var s: [InspectorPart] = [.multi]
            if items.allSatisfy({ $0.track.kind != .audio }) { s += [.opacity, .color] }
            if items.allSatisfy({ $0.track.kind == .audio }) { s += [.audio] }
            return s
        case .audio:
            return [.timing, .audio, .speed]
        case .video:
            var s: [InspectorPart] = [.timing, .transform, .crop, .color, .speed, .fades]
            if screen { s.insert(.screen, at: 1) }
            if item.map({ !($0.clip.effects ?? []).isEmpty }) == true { s.append(.effects) }
            return s
        case .image, .title, .sticker, .motion, .graphic:
            var s: [InspectorPart] = [.timing]
            if kind == .title || kind == .motion { s.insert(.text, at: 0) }
            s.append(.transform)
            if kind == .image { s += [.color, .fades] }
            if let it = item, let p, InspectorEdits.faceSource(for: it.clip, in: p) != nil, kind != .motion { s.append(.follow) }
            if item.map({ !($0.clip.effects ?? []).isEmpty }) == true { s.append(.effects) }
            return s
        }
    }
}

/// A section of the inspector.
enum InspectorPart: String {
    case project, timing, text, transform, crop, color, speed, fades, audio, effects, follow, captionStyle, captionText, multi, opacity, screen
}

/// A numeric field of the inspector.
enum InspectorField: String, CaseIterable {
    case start, end, duration
    case x, y, scale, rotation, opacity
    case cropLeft, cropTop, cropRight, cropBottom
    case brightness, contrast, saturation, lookAmount
    case speed
    case fadeIn, fadeOut, gain, duck
    case pictureFadeIn, pictureFadeOut
}

/// One command: what a field change runs.
struct InspectorCommand: Equatable {
    var id: String
    var params: JSONValue
}

enum InspectorEdits {
    /// The clip is placed on the frame (titles, stickers, logos, native-size overlays, a picture once moved by hand):
    /// position, size and rotation are a view of its placement and go through clip.place (pixels of the frame), as a
    /// drag on the monitor does (#53).
    static func isPlaced(_ c: Clip) -> Bool {
        guard let pl = c.placement else { return false }
        return pl.fit != .fill && c.shape == nil
    }

    /// The current value of a field for one clip (frame pixels for positions, as the user sees them).
    static func value(_ f: InspectorField, _ it: InspectorTarget.Item, in p: Project) -> Double {
        let c = it.clip, tr = c.transform ?? Transform()
        let W = Double(p.settings.width), H = Double(p.settings.height)
        switch f {
        case .start: return c.start.seconds
        case .end: return c.end.seconds
        case .duration: return c.duration.seconds
        case .x: return isPlaced(c) ? ((c.placement!.x + tr.x) * W).rounded() : (tr.x * W).rounded()
        case .y: return isPlaced(c) ? ((c.placement!.y + tr.y) * H).rounded() : (tr.y * H).rounded()
        case .scale:
            // One size per picture (#53): a clip placed by hand shows the size its handles and the bar set — a box against
            // its size before the first move (a full-frame picture: the whole frame), else the rest scale clip.place
            // writes. A transform scale left on a box by an older Inspector still draws, but is not this value.
            if isPlaced(c), let base = c.boxBase, let w = c.placement?.width { return w / max(base.width, 1e-9) }
            return tr.scale
        case .rotation: return tr.rotation
        case .opacity: return tr.opacity
        case .cropLeft: return tr.cropLeft
        case .cropTop: return tr.cropTop
        case .cropRight: return tr.cropRight
        case .cropBottom: return tr.cropBottom
        case .brightness: return c.color?.brightness ?? 0
        case .contrast: return c.color?.contrast ?? 1
        case .saturation: return c.color?.saturation ?? 1
        case .lookAmount: return c.grade?.amount ?? 1
        case .speed: return c.speed?.rate ?? 1
        case .fadeIn: return (c.fadeIn ?? linkedAudio(of: c, in: p).first?.fadeIn)?.seconds ?? 0
        case .fadeOut: return (c.fadeOut ?? linkedAudio(of: c, in: p).first?.fadeOut)?.seconds ?? 0
        case .pictureFadeIn: return c.pictureFadeIn?.seconds ?? 0
        case .pictureFadeOut: return c.pictureFadeOut?.seconds ?? 0
        case .gain: return c.gain ?? 0
        case .duck: return it.track.ducking?.depth ?? 0
        }
    }

    /// The command that sets `f` to `v` on the target's clips (nil: nothing to do).
    static func command(_ f: InspectorField, _ v: Double, _ target: InspectorTarget, in p: Project) -> InspectorCommand? {
        guard let first = target.items.first else { return nil }
        let ids = JSONValue.array(target.clipIDs.map { .string($0) })
        let c = first.clip
        let one = JSONValue.string(c.id)
        func set(_ key: String, _ value: JSONValue, clips: JSONValue? = nil) -> InspectorCommand {
            InspectorCommand(id: "clip.set", params: ["clipIds": clips ?? ids, key: value])
        }
        let fps = p.settings.frameRate.doubleValue
        func snap(_ t: Double) -> Double { max(0, (t * fps).rounded() / fps) }
        switch f {
        case .start:
            return InspectorCommand(id: "timeline.move", params: ["clipId": one, "start": .number(snap(v))])
        case .end:
            return InspectorCommand(id: "timeline.trim", params: ["clipId": one, "edge": "end", "to": .number(snap(v))])
        case .duration:
            return InspectorCommand(id: "timeline.trim", params: ["clipId": one, "edge": "end", "to": .number(snap(c.start.seconds + max(v, 1 / fps)))])
        case .x, .y:
            let W = Double(p.settings.width), H = Double(p.settings.height)
            if target.items.count == 1, isPlaced(c) { return InspectorCommand(id: "clip.place", params: ["clipId": one, f.rawValue: .number(v.rounded())]) }
            return set(f.rawValue, .number(f == .x ? v / W : v / H))
        case .scale, .rotation:
            if target.items.count == 1, isPlaced(c) { return InspectorCommand(id: "clip.place", params: ["clipId": one, f.rawValue: .number(v)]) }
            return set(f.rawValue, .number(v))
        case .opacity: return set("opacity", .number(min(max(v, 0), 1)))
        case .brightness, .contrast, .saturation: return set(f.rawValue, .number(v))
        case .cropLeft, .cropTop, .cropRight, .cropBottom:
            guard let video = p.asset(c.assetID)?.video else { return nil }
            var tr = c.transform ?? Transform()
            let edge = min(max(v, 0), 0.45)
            switch f {
            case .cropLeft: tr.cropLeft = edge
            case .cropTop: tr.cropTop = edge
            case .cropRight: tr.cropRight = edge
            default: tr.cropBottom = edge
            }
            let rect = tr.cropRect(sourceWidth: video.width, sourceHeight: video.height).map { ($0 * 100).rounded() / 100 }
            return InspectorCommand(id: "clip.set", params: ["clipId": one, "crop": .array(rect.map { .number($0) })])
        case .lookAmount:
            guard let look = c.grade?.look else { return nil }
            return InspectorCommand(id: "look.apply", params: ["look": .string(look), "amount": .number(min(max(v, 0), 1)), "clipIds": ids])
        case .speed:
            return InspectorCommand(id: "clip.speed", params: ["clipId": one, "rate": .number(min(max(v, Speed.minRate), Speed.maxRate))])
        case .fadeIn, .fadeOut:
            // On a picture clip the fades belong to its sound: the linked audio clips.
            var targets = target.clipIDs
            if target.kind == .video { targets = linkedAudio(of: c, in: p).map(\.id) }
            guard !targets.isEmpty else { return nil }
            return set(f.rawValue, .number(max(v, 0)), clips: .array(targets.map { .string($0) }))
        case .pictureFadeIn, .pictureFadeOut:
            return set(f.rawValue, .number(max((v * 100).rounded() / 100, 0)))
        case .gain:
            // A music bed is several looped clips: its volume is the whole track's (E3 #55).
            if target.items.count == 1, first.track.role == "music" {
                return InspectorCommand(id: "clip.set", params: ["trackId": .string(first.track.id), "gain": .number((v * 10).rounded() / 10)])
            }
            return set("gain", .number((v * 10).rounded() / 10))
        case .duck:
            return InspectorCommand(id: "audio.duck", params: ["trackId": .string(first.track.id), "duck": .number(v.rounded())])
        }
    }

    /// A fade on a picture clip and its linked sound together, in one clip.set (picture fades go to the picture clips,
    /// audio fades to the sound clips): the inspector's linked fades (#79).
    static func linkedFade(in edge: Bool, _ v: Double, _ target: InspectorTarget, in p: Project) -> InspectorCommand? {
        guard !target.items.isEmpty else { return nil }
        let sound = target.items.flatMap { linkedAudio(of: $0.clip, in: p) }.map(\.id)
        let ids = (target.clipIDs + sound).map { JSONValue.string($0) }
        let value = JSONValue.number(max((v * 100).rounded() / 100, 0))
        var o: [String: JSONValue] = ["clipIds": .array(ids), edge ? "pictureFadeIn" : "pictureFadeOut": value]
        if !sound.isEmpty { o[edge ? "fadeIn" : "fadeOut"] = value }
        return InspectorCommand(id: "clip.set", params: .object(o))
    }

    /// Crop back to the whole picture.
    static func resetCrop(_ it: InspectorTarget.Item, in p: Project) -> InspectorCommand? {
        guard let v = p.asset(it.clip.assetID)?.video else { return nil }
        return InspectorCommand(id: "clip.set", params: ["clipId": .string(it.clip.id), "crop": [.number(Double(v.width)), .number(Double(v.height)), 0, 0]])
    }

    /// The audio clips linked to a picture clip (its sound).
    static func linkedAudio(of c: Clip, in p: Project) -> [Clip] {
        guard let link = c.link else { return [] }
        return p.tracks.filter { $0.kind == .audio }.flatMap(\.clips).filter { $0.link == link && $0.id != c.id }
    }

    /// The video asset with face data under an overlay (what "Segui il volto" follows), if any.
    static func faceSource(for c: Clip, in p: Project) -> MediaAsset? {
        let mid = c.start + MediaTime(seconds: c.duration.seconds / 2)
        for t in p.tracks where t.kind == .video {
            if let under = t.clips.first(where: { $0.start <= mid && mid < $0.end }), let a = p.asset(under.assetID), a.analysis?.faces != nil { return a }
        }
        return nil
    }

    /// Timeline word indices of a caption block (what transcript.editText takes).
    static func words(of chunk: RegistaCore.CaptionChunk, in words: [TimelineWord]) -> ClosedRange<Int>? {
        guard let a = chunk.words.first?.start else { return nil }
        let hits = words.filter { $0.start >= a - MediaTime(seconds: 0.005) && $0.start < chunk.end }.map(\.index)
        guard let lo = hits.min(), let hi = hits.max() else { return nil }
        return lo...hi
    }
}

/// Slider drags write only a draft; the command runs once, on release (one undo step per gesture).
struct InspectorDrafts {
    private(set) var values: [InspectorField: Double] = [:]

    func value(_ f: InspectorField, else current: Double) -> Double { values[f] ?? current }

    /// A step of a drag: the slider and the number follow, nothing runs.
    mutating func drag(_ f: InspectorField, _ v: Double) { values[f] = v }

    /// The drag ended: the value to commit (the draft stays until the next snapshot clears it, so nothing jumps back).
    func release(_ f: InspectorField) -> Double? { values[f] }

    /// A new snapshot of the project arrived.
    mutating func clear() { values = [:] }
}
