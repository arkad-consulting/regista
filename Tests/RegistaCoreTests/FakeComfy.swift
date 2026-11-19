import Foundation
@testable import RegistaCore

/// A stand-in ComfyUI server inside the test process (#6): a local listener on a free port that answers the endpoints
/// Regista calls, records every request, and finishes a queued prompt after `polls` looks at its history (never, with
/// `polls` nil). No model, no Python.
final class FakeComfy: @unchecked Sendable {
    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data
        var json: JSONValue? { try? JSONValue.parse(body) }
    }

    enum Reply {
        case ok
        /// `POST /prompt` refused with these node errors (400).
        case refuse(JSONValue)
        /// The prompt runs and fails: this execution error in its history.
        case fail(JSONValue)
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0
    private var _requests: [Request] = []
    private var prompts: [String: JSONValue] = [:]
    private var looks: [String: Int] = [:]
    private var _up = true
    var reply: Reply = .ok
    /// Looks at /history before a prompt is done (nil: never).
    var polls: Int? = 1
    /// The bytes /view returns.
    var output = Data("fake-output".utf8)

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    var requests: [Request] { lock.withLock { _requests } }
    /// false: every request gets 503 (a server that is not up yet).
    var up: Bool {
        get { lock.withLock { _up } }
        set { lock.withLock { _up = newValue } }
    }
    func requests(_ path: String) -> [Request] { requests.filter { $0.path == path } }
    var lastPrompt: JSONValue? { requests("/prompt").last?.json?["prompt"] }

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 16) == 0 else { throw CommandError(.io, "FakeComfy cannot listen") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                Thread.detachNewThread { self?.serve(c) }
            }
        }
    }

    deinit { close(fd) }
    func stop() { close(fd) }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var headerEnd: Range<Data.Index>?
        var length = 0
        while true {
            let n = read(c, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(contentsOf: buffer[0..<n])
            if headerEnd == nil, let r = data.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = r
                let head = String(decoding: data[..<r.lowerBound], as: UTF8.self)
                for line in head.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
                    length = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            if let h = headerEnd, data.count - h.upperBound >= length { break }
        }
        guard let h = headerEnd else { return }
        let head = String(decoding: data[..<h.lowerBound], as: UTF8.self)
        let first = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return }
        let target = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for q in target?.queryItems ?? [] { query[q.name] = q.value ?? "" }
        let request = Request(method: String(parts[0]), path: target?.path ?? "/", query: query, body: Data(data[h.upperBound...]))
        lock.withLock { _requests.append(request) }
        let (status, body) = respond(request)
        let header = "HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        let out = Data(header.utf8) + body
        out.withUnsafeBytes { _ = write(c, $0.baseAddress, out.count) }
    }

    private func respond(_ r: Request) -> (Int, Data) {
        guard up else { return (503, Data()) }
        func json(_ v: JSONValue, _ status: Int = 200) -> (Int, Data) { (status, v.data()) }
        switch (r.method, r.path) {
        case ("GET", "/system_stats"): return json(["system": ["os": "darwin"]])
        case ("GET", "/object_info"): return json([:])
        case ("POST", "/upload/image"):
            let text = String(decoding: r.body, as: UTF8.self)
            let name = text.range(of: #"filename="[^"]+""#, options: .regularExpression).map { String(text[$0].dropFirst(10).dropLast()) } ?? "?"
            return json(["name": .string(name), "subfolder": "regista", "type": "input"])
        case ("POST", "/prompt"):
            guard let body = r.json, let id = body["prompt_id"]?.stringValue, let prompt = body["prompt"] else { return json([:], 400) }
            if case .refuse(let errors) = reply { return json(["error": ["type": "prompt_outputs_failed_validation", "message": "Prompt outputs failed validation"], "node_errors": errors], 400) }
            lock.withLock { prompts[id] = prompt }
            return json(["prompt_id": .string(id), "number": 1, "node_errors": [:]])
        case ("GET", let p) where p.hasPrefix("/history/"):
            let id = String(p.dropFirst("/history/".count))
            let done: Bool = lock.withLock {
                looks[id, default: 0] += 1
                guard prompts[id] != nil, let polls else { return false }
                return looks[id]! >= polls
            }
            guard done else { return json([:]) }
            if case .fail(let error) = reply {
                return json([id: ["status": ["status_str": "error", "completed": false,
                                                                   "messages": [["execution_start", [:]], ["execution_error", error]]], "outputs": [:]]])
            }
            let prompt = lock.withLock { prompts[id] } ?? [:]
            // The save node is the one whose class starts with "Save": its files, as ComfyUI lists them.
            var outputs: [String: JSONValue] = [:]
            for (node, v) in prompt.objectValue ?? [:] where v["class_type"]?.stringValue?.hasPrefix("Save") == true {
                let ext = v["class_type"]?.stringValue == "SaveAudio" ? "flac" : v["class_type"]?.stringValue == "SaveVideo" ? "mp4" : "png"
                let key = ext == "flac" ? "audio" : "images"
                outputs[node] = .object([key: [["filename": .string("out_00001_.\(ext)"), "subfolder": "regista", "type": "output"]]])
            }
            return json([id: ["status": ["status_str": "success", "completed": true, "messages": []], "outputs": .object(outputs)]])
        case ("GET", "/view"): return (200, output)
        case ("GET", "/queue"): return json(["queue_running": [], "queue_pending": []])
        case ("POST", "/interrupt"), ("POST", "/queue"), ("POST", "/free"): return json([:])
        default: return json(["error": "unknown"], 404)
        }
    }
}
