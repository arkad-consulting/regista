import Foundation

/// ComfyUI's own HTTP API (#6), called directly: no Python of ours, no outside script. Synchronous (the generation runs on
/// a thread of its own); every call has a timeout and throws a `CommandError` with what the server said.
public struct ComfyClient: Sendable {
    public let base: URL

    public init(base: URL) { self.base = base }

    /// A reply: the HTTP status and the body.
    struct Reply {
        var status: Int
        var data: Data
        var json: JSONValue? { try? JSONValue.parse(data) }
        var text: String { String(decoding: data.prefix(2000), as: UTF8.self) }
    }

    /// One request; nil when nothing answers (connection refused, timeout).
    func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
              contentType: String? = nil, timeout: TimeInterval = 30) -> Reply? {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        final class Box: @unchecked Sendable { var reply: Reply? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse { box.reply = Reply(status: http.statusCode, data: data ?? Data()) }
            done.signal()
        }
        task.resume()
        if done.wait(timeout: .now() + timeout + 1) == .timedOut { task.cancel(); return nil }
        return box.reply
    }

    func json(_ path: String, method: String = "GET", body: JSONValue? = nil, timeout: TimeInterval = 30) throws -> JSONValue {
        let data = body?.data()
        guard let r = send(path, method: method, body: data, contentType: data == nil ? nil : "application/json", timeout: timeout) else {
            throw CommandError(.io, "ComfyUI does not answer at \(base.absoluteString) (\(method) /\(path))")
        }
        guard r.status == 200 else { throw CommandError(.io, "ComfyUI answered \(r.status) to \(method) /\(path): \(r.text)") }
        guard let v = r.json else { throw CommandError(.io, "ComfyUI's reply to \(method) /\(path) is not JSON") }
        return v
    }

    // MARK: the endpoints

    /// `GET /system_stats`: whether the server answers, within `timeout` seconds.
    public func answers(timeout: TimeInterval = 2) -> Bool { send("system_stats", timeout: timeout)?.status == 200 }

    /// `GET /object_info`: every node class the server has, nil when it does not answer.
    public func objectInfo(timeout: TimeInterval = 10) -> Data? {
        guard let r = send("object_info", timeout: timeout), r.status == 200 else { return nil }
        return r.data
    }

    /// `POST /upload/image` (ComfyUI's upload for any input file: the start image, the clip to upscale) into
    /// `subfolder` of its input folder. Returns the value a LoadImage / LoadVideo input takes (`subfolder/name`).
    public func upload(_ file: URL, as name: String, subfolder: String) throws -> String {
        guard let content = FileManager.default.contents(atPath: file.path) else { throw CommandError(.io, "cannot read \(file.path)") }
        let boundary = "regista-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("subfolder", subfolder)
        field("overwrite", "true")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(content)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard let r = send("upload/image", method: "POST", body: body, contentType: "multipart/form-data; boundary=\(boundary)", timeout: 120) else {
            throw CommandError(.io, "ComfyUI does not answer at \(base.absoluteString) (upload of \(file.lastPathComponent))")
        }
        guard r.status == 200, let saved = r.json?["name"]?.stringValue else {
            throw CommandError(.io, "ComfyUI refused the upload of \(file.lastPathComponent) (\(r.status)): \(r.text)")
        }
        let folder = r.json?["subfolder"]?.stringValue ?? subfolder
        return folder.isEmpty ? saved : "\(folder)/\(saved)"
    }

    /// `POST /prompt` with our own prompt id (so a cancel can name it before the reply). A workflow ComfyUI refuses
    /// (`node_errors`) throws a sentence naming the node, the input and the value (`ComfyErrors.refusal`).
    public func queue(_ workflow: JSONValue, promptID: String) throws {
        let body: JSONValue = ["prompt": workflow, "prompt_id": .string(promptID), "client_id": .string("regista")]
        guard let r = send("prompt", method: "POST", body: body.data(), contentType: "application/json", timeout: 60) else {
            throw CommandError(.io, "ComfyUI does not answer at \(base.absoluteString) (POST /prompt)")
        }
        guard r.status == 200 else {
            throw CommandError(.io, r.json.map { ComfyErrors.refusal($0, workflow: workflow) } ?? "ComfyUI refused the workflow (\(r.status)): \(r.text)")
        }
    }

    /// `GET /history/<id>`: the finished prompt's entry, nil while it is queued or running.
    public func history(_ promptID: String) throws -> JSONValue? {
        let h = try json("history/\(promptID)", timeout: 15)
        return h[promptID]
    }

    /// `GET /view` of an output file, written to `destination`.
    public func download(filename: String, subfolder: String, type: String, to destination: URL) throws {
        let query = [URLQueryItem(name: "filename", value: filename), URLQueryItem(name: "subfolder", value: subfolder),
                     URLQueryItem(name: "type", value: type)]
        guard let r = send("view", query: query, timeout: 300) else { throw CommandError(.io, "ComfyUI does not answer at \(base.absoluteString) (GET /view)") }
        guard r.status == 200 else { throw CommandError(.io, "ComfyUI cannot give \(filename) (\(r.status))") }
        try r.data.write(to: destination, options: .atomic)
    }

    /// `POST /interrupt` of this prompt when it runs, and `POST /queue` delete when it still waits.
    public func cancel(_ promptID: String) {
        _ = send("interrupt", method: "POST", body: JSONValue.object(["prompt_id": .string(promptID)]).data(), contentType: "application/json", timeout: 5)
        _ = send("queue", method: "POST", body: JSONValue.object(["delete": [.string(promptID)]]).data(), contentType: "application/json", timeout: 5)
    }

    /// `GET /queue`: how many prompts run or wait (nil when it does not answer).
    public func busy() -> Int? {
        guard let q = try? json("queue", timeout: 5) else { return nil }
        return (q["queue_running"]?.arrayValue?.count ?? 0) + (q["queue_pending"]?.arrayValue?.count ?? 0)
    }

    /// `POST /free`: unload the models and free the memory (a server someone else started keeps running).
    public func free() {
        _ = send("free", method: "POST", body: JSONValue.object(["unload_models": true, "free_memory": true]).data(), contentType: "application/json", timeout: 5)
    }
}

/// ComfyUI's errors in words a person can act on: which node, which model file or value, and the fix generate.check
/// words for the same case.
public enum ComfyErrors {
    /// A `POST /prompt` refusal: `{"error": {...}, "node_errors": {"<id>": {"class_type", "errors": [{"type", "message",
    /// "details", "extra_info": {"input_name", "received_value"}}]}}}`.
    public static func refusal(_ reply: JSONValue, workflow: JSONValue) -> String {
        var lines: [String] = []
        let nodes = reply["node_errors"]?.objectValue ?? [:]
        for id in nodes.keys.sorted(by: { $0.compare($1, options: .numeric) == .orderedAscending }) {
            let n = nodes[id]!
            let cls = n["class_type"]?.stringValue ?? workflow[id]?["class_type"]?.stringValue ?? "?"
            for e in n["errors"]?.arrayValue ?? [] {
                let input = e.value(at: "extra_info.input_name")?.stringValue
                let value = e.value(at: "extra_info.received_value").map { $0.stringValue ?? $0.text() }
                lines.append(sentence(node: id, cls: cls, type: e["type"]?.stringValue ?? "", message: e["message"]?.stringValue ?? "",
                                      details: e["details"]?.stringValue ?? "", input: input, value: value))
            }
        }
        if lines.isEmpty, let e = reply["error"] {
            let type = e["type"]?.stringValue ?? ""
            if type == "missing_node_type" || (e["message"]?.stringValue ?? "").contains("not found") {
                let cls = e.value(at: "extra_info.class_type")?.stringValue ?? e["details"]?.stringValue ?? "?"
                lines.append(ComfyCheck.nodeHint(cls))
            } else {
                lines.append("ComfyUI refused the workflow: \(e["message"]?.stringValue ?? type) \(e["details"]?.stringValue ?? "")".trimmingCharacters(in: .whitespaces))
            }
        }
        return "ComfyUI refused the workflow:\n" + lines.map { "- \($0)" }.joined(separator: "\n")
    }

    static func sentence(node: String, cls: String, type: String, message: String, details: String, input: String?, value: String?) -> String {
        if type == "value_not_in_list", let input, let value {
            let isModel = ComfyCheck.folders[cls] != nil || cls.contains("Loader")
            if isModel { return "node \(node) (\(cls)): " + ComfyCheck.modelHint(cls: cls, value: value) }
            return "node \(node) (\(cls)): " + ComfyCheck.valueHint(cls: cls, input: input, value: value)
        }
        let what = [message, details].filter { !$0.isEmpty }.joined(separator: ": ")
        return "node \(node) (\(cls))\(input.map { ", input \($0)" } ?? ""): \(what.isEmpty ? type : what)"
    }

    /// An execution error in `/history` (`status.messages` holds `["execution_error", {node_id, node_type,
    /// exception_message, …}]`).
    public static func execution(_ entry: JSONValue) -> String {
        let messages = entry.value(at: "status.messages")?.arrayValue ?? []
        let errors = messages.compactMap { m -> JSONValue? in
            guard let a = m.arrayValue, a.first?.stringValue == "execution_error", a.count > 1 else { return nil }
            return a[1]
        }
        guard let e = errors.first else {
            let interrupted = messages.contains { $0.arrayValue?.first?.stringValue == "execution_interrupted" }
            return interrupted ? "ComfyUI stopped the workflow (interrupted)" : "ComfyUI did not finish the workflow (\(entry.value(at: "status.status_str")?.stringValue ?? "no status"))"
        }
        let node = e["node_id"]?.stringValue ?? "?", cls = e["node_type"]?.stringValue ?? "?"
        let text = (e["exception_message"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let fix: String
        if lower.contains("out of memory") || lower.contains("mps backend out of memory") || lower.contains("not enough memory") {
            fix = "ComfyUI ran out of memory: close other heavy apps, or ask for a smaller size or a shorter clip, then run it again"
        } else if lower.contains("no such file") || lower.contains("not found") {
            fix = "a file the workflow needs is missing: run generate.check, which names it and the folder it goes in"
        } else {
            fix = "see ComfyUI's own log for the details; generate.check names a missing node pack or model file"
        }
        return "ComfyUI failed in node \(node) (\(cls)): \(text.isEmpty ? e["exception_type"]?.stringValue ?? "error" : String(text.prefix(400))) — \(fix)"
    }
}
