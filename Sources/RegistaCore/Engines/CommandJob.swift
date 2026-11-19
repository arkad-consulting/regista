import Foundation

/// The job a command runs in: the app's jobs list (E2 #54) or an MCP call with a progress token (#15). A command and
/// the engines it calls report progress through it and stop when it is cancelled: `Subprocess` registers every engine
/// process here, so Cancel kills ffmpeg / whisper-cli / deep-filter / uv for real, and the command then fails with
/// "cancelled" (an edit changes nothing: the engine keeps the project it had). Bound to the thread that runs the
/// command with `CommandJob.$current.withValue(job) { … }`; code outside a job sees nil and every call here is a no-op.
public final class CommandJob: @unchecked Sendable {
    @TaskLocal public static var current: CommandJob?

    /// The processes the command waits for; `cancel` stops them and refuses new ones.
    public let cancellation = GenerationCancellation()
    private let lock = NSLock()
    /// The part of the whole job the running stage fills (stages nest: transcription inside "Fai tutto"…).
    private var lo = 0.0, hi = 1.0
    /// Seconds of media the running stage reads (ffmpeg reports its position in seconds).
    private var media: Double?
    private var last = -1.0
    /// An estimate fills the running stage (`estimating`) and the engine has printed no number of its own yet.
    private var estimating = false
    private let sink: @Sendable (_ fraction: Double?, _ detail: String?, _ estimated: Bool) -> Void

    /// `sink` receives the progress of the whole job, 0…1 (nil: unknown, or with a detail only: a line of detail, the bar
    /// unchanged), and a line of detail; any thread.
    public convenience init(_ sink: @escaping @Sendable (_ fraction: Double?, _ detail: String?) -> Void = { _, _ in }) {
        self.init(estimates: { fraction, detail, _ in sink(fraction, detail) })
    }

    /// The same, and whether the fraction is an estimate (#13: an engine that prints no progress, timed from the length
    /// of its audio and the speed it had on this Mac) rather than a number the work measured.
    public init(estimates sink: @escaping @Sendable (_ fraction: Double?, _ detail: String?, _ estimated: Bool) -> Void) {
        self.sink = sink
    }

    public var isCancelled: Bool { cancellation.isCancelled }

    /// Stops the processes running now and every later one.
    public func cancel() { cancellation.cancel() }

    /// The error a cancelled command throws.
    public static func cancelledError(_ command: String) -> CommandError { CommandError(.io, "\(command): cancelled") }

    /// Progress of the running stage, 0…1 (mapped into the stage's part of the job; never goes back); nil: an engine
    /// that says nothing until it ends is running (the job shows an indeterminate bar until the next number).
    public func report(_ fraction: Double?, detail: String? = nil) { report(fraction, detail: detail, estimated: false) }

    private func report(_ fraction: Double?, detail: String?, estimated: Bool) {
        let mapped: Double? = lock.withLock {
            guard let f = fraction else { return nil }
            if estimated && !estimating { return -1 }   // the engine's own numbers took over
            let v = lo + (hi - lo) * min(max(f, 0), 1)
            if v < last + 0.002, detail == nil { return -1 }   // unchanged (or a step back): nothing to say
            last = max(last, v)
            return last
        }
        if mapped == -1 { return }
        sink(mapped, detail, estimated)
    }

    /// A line an engine printed, read for its progress.
    func consume(_ line: String, _ kind: LineProgress) {
        switch kind {
        case .whisper:
            if let p = Self.whisperPercent(line) { report(p / 100) }
        case .whisperX:
            // Transcription is most of a WhisperX run: loading and voice detection come before it, alignment after.
            if let p = Self.whisperXPercent(line) { measured(0.1 + 0.85 * p / 100) }
        case .installer:
            consumeInstaller(line)
        case .ffmpeg:
            guard let s = Self.ffmpegSeconds(line), let total = lock.withLock({ media }), total > 0 else { return }
            report(s / total)
        }
    }

    // MARK: Stages

    /// Runs `body` as the part [lo, hi] of the current stage (fractions of it); `media`: the seconds of media it reads
    /// (ffmpeg's position becomes a fraction; nil keeps the enclosing stage's). Reports the start (with `detail`) and the end. No job: just runs.
    public static func stage<T>(_ lo: Double, _ hi: Double, media: Double? = nil, detail: String? = nil, _ body: () throws -> T) rethrows -> T {
        guard let job = current else { return try body() }
        let saved = job.enter(lo, hi, media: media)
        job.report(0, detail: detail)
        defer { job.leave(saved) }
        let r = try body()
        job.report(1)
        return r
    }

    private func enter(_ a: Double, _ b: Double, media m: Double?) -> (Double, Double, Double?) {
        lock.withLock {
            let saved = (lo, hi, media)
            let span = hi - lo
            (lo, hi, media) = (lo + span * a, lo + span * b, m ?? media)
            return saved
        }
    }

    private func leave(_ saved: (Double, Double, Double?)) {
        lock.withLock { (lo, hi, media) = saved }
    }

    // MARK: Estimates

    /// Runs `body`, an engine that prints no progress (or none yet), while an estimate fills the running stage: the
    /// seconds elapsed over the `expected` seconds, held at 95 % until `body` returns, and said to be an estimate. The
    /// first number the engine prints itself ends the estimate (the bar waits for such a number to pass it: never back).
    /// `expected` nil: an indeterminate bar, as before. No job: just runs.
    public static func estimating<T>(_ expected: Double?, _ body: () throws -> T) rethrows -> T {
        guard let job = current else { return try body() }
        guard let expected, expected > 0 else {
            job.report(nil)
            return try body()
        }
        job.lock.withLock { job.estimating = true }
        let stop = Flag()
        let started = Date()
        // A thread of its own (not a global-queue worker): the engine can run for minutes.
        Thread.detachNewThread {
            while !stop.isSet {
                job.report(min(0.95, Date().timeIntervalSince(started) / expected), detail: nil, estimated: true)
                Thread.sleep(forTimeInterval: 0.25)
            }
        }
        defer {
            stop.set()
            job.lock.withLock { job.estimating = false }
        }
        return try body()
    }

    /// A number the work measured: it ends a running estimate. Behind the estimate, the bar waits for it (still an
    /// estimate until a measured number passes it).
    private func measured(_ fraction: Double) {
        lock.withLock { estimating = false }
        report(fraction)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }

    /// Throws "cancelled" when the current job was cancelled (between the steps of a command).
    public static func checkCancelled(_ command: String) throws {
        if current?.isCancelled == true { throw cancelledError(command) }
    }

    public static func report(_ fraction: Double?, detail: String? = nil) { current?.report(fraction, detail: detail) }

    /// A line of detail for the job's line (what the work waits for), leaving its bar as it is (#6).
    public static func say(_ detail: String) { current?.sink(nil, detail, false) }

    // MARK: Engine output

    /// What an engine prints about its progress.
    public enum LineProgress: Sendable {
        /// ffmpeg with `-progress pipe:1`: `out_time_us=…` (a position in the input, seconds = µs / 1e6).
        case ffmpeg
        /// whisper-cli with `-pp`: `… progress =  45%`.
        case whisper
        /// WhisperX's own `print_progress` (wx_align.py turns it on): `Progress: 45.00%...` per batch it transcribed.
        case whisperX
        /// scripts/install.sh: `==> step` / `  ✓ done` / `  ↓ file (size)` lines and curl's `###  45.3%` bar. Each
        /// download starts the bar again (a step downloads several files), its line becomes the detail.
        case installer
    }

    private func consumeInstaller(_ line: String) {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("↓") {
            lock.withLock { last = -1 }
            report(0, detail: String(l.dropFirst()).trimmingCharacters(in: .whitespaces))
        } else if let p = Self.curlPercent(l) {
            report(p / 100)
        } else if l.hasPrefix("==>") || l.hasPrefix("✓") || l.hasPrefix("…") || l.hasPrefix("!") {
            let text = l.drop { "=>✓…! ".contains($0) }
            if !text.isEmpty { sink(nil, String(text), false) }   // a line of detail: the installer job keeps its bar
        }
    }

    /// Percent from curl's `--progress-bar` (`######   45.3%`).
    public static func curlPercent(_ line: String) -> Double? {
        let l = line.trimmingCharacters(in: .whitespaces)
        guard l.hasSuffix("%"), l.allSatisfy({ "#0123456789.% ".contains($0) }),
              let n = l.dropLast().split(separator: " ").last.flatMap({ Double($0) }), n <= 100 else { return nil }
        return n
    }

    /// Seconds from an ffmpeg `-progress` line (`out_time_us`, `out_time_ms` — also µs — or `out_time=HH:MM:SS.ff`).
    public static func ffmpegSeconds(_ line: String) -> Double? {
        let l = line.trimmingCharacters(in: .whitespaces)
        for key in ["out_time_us=", "out_time_ms="] where l.hasPrefix(key) {
            return Double(l.dropFirst(key.count)).flatMap { $0 >= 0 ? $0 / 1_000_000 : nil }
        }
        guard l.hasPrefix("out_time=") else { return nil }
        let parts = l.dropFirst(9).split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3 else { return nil }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    /// Percent from a WhisperX progress line (`Progress: 6.25%...`).
    public static func whisperXPercent(_ line: String) -> Double? {
        guard let r = line.range(of: #"^\s*Progress:\s*\d+(\.\d+)?%"#, options: .regularExpression) else { return nil }
        return Double(line[r].drop { !$0.isNumber }.dropLast()).flatMap { $0 <= 100 ? $0 : nil }
    }

    /// Percent from a whisper-cli progress line.
    public static func whisperPercent(_ line: String) -> Double? {
        guard let r = line.range(of: #"progress\s*=\s*(\d+)\s*%"#, options: .regularExpression) else { return nil }
        return Double(line[r].filter(\.isNumber))
    }
}
