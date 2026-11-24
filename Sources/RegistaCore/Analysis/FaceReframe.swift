import Foundation

/// A change of aspect that keeps the face in frame: a full-frame camera clip drawn at another aspect (project.format, an
/// export or contact-sheet preset of another aspect, a take joining a project of another format) is cropped on its face
/// track with the rules of edit.punchIns (`FaceFraming.cropPath`: every face kept, room above the hair, never a head cut,
/// static when one crop holds the shot, else smoothed and speed-limited), at the zoom the clip has now. A clip without a
/// face track, or without a face in its range (a screen, B-roll), keeps its crop: the renderer centres it.
public enum FaceReframe {
    /// What happened to one clip.
    public struct Row: Sendable {
        public var clipID: String
        public var faces: Int
        public var fits: Bool
        public var keyframes: Int

        public var json: JSONValue {
            ["clipId": .string(clipID), "faces": .number(Double(faces)), "fits": .bool(fits), "keyframes": .number(Double(keyframes))]
        }
    }

    /// A clip the reframe may crop again: a camera picture filling the frame (a video asset, not an image, not generated,
    /// not a recording's screen), on a video track, whose keyframes (if any) move only the crop.
    static func reframable(_ clip: Clip, in project: Project, screens: Set<String>) -> Bool {
        guard !clip.isGenerated, clip.placement == nil || clip.placement?.fit == .fill,
              let asset = project.asset(clip.assetID), asset.video != nil, asset.image == nil, asset.generated == nil,
              !screens.contains(asset.id) else { return false }
        let rest = clip.transform ?? Transform()
        return (clip.keyframes ?? []).allSatisfy { k in
            var a = k.transform, b = rest
            (a.cropLeft, a.cropTop, a.cropRight, a.cropBottom) = (0, 0, 0, 0)
            (b.cropLeft, b.cropTop, b.cropRight, b.cropBottom) = (0, 0, 0, 0)
            return a == b
        }
    }

    /// The assets that are a recording's screen (never a face to frame on).
    static func screens(_ project: Project) -> Set<String> { Set((project.recordings ?? []).compactMap(\.screen)) }

    /// The clips of the video tracks a reframe to `aspect` touches: reframable, and cropped by hand or drawn from a source of
    /// another aspect (a clip that shows its whole source at the output's aspect has nothing to frame).
    public static func candidates(_ project: Project, aspect: Double) -> [(track: Int, clip: Int)] {
        let screens = screens(project)
        var out: [(Int, Int)] = []
        for (t, track) in project.tracks.enumerated() where track.kind == .video {
            for (c, clip) in track.clips.enumerated() where reframable(clip, in: project, screens: screens) {
                guard let v = project.asset(clip.assetID)?.video else { continue }
                let r = (clip.keyframes?.first?.transform ?? clip.transform ?? Transform()).cropRect(sourceWidth: v.width, sourceHeight: v.height)
                let whole = abs(r[0] - Double(v.width)) < 0.5 && abs(r[1] - Double(v.height)) < 0.5
                if !whole || abs(Double(v.width) / Double(v.height) - aspect) > 1e-3 { out.append((t, c)) }
            }
        }
        return out
    }

    /// The largest crop of `aspect` inside a `w`×`h` source: its height.
    static func maxHeight(_ w: Double, _ h: Double, aspect: Double) -> Double { w / h > aspect ? h : w / aspect }

    /// Crops the candidate clips (`candidates`) of `project`, drawn now at `from` (the output aspect before), for an output
    /// of aspect `to`, on the face tracks `faces` gives; `only`: those clips alone (a clip just placed). Returns the clips
    /// framed on a face.
    @discardableResult
    public static func apply(_ project: inout Project, from: Double, to aspect: Double, only: Set<String>? = nil,
                             faces: (MediaAsset) -> FaceTrack?) -> [Row] {
        var rows: [Row] = []
        for (t, c) in candidates(project, aspect: aspect) {
            var clip = project.tracks[t].clips[c]
            if let only, !only.contains(clip.id) { continue }
            guard let asset = project.asset(clip.assetID), let v = asset.video, let track = faces(asset) else { continue }
            let W = Double(v.width), H = Double(v.height)
            // The zoom the clip has now: the height it is drawn with, against the largest crop of the aspect it is drawn at.
            let rest = clip.transform ?? Transform()
            let r = (clip.keyframes?.first?.transform ?? rest).cropRect(sourceWidth: v.width, sourceHeight: v.height)
            let drawn = RenderJob.fit(r, aspect: from, within: (W, H))
            let zoom = min(max(drawn[1] / maxHeight(W, H, aspect: from), 0.2), 1)
            guard let path = FaceFraming.cropPath(track, from: clip.sourceIn.seconds, to: clip.sourceOut.seconds, frame: (v.width, v.height),
                                                  aspect: aspect, options: FaceFraming.Options(zoom: zoom)) else { continue }
            // Inside the source (rounding), then written as clip.set writes a crop and its keyframes.
            func inside(_ k: [Double]) -> JSONValue {
                let w = min(k[0], W), h = min(k[1], H)
                return .array([w, h, min(max(k[2], 0), W - w), min(max(k[3], 0), H - h)].map { .number($0) })
            }
            var tr = rest
            do {
                try ClipSet.apply(["crop": inside(path.points[0].crop)], to: &tr, video: v, clip: clip.id)
                clip.keyframes = path.points.count > 1
                    ? try ClipSet.keyframes(path.points.map { ["time": .number($0.time), "crop": inside($0.crop)] }, rest: tr, video: v, clip: clip.id,
                                            command: ProjectFormat.id)
                    : nil
            } catch { continue }
            clip.transform = tr
            project.tracks[t].clips[c] = clip
            rows.append(Row(clipID: clip.id, faces: path.faces, fits: path.fits, keyframes: path.points.count > 1 ? path.points.count : 0))
        }
        return rows
    }

    /// The face track of an asset from its sidecar (nil: none, or unreadable), read once per `cache`.
    public static func track(_ asset: MediaAsset, cache: inout [String: FaceTrack]) -> FaceTrack? {
        guard let path = asset.analysis?.faces?.path else { return nil }
        if let t = cache[path] { return t }
        guard let data = FileManager.default.contents(atPath: path), let t = try? JSONDecoder().decode(FaceTrack.self, from: data) else { return nil }
        cache[path] = t
        return t
    }

    /// The project as a preset of another aspect draws it (export.render, frame.render, frame.contactSheet): its camera
    /// clips framed on their faces for that aspect. The same project when the aspect is the project's own.
    public static func forPreset(_ project: Project, width: Int, height: Int) -> Project {
        let from = Double(project.settings.width) / Double(max(project.settings.height, 1)), to = Double(width) / Double(max(height, 1))
        guard abs(from - to) > 1e-3 else { return project }
        var p = project, cache: [String: FaceTrack] = [:]
        apply(&p, from: from, to: to) { track($0, cache: &cache) }
        return p
    }
}
