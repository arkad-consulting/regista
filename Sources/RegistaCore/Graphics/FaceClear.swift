import Foundation

// Graphics kept off the speaker's face (#16). A motion template added without a position and layout.speaker's bubble
// over the speaker pick, among the places they allow, the first that leaves the face free over their whole time — the
// face test of the captions (`OutputFaces.firstOverlap`: the face track through each clip's crop, frame by frame). A
// place given by the person or by Claude is never moved; it gets a warning when it covers the face. Without a face
// track nothing changes, and the result says once (its `faceCheck`) that the place was not checked.

enum FaceClear {
    /// The face-tracked state of the picture under [from, to): every main-picture video clip there and whether its
    /// asset has a face track. nil when no video clip is under it (a graphic over nothing: nothing to check).
    static func untracked(_ project: Project, from: MediaTime, to: MediaTime) -> (tracked: Bool, asset: String)? {
        let under = project.tracks.filter { $0.kind == .video }.flatMap(\.clips).filter { c in
            c.start < to && from < c.end && project.asset(c.assetID).map { $0.video != nil && $0.image == nil } == true
        }
        guard let first = under.first else { return nil }
        if let bare = under.first(where: { project.asset($0.assetID)?.analysis?.faces == nil }) { return (false, bare.assetID) }
        return (true, first.assetID)
    }

    /// The result's `faceCheck` when the place was not checked against a face.
    static func notChecked(asset: String) -> String {
        "not checked: the picture under it has no face track — faces.track {assetId: \"\(asset)\"} first, then add it again to keep it off the face"
    }

    /// The result's `faceCheck` after the face test.
    static func checked(covers: Bool) -> String { covers ? "checked: it covers the face (see warnings)" : "checked: the face stays clear" }

    /// The warning of a place given by hand that covers the face (the captions' wording: captions.checkFaces).
    static func placedOverFace(_ what: String, at t: MediaTime) -> String {
        "\(what) was placed by hand over a face at \(String(format: "%.2f", t.seconds)) s (left there)"
    }

    /// The warning when every allowed place covers the face at some point.
    static func noFreePlace(_ what: String, at t: MediaTime, places: [String]) -> String {
        "\(what) covers a face at \(String(format: "%.2f", t.seconds)) s wherever it may go (\(places.joined(separator: ", "))): kept at its default — give a position, or shorten it"
    }
}

/// Where a motion template sits when motion.add gets no position (#16).
enum MotionPlacement {
    struct Choice {
        var fields: [String: JSONValue]
        var warnings: [String] = []
        /// The place it went to ("band lower", "position [290, 540]"), when it was checked against a face.
        var place: String?
        /// Whether the place was checked against a face, and how it went (nil: nothing to check).
        var faceCheck: String?
    }

    /// The places a template may sit, as field overrides, its default first: its own `position` then the same point
    /// mirrored (templates placed by a point), or its band then the other bands. None for a template that fills the
    /// frame, re-draws the picture or is drawn around the person (behind, split): those go where they go by design.
    static func candidates(_ spec: MotionSpec, fields: [String: JSONValue]) -> [(name: String, fields: [String: JSONValue])] {
        guard !spec.coversFrame, !spec.consumesBelow, spec.layering == .front else { return [] }
        if spec.field("position")?.type == "point", let p = fields["position"]?.arrayValue?.compactMap(\.doubleValue), p.count == 2 {
            let mirrored = [SafeZones.referenceWidth - p[0], p[1]]
            func name(_ q: [Double]) -> String { "position [\(Int(q[0])), \(Int(q[1]))]" }
            return [(name(p), fields), (name(mirrored), fields.merging(["position": .array(mirrored.map { .number($0) })]) { $1 })]
        }
        guard let own = fields["band"]?.stringValue ?? spec.band else { return [] }
        return ([own] + SafeZones.bandNames.filter { $0 != own }).map { ("band \($0)", fields.merging(["band": .string($0)]) { $1 }) }
    }

    /// The box the template draws in over its time (output pixels): the union of its ink at three moments, from the
    /// compositor; an estimate from its band or point on a host without one.
    static func box(_ clip: Clip, in project: Project, job: RenderJob, renderer: VideoRenderer?) -> [Double] {
        let times = [0.35, 0.6, 0.85].map { (clip.start + MediaTime(seconds: clip.duration.seconds * $0)).snapped(to: project.settings.frameRate) }
        if let renderer, let boxes = try? times.compactMap({ try renderer.layerBox(job, clipID: clip.id, at: $0) }) {
            return FaceFraming.union(boxes) ?? [0, 0, 0, 0]
        }
        return estimatedBox(clip.motion?.fields ?? [:], width: job.width, height: job.height)
    }

    /// A template's box from its fields alone: a 480×320 card around its point, else the whole width of its band.
    static func estimatedBox(_ fields: [String: JSONValue], width: Int, height: Int) -> [Double] {
        let kx = Double(width) / SafeZones.referenceWidth, ky = Double(height) / SafeZones.referenceHeight
        if let p = fields["position"]?.arrayValue?.compactMap(\.doubleValue), p.count == 2 {
            return [(p[0] - 240) * kx, (p[1] - 160) * ky, 480 * kx, 320 * ky]
        }
        let (top, bottom): (Double, Double) = switch fields["band"]?.stringValue ?? "top" {
        case "middle": (695, 1225)
        case "lower": SafeZones.lower
        default: SafeZones.top
        }
        return [0, top * ky, Double(width), (bottom - top) * ky]
    }

    /// The fields of `clip` (on track `t`, not yet in the project) with the first free place, or as given when the
    /// place was given (`explicit`), plus the warnings about the face.
    static func choose(_ spec: MotionSpec, clip: Clip, track t: Int, in project: Project, explicit: Bool,
                       renderer: VideoRenderer?) -> Choice {
        let fields = clip.motion?.fields ?? [:]
        let options = candidates(spec, fields: fields)
        guard !options.isEmpty else { return Choice(fields: fields) }
        let what = "motion template \"\(spec.id)\""
        guard let under = FaceClear.untracked(project, from: clip.start, to: clip.end) else { return Choice(fields: fields) }
        guard under.tracked else { return Choice(fields: fields, faceCheck: FaceClear.notChecked(asset: under.asset)) }
        /// When the face first meets the template drawn with `f`, nil when never.
        func overlap(_ f: [String: JSONValue]) -> MediaTime? {
            var probe = clip
            probe.motion?.fields = f
            var p = project
            p.tracks[t].clips.append(probe)
            p.tracks[t].sortClips()
            let job = RenderJob(project: p, preset: ExportPreset.named(nil, project: p))
            var faces = OutputFaces(job: job)
            return faces.firstOverlap(box(probe, in: p, job: job, renderer: renderer), from: clip.start, to: clip.end)
        }
        if explicit {
            let at = overlap(fields)
            let place = fields["position"]?.arrayValue.map { "position \(JSONValue.array($0).text())" } ?? "band \(fields["band"]?.stringValue ?? "")"
            return Choice(fields: fields, warnings: at.map { [FaceClear.placedOverFace(what, at: $0)] } ?? [], place: place,
                          faceCheck: FaceClear.checked(covers: at != nil))
        }
        var first: MediaTime?
        for (i, o) in options.enumerated() {
            guard let at = overlap(o.fields) else { return Choice(fields: o.fields, place: o.name, faceCheck: FaceClear.checked(covers: false)) }
            if i == 0 { first = at }
        }
        return Choice(fields: fields, warnings: [FaceClear.noFreePlace(what, at: first ?? clip.start, places: options.map(\.name))], place: options[0].name,
                      faceCheck: FaceClear.checked(covers: true))
    }
}
