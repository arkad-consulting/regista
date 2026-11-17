import Foundation

// Face checks on the edit (issue #13): captions never on a face, crops never cutting a head. Geometry
// from the face track (faces.track) through each clip's crop, frame by frame: no render needed.

enum CaptionsCheckFaces: Command {
    static let id = "captions.checkFaces"
    static let summary = "Verify that no caption covers a face: on every frame a chunk shows, each word drawn (ink box, at its band and shift) against the caption zone of every face on the picture (head + some neck; a child in the arms too), from the face track through the clip crops. Run it after captions.generate (and after any crop change). Fails on any overlap. Returns pass, frames and chunks checked, and each overlap (chunk, time, boxes)."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Caption track (default: the first one with captions)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let t = try CaptionsCommon.trackIndex(p, project, command: id)
        let captions = try CaptionsCommon.require(project.tracks[t], command: id)
        var job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project))
        job.captions = captions
        var faces = OutputFaces(job: job)
        guard faces.available else { throw CommandError.conflict("\(id): no face track on the picture — run faces.track") }
        // Word boxes per chunk (output pixels) from the compositor when there is one, else the style estimate.
        let words = CaptionPlacement.wordBoxes(job, renderer: ctx.services.renderer)
        let frame = MediaTime.frameDuration(at: job.frameRate)
        var overlaps: [JSONValue] = [], warnings: [JSONValue] = []
        var frames = 0, faceFrames = 0, bad = Set<Int>(), placed = Set<Int>()
        func r1(_ b: [Double]) -> JSONValue { .array(b.map { .number(($0 * 10).rounded() / 10) }) }
        for (ci, ch) in captions.chunks.enumerated() {
            guard var at = ch.words.first?.start else { continue }
            while at < ch.end {
                frames += 1
                let zones = faces.zones(at: at)
                if !zones.isEmpty { faceFrames += 1 }
                // The words drawn on this frame (word-by-word reveal).
                let shown = captions.style.showsWholeChunk ? ch.words.indices.map { $0 } : ch.words.indices.filter { ch.words[$0].start < at + frame }
                for wi in shown where wi < words[ci].count {
                    guard let z = zones.first(where: { FaceFraming.intersects($0, words[ci][wi]) }) else { continue }
                    // Put there by hand (captions.place): the person's choice wins, reported as a warning.
                    if captions.isPinned(chunk: ci) {
                        if !placed.contains(ci) {
                            warnings.append(.string("chunk \(ci) \"\(ch.text)\" was placed by hand over a face at \(String(format: "%.2f", at.seconds)) s"))
                        }
                        placed.insert(ci)
                        break
                    }
                    if !bad.contains(ci), overlaps.count < 50 {
                        overlaps.append(["chunk": .number(Double(ci)), "text": .string(ch.text), "word": .string(ch.words[wi].text),
                                         "time": ProjectState.seconds(at), "caption": r1(words[ci][wi]), "face": r1(z)])
                    }
                    bad.insert(ci)
                    break
                }
                at = at + frame
            }
        }
        return ["pass": .bool(bad.isEmpty), "chunks": .number(Double(captions.chunks.count)), "framesChecked": .number(Double(frames)),
                "framesWithFaces": .number(Double(faceFrames)), "overlappingChunks": .number(Double(bad.count)),
                "moved": .number(Double(captions.chunks.filter { $0.bandY != nil || $0.offsetX != nil }.count)),
                "placedOverFaces": .number(Double(placed.count)), "warnings": .array(warnings),
                "overlaps": .array(overlaps)]
    }
}

enum FacesCheckFraming: Command {
    static let id = "faces.checkFraming"
    static let summary = "Verify that no crop cuts a head: on sampled frames of a video track, every face of the face track (hair to chin, a child's too; as far as the source frame shows it) must lie inside the clip's crop, with headroom above the hair. Run it after edit.punchIns. Returns pass, frames checked and the cut heads (time, clip, head and crop boxes)."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("trackId", .string, "Video track (default: the first one)."),
        .optional("every", .integer, "Check every Nth frame (default 3)."),
        .optional("headroom", .number, "Room required above the hair, fraction of the crop height (default 0.02)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let track: Track
        if let tid = p.string("trackId") { track = project.tracks[try Timeline.trackIndex(tid, in: project, editable: false)] }
        else {
            guard let v = project.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }) else { throw CommandError.conflict("\(id): no video track with clips") }
            track = v
        }
        let job = RenderJob(project: project, preset: ExportPreset.named(nil, project: project))
        let every = max(p.int("every") ?? 3, 1), headroom = p.number("headroom") ?? 0.02
        let frame = MediaTime.frameDuration(at: job.frameRate)
        var sidecars: [String: FaceTrack] = [:]
        var cut: [JSONValue] = []
        var checked = 0, withFaces = 0, badFrames = 0
        func r1(_ b: [Double]) -> JSONValue { .array(b.map { .number(($0 * 10).rounded() / 10) }) }
        for clip in track.clips {
            guard let asset = project.asset(clip.assetID), let video = asset.video, let path = asset.analysis?.faces?.path else { continue }
            if sidecars[path] == nil {
                guard let data = FileManager.default.contents(atPath: path) else { throw CommandError.notFound("\(id): face sidecar missing: \(path)") }
                sidecars[path] = try JSONDecoder().decode(FaceTrack.self, from: data)
            }
            let samples = FaceFraming.faces(sidecars[path]!, from: clip.sourceIn.seconds, to: clip.sourceOut.seconds)
            var k = 0
            var at = clip.start
            while at < clip.end {
                defer { k += 1; at = at + frame }
                guard k % every == 0 else { continue }
                guard let layer = job.layers(at: at).first(where: { $0.clipID == clip.id }) else { continue }
                let s = layer.sourceTime.seconds
                guard let sample = samples.min(by: { abs($0.t - s) < abs($1.t - s) }), abs(sample.t - s) <= 1.5 / 30 else { continue }
                checked += 1
                if !sample.boxes.isEmpty { withFaces += 1 }
                let heads = FaceFraming.cutHeads(sample.boxes, crop: layer.crop, frame: (video.width, video.height), headroom: headroom)
                if !heads.isEmpty {
                    badFrames += 1
                    if cut.count < 50 {
                        cut.append(["time": ProjectState.seconds(at), "clip": .string(clip.id), "head": r1(heads[0]), "crop": r1(layer.crop)])
                    }
                }
            }
        }
        guard checked > 0 else { throw CommandError.conflict("\(id): no frame with a face track on \(track.name) — run faces.track") }
        return ["pass": .bool(badFrames == 0), "framesChecked": .number(Double(checked)), "framesWithFaces": .number(Double(withFaces)),
                "framesCut": .number(Double(badFrames)), "cuts": .array(cut)]
    }
}
