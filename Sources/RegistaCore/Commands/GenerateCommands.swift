import Foundation

// generate.* (issue #11): generated B-roll, music and upscales from providers (ComfyUI free, Higgsfield paid).
// The result becomes an ordinary asset (with `generated` metadata) that overlay.add / audio.addMusic place.

enum Generate {
    static let requestParams: [ParamSpec] = [
        .optional("provider", .string, "comfyui (local, free: the default), voxcpm (local, free: the default for voice) or higgsfield (paid: needs the human's approval, hard budget of 2 calls in total)."),
        .required("kind", .oneOf(["image", "video", "music", "voice"]), "image (a still: B-roll or a start frame), video (a clip; ComfyUI animates a start frame from refs), music (a bed; ComfyUI ACE-Step), voice (voice-over in the owner's cloned voice; VoxCPM2)."),
        .required("prompt", .string, "What to show (video: the motion and camera, not the whole scene). English works best. Voice: the words to say, in the voice's language, with the real spelling (brand names as written), numbers in words, a whole paragraph rather than a short line."),
        .optional("model", .string, "Provider model (generate.providers lists them; default per kind)."),
        .optional("refs", .array(.string), "Reference images: asset ids (a1) or file paths. ComfyUI video: refs[0] is the start frame."),
        .optional("duration", .number, "Seconds (video 1–5 on ComfyUI; music)."),
        .optional("size", .array(.integer), "[width, height] in pixels (ComfyUI: multiples of 16; default 720×1280 still, 464×832 clip). Higgsfield uses it for the aspect ratio."),
        .optional("seed", .integer, "Seed (default: derived from the prompt, so the same request is cached)."),
        .optional("options", .object, "Provider flags as strings, e.g. {\"resolution\": \"480p\", \"generate_audio\": \"false\"} (Higgsfield) or {\"bpm\": \"100\"} (ACE-Step). Voice: {\"voice\": \"ada\", \"language\": \"fr\", \"tone\": \"neutral\"} (voice.list shows them; voice and language may be left out when there is only one)."),
    ]

    static func provider(_ id: String?, _ ctx: CommandContext, command: String) throws -> GeneratorProvider {
        let id = id ?? "comfyui"
        guard let p = ctx.services.generators[id] else {
            let known = ctx.services.generators.keys.sorted().joined(separator: ", ")
            throw CommandError.invalid("\(command): unknown provider \(id) (this host has: \(known.isEmpty ? "none" : known))")
        }
        return p
    }

    /// A ref is an asset id of the project or a file path.
    static func resolve(ref: String, in project: Project, command: String) throws -> (path: String, assetID: String?) {
        if let a = project.asset(ref) { return (a.path, a.id) }
        let path = URL(fileURLWithPath: EngineConfig.expand(ref)).standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else { throw CommandError.notFound("\(command): ref \(ref) is neither an asset nor a file") }
        return (path, project.assets.first { $0.path == path }?.id)
    }

    static func request(_ p: CommandParams, _ project: Project, command: String) throws -> (GenerationRequest, String?) {
        var refs: [String] = [], source: String?
        for r in p.strings("refs") ?? [] {
            let (path, asset) = try resolve(ref: r, in: project, command: command)
            refs.append(path)
            if source == nil { source = asset }
        }
        var w: Int?, h: Int?
        if let s = p.numbers("size") {
            guard s.count == 2 else { throw CommandError.invalid("\(command): size is [width, height]") }
            w = Int(s[0]); h = Int(s[1])
        }
        var options: [String: String]?
        if let o = p.json("options")?.objectValue, !o.isEmpty {
            options = o.mapValues { v in v.stringValue ?? v.text() }
        }
        let prompt = p.requiredString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw CommandError.invalid("\(command): prompt is empty") }
        let kind = GenerationKind(rawValue: p.requiredString("kind"))!
        let r = GenerationRequest(provider: p.string("provider") ?? (kind == .voice ? "voxcpm" : "comfyui"), kind: kind,
                                  prompt: prompt, model: p.string("model"), refs: refs, duration: p.number("duration"),
                                  width: w, height: h, seed: p.int("seed"), options: options)
        return (r, source)
    }

    static func check(_ provider: GeneratorProvider, _ kind: GenerationKind, _ ctx: CommandContext, command: String) throws {
        if ctx.services.tier < provider.minimumTier {
            throw CommandError(.io, "\(command): \(provider.id) needs the \(provider.minimumTier.rawValue) tier (this Mac: \(ctx.services.tier.rawValue)) — reuse footage or ask for a paid shot")
        }
        if let why = provider.unavailableReason(kind) { throw CommandError(.io, "\(command): \(why)") }
    }

    /// What generate.upscale runs for a clip of the project (generate.estimate prices the same request).
    static func upscaleRequest(_ asset: MediaAsset, command: String) throws -> GenerationRequest {
        guard asset.video != nil, asset.image == nil else { throw CommandError.conflict("\(command): \(asset.name) is not a video clip") }
        return GenerationRequest(provider: "comfyui", kind: .upscale, prompt: asset.generated?.prompt ?? "", refs: [asset.path])
    }

    /// The provider's own validation and completion of the request (before hashing).
    static func prepare(_ provider: GeneratorProvider, _ request: GenerationRequest, command: String) throws -> GenerationRequest {
        do { return try provider.prepare(request) }
        catch let e as CommandError { throw CommandError(e.code, "\(command): \(e.message)") }
    }

    static func jobDir(_ ctx: CommandContext, _ provider: String, _ hash: String) -> GenerationJobDir {
        GenerationJobDir(ctx.services.config.url(ctx.services.config.cacheDirectory).appendingPathComponent("generate/\(provider)-\(hash)"))
    }

    static func estimate(_ provider: GeneratorProvider, _ request: GenerationRequest) throws -> GenerationEstimate {
        let hash = try request.hash()
        let credits = provider.paid ? try provider.estimate(request) : 0
        return GenerationEstimate(provider: provider.id, model: provider.model(for: request), request: request, requestHash: hash,
                                  credits: credits, paid: provider.paid)
    }

    /// Copies the result into the project's media folder and imports it as an asset carrying its origin.
    static func importOutput(_ out: GenerationOutput, _ job: GenerationJob, _ project: inout Project, _ ctx: inout CommandContext,
                             command: String) throws -> String {
        let src = URL(fileURLWithPath: out.file)
        let dir = try ctx.mediaDirectory().appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("\(job.request.provider)-\(job.request.kind.rawValue)-\(job.requestHash).\(src.pathExtension.lowercased())")
        if !FileManager.default.fileExists(atPath: dest.path) {
            do { try FileManager.default.copyItem(at: src, to: dest) }
            catch { throw CommandError(.io, "\(command): cannot copy the result into \(dir.path): \(error.localizedDescription)") }
        }
        let assetID: String
        switch job.request.kind {
        case .music, .voice: assetID = try AudioTracks.importAudio(dest.path, into: &project, ctx, command: command).id
        case .image, .video, .upscale: assetID = try Graphics.importVisual(dest.path, into: &project, &ctx, alpha: false, command: command)
        }
        let i = project.assets.firstIndex { $0.id == assetID }!
        // Named by its own words (the paragraph said, the prompt), never by the provider's id (#86: «voxcpm voice: …»).
        project.assets[i].name = job.request.prompt.isEmpty ? src.lastPathComponent : String(job.request.prompt.prefix(60))
        project.assets[i].generated = GenerationInfo(
            provider: job.request.provider, model: out.model, kind: job.request.kind, prompt: job.request.prompt, seed: out.seed,
            cost: out.cost ?? job.cost, unit: job.cost > 0 || (out.cost ?? 0) > 0 ? "credits" : (ctx.services.generators[job.request.provider]?.paid == true ? "credits" : "free"),
            created: Generation.now(), jobID: job.id, requestHash: job.requestHash, sourceAssetID: job.sourceAssetID,
            remoteID: out.remoteID, seconds: out.seconds)
        return assetID
    }

    /// Collects a finished job folder (exit 0) into output.json.
    static func collect(_ provider: GeneratorProvider, _ request: GenerationRequest, _ dir: GenerationJobDir, cost: Double) throws -> GenerationOutput {
        var out = try provider.collect(request, job: dir.url, stdout: dir.stdout)
        out.cost = cost
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try e.encode(out).write(to: dir.outputFile, options: .atomic)
        return out
    }

    static func jobJSON(_ job: GenerationJob, _ project: Project) -> JSONValue {
        var o: [String: JSONValue] = ["jobId": .string(job.id), "status": .string(job.status.rawValue), "provider": .string(job.request.provider),
                                      "kind": .string(job.request.kind.rawValue), "prompt": .string(job.request.prompt),
                                      "cost": .number(job.cost), "created": .string(job.created), "directory": .string(job.directory)]
        if let a = job.assetID, let asset = project.asset(a) {
            o["assetId"] = .string(a)
            o["path"] = .string(asset.path)
            o["asset"] = ProjectState.summary(of: asset)
        }
        if let e = job.error { o["error"] = .string(e) }
        return .object(o)
    }

    /// Runs (or reuses) one job. Paid providers: approval token for exactly this request, then one call off the budget.
    static func execute(_ request: GenerationRequest, sourceAssetID: String?, approval: String?, wait: Bool, keepRunning: Bool,
                        _ ctx: inout CommandContext, command: String) throws -> JSONValue {
        var project = try ctx.requireProject()
        let provider = try Self.provider(request.provider, ctx, command: command)
        try check(provider, request.kind, ctx, command: command)
        // ComfyUI: its node packs and model files before anything is queued (#36); a server that is off does not block.
        if provider.id == "comfyui" {
            let location = (provider as? ComfyUIProvider)?.location ?? ctx.services.comfyLocation
            // A refused run ends like any other (#123): a server Regista started and kept up for it is stopped unless the
            // caller keeps it.
            do { try ComfyCheck.gate(model: provider.model(for: request), location: location, command: command, fetch: ctx.services.comfyServer) }
            catch { provider.finish(keepRunning: keepRunning); throw error }
        }
        let request = try prepare(provider, request, command: command)
        let hash = try request.hash()
        let dir = jobDir(ctx, provider.id, hash)
        var job = GenerationJob(id: project.makeID("g"), request: request, requestHash: hash, status: .running, directory: dir.url.path,
                                sourceAssetID: sourceAssetID, cost: 0, created: Generation.now())

        func finishDone(_ out: GenerationOutput, cached: Bool) throws -> JSONValue {
            job.cost = out.cost ?? 0
            job.assetID = try importOutput(out, job, &project, &ctx, command: command)
            job.status = .done
            project.generations = (project.generations ?? []) + [job]
            ctx.project = project
            var r = jobJSON(job, project).objectValue!
            r["cached"] = .bool(cached)
            r["model"] = .string(out.model)
            if let s = out.seed { r["seed"] = .number(Double(s)) }
            if let s = out.seconds { r["seconds"] = .number(s) }
            if provider.paid { r["budgetRemaining"] = .number(Double(try GenerationBudget(directory: ctx.services.generationState).remaining(provider.id))) }
            return .object(r)
        }

        // Cache: the same request (refs by content) already produced a file.
        if let out = dir.output { return try finishDone(out, cached: true) }
        if FileManager.default.fileExists(atPath: dir.stdoutFile.path), dir.exitStatus == nil {
            project.generations = (project.generations ?? []) + [job]
            ctx.project = project
            return ["jobId": .string(job.id), "status": "running", "directory": .string(dir.url.path),
                    "note": "the same request is already running: poll generate.status"]
        }
        if dir.exitStatus == 0 {
            // Finished earlier (e.g. detached) but never collected: collect, never run (or pay) twice.
            do {
                let cost = (try? JSONValue.parse(String(contentsOf: dir.url.appendingPathComponent("cost.json"), encoding: .utf8)))?["credits"]?.doubleValue ?? 0
                return try finishDone(try collect(provider, request, dir, cost: cost), cached: true)
            } catch where provider.paid {
                throw CommandError(.io, "\(command): a paid job for this request already ran but its result cannot be read (\(error)). Job folder: \(dir.url.path) — inspect it; deleting it allows another (paid) run")
            } catch {}
        }

        var cost = 0.0
        if provider.paid {
            let budget = GenerationBudget(directory: ctx.services.generationState)
            try budget.requireRemaining(provider.id)
            guard let token = approval else {
                let e = try estimate(provider, request)
                try GenerationApprovals(directory: ctx.services.generationState).request(e, project: ctx.projectURL?.path)
                throw CommandError.invalid("\(command): \(provider.id) is paid (\(e.credits) credits, \(e.model)): it needs the human's approval of estimate \(e.estimateID). Ask them to approve it in the Regista app (or `regista-engine exec generate.approve '{\"estimateId\":\"\(e.estimateID)\"}'` in their terminal), then pass the token as approval. Prefer ComfyUI (free) unless this is the final hero shot.")
            }
            let e = try estimate(provider, request)
            let approved = try GenerationApprovals(directory: ctx.services.generationState).consume(token: token, requestHash: hash, credits: e.credits)
            cost = e.credits
            _ = try budget.consume(provider.id, GenerationBudget.Call(at: Generation.now(), model: e.model, prompt: request.prompt, credits: e.credits,
                                                                      estimateID: approved.estimate.estimateID, project: ctx.projectURL?.path))
            job.cost = cost
        }

        let process = try provider.process(request, job: dir.url)
        try FileManager.default.createDirectory(at: dir.url, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(request).write(to: dir.url.appendingPathComponent("request.json"))
        try JSONValue.object(["credits": .number(cost)]).data().write(to: dir.url.appendingPathComponent("cost.json"))
        // The app's job (its Cancel) when the command runs in one, else the host's.
        let cancellation = CommandJob.current?.cancellation ?? ctx.services.cancellation
        try dir.launch(process, wait: wait, cancellation: cancellation)
        guard wait else {
            project.generations = (project.generations ?? []) + [job]
            ctx.project = project
            return ["jobId": .string(job.id), "status": "running", "directory": .string(dir.url.path), "cost": .number(cost),
                    "note": "running in the background: poll generate.status {jobId} (ComfyUI clips take ~5 min)"]
        }
        defer { provider.finish(keepRunning: keepRunning) }
        if dir.exitStatus != 0, cancellation?.isCancelled == true { throw CommandError(.io, "\(command): cancelled") }
        guard dir.exitStatus == 0 else {
            throw CommandError(.io, "\(command): \(provider.id) failed (exit \(dir.exitStatus.map(String.init) ?? "?")):\n\(dir.stderrTail)\n\(dir.stdout.suffix(600))")
        }
        return try finishDone(try collect(provider, request, dir, cost: cost), cached: false)
    }
}

enum GenerateProviders: Command {
    static let id = "generate.providers"
    static let summary = "List the generation providers before generating: comfyui (local, free, Pro tier: Z-Image stills, Wan 2.2 clips from a start frame, ACE-Step music, Real-ESRGAN/RIFE upscale) and higgsfield (paid: every run needs the human's approval, hard budget of 2 calls in total). Returns each provider's models, availability per kind (when unavailable: reason, why = tier | setup, and the engine to install or set up), the picture formats it makes per kind (name and size to pass as size) and the budget left."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let budget = GenerationBudget(directory: ctx.services.generationState)
        let list = ctx.services.generators.values.sorted { $0.id < $1.id }.map { g -> JSONValue in
            var kinds: [String: JSONValue] = [:]
            var formats: [String: JSONValue] = [:]
            // The manifest entry a person installs or sets up for this provider (Impostazioni › Motori), when there is one.
            let engine: JSONValue = EngineManifest.shared.entry(g.id) != nil ? .string(g.id) : .null
            for k in GenerationKind.allCases where g.models.contains(where: { $0.kind == k }) {
                let lowTier = ctx.services.tier < g.minimumTier
                let why = lowTier ? "needs the \(g.minimumTier.rawValue) tier" : g.unavailableReason(k)
                kinds[k.rawValue] = why.map { ["available": false, "reason": .string($0), "why": lowTier ? "tier" : "setup", "engine": engine] }
                    ?? ["available": true]
                let f = g.formats(k)
                if !f.isEmpty {
                    formats[k.rawValue] = .array(f.map { ["name": .string($0.name), "size": [.number(Double($0.width)), .number(Double($0.height))]] })
                }
            }
            var o: [String: JSONValue] = [
                "id": .string(g.id), "title": .string(g.title), "paid": .bool(g.paid), "minimumTier": .string(g.minimumTier.rawValue),
                "kinds": .object(kinds), "formats": .object(formats),
                "models": .array(g.models.map { ["id": .string($0.id), "kind": .string($0.kind.rawValue), "note": .string($0.note), "default": .bool($0.isDefault)] }),
            ]
            if g.id == "comfyui" {
                // The last generate.check of each model in this process (no server call here).
                let checks = ComfyCheck.models.compactMap { ComfyCheck.lastResult($0)?.json }
                if !checks.isEmpty { o["lastCheck"] = .array(checks) }
            }
            if g.paid {
                o["budgetRemaining"] = (try? budget.remaining(g.id)).map { .number(Double($0)) } ?? "unreadable"
                o["budgetCap"] = .number(Double(GenerationBudget.hardCaps[g.id] ?? 0))
            }
            return .object(o)
        }
        return ["providers": .array(list), "tier": .string(ctx.services.tier.rawValue), "budgetFile": .string(budget.file.path),
                "rule": "ComfyUI first; Higgsfield only for the final hero shot, with the human's approval."]
    }
}

enum GenerateCheck: Command {
    static let id = "generate.check"
    static let summary = "Check that ComfyUI can run a model before generating (generate.run also does it first): each ComfyUI model's workflow (shipped in Regista) against the running server's node list and model files. Never starts ComfyUI: when it is off, says which ComfyUI Regista would start (the folder set in Settings › Motori, or one found in the usual places) and the rest is \"not checked\". Returns the server address, where ComfyUI is, per model ready / missing (each missing node pack, model file or value with its ComfyUI folder and how to fix it) / notChecked, and the setup steps when Regista knows no ComfyUI."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = [
        .optional("model", .oneOf(ComfyCheck.models), "One ComfyUI model (default: all four)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let s = ctx.services
        let minimum = EngineManifest.shared.minimumTier("comfyui")
        let location = (s.generators["comfyui"] as? ComfyUIProvider)?.location ?? s.comfyLocation
        let info = s.comfyServer()
        let results = ComfyCheck.run(model: p.string("model"), location: location, objectInfo: info)
        // Every file each model loads, whether the running ComfyUI sees it (absent when it is off) and whether Regista can
        // download it into the ComfyUI folder it knows (#121).
        var downloadable: [EngineManifest.ModelFile] = []
        let models: [JSONValue] = results.map { r in
            guard var o = r.json.objectValue, let w = ComfyCheck.workflow(r.model), let entry = EngineManifest.shared.entry(w.engine) else { return r.json }
            let seen = Dictionary(r.files.map { ($0.file.name, $0.present) }, uniquingKeysWith: { a, _ in a })
            o["files"] = .array(entry.modelFiles.map { f in
                var j = ComfyCheck.FileState(file: f, present: seen[f.name] ?? false).json.objectValue!
                if seen[f.name] == nil { j["present"] = nil }
                let plan = ModelFetch.plan(f, location: location, source: s.modelSource)
                if case .ready = plan, seen[f.name] != true, !downloadable.contains(f) { downloadable.append(f) }
                j.merge(ModelFetch.json(plan, f)) { _, new in new }
                return .object(j)
            })
            return .object(o)
        }
        var o: [String: JSONValue] = [
            "models": .array(models),
            "ready": .bool(results.allSatisfy { $0.state == "ready" }),
            "summary": .string(results.map(\.summary).joined(separator: "\n")),
            "server": .string(location.server.absoluteString),
            "running": .bool(info != nil),
        ]
        // Where ComfyUI is (what Regista starts when nothing answers): the folder set in Settings, or the one found.
        if let start = location.start { o["comfyui"] = .string(start.path); o["found"] = .string(location.configured ? "set in Regista" : "found in the usual places") }
        if let problem = location.startProblem { o["startProblem"] = .string(problem) }
        if info == nil, location.start == nil { o["setupSteps"] = .string(ComfyCheck.setupSteps); o["searched"] = .array(location.configured ? [] : (s.generators["comfyui"] as? ComfyUIProvider)?.places.map { .string($0) } ?? s.comfyPlaces.map { .string($0) }) }
        if s.tier < minimum { o["tierReason"] = .string("ComfyUI needs the \(minimum.rawValue) tier (this Mac: \(s.tier.rawValue))") }
        if !downloadable.isEmpty {
            let bytes = downloadable.reduce(Int64(0)) { $0 + $1.bytes }
            o["downloadable"] = ["files": .number(Double(downloadable.count)), "bytes": .number(Double(bytes)), "size": .string(EngineManifest.sizeText(bytes)),
                                 "how": .string("generate.fetch downloads them (\(EngineManifest.sizeText(bytes))) into the ComfyUI folder Regista knows: tell the user the size and ask first")]
        }
        return .object(o)
    }
}

enum GenerateFetch: Command {
    static let id = "generate.fetch"
    static let summary = "Download missing ComfyUI model files: tens of GB, so before calling tell the user the size (generate.check gives each file's size and the total of the missing ones) and ask first. Each file goes into the models folder of the ComfyUI folder Regista knows (set in Settings › Motori, or found in the usual places; never one guessed from a running server: with only an address or a start program it refuses and says what to set). Free space is checked first (the files plus the manifest's disk margin of \(Int(EngineManifest.shared.diskMarginGB)) GB: the refusal says how much is missing); a file already there with the right size is skipped, one with another size is never overwritten; a partial download resumes; the sha256 is checked before the file is moved into place. Answers at once with one job per file (jobId d1…); generate.status {jobId} follows each (received, bytes, percent, running / done / failed with the reason / cancelled). Restart ComfyUI afterwards so it sees the new files."
    static let kind = CommandKind.job
    static let undoNote: String? = "no — starts downloads into the ComfyUI folder, outside the project; stop one with generate.status {jobId, cancel: true} (its partial file stays for the next generate.fetch)"
    static let params: [ParamSpec] = [
        .optional("model", .oneOf(ComfyCheck.models), "Every missing file of one ComfyUI model."),
        .optional("file", .string, "One model file by name (generate.check lists them)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let s = ctx.services
        let manifest = EngineManifest.shared
        let files: [EngineManifest.ModelFile]
        switch (p.string("model"), p.string("file")) {
        case (let m?, nil): files = manifest.entry(ComfyCheck.workflow(m)!.engine)?.modelFiles ?? []
        case (nil, let name?):
            guard let f = manifest.modelFile(name) else { throw CommandError.notFound("\(id): no model file \(name) (generate.check lists them)") }
            files = [f]
        default: throw CommandError.invalid("\(id): pass model or file (one of them)")
        }
        let location = (s.generators["comfyui"] as? ComfyUIProvider)?.location ?? s.comfyLocation
        let folder: URL
        switch ModelFetch.folder(location) {
        case .success(let f): folder = f
        case .failure(let e): throw CommandError(.io, "\(id): \(e.message)")
        }
        var start: [(file: EngineManifest.ModelFile, url: URL, target: URL)] = [], running: [ModelDownloads.Job] = [], skipped: [JSONValue] = []
        for f in files {
            let plan = ModelFetch.plan(f, location: location, source: s.modelSource)
            if let job = ModelDownloads.shared.running(f.name), job.target == plan.target { running.append(job); continue }
            if case .ready(let target, let url) = plan { start.append((f, url, target)); continue }
            var o = ModelFetch.json(plan, f)
            o["file"] = .string(f.name)
            skipped.append(.object(o))
            if files.count == 1, plan.state != "there" { throw CommandError(.conflict, "\(id): \(f.name): \(ModelFetch.note(plan, f) ?? plan.state)") }
        }
        // The room for everything this call starts, before the first byte (each download checks again for itself).
        let remaining = start.reduce(Int64(0)) { $0 + $1.file.bytes - (ModelFetch.fileSize($1.target.appendingPathExtension("part")) ?? 0) }
        if remaining > 0, let short = ModelFetch.shortfall(bytes: remaining, at: folder, source: s.modelSource) {
            throw CommandError(.io, "\(id): \(short.message). Nothing was downloaded.")
        }
        let jobs = running + start.map { ModelDownloads.shared.start($0.file, from: $0.url, to: $0.target, source: s.modelSource) }
        let bytes = jobs.reduce(Int64(0)) { $0 + $1.file.bytes }
        return ["jobs": .array(jobs.map(\.json)), "skipped": .array(skipped), "comfyui": .string(folder.path),
                "bytes": .number(Double(bytes)), "size": .string(EngineManifest.sizeText(bytes)),
                "note": .string(jobs.isEmpty ? "nothing to download: every file asked for is already there (or cannot be downloaded: see skipped)"
                                    : "downloading in the background: generate.status {jobId} follows each; restart ComfyUI once they are done so it sees them")]
    }
}

enum GenerateEstimate: Command {
    static let id = "generate.estimate"
    static let summary = "Price a generation before running it: credits from the provider's CLI (Higgsfield) or free (ComfyUI), about how long it takes on this Mac (local providers), and whether the result is already cached. kind upscale prices generate.upscale of the clip in refs[0] (no prompt). For a paid provider it records an approval request that the human sees in the Regista app (prompt, model, cost); generate.run then needs the token they get. Returns {estimateId, credits, seconds, model, paid, cached, budgetRemaining, approval}."
    static let kind = CommandKind.query
    static let undoNote: String? = "no — for a paid provider it records an approval request the person sees in the app, outside the project"
    static let params: [ParamSpec] = Generate.requestParams.map { spec in
        switch spec.name {
        case "kind": return .required("kind", .oneOf(["image", "video", "music", "voice", "upscale"]), "image, video, music or voice as for generate.run; upscale = generate.upscale of the clip in refs[0] (an asset id).")
        case "prompt": return .optional("prompt", .string, "As for generate.run (required for every kind but upscale).")
        default: return spec
        }
    }

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let raw: GenerationRequest
        var sourceSeconds: Double?
        if p.string("kind") == "upscale" {
            guard let ref = p.strings("refs")?.first, let asset = project.asset(ref) else {
                throw CommandError.invalid("\(id): upscale needs the clip's asset id in refs")
            }
            raw = try Generate.upscaleRequest(asset, command: id)
            sourceSeconds = asset.duration.seconds
        } else {
            guard p.string("prompt") != nil else { throw CommandError.invalid("\(id): prompt is required") }
            raw = try Generate.request(p, project, command: id).0
        }
        let provider = try Generate.provider(raw.provider, ctx, command: id)
        try Generate.check(provider, raw.kind, ctx, command: id)
        let request = try Generate.prepare(provider, raw, command: id)
        let e = try Generate.estimate(provider, request)
        let cached = Generate.jobDir(ctx, provider.id, e.requestHash).output != nil
        var r: [String: JSONValue] = ["estimateId": .string(e.estimateID), "provider": .string(e.provider), "model": .string(e.model),
                                      "kind": .string(e.kind.rawValue), "credits": .number(e.credits), "unit": .string(e.unit),
                                      "paid": .bool(e.paid), "cached": .bool(cached), "requestHash": .string(e.requestHash)]
        if let s = provider.seconds(request, sourceSeconds: sourceSeconds) { r["seconds"] = .number(s.rounded()) }
        if provider.paid {
            r["budgetRemaining"] = .number(Double(try GenerationBudget(directory: ctx.services.generationState).remaining(provider.id)))
            if cached {
                r["approval"] = "not needed: the result is cached (no call, no credits)"
            } else {
                try GenerationApprovals(directory: ctx.services.generationState).request(e, project: ctx.projectURL?.path)
                r["approval"] = .string("pending: the human approves \(e.estimateID) in the Regista app (or `regista-engine exec generate.approve '{\"estimateId\":\"\(e.estimateID)\"}'`); pass the token they get to generate.run as approval")
            }
        } else {
            r["approval"] = "not needed (free)"
        }
        return .object(r)
    }
}

enum GenerateApprove: Command {
    static let id = "generate.approve"
    static let summary = "Human only: approve (or decline) a paid generation estimate. The Regista app's confirmation sheet calls it; from a terminal the owner runs `regista-engine exec generate.approve '{\"estimateId\": \"e-…\"}'`. Agents cannot call it (MCP refuses). Returns the single-use approval token (valid 2 h, for exactly that request)."
    static let kind = CommandKind.session
    static let undoNote: String? = "no — records the person's decision on a paid estimate (a single-use token), outside the project"
    static let humanOnly = true
    static let params: [ParamSpec] = [
        .optional("estimateId", .string, "The estimate to decide (default: the only pending one)."),
        .optional("decline", .boolean, "Decline instead of approving."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let store = GenerationApprovals(directory: ctx.services.generationState)
        var eid = p.string("estimateId")
        if eid == nil {
            let pending = try store.pending()
            guard pending.count == 1 else {
                throw CommandError.invalid("\(id): \(pending.count) pending estimates — pass estimateId (\(pending.map(\.estimate.estimateID).joined(separator: ", ")))")
            }
            eid = pending[0].estimate.estimateID
        }
        let e = try store.decide(eid!, approve: p.bool("decline") != true)
        let budget = GenerationBudget(directory: ctx.services.generationState)
        try? budget.ensureFile()
        var r: [String: JSONValue] = ["estimateId": .string(e.estimate.estimateID), "status": .string(e.status.rawValue),
                                      "provider": .string(e.estimate.provider), "model": .string(e.estimate.model),
                                      "prompt": .string(e.estimate.prompt), "credits": .number(e.estimate.credits),
                                      "budgetRemaining": .number(Double((try? budget.remaining(e.estimate.provider)) ?? 0))]
        if let t = e.token { r["approval"] = .string(t) }
        return .object(r)
    }
}

enum GenerateRun: Command {
    static let id = "generate.run"
    static let summary = "Generate a still, a clip, a music bed or a voice-over (kind voice: the owner's cloned voice, VoxCPM2, see voice.list) and add it to the media bin (asset with provider, model, prompt, seed, cost, created). Then place it: overlay.add {path, fullFrame: true} for B-roll, audio.addMusic {path} for music, timeline.place for a voice-over. ComfyUI (free) first: image → video uses the still as start frame (refs), then generate.upscale to reach 1080×1920. Cached by request. Higgsfield (paid) needs approval (token from the human via generate.approve) and draws on the 2-call budget. Waits by default (ComfyUI stills ~30 s, clips ~5 min); wait: false runs in the background, poll generate.status. Returns the job and the asset."
    static let kind = CommandKind.edit
    static let undoNote: String? = "yes — one undo step takes the asset off the project; the generated file stays in the job folder, a paid call's credits are spent, and with wait: false the job keeps running (undo takes its record off the project)"
    static let params: [ParamSpec] = Generate.requestParams + [
        .optional("approval", .string, "Paid providers: the approval token the human got from generate.approve for this exact request."),
        .optional("wait", .boolean, "Wait for the result (default true); false = background job, poll generate.status."),
        .optional("keepRunning", .boolean, "ComfyUI: keep the server Regista started up for the next job (default false: stopped after use; a server someone else started keeps running and only frees its memory)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let (request, source) = try Generate.request(p, project, command: id)
        return try Generate.execute(request, sourceAssetID: source, approval: p.string("approval"), wait: p.bool("wait") ?? true,
                                    keepRunning: p.bool("keepRunning") ?? false, &ctx, command: id)
    }
}

enum GenerateUpscale: Command {
    static let id = "generate.upscale"
    static let summary = "Upscale a generated clip (ComfyUI Real-ESRGAN x4plus + RIFE 4.26): a 464×832 32 fps Wan clip becomes 1080×1920 at exactly 30 fps, same duration (~4 min per 3 s, cached). Crisper edges, no invented detail. Returns the new asset (generated.sourceAssetId = the original)."
    static let kind = CommandKind.edit
    static let undoNote: String? = "yes — one undo step takes the asset off the project; the upscaled file stays in the job folder, and with wait: false the job keeps running (undo takes its record off the project)"
    static let params: [ParamSpec] = [
        .required("assetId", .string, "Video asset to upscale."),
        .optional("wait", .boolean, "Wait for the result (default true)."),
        .optional("keepRunning", .boolean, "Keep ComfyUI up afterwards (default false)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        guard let asset = project.asset(p.requiredString("assetId")) else { throw CommandError.notFound("\(id): no asset \(p.requiredString("assetId"))") }
        let request = try Generate.upscaleRequest(asset, command: id)
        return try Generate.execute(request, sourceAssetID: asset.id, approval: nil, wait: p.bool("wait") ?? true,
                                    keepRunning: p.bool("keepRunning") ?? false, &ctx, command: id)
    }
}

enum GenerateStatus: Command {
    static let id = "generate.status"
    static let summary = "Check generation jobs: a background job (generate.run wait: false) is collected into the media bin when its process has finished. Without jobId lists every job of the project. A download of generate.fetch (jobId d1…) answers with or without a project: file, received, bytes, percent, status running / done / failed (with the reason) / cancelled; cancel: true stops it (the partial file stays: the next generate.fetch of that file resumes it). Returns the job(s) with status running / done / failed, asset and path when done."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .optional("jobId", .string, "Job (g1…, or d1… for a download of generate.fetch)."),
        .optional("cancel", .boolean, "Stop the download jobId (d1…): it answers once it has stopped (status cancelled; still running when the connection did not let go within 5 s: ask again)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        if p.bool("cancel") == true {
            guard let jid = p.string("jobId"), ModelDownloads.shared.job(jid) != nil else {
                throw CommandError.invalid("\(id): cancel stops a download of generate.fetch: pass its jobId (d1…)")
            }
            ModelDownloads.shared.cancel(jid)
            // The download stops at its next read (a moment); a stuck connection answers still running after 5 s.
            let end = Date().addingTimeInterval(5)
            while ModelDownloads.shared.job(jid)?.state == .running, Date() < end { Thread.sleep(forTimeInterval: 0.05) }
            return ModelDownloads.shared.job(jid)!.json
        }
        // A model file's download (generate.fetch): the process's, not the project's.
        if let jid = p.string("jobId"), let d = ModelDownloads.shared.job(jid) { return d.json }
        let downloads = ModelDownloads.shared.all
        if ctx.project == nil, p.string("jobId") == nil, !downloads.isEmpty { return ["jobs": [], "downloads": .array(downloads.map(\.json))] }
        var project = try ctx.requireProject()
        let jobs = project.generations ?? []
        guard let jid = p.string("jobId") else {
            var r: [String: JSONValue] = ["jobs": .array(jobs.map { Generate.jobJSON($0, project) })]
            if !downloads.isEmpty { r["downloads"] = .array(downloads.map(\.json)) }
            return .object(r)
        }
        guard let i = jobs.firstIndex(where: { $0.id == jid }) else { throw CommandError.notFound("\(id): no job \(jid)") }
        var job = jobs[i]
        if job.status == .running {
            let dir = GenerationJobDir(URL(fileURLWithPath: job.directory))
            if let out = dir.output {
                job.cost = out.cost ?? job.cost
                job.assetID = try Generate.importOutput(out, job, &project, &ctx, command: id)
                job.status = .done
            } else if let status = dir.exitStatus {
                let provider = try Generate.provider(job.request.provider, ctx, command: id)
                if status == 0 {
                    let out = try Generate.collect(provider, job.request, dir, cost: job.cost)
                    job.assetID = try Generate.importOutput(out, job, &project, &ctx, command: id)
                    job.status = .done
                } else {
                    job.status = .failed
                    job.error = "exit \(status): \(dir.stderrTail)"
                }
                provider.finish(keepRunning: false)
            }
            project.generations![i] = job
            ctx.project = project
        }
        return Generate.jobJSON(job, project)
    }
}

enum GenerateList: Command {
    static let id = "generate.list"
    static let summary = "List the generated assets of the project with their metadata (provider, model, prompt, seed, cost, created, source asset), the jobs, the paid budget left and the pending or approved estimates (approval tokens included). Returns {assets, jobs, budget, approvals}."
    static let kind = CommandKind.query
    static let params: [ParamSpec] = []

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let assets = project.assets.compactMap { a -> JSONValue? in
            guard let g = a.generated else { return nil }
            var o: [String: JSONValue] = ["assetId": .string(a.id), "path": .string(a.path), "provider": .string(g.provider), "model": .string(g.model),
                                          "kind": .string(g.kind.rawValue), "prompt": .string(g.prompt), "cost": .number(g.cost),
                                          "unit": .string(g.unit), "created": .string(g.created), "jobId": .string(g.jobID)]
            if let s = g.seed { o["seed"] = .number(Double(s)) }
            if let s = g.sourceAssetID { o["sourceAssetId"] = .string(s) }
            if let r = g.remoteID { o["remoteId"] = .string(r) }
            if let v = a.video { o["size"] = [.number(Double(v.width)), .number(Double(v.height))] }
            o["duration"] = .number(a.image?.kind == .still ? 0 : a.duration.seconds)
            return .object(o)
        }
        let budget = GenerationBudget(directory: ctx.services.generationState)
        var remaining: [String: JSONValue] = [:]
        for (k, _) in GenerationBudget.hardCaps { remaining[k] = (try? budget.remaining(k)).map { .number(Double($0)) } ?? "unreadable" }
        let approvals = ((try? GenerationApprovals(directory: ctx.services.generationState).load()) ?? []).suffix(10).map { e -> JSONValue in
            var o: [String: JSONValue] = ["estimateId": .string(e.estimate.estimateID), "status": .string(e.status.rawValue),
                                          "provider": .string(e.estimate.provider), "model": .string(e.estimate.model),
                                          "prompt": .string(e.estimate.prompt), "credits": .number(e.estimate.credits)]
            if e.status == .approved, let t = e.token { o["approval"] = .string(t) }
            return .object(o)
        }
        return ["assets": .array(assets), "jobs": .array((project.generations ?? []).map { Generate.jobJSON($0, project) }),
                "budget": .object(remaining), "approvals": .array(Array(approvals))]
    }
}
