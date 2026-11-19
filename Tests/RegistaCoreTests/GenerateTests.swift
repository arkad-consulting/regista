import Foundation
import Testing
@testable import RegistaCore

/// A provider whose job is a tiny shell script: it counts its runs and writes result.png.
struct FakeGenerator: GeneratorProvider {
    var id = "fakefree"
    var paid = false
    var credits = 2.4
    var title: String { id }
    var minimumTier = MachineTier.base
    var models = [GeneratorModel("fake-still", .image, "test", isDefault: true), GeneratorModel("fake-clip", .video, "test", isDefault: true)]
    /// Each run appends a line here.
    let runs: URL

    func unavailableReason(_ kind: GenerationKind) -> String? { nil }
    func estimate(_ request: GenerationRequest) throws -> Double { paid ? credits : 0 }
    func process(_ request: GenerationRequest, job: URL) throws -> GenerationProcess {
        GenerationProcess(URL(fileURLWithPath: "/bin/sh"),
                          ["-c", "echo run >> '\(runs.path)'; printf png > result.png; echo '{\"files\": [\"result.png\"], \"seed\": 7}'"])
    }
    func collect(_ request: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput {
        guard Generation.lastJSON(stdout)?["files"] != nil else { throw CommandError(.io, "no result") }
        return GenerationOutput(file: job.appendingPathComponent("result.png").path, model: model(for: request), seed: 7)
    }

    var runCount: Int { ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count }
}

struct GenerateFixture {
    let free: FakeGenerator
    let paid: FakeGenerator
    let state = tempDir()
    let engine: Engine

    init() throws {
        let dir = tempDir()
        free = FakeGenerator(runs: dir.appendingPathComponent("free-runs.txt"))
        paid = FakeGenerator(id: "higgsfield", paid: true, runs: dir.appendingPathComponent("paid-runs.txt"))
        var services = FakeServices().make()
        services.generators = [free.id: free, paid.id: paid]
        services.generationState = state
        engine = Engine(prober: FakeProber(), services: services)
        try engine.execute("project.new", params: ["name": "gen", "directory": .string(tempDir().path)])
    }

    var budget: GenerationBudget { GenerationBudget(directory: state) }

    func approve(_ estimateID: String) throws -> String {
        try engine.execute("generate.approve", params: ["estimateId": .string(estimateID)])["approval"]!.stringValue!
    }

    func estimate(_ prompt: String) throws -> String {
        try engine.execute("generate.estimate", params: ["provider": "higgsfield", "kind": "image", "prompt": .string(prompt)])["estimateId"]!.stringValue!
    }
}

@Test func freeRunLandsInTheBinWithMetadataAndIsCached() throws {
    let f = try GenerateFixture()
    let r = try f.engine.execute("generate.run", params: ["provider": "fakefree", "kind": "image", "prompt": "abstract server room", "seed": 42])
    #expect(r["status"] == "done")
    #expect(r["cached"] == false)
    let aid = try #require(r["assetId"]?.stringValue)
    let asset = try #require(f.engine.project?.asset(aid))
    let g = try #require(asset.generated)
    #expect(g.provider == "fakefree")
    // Named by its own words, never by the provider and the kind (#86: «voxcpm voice: …»).
    #expect(asset.name == "abstract server room", "the generated asset is named «\(asset.name)»")
    #expect(g.model == "fake-still")
    #expect(g.prompt == "abstract server room")
    #expect(g.seed == 7)
    #expect(g.cost == 0)
    #expect(g.unit == "free")
    #expect(ISO8601DateFormatter().date(from: g.created) != nil)
    #expect(asset.path.contains("/media/generated/"))
    #expect(asset.image?.kind == .still)
    #expect(f.free.runCount == 1)

    // Same request: cached, no second process.
    let again = try f.engine.execute("generate.run", params: ["provider": "fakefree", "kind": "image", "prompt": "abstract server room", "seed": 42])
    #expect(again["cached"] == true)
    #expect(again["assetId"]?.stringValue == aid)
    #expect(f.free.runCount == 1)
    let list = try f.engine.execute("generate.list")
    #expect(list["assets"]?.arrayValue?.count == 1)
    #expect(list["jobs"]?.arrayValue?.count == 2)

    // The generated file can go straight on the timeline.
    try f.engine.execute("overlay.add", params: ["path": .string(asset.path), "start": 0, "duration": 1, "fullFrame": true])
    #expect(f.engine.project?.assets.count == 1)
}

@Test func backgroundRunIsCollectedByStatus() throws {
    let f = try GenerateFixture()
    let r = try f.engine.execute("generate.run", params: ["provider": "fakefree", "kind": "image", "prompt": "bg", "wait": false])
    #expect(r["status"] == "running")
    let jid = try #require(r["jobId"]?.stringValue)
    var status = JSONValue.null
    for _ in 0..<600 {   // up to 60 s: the background job is slow to start on a busy Mac
        status = try f.engine.execute("generate.status", params: ["jobId": .string(jid)])
        if status["status"] != "running" { break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    #expect(status["status"] == "done")
    #expect(status["assetId"] != nil)
}

@Test func paidRunWithoutApprovalFails() throws {
    let f = try GenerateFixture()
    #expect(throws: CommandError.self) {
        try f.engine.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": "hero"])
    }
    #expect(f.paid.runCount == 0)
    #expect(try f.budget.remaining("higgsfield") == 2)
    // The refusal left a pending estimate for the human.
    #expect(try GenerationApprovals(directory: f.state).pending().count == 1)
    // A made-up token fails too.
    #expect(throws: CommandError.self) {
        try f.engine.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": "hero", "approval": "ap-nope"])
    }
    #expect(f.paid.runCount == 0)
}

@Test func approvalForADifferentEstimateFails() throws {
    let f = try GenerateFixture()
    let token = try f.approve(try f.estimate("prompt A"))
    do {
        try f.engine.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": "prompt B", "approval": .string(token)])
        Issue.record("ran with an approval for another estimate")
    } catch let e as CommandError {
        #expect(e.message.contains("different estimate"))
    }
    #expect(f.paid.runCount == 0)
    #expect(try f.budget.remaining("higgsfield") == 2)

    // The right request runs once, costs its credits, and the token is spent.
    let r = try f.engine.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": "prompt A", "approval": .string(token)])
    #expect(r["cost"] == 2.4)
    #expect(r["budgetRemaining"] == 1)
    let asset = try #require(f.engine.project?.asset(r["assetId"]!.stringValue!))
    #expect(asset.generated?.cost == 2.4)
    #expect(asset.generated?.unit == "credits")
    #expect(f.paid.runCount == 1)
    #expect(throws: CommandError.self) {   // single use (and the cached result needs no token: no new call)
        try f.engine.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": "prompt C", "approval": .string(token)])
    }
}

@Test func paidCapOfTwoCallsIsHard() throws {
    let f = try GenerateFixture()
    for prompt in ["one", "two"] {
        let token = try f.approve(try f.estimate(prompt))
        try f.engine.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": .string(prompt), "approval": .string(token)])
    }
    #expect(f.paid.runCount == 2)
    #expect(try f.budget.remaining("higgsfield") == 0)
    let token = try f.approve(try f.estimate("three"))
    do {
        try f.engine.execute("generate.run", params: ["provider": "higgsfield", "kind": "image", "prompt": "three", "approval": .string(token)])
        Issue.record("third paid call ran")
    } catch let e as CommandError {
        #expect(e.message.contains("budget exhausted"))
    }
    #expect(f.paid.runCount == 2)
    // The file shows the calls; editing it cannot raise the cap above 2.
    let file = try JSONValue.parse(String(contentsOf: f.budget.file, encoding: .utf8))
    #expect(file.value(at: "higgsfield.remaining") == 0)
    #expect(file.value(at: "higgsfield.calls")?.arrayValue?.count == 2)
    try #"{"higgsfield": {"cap": 10, "used": 0, "remaining": 10, "calls": []}}"#.write(to: f.budget.file, atomically: true, encoding: .utf8)
    #expect(try f.budget.remaining("higgsfield") == 2)
}

@Test func approveIsHumanOnly() throws {
    #expect(GenerateApprove.descriptor.humanOnly)
    #expect(!GenerateRun.descriptor.humanOnly)
    #expect(Engine().descriptors.filter(\.humanOnly).map(\.id).sorted() == ["generate.approve", "profile.adopt", "profile.delete", "profile.switch"])
}

@Test func requestHashFollowsPromptParamsAndRefContent() throws {
    let dir = tempDir()
    let ref = dir.appendingPathComponent("start.png")
    try Data("a".utf8).write(to: ref)
    let a = GenerationRequest(provider: "comfyui", kind: .video, prompt: "pan", refs: [ref.path], duration: 3)
    let h1 = try a.hash()
    #expect(try a.hash() == h1)
    var b = a; b.duration = 4
    #expect(try b.hash() != h1)
    try Data("b".utf8).write(to: ref)   // same path, new content
    #expect(try a.hash() != h1)
    let copy = dir.appendingPathComponent("copy.png")   // same content elsewhere: same job
    try Data("a".utf8).write(to: copy)
    var c = a; c.refs = [copy.path]
    #expect(try c.hash() == h1)
    #expect(GenerationRequest.defaultSeed("x") == GenerationRequest.defaultSeed("x"))
    #expect(GenerationRequest.defaultSeed("x") != GenerationRequest.defaultSeed("y"))
}

@Test func providersCommandArgumentsMatchTheCLIs() throws {
    let config = EngineConfig()
    let comfy = ComfyUIProvider(config: config, places: [])
    let job = tempDir()
    // ComfyUI runs in this process (#6): the request is checked before anything runs (ComfyTests drive a stand-in server).
    #expect(try comfy.process(GenerationRequest(provider: "comfyui", kind: .video, prompt: "slow push", refs: ["/tmp/s.png"], duration: 3, seed: 5), job: job).work != nil)
    #expect(throws: CommandError.self) { try comfy.process(GenerationRequest(provider: "comfyui", kind: .video, prompt: "x"), job: job) }
    #expect(throws: CommandError.self) { try comfy.process(GenerationRequest(provider: "comfyui", kind: .image, prompt: "x", width: 1000, height: 1000), job: job) }
    let hf = HiggsfieldProvider(config: config)
    let args = hf.arguments(GenerationRequest(provider: "higgsfield", kind: .video, prompt: "p", refs: ["/tmp/s.png"], duration: 4,
                                              options: ["resolution": "480p", "generate_audio": "false"]))
    #expect(args == ["seedance1_5", "--prompt", "p", "--aspect_ratio", "9:16", "--start-image", "/tmp/s.png", "--duration", "4",
                     "--generate_audio", "false", "--resolution", "480p"])
    let found = HiggsfieldProvider.result(try JSONValue.parse(#"[{"id": "j1", "status": "completed", "result_url": "https://x/y.mp4"}]"#))
    #expect(found?.url == "https://x/y.mp4")
    #expect(found?.id == "j1")
    #expect(HiggsfieldProvider.authHint("Error: Not authenticated. Run higgsfield auth login") != nil)
}

/// Writes an empty file per frame (the pixels do not matter to the command layer).
final class FakeSegmenter: PersonSegmenter {
    var requests: [MatteRequest] = []
    func segment(_ r: MatteRequest) throws -> MatteReport {
        requests.append(r)
        try FileManager.default.createDirectory(at: r.directory, withIntermediateDirectories: true)
        var n = 0
        for i in r.frames {
            let f = r.directory.appendingPathComponent(String(format: "%06d.png", i))
            if !FileManager.default.fileExists(atPath: f.path) { FileManager.default.createFile(atPath: f.path, contents: Data()); n += 1 }
        }
        return MatteReport(width: 384, height: 512, segmented: n, coverage: 0.4, engine: "fake")
    }
}

@Test func matteTrackCoversTheWindowAndBehindSubjectWarnsUntilThen() throws {
    let seg = FakeSegmenter()
    var services = FakeServices().make()
    services.segmenter = seg
    try FileManager.default.createDirectory(at: services.generationState, withIntermediateDirectories: true)
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "m", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "start": 0, "sourceIn": 10, "sourceOut": 20])

    let before = try e.execute("title.add", params: ["text": "HOOK", "start": 0, "duration": 3, "behindSubject": true])
    #expect(before["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("matte.track") == true } == true)
    #expect(before.value(at: "clip.behindSubject") == true)
    try e.execute("history.undo")

    let r = try e.execute("matte.track", params: ["from": 0, "to": 3])
    // Source 10–13 s at 30 fps = frames 300…390, plus one frame of margin each side.
    #expect(r["frames"] == 93)
    #expect(seg.requests.first?.frames.first == 299)
    #expect(e.project?.assets[0].analysis?.matte?.ranges == [[299, 391]])
    let again = try e.execute("matte.track", params: ["from": 0, "to": 3])
    #expect(again["segmented"] == 0)
    let after = try e.execute("title.add", params: ["text": "HOOK", "start": 0, "duration": 3, "behindSubject": true])
    #expect(after["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("matte.track") == true } != true)
    // The render plan hands the camera layer its matte frame.
    let layers = RenderJob(project: e.project!, preset: .vertical).layers(at: MediaTime(seconds: 1))
    #expect(layers.first?.matte?.hasSuffix("000330.png") == true)
    #expect(layers.last?.behindSubject == true)
    #expect(RenderJob.subjects(layers) == [1: 0])
}

/// #77: a cancel also stops what the job starts after it (a cancel that came before the wrapper had started its child
/// found nothing to stop, and the child ran to its end). Here the model ignores SIGTERM, starts its worker a second
/// after the cancel and waits for it: the worker must still be stopped.
@Test func aCancelAlsoStopsWhatTheJobStartsAfterIt() throws {
    let dir = tempDir()
    let model = dir.appendingPathComponent("model.sh")
    try """
    #!/bin/sh
    trap '' TERM
    touch ready
    sleep 1
    sleep 60 &
    echo $! > worker.pid
    wait
    """.write(to: model, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: model.path)
    let job = GenerationJobDir(dir.appendingPathComponent("job"))
    let cancel = GenerationCancellation()
    // A thread of its own (the global queues can be saturated in the full suite); cancels once the model runs.
    Thread.detachNewThread {
        for _ in 0..<600 where !FileManager.default.fileExists(atPath: job.url.appendingPathComponent("ready").path) {
            Thread.sleep(forTimeInterval: 0.05)
        }
        cancel.cancel()
    }
    let started = Date()
    try job.launch(GenerationProcess(model, []), wait: true, cancellation: cancel)
    #expect(Date().timeIntervalSince(started) < 30)   // well under the worker's 60 s
    #expect(job.exitStatus != 0)
    let pidText = try String(contentsOf: job.url.appendingPathComponent("worker.pid"), encoding: .utf8)
    let worker = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    var gone = false
    for _ in 0..<300 where !gone {   // SIGKILL 3 s after the sweep that found it, whatever the load (up to 30 s)
        gone = kill(worker, 0) != 0
        if !gone { Thread.sleep(forTimeInterval: 0.1) }
    }
    if !gone { kill(worker, SIGKILL) }
    #expect(gone, "the worker started after the cancel is still running")
}

/// G1 (#5): what the Generate panel reads from the commands — the formats per kind, why a kind cannot run (tier or setup,
/// and the engine to install), the time a local run takes, and the price of an upscale before generate.upscale.
@Test func providersAndEstimateTellThePanelFormatsReasonsAndTime() throws {
    let dir = tempDir()
    var config = EngineConfig()
    config.cacheDirectory = dir.path
    config.comfyServer = "http://127.0.0.1:9"   // nothing answers there
    func engine(_ tier: MachineTier, start: String? = nil) throws -> Engine {
        var s = FakeServices(tier: tier).make()
        var config = config
        config.comfyStart = start
        s.config = config
        s.generators = ["comfyui": ComfyUIProvider(config: config, places: [])]
        s.generationState = tempDir()
        let e = Engine(prober: FakeProber(), services: s)
        try e.execute("project.new", params: ["name": "g", "directory": .string(tempDir().path)])
        return e
    }
    // Regista knows no ComfyUI: every kind waits for the setup, with the engine to set up.
    let unset = try #require(try engine(.pro).execute("generate.providers")["providers"]?.arrayValue?.first)
    #expect(unset.value(at: "kinds.music.available") == false)
    #expect(unset.value(at: "kinds.music.why") == "setup")
    #expect(unset.value(at: "kinds.music.engine") == "comfyui")
    // A start command set: Regista starts the server when it runs, every kind is available.
    let e = try engine(.pro, start: "/usr/bin/true")
    let comfy = try #require(try e.execute("generate.providers")["providers"]?.arrayValue?.first)
    #expect(comfy.value(at: "kinds.image.available") == true && comfy.value(at: "kinds.music.available") == true)
    #expect(comfy.value(at: "formats.image")?.arrayValue?.first?["name"] == "9:16")
    #expect(comfy.value(at: "formats.image")?.arrayValue?.first?["size"] == [720, 1280])
    #expect(comfy.value(at: "formats.video")?.arrayValue?.map { $0["name"]?.stringValue ?? "" } == ["9:16", "4:5", "1:1", "16:9"])
    #expect(comfy.value(at: "formats.music") == nil)
    let low = try #require(try engine(.medium).execute("generate.providers")["providers"]?.arrayValue?.first)
    #expect(low.value(at: "kinds.image.why") == "tier")

    let still = try e.execute("generate.estimate", params: ["provider": "comfyui", "kind": "image", "prompt": "a calm desk"])
    #expect(still["seconds"]?.doubleValue.map { $0 > 20 && $0 < 60 } == true)
    #expect(still["credits"] == 0)
    let clip = try e.execute("generate.estimate", params: ["provider": "comfyui", "kind": "video", "prompt": "slow push", "duration": 3])
    #expect(clip["seconds"] == 300)
    #expect(throws: CommandError.self) { try e.execute("generate.estimate", params: ["provider": "comfyui", "kind": "image"]) }

    // Upscale: the clip by asset id, no prompt; the time follows its length. The same request generate.upscale runs.
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    let up = try e.execute("generate.estimate", params: ["provider": "comfyui", "kind": "upscale", "refs": ["a1"]])
    let asset = try #require(e.project?.asset("a1"))
    #expect(up["seconds"]?.doubleValue == (80 * asset.duration.seconds).rounded())
    #expect(up["requestHash"]?.stringValue == (try Generate.upscaleRequest(asset, command: "t").hash()))
}

/// A provider whose job waits a minute (it touches `ready` first).
private struct SlowGenerator: GeneratorProvider {
    let ready: URL
    var id = "slow"
    var title: String { id }
    var paid = false
    var minimumTier = MachineTier.base
    var models = [GeneratorModel("slow-still", .image, "test", isDefault: true)]
    func unavailableReason(_ kind: GenerationKind) -> String? { nil }
    func estimate(_ request: GenerationRequest) throws -> Double { 0 }
    func process(_ request: GenerationRequest, job: URL) throws -> GenerationProcess {
        GenerationProcess(URL(fileURLWithPath: "/bin/sh"), ["-c", "touch '\(ready.path)'; sleep 60"])
    }
    func collect(_ request: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput { throw CommandError(.io, "never") }
}

/// The app runs generate.run inside a job: its Cancel stops the generation process and the command fails "cancelled",
/// leaving the project as it was.
@Test func aJobCancelStopsAGenerationRun() throws {
    let ready = tempDir().appendingPathComponent("ready")
    var s = FakeServices().make()
    s.generators = ["slow": SlowGenerator(ready: ready)]
    s.generationState = tempDir()
    let e = Engine(prober: FakeProber(), services: s)
    try e.execute("project.new", params: ["name": "c", "directory": .string(tempDir().path)])
    let job = CommandJob()
    Thread.detachNewThread {
        for _ in 0..<600 where !FileManager.default.fileExists(atPath: ready.path) { Thread.sleep(forTimeInterval: 0.05) }
        job.cancel()
    }
    let started = Date()
    do {
        try CommandJob.$current.withValue(job) {
            _ = try e.execute("generate.run", params: ["provider": "slow", "kind": "image", "prompt": "never"])
        }
        Issue.record("the run was not cancelled")
    } catch let error as CommandError {
        #expect(error.message.contains("cancelled"))
    }
    #expect(Date().timeIntervalSince(started) < 30)
    #expect(e.project?.generations == nil)
    #expect(e.project?.assets.isEmpty == true)
}
