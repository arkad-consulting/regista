import Foundation

/// Minimal RIFF/WAVE reader: PCM 16/24/32-bit and float 32, any channel count. Enough for the
/// wavs Regista writes with ffmpeg; nothing else is expected here.
public struct WAVAudio: Sendable {
    public var sampleRate: Int
    public var channels: Int
    /// Interleaved samples in -1…1.
    public var samples: [Float]

    public var frameCount: Int { samples.count / max(channels, 1) }
    public var duration: Double { Double(frameCount) / Double(sampleRate) }

    public init(sampleRate: Int, channels: Int, samples: [Float]) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.samples = samples
    }

    public static func read(_ url: URL) throws -> WAVAudio {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw CommandError(.io, "Cannot read \(url.path)")
        }
        return try parse(data, name: url.lastPathComponent)
    }

    public static func parse(_ data: Data, name: String = "wav") throws -> WAVAudio {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard bytes.count >= 12, String(decoding: bytes[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: bytes[8..<12], as: UTF8.self) == "WAVE" else {
            throw CommandError(.io, "\(name) is not a WAVE file")
        }
        var format = 0, channels = 0, rate = 0, bits = 0
        var offset = 12
        while offset + 8 <= bytes.count {
            let id = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            var size = u32(offset + 4)
            let body = offset + 8
            if id == "fmt " {
                format = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE, size >= 26 { format = u16(body + 24) }   // WAVE_FORMAT_EXTENSIBLE subformat
            } else if id == "data" {
                if size == 0xFFFF_FFFF || body + size > bytes.count { size = bytes.count - body }   // streamed wavs
                guard channels > 0, rate > 0 else { throw CommandError(.io, "\(name): data before fmt") }
                let width = bits / 8
                let n = size / width
                var samples = [Float](repeating: 0, count: n)
                switch (format, bits) {
                case (1, 16):
                    for i in 0..<n { samples[i] = Float(Int16(bitPattern: UInt16(u16(body + 2 * i)))) / 32768 }
                case (1, 24):
                    for i in 0..<n {
                        let o = body + 3 * i
                        let v = Int32(bitPattern: UInt32(bytes[o]) << 8 | UInt32(bytes[o + 1]) << 16 | UInt32(bytes[o + 2]) << 24) >> 8
                        samples[i] = Float(v) / 8_388_608
                    }
                case (1, 32):
                    for i in 0..<n { samples[i] = Float(Int32(bitPattern: UInt32(u32(body + 4 * i)))) / 2_147_483_648 }
                case (3, 32):
                    for i in 0..<n { samples[i] = Float(bitPattern: UInt32(u32(body + 4 * i))) }
                default:
                    throw CommandError(.io, "\(name): unsupported WAVE format \(format) / \(bits) bits")
                }
                return WAVAudio(sampleRate: rate, channels: channels, samples: samples)
            }
            offset = body + size + (size & 1)
        }
        throw CommandError(.io, "\(name): no data chunk")
    }

    /// One channel (or the average of all).
    public func mono(channel: Int? = nil) -> [Float] {
        guard channels > 1 else { return samples }
        var out = [Float](repeating: 0, count: frameCount)
        for f in 0..<frameCount {
            if let channel { out[f] = samples[f * channels + channel] }
            else {
                var s: Float = 0
                for c in 0..<channels { s += samples[f * channels + c] }
                out[f] = s / Float(channels)
            }
        }
        return out
    }

    /// Writes 16-bit PCM (tests and fixtures).
    public func write16(to url: URL) throws {
        var d = Data()
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put32(36 + samples.count * 2)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put32(16); put16(1); put16(channels); put32(sampleRate)
        put32(sampleRate * channels * 2); put16(channels * 2); put16(16)
        d.append(contentsOf: Array("data".utf8)); put32(samples.count * 2)
        for s in samples {
            let v = Int16(max(-32768, min(32767, (s * 32767).rounded())))
            withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
        }
        try d.write(to: url)
    }
}

/// 10 ms RMS energy envelope in dBFS (port of the Python prototype's `envelope.py`), used to put cut points
/// on real speech onsets/offsets and to measure word-timing accuracy at pauses.
public struct Envelope: Sendable {
    public static let hop = 0.01
    public var db: [Double]

    public init(db: [Double]) { self.db = db }

    public init(samples: [Float], sampleRate: Int) {
        let n = Int(Double(sampleRate) * Self.hop)
        let m = samples.count / n
        db = (0..<m).map { f in
            var acc = 0.0
            for i in f * n..<(f + 1) * n { let v = Double(samples[i]); acc += v * v }
            return 10 * log10(acc / Double(n) + 1e-12)
        }
    }

    public static func read(_ url: URL) throws -> Envelope {
        let wav = try WAVAudio.read(url)
        return Envelope(samples: wav.mono(), sampleRate: wav.sampleRate)
    }

    public var duration: Double { Double(db.count) * Self.hop }

    /// numpy.percentile with linear interpolation.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return -120 }
        let pos = p / 100 * Double(s.count - 1)
        let lo = Int(pos.rounded(.down)), hi = min(lo + 1, s.count - 1)
        return s[lo] + (s[hi] - s[lo]) * (pos - Double(lo))
    }

    /// Speech threshold: 12 dB above the 10th-percentile floor.
    public func speechThreshold(aboveFloor: Double = 12) -> (threshold: Double, floor: Double) {
        let floor = Self.percentile(db, 10)
        return (floor + aboveFloor, floor)
    }

    /// Runs below `threshold` lasting at least `minLength` seconds, as (start, end) seconds.
    public func silences(below threshold: Double, minLength: Double = 0.2) -> [(start: Double, end: Double)] {
        var out: [(Double, Double)] = []
        var i = 0
        while i < db.count {
            guard db[i] < threshold else { i += 1; continue }
            var j = i
            while j < db.count, db[j] < threshold { j += 1 }
            if Double(j - i) * Self.hop >= minLength { out.append((Double(i) * Self.hop, Double(j) * Self.hop)) }
            i = j
        }
        return out
    }

    func frame(_ t: Double) -> Int { Int((t / Self.hop).rounded()) }

    /// First loud frame (3 loud frames in a row) within [t − 0.25, t + 0.10], else t.
    public func onset(near t: Double, threshold: Double) -> Double {
        var f = max(frame(t - 0.25), 0)
        while f < min(frame(t + 0.10), db.count) {
            if (f..<min(f + 3, db.count)).allSatisfy({ db[$0] >= threshold }) { return Double(f) * Self.hop }
            f += 1
        }
        return t
    }

    /// Start of the first 60 ms quiet run after t − 0.10 (within t + 0.35), else t.
    public func offset(near t: Double, threshold: Double) -> Double {
        var f = max(frame(t - 0.10), 0)
        while f < min(frame(t + 0.35), db.count - 6) {
            if !(f..<f + 6).contains(where: { db[$0] >= threshold }) { return Double(f) * Self.hop }
            f += 1
        }
        return t
    }
}

/// Word-timing accuracy against the energy envelope at every interior pause (port of
/// the Python prototype's `timing_eval.py`): for each silence ≥ minGap, the word boundary closest to it,
/// word end − speech offset and next word start − speech onset.
public enum TimingEvaluation {
    public struct Stats: Sendable {
        public var count: Int
        public var medianMs: Double
        public var p90Ms: Double
        public var maxMs: Double
        public var within100: Double
        public var within200: Double

        init(_ errors: [Double]) {
            let ms = errors.map { abs($0) * 1000 }
            count = ms.count
            medianMs = Envelope.percentile(ms, 50).rounded()
            p90Ms = Envelope.percentile(ms, 90).rounded()
            maxMs = (ms.max() ?? 0).rounded()
            within100 = ms.isEmpty ? 0 : Double(ms.filter { $0 <= 100 }.count) / Double(ms.count)
            within200 = ms.isEmpty ? 0 : Double(ms.filter { $0 <= 200 }.count) / Double(ms.count)
        }

        public var json: JSONValue {
            ["n": .number(Double(count)), "medianMs": .number(medianMs), "p90Ms": .number(p90Ms), "maxMs": .number(maxMs),
             "within100ms": .number((within100 * 1000).rounded() / 1000), "within200ms": .number((within200 * 1000).rounded() / 1000)]
        }
    }

    public static func evaluate(words: [Word], envelope: Envelope, minGap: Double = 0.25) -> (starts: Stats, ends: Stats, pauses: Int) {
        let (thr, _) = envelope.speechThreshold()
        let dur = envelope.duration
        let gaps = envelope.silences(below: thr, minLength: minGap).filter { $0.start > 0.05 && $0.end < dur - 0.05 }
        let ws = words.map { (s: $0.start.seconds, e: $0.end.seconds) }
        guard ws.count > 1 else { return (Stats([]), Stats([]), gaps.count) }
        var starts: [Double] = [], ends: [Double] = []
        for g in gaps {
            let k = (0..<ws.count - 1).min { abs(ws[$0].e - g.start) + abs(ws[$0 + 1].s - g.end) < abs(ws[$1].e - g.start) + abs(ws[$1 + 1].s - g.end) }!
            ends.append(ws[k].e - g.start)
            starts.append(ws[k + 1].s - g.end)
        }
        return (Stats(starts), Stats(ends), gaps.count)
    }
}
