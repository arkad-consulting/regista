import Foundation
import RegistaCore

/// The Generate panel from sample data for a render (ui.screenshot `generate`): sample providers read by the same
/// parser as generate.providers, and the state asked for. Nothing is run, priced or approved.
extension GenerateState {
    static let demoStates = ["still", "clip", "music", "upscale", "unavailable", "approval", "running", "failed", "recent"]

    /// `state`: still | clip | music | upscale (that kind ready to run), unavailable (a new Mac: no generator set up),
    /// approval (a paid clip waiting for the user's yes), running (a clip being generated), failed (what went wrong),
    /// recent (generations of the project listed). `kind` overrides the kind shown.
    @MainActor
    static func demo(_ state: String, kind: String? = nil, store: EditorStore) -> GenerateState {
        let m = GenerateState(store: store)
        m.isDemo = true
        let ready = state != "unavailable"
        m.providersForDemo(GenProvider.parse(sampleProviders(ready: ready)))
        let k = GenKind(rawValue: kind ?? "") ?? GenKind(rawValue: state) ?? (["approval", "running", "failed"].contains(state) ? .clip : .still)
        m.kind = k
        m.prompts[k] = k.ideas.first.map { loc($0) } ?? ""
        let project = store.project
        if k == .upscale {
            m.upscaleAsset = project?.assets.first { $0.video != nil && $0.image == nil && UpscaleReason.of($0) == nil }?.id
        }
        if ready, !(k == .clip && state == "approval") {
            m.estimateForDemo(GenEstimate(id: "e-sample", provider: "comfyui", model: "", credits: 0,
                                          seconds: [.still: 35, .clip: 300, .music: 70, .upscale: 240][k], paid: false))
        }
        switch state {
        case "approval":
            m.chosen[.clip] = "higgsfield"
            if let r = m.request(.clip) {
                m.pendingForDemo(GenPending(request: r, estimate: GenEstimate(id: "e-sample", provider: "higgsfield", model: "seedance1_5",
                                                                             credits: 2.4, paid: true, budgetRemaining: 2)))
            }
        case "running":
            m.demoJob = JobCenter.Job(id: UUID(), kind: jobKind, title: GenKind.clip.jobTitle,
                                      detail: String(format: loc("%@ · %@"), "ComfyUI", GenWords.duration(300)), progress: 0.36,
                                      cancellable: true, started: Date() - 108)
        case "failed":
            m.demoJob = JobCenter.Job(id: UUID(), kind: jobKind, title: GenKind.clip.jobTitle, detail: "", progress: nil,
                                      state: .failed(GenWords.readable(CommandError(.io, "generate.run: comfyui failed (exit 1):"))),  // l10n-ignore
                                      cancellable: true, started: Date() - 40)
        case "recent":
            m.recentForDemo(sampleRecent(project))
            m.scrollToRecent = true
        default: break
        }
        if state != "recent", ready { m.recentForDemo(Array(sampleRecent(project).prefix(2))) }
        return m
    }

    /// generate.providers as a Mac with ComfyUI set up and a Higgsfield account would answer, or (`ready` false) a new
    /// Mac without either.
    static func sampleProviders(ready: Bool) -> JSONValue {
        func kinds(_ ks: [String], why: String, engine: String) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: ks.map { ($0, ready ? ["available": true] : ["available": false, "reason": "-", "why": .string(why), "engine": .string(engine)]) }))
        }
        func formats(_ f: [(String, Int, Int)]) -> JSONValue { .array(f.map { ["name": .string($0.0), "size": [.number(Double($0.1)), .number(Double($0.2))]] }) }
        let comfy = ComfyUIProvider(config: EngineConfig()), hf = HiggsfieldProvider(config: EngineConfig())
        func fs(_ p: GeneratorProvider, _ k: GenerationKind) -> JSONValue { formats(p.formats(k).map { ($0.name, $0.width, $0.height) }) }
        return ["tier": "pro", "providers": [
            ["id": "comfyui", "paid": false, "minimumTier": "pro", "kinds": kinds(["image", "video", "music", "upscale"], why: "setup", engine: "comfyui"),
             "formats": ["image": fs(comfy, .image), "video": fs(comfy, .video)],
             "models": .array(comfy.models.map { ["id": .string($0.id), "kind": .string($0.kind.rawValue)] })],
            ["id": "higgsfield", "paid": true, "minimumTier": "base", "kinds": kinds(["image", "video"], why: "setup", engine: "higgsfield"),
             "formats": ["image": fs(hf, .image), "video": fs(hf, .video)], "budgetRemaining": 2, "budgetCap": 2,
             "models": .array(hf.models.map { ["id": .string($0.id), "kind": .string($0.kind.rawValue)] })],
            ["id": "voxcpm", "paid": false, "minimumTier": "medium", "kinds": ["voice": ["available": true]], "models": []],
        ]]
    }

    /// Four recent generations, drawn with the project's own files where it has them (so the thumbnails show).
    static func sampleRecent(_ p: Project?) -> [GenRecent] {
        let still = p?.assets.first { $0.image?.kind == .still }?.id ?? "a-still"   // l10n-ignore: sample ids
        let clip = p?.assets.first { $0.video != nil && $0.image == nil }?.id ?? "a-clip"   // l10n-ignore
        let music = p?.assets.first { $0.video == nil && $0.audio != nil }?.id ?? "a-music"   // l10n-ignore
        let now = Date()
        return [
            GenRecent(assetID: clip, kind: .clip, provider: "comfyui", prompt: loc(GenKind.clip.ideas[0]), cost: 0, paid: false, created: now - 240, duration: 3),
            GenRecent(assetID: still, kind: .still, provider: "comfyui", prompt: loc(GenKind.still.ideas[0]), cost: 0, paid: false, created: now - 900, duration: 0),
            GenRecent(assetID: music, kind: .music, provider: "comfyui", prompt: loc(GenKind.music.ideas[2]), cost: 0, paid: false, created: now - 3600, duration: 30),
            GenRecent(assetID: still + "-2", kind: .still, provider: "higgsfield", prompt: loc(GenKind.still.ideas[1]), cost: 0.15, paid: true, created: now - 7200, duration: 0),
        ]
    }
}
