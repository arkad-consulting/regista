import Foundation

/// Downloads of the ComfyUI model files (#121): a missing file with a direct URL in the manifest goes into the models
/// folder of the ComfyUI folder Regista knows (`comfyStart` as a folder, or the folder found in the usual places), never
/// into one guessed from a running server. The bytes land in `<name>.part` next to the target (kept after a Cancel or a
/// lost connection, and resumed with a Range request), the sha256 of the whole file is checked, then it is renamed into
/// place. Free space is checked before the first byte; a file already there with the right size is never fetched
/// again, and one with another size is never overwritten.
public enum ModelFetch {
    /// Where the downloads come from and how much room there is: the manifest's URLs and the volume's free space by
    /// default; a test points them at a stand-in server and a disk of its own.
    public struct Source: Sendable {
        public var url: @Sendable (EngineManifest.ModelFile) -> URL?
        public var freeSpace: @Sendable (URL) -> Int64?

        public init(url: @escaping @Sendable (EngineManifest.ModelFile) -> URL? = { $0.download.flatMap(URL.init(string:)) },
                    freeSpace: @escaping @Sendable (URL) -> Int64? = ModelFetch.freeSpace) {
            self.url = url
            self.freeSpace = freeSpace
        }

        /// Downloads that go nowhere (an address where nothing listens): what a host outside the standard set gets.
        public static var unreachable: Source { Source(url: { URL(string: "http://127.0.0.1:9/")!.appendingPathComponent($0.name) }) }
    }

    /// The bytes free for important use on the volume that holds `url` (or its nearest existing parent).
    @Sendable public static func freeSpace(_ url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.path != "/" { u.deleteLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// The headroom kept free beyond the files themselves (the manifest's disk margin).
    public static var marginBytes: Int64 { Int64(EngineManifest.shared.diskMarginGB * 1e9) }

    // MARK: where a file goes

    /// What can be done for one model file on this Mac.
    public enum Plan: Equatable, Sendable {
        /// Missing from the ComfyUI folder Regista knows and downloadable from `url`.
        case ready(target: URL, url: URL)
        /// Already there with the right size: never downloaded again.
        case there(target: URL)
        /// A file of another size has its name: not overwritten.
        case otherSize(target: URL, bytes: Int64)
        /// No direct URL: its publisher asks for a login or an accepted licence on its page.
        case manual
        /// Regista does not know the ComfyUI folder (a start program, only an address, or a folder it cannot use).
        case noFolder(String)

        public var state: String {
            switch self {
            case .ready: "ready"
            case .there: "there"
            case .otherSize: "otherSize"
            case .manual: "manual"
            case .noFolder: "noFolder"
            }
        }

        public var target: URL? {
            switch self {
            case .ready(let t, _), .there(let t), .otherSize(let t, _): t
            case .manual, .noFolder: nil
            }
        }
    }

    /// The ComfyUI folder Regista knows as a folder, or why it knows none.
    public static func folder(_ location: ComfyServer.Location) -> Result<URL, FetchFailure> {
        switch location.start {
        case .folder(let f, _): return .success(f)
        case .executable(let e):
            return .failure(FetchFailure(.noFolder, "Regista starts ComfyUI with a program (\(e.path)), so it does not know ComfyUI's folder: set the ComfyUI folder in Settings › Motori › ComfyUI to download the model files into it"))
        case nil:
            if let p = location.startProblem {
                return .failure(FetchFailure(.noFolder, "the ComfyUI folder set in Regista cannot be used (\(p)): fix it in Settings › Motori › ComfyUI to download the model files into it"))
            }
            return .failure(FetchFailure(.noFolder, "Regista knows only ComfyUI's address (\(location.server.absoluteString)), not its folder: set the ComfyUI folder in Settings › Motori › ComfyUI to download the model files into it"))
        }
    }

    /// `<ComfyUI folder>/models/<manifest folder>/<name>`.
    public static func target(_ f: EngineManifest.ModelFile, in folder: URL) -> URL {
        folder.appendingPathComponent("models", isDirectory: true).appendingPathComponent(f.folder, isDirectory: true).appendingPathComponent(f.name)
    }

    public static func plan(_ f: EngineManifest.ModelFile, location: ComfyServer.Location, source: Source = Source()) -> Plan {
        let folder: URL
        switch Self.folder(location) {
        case .success(let u): folder = u
        case .failure(let e): return .noFolder(e.message)
        }
        let target = target(f, in: folder)
        if let size = fileSize(target) { return size == f.bytes ? .there(target: target) : .otherSize(target: target, bytes: size) }
        guard let url = source.url(f) else { return .manual }
        return .ready(target: target, url: url)
    }

    /// The sentence a person reads for a plan (nil when there is nothing to say: ready).
    public static func note(_ plan: Plan, _ f: EngineManifest.ModelFile) -> String? {
        switch plan {
        case .ready: return nil
        case .there: return "already in models/\(f.folder): Regista does not download it again (restart ComfyUI if it does not see it)"
        case .otherSize(_, let bytes):
            return "a file named \(f.name) is already in models/\(f.folder) with another size (\(bytes) bytes, the manifest's is \(f.bytes)): Regista does not overwrite it; move it away to download it again"
        case .manual:
            return "its publisher asks for a login or an accepted licence on its page: download it there (\(f.url)) and put it in ComfyUI's models/\(f.folder) folder"
        case .noFolder(let why): return why
        }
    }

    /// The plan as generate.check and engines.status report it beside each file.
    public static func json(_ plan: Plan, _ f: EngineManifest.ModelFile) -> [String: JSONValue] {
        var o: [String: JSONValue] = ["download": .string(plan.state)]
        if let t = plan.target { o["target"] = .string(t.path) }
        if let n = note(plan, f) { o["downloadNote"] = .string(n) }
        if let job = ModelDownloads.shared.running(f.name), job.target == plan.target {
            o["jobId"] = .string(job.id)
            o["received"] = .number(Double(job.received))
        }
        return o
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), (a[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        return (a[.size] as? NSNumber)?.int64Value
    }

    /// The refusal when the disk lacks the room for `bytes` of downloads plus the margin, saying how much is missing (nil:
    /// there is enough).
    public static func shortfall(bytes: Int64, at folder: URL, source: Source) -> FetchFailure? {
        let need = bytes + marginBytes
        guard let free = source.freeSpace(folder), free < need else { return nil }
        return FetchFailure(.space(missing: need - free), "not enough free space on the disk of \(folder.path): the download needs \(EngineManifest.sizeText(need)) (\(EngineManifest.sizeText(bytes)) of files plus a \(EngineManifest.sizeText(marginBytes)) margin), \(EngineManifest.sizeText(max(free, 0))) are free: free \(EngineManifest.sizeText(need - free)) more, then download again")
    }

    // MARK: one download

    /// Downloads `f` from `url` to `target` (see the type's comment). `progress` gets the bytes in the file so far and
    /// its total; `cancellation` stops it (the partial file is kept). Returns the target.
    @discardableResult
    public static func run(_ f: EngineManifest.ModelFile, from url: URL, to target: URL, source: Source = Source(),
                           cancellation: GenerationCancellation? = nil, timeout: TimeInterval = 60,
                           progress: @escaping @Sendable (Int64, Int64) -> Void = { _, _ in }) throws -> URL {
        let fm = FileManager.default
        if let size = fileSize(target) {
            guard size == f.bytes else {
                throw FetchFailure(.otherSize, note(.otherSize(target: target, bytes: size), f)!)
            }
            progress(size, f.bytes)
            return target
        }
        let dir = target.deletingLastPathComponent()
        do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw FetchFailure(.io, "cannot create \(dir.path): \(error.localizedDescription)") }
        let part = target.appendingPathExtension("part")
        var have = fileSize(part) ?? 0
        if have > f.bytes { try? fm.removeItem(at: part); have = 0 }
        if let short = shortfall(bytes: f.bytes - have, at: dir, source: source) { throw short }
        if have < f.bytes {
            try transfer(url, to: part, from: have, total: f.bytes, cancellation: cancellation, timeout: timeout, progress: progress)
        }
        let size = fileSize(part) ?? 0
        if size > f.bytes {
            try? fm.removeItem(at: part)
            throw FetchFailure(.checksum, "the server sent more bytes than \(f.name) has (\(size), the manifest's is \(f.bytes)): the partial file was removed; download it again")
        }
        guard size == f.bytes else {
            throw FetchFailure(.lost(received: size, total: f.bytes), "the connection ended after \(EngineManifest.sizeText(size)) of \(EngineManifest.sizeText(f.bytes)) of \(f.name): download it again to resume from there")
        }
        CommandJob.say("checking \(f.name)")
        let digest: String
        do { digest = try FileDigest.sha256(part) } catch { throw FetchFailure(.io, "cannot read \(part.path) to check it: \(error)") }
        if let expected = f.sha256, digest != expected {
            try? fm.removeItem(at: part)
            throw FetchFailure(.checksum, "the downloaded \(f.name) does not match its checksum (sha256 \(digest.prefix(12))…, expected \(expected.prefix(12))…): the file was removed. Download it again; if it fails again, the file on the publisher's page changed")
        }
        do { try fm.moveItem(at: part, to: target) }
        catch { throw FetchFailure(.io, "cannot move \(f.name) into \(dir.path): \(error.localizedDescription)") }
        return target
    }

    /// GET `url` into `part` from byte `offset` (a Range request when the partial file has bytes), appending.
    static func transfer(_ url: URL, to part: URL, from offset: Int64, total: Int64, cancellation: GenerationCancellation?,
                         timeout: TimeInterval, progress: @escaping @Sendable (Int64, Int64) -> Void) throws {
        if !FileManager.default.fileExists(atPath: part.path) { FileManager.default.createFile(atPath: part.path, contents: nil) }
        guard let handle = FileHandle(forWritingAtPath: part.path) else { throw FetchFailure(.io, "cannot write \(part.path)") }
        defer { try? handle.close() }
        let sink = Sink(handle: handle, offset: offset, total: total, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 7 * 24 * 3600
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: sink, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let task = session.dataTask(with: request)
        task.resume()
        while sink.done.wait(timeout: .now() + 0.2) == .timedOut {
            if cancellation?.isCancelled == true || CommandJob.current?.isCancelled == true { task.cancel() }
        }
        if cancellation?.isCancelled == true || CommandJob.current?.isCancelled == true {
            throw FetchFailure(.cancelled, "cancelled")
        }
        if let failure = sink.failure { throw failure }
        if let error = sink.error {
            let got = fileSize(part) ?? 0
            throw FetchFailure(.lost(received: got, total: total), "the connection was lost after \(EngineManifest.sizeText(got)) of \(EngineManifest.sizeText(total)) (\(error.localizedDescription)): download it again to resume from there")
        }
    }

    /// The download's delegate: checks the answer, appends the bytes, reports progress.
    private final class Sink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let handle: FileHandle
        let total: Int64
        let progress: @Sendable (Int64, Int64) -> Void
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var written: Int64
        private var _failure: FetchFailure?
        private var _error: Error?
        var failure: FetchFailure? { lock.withLock { _failure } }
        var error: Error? { lock.withLock { _error } }

        init(handle: FileHandle, offset: Int64, total: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
            self.handle = handle
            self.written = offset
            self.total = total
            self.progress = progress
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let start = written
            switch status {
            case 206 where start > 0:
                // The rest of the file, from where the partial one ends (a server that starts elsewhere is not trusted).
                let range = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") ?? ""
                if let from = range.split(separator: " ").last?.split(separator: "-").first.flatMap({ Int64($0) }), from != start {
                    fail(FetchFailure(.http(status), "the server resumed the download at byte \(from) instead of \(start): download it again"))
                    completionHandler(.cancel)
                    return
                }
                try? handle.seek(toOffset: UInt64(start))
                completionHandler(.allow)
            case 200, 206:
                // The whole file (the server ignored the Range, or there was nothing to resume): start over.
                try? handle.truncate(atOffset: 0)
                lock.withLock { written = 0 }
                completionHandler(.allow)
            default:
                fail(FetchFailure(.http(status), "the server answered \(status) for \(response.url?.absoluteString ?? "the file"): try again later"))
                completionHandler(.cancel)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            do {
                try handle.write(contentsOf: data)
            } catch {
                fail(FetchFailure(.io, "cannot write the download: \(error.localizedDescription)"))
                dataTask.cancel()
                return
            }
            let now = lock.withLock { written += Int64(data.count); return written }
            progress(now, total)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            lock.withLock { if _failure == nil, let error, (error as NSError).code != NSURLErrorCancelled { _error = error } }
            done.signal()
        }

        private func fail(_ f: FetchFailure) { lock.withLock { if _failure == nil { _failure = f } } }
    }
}

/// Why a download could not be done or finish, with the sentence a person can act on (English, like every engine
/// message; the app words each kind in the person's language).
public struct FetchFailure: Error, Equatable, CustomStringConvertible, LocalizedError, Sendable {
    public enum Kind: Equatable, Sendable {
        case noFolder, otherSize, manual, cancelled, io, checksum
        case space(missing: Int64)
        case lost(received: Int64, total: Int64)
        case http(Int)
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}

// MARK: - the downloads of this process

/// The downloads running in this process (generate.fetch answers at once; generate.status, Settings › Motori and the
/// jobs list follow them). One download per target at a time: asking again for a file that is downloading there gets its job.
public final class ModelDownloads: @unchecked Sendable {
    public static let shared = ModelDownloads()

    public enum State: String, Sendable { case running, done, failed, cancelled }

    public struct Job: Sendable {
        public let id: String
        public let file: EngineManifest.ModelFile
        public let target: URL
        public var state: State = .running
        public var received: Int64 = 0
        public var failure: FetchFailure?

        public var json: JSONValue {
            var o: [String: JSONValue] = ["jobId": .string(id), "kind": "download", "file": .string(file.name),
                                          "folder": .string("models/\(file.folder)"), "target": .string(target.path),
                                          "status": .string(state.rawValue), "received": .number(Double(received)),
                                          "bytes": .number(Double(file.bytes)), "size": .string(file.sizeText),
                                          "percent": .number(file.bytes > 0 ? (Double(received) / Double(file.bytes) * 1000).rounded() / 10 : 0)]
            if let f = failure { o["error"] = .string(f.message) }
            return .object(o)
        }
    }

    private let lock = NSCondition()
    private var jobs: [String: Job] = [:]
    private var cancels: [String: GenerationCancellation] = [:]
    private var next = 1

    public init() {}

    public func job(_ id: String) -> Job? { lock.withLock { jobs[id] } }
    public var all: [Job] { lock.withLock { jobs.values.sorted { $0.id.compare($1.id, options: .numeric) == .orderedAscending } } }
    /// The running download of a file, if any.
    public func running(_ name: String) -> Job? { lock.withLock { jobs.values.first { $0.file.name == name && $0.state == .running } } }

    /// Starts downloading `f` (on a thread of its own) unless it is already downloading; returns its job.
    @discardableResult
    public func start(_ f: EngineManifest.ModelFile, from url: URL, to target: URL, source: Source) -> Job {
        let (job, cancellation, fresh): (Job, GenerationCancellation, Bool) = lock.withLock {
            if let j = jobs.values.first(where: { $0.target == target && $0.state == .running }) { return (j, cancels[j.id]!, false) }
            let j = Job(id: "d\(next)", file: f, target: target)
            next += 1
            let c = GenerationCancellation()
            jobs[j.id] = j
            cancels[j.id] = c
            return (j, c, true)
        }
        guard fresh else { return job }
        let id = job.id
        Thread.detachNewThread { [self] in
            var state = State.done, failure: FetchFailure?
            do {
                try ModelFetch.run(f, from: url, to: target, source: source, cancellation: cancellation) { received, _ in
                    self.update(id) { $0.received = received }
                }
            } catch let e as FetchFailure {
                (state, failure) = e.kind == .cancelled ? (.cancelled, nil) : (.failed, e)
            } catch {
                (state, failure) = (.failed, FetchFailure(.io, "\(error)"))
            }
            self.update(id) { j in
                j.state = state
                j.failure = failure
                if state == .done { j.received = f.bytes }
            }
        }
        return job
    }
    public typealias Source = ModelFetch.Source

    /// Stops a download (its partial file stays, for the next one to resume).
    public func cancel(_ id: String) {
        let c = lock.withLock { cancels[id] }
        c?.cancel()
    }

    /// Waits for a download to end, calling `progress` with the bytes so far about four times a second. Returns the job
    /// as it ended (nil: no such job).
    public func wait(_ id: String, progress: (Int64) -> Void = { _ in }) -> Job? {
        while true {
            let j: Job? = lock.withLock {
                if jobs[id]?.state == .running { _ = lock.wait(until: Date().addingTimeInterval(0.25)) }
                return jobs[id]
            }
            guard let j else { return nil }
            if j.state != .running { return j }
            progress(j.received)
        }
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        lock.withLock {
            guard var j = jobs[id] else { return }
            change(&j)
            jobs[id] = j
            if j.state != .running { cancels[id] = nil }
            lock.broadcast()
        }
    }
}
