import Foundation

/// Where Regista's ComfyUI is and how it starts (#6). `comfyServer` is the address; when nothing answers there, Regista
/// starts the server from `comfyStart` (a ComfyUI folder or an executable), else from a ComfyUI folder in one of the
/// usual places. A server Regista started is stopped after a waited-for run (its whole process group); a server that
/// was already running is someone else's and only gets `POST /free`.
public enum ComfyServer {
    /// ComfyUI's own default (`python main.py`). The desktop app listens on another port: the person sets it.
    public static let defaultAddress = "http://127.0.0.1:8188"

    /// Where a ComfyUI folder is looked for when `comfyStart` is not set, in this order (documented in the install guide).
    public static let usualPlaces = ["~/ComfyUI", "~/comfy/ComfyUI", "~/Documents/ComfyUI", "~/Developer/ComfyUI",
                                     "~/Projects/ComfyUI", "~/src/ComfyUI", "~/git/ComfyUI", "/Applications/ComfyUI"]

    /// How the server is started.
    public enum Start: Equatable, Sendable {
        /// A ComfyUI folder: `<python> main.py --listen 127.0.0.1 --port <port>` in it.
        case folder(URL, python: URL)
        /// An executable that starts the server (it listens where `comfyServer` says).
        case executable(URL)

        public var path: String {
            switch self {
            case .folder(let f, _): return f.path
            case .executable(let e): return e.path
            }
        }
    }

    /// What Regista knows about the ComfyUI it would use.
    public struct Location: Sendable {
        public var server: URL
        /// The start, nil when there is none (or `startProblem` says why the configured one cannot start).
        public var start: Start?
        /// The start comes from `comfyStart` (false: found in the usual places).
        public var configured: Bool
        /// Why `comfyStart` cannot start a server (a folder without main.py or Python environment, a missing file).
        public var startProblem: String?
    }

    /// `config` with `comfyServer` and `comfyStart` as `file` says now (a missing key: the default; an unreadable file:
    /// `config` unchanged).
    public static func fresh(_ config: EngineConfig, from file: URL) -> EngineConfig {
        guard let d = FileManager.default.contents(atPath: file.path), let o = try? JSONValue.parse(d), o.objectValue != nil else {
            return FileManager.default.fileExists(atPath: file.path) ? config : { var c = config; c.comfyServer = defaultAddress; c.comfyStart = nil; return c }()
        }
        var c = config
        c.comfyServer = o["comfyServer"]?.stringValue ?? defaultAddress
        c.comfyStart = o["comfyStart"]?.stringValue
        return c
    }

    /// The server address of the config (the default when it is not a valid http URL).
    public static func address(_ config: EngineConfig) -> URL {
        let s = config.comfyServer.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host != nil else { return URL(string: defaultAddress)! }
        return u
    }

    /// The Python of a ComfyUI folder's own environment.
    static func python(in folder: URL) -> URL? {
        let fm = FileManager.default
        return [".venv/bin/python", "venv/bin/python", ".venv/bin/python3", "venv/bin/python3"]
            .map { folder.appendingPathComponent($0) }.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// A ComfyUI folder: `main.py` and the `comfy` package.
    static func isComfyFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        var dir: ObjCBool = false
        return fm.fileExists(atPath: folder.appendingPathComponent("main.py").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("comfy").path, isDirectory: &dir) && dir.boolValue
    }

    /// The path as it is on disk (the usual places are matched without regard to case).
    static func canonical(_ url: URL) -> URL {
        guard let r = realpath(url.path, nil) else { return url }
        defer { free(r) }
        return URL(fileURLWithPath: String(cString: r), isDirectory: true)
    }

    /// The start `comfyStart` names, or why it cannot start.
    static func start(from setting: String) -> (Start?, String?) {
        let url = URL(fileURLWithPath: EngineConfig.expand(setting))
        let fm = FileManager.default
        var dir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &dir) else { return (nil, "the ComfyUI folder set in Regista (\(url.path)) does not exist") }
        if !dir.boolValue {
            return fm.isExecutableFile(atPath: url.path) ? (.executable(url), nil)
                : (nil, "\(url.path) is neither a ComfyUI folder nor an executable that starts ComfyUI")
        }
        guard isComfyFolder(url) else { return (nil, "\(url.path) is not a ComfyUI folder (no main.py and comfy folder in it)") }
        guard let py = python(in: url) else {
            return (nil, "the ComfyUI folder \(url.path) has no Python environment of its own (.venv or venv): create it as ComfyUI's instructions say")
        }
        return (.folder(url, python: py), nil)
    }

    /// The first usual place that holds a ComfyUI folder with its Python environment.
    static func find(in places: [String]) -> Start? {
        for p in places {
            let url = URL(fileURLWithPath: EngineConfig.expand(p), isDirectory: true)
            guard isComfyFolder(url), let py = python(in: url) else { continue }
            let real = canonical(url)
            return .folder(real, python: python(in: real) ?? py)
        }
        return nil
    }

    public static func locate(_ config: EngineConfig, places: [String]) -> Location {
        let server = address(config)
        if let s = config.comfyStart?.trimmingCharacters(in: .whitespaces), !s.isEmpty {
            let (start, problem) = start(from: s)
            return Location(server: server, start: start, configured: true, startProblem: problem)
        }
        return Location(server: server, start: find(in: places), configured: false, startProblem: nil)
    }

    // MARK: the server Regista started

    /// `<cache>/comfyui/`: the record of the server Regista started and its log.
    static func folder(_ config: EngineConfig) -> URL { config.url(config.cacheDirectory).appendingPathComponent("comfyui", isDirectory: true) }
    static func recordFile(_ config: EngineConfig) -> URL { folder(config).appendingPathComponent("started.json") }
    public static func logFile(_ config: EngineConfig) -> URL { folder(config).appendingPathComponent("server.log") }

    /// The server Regista started and that still runs: its process (the leader of its group) and when it started.
    public struct Started: Codable, Equatable, Sendable {
        public var pid: Int32
        public var startedAt: UInt64
        public var server: String
    }

    /// When a process started (seconds since 1970), nil when it is gone.
    static func startTime(_ pid: Int32) -> UInt64? {
        var info = proc_bsdinfo()
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        guard n == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_status != 5 /* SZOMB */ else { return nil }
        return info.pbi_start_tvsec
    }

    /// The record, when its process is still the one Regista started (the same pid and start time).
    public static func started(_ config: EngineConfig) -> Started? {
        guard let d = FileManager.default.contents(atPath: recordFile(config).path),
              let r = try? JSONDecoder().decode(Started.self, from: d) else { return nil }
        guard let t = startTime(r.pid), t == r.startedAt else {
            try? FileManager.default.removeItem(at: recordFile(config))
            return nil
        }
        return r
    }

    /// Starts the server in a process group of its own (stdout and stderr to the log) and records it. Returns its pid.
    static func spawn(_ start: Start, server: URL, config: EngineConfig) throws -> Int32 {
        let executable: URL, arguments: [String], directory: URL
        switch start {
        case .folder(let f, let python):
            let port = server.port ?? (server.scheme == "https" ? 443 : 80)
            executable = python
            arguments = ["main.py", "--listen", "127.0.0.1", "--port", String(port)]
            directory = f
        case .executable(let e):
            executable = e
            arguments = []
            directory = e.deletingLastPathComponent()
        }
        try FileManager.default.createDirectory(at: folder(config), withIntermediateDirectories: true)
        let log = logFile(config)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // A group of its own: the stop reaches everything the server started, and nothing of Regista's.
        // Default signal handling and an empty mask: a host that ignores or blocks SIGTERM must not pass that on.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        var env = ProcessInfo.processInfo.environment
        env["PYTORCH_ENABLE_MPS_FALLBACK"] = env["PYTORCH_ENABLE_MPS_FALLBACK"] ?? "1"   // ops MPS lacks run on the CPU
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attr, argv, envp)
        guard rc == 0 else { throw CommandError(.io, "cannot start ComfyUI (\(executable.path)): \(String(cString: strerror(rc)))") }
        let record = Started(pid: pid, startedAt: startTime(pid) ?? 0, server: server.absoluteString)
        try JSONEncoder().encode(record).write(to: recordFile(config), options: .atomic)
        return pid
    }

    /// The last lines of the server's log.
    static func logTail(_ config: EngineConfig, lines: Int = 8) -> String {
        ((try? String(contentsOf: logFile(config), encoding: .utf8)) ?? "").split(separator: "\n").suffix(lines).joined(separator: "\n")
    }

    /// Makes sure a server answers: the running one, else the one Regista starts (waiting for `/system_stats`, the wait
    /// said in the job's line). Throws what to do when there is none, when it exits or does not answer in `timeout`.
    static func ensure(_ config: EngineConfig, places: [String], timeout: TimeInterval, cancellation: GenerationCancellation?) throws -> ComfyClient {
        let loc = locate(config, places: places)
        let client = ComfyClient(base: loc.server)
        if client.answers() { return client }
        guard let start = loc.start else { throw CommandError(.io, notRunning(loc)) }
        let pid = try spawn(start, server: loc.server, config: config)
        let began = Date()
        CommandJob.say("starting ComfyUI: waiting for it to answer at \(loc.server.absoluteString)")
        while Date().timeIntervalSince(began) < timeout {
            if cancellation?.isCancelled == true || CommandJob.current?.isCancelled == true {
                stop(config)
                throw CommandError(.io, "cancelled")
            }
            if client.answers(timeout: 1) { return client }
            if startTime(pid) == nil {
                _ = waitpid(pid, nil, WNOHANG)
                try? FileManager.default.removeItem(at: recordFile(config))
                throw CommandError(.io, "ComfyUI (\(start.path)) stopped before it answered at \(loc.server.absoluteString). Its last lines:\n\(logTail(config))")
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        stop(config)
        throw CommandError(.io, "ComfyUI (\(start.path)) did not answer at \(loc.server.absoluteString) within \(Int(timeout)) s, so Regista stopped it. Its last lines:\n\(logTail(config))")
    }

    /// The sentence when no server answers and Regista has nothing to start.
    static func notRunning(_ loc: Location) -> String {
        if let problem = loc.startProblem {
            return "ComfyUI does not answer at \(loc.server.absoluteString) and Regista cannot start it: \(problem). Fix the folder in Settings › Motori › ComfyUI. Steps:\n\(ComfyCheck.setupSteps)"
        }
        return "ComfyUI does not answer at \(loc.server.absoluteString) and Regista does not know where it is (no ComfyUI folder set, none in the usual places): start ComfyUI, or tell Regista its folder in Settings › Motori › ComfyUI. Steps:\n\(ComfyCheck.setupSteps)"
    }

    /// After a waited-for run: the server Regista started is stopped (its process group: SIGTERM, then SIGKILL after
    /// `grace` seconds) unless another prompt still runs or waits in it; a server someone else started gets `POST /free`.
    public static func finish(_ config: EngineConfig, grace: TimeInterval = 10) {
        let client = ComfyClient(base: address(config))
        guard let mine = started(config) else {
            if client.answers(timeout: 1) { client.free() }
            return
        }
        if let busy = ComfyClient(base: URL(string: mine.server) ?? address(config)).busy(), busy > 0 { return }   // another job's turn
        stop(config, grace: grace)
    }

    /// Stops the process group Regista started (nothing when there is none).
    public static func stop(_ config: EngineConfig, grace: TimeInterval = 10) {
        guard let mine = started(config) else { return }
        kill(-mine.pid, SIGTERM)
        let until = Date().addingTimeInterval(grace)
        while Date() < until {
            _ = waitpid(mine.pid, nil, WNOHANG)   // our own child: reap it (a zombie still answers kill 0)
            if kill(-mine.pid, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if kill(-mine.pid, 0) == 0 {
            kill(-mine.pid, SIGKILL)
            for _ in 0..<50 where kill(-mine.pid, 0) == 0 {
                _ = waitpid(mine.pid, nil, WNOHANG)
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        try? FileManager.default.removeItem(at: recordFile(config))
    }
}
