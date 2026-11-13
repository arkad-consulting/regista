import Foundation

/// Lowers an audio track (the music bed) while another track speaks: the speech regions of `sourceTrack`
/// (its words on the timeline, or its clips when there is no transcript) become a gain envelope with smooth
/// raised-cosine ramps — fully down `attack` seconds before a word starts, back up over `release` after it ends.
/// Pauses shorter than `mergeGap` stay down, so the music never pumps between words.
public struct Ducking: Codable, Hashable, Sendable {
    public var sourceTrack: String
    /// Gain under speech, dB (negative).
    public var depth: Double
    public var attack: Double
    public var release: Double
    public var mergeGap: Double

    public init(sourceTrack: String, depth: Double = -12, attack: Double = 0.15, release: Double = 0.45, mergeGap: Double = 0.7) {
        self.sourceTrack = sourceTrack
        self.depth = depth
        self.attack = attack
        self.release = release
        self.mergeGap = mergeGap
    }
}

public enum DuckingEnvelope {
    /// Speech regions (seconds) of a track: its words on the timeline merged across short gaps, else its clips.
    public static func regions(of track: Track, in project: Project, mergeGap: Double) -> [(Double, Double)] {
        let words = TimelineTranscript.words(of: track, in: project)
        let raw: [(Double, Double)] = words.isEmpty
            ? track.clips.map { ($0.start.seconds, $0.end.seconds) }
            : words.map { ($0.start.seconds, $0.end.seconds) }
        return merge(raw, gap: mergeGap)
    }

    public static func merge(_ ranges: [(Double, Double)], gap: Double) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for r in ranges.sorted(by: { $0.0 < $1.0 }) where r.1 > r.0 {
            if let last = out.last, r.0 - last.1 <= gap { out[out.count - 1].1 = max(last.1, r.1) } else { out.append(r) }
        }
        return out
    }

    /// Gain in dB at `t` for regions (already merged).
    public static func gain(at t: Double, regions: [(Double, Double)], ducking d: Ducking) -> Double {
        var g = 0.0
        for (a, b) in regions {
            let down: Double
            if t >= a && t <= b { down = 1 }
            else if t < a && t > a - d.attack { down = ramp((t - (a - d.attack)) / d.attack) }
            else if t > b && t < b + d.release { down = ramp(1 - (t - b) / d.release) }
            else { continue }
            g = min(g, d.depth * down)
            if g <= d.depth { break }
        }
        return g
    }

    /// 0 → 1 raised cosine.
    static func ramp(_ x: Double) -> Double { 0.5 - 0.5 * cos(Double.pi * min(max(x, 0), 1)) }

    /// Linear gain per sample over `length` samples at `rate` (the file the mixer multiplies the track with).
    public static func samples(regions: [(Double, Double)], ducking d: Ducking, rate: Int, length: Int) -> [Float] {
        var out = [Float](repeating: 1, count: length)
        let r = Double(rate)
        for (a, b) in regions {
            let lo = max(Int(((a - d.attack) * r).rounded(.down)), 0), hi = min(Int(((b + d.release) * r).rounded(.up)), length)
            guard lo < hi else { continue }
            for i in lo..<hi {
                let t = Double(i) / r
                let down: Double = t < a ? ramp((t - (a - d.attack)) / d.attack) : t <= b ? 1 : ramp(1 - (t - b) / d.release)
                out[i] = min(out[i], Float(pow(10, d.depth * down / 20)))
            }
        }
        return out
    }
}

extension WAVAudio {
    /// Writes 32-bit float PCM (gain envelopes: values above 1 are kept).
    public func writeFloat(to url: URL) throws {
        var d = Data(capacity: 44 + samples.count * 4)
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + samples.count * 4)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(3); put16(channels); put32(sampleRate)
        put32(sampleRate * channels * 4); put16(channels * 4); put16(32)
        d.append(contentsOf: Array("data".utf8)); put32(samples.count * 4)
        samples.withUnsafeBufferPointer { p in
            for s in p { withUnsafeBytes(of: s.bitPattern.littleEndian) { d.append(contentsOf: $0) } }
        }
        try d.write(to: url)
    }
}

/// A 3D LUT from an Adobe/Resolve `.cube` file: `size`³ RGB triples, red fastest.
public struct CubeLUT: Sendable {
    public var size: Int
    public var values: [Float]

    public static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("LUT_3D_SIZE") { size = Int(line.split(separator: " ").last ?? "") ?? 0; continue }
            if line.first?.isLetter == true { continue }   // TITLE, DOMAIN_MIN/MAX, LUT_1D_SIZE
            let v = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
            if v.count == 3 { values += v }
        }
        guard size >= 2, values.count == size * size * size * 3 else {
            throw CommandError.invalid("LUT: expected LUT_3D_SIZE n and n³ RGB rows (got size \(size), \(values.count / 3) rows)")
        }
        return CubeLUT(size: size, values: values)
    }

    public static func load(_ path: String) throws -> CubeLUT {
        guard let data = FileManager.default.contents(atPath: EngineConfig.expand(path)) else {
            throw CommandError.notFound("LUT: no file at \(path)")
        }
        return try parse(String(decoding: data, as: UTF8.self))
    }
}
