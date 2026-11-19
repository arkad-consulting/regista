import Foundation
import Testing
@testable import RegistaCore

// #6: Regista calls ComfyUI's own HTTP API. Every test talks to FakeComfy, a stand-in server in this process: no model,
// no Python, no outside runner.

/// An engine whose ComfyUI provider talks to `fake` (no folder looked for, a quick poll).
private func comfyEngine(_ fake: FakeComfy, start: String? = nil, cache: URL = tempDir()) throws -> (Engine, EngineConfig) {
    var config = EngineConfig()
    config.cacheDirectory = cache.path
    config.comfyServer = fake.base.absoluteString
    config.comfyStart = start
    var provider = ComfyUIProvider(config: config, places: [])
    provider.poll = 0.05
    provider.startTimeout = 20
    var s = FakeServices().make()
    s.config = config
    s.generators = ["comfyui": provider]
    s.generationState = tempDir()
    let e = Engine(prober: FakeProber(), services: s)
    try e.execute("project.new", params: ["name": "c", "directory": .string(tempDir().path)])
    return (e, config)
}

private func png(_ name: String = "start.png") throws -> URL {
    let f = tempDir().appendingPathComponent(name)
    try Data("png-bytes".utf8).write(to: f)
    return f
}

@Test func aStillPutsThePromptSizeAndSeedInTheirNodesAndFetchesTheFile() throws {
    let fake = try FakeComfy()
    let (e, _) = try comfyEngine(fake)
    let r = try e.execute("generate.run", params: ["kind": "image", "prompt": "a calm desk", "size": [464, 832], "seed": 7])
    let prompt = try #require(fake.lastPrompt)
    #expect(prompt.value(at: "5.inputs.text") == "a calm desk")
    #expect(prompt.value(at: "7.inputs.width") == 464 && prompt.value(at: "7.inputs.height") == 832)
    #expect(prompt.value(at: "8.inputs.seed") == 7)
    #expect(prompt.value(at: "10.inputs.filename_prefix") == "regista/still")
    #expect(r["model"] == "z-image-turbo" && r["seed"] == 7)
    let view = try #require(fake.requests("/view").first)
    #expect(view.query["filename"] == "out_00001_.png" && view.query["subfolder"] == "regista" && view.query["type"] == "output")
    let path = try #require(r["path"]?.stringValue)
    #expect(FileManager.default.contents(atPath: path) == fake.output, "the fetched file is the asset")
    #expect(fake.requests("/history/" + (fake.requests("/prompt").last?.json?["prompt_id"]?.stringValue ?? "")).count >= 1, "polled")
    // A server someone else runs keeps running: only its memory is freed after the waited-for run.
    #expect(fake.requests("/free").count == 1)
}

/// The cache folder spelled through /private (as /private/tmp is): the fetched file is the result, not removed as a copy of
/// itself (found by the proof run on a real ComfyUI).
@Test func aResultInACacheSpelledThroughPrivateIsKept() throws {
    let fake = try FakeComfy()
    let real = URL(fileURLWithPath: "/private" + tempDir().path)
    #expect(real.path.hasPrefix("/private/"))
    let (e, _) = try comfyEngine(fake, cache: real)
    let r = try e.execute("generate.run", params: ["kind": "image", "prompt": "kept", "seed": 1])
    #expect(FileManager.default.contents(atPath: try #require(r["path"]?.stringValue)) == fake.output)
}

@Test func aClipUploadsItsStartImageAndAsksForTheFramesOfItsSeconds() throws {
    let fake = try FakeComfy()
    let (e, _) = try comfyEngine(fake)
    let start = try png()
    try e.execute("generate.run", params: ["kind": "video", "prompt": "slow push", "refs": [.string(start.path)], "duration": 1, "seed": 3])
    let upload = try #require(fake.requests("/upload/image").first)
    let form = String(decoding: upload.body, as: UTF8.self)
    #expect(form.contains("name=\"subfolder\"\r\n\r\nregista") && form.contains("png-bytes"))
    let name = "\(try FileDigest.sha256(start).prefix(16)).png"
    let prompt = try #require(fake.lastPrompt)
    #expect(prompt.value(at: "11.inputs.image")?.stringValue == "regista/\(name)")
    #expect(prompt.value(at: "12.inputs.length") == 17 && prompt.value(at: "12.inputs.width") == 464 && prompt.value(at: "12.inputs.height") == 832)
    #expect(prompt.value(at: "13.inputs.noise_seed") == 3 && prompt.value(at: "9.inputs.text") == "slow push")
}

@Test func musicAndUpscaleFillTheirOwnNodes() throws {
    let fake = try FakeComfy()
    let (e, _) = try comfyEngine(fake)
    try e.execute("generate.run", params: ["kind": "music", "prompt": "warm lofi", "duration": 10, "seed": 5, "options": ["bpm": "90"]])
    let music = try #require(fake.lastPrompt)
    #expect(music.value(at: "PROMPT.inputs.tags") == "warm lofi" && music.value(at: "PROMPT.inputs.bpm") == 90)
    #expect(music.value(at: "PROMPT.inputs.duration") == 10 && music.value(at: "LATENT.inputs.seconds") == 10)
    #expect(music.value(at: "PROMPT.inputs.seed") == 5 && music.value(at: "SAMPLER.inputs.seed") == 5)
    #expect(e.project?.assets.last?.generated?.model == "ace-step-1.5-turbo")

    // The upscale reads the clip it uploads (LoadVideo), through the real generate.upscale on an imported clip.
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    let clip = try #require(e.project?.assets.first { $0.video != nil && $0.generated == nil })
    try e.execute("generate.upscale", params: ["assetId": .string(clip.id)])
    let up = try #require(fake.lastPrompt)
    #expect(up.value(at: "1.inputs.file")?.stringValue?.hasPrefix("regista/") == true)
    #expect(up.value(at: "12.inputs.filename_prefix") == "regista/upscale")
}

@Test func aRefusedWorkflowAndAFailedRunAreSentencesAPersonCanActOn() throws {
    let fake = try FakeComfy()
    fake.reply = .refuse(["3": ["class_type": "VAELoader", "errors": [["type": "value_not_in_list", "message": "Value not in list",
                                                                        "details": "vae_name: 'ae.safetensors' not in []",
                                                                        "extra_info": ["input_name": "vae_name", "received_value": "ae.safetensors"]]]]])
    let (e, _) = try comfyEngine(fake)
    do {
        try e.execute("generate.run", params: ["kind": "image", "prompt": "x"])
        Issue.record("a refused workflow ran")
    } catch let error as CommandError {
        #expect(error.message.contains("node 3 (VAELoader)") && error.message.contains("ae.safetensors") && error.message.contains("models/vae"), "\(error.message)")
    }
    fake.reply = .fail(["node_id": "8", "node_type": "KSampler", "exception_message": "MPS backend out of memory", "exception_type": "RuntimeError"])
    do {
        try e.execute("generate.run", params: ["kind": "image", "prompt": "y"])
        Issue.record("a failed run gave a result")
    } catch let error as CommandError {
        #expect(error.message.contains("node 8 (KSampler)") && error.message.contains("out of memory") && error.message.contains("smaller size"), "\(error.message)")
    }
    #expect(e.project?.assets.isEmpty == true)
}

@Test func aCancelReachesInterruptAndTheRunFailsCancelled() throws {
    let fake = try FakeComfy()
    fake.polls = nil   // never finishes
    let (e, _) = try comfyEngine(fake)
    let job = CommandJob()
    Thread.detachNewThread {
        for _ in 0..<400 where fake.requests("/prompt").isEmpty { Thread.sleep(forTimeInterval: 0.05) }
        Thread.sleep(forTimeInterval: 0.2)
        job.cancel()
    }
    do {
        try CommandJob.$current.withValue(job) { _ = try e.execute("generate.run", params: ["kind": "image", "prompt": "never"]) }
        Issue.record("not cancelled")
    } catch let error as CommandError {
        #expect(error.message.contains("cancelled"))
    }
    let id = try #require(fake.requests("/prompt").first?.json?["prompt_id"]?.stringValue)
    #expect(fake.requests("/interrupt").first?.json?["prompt_id"]?.stringValue == id)
    #expect(fake.requests("/queue").contains { $0.method == "POST" && $0.json?["delete"] == [.string(id)] })
}

/// A start script standing in for ComfyUI: it records its pid, starts a child (the server's own workers) and waits.
private func standInStart(_ dir: URL) throws -> URL {
    let script = dir.appendingPathComponent("start-comfy")
    try "#!/bin/sh\necho $$ > \"\(dir.path)/server.pid\"\nsleep 300 &\necho $! > \"\(dir.path)/child.pid\"\nwait\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
}

private func pid(_ file: URL) -> Int32? {
    (try? String(contentsOf: file, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
}

@Test func aServerRegistaStartedIsStoppedAfterTheRunWithEverythingItStarted() throws {
    let fake = try FakeComfy()
    fake.up = false
    let dir = tempDir()
    let (e, config) = try comfyEngine(fake, start: try standInStart(dir).path)
    // The stand-in "answers" once its script runs.
    Thread.detachNewThread {
        for _ in 0..<400 where pid(dir.appendingPathComponent("child.pid")) == nil { Thread.sleep(forTimeInterval: 0.05) }
        fake.up = true
    }
    let said = LockedValue<[String]>([])
    let job = CommandJob(estimates: { _, detail, _ in if let detail { said.withLock { $0.append(detail) } } })
    try CommandJob.$current.withValue(job) { _ = try e.execute("generate.run", params: ["kind": "image", "prompt": "started"]) }
    #expect(said.withLock { $0 }.contains { $0.contains("starting ComfyUI: waiting for it to answer at \(fake.base.absoluteString)") })
    let server = try #require(pid(dir.appendingPathComponent("server.pid")))
    let child = try #require(pid(dir.appendingPathComponent("child.pid")))
    #expect(kill(server, 0) != 0 && kill(child, 0) != 0, "the script and its child are stopped")
    #expect(ComfyServer.started(config) == nil && fake.requests("/free").isEmpty, "stopped, not freed")

    // keepRunning: the next job finds it running; the run after it without keepRunning stops it.
    try FileManager.default.removeItem(at: dir.appendingPathComponent("child.pid"))
    fake.up = false
    Thread.detachNewThread {
        for _ in 0..<400 where pid(dir.appendingPathComponent("child.pid")) == nil { Thread.sleep(forTimeInterval: 0.05) }
        fake.up = true
    }
    try e.execute("generate.run", params: ["kind": "image", "prompt": "kept", "keepRunning": true])
    let kept = try #require(ComfyServer.started(config))
    #expect(kill(kept.pid, 0) == 0)
    try e.execute("generate.run", params: ["kind": "image", "prompt": "then stopped"])
    #expect(kill(kept.pid, 0) != 0 && ComfyServer.started(config) == nil)
}

/// #123: a server Regista started and kept up (keepRunning) is stopped when the next run, without keepRunning, is refused
/// by Regista's own check before anything is queued; a refused run with keepRunning leaves it up. Found on a real ComfyUI
/// (a folder that sees none of the model files): the server stayed up after the refusal until it was stopped by hand.
@Test func aServerRegistaStartedIsStoppedWhenTheNextRunIsRefusedByItsCheck() throws {
    let fake = try FakeComfy()
    fake.up = false
    let dir = tempDir()
    var config = EngineConfig()
    config.cacheDirectory = tempDir().path
    config.comfyServer = fake.base.absoluteString
    config.comfyStart = try standInStart(dir).path
    var provider = ComfyUIProvider(config: config, places: [])
    provider.poll = 0.05
    provider.startTimeout = 20
    // The node list Regista's check reads: none while the server is off, then one that lacks every node of the workflow.
    let nodes = LockedValue<Data?>(nil)
    var s = FakeServices().make()
    s.config = config
    s.generators = ["comfyui": provider]
    s.generationState = tempDir()
    s.comfyServer = { nodes.withLock { $0 } }
    let e = Engine(prober: FakeProber(), services: s)
    try e.execute("project.new", params: ["name": "c", "directory": .string(tempDir().path)])
    Thread.detachNewThread {
        for _ in 0..<400 where pid(dir.appendingPathComponent("child.pid")) == nil { Thread.sleep(forTimeInterval: 0.05) }
        fake.up = true
    }
    try e.execute("generate.run", params: ["kind": "image", "prompt": "kept", "keepRunning": true])
    let kept = try #require(ComfyServer.started(config), "the stand-in was not started")
    nodes.withLock { $0 = Data("{}".utf8) }
    let prompts = fake.requests("/prompt").count
    #expect(throws: CommandError.self) { try e.execute("generate.run", params: ["kind": "image", "prompt": "refused, kept", "keepRunning": true]) }
    #expect(kill(kept.pid, 0) == 0 && ComfyServer.started(config) != nil, "a refused run with keepRunning stopped the server")
    #expect(throws: CommandError.self) { try e.execute("generate.run", params: ["kind": "image", "prompt": "refused"]) }
    #expect(fake.requests("/prompt").count == prompts, "a refused run queued something")
    #expect(kill(kept.pid, 0) != 0 && ComfyServer.started(config) == nil, "the refused run left the server Regista started running")
}

@Test func whereComfyUIIsFoldersExecutablesAndTheUsualPlaces() throws {
    let home = tempDir()
    let comfy = home.appendingPathComponent("code/comfyui")
    try FileManager.default.createDirectory(at: comfy.appendingPathComponent("comfy"), withIntermediateDirectories: true)
    try Data().write(to: comfy.appendingPathComponent("main.py"))
    var config = EngineConfig()
    config.comfyServer = "http://127.0.0.1:9"
    // No Python environment: not a place Regista can start; set by hand, it says why.
    #expect(ComfyServer.locate(config, places: [home.appendingPathComponent("code/ComfyUI").path]).start == nil)
    config.comfyStart = comfy.path
    #expect(ComfyServer.locate(config, places: []).startProblem?.contains("no Python environment") == true)
    try FileManager.default.createDirectory(at: comfy.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
    let py = comfy.appendingPathComponent(".venv/bin/python")
    try "#!/bin/sh\n".write(to: py, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
    #expect(ComfyServer.locate(config, places: []).start?.path == comfy.path)
    // Not set: found in the usual places, whatever the case of the folder's name, and said as it is on disk.
    config.comfyStart = nil
    let found = ComfyServer.locate(config, places: [home.appendingPathComponent("ComfyUI").path, home.appendingPathComponent("code/ComfyUI").path])
    #expect(found.start?.path.hasSuffix("/code/comfyui") == true && !found.configured)
    // generate.check names it with the server off, and the provider can run (Regista would start it).
    var s = FakeServices().make()
    s.config = config
    s.comfyPlaces = [home.appendingPathComponent("code/ComfyUI").path]
    let check = try Engine(prober: FakeProber(), services: s).execute("generate.check", params: ["model": "z-image-turbo"])
    #expect(check["comfyui"]?.stringValue?.hasSuffix("/code/comfyui") == true && check["found"] == "found in the usual places")
    #expect(check.value(at: "models.0.state") == "notChecked" && check["running"] == false)
    #expect(ComfyUIProvider(config: config, places: s.comfyPlaces).unavailableReason(.music) == nil)
    // Nothing anywhere: the setup steps and the list it searched.
    s.comfyPlaces = []
    let none = try Engine(prober: FakeProber(), services: s).execute("generate.check")
    #expect(none.value(at: "models.0.state") == "missing" && none["setupSteps"] != nil)
    #expect(ComfyUIProvider(config: config, places: []).unavailableReason(.image)?.contains("does not know where it is") == true)
}

@Test func anOldEnginesFileWithTheRunnersIsReadAndTheyAreIgnored() throws {
    let f = tempDir().appendingPathComponent("engines.json")
    try #"{"comfyGen": "/somewhere/gen", "comfyRun": "/somewhere/run.py", "python3": "/usr/bin/python3", "comfyServer": "http://127.0.0.1:8000"}"#
        .write(to: f, atomically: true, encoding: .utf8)
    let c = try EngineConfig.load(from: f)
    #expect(c.comfyServer == "http://127.0.0.1:8000" && c.comfyStart == nil)
    #expect(ComfyServer.address(c).port == 8000)
}

@Test func inProcessWorkWhoseHostEndedReadsAsFailed() throws {
    let job = GenerationJobDir(tempDir().appendingPathComponent("job"))
    try FileManager.default.createDirectory(at: job.url, withIntermediateDirectories: true)
    // A pid whose start time is not the recorded one: the process that ran it is gone (its pid since reused).
    try Data().write(to: job.stdoutFile)
    try "\(getpid()) 1\n".write(to: job.hostFile, atomically: true, encoding: .utf8)
    #expect(job.exitStatus == 1 && job.stderrTail.contains("ended before the job finished"))
    // The host that is this process: still running.
    let live = GenerationJobDir(tempDir().appendingPathComponent("live"))
    try FileManager.default.createDirectory(at: live.url, withIntermediateDirectories: true)
    try "\(getpid()) \(ComfyServer.startTime(getpid()) ?? 0)\n".write(to: live.hostFile, atomically: true, encoding: .utf8)
    #expect(live.exitStatus == nil)
}

@Test func theShippedWorkflowsCarryEveryInputRegistaFills() throws {
    for w in ComfyCheck.workflows {
        let graph = w.graph
        #expect(graph[w.output]?["class_type"]?.stringValue?.hasPrefix("Save") == true, "\(w.model): output node")
        #expect(graph[w.output]?.value(at: "inputs.filename_prefix")?.stringValue?.hasPrefix("regista/") == true)
        for f in w.fills { #expect(graph[f.node]?.value(at: "inputs.\(f.input)") != nil, "\(w.model): \(f.node).\(f.input)") }
        for (_, n) in graph.objectValue ?? [:] {
            if let cls = n["class_type"]?.stringValue, cls == "UnetLoaderGGUF" { #expect(ComfyCheck.packs[cls] != nil) }
        }
    }
    #expect(ComfyCheck.models == ComfyUIProvider(config: EngineConfig(), places: []).models.map(\.id))
}

// MARK: item 1 — the manifest lists every model file; generate.check and engines.status say which ComfyUI sees

@Test func theManifestListsEveryModelFileTheWorkflowsLoad() throws {
    var loaded: [String: String] = [:]   // file → ComfyUI folder of the loader that reads it
    for w in ComfyCheck.workflows {
        let listed = Set(try #require(EngineManifest.shared.entry(w.engine)).modelFiles.map(\.name))
        for (_, n) in w.graph.objectValue ?? [:] {
            guard let cls = n["class_type"]?.stringValue, let folder = ComfyCheck.folders[cls] else { continue }
            for (_, v) in n["inputs"]?.objectValue ?? [:] {
                guard let file = v.stringValue, file.contains(".") else { continue }
                loaded[file] = folder
                #expect(listed.contains(file), "\(w.model) loads \(file), not listed under \(w.engine)")
            }
        }
    }
    let files = EngineManifest.shared.entries.flatMap(\.modelFiles)
    #expect(Set(files.map(\.name)) == Set(loaded.keys), "every listed file is loaded by a workflow")
    for f in files {
        #expect(f.folder == loaded[f.name], "\(f.name): models/\(f.folder), the loader reads models/\(loaded[f.name] ?? "?")")
        #expect(f.bytes > 1_000_000 && f.url.hasPrefix("https://") && !f.licence.isEmpty, "\(f.name)")
        #expect(f.sha256?.count == 64, "\(f.name): sha256")
    }
    // A missing file's hint carries the manifest's facts.
    #expect(ComfyCheck.modelHint(cls: "VAELoader", value: "ae.safetensors").contains("335 MB") == true || ComfyCheck.modelHint(cls: "VAELoader", value: "ae.safetensors").contains("0.34 GB"))
    #expect(ComfyCheck.modelHint(cls: "VAELoader", value: "ae.safetensors").contains("https://huggingface.co/Comfy-Org/z_image_turbo"))
}

@Test func generateCheckAndEnginesStatusSayWhichModelFilesComfyUISees() throws {
    // A ComfyUI that has everything Z-Image needs but its VAE.
    var info: [String: JSONValue] = [:]
    for w in ComfyCheck.workflows where w.model == "z-image-turbo" {
        for (_, n) in w.graph.objectValue ?? [:] {
            guard let cls = n["class_type"]?.stringValue else { continue }
            var req = info[cls]?.value(at: "input.required")?.objectValue ?? [:]
            for (name, v) in n["inputs"]?.objectValue ?? [:] {
                guard let t = v.stringValue, t != "ae.safetensors" else { continue }
                req[name] = [.array((req[name]?.arrayValue?.first?.arrayValue ?? []) + [.string(t)])]
            }
            info[cls] = ["input": ["required": .object(req)]]
        }
    }
    let data = JSONValue.object(info).data()
    var s = FakeServices().make()
    s.config.comfyServer = "http://127.0.0.1:9"
    s.generators = ["comfyui": ComfyUIProvider(config: s.config, places: [])]
    s.comfyServer = { data }
    let e = Engine(prober: FakeProber(), services: s)
    let check = try e.execute("generate.check", params: ["model": "z-image-turbo"])
    let files = try #require(check.value(at: "models.0.files")?.arrayValue)
    #expect(files.first { $0["name"] == "z_image_turbo_bf16.safetensors" }?["present"] == true)
    #expect(files.first { $0["name"] == "ae.safetensors" }?["present"] == false)
    #expect(files.first { $0["name"] == "ae.safetensors" }?["folder"] == "models/vae")
    let status = try e.execute("engines.status")
    let row = try #require(status["components"]?.arrayValue?.first { $0["id"] == "comfyui-z-image" })
    #expect(row["state"] == "missing" && row["reason"] == "ComfyUI does not see every model file")
    #expect(row["files"]?.arrayValue?.count == 3)
    let catalog = try #require(EngineCatalog(status: status).row("comfyui-z-image"))
    #expect(catalog.files.map(\.present) == [true, true, false] || Set(catalog.files.compactMap(\.present)) == [true, false])
    // ComfyUI off: the files are listed, not checked.
    s.comfyServer = { nil }
    let off = try Engine(prober: FakeProber(), services: s).execute("engines.status")
    let offRow = try #require(off["components"]?.arrayValue?.first { $0["id"] == "comfyui-wan22" })
    #expect(offRow["state"] == "notChecked" && offRow["files"]?.arrayValue?.allSatisfy { $0["present"] == nil } == true)
    // The ComfyUI row: its address and where it is, in the status Settings › Motori reads.
    let comfy = try #require(EngineCatalog(status: off).row("comfyui")?.comfy)
    #expect(comfy.server == "http://127.0.0.1:9" && !comfy.running && comfy.start == nil)
}

@Test func theAddressAndFolderSetInSettingsReachTheProviderWithoutARestart() throws {
    let file = tempDir().appendingPathComponent("engines.json")
    let provider = ComfyUIProvider(config: EngineConfig(), places: [], configFile: file)
    #expect(provider.location.server.absoluteString == ComfyServer.defaultAddress)
    try #"{"comfyServer": "http://127.0.0.1:8000", "comfyStart": "/usr/bin/true", "tier": "pro"}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(provider.location.server.port == 8000 && provider.location.start == .executable(URL(fileURLWithPath: "/usr/bin/true")))
    try #"{"tier": "pro"}"#.write(to: file, atomically: true, encoding: .utf8)
    #expect(provider.location.server.port == 8188 && provider.location.start == nil)
}
