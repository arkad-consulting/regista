import Foundation

// A log of the moments the app stops answering (#161): a watchdog thread asks the main queue for an answer every half
// second; when none comes for two seconds it samples the process once with macOS's own `sample` tool into
// ~/Library/Logs/Regista/hang-<date>.txt, and writes there how long the hang lasted once the main thread answers again.
// Nothing is shown, sent or uploaded: the files stay on this Mac (Impostazioni › Generale shows them in the Finder).

/// Takes the sample of a hang: `/usr/bin/sample` on the Mac, a stand-in in the tests.
protocol HangSampler: Sendable {
    func sample(pid: Int32, seconds: Int, into file: URL)
}

/// macOS's `sample` tool, run directly (no shell, the full path, the arguments as an array), waited for.
struct MacSampler: HangSampler {
    func sample(pid: Int32, seconds: Int, into file: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = [String(pid), String(seconds), "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            try? "sample did not run: \(error.localizedDescription)\n".write(to: file, atomically: true, encoding: .utf8)   // l10n-ignore
        }
    }
}

enum HangLog {
    /// `$REGISTA_LOGS_DIR` (the tests' scratch folder), else ~/Library/Logs/Regista.
    static var folder: URL {
        if let p = ProcessInfo.processInfo.environment["REGISTA_LOGS_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Regista", isDirectory: true)   // l10n-ignore
    }

    /// The hang reports in `folder`, newest first.
    static func reports(in folder: URL = folder) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("hang-") && $0.hasSuffix(".txt") }.sorted(by: >).map { folder.appendingPathComponent($0) }
    }

    /// The app's watchdog (started at launch, release builds too).
    static let watchdog = HangWatchdog(folder: folder)
}

/// The watchdog itself. Its state lives on its own serial queue; while the app is idle it costs one timer tick and one
/// empty block on the main queue every `interval` (no busy loop).
final class HangWatchdog: @unchecked Sendable {
    struct Limits {
        /// How often the main queue is asked.
        var interval = 0.5
        /// How long without an answer is a hang.
        var threshold = 2.0
        /// At most one sample in this many seconds.
        var cooldown = 60.0
        /// Reports kept (the oldest go).
        var keep = 20
        /// The length of the sample.
        var sampleSeconds = 3
    }

    let folder: URL
    let limits: Limits
    private let sampler: HangSampler
    private let clock: @Sendable () -> Double
    private let now: @Sendable () -> Date
    private let ping: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let queue = DispatchQueue(label: "regista.hang-watchdog", qos: .utility)   // l10n-ignore
    private var timer: DispatchSourceTimer?

    // On `queue` only.
    /// When the question in flight was asked (nil: answered).
    private var askedAt: Double?
    /// The report of the hang in progress.
    private var report: URL?
    private var lastSample = -Double.infinity
    private var looks = 0

    /// `clock`: seconds, monotonic; `now`: the date in the report's name; `ping`: runs a block on the watched queue (the
    /// main queue in the app, a queue the test blocks in the tests).
    init(folder: URL, limits: Limits = Limits(), sampler: HangSampler = MacSampler(),
         clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
         now: @escaping @Sendable () -> Date = { Date() },
         ping: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
        self.folder = folder
        self.limits = limits
        self.sampler = sampler
        self.clock = clock
        self.now = now
        self.ping = ping
    }

    /// Starts the timer (once).
    func start() {
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + limits.interval, repeating: limits.interval, leeway: .milliseconds(50))
            t.setEventHandler { [weak self] in self?.look() }
            t.resume()
            timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// One look now, as the timer's (a test drives the watchdog with it on a stand-in clock).
    func lookNow() { queue.sync { look() } }

    /// Waits until the blocks queued on the watchdog's queue so far have run (a test reads the folder after it).
    func drain() { queue.sync {} }

    /// The looks taken so far.
    var lookCount: Int { queue.sync { looks } }

    private func look() {
        looks += 1
        let t = clock()
        guard let asked = askedAt else {
            askedAt = t
            ping { [weak self] in
                guard let self else { return }
                let answered = self.clock()
                self.queue.async { self.answer(at: answered) }
            }
            return
        }
        guard t - asked >= limits.threshold, report == nil, t - lastSample >= limits.cooldown else { return }
        lastSample = t
        let file = newReportURL()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // On this queue: the answer, queued meanwhile, is written after the sample.
        sampler.sample(pid: ProcessInfo.processInfo.processIdentifier, seconds: limits.sampleSeconds, into: file)
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        report = file
        prune()
    }

    private func answer(at answered: Double) {
        guard let asked = askedAt else { return }
        askedAt = nil
        guard let file = report else { return }
        report = nil
        let line = String(format: "\nRegista's main thread did not answer for %.1f s.\n", answered - asked)   // l10n-ignore
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }

    /// hang-2026-11-24-15.03.12.txt (another one in the same second gets -2, -3…).
    private func newReportURL() -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HH.mm.ss"   // l10n-ignore
        let stem = "hang-" + f.string(from: now())
        var url = folder.appendingPathComponent(stem + ".txt")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(stem)-\(n).txt")
            n += 1
        }
        return url
    }

    /// Keeps the newest `limits.keep` reports.
    private func prune() {
        for old in HangLog.reports(in: folder).dropFirst(limits.keep) { try? FileManager.default.removeItem(at: old) }
    }
}
