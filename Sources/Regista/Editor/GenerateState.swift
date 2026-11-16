import Foundation
import RegistaCore

/// A paid estimate on screen, waiting for the user's yes or no: the request it prices and its cost.
struct GenPending: Equatable {
    var request: GenRequest
    var estimate: GenEstimate
    /// The panel's request when the price was asked (before the monitor's frame became a file): while the panel asks
    /// for the same thing, the estimate stands (#43).
    var asked: GenRequest?
}

/// The Generate panel of one tab: what is being asked for (kind, words, provider, format, length, start frame or clip),
/// what this Mac offers, the recent generations, and a paid estimate waiting for approval. Every action is a command
/// through the tab's store (`GenerateFlow` inside a job for the runs, quiet queries for what is only read).
@MainActor
final class GenerateState: ObservableObject {
    weak var store: EditorStore?
    @Published var kind: GenKind = .still
    @Published var prompts: [GenKind: String] = [:]
    /// The provider chosen per kind (nil: the first that can run, local first).
    @Published var chosen: [GenKind: String] = [:]
    @Published var formats: [GenKind: String] = [:]
    @Published var durations: [GenKind: Double] = [:]
    /// The start frame of a clip: an image of Media, or nil for the monitor's frame at the playhead.
    @Published var startAsset: String?
    @Published var upscaleAsset: String?
    @Published private(set) var providers: [GenProvider] = []
    @Published private(set) var recent: [GenRecent] = []
    /// The time a local run takes (generate.estimate, read quietly while the request changes).
    @Published private(set) var estimate: GenEstimate?
    @Published private(set) var pending: GenPending?
    /// A paid estimate is being asked for.
    @Published private(set) var pricing = false
    /// Why the last paid estimate could not be made, in words.
    @Published var problem: String?
    @Published private(set) var loaded = false
    /// A render's sample job (ui.screenshot `generate`).
    var demoJob: JobCenter.Job?
    var isDemo = false
    /// A render scrolled to the recent generations.
    var scrollToRecent = false
    private var estimateTask: Task<Void, Never>?

    /// The start frame placeholder of a request until the monitor's frame is rendered to a file (`prepare`).
    static let monitorFrame = "@monitor"
    static let jobKind = "generate"

    init(store: EditorStore?) { self.store = store }

    // MARK: What is asked for

    func provider(_ k: GenKind) -> GenProvider? { GenOffer.pick(providers, k, chosen: chosen[k]) }

    func formatOptions(_ k: GenKind) -> [GenerationFormat] { provider(k)?.formats[k.engineKind] ?? [] }

    /// The format chosen, else the one closest to the project's (9:16 when there is no project).
    func format(_ k: GenKind) -> GenerationFormat? {
        let options = formatOptions(k)
        if let name = formats[k], let f = options.first(where: { $0.name == name }) { return f }
        let s = store?.project?.settings
        return GenOffer.format(options, width: s?.width ?? 1080, height: s?.height ?? 1920)
    }

    func durationOptions(_ k: GenKind) -> [Double] { GenOffer.durations(provider(k)?.id, k) }

    func duration(_ k: GenKind) -> Double? {
        let options = durationOptions(k)
        if let d = durations[k], options.contains(d) { return d }
        // A paid clip starts at its shortest (cheapest) length; a free one in the middle.
        return options.isEmpty ? nil : provider(k)?.paid == true ? options[0] : options[options.count / 2]
    }

    /// The request the panel would send now (nil: no provider can make this kind here).
    func request(_ k: GenKind? = nil) -> GenRequest? {
        let k = k ?? kind
        guard let p = provider(k) else { return nil }
        var r = GenRequest(kind: k, provider: p.id, prompt: prompts[k] ?? "", format: format(k), duration: duration(k))
        if k == .clip { r.start = startAsset ?? ((store?.project?.duration ?? .zero) > .zero || isDemo ? Self.monitorFrame : nil) }
        if k == .upscale { r.assetID = upscaleAsset }
        return r
    }

    var jobRunning: Bool { demoJob?.isRunning ?? store?.jobs.latest(Self.jobKind)?.isRunning ?? false }

    // MARK: Reading

    /// generate.providers, generate.check (ComfyUI only: it asks the local server, never starts it) and generate.list.
    func refresh() async {
        guard let store, !isDemo else { return }
        if let p = try? await store.silent(GenerateCalls.providers.id) {
            var check: JSONValue?
            if p["providers"]?.arrayValue?.contains(where: { $0["id"] == "comfyui" && $0["kinds"]?.objectValue?.values.contains { $0["available"] == true } == true }) == true {
                check = try? await store.silent(GenerateCalls.check.id)
            }
            providers = GenProvider.parse(p, check: check)
        }
        loaded = true
        await refreshList()
        changed()
    }

    func refreshList() async {
        guard let store, !isDemo else { return }
        guard store.project != nil, let l = try? await store.silent(GenerateCalls.list.id) else { recent = []; return }
        recent = GenRecent.parse(l)
    }

    /// The request may have changed: a waiting paid estimate made for another request is declined (the same request —
    /// the panel appearing again, a tab switch and back — keeps it, #43), the local time is read again.
    func changed() {
        if let p = pending, p.asked == nil || p.asked != request() { decline() }
        problem = nil
        estimateTask?.cancel()
        guard let store, !isDemo, store.project != nil, var r = request(), let p = provider(kind), !p.paid else { estimate = nil; return }
        if r.kind.hasPrompt, r.prompt.trimmingCharacters(in: .whitespaces).isEmpty { r.prompt = "-" }
        if r.start == Self.monitorFrame { r.start = nil }   // the time does not depend on the frame
        if r.kind == .upscale, r.assetID == nil { estimate = nil; return }
        let call = r.estimateCall
        estimateTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let j = try? await store.silent(call.id, call.params) else { return }
            self?.estimate = GenEstimate(j)
        }
    }

    // MARK: Running

    /// "Genera": a free run starts as a job at once; a paid one is priced first and waits for the user's approval.
    func generate() {
        guard let r = request(), r.missing == nil, !jobRunning, let p = provider(r.kind) else { return }
        if p.paid { price(r) } else { start(r, estimate: nil, approved: false) }
    }

    private func price(_ request: GenRequest) {
        guard let store else { return }
        pricing = true
        problem = nil
        // The panel shows its own approval card: the window's sheet (for an agent's request) stays away, also while the
        // estimate is being made (generate.estimate records the pending approval before the panel knows its id).
        store.bench.panelPricing += 1
        Task {
            defer { pricing = false }
            do {
                let r: GenRequest, e: GenEstimate
                do {
                    r = try await prepare(request)
                    e = try await GenerateFlow(perform: { try await store.perform($0.id, $0.params) }).estimate(r)
                } catch {
                    store.bench.panelPricing -= 1
                    throw error
                }
                store.bench.panelEstimates.insert(e.id)
                store.bench.panelPricing -= 1
                store.refreshApprovals()
                if e.needsApproval { pending = GenPending(request: r, estimate: e, asked: request) } else { start(r, estimate: e, approved: false) }
            } catch {
                problem = GenWords.readable(error)
            }
        }
    }

    /// The approval card's "Approva e spendi": generate.approve for that estimate, then the run, as one job.
    func approve() {
        guard let p = pending else { return }
        pending = nil
        start(p.request, estimate: p.estimate, approved: true)
    }

    /// "Rifiuta" (or the request changed): the estimate is declined and nothing is spent.
    func decline() {
        guard let p = pending, let store else { pending = nil; return }
        pending = nil
        Task { _ = try? await GenerateFlow(perform: { try await store.perform($0.id, $0.params) }).decline(p.estimate) }
    }

    /// The monitor's frame becomes an image file (frame.render) when the clip starts from it.
    private func prepare(_ request: GenRequest) async throws -> GenRequest {
        guard request.start == Self.monitorFrame, let store else { return request }
        var r = request
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-start-frames", isDirectory: true)
        let path = dir.appendingPathComponent("frame-\(UUID().uuidString.prefix(8)).png").path
        let call = GenerateCalls.frame(at: store.preview.time, path: path)
        r.start = try await store.perform(call.id, call.params)["path"]?.stringValue ?? path
        return r
    }

    /// The run as a job of the tab: estimate (unless priced already), approval when paid, then generate.run; the
    /// progress follows the estimated time; Cancel stops the generation; the result lands in Media and in the recent list.
    private func start(_ request: GenRequest, estimate known: GenEstimate?, approved: Bool) {
        guard let store else { return }
        let name = provider(request.kind)?.name ?? request.provider
        store.startJob(kind: Self.jobKind, title: request.kind.jobTitle) { [weak self] h, job in
            let flow = GenerateFlow(perform: { [weak store] call in
                guard let store else { throw CancellationError() }
                return try await store.performInJob(call, job)
            })
            do {
                h.update(detail: loc("Preparo…"))
                var r = request
                if known == nil { r = try await self?.prepare(r) ?? r }
                let e: GenEstimate
                if let known { e = known } else { e = try await flow.estimate(r) }
                if e.needsApproval, !approved { throw GenerateBlocked(estimate: e) }
                let approval = approved && e.needsApproval ? try await flow.approve(e) : nil
                h.update(detail: e.seconds.map { String(format: loc("%@ · %@"), name, GenWords.duration($0)) } ?? name)
                let started = Date()
                let ticker = Task { @MainActor in
                    while !Task.isCancelled, let s = e.seconds, s > 0 {
                        h.update(progress: min(0.9, Date().timeIntervalSince(started) / s))
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                defer { ticker.cancel() }
                let result = try await flow.run(r, estimate: e, approval: approval)
                h.update(detail: result.cached ? loc("Era già pronto: è in Media.") : loc("Fatto: è in Media."))
                if store.project?.asset(result.assetID)?.video != nil { store.sourceAssetID = result.assetID }
                await self?.refreshList()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw StepError(message: GenWords.readable(error))
            }
        }
    }

    // A render's sample state (GenerateDemo.swift).
    func providersForDemo(_ p: [GenProvider]) { providers = p; loaded = true }
    func estimateForDemo(_ e: GenEstimate) { estimate = e }
    func pendingForDemo(_ p: GenPending) { pending = p }
    func recentForDemo(_ r: [GenRecent]) { recent = r }

    /// "Usa di nuovo": the kind, the words and the provider of a recent generation, ready to run again or change.
    func useAgain(_ g: GenRecent) {
        guard let k = g.kind else { return }
        kind = k
        if k.hasPrompt { prompts[k] = g.prompt }
        if providers.contains(where: { $0.id == g.provider }) { chosen[k] = g.provider }
        changed()
    }
}

extension EditorStore {
    /// "1 h fa" style ages for the recent list, in the app's language.
    static let ageFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        return f
    }()
}
