import AppKit
import CoreGraphics
import Foundation
import ImageIO
@testable import RegistaCore
import RegistaEngines
import Testing
@testable import Regista

// G1 (#5): the Genera panel. Its own calls (GenerateState builds the request, GenerateFlow runs it: the same code the
// panel's button runs inside a job) on a headless engine whose generators are stand-ins — a local one and a paid one
// registered as "higgsfield" so the real budget rules apply. The real Higgsfield provider is never registered: no test
// reaches it. Scratch folders only (budget, approvals, cache).

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-generate-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A real 72×128 PNG (the engine probes what it imports).
private func png(in dir: URL) throws -> URL {
    let url = dir.appendingPathComponent("still.png")
    let ctx = CGContext(data: nil, width: 72, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 72, height: 128))
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(dest))
    return url
}

/// A stand-in provider: its job copies a PNG as the result and counts its runs.
private struct StandIn: GeneratorProvider {
    var id: String
    var paid: Bool
    let source: URL
    let runs: URL
    var title: String { id }
    var minimumTier = MachineTier.base
    var models = [GeneratorModel("stand-in-still", .image, "test", isDefault: true), GeneratorModel("stand-in-clip", .video, "test", isDefault: true)]

    func unavailableReason(_ kind: GenerationKind) -> String? { nil }
    func estimate(_ request: GenerationRequest) throws -> Double { paid ? 2.4 : 0 }
    func seconds(_ request: GenerationRequest, sourceSeconds: Double?) -> Double? { paid ? nil : 1 }
    func formats(_ kind: GenerationKind) -> [GenerationFormat] { [.init("9:16", 720, 1280), .init("1:1", 1024, 1024), .init("16:9", 1280, 720)] }
    func process(_ request: GenerationRequest, job: URL) throws -> GenerationProcess {
        GenerationProcess(URL(fileURLWithPath: "/bin/sh"),
                          ["-c", "echo run >> '\(runs.path)'; cp '\(source.path)' result.png; echo '{\"files\": [\"result.png\"]}'"])
    }
    func collect(_ request: GenerationRequest, job: URL, stdout: String) throws -> GenerationOutput {
        GenerationOutput(file: job.appendingPathComponent("result.png").path, model: model(for: request), seed: 1)
    }

    var runCount: Int { ((try? String(contentsOf: runs, encoding: .utf8)) ?? "").split(separator: "\n").count }
}

private struct Fixture {
    let engine: Engine
    let local: StandIn
    let paid: StandIn
    let state: URL

    init() throws {
        let dir = tempDir()
        let source = try png(in: dir)
        local = StandIn(id: "local-test", paid: false, source: source, runs: dir.appendingPathComponent("local-runs"))
        paid = StandIn(id: "higgsfield", paid: true, source: source, runs: dir.appendingPathComponent("paid-runs"))
        var s = EngineServices.live()
        s.config.cacheDirectory = tempDir().path
        s.generators = [local.id: local, paid.id: paid]
        state = tempDir()
        s.generationState = state
        s.profiles = ProfileStore(directory: tempDir())
        engine = Engine(services: s)
        try engine.execute("project.new", params: ["name": "genera", "directory": .string(tempDir().path)])
    }

    /// The panel's flow on this engine.
    @MainActor var flow: GenerateFlow { GenerateFlow(perform: { [engine] in try engine.execute($0.id, params: $0.params) }) }

    /// The panel's state, its providers read from generate.providers.
    @MainActor func panel() throws -> GenerateState {
        let p = GenerateState(store: nil)
        p.providersForDemo(GenProvider.parse(try engine.execute("generate.providers")))
        return p
    }

    var budget: Int { (try? GenerationBudget(directory: state).remaining("higgsfield")) ?? -1 }
}

@MainActor
@Test func aLocalGenerationFromThePanelLandsInMediaAndInTheList() async throws {
    let f = try Fixture()
    let panel = try f.panel()
    panel.kind = .still
    panel.prompts[.still] = loc(GenKind.still.ideas[0])
    let r = try #require(panel.request())
    #expect(r.provider == "local-test")                       // local first, even with a paid provider listed
    #expect(r.format == GenerationFormat("9:16", 720, 1280))  // the project's format (a new project is 9:16)
    #expect(r.missing == nil)

    guard case .done(let result) = try await f.flow.start(r) else { Issue.record("a free run asked for approval"); return }
    #expect(f.local.runCount == 1)
    let asset = try #require(f.engine.project?.asset(result.assetID))
    #expect(asset.generated?.prompt == r.prompt)
    #expect(asset.path.contains("/media/generated/"))
    #expect(asset.image?.kind == .still)
    var recent = GenRecent.parse(try f.engine.execute(GenerateCalls.list.id))
    #expect(recent.map(\.assetID) == [result.assetID])
    #expect(recent.first?.kind == .still && recent.first?.prompt == r.prompt && recent.first?.paid == false)

    // Undo takes the file out of Media and of the list; redo puts it back; the same request again is the cached file.
    try f.engine.execute("history.undo")
    #expect(f.engine.project?.asset(result.assetID) == nil)
    #expect(GenRecent.parse(try f.engine.execute(GenerateCalls.list.id)).isEmpty)
    try f.engine.execute("history.redo")
    #expect(f.engine.project?.asset(result.assetID) != nil)
    guard case .done(let again) = try await f.flow.start(r) else { Issue.record("no result"); return }
    #expect(again.cached)
    #expect(f.local.runCount == 1)

    // "Usa di nuovo" puts the words, the kind and the provider back.
    recent = GenRecent.parse(try f.engine.execute(GenerateCalls.list.id))
    panel.prompts[.still] = ""
    panel.kind = .music
    panel.useAgain(try #require(recent.first))
    #expect(panel.kind == .still && panel.prompts[.still] == r.prompt && panel.chosen[.still] == "local-test")

    // Another project format picks the provider's matching format.
    #expect(GenOffer.format(f.local.formats(.image), width: 1920, height: 1080)?.name == "16:9")
    #expect(GenOffer.format(f.local.formats(.image), width: 1080, height: 1350)?.name == "1:1")   // 4:5 is nearest to 1:1 among these
}

@MainActor
@Test func aPaidRunWithoutApprovalStaysBlockedAndNeverReachesTheProvider() async throws {
    let f = try Fixture()
    #expect(!(f.engine.context.services.generators["higgsfield"] is HiggsfieldProvider))   // a stand-in, never the real one
    let panel = try f.panel()
    panel.kind = .still
    panel.prompts[.still] = "a hero shot"
    panel.chosen[.still] = "higgsfield"
    let r = try #require(panel.request())
    #expect(r.provider == "higgsfield")

    // Start: the estimate shows the cost, and the run waits.
    guard case .needsApproval(let e) = try await f.flow.start(r) else { Issue.record("a paid run started without approval"); return }
    #expect(e.credits == 2.4 && e.paid && e.needsApproval)
    #expect(f.paid.runCount == 0)
    // Asked to run anyway without an approval: refused by the flow, nothing reaches the provider or the budget.
    await #expect(throws: GenerateBlocked.self) { _ = try await f.flow.run(r, estimate: e, approval: nil) }
    #expect(f.paid.runCount == 0)
    #expect(f.budget == 2)
    // The engine refuses it too (a generate.run without a token, as a buggy panel would send).
    #expect(throws: CommandError.self) { try f.engine.execute(r.runCall(approval: nil).id, params: r.runCall(approval: nil).params) }
    #expect(f.paid.runCount == 0)

    // Approved on the card: the run reaches the stand-in once, costs its credits, takes one call off the budget.
    let approval = try await f.flow.approve(e)
    let result = try await f.flow.run(r, estimate: e, approval: approval)
    #expect(f.paid.runCount == 1)
    #expect(result.cost == 2.4)
    #expect(f.budget == 1)
    #expect(f.engine.project?.asset(result.assetID)?.generated?.unit == "credits")

    // Nothing is remembered as "always allow": the next paid request needs its own approval.
    var r2 = r
    r2.prompt = "another hero shot"
    guard case .needsApproval(let e2) = try await f.flow.start(r2) else { Issue.record("the second paid run did not ask"); return }
    await #expect(throws: GenerateBlocked.self) { _ = try await f.flow.run(r2, estimate: e2, approval: approval) }
    #expect(f.paid.runCount == 1)
    // A declined estimate cannot be approved afterwards.
    try await f.flow.decline(e2)
    await #expect(throws: (any Error).self) { _ = try await f.flow.approve(e2) }
    #expect(f.paid.runCount == 1)
    #expect(f.budget == 1)
}

/// Every provider × kind generate.providers reports is in the panel: under its kind (or, for the voice-over, as the
/// pointer to the Voce panel), available, or greyed with a reason in words and the engine to install or set up.
@MainActor
@Test func everyProviderAndKindIsShownAvailableOrDisabledWithAReason() throws {
    let dir = tempDir()
    for tier in [MachineTier.medium, .pro] {
        var config = EngineConfig()
        config.cacheDirectory = tempDir().path
        config.comfyServer = "http://127.0.0.1:9"   // nothing answers, no ComfyUI folder set or looked for
        config.higgsfield = dir.appendingPathComponent("missing/higgsfield").path   // set and missing: no PATH search, no call
        var s = EngineServices.live()
        s.config = config
        s.tier = tier
        let standIn = StandIn(id: "local-test", paid: false, source: try png(in: tempDir()), runs: dir.appendingPathComponent("runs"))
        s.generators = ["comfyui": ComfyUIProvider(config: config, places: []), "higgsfield": HiggsfieldProvider(config: config),
                        "voxcpm": VoxCPMProvider(config: config, profiles: ProfileStore(directory: tempDir())), standIn.id: standIn]
        s.generationState = tempDir()
        let json = try Engine(services: s).execute("generate.providers")
        let parsed = GenProvider.parse(json)
        var seen = 0
        for p in json["providers"]?.arrayValue ?? [] {
            let id = try #require(p["id"]?.stringValue)
            for (k, v) in p["kinds"]?.objectValue ?? [:] {
                let kind = try #require(GenerationKind(rawValue: k))
                let row: GenProvider? = GenKind(kind).map { GenOffer.rows(parsed, $0) }?.first { $0.id == id }
                    ?? GenOffer.elsewhere(parsed).first { $0.provider.id == id && $0.kind == kind }?.provider
                let shown = try #require(row, "\(id) × \(k) is not in the panel")
                let a = shown.availability(kind)
                #expect(a.available == (v["available"]?.boolValue == true), "\(id) × \(k)")
                if !a.available {
                    let reason = try #require(a.reason, "\(id) × \(k) is greyed without a reason")
                    #expect(!reason.isEmpty && reason != v["reason"]?.stringValue, "\(id) × \(k): the engine's words")
                    #expect(a.engine == v["engine"]?.stringValue, "\(id) × \(k): no install / setup action")
                }
                seen += 1
            }
        }
        #expect(seen == 9)   // ComfyUI 4 kinds, Higgsfield 2, VoxCPM2 1, the stand-in 2
        // Local first under every kind.
        for k in GenKind.allCases {
            let rows = GenOffer.rows(parsed, k)
            #expect(rows.map(\.paid) == rows.map(\.paid).sorted { !$0 && $1 })
        }
        let comfy = try #require(parsed.first { $0.id == "comfyui" })
        #expect(comfy.availability(.image).reason == (tier == .medium ? String(format: loc("Serve un Mac con almeno %@ GB di memoria."), "32")
                                                                         : loc("ComfyUI non è installato su questo Mac.")))
        #expect(parsed.first { $0.id == "higgsfield" }?.availability(.video).setup == true)
        // With nothing else ready, the stand-in is what a run would use.
        let panel = GenerateState(store: nil)
        panel.providersForDemo(parsed)
        #expect(panel.request(.still)?.provider == "local-test")
    }
}

/// A ComfyUI model generate.check finds incomplete is greyed with the reason and "Prepara…".
@Test func aComfyModelMissingFilesIsGreyedWithTheSetupAction() {
    let providers: JSONValue = ["tier": "pro", "providers": [["id": "comfyui", "paid": false,
        "kinds": ["image": ["available": true], "video": ["available": true]],
        "models": [["id": "z-image-turbo", "kind": "image"], ["id": "wan2.2-i2v-14b-lightning", "kind": "video"]]]]]
    let check: JSONValue = ["models": [["model": "z-image-turbo", "state": "ready"], ["model": "wan2.2-i2v-14b-lightning", "state": "missing"]]]
    let p = GenProvider.parse(providers, check: check)[0]
    #expect(p.availability(.image).available)
    #expect(!p.availability(.video).available)
    #expect(p.availability(.video).setup && p.availability(.video).engine == "comfyui")
}

/// The render states draw what they say (ui.screenshot `generate`).
@MainActor
@Test func theSampleStatesOfThePanel() {
    _ = NSApplication.shared
    let d = TestDefaults.make("generate-tests")
    defer { TestDefaults.end(d) }
    let store = Workbench(defaults: d, seedFolders: [], socketPath: nil).newTab()
    for s in GenerateState.demoStates { #expect(!GenerateState.demo(s, store: store).providers.isEmpty, "\(s)") }
    let approval = GenerateState.demo("approval", store: store)
    #expect(approval.pending?.estimate.credits == 2.4 && approval.pending?.request.provider == "higgsfield")
    let none = GenerateState.demo("unavailable", store: store)
    #expect(GenKind.allCases.allSatisfy { k in GenOffer.rows(none.providers, k).allSatisfy { !$0.availability(k.engineKind).available && $0.availability(k.engineKind).engine != nil } })
    #expect(none.request() == nil)
    #expect(GenerateState.demo("running", store: store).demoJob?.isRunning == true)
    #expect(GenerateState.demo("recent", store: store).recent.count == 4)
}

/// #43: a waiting paid estimate stands while the panel asks for the request it was made for (the panel reading its
/// providers again calls changed() too), and goes when the prompt, the generator or a parameter changes.
@MainActor
@Test func aWaitingEstimateStaysForTheSameRequestOnly() throws {
    let f = try Fixture()
    func waiting() throws -> GenerateState {
        let panel = try f.panel()
        panel.kind = .clip
        panel.prompts[.clip] = "La camera si avvicina piano"
        panel.chosen[.clip] = "higgsfield"
        let r = try #require(panel.request())
        #expect(r.provider == "higgsfield")
        panel.pendingForDemo(GenPending(request: r, estimate: GenEstimate(id: "e-test", provider: "higgsfield", model: "m", credits: 2.4, paid: true,
                                                                          budgetRemaining: 2), asked: r))
        return panel
    }
    let same = try waiting()
    same.changed()
    #expect(same.pending != nil, "the same request declined the estimate")
    let prompt = try waiting()
    prompt.prompts[.clip] = "Un leggero zoom indietro"
    prompt.changed()
    #expect(prompt.pending == nil, "a new prompt kept the estimate")
    let model = try waiting()
    model.chosen[.clip] = "local-test"
    #expect(model.request()?.provider == "local-test")
    model.changed()
    #expect(model.pending == nil, "another generator kept the estimate")
    let length = try waiting()
    length.durations[.clip] = try #require(length.durationOptions(.clip).last { $0 != length.duration(.clip) })
    length.changed()
    #expect(length.pending == nil, "another length kept the estimate")
    let kind = try waiting()
    kind.kind = .still
    kind.changed()
    #expect(kind.pending == nil, "another kind kept the estimate")
}

// #43: a paid estimate waiting on the approval card stands while the panel asks for the same thing — the panel going
// away and coming back, a tab switch and back — and is declined as soon as the request changes (the prompt, the
// generator, a parameter). Real clicks on the whole window; the rig's paid stand-in prices at a fixed cost and can
// start no job.
extension MouseSuites {
@Suite(.serialized) @MainActor struct GenerateApprovalMouseTests {
    @Test func aWaitingPaidEstimateSurvivesThePanelComingBackAndGoesWhenTheRequestChanges() async throws {
        let app = try await AppRig()
        defer { app.close() }
        // A taller window: the card sits under the form, past the bottom of a 900 pt window.
        app.hostEditor(Navigation(activity: .generate, rightTab: .inspector), size: CGSize(width: 1440, height: 1300))
        await app.idle(0.5)   // the panel's first reading
        let g = app.store.generation
        func until(_ seconds: Double = 4, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        func control(_ name: String) -> RigElement? {
            app.rig.elements().first { $0.isControl && $0.visible && ($0.label == name || $0.label.hasPrefix(name + ",") || $0.title == name) }
        }
        func activity(_ name: String) throws -> RigElement {
            try #require(app.rig.elements().first { $0.isControl && $0.label == name && $0.frame.maxX < 60 }, "no «\(name)» in the activity bar")
        }
        var card: Bool { app.rig.elements().contains { $0.isControl && $0.visible && $0.name.hasPrefix("Approva e spendi") } }
        /// Asks the paid stand-in for a price with the panel's «Genera…»: the approval card comes up.
        func price() async throws -> GenPending {
            g.kind = .still
            g.prompts = [.still: "Una sedia rossa in una stanza bianca"]
            g.chosen = [.still: "higgsfield"]
            g.formats = [:]
            g.durations = [:]
            await app.settle()
            // The paid generator's «Genera…», named by its tooltip.
            app.rig.click(try #require(control("Prima vedi il costo, poi decidi"), "no «Genera…» for the paid generator").centre)
            #expect(await until { g.pending != nil }, "no estimate: \(g.problem ?? "")")
            await app.settle()
            #expect(card, "no approval card")
            return try #require(g.pending)
        }
        func declined(since n: Int) -> Bool { app.commands(since: n).contains("generate.approve") }

        // The panel goes away (another activity) and comes back.
        let estimate = try await price()
        var n = app.store.activity.count
        app.rig.click(try activity("Media").centre)
        await app.settle()
        #expect(app.store.nav.activity == .media)
        app.rig.click(try activity("Genera").centre)
        await app.settle()
        await app.idle(0.5)   // the panel reads its providers again
        #expect(app.store.nav.activity == .generate)
        #expect(g.pending == estimate && card && !declined(since: n), "the estimate did not survive the panel coming back (\(app.commands(since: n)))")

        // The panel rebuilt from scratch (every view's own state).
        app.reset.bump()
        await app.settle()
        await app.idle(0.5)
        #expect(g.pending == estimate && card && !declined(since: n), "the estimate did not survive the panel being rebuilt")

        // Another tab and back.
        app.rig.click(try #require(app.rig.element("Nuova scheda"), "no + in the tab strip").centre)
        await app.settle()
        #expect(app.store.bench.active !== app.store, "+ did not open another tab")
        // A tab's name reads as itself (#32).
        let tab = try #require(app.rig.elements().filter { $0.role == "AXStaticText" && $0.name == "clicks" && $0.visible && $0.frame.minY < 90 }
            .min { $0.frame.minX < $1.frame.minX }, "no tab of the project")
        app.rig.click(tab.centre)
        await app.settle()
        await app.idle(0.5)
        #expect(app.store.bench.active === app.store && app.store.nav.activity == .generate, "the project's tab did not come back on Genera")
        #expect(g.pending == estimate && card && !declined(since: n), "the estimate did not survive a tab switch and back (\(app.commands(since: n)))")

        // The prompt changes (one of the ideas under it): declined.
        n = app.store.activity.count
        app.rig.click(try #require(control("Usa questa idea: poi la puoi cambiare"), "no idea under the prompt").centre)
        #expect(await until { g.pending == nil && declined(since: n) }, "a new prompt did not decline the estimate (\(app.commands(since: n)))")
        await app.settle()
        #expect(!card, "the card stayed after the prompt changed")

        // A click on a generator that cannot run here (ComfyUI is not ready in the rig) leaves the request as it was: the
        // estimate stays. (The rig offers no second generator that can run: another generator declining it is proven
        // in aWaitingEstimateStaysForTheSameRequestOnly.)
        let again = try await price()
        n = app.store.activity.count
        app.rig.click(try #require(control("ComfyUI"), "no ComfyUI row").centre)
        await app.settle()
        #expect(g.request()?.provider == "higgsfield" && g.pending == again && !declined(since: n), "a generator that cannot run changed the request")

        // A parameter changes (the format): declined.
        n = app.store.activity.count
        let other = try #require(["1:1", "16:9", "4:5"].lazy.compactMap { control($0) }.first { !$0.selected }, "no other format chip")
        app.rig.click(other.centre)
        #expect(await until { g.pending == nil && declined(since: n) }, "another format did not decline the estimate (\(app.commands(since: n)))")
        #expect(g.formats[.still] != nil, "the format chip did not change the format")
    }
}
}
