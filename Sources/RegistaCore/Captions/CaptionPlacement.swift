import Foundation

/// Where the faces are on the output frame: the face track of the picture that fills the frame at a
/// timeline time, mapped through its crop (and scale/offset). Stray detections are dropped per clip
/// (see `FaceFraming.faces`). An insert or a picture without a face track hides the faces under it.
public struct OutputFaces {
    let job: RenderJob
    var tracks: [String: FaceTrack] = [:]
    var perClip: [String: [(t: Double, boxes: [[Double]])]] = [:]

    public init(job: RenderJob) { self.job = job }

    /// True when some clip of the job's picture has a face track.
    public var available: Bool {
        job.visualTracks.contains { $0.clips.contains { job.project.asset($0.assetID)?.analysis?.faces != nil } }
    }

    mutating func track(_ asset: MediaAsset) -> FaceTrack? {
        guard let path = asset.analysis?.faces?.path else { return nil }
        if let t = tracks[path] { return t }
        guard let data = FileManager.default.contents(atPath: path), let t = try? JSONDecoder().decode(FaceTrack.self, from: data) else { return nil }
        tracks[path] = t
        return t
    }

    /// Face boxes (landmark extent) on the output frame at timeline time `t`, output pixels.
    public mutating func boxes(at t: MediaTime) -> [[Double]] {
        let layers = job.layers(at: t)
        guard let top = layers.last(where: { $0.placement == nil || $0.placement?.fit == .fill }), case .video = top.source,
              let asset = job.project.asset(top.assetID), asset.image == nil, top.crop[0] > 0, let track = track(asset),
              let clip = job.project.tracks.first(where: { $0.id == top.trackID })?.clips.first(where: { $0.id == top.clipID }) else { return [] }
        if perClip[clip.id] == nil {
            perClip[clip.id] = FaceFraming.faces(track, from: clip.sourceIn.seconds - 1e-3, to: clip.sourceOut.seconds + 1.5 / max(track.fps, 1))
        }
        let samples = perClip[clip.id]!
        let s = top.sourceTime.seconds
        // Nearest sample (they are in time order).
        var lo = 0, hi = samples.count - 1
        guard hi >= 0 else { return [] }
        while lo < hi { let mid = (lo + hi) / 2; if samples[mid].t < s { lo = mid + 1 } else { hi = mid } }
        if lo > 0, abs(samples[lo - 1].t - s) < abs(samples[lo].t - s) { lo -= 1 }
        guard abs(samples[lo].t - s) <= 1.5 / max(track.fps, 1) else { return [] }
        return samples[lo].boxes.map { Self.toOutput($0, layer: top, width: job.width, height: job.height) }
    }

    /// A source box through a full-frame layer's crop, scale and offset.
    public static func toOutput(_ b: [Double], layer: VideoLayer, width: Int, height: Int) -> [Double] {
        let k = Double(width) / layer.crop[0] * layer.scale
        let (cx, cy) = layer.centre(width: width, height: height)
        let sx = layer.crop[2] + layer.crop[0] / 2, sy = layer.crop[3] + layer.crop[1] / 2
        return [cx + (b[0] - sx) * k, cy + (b[1] - sy) * k, b[2] * k, b[3] * k]
    }
}

/// Moves caption chunks off faces: each chunk's line (its ink box) is checked against the caption zone of
/// every face on every frame it shows; when it touches one, the chunk goes to the nearest clear band
/// inside the Instagram safe zones (lower first, then higher), shifted left or right if that is what it
/// takes; when nothing is clear the chunk is split in two (fewer words, shorter time) and each half is
/// placed again. What still overlaps is reported (captions.checkFaces fails on it).
public enum CaptionPlacement {
    /// Band tops tried after the style's own (reference pixels, 1080×1920; band 200 px, ink in its middle ~120 px).
    public static let bands: [Double] = [1290, 1340, 1380, 1180, 1110, 1040, 970, 900, 830, 760, 690, 620, 550, 480, 410, 340, 270, 200]

    public struct Report: Sendable {
        public var moved = 0
        public var shifted = 0
        public var split = 0
        /// Chunks (after splits) still touching a face.
        public var overlapping: [Int] = []
    }

    /// - ink: per chunk, the box of each of its words relative to an unshifted band [x, y, w, h], reference pixels.
    /// - isStop: a word a chunk must not end on (a split never leaves one at the end of the first half).
    /// - zones: the face zones (reference pixels) on the frame at a timeline time.
    /// A word only counts from the frame it appears on (word-by-word reveal) to the end of its chunk; every word of a
    /// whole-chunk or ghost-karaoke style counts from the chunk's start.
    public static func place(_ captions: inout Captions, ink: ([CaptionChunk]) -> [[[Double]]], frame: MediaTime,
                             isStop: (String) -> Bool = { _ in false }, zones: (MediaTime) -> [[Double]]) -> Report {
        let style = captions.style
        let scaleY = style.referenceHeight / SafeZones.referenceHeight, scaleX = style.referenceWidth / SafeZones.referenceWidth
        let left = 24 * scaleX, right = style.referenceWidth - SafeZones.rightMargin * scaleX
        let candidates = [style.bandY] + bands.map { $0 * scaleY }.filter { abs($0 - style.bandY) > 1 }
        // Near the usual band first (centred, then beside the face), then farther bands (centred, then beside).
        let near = candidates.filter { abs($0 - style.bandY) <= 150 * scaleY }, far = candidates.filter { abs($0 - style.bandY) > 150 * scaleY }
        var report = Report()
        var out: [CaptionChunk] = []
        var queue = captions.chunks
        var inks = ink(queue)
        var depth = [Int](repeating: 0, count: queue.count)
        var i = 0
        let trackPinned = captions.place?.x != nil || captions.place?.y != nil
        while i < queue.count {
            var chunk = queue[i]
            let boxes = inks[i]
            chunk.bandY = nil
            chunk.offsetX = nil
            // Put somewhere by hand (captions.place): stays there; captions.checkFaces reports a face under it as a warning.
            if trackPinned || chunk.place?.x != nil || chunk.place?.y != nil {
                out.append(chunk)
                i += 1
                continue
            }
            // Face zones per frame of the chunk, and from which frame each word is drawn.
            var times: [MediaTime] = []
            var at = chunk.words.first?.start ?? chunk.end
            while at < chunk.end { times.append(at); at = at + frame }
            let z = times.map(zones)
            let whole = style.showsWholeChunk
            let from = chunk.words.map { w in whole ? 0 : times.firstIndex { $0 + frame > w.start } ?? times.count }
            let line = FaceFraming.union(boxes) ?? [0, 0, 0, 0]
            func hits(_ y: Double, _ dx: Double, stopAtFirst: Bool) -> Int {
                var n = 0
                for (j, b) in boxes.enumerated() where j < from.count {
                    let r = [b[0] + dx, y + b[1], b[2], b[3]]
                    for f in from[j]..<times.count where z[f].contains(where: { FaceFraming.intersects($0, r) }) {
                        n += 1
                        if stopAtFirst { return n }
                    }
                }
                return n
            }
            var chosen: (y: Double, dx: Double)?
            if z.allSatisfy(\.isEmpty) || hits(style.bandY, 0, stopAtFirst: true) == 0 {
                chosen = (style.bandY, 0)
            } else {
                let shifts = [left - line[0], right - (line[0] + line[2])].filter { line[0] + $0 >= left - 0.5 && line[0] + line[2] + $0 <= right + 0.5 }
                let order = near.map { ($0, 0.0) } + near.flatMap { y in shifts.map { (y, $0) } }
                    + far.map { ($0, 0.0) } + far.flatMap { y in shifts.map { (y, $0) } }
                chosen = order.first { hits($0.0, $0.1, stopAtFirst: true) == 0 }.map { (y: $0.0, dx: $0.1) }
                if chosen == nil {
                    // Shorten: two chunks, each placed on its own; the first half never ends on a stop word.
                    let cuts = chunk.words.indices.dropFirst().filter { !isStop(chunk.words[$0 - 1].text) }
                    if depth[i] < 3, let cut = cuts.min(by: { abs($0 * 2 - chunk.words.count) < abs($1 * 2 - chunk.words.count) }) {
                        var a = chunk, b = chunk
                        a.words = Array(chunk.words[..<cut]); a.end = chunk.words[cut].start; a.closed = nil
                        b.words = Array(chunk.words[cut...])
                        queue.replaceSubrange(i...i, with: [a, b])
                        let d = depth[i] + 1
                        depth.replaceSubrange(i...i, with: [d, d])
                        inks.replaceSubrange(i...i, with: ink([a, b]))
                        report.split += 1
                        continue
                    }
                    // Least overlap (word-frames touching a face) over every band and shift.
                    let best = order.min { hits($0.0, $0.1, stopAtFirst: false) < hits($1.0, $1.1, stopAtFirst: false) } ?? (style.bandY, 0)
                    chosen = (best.0, best.1)
                    report.overlapping.append(out.count)
                }
            }
            if let c = chosen {
                if abs(c.y - style.bandY) > 0.5 { chunk.bandY = c.y; report.moved += 1 }
                if abs(c.dx) > 0.5 { chunk.offsetX = (c.dx * 10).rounded() / 10; report.shifted += 1 }
            }
            out.append(chunk)
            i += 1
        }
        captions.chunks = out
        return report
    }

    /// Word boxes of every chunk on the output frame [x, y, w, h], output pixels: the compositor's layout when there is a
    /// renderer, else the style estimate placed the same way (band origin, scale, manual placement).
    public static func wordBoxes(_ job: RenderJob, renderer: VideoRenderer?) -> [[[Double]]] {
        guard let c = job.captions else { return [] }
        if let renderer, let layout = try? renderer.captionLayout(job), layout.count == c.chunks.count { return layout }
        let k = job.captionScale
        return estimatedInk(c.chunks, style: c.style).enumerated().map { i, boxes in
            let s = c.scale(chunk: i) * k
            let scaled = boxes.map { $0.map { $0 * s } }
            let line = FaceFraming.union(scaled) ?? [0, 0, 0, 0]
            let o = job.captionBandOrigin(chunk: i, line: line)
            return scaled.map { [$0[0] + o.x, $0[1] + o.y, $0[2], $0[3]] }
        }
    }

    /// Word boxes of each chunk relative to its band, estimated from the style (hosts without Core Text):
    /// 0.52 em per character, keyword boxes padded, the line centred.
    public static func estimatedInk(_ chunks: [CaptionChunk], style: CaptionStyle) -> [[[Double]]] {
        chunks.map { ch in
            let em = style.fontSize
            let widths = ch.words.map { Double($0.text.count) * 0.52 * em + ($0.keyword ? 2 * style.boxPadX : style.strokeWidth) }
            let total = widths.reduce(0, +) + style.gap * Double(max(ch.words.count - 1, 0))
            var x = (style.referenceWidth - total) / 2
            return zip(ch.words, widths).map { word, w in
                defer { x += w + style.gap }
                let h = 0.8 * em + (word.keyword ? 2 * style.boxPadY : style.strokeWidth)
                return [x, (style.bandHeight - h) / 2, w, h]
            }
        }
    }
}
