import CryptoKit
import Foundation

// Generated media (issue #11): B-roll stills and clips, music beds, upscales. A provider turns a request
// (prompt + reference images + params) into one file through a separate process; the job runs in a folder of
// the cache keyed by the request (refs hashed by content), so the same request never runs twice. The result
// is copied into the project's media folder and imported as an asset that carries where it came from.

public enum GenerationKind: String, Codable, CaseIterable, Sendable {
    case image, video, music
    /// Real-ESRGAN x4 + RIFE to 30 fps of an existing clip (ComfyUI).
    case upscale
    /// Voice-over in a cloned voice (VoxCPM2): the prompt is the text to say.
    case voice

    public static let names = allCases.map(\.rawValue)
}

/// What to generate. Canonical (sorted-key JSON) so its hash identifies the job, the estimate and the approval.
public struct GenerationRequest: Codable, Hashable, Sendable {
    public var provider: String
    public var kind: GenerationKind
    public var prompt: String
    /// Provider model id (nil: the provider's default for the kind).
    public var model: String?
    /// Reference files (start frame, image references, the clip to upscale), absolute paths.
    public var refs: [String]
    /// Seconds (video, music).
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var seed: Int?
    /// Provider-specific flags passed through (e.g. Higgsfield `resolution: 480p`, ACE-Step `bpm: 100`).
    public var options: [String: String]?

    public init(provider: String, kind: GenerationKind, prompt: String, model: String? = nil, refs: [String] = [],
                duration: Double? = nil, width: Int? = nil, height: Int? = nil, seed: Int? = nil, options: [String: String]? = nil) {
        self.provider = provider
        self.kind = kind
        self.prompt = prompt
        self.model = model
        self.refs = refs
        self.duration = duration
        self.width = width
        self.height = height
        self.seed = seed
        self.options = options
    }

    /// SHA-256 (hex, 16 chars) of the canonical request with every reference file replaced by the SHA-256 of its
    /// content: the same start frame copied into another project hits the same job.
    public func hash() throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var canonical = self
        canonical.refs = try refs.map { try FileDigest.sha256(URL(fileURLWithPath: $0)) }
        return Generation.digest(String(decoding: try e.encode(canonical), as: UTF8.self))
    }

    /// The seed used when none is given: derived from the prompt, so a re-run hits the cache.
    public static func defaultSeed(_ prompt: String) -> Int {
        Int(SHA256.hash(data: Data(prompt.utf8)).prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) } & 0x7FFF_FFFF)
    }
}

/// Cost of a request before running it.
public struct GenerationEstimate: Codable, Hashable, Sendable {
    public var estimateID: String
    public var provider: String
    public var model: String
    public var kind: GenerationKind
    public var prompt: String
    public var credits: Double
    /// "credits" (Higgsfield) or "free" (local).
    public var unit: String
    public var requestHash: String
    public var paid: Bool

    public init(provider: String, model: String, request: GenerationRequest, requestHash: String, credits: Double, paid: Bool) {
        self.provider = provider
        self.model = model
        kind = request.kind
        prompt = request.prompt
        self.credits = credits
        unit = paid ? "credits" : "free"
        self.requestHash = requestHash
        self.paid = paid
        estimateID = "e-" + Generation.digest("\(requestHash)|\(credits)").prefix(12)
    }
}

/// Where a generated asset came from (on `MediaAsset.generated`).
public struct GenerationInfo: Codable, Hashable, Sendable {
    public var provider: String
    public var model: String
    public var kind: GenerationKind
    public var prompt: String
    public var seed: Int?
    /// Credits spent (0 for local providers).
    public var cost: Double
    public var unit: String
    /// ISO 8601.
    public var created: String
    public var jobID: String
    public var requestHash: String
    /// The asset this one was made from (upscale, image → video).
    public var sourceAssetID: String?
    /// Provider job id (Higgsfield), for retrospection.
    public var remoteID: String?
    /// Wall time of the job, seconds.
    public var seconds: Double?
}

/// One generate.run on the project (running jobs finish through generate.status).
public struct GenerationJob: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case running, done, failed }
    public var id: String
    public var request: GenerationRequest
    public var requestHash: String
    public var status: Status
    /// The job folder in the cache.
    public var directory: String
    public var assetID: String?
    public var sourceAssetID: String?
    public var error: String?
    public var cost: Double
    public var created: String
}

/// What a finished job produced.
public struct GenerationOutput: Codable, Hashable, Sendable {
    /// The result file inside the job folder.
    public var file: String
    public var model: String
    public var seed: Int?
    public var remoteID: String?
    public var seconds: Double?
    /// Credits the run cost (set by the engine when it records the output).
    public var cost: Double? = nil
}

/// A process to run for a job: executable, arguments, extra environment.
public struct GenerationProcess: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]

    public init(_ executable: URL, _ arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public struct GeneratorModel: Sendable {
    public var id: String
    public var kind: GenerationKind
    public var note: String
    public var isDefault: Bool

    public init(_ id: String, _ kind: GenerationKind, _ note: String, isDefault: Bool = false) {
        self.id = id
        self.kind = kind
        self.note = note
        self.isDefault = isDefault
    }
}

/// A generation backend. The job itself is a separate process (`process`), run detached or waited for by the
/// engine; `collect` reads what it left in the job folder.
public protocol GeneratorProvider {
    var id: String { get }
    var title: String { get }
    /// Paid providers need a human approval per run and draw on the hard budget.
    var paid: Bool { get }
    var minimumTier: MachineTier { get }
    var models: [GeneratorModel] { get }
    /// Why it cannot run this kind (nil: it can).
    func unavailableReason(_ kind: GenerationKind) -> String?
    /// Credits the request will cost (0 for local providers). May call the provider's CLI (free).
    func estimate(_ request: GenerationRequest) throws -> Double
    func process(_ request: GenerationRequest, job: URL) throws -> GenerationProcess
    /// Validates the request and fills in what the job depends on beyond the caller's params (VoxCPM: the voice files
    /// and the text after the lexicon), before it is hashed: the cache key then changes when they do.
    func prepare(_ request: GenerationRequest) throws -> GenerationRequest
    /// Reads the job's stdout and files once its process exited with 0; returns the result (a file in `job`).
    func collect(_ request: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput
    /// Called after a waited-for run (ComfyUI: stop the server so it frees the memory).
    func finish(keepRunning: Bool)
    /// About how long the job takes on this Mac, seconds (nil: not known). `sourceSeconds`: the length of the clip an
    /// upscale reads.
    func seconds(_ request: GenerationRequest, sourceSeconds: Double?) -> Double?
    /// The picture formats this provider makes for a kind ("9:16" → width × height), the first one the default.
    func formats(_ kind: GenerationKind) -> [GenerationFormat]
}

/// A picture format a provider makes: its aspect name and the size it asks for.
public struct GenerationFormat: Hashable, Sendable {
    public var name: String
    public var width: Int
    public var height: Int

    public init(_ name: String, _ width: Int, _ height: Int) {
        self.name = name
        self.width = width
        self.height = height
    }
}

extension GeneratorProvider {
    public func model(for request: GenerationRequest) -> String {
        request.model ?? models.first { $0.kind == request.kind && $0.isDefault }?.id ?? models.first { $0.kind == request.kind }?.id ?? "?"
    }

    public func finish(keepRunning: Bool) {}

    public func prepare(_ request: GenerationRequest) throws -> GenerationRequest { request }

    public func seconds(_ request: GenerationRequest, sourceSeconds: Double?) -> Double? { nil }

    public func formats(_ kind: GenerationKind) -> [GenerationFormat] { [] }
}

public enum Generation {
    static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

    /// `~/Library/Application Support/Regista`: budget.json and approvals.json.
    public static var defaultStateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Regista")
    }

    /// The last JSON value on stdout (CLIs print logs before their result line).
    static func lastJSON(_ text: String) -> JSONValue? {
        if let whole = try? JSONValue.parse(text.trimmingCharacters(in: .whitespacesAndNewlines)) { return whole }
        for line in text.split(separator: "\n").reversed() {
            let l = line.trimmingCharacters(in: .whitespaces)
            if (l.hasPrefix("{") || l.hasPrefix("[")), let v = try? JSONValue.parse(l) { return v }
        }
        return nil
    }
}

// MARK: - Job folder

/// A job folder: request.json, stdout.txt, stderr.txt, `exit` (written last, the exit status) and the result.
public struct GenerationJobDir {
    public let url: URL

    public init(_ url: URL) { self.url = url }

    public var exitFile: URL { url.appendingPathComponent("exit") }
    public var outputFile: URL { url.appendingPathComponent("output.json") }
    public var stdoutFile: URL { url.appendingPathComponent("stdout.txt") }
    public var stderrFile: URL { url.appendingPathComponent("stderr.txt") }

    /// The collected output of a finished, successful job.
    public var output: GenerationOutput? {
        guard let d = FileManager.default.contents(atPath: outputFile.path) else { return nil }
        guard let o = try? JSONDecoder().decode(GenerationOutput.self, from: d), FileManager.default.fileExists(atPath: o.file) else { return nil }
        return o
    }

    /// nil while the process runs.
    public var exitStatus: Int32? {
        guard let s = try? String(contentsOf: exitFile, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var stdout: String { (try? String(contentsOf: stdoutFile, encoding: .utf8)) ?? "" }
    public var stderrTail: String {
        ((try? String(contentsOf: stderrFile, encoding: .utf8)) ?? "").split(separator: "\n").suffix(10).joined(separator: "\n")
    }

    /// Starts the process through /bin/sh, which writes stdout/stderr and then the exit status. `wait`: block until it ends.
    /// `cancellation`: a waited-for run registers there, so the host's Cancel can stop it (the exit status is then
    /// the signal's, and the folder is free for another run).
    public func launch(_ p: GenerationProcess, wait: Bool, cancellation: GenerationCancellation? = nil) throws {
        if wait, cancellation?.isCancelled == true { throw CommandError(.io, "cancelled") }
        let fm = FileManager.default
        for f in [exitFile, outputFile, stdoutFile, stderrFile] { try? fm.removeItem(at: f) }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        // `exec mv`: the status is written by the wrapper's own process, never by a child of it, which a Cancel (it stops
        // every process under the wrapper) could kill before the folder says the run ended.
        let script = #""$0" "$@" > stdout.txt 2> stderr.txt; echo $? > exit.tmp && exec mv exit.tmp exit"#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, p.executable.path] + p.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(p.environment) { $1 }
        process.currentDirectoryURL = url
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        if wait { process.terminationHandler = { _ in exited.signal() } }
        do { try process.run() } catch { throw CommandError(.io, "cannot start \(p.executable.lastPathComponent): \(error.localizedDescription)") }
        guard wait else { return }
        let pid = process.processIdentifier
        guard let cancellation else { process.waitUntilExit(); return }
        cancellation.register(pid)
        defer { cancellation.unregister(pid) }
        // After a cancel, stop again every half second whatever runs under the wrapper: a cancel that came before the
        // wrapper had started its child (a busy Mac) found nothing to stop, and the child would run to its end (#77).
        while exited.wait(timeout: .now() + 0.5) == .timedOut {
            if cancellation.isCancelled { GenerationCancellation.terminateChildren(of: pid) }
        }
        process.waitUntilExit()
    }
}

/// The Cancel of one engine host (the app's jobs): stops the generation processes it waits for. `launch` registers
/// each waited-for /bin/sh wrapper; `cancel` terminates everything under it (uv, python) but not the wrapper itself,
/// which then writes the exit status — the job folder never looks "still running". Reset before each job.
public final class GenerationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    /// pid → whether the process itself is stopped too (a direct engine process: ffmpeg, whisper-cli, deep-filter) or
    /// only what runs under it (the /bin/sh wrapper of a generation, which must still write its exit status).
    private var running: [Int32: Bool] = [:]
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Ready for the next job.
    public func reset() { lock.withLock { cancelled = false } }

    func register(_ pid: Int32, includingSelf: Bool = false) {
        let stop = lock.withLock { () -> Bool in
            running[pid] = includingSelf
            return cancelled
        }
        if stop { Self.terminate(pid, includingSelf: includingSelf) }
    }

    func unregister(_ pid: Int32) { _ = lock.withLock { running.removeValue(forKey: pid) } }

    /// Stops what runs now and refuses to start anything until `reset`.
    public func cancel() {
        let pids = lock.withLock { () -> [Int32: Bool] in
            cancelled = true
            return running
        }
        for (pid, includingSelf) in pids { Self.terminate(pid, includingSelf: includingSelf) }
    }

    /// SIGTERM to every descendant of `pid`, then SIGKILL to whatever is still there 3 s later.
    static func terminateChildren(of pid: Int32) { terminate(pid, includingSelf: false) }

    /// SIGTERM to every descendant of `pid` (listed before anything is stopped: a stopped parent hands its children to
    /// launchd) and to `pid` itself when `includingSelf`, then SIGKILL to whatever is still there 3 s later.
    static func terminate(_ pid: Int32, includingSelf: Bool) {
        let first = descendants(of: pid) + (includingSelf ? [pid] : [])
        for d in first { kill(d, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            for d in first where kill(d, 0) == 0 { kill(d, SIGKILL) }
        }
    }

    /// Every process under `pid`, read from the kernel (libproc): no helper process to launch, so a Cancel works at
    /// once even when the machine is busy.
    static func descendants(of pid: Int32) -> [Int32] {
        let estimate = proc_listchildpids(pid, nil, 0)
        guard estimate > 0 else { return [] }
        var buffer = [Int32](repeating: 0, count: Int(estimate) + 8)
        let n = proc_listchildpids(pid, &buffer, Int32(buffer.count * MemoryLayout<Int32>.size))
        let children = buffer.prefix(max(0, min(Int(n), buffer.count))).filter { $0 > 0 }
        return children.flatMap { [$0] + descendants(of: $0) }
    }

}

// MARK: - Budget and approvals

/// The hard budget of paid providers: `budget.json` in the state folder. The project rule (issue #11, 2026-11-01): at most
/// **2 Higgsfield calls in total**, ever. The cap is a constant here — the file can lower it, never raise it — and
/// every paid run is counted before it starts (a run that fails after starting may still have cost credits).
public struct GenerationBudget {
    public static let hardCaps = ["higgsfield": 2]

    public struct Call: Codable, Hashable, Sendable {
        public var at: String
        public var model: String
        public var prompt: String
        public var credits: Double
        public var estimateID: String
        public var project: String?
    }

    public struct Entry: Codable, Hashable, Sendable {
        public var cap: Int
        public var used: Int
        public var remaining: Int
        public var calls: [Call]
    }

    public let file: URL

    public init(directory: URL) { file = directory.appendingPathComponent("budget.json") }

    func load() throws -> [String: Entry] {
        guard let d = FileManager.default.contents(atPath: file.path) else { return [:] }
        do { return try JSONDecoder().decode([String: Entry].self, from: d) }
        catch { throw CommandError(.io, "budget file \(file.path) is unreadable (\(error)): fix or delete it by hand — paid runs stay blocked until then") }
    }

    /// Calls left for a provider (0 for an unknown paid provider: no cap, no runs).
    public func remaining(_ provider: String) throws -> Int {
        let cap = Self.hardCaps[provider] ?? 0
        guard let e = try load()[provider] else { return cap }
        return max(0, min(cap, e.cap) - max(e.used, e.calls.count))
    }

    static func exhausted(_ provider: String, used: Int, cap: Int, file: URL) -> CommandError {
        CommandError.conflict("\(provider) budget exhausted: \(used) of \(cap) paid calls used (hard cap, \(file.path)). No more \(provider) runs — use ComfyUI (free) or reuse existing footage.")
    }

    /// Throws the cap message when no call is left.
    public func requireRemaining(_ provider: String) throws {
        guard try remaining(provider) == 0 else { return }
        let cap = min(Self.hardCaps[provider] ?? 0, (try load()[provider]?.cap) ?? Int.max)
        throw Self.exhausted(provider, used: (try load()[provider]).map { max($0.used, $0.calls.count) } ?? 0, cap: cap, file: file)
    }

    /// Counts one call, or throws when the cap is reached. Atomic across processes (flock on the file).
    public func consume(_ provider: String, _ call: Call) throws -> Int {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return try FileLock.with(file.appendingPathExtension("lock")) {
            var all = try load()
            let cap = Self.hardCaps[provider] ?? 0
            var e = all[provider] ?? Entry(cap: cap, used: 0, remaining: cap, calls: [])
            let used = max(e.used, e.calls.count)
            let left = max(0, min(cap, e.cap) - used)
            guard left > 0 else { throw Self.exhausted(provider, used: used, cap: min(cap, e.cap), file: file) }
            e.cap = min(cap, e.cap)
            e.used = used + 1
            e.remaining = left - 1
            e.calls.append(call)
            all[provider] = e
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(all).write(to: file, options: .atomic)
            return e.remaining
        }
    }

    /// Writes the file with the full cap when it does not exist yet (so the human can see it).
    public func ensureFile() throws {
        guard !FileManager.default.fileExists(atPath: file.path) else { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let all = Self.hardCaps.mapValues { Entry(cap: $0, used: 0, remaining: $0, calls: []) }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(all).write(to: file, options: .atomic)
    }
}

/// Approvals of paid estimates: `approvals.json` in the state folder. generate.estimate records a pending entry,
/// generate.approve (human only) turns it into a single-use token, generate.run consumes the token for exactly the
/// estimated request.
public struct GenerationApprovals {
    public static let lifetime: TimeInterval = 2 * 3600

    public struct Entry: Codable, Hashable, Sendable {
        public enum Status: String, Codable, Sendable { case pending, approved, used, declined }
        public var estimate: GenerationEstimate
        public var status: Status
        public var created: String
        public var token: String?
        public var approvedAt: String?
        public var usedAt: String?
        public var project: String?
    }

    public let file: URL

    public init(directory: URL) { file = directory.appendingPathComponent("approvals.json") }

    public func load() throws -> [Entry] {
        guard let d = FileManager.default.contents(atPath: file.path) else { return [] }
        do { return try JSONDecoder().decode([Entry].self, from: d) }
        catch { throw CommandError(.io, "approvals file \(file.path) is unreadable: \(error)") }
    }

    func update(_ body: (inout [Entry]) throws -> Void) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileLock.with(file.appendingPathExtension("lock")) {
            var all = try load()
            try body(&all)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(all).write(to: file, options: .atomic)
        }
    }

    static func expired(_ iso: String?) -> Bool {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return true }
        return Date().timeIntervalSince(d) > lifetime
    }

    /// Records a paid estimate waiting for the human (kept once per estimate id).
    public func request(_ e: GenerationEstimate, project: String?) throws {
        try update { all in
            if let i = all.firstIndex(where: { $0.estimate.estimateID == e.estimateID && $0.status == .pending }) {
                all[i].created = Generation.now()
                return
            }
            all.append(Entry(estimate: e, status: .pending, created: Generation.now(), project: project))
        }
    }

    /// Estimates still waiting for a decision (what the app's confirmation sheet shows).
    public func pending() throws -> [Entry] {
        try load().filter { $0.status == .pending && !Self.expired($0.created) }
    }

    /// Human decision on a pending estimate: a token when approved.
    public func decide(_ estimateID: String, approve: Bool) throws -> Entry {
        var out: Entry?
        try update { all in
            guard let i = all.lastIndex(where: { $0.estimate.estimateID == estimateID && $0.status == .pending }) else {
                throw CommandError.notFound("no pending estimate \(estimateID): run generate.estimate first (pending estimates expire after 2 h)")
            }
            guard !Self.expired(all[i].created) else { throw CommandError.conflict("estimate \(estimateID) expired: estimate again") }
            if approve {
                var rng = SystemRandomNumberGenerator()   // arc4random: cryptographically secure on Darwin
                all[i].token = "ap-" + (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255, using: &rng)) }.joined()
                all[i].status = .approved
                all[i].approvedAt = Generation.now()
            } else {
                all[i].status = .declined
            }
            out = all[i]
        }
        return out!
    }

    /// Checks a token against the request about to run and marks it used. Throws with the reason otherwise.
    public func consume(token: String, requestHash: String, credits: Double) throws -> Entry {
        var out: Entry?
        try update { all in
            guard let i = all.firstIndex(where: { $0.token == token }) else {
                throw CommandError.invalid("approval \(token) does not exist: the human approves an estimate with generate.approve")
            }
            let e = all[i]
            guard e.status == .approved else { throw CommandError.conflict("approval \(token) is \(e.status.rawValue): approvals are single-use") }
            guard !Self.expired(e.approvedAt) else { throw CommandError.conflict("approval \(token) expired (2 h): estimate and ask again") }
            guard e.estimate.requestHash == requestHash else {
                throw CommandError.conflict("approval \(token) was given for a different estimate (\(e.estimate.estimateID): \(e.estimate.model), \"\(e.estimate.prompt.prefix(60))\"): the prompt, model, refs or params changed — estimate again and ask for a new approval")
            }
            guard credits <= e.estimate.credits + 1e-9 else {
                throw CommandError.conflict("the cost went up from \(e.estimate.credits) to \(credits) credits since approval \(token): ask again")
            }
            all[i].status = .used
            all[i].usedAt = Generation.now()
            out = all[i]
        }
        return out!
    }
}

/// An exclusive advisory lock (flock) on a file for the duration of `body`.
enum FileLock {
    static func with<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CommandError(.io, "cannot open \(url.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CommandError(.io, "cannot lock \(url.path)") }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
