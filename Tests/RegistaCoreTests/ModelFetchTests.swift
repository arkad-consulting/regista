import Foundation
import Testing
@testable import RegistaCore

// #121: a missing ComfyUI model file is downloaded by Regista into the ComfyUI folder it knows, checked against its
// sha256. Every download here comes from StandInFiles, a server in this process, into a scratch ComfyUI folder: no model
// file is fetched from anywhere, and the person's ComfyUI is never listed or written.

/// A scratch ComfyUI folder Regista knows as a folder (main.py, comfy/, its own .venv).
private func comfyFolder() throws -> URL {
    let f = tempDir().appendingPathComponent("ComfyUI", isDirectory: true)
    try FileManager.default.createDirectory(at: f.appendingPathComponent("comfy"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: f.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
    try Data().write(to: f.appendingPathComponent("main.py"))
    let py = f.appendingPathComponent(".venv/bin/python")
    try "#!/bin/sh\n".write(to: py, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
    return ComfyServer.canonical(f)
}

/// A small model file and its bytes (a manifest entry of the test's own).
private func tiny(_ name: String = "tiny_vae.safetensors", count: Int = 300_000) -> (EngineManifest.ModelFile, Data) {
    let bytes = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 131 &+ 7) })
    let f = EngineManifest.ModelFile(name: name, folder: "vae", bytes: Int64(count), sha256: sha(bytes), licence: "MIT",
                                     url: "https://example.invalid/page", download: "https://example.invalid/\(name)")
    return (f, bytes)
}

private func sha(_ d: Data) -> String {
    let f = tempDir().appendingPathComponent("x")
    try! d.write(to: f)
    return try! FileDigest.sha256(f)
}

private func location(_ folder: URL?) -> ComfyServer.Location {
    var c = EngineConfig()
    c.comfyServer = "http://127.0.0.1:9"
    c.comfyStart = folder?.path
    return ComfyServer.locate(c, places: [])
}

private func source(_ server: StandInFiles, free: Int64 = 1 << 50) -> ModelFetch.Source {
    ModelFetch.Source(url: { server.url($0.name) }, freeSpace: { _ in free })
}

@Test func aMissingFileIsDownloadedCheckedAndPutInItsComfyUIFolder() throws {
    let server = try StandInFiles()
    let (f, bytes) = tiny()
    server[f.name] = bytes
    let folder = try comfyFolder()
    let plan = ModelFetch.plan(f, location: location(folder), source: source(server))
    let target = folder.appendingPathComponent("models/vae/\(f.name)")
    #expect(plan == .ready(target: target, url: server.url(f.name)))
    let seen = LockedValue<[Int64]>([])
    try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server)) { got, total in
        #expect(total == f.bytes)
        seen.withLock { $0.append(got) }
    }
    #expect(FileManager.default.contents(atPath: target.path) == bytes)
    #expect(!FileManager.default.fileExists(atPath: target.path + ".part"), "the partial file was renamed into place")
    #expect(seen.withLock { $0.last } == f.bytes && seen.withLock { $0 == $0.sorted() }, "progress only grows, up to the size")
    #expect(server.requests.count == 1 && server.requests[0].range == nil)
    // There now, with the right size: never downloaded again.
    #expect(ModelFetch.plan(f, location: location(folder), source: source(server)) == .there(target: target))
    try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server))
    #expect(server.requests.count == 1, "a file already there is not fetched again")
}

@Test func aCancelledDownloadKeepsItsPartAndResumesWithARange() async throws {
    let server = try StandInFiles()
    let (f, bytes) = tiny()
    server[f.name] = bytes
    server.mode = .hold(after: 100_000)
    let target = try comfyFolder().appendingPathComponent("models/vae/\(f.name)")
    let part = URL(fileURLWithPath: target.path + ".part")
    let cancel = GenerationCancellation()
    let failure = LockedValue<FetchFailure?>(nil)
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        do { try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server), cancellation: cancel) }
        catch let e as FetchFailure { failure.withLock { $0 = e } } catch {}
        done.signal()
    }
    for _ in 0..<100 where (ModelFetch.fileSize(part) ?? 0) < 100_000 { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(ModelFetch.fileSize(part) == 100_000, "the first bytes are in the partial file")
    cancel.cancel()
    #expect(done.wait(timeout: .now() + 10) == .success, "the cancel stops the download")
    #expect(failure.withLock { $0?.kind } == .cancelled)
    #expect(ModelFetch.fileSize(part) == 100_000 && !FileManager.default.fileExists(atPath: target.path), "the part is kept, nothing in place")
    // Again: a Range request from where it stopped, then the whole file checked and in place.
    server.mode = .normal
    try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server))
    #expect(server.requests.last?.range == "bytes=100000-")
    #expect(FileManager.default.contents(atPath: target.path) == bytes && !FileManager.default.fileExists(atPath: part.path))
}

@Test func aDroppedConnectionKeepsThePartAndTheNextDownloadResumes() throws {
    let server = try StandInFiles()
    let (f, bytes) = tiny(count: 4_000_000)
    server[f.name] = bytes
    server.mode = .drop(after: 3_000_000)
    let target = try comfyFolder().appendingPathComponent("models/vae/\(f.name)")
    let part = URL(fileURLWithPath: target.path + ".part")
    var kept: Int64 = 0
    do {
        try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server), timeout: 5)
        Issue.record("a dropped connection ended as a download")
    } catch let e as FetchFailure {
        guard case .lost(let received, let total) = e.kind else { Issue.record("\(e)"); return }
        // What reached the file before the connection ended (the loader may hold back its last buffer) is kept.
        kept = received
        #expect(received > 1_000_000 && received <= 3_000_000 && total == f.bytes, "\(received)")
        #expect(ModelFetch.fileSize(part) == received)
        #expect(e.message.contains("download it again to resume"), "\(e.message)")
    }
    server.mode = .normal
    try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server))
    #expect(server.requests.count == 2 && server.requests.last?.range == "bytes=\(kept)-")
    #expect(FileManager.default.contents(atPath: target.path) == bytes && !FileManager.default.fileExists(atPath: part.path))
}

@Test func aWrongChecksumRemovesThePartialFileAndSaysWhatToDo() throws {
    let server = try StandInFiles()
    let (f, bytes) = tiny()
    var wrong = bytes
    wrong[1234] ^= 0xFF
    server[f.name] = wrong
    let target = try comfyFolder().appendingPathComponent("models/vae/\(f.name)")
    do {
        try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server))
        Issue.record("a file with the wrong checksum was put in place")
    } catch let e as FetchFailure {
        #expect(e.kind == .checksum)
        #expect(e.message.contains("does not match its checksum") && e.message.contains("Download it again"), "\(e.message)")
    }
    #expect(!FileManager.default.fileExists(atPath: target.path) && !FileManager.default.fileExists(atPath: target.path + ".part"))
}

@Test func notEnoughSpaceIsRefusedBeforeTheFirstByteSayingHowMuchIsMissing() throws {
    let server = try StandInFiles()
    let (f, bytes) = tiny()
    server[f.name] = bytes
    let target = try comfyFolder().appendingPathComponent("models/vae/\(f.name)")
    let free: Int64 = 1_000_000_000   // 1 GB free; the file plus the 2 GB margin need 2.0003 GB
    do {
        try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server, free: free))
        Issue.record("a download started without the room for it")
    } catch let e as FetchFailure {
        let need = f.bytes + ModelFetch.marginBytes
        #expect(e.kind == .space(missing: need - free))
        #expect(e.message.contains("free \(EngineManifest.sizeText(need - free)) more"), "\(e.message)")
    }
    #expect(server.requests.isEmpty, "no byte was asked for")
}

@Test func aFileOfAnotherSizeIsNeverOverwritten() throws {
    let server = try StandInFiles()
    let (f, bytes) = tiny()
    server[f.name] = bytes
    let folder = try comfyFolder()
    let target = folder.appendingPathComponent("models/vae/\(f.name)")
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("someone else's file".utf8).write(to: target)
    let plan = ModelFetch.plan(f, location: location(folder), source: source(server))
    #expect(plan == .otherSize(target: target, bytes: 19))
    #expect(ModelFetch.note(plan, f)?.contains("does not overwrite it") == true)
    #expect(throws: FetchFailure.self) { try ModelFetch.run(f, from: server.url(f.name), to: target, source: source(server)) }
    #expect(FileManager.default.contents(atPath: target.path) == Data("someone else's file".utf8) && server.requests.isEmpty)
}

@Test func onlyAFolderRegistaKnowsGetsTheFiles() throws {
    let (f, _) = tiny()
    // ComfyUI started by a program: Regista does not know the folder, so nothing is offered.
    var c = EngineConfig()
    c.comfyServer = "http://127.0.0.1:9"
    c.comfyStart = "/usr/bin/true"
    let executable = ComfyServer.locate(c, places: [])
    guard case .noFolder(let why) = ModelFetch.plan(f, location: executable) else { Issue.record("a start program got a folder"); return }
    #expect(why.contains("program") && why.contains("ComfyUI folder"), "\(why)")
    // Only an address.
    guard case .noFolder(let only) = ModelFetch.plan(f, location: location(nil)) else { Issue.record("an address got a folder"); return }
    #expect(only.contains("address") && only.contains("ComfyUI folder"), "\(only)")
    // A file with no direct URL keeps the manual step.
    let manual = EngineManifest.ModelFile(name: "gated.safetensors", folder: "vae", bytes: 10, sha256: nil, licence: "x", url: "https://example.invalid/page", download: nil)
    let plan = ModelFetch.plan(manual, location: location(try comfyFolder()), source: ModelFetch.Source())
    #expect(plan == .manual && ModelFetch.note(plan, manual)?.contains("login") == true)
}

// MARK: the commands

/// An engine whose ComfyUI is `folder` (nil: only an address) and whose downloads come from `server`.
private func fetchEngine(_ server: StandInFiles, folder: URL?, start: String? = nil, free: Int64 = 1 << 50) -> Engine {
    var s = FakeServices().make()
    s.config.comfyServer = "http://127.0.0.1:9"
    s.config.comfyStart = start ?? folder?.path
    s.generators = ["comfyui": ComfyUIProvider(config: s.config, places: [])]
    s.modelSource = source(server, free: free)
    return Engine(prober: FakeProber(), services: s)
}

@Test func generateFetchStartsAJobPerMissingFileAndGenerateStatusFollowsIt() throws {
    let server = try StandInFiles()
    let rife = try #require(EngineManifest.shared.modelFile("rife_v4.26.safetensors"))
    // The stand-in serves bytes of the right size whose checksum is not the publisher's: the job fails as it must.
    server[rife.name] = Data(count: Int(rife.bytes))
    let folder = try comfyFolder()
    let e = fetchEngine(server, folder: folder)
    // generate.check says per file whether it can be downloaded (ComfyUI off: the files are listed, not checked).
    let check = try e.execute("generate.check", params: ["model": "realesrgan-x4plus+rife-4.26"])
    let files = try #require(check.value(at: "models.0.files")?.arrayValue)
    #expect(files.count == 2 && files.allSatisfy { $0["download"] == "ready" && $0["present"] == nil }, "\(files)")
    #expect(files.first { $0["name"] == "rife_v4.26.safetensors" }?["target"]?.stringValue == folder.path + "/models/frame_interpolation/rife_v4.26.safetensors")
    let r = try e.execute("generate.fetch", params: ["file": "rife_v4.26.safetensors"])
    let job = try #require(r["jobs"]?.arrayValue?.first)
    let id = try #require(job["jobId"]?.stringValue)
    #expect(job["file"] == "rife_v4.26.safetensors" && job["bytes"] == .number(Double(rife.bytes)))
    // generate.status follows it, without a project open.
    let end = try #require(ModelDownloads.shared.wait(id))
    #expect(end.state == .failed && end.failure?.kind == .checksum)
    let status = try e.execute("generate.status", params: ["jobId": .string(id)])
    #expect(status["status"] == "failed" && status["error"]?.stringValue?.contains("does not match its checksum") == true, "\(status)")
    #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("models/frame_interpolation/rife_v4.26.safetensors.part").path))
    #expect(server.requests.map(\.path) == ["/rife_v4.26.safetensors"])
}

/// A download is stopped from a command too (generate.status {jobId, cancel: true}): it answers cancelled, the partial file
/// stays, and the next generate.fetch of that file resumes it with a Range request.
@Test func generateStatusCancelsADownloadAndTheNextFetchResumesIt() async throws {
    let server = try StandInFiles()
    let rife = try #require(EngineManifest.shared.modelFile("rife_v4.26.safetensors"))
    server[rife.name] = Data(count: Int(rife.bytes))
    server.mode = .hold(after: 100_000)
    let folder = try comfyFolder()
    let part = folder.appendingPathComponent("models/frame_interpolation/\(rife.name).part")
    let e = fetchEngine(server, folder: folder)
    let r = try e.execute("generate.fetch", params: ["file": .string(rife.name)])
    let id = try #require(r.value(at: "jobs.0.jobId")?.stringValue)
    for _ in 0..<200 where (ModelFetch.fileSize(part) ?? 0) < 100_000 { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(ModelFetch.fileSize(part) == 100_000 && ModelDownloads.shared.job(id)?.state == .running)
    // cancel needs a download's id.
    #expect(throws: CommandError.self) { try e.execute("generate.status", params: ["cancel": true]) }
    #expect(throws: CommandError.self) { try e.execute("generate.status", params: ["jobId": "g1", "cancel": true]) }
    let stopped = try e.execute("generate.status", params: ["jobId": .string(id), "cancel": true])
    #expect(stopped["status"] == "cancelled" && stopped["received"] == 100_000, "\(stopped)")
    #expect(ModelFetch.fileSize(part) == 100_000, "the partial file stays")
    // The next generate.fetch of the file starts where the part ends.
    server.mode = .normal
    let again = try e.execute("generate.fetch", params: ["file": .string(rife.name)])
    let next = try #require(again.value(at: "jobs.0.jobId")?.stringValue)
    #expect(next != id)
    _ = ModelDownloads.shared.wait(next)
    #expect(server.requests.last?.range == "bytes=100000-")
}

@Test func generateFetchRefusesWhatItCannotDo() throws {
    let server = try StandInFiles()
    // The executable form: no folder, no download, and the error says what to set.
    let start = tempDir().appendingPathComponent("start.sh")
    try "#!/bin/sh\n".write(to: start, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: start.path)
    let exe = fetchEngine(server, folder: nil, start: start.path)
    #expect { try exe.execute("generate.fetch", params: ["model": "z-image-turbo"]) } throws: { e in
        (e as? CommandError)?.message.contains("Settings › Motori › ComfyUI") == true
    }
    let checked = try exe.execute("generate.check", params: ["model": "z-image-turbo"])
    #expect(checked.value(at: "models.0.files")?.arrayValue?.allSatisfy { $0["download"] == "noFolder" } == true)
    // Not enough room for the three Z-Image files: refused at once, with how much is missing.
    let folder = try comfyFolder()
    let small = fetchEngine(server, folder: folder, free: 5_000_000_000)
    #expect { try small.execute("generate.fetch", params: ["model": "z-image-turbo"]) } throws: { e in
        let m = (e as? CommandError)?.message ?? ""
        return m.contains("not enough free space") && m.contains("more, then download again") && m.contains("Nothing was downloaded")
    }
    #expect(server.requests.isEmpty)
    // A file already there with the right size (a sparse file of its size) is not downloaded again; one of another size
    // is not overwritten.
    let ae = try #require(EngineManifest.shared.modelFile("ae.safetensors"))
    let vae = folder.appendingPathComponent("models/vae", isDirectory: true)
    try FileManager.default.createDirectory(at: vae, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: vae.appendingPathComponent(ae.name).path, contents: nil)
    let h = try FileHandle(forWritingTo: vae.appendingPathComponent(ae.name))
    try h.truncate(atOffset: UInt64(ae.bytes))
    try h.close()
    let e = fetchEngine(server, folder: folder)
    let there = try e.execute("generate.fetch", params: ["file": "ae.safetensors"])
    #expect(there["jobs"]?.arrayValue?.isEmpty == true && there.value(at: "skipped.0.download") == "there", "\(there)")
    try Data("other".utf8).write(to: folder.appendingPathComponent("models/text_encoders/qwen_3_4b.safetensors").creatingParent())
    #expect { try e.execute("generate.fetch", params: ["file": "qwen_3_4b.safetensors"]) } throws: { e in
        (e as? CommandError)?.message.contains("does not overwrite it") == true
    }
    #expect(server.requests.isEmpty, "nothing was fetched")
}

private extension URL {
    func creatingParent() throws -> URL {
        try FileManager.default.createDirectory(at: deletingLastPathComponent(), withIntermediateDirectories: true)
        return self
    }
}

// MARK: the manifest's direct URLs

@Test func everyModelFileHasADirectURLPinnedToARevision() throws {
    let files = EngineManifest.shared.entries.flatMap(\.modelFiles)
    #expect(files.count == 16)
    for f in files {
        let d = try #require(f.download, "\(f.name): no direct URL")
        let hf = try NSRegularExpression(pattern: #"^https://huggingface\.co/[^/]+/[^/]+/resolve/[0-9a-f]{40}/.+$"#)
        let gh = try NSRegularExpression(pattern: #"^https://github\.com/[^/]+/[^/]+/releases/download/v[0-9][^/]*/[^/]+$"#)
        let pinned = [hf, gh].contains { $0.firstMatch(in: d, range: NSRange(d.startIndex..., in: d)) != nil }
        #expect(pinned, "\(f.name): \(d) is not pinned to a commit or a release tag")
        #expect(d.hasSuffix("/" + f.name), "\(f.name): \(d)")
    }
}
