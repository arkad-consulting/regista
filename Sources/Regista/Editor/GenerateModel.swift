import Foundation
import RegistaCore

// G1 (#5): the Generate panel — a still from a prompt, a clip from a start frame, music, an upscale. What exists comes
// from generate.providers (and generate.check for ComfyUI); every run is generate.estimate first, then generate.run /
// generate.upscale as a job of the tab. A paid run needs the user's approval of that estimate, every time: the flow
// below refuses to call the provider without a token from generate.approve for exactly that estimate, and the engine
// refuses it too. The calls live here (`GenerateCalls`, `GenerateFlow`), so the panel and the tests run the same ones.

/// What the panel makes, in its order.
enum GenKind: String, CaseIterable, Identifiable {
    case still, clip, music, upscale
    var id: String { rawValue }

    var engineKind: GenerationKind {
        switch self {
        case .still: .image
        case .clip: .video
        case .music: .music
        case .upscale: .upscale
        }
    }

    init?(_ kind: GenerationKind) {
        guard let k = Self.allCases.first(where: { $0.engineKind == kind }) else { return nil }
        self = k
    }

    /// Lookup keys.
    var title: String {
        switch self {
        case .still: "Immagine"
        case .clip: "genKind.clip"
        case .music: "Musica"
        case .upscale: "genKind.upscale"
        }
    }

    var symbol: String {
        switch self {
        case .still: "photo"
        case .clip: "film"
        case .music: "music.note"
        case .upscale: "arrow.up.left.and.arrow.down.right"
        }
    }

    var purpose: String {
        switch self {
        case .still: "Un'immagine da una descrizione: uno sfondo, un dettaglio, il primo fotogramma di una clip."
        case .clip: "Una clip di pochi secondi che parte da un'immagine e si muove come descrivi."
        case .music: "Una musica di sottofondo, senza voce, della durata che scegli."
        case .upscale: "Una clip generata diventa più nitida e più grande, a 30 fotogrammi al secondo."
        }
    }

    var placeholder: String {
        switch self {
        case .still: "Descrivi l'immagine: cosa si vede, la luce, i colori"
        case .clip: "Descrivi il movimento: cosa si muove e come si muove la camera"
        case .music: "Descrivi la musica: l'atmosfera, gli strumenti, il ritmo"
        case .upscale: ""
        }
    }

    /// Three or four plain starting points (lookup keys).
    var ideas: [String] {
        switch self {
        case .still: ["Una scrivania ordinata con un portatile, luce del mattino", "Una città di notte vista dall'alto, luci sfocate",
                      "Mani che scrivono su un taccuino, primo piano", "Uno sfondo astratto e morbido, toni del blu"]
        case .clip: ["La camera si avvicina piano", "Un movimento lento da sinistra a destra",
                     "Le luci cambiano piano, il resto resta fermo", "Un leggero zoom indietro che mostra la scena"]
        case .music: ["Calma e positiva, chitarra e pianoforte", "Elettronica leggera ed energica",
                      "Morbida e discreta, per un tutorial", "Allegra, con battito di mani"]
        case .upscale: []
        }
    }

    /// The job's title (a lookup key).
    var jobTitle: String {
        switch self {
        case .still: "Genero un'immagine"
        case .clip: "Genero una clip"
        case .music: "Genero la musica"
        case .upscale: "Ingrandisco la clip"
        }
    }

    var hasPrompt: Bool { self != .upscale }
}

// MARK: - Providers

/// Whether a provider can make a kind here; when not, why in words and the engine to install or set up.
struct GenAvailability: Equatable {
    var available: Bool
    var reason: String?
    /// The row of Impostazioni › Motori that installs or sets it up.
    var engine: String?
    /// "Prepara…" (the engine is there but not ready) rather than "Installa…".
    var setup = false

    static let ready = GenAvailability(available: true)
}

/// A provider as the panel shows it.
struct GenProvider: Equatable, Identifiable {
    var id: String
    var paid: Bool
    var kinds: [GenerationKind: GenAvailability]
    var formats: [GenerationKind: [GenerationFormat]] = [:]
    var budgetRemaining: Int?
    var budgetCap: Int?

    /// Its product name (never translated).
    var name: String {
        switch id {
        case "comfyui": "ComfyUI"
        case "higgsfield": "Higgsfield"
        case "voxcpm": "VoxCPM2"  // l10n-ignore: product names
        default: id
        }
    }

    /// Where it runs (a lookup key).
    var place: String { paid ? "Nel cloud, a pagamento" : "Su questo Mac, gratis" }

    func availability(_ kind: GenerationKind) -> GenAvailability {
        kinds[kind] ?? GenAvailability(available: false, reason: loc("Non fa questo tipo di contenuto."))
    }

    /// generate.providers (and the last generate.check, which can make a ComfyUI model unavailable) read for the panel.
    static func parse(_ json: JSONValue, check: JSONValue? = nil, lookup: (String) -> String = loc) -> [GenProvider] {
        let thisTier = json["tier"]?.stringValue ?? ""
        let checks = Dictionary((check?["models"]?.arrayValue ?? []).compactMap { m -> (String, String)? in
            guard let id = m["model"]?.stringValue, let st = m["state"]?.stringValue else { return nil }
            return (id, st)
        }, uniquingKeysWith: { a, _ in a })
        return (json["providers"]?.arrayValue ?? []).compactMap { p -> GenProvider? in
            guard let id = p["id"]?.stringValue else { return nil }
            var out = GenProvider(id: id, paid: p["paid"]?.boolValue ?? false, kinds: [:])
            let modelKinds = (p["models"]?.arrayValue ?? []).compactMap { m -> (String, GenerationKind)? in
                guard let mid = m["id"]?.stringValue, let k = m["kind"]?.stringValue.flatMap(GenerationKind.init(rawValue:)) else { return nil }
                return (mid, k)
            }
            for (k, v) in p["kinds"]?.objectValue ?? [:] {
                guard let kind = GenerationKind(rawValue: k) else { continue }
                if v["available"]?.boolValue == true {
                    // A model generate.check found incomplete (a node pack or a model file missing) cannot run either.
                    let missing = modelKinds.contains { $0.1 == kind && checks[$0.0] == "missing" }
                    out.kinds[kind] = missing
                        ? GenAvailability(available: false, reason: lookup("Non è pronto: mancano dei file del modello o dei nodi di ComfyUI."),
                                          engine: id, setup: true)
                        : .ready
                } else {
                    out.kinds[kind] = GenWords.unavailable(provider: id, why: v["why"]?.stringValue, engine: v["engine"]?.stringValue,
                                                           minimumTier: p["minimumTier"]?.stringValue ?? "", thisTier: thisTier, lookup: lookup)
                }
            }
            for (k, v) in p["formats"]?.objectValue ?? [:] {
                guard let kind = GenerationKind(rawValue: k) else { continue }
                out.formats[kind] = (v.arrayValue ?? []).compactMap { f in
                    guard let name = f["name"]?.stringValue, let s = f["size"]?.arrayValue, s.count == 2,
                          let w = s[0].doubleValue, let h = s[1].doubleValue else { return nil }
                    return GenerationFormat(name, Int(w), Int(h))
                }
            }
            out.budgetRemaining = p["budgetRemaining"]?.doubleValue.map { Int($0) }
            out.budgetCap = p["budgetCap"]?.doubleValue.map { Int($0) }
            return out
        }
    }
}

/// What the panel offers for each kind.
enum GenOffer {
    /// The providers that make `kind`: local first, then by name.
    static func rows(_ providers: [GenProvider], _ kind: GenKind) -> [GenProvider] {
        providers.filter { $0.kinds[kind.engineKind] != nil }.sorted { ($0.paid ? 1 : 0, $0.name) < ($1.paid ? 1 : 0, $1.name) }
    }

    /// Kinds the panel does not make itself (the voice-over is made in the Voce panel): shown as a pointer there.
    static func elsewhere(_ providers: [GenProvider]) -> [(provider: GenProvider, kind: GenerationKind)] {
        providers.flatMap { p in p.kinds.keys.filter { GenKind($0) == nil }.sorted { $0.rawValue < $1.rawValue }.map { (p, $0) } }
    }

    /// The provider used for `kind`: the one chosen if it can run, else the first that can (local first).
    static func pick(_ providers: [GenProvider], _ kind: GenKind, chosen: String?) -> GenProvider? {
        let rows = rows(providers, kind)
        if let c = chosen, let p = rows.first(where: { $0.id == c }), p.availability(kind.engineKind).available { return p }
        return rows.first { $0.availability(kind.engineKind).available }
    }

    /// How long a clip or a music bed can be, by provider (generate.run's duration).
    static func durations(_ provider: String?, _ kind: GenKind) -> [Double] {
        switch kind {
        case .clip: provider == "higgsfield" ? [4, 8] : [2, 3, 5]
        case .music: [15, 30, 60]
        default: []
        }
    }

    /// The format a project of `width`×`height` asks for: the provider's format closest to its aspect.
    static func format(_ formats: [GenerationFormat], width: Int, height: Int) -> GenerationFormat? {
        let target = Double(width) / Double(max(height, 1))
        return formats.min { abs(log(Double($0.width) / Double($0.height) / target)) < abs(log(Double($1.width) / Double($1.height) / target)) }
    }
}

// MARK: - Requests

/// One generation the panel asks for.
struct GenRequest: Equatable {
    var kind: GenKind
    var provider: String
    var prompt = ""
    var format: GenerationFormat?
    var duration: Double?
    /// The start frame of a clip: an asset id or an image file (the monitor's frame).
    var start: String?
    /// The clip to upscale.
    var assetID: String?

    /// Why it cannot start yet (a lookup key), nil when it can.
    var missing: String? {
        if kind.hasPrompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Scrivi prima cosa vuoi ottenere." }
        if kind == .clip, start == nil { return "Scegli l'immagine da cui parte la clip." }
        if kind == .upscale, assetID == nil { return "Scegli la clip da ingrandire." }
        return nil
    }

    private var common: [String: JSONValue] {
        var o: [String: JSONValue] = ["provider": .string(provider), "kind": .string(kind.engineKind.rawValue),
                                      "prompt": .string(prompt.trimmingCharacters(in: .whitespacesAndNewlines))]
        if let f = format { o["size"] = [.number(Double(f.width)), .number(Double(f.height))] }
        if let d = duration { o["duration"] = .number(d) }
        if let s = start { o["refs"] = [.string(s)] }
        return o
    }

    /// generate.estimate of exactly what `run` sends.
    var estimateCall: StepCall {
        if kind == .upscale { return StepCall(id: "generate.estimate", params: ["provider": .string(provider), "kind": "upscale", "refs": [.string(assetID ?? "")]]) }
        return StepCall(id: "generate.estimate", params: .object(common))
    }

    /// generate.run (or generate.upscale), with the approval token for a paid run.
    func runCall(approval: String?) -> StepCall {
        if kind == .upscale { return StepCall(id: "generate.upscale", params: ["assetId": .string(assetID ?? "")]) }
        var o = common
        if let approval { o["approval"] = .string(approval) }
        return StepCall(id: "generate.run", params: .object(o))
    }
}

/// Why a file of Media cannot be upscaled (a lookup key), nil when it can: the upscale makes 1080×1920 clips.
enum UpscaleReason {
    static func of(_ a: MediaAsset) -> String? {
        guard let v = a.video else { return "Non ha immagine." }
        if a.image?.kind == .still { return "Per ora si ingrandiscono solo le clip." }
        if v.width >= v.height { return "Per ora solo clip verticali (9:16)." }
        if v.width >= 1080 { return "È già a piena risoluzione." }
        return nil
    }
}

/// The calls behind the panel.
enum GenerateCalls {
    static let providers = StepCall(id: "generate.providers", params: [:])
    static let check = StepCall(id: "generate.check", params: [:])
    static let list = StepCall(id: "generate.list", params: [:])
    static func approve(_ estimateID: String) -> StepCall { StepCall(id: "generate.approve", params: ["estimateId": .string(estimateID)]) }
    static func decline(_ estimateID: String) -> StepCall {
        StepCall(id: "generate.approve", params: ["estimateId": .string(estimateID), "decline": true])
    }
    /// The monitor's frame at `time` as an image file (the start frame of a clip).
    static func frame(at time: Double, path: String) -> StepCall {
        StepCall(id: "frame.render", params: ["time": .number(time), "path": .string(path), "captions": false, "inline": false])
    }
}

/// generate.estimate read.
struct GenEstimate: Equatable {
    var id: String
    var provider: String
    var model: String
    var credits: Double
    var seconds: Double?
    var paid: Bool
    var cached: Bool
    var budgetRemaining: Int?

    init(id: String, provider: String, model: String, credits: Double, seconds: Double? = nil, paid: Bool, cached: Bool = false,
         budgetRemaining: Int? = nil) {
        (self.id, self.provider, self.model, self.credits, self.seconds, self.paid, self.cached, self.budgetRemaining) =
            (id, provider, model, credits, seconds, paid, cached, budgetRemaining)
    }

    init?(_ j: JSONValue) {
        guard let id = j["estimateId"]?.stringValue else { return nil }
        self.init(id: id, provider: j["provider"]?.stringValue ?? "", model: j["model"]?.stringValue ?? "",
                  credits: j["credits"]?.doubleValue ?? 0, seconds: j["seconds"]?.doubleValue, paid: j["paid"]?.boolValue ?? false,
                  cached: j["cached"]?.boolValue ?? false, budgetRemaining: j["budgetRemaining"]?.doubleValue.map { Int($0) })
    }

    /// A paid call that costs credits now (a cached result costs nothing and needs no approval).
    var needsApproval: Bool { paid && !cached }
}

/// The user's yes to one paid estimate: only `GenerateFlow.approve` makes one (generate.approve, which agents cannot call).
struct PaidApproval: Equatable {
    let estimateID: String
    let token: String
    fileprivate init(estimateID: String, token: String) {
        self.estimateID = estimateID
        self.token = token
    }
}

/// A paid run asked to start without the user's approval of its estimate: nothing was sent to the provider.
struct GenerateBlocked: Error, CustomStringConvertible {
    let estimate: GenEstimate
    var description: String { loc("Una generazione a pagamento parte solo dopo la tua approvazione.") }
}

/// What a finished run left in Media.
struct GenResult: Equatable {
    var assetID: String
    var cached: Bool
    var cost: Double
}

/// How a generation starts: done (free, or cached), or waiting for the user's approval of a paid estimate.
enum GenStart: Equatable {
    case done(GenResult)
    case needsApproval(GenEstimate)
}

/// The panel's runs through a `perform` closure — the tab's queue in the app (inside a job), a headless engine in the
/// tests — so both run the same commands in the same order.
@MainActor
struct GenerateFlow {
    var perform: (StepCall) async throws -> JSONValue

    func estimate(_ r: GenRequest) async throws -> GenEstimate {
        let j = try await perform(r.estimateCall)
        guard let e = GenEstimate(j) else { throw StepError(message: loc("La stima non è arrivata: riprova.")) }
        return e
    }

    /// Estimate, then run when that costs nothing; a paid estimate stops here and waits for `approve`.
    func start(_ r: GenRequest) async throws -> GenStart {
        let e = try await estimate(r)
        if e.needsApproval { return .needsApproval(e) }
        return .done(try await run(r, estimate: e, approval: nil))
    }

    /// The user approved the estimate on screen (generate.approve): a single-use token for exactly that request.
    func approve(_ e: GenEstimate) async throws -> PaidApproval {
        let j = try await perform(GenerateCalls.approve(e.id))
        guard let token = j["approval"]?.stringValue else { throw StepError(message: loc("L'approvazione non è stata registrata: niente è stato speso.")) }
        return PaidApproval(estimateID: e.id, token: token)
    }

    func decline(_ e: GenEstimate) async throws { _ = try await perform(GenerateCalls.decline(e.id)) }

    /// Runs `r`. A paid estimate that costs credits needs the approval of that very estimate, or nothing is sent.
    func run(_ r: GenRequest, estimate e: GenEstimate, approval: PaidApproval?) async throws -> GenResult {
        var token: String?
        if e.needsApproval {
            guard let approval, approval.estimateID == e.id else { throw GenerateBlocked(estimate: e) }
            token = approval.token
        }
        let j = try await perform(r.runCall(approval: token))
        guard let asset = j["assetId"]?.stringValue else { throw StepError(message: loc("La generazione non ha prodotto un file.")) }
        return GenResult(assetID: asset, cached: j["cached"]?.boolValue ?? false, cost: j["cost"]?.doubleValue ?? 0)
    }
}

/// One generated file of the project (generate.list), newest first.
struct GenRecent: Equatable, Identifiable {
    var assetID: String
    var kind: GenKind?
    var provider: String
    var prompt: String
    var cost: Double
    var paid: Bool
    var created: Date?
    var duration: Double
    var id: String { assetID }

    static func parse(_ list: JSONValue) -> [GenRecent] {
        let iso = ISO8601DateFormatter()
        return Array((list["assets"]?.arrayValue ?? []).compactMap { a -> GenRecent? in
            guard let id = a["assetId"]?.stringValue else { return nil }
            return GenRecent(assetID: id, kind: a["kind"]?.stringValue.flatMap(GenerationKind.init(rawValue:)).flatMap(GenKind.init),
                             provider: a["provider"]?.stringValue ?? "", prompt: a["prompt"]?.stringValue ?? "",
                             cost: a["cost"]?.doubleValue ?? 0, paid: a["unit"]?.stringValue == "credits",
                             created: a["created"]?.stringValue.flatMap { iso.date(from: $0) }, duration: a["duration"]?.doubleValue ?? 0)
        }.reversed())
    }
}

// MARK: - Words

enum GenWords {
    /// Why a provider cannot make a kind here, in words, with the engine to install or set up.
    static func unavailable(provider: String, why: String?, engine: String?, minimumTier: String, thisTier: String,
                            lookup: (String) -> String = loc) -> GenAvailability {
        if why == "tier" {
            let gb = EngineManifest.shared.entry(provider)?.minRamGB.map { String(Int($0)) } ?? "32"
            return GenAvailability(available: false, reason: String(format: lookup("Serve un Mac con almeno %@ GB di memoria."), gb), engine: engine)
        }
        switch provider {
        case "comfyui": return GenAvailability(available: false, reason: lookup("ComfyUI non è installato su questo Mac."), engine: engine)
        case "higgsfield": return GenAvailability(available: false, reason: lookup("Serve un account Higgsfield collegato a questo Mac."), engine: engine, setup: true)
        case "voxcpm": return GenAvailability(available: false, reason: lookup("Il motore della voce non è installato."), engine: engine)
        default: return GenAvailability(available: false, reason: lookup("Non disponibile su questo Mac."), engine: engine)
        }
    }

    /// A failed run in words a person can act on.
    static func readable(_ error: Error, _ lookup: (String) -> String = loc) -> String {
        if let b = error as? GenerateBlocked { return b.description }
        let raw = JobCenter.message(error)
        if let sentence = StepError.refusal(raw, lookup) { return sentence }
        let says = [  // l10n-ignore-begin
            "budget exhausted",
            "not logged in",
            "cannot run, ComfyUI is missing",
            "printed no result",
            "failed (exit",
            "approval",
        ]  // l10n-ignore-end
        let reads = [
            lookup("Il budget delle generazioni a pagamento è finito: usa ComfyUI, gratis."),
            lookup("Higgsfield non è collegato: accedi di nuovo dal suo programma, poi riprova."),
            lookup("ComfyUI non è pronto: mancano dei file del modello o dei nodi. Impostazioni › Motori dice cosa aggiungere."),
            lookup("Il generatore ha finito senza produrre un file: riprova, magari con una descrizione diversa."),
            lookup("Il generatore si è fermato con un errore: controlla che ComfyUI funzioni e riprova."),
            lookup("L'approvazione non vale più (usata o scaduta): genera di nuovo per vedere il costo."),
        ]
        let known = Array(zip(says, reads))
        if let hit = known.first(where: { raw.contains($0.0) }) { return hit.1 }
        return StepError.readable(error, lookup)
    }

    /// "circa 30 s", "circa 5 min".
    static func duration(_ seconds: Double) -> String {
        seconds < 90 ? String(format: loc("circa %d s"), Int((seconds / 5).rounded() * 5)) : String(format: loc("circa %d min"), Int((seconds / 60).rounded()))
    }

    /// "2,4 crediti" in the user's locale.
    static func credits(_ c: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.minimumFractionDigits = 0
        let n = f.string(from: NSNumber(value: c)) ?? String(c)
        return Plural.singular(c) ? String(format: loc("%@ credito"), n) : String(format: loc("%@ crediti"), n)
    }
}
