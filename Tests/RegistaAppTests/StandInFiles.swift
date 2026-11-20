import Foundation

/// A stand-in file server in the test process (#121): a local listener that serves `GET /<name>` from `files`, honours
/// `Range: bytes=N-` with a 206, and can misbehave on purpose — drop the connection after some bytes, or hold the rest
/// until `release()`. Every request is written down (path and Range header). Nothing leaves the machine.
final class StandInFiles: @unchecked Sendable {
    struct Request: Sendable {
        var path: String
        var range: String?
    }

    enum Mode: Sendable {
        case normal
        /// Sends this many bytes of the answer's body, then closes the connection (a lost connection).
        case drop(after: Int)
        /// Sends this many bytes of the answer's body, then waits for `release()` (or the client giving up).
        case hold(after: Int)
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    private(set) var port: UInt16 = 0
    private var _requests: [Request] = []
    private var _files: [String: Data] = [:]
    private var _mode: Mode = .normal
    private var released = false

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }
    func url(_ name: String) -> URL { base.appendingPathComponent(name) }
    var requests: [Request] { lock.withLock { _requests } }
    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue; released = false } }
    }
    subscript(name: String) -> Data? {
        get { lock.withLock { _files[name] } }
        set { lock.withLock { _files[name] = newValue } }
    }
    func release() { lock.withLock { released = true } }

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
        guard bound == 0, listen(fd, 16) == 0 else { throw NSError(domain: "StandInFiles", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot listen"]) }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        let listener = fd
        Thread.detachNewThread { [weak self] in
            while true {
                let c = accept(listener, nil, nil)
                if c < 0 { return }
                var on: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { self?.serve(c) }
            }
        }
    }

    deinit { close(fd) }
    func stop() { close(fd) }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while data.range(of: Data("\r\n\r\n".utf8)) == nil {
            let n = read(c, &buffer, buffer.count)
            if n <= 0 { return }
            data.append(contentsOf: buffer[0..<n])
        }
        let head = String(decoding: data, as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return }
        let path = String(parts[1])
        let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        let (body, mode): (Data?, Mode) = lock.withLock {
            _requests.append(Request(path: path, range: range))
            return (_files[String(path.dropFirst())], _mode)
        }
        guard let body else {
            send(c, Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        var from = 0
        if let r = range, r.hasPrefix("bytes="), let n = Int(r.dropFirst(6).split(separator: "-").first ?? "") { from = min(n, body.count) }
        let slice = body.subdata(in: from..<body.count)
        let status = from > 0 ? "206 Partial Content" : "200 OK"
        var header = "HTTP/1.1 \(status)\r\nContent-Type: application/octet-stream\r\nContent-Length: \(slice.count)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n"
        if from > 0 { header += "Content-Range: bytes \(from)-\(body.count - 1)/\(body.count)\r\n" }
        guard send(c, Data((header + "\r\n").utf8)) else { return }
        switch mode {
        case .normal:
            send(c, slice)
        case .drop(let after):
            // The bytes reach the client, then the connection ends early (an orderly close, as a lost route looks).
            send(c, slice.prefix(after))
            shutdown(c, SHUT_WR)
            Thread.sleep(forTimeInterval: 0.3)
        case .hold(let after):
            guard send(c, slice.prefix(after)) else { return }
            while !lock.withLock({ released }) {
                // The client gone: a write of nothing does not tell, so look whether the socket was closed.
                var probe: UInt8 = 0
                let n = recv(c, &probe, 1, MSG_PEEK | MSG_DONTWAIT)
                if n == 0 { return }
                Thread.sleep(forTimeInterval: 0.05)
            }
            send(c, slice.dropFirst(after))
        }
    }

    @discardableResult
    private func send(_ c: Int32, _ data: Data) -> Bool {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { write(c, $0.baseAddress! + sent, data.count - sent) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }
}
