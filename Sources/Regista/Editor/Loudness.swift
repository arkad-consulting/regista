import Foundation
import RegistaCore

/// EBU R128 / ITU-R BS.1770-4 loudness of the timeline mix (the unmuted audio tracks, clip gains, fades and the music's
/// ducking under the voice applied, as in the export),
/// computed in the background after every edit: momentary (400 ms) and short-term (3 s) curves every
/// 100 ms, gated integrated loudness and an oversampled true peak. The meter reads the curves at the
/// playhead. Mono sources play as dual mono in the export, so they are measured as two identical channels.
struct LoudnessCurve: Sendable {
    static let hop = 0.1
    var momentary: [Double] = []
    var shortTerm: [Double] = []
    var integrated: Double = -.infinity
    var truePeak: Double = -.infinity

    func at(_ t: Double) -> (m: Double, s: Double) {
        guard !momentary.isEmpty else { return (-.infinity, -.infinity) }
        let i = min(max(Int(t / Self.hop), 0), momentary.count - 1)
        return (momentary[i], shortTerm[i])
    }

    /// The mix of the project's unmuted audio clips at 48 kHz (nil while a source is still decoding).
    @MainActor
    static func mix(_ project: Project, cache: MediaCache) -> [Float]? {
        let rate = 48_000.0
        let length = Int(project.duration.seconds * rate)
        guard length > 0 else { return [] }
        var out = [Float](repeating: 0, count: length)
        for track in project.tracks where track.kind == .audio && !track.muted {
            // The ducking envelope of a music bed, sample by sample (the same curve the export multiplies it with).
            var duck: [Float]?
            if let d = track.ducking, let source = project.tracks.first(where: { $0.id == d.sourceTrack }) {
                duck = DuckingEnvelope.samples(regions: DuckingEnvelope.regions(of: source, in: project, mergeGap: d.mergeGap),
                                               ducking: d, rate: Int(rate), length: length)
            }
            for clip in track.clips {
                let level = Float(pow(10, (clip.gain ?? 0) / 20))
                guard let asset = project.asset(clip.assetID), asset.audio != nil else { continue }
                guard let src = cache.samples(asset.path) else { return nil }
                let a = Int(clip.sourceIn.seconds * rate), b = min(Int(clip.sourceOut.seconds * rate), src.count)
                let at = Int(clip.start.seconds * rate)
                guard b > a else { continue }
                let n = b - a
                let fin = Int((clip.fadeIn?.seconds ?? 0) * rate), fout = Int((clip.fadeOut?.seconds ?? 0) * rate)
                for k in 0..<n where at + k < length && at + k >= 0 {
                    var g: Float = 1
                    if k < fin { g = Float(k) / Float(fin) }
                    if n - k <= fout { g = min(g, Float(n - k) / Float(fout)) }
                    out[at + k] += src[a + k] * g * level * (duck?[at + k] ?? 1)
                }
            }
        }
        return out
    }

    /// BS.1770 on a mono signal measured as dual mono, 48 kHz.
    static func measure(_ x: [Float]) -> LoudnessCurve {
        var c = LoudnessCurve()
        guard x.count > 4800 else { return c }
        // K-weighting at 48 kHz: high shelf, then the RLB high-pass.
        let y = biquad(biquad(x, b: [1.53512485958697, -2.69169618940638, 1.19839281085285], a: [-1.69065929318241, 0.73248077421585]),
                       b: [1, -2, 1], a: [-1.99004745483398, 0.99007225036621])
        // Mean square per 100 ms hop.
        let hopN = 4800
        let hops = y.count / hopN
        var ms = [Double](repeating: 0, count: hops)
        for h in 0..<hops {
            var s = 0.0
            for i in h * hopN..<(h + 1) * hopN { s += Double(y[i]) * Double(y[i]) }
            ms[h] = s / Double(hopN)
        }
        func lufs(_ z: Double) -> Double { z > 0 ? -0.691 + 10 * log10(2 * z) : -.infinity }   // 2 channels
        func window(_ end: Int, _ n: Int) -> Double {
            let a = max(0, end - n + 1)
            return ms[a...end].reduce(0, +) / Double(n)
        }
        c.momentary = (0..<hops).map { lufs(window($0, 4)) }
        c.shortTerm = (0..<hops).map { lufs(window($0, 30)) }
        // Integrated: 400 ms blocks every 100 ms, absolute gate −70 LUFS, relative gate −10 LU.
        let blocks = (3..<max(hops, 3)).map { window($0, 4) }
        let audible = blocks.filter { lufs($0) > -70 }
        if !audible.isEmpty {
            let rel = lufs(audible.reduce(0, +) / Double(audible.count)) - 10
            let gated = audible.filter { lufs($0) > rel }
            if !gated.isEmpty { c.integrated = lufs(gated.reduce(0, +) / Double(gated.count)) }
        }
        // True peak: 4× oversampling with a Catmull-Rom interpolator (close to the BS.1770 FIR for speech).
        var peak: Float = 0
        for i in 1..<(x.count - 2) {
            let p0 = x[i - 1], p1 = x[i], p2 = x[i + 1], p3 = x[i + 2]
            peak = max(peak, abs(p1))
            for f in [Float(0.25), 0.5, 0.75] {
                let v = 0.5 * ((2 * p1) + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f * f + (-p0 + 3 * p1 - 3 * p2 + p3) * f * f * f)
                peak = max(peak, abs(v))
            }
        }
        c.truePeak = peak > 0 ? 20 * log10(Double(peak)) : -.infinity
        return c
    }

    static func biquad(_ x: [Float], b: [Double], a: [Double]) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let x0 = Double(x[i])
            let y0 = b[0] * x0 + b[1] * x1 + b[2] * x2 - a[0] * y1 - a[1] * y2
            y[i] = Float(y0)
            x2 = x1; x1 = x0; y2 = y1; y1 = y0
        }
        return y
    }
}

/// Recomputes the curve after edits; publishes it for the meter.
@MainActor
final class LoudnessMeter: ObservableObject {
    @Published private(set) var curve = LoudnessCurve()
    @Published private(set) var measuring = false
    private var measuredFrom: Project?
    private var generation = 0

    func update(_ project: Project?, cache: MediaCache) {
        guard let project else { curve = LoudnessCurve(); measuredFrom = nil; return }
        // Only the audio side matters.
        var audioOnly = project
        audioOnly.tracks = project.tracks.filter { $0.kind == .audio }
        guard audioOnly != measuredFrom else { return }
        guard let mix = LoudnessCurve.mix(project, cache: cache) else { return }   // retried when the cache bumps
        measuredFrom = audioOnly
        generation += 1
        let gen = generation
        measuring = true
        DispatchQueue.global(qos: .utility).async {
            let c = LoudnessCurve.measure(mix)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.curve = c
                self.measuring = false
            }
        }
    }
}
