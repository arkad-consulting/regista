import AppKit
import RegistaCore
import SwiftUI

// G1 (#5): the Genera side panel. Four things to make (a still, a clip from a start frame, music, an upscale), the
// words to describe it with a few plain ideas, the format and length where the provider has a choice, the providers
// (local first; one that cannot run here stays, greyed, with the reason and the way to install or set it up), then
// "Genera". A paid run first shows its cost on an approval card and starts only on "Approva e spendi"; every run is a
// job of the tab (progress, Cancel) and lands in Media; the recent generations are listed below, ready to drag to the
// timeline or to use again.

private struct GenerateDemoKey: EnvironmentKey { static let defaultValue: GenerateState? = nil }

extension EnvironmentValues {
    /// The panel drawn from sample data (ui.screenshot `generate`).
    var generateDemo: GenerateState? {
        get { self[GenerateDemoKey.self] }
        set { self[GenerateDemoKey.self] = newValue }
    }
}

struct GeneratePanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.generateDemo) private var demo

    var body: some View { Content(model: demo ?? store.generation, jobs: store.jobs) }

    private struct Content: View {
        @EnvironmentObject private var store: EditorStore
        @ObservedObject var model: GenerateState
        @ObservedObject var jobs: JobCenter

        var body: some View {
            let k = model.kind
            ScrollViewReader { proxy in ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.l + 2) {
                    VStack(alignment: .leading, spacing: Ed.Space.s) {
                        KindChips(model: model)
                        Text(verbatim: loc(k.purpose)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch k {
                    case .upscale: UpscaleSource(model: model)
                    case .clip:
                        GenStartFrame(model: model)
                        PromptBox(model: model, kind: k)
                    default: PromptBox(model: model, kind: k)
                    }
                    GenOptions(model: model, kind: k)
                    ProviderList(model: model, kind: k)
                    RunArea(model: model, job: model.demoJob ?? jobs.latest(GenerateState.jobKind))
                    Elsewhere(model: model)
                    if !model.recent.isEmpty { GenRecentList(model: model) }
                }
                .padding(Ed.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { if model.scrollToRecent { DispatchQueue.main.async { proxy.scrollTo("recent", anchor: .top) } } }
            }
            .task(id: store.tabID) { await model.refresh() }
            .onChange(of: store.projectVersion) { Task { await model.refreshList() } }
            .onChange(of: model.kind) { model.changed() }
        }
    }
}

// MARK: - Kind

/// Immagine · Clip · Musica · Ingrandisci as four equal tiles, the one chosen in the accent.
private struct KindChips: View {
    @ObservedObject var model: GenerateState

    var body: some View {
        RChips(items: GenKind.allCases.map { .init(id: $0, title: $0.title, symbol: $0.symbol) }, selection: model.kind, stacked: true) {
            model.kind = $0
        }
    }
}

// MARK: - Words

/// The description, and a few plain ideas that fill it in.
private struct PromptBox: View {
    @ObservedObject var model: GenerateState
    let kind: GenKind

    var body: some View {
        let text = Binding(get: { model.prompts[kind] ?? "" }, set: { model.prompts[kind] = $0; model.changed() })
        RSection(kind == .clip ? "Il movimento" : "Descrivi") {
            RTextEditor(placeholder: kind.placeholder, text: text, size: Ed.TypeSize.control)
            VStack(alignment: .leading, spacing: 1) {
                ForEach(kind.ideas, id: \.self) { idea in
                    IdeaRow(text: loc(idea), on: text.wrappedValue == loc(idea)) { text.wrappedValue = loc(idea) }
                }
            }
        }
    }
}

private struct IdeaRow: View {
    let text: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: on ? "checkmark" : "lightbulb").font(Ed.icon(Ed.TypeSize.micro)).foregroundStyle(on ? Ed.gold : Ed.text4).frame(width: 12)
                Text(verbatim: text).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(hover || on ? Ed.text : Ed.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, Ed.Space.xs)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(hover ? Ed.hover.opacity(0.6) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .tip("Usa questa idea: poi la puoi cambiare")
    }
}

// MARK: - Start frame and clip to upscale

/// A row to pick: a thumbnail (or a symbol), a name, a dim line; greyed with the reason when it cannot be picked.
private struct GenPickRow: View {
    @EnvironmentObject private var media: MediaCache
    var asset: MediaAsset?
    var symbol = "photo"
    let title: String
    let line: String
    let on: Bool
    var reason: String?
    let action: () -> Void

    var body: some View {
        let _ = media.revision
        PickRow(title: title, detail: line, reason: reason, selected: on) {
            RowThumb(selected: on) {
                if let a = asset, a.video != nil, let img = media.picture(a, at: min(1, a.duration.seconds / 2)) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.control, .light)).foregroundStyle(Ed.text3)
                }
            }
        } action: { action() }
    }
}

/// Where a clip starts: the monitor's frame at the playhead, or a still of Media.
private struct GenStartFrame: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject var model: GenerateState

    var body: some View {
        let stills = store.project?.assets.filter { $0.image?.kind == .still } ?? []
        let hasPicture = (store.project?.duration ?? .zero) > .zero || model.isDemo
        RSection("Parte da", rows: true) {
            GenPickRow(symbol: "play.rectangle", title: loc("Il fotogramma del monitor"),
                    line: String(format: loc("Alla testina, %@"), shortTime(playhead.time)), on: model.startAsset == nil && hasPicture,
                    reason: hasPicture ? nil : loc("Il monitor è vuoto: metti prima un video in timeline.")) {
                model.startAsset = nil
                model.changed()
            }
            ForEach(stills, id: \.id) { a in
                GenPickRow(asset: a, title: a.name, line: a.generated != nil ? loc("Immagine generata") : loc("Immagine di Media"),
                        on: model.startAsset == a.id) {
                    model.startAsset = a.id
                    model.changed()
                }
            }
            if stills.isEmpty {
                Text(verbatim: loc("Oppure genera prima un'immagine: comparirà qui."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).padding(.horizontal, Ed.Space.s).padding(.top, Ed.Space.xs)
            }
        }
    }
}

/// The clip to upscale: the clips of Media (stills and clips the upscale cannot take stay, greyed, with the reason).
private struct UpscaleSource: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject var model: GenerateState

    var body: some View {
        let assets = (store.project?.assets ?? []).filter { $0.video != nil }
        RSection("Clip da ingrandire", rows: true) {
            if assets.isEmpty {
                Text(verbatim: loc("Media non ha ancora clip: genera prima una clip."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(assets, id: \.id) { a in
                let v = a.video!
                GenPickRow(asset: a, symbol: "film", title: a.name,
                        line: a.image?.kind == .still ? "\(v.width)×\(v.height)" : "\(v.width)×\(v.height) · \(clockTime(a.duration.seconds))",
                        on: model.upscaleAsset == a.id, reason: UpscaleReason.of(a).map { loc($0) }) {
                    model.upscaleAsset = a.id
                    model.changed()
                }
            }
            Text(verbatim: loc("Diventa 1080×1920 a 30 fotogrammi al secondo, senza inventare dettagli."))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Format and length

private struct GenOptions: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject var model: GenerateState
    let kind: GenKind

    var body: some View {
        let formats = model.formatOptions(kind)
        let lengths = model.durationOptions(kind)
        if formats.count > 1 || !lengths.isEmpty {
            HStack(alignment: .top, spacing: Ed.Space.m) {
                if formats.count > 1, let f = model.format(kind) {
                    RSection("Formato") {
                        RSegmented(items: formats.map { ($0.name, $0.name) },
                                   selection: Binding(get: { f.name }, set: { model.formats[kind] = $0; model.changed() }),
                                   tips: Dictionary(uniqueKeysWithValues: formats.map { ($0.name, Self.formatTip($0.name, project: store.project)) }))
                    }
                }
                if !lengths.isEmpty, let d = model.duration(kind) {
                    RSection("Durata") {
                        RSegmented(items: lengths.map { ($0, String(format: loc("%d s"), Int($0))) },
                                   selection: Binding(get: { d }, set: { model.durations[kind] = $0; model.changed() }))
                    }
                    .frame(maxWidth: formats.count > 1 ? 112 : .infinity)
                }
            }
        }
    }

    /// The project's own format says so.
    static func formatTip(_ name: String, project: Project?) -> String {
        guard let s = project?.settings else { return "" }
        let own = GenOffer.format(GeneralPrefs.formats.map { GenerationFormat($0.id, $0.width, $0.height) }, width: s.width, height: s.height)
        return own?.name == name ? "Il formato del progetto" : ""
    }
}

// MARK: - Providers

/// Who makes it: local first; one that cannot run here is greyed with the reason and the way to install or set it up.
private struct ProviderList: View {
    @ObservedObject var model: GenerateState
    let kind: GenKind

    var body: some View {
        let rows = GenOffer.rows(model.providers, kind)
        let picked = model.provider(kind)?.id
        RSection("Generatore", rows: true) {
            if rows.isEmpty {
                Text(verbatim: model.loaded || model.isDemo ? loc("Nessun generatore fa questo su questo Mac.") : loc("Controllo i generatori…"))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
            }
            ForEach(rows) { p in
                ProviderRow(provider: p, kind: kind, on: p.id == picked, estimate: p.id == picked && !p.paid ? model.estimate : nil) {
                    model.chosen[kind] = p.id
                    model.changed()
                }
            }
        }
    }
}

private struct ProviderRow: View {
    @Environment(\.openSettings) private var openSettings
    let provider: GenProvider
    let kind: GenKind
    let on: Bool
    let estimate: GenEstimate?
    let action: () -> Void

    var body: some View {
        let a = provider.availability(kind.engineKind)
        PickRow(title: provider.name, detail: line, reason: a.reason, tag: provider.paid ? "a pagamento" : nil, selected: on, mark: .none,
                link: !a.available ? a.engine.map { engine in
                    RowLink(title: a.setup ? "Prepara…" : "Installa…", tip: "Apre Impostazioni › Motori su questo motore") {
                        SettingsRoute.open(.engines, engine: engine, with: openSettings)
                    }
                } : nil) {
            RadioMark(on: on)
        } action: { action() }
    }

    private var line: String {
        if provider.paid {
            if let left = provider.budgetRemaining, let cap = provider.budgetCap {
                return String(format: loc("Nel cloud · il costo si vede prima · restano %@ chiamate su %@"), String(left), String(cap))
            }
            return loc("Nel cloud · il costo si vede prima di partire")
        }
        if let s = estimate?.seconds { return String(format: loc("Su questo Mac, gratis · %@"), GenWords.duration(s)) }
        return loc(provider.place)
    }
}

// MARK: - Run

/// "Genera" with what it costs (time, or the cost shown before a paid run), the approval card of a paid estimate, and
/// the job of the last run (progress and Cancel, or what went wrong).
private struct RunArea: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject var model: GenerateState
    let job: JobCenter.Job?

    var body: some View {
        let r = model.request()
        let p = model.provider(model.kind)
        VStack(alignment: .leading, spacing: Ed.Space.s + 2) {
            if let pending = model.pending {
                ApprovalCard(model: model, pending: pending)
            } else {
                let blocked = blockReason(r)
                EdButton(title: p?.paid == true ? loc("Genera…") : loc("Genera"), symbol: "wand.and.stars",
                         prominent: blocked == nil, large: true, fill: true, disabled: blocked != nil || model.pricing) { model.generate() }
                    .tip(p?.paid == true ? "Prima vedi il costo, poi decidi" : "Genera sul tuo Mac: il risultato va in Media")
                Text(verbatim: model.problem ?? blocked.map { loc($0) } ?? line(r, p))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(model.problem != nil ? Ed.warn : Ed.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let job, job.isRunning || job.state != .done || model.demoJob != nil || recentJob(job) {
                JobCard(job: job, onCancel: { store.jobs.cancel(job.id) }, onDismiss: model.demoJob == nil ? { store.jobs.dismiss(job.id) } : nil)
            }
        }
    }

    /// A finished run stays visible for a minute (where its result went).
    private func recentJob(_ j: JobCenter.Job) -> Bool { Date().timeIntervalSince(j.started) < 600 }

    private func blockReason(_ r: GenRequest?) -> String? {
        if store.project == nil, !model.isDemo { return "Apri o crea un progetto: quello che generi va nei suoi Media." }
        guard let r else { return model.loaded || model.isDemo ? "Nessun generatore pronto su questo Mac: vedi sopra come prepararne uno." : "Controllo i generatori…" }
        if model.jobRunning { return "Una generazione è in corso: aspetta che finisca o annullala." }
        if model.pricing { return "Chiedo il costo…" }
        return r.missing
    }

    private func line(_ r: GenRequest?, _ p: GenProvider?) -> String {
        guard let p else { return "" }
        if p.paid { return loc("A pagamento: prima vedi il costo e decidi. Niente parte senza il tuo sì.") }
        if let s = model.estimate?.seconds { return String(format: loc("Gratis, su questo Mac: %@. Il risultato va in Media."), GenWords.duration(s)) }
        return loc("Gratis, su questo Mac. Il risultato va in Media.")
    }
}

/// The cost of one paid run, plainly, and the user's decision. Valid for this run only.
private struct ApprovalCard: View {
    @ObservedObject var model: GenerateState
    let pending: GenPending

    var body: some View {
        let e = pending.estimate, r = pending.request
        VStack(alignment: .leading, spacing: Ed.Space.s + 2) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Generazione a pagamento", tint: Ed.text2)
                Spacer(minLength: Ed.Space.xs)
                Text(verbatim: model.provider(r.kind)?.name ?? e.provider).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
            }
            Text(verbatim: GenWords.credits(e.credits)).font(Ed.ui(Ed.TypeSize.large, .semibold)).foregroundStyle(Ed.text).monospacedDigit()
            Text(verbatim: details(r, e)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            if !r.prompt.isEmpty {
                Text(verbatim: "«" + r.prompt + "»").font(Ed.ui(Ed.TypeSize.small)).italic().foregroundStyle(Ed.text2)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let left = e.budgetRemaining {
                Text(verbatim: left == 1 ? loc("Del budget resta 1 chiamata a pagamento: questa la usa.")
                                         : String(format: loc("Del budget restano %@ chiamate a pagamento: questa ne usa una."), String(left)))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: loc("L'approvazione vale solo per questa generazione: la prossima chiede di nuovo."))
                .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            // Side by side when the words fit, else the approval on its own line: never a shrunken amount.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Ed.Space.s) { decline; approve(e) }
                VStack(spacing: Ed.Space.xs) { approve(e); decline }
            }
        }
        .rCard(.raised, border: Ed.text3.opacity(0.45))
    }

    private var decline: some View { EdButton(title: loc("Rifiuta"), quiet: true) { model.decline() } }

    private func approve(_ e: GenEstimate) -> some View {
        EdButton(title: String(format: loc("Approva e spendi %@"), GenWords.credits(e.credits)), prominent: true, fill: true,
                 disabled: e.budgetRemaining == 0) { model.approve() }
    }

    private func details(_ r: GenRequest, _ e: GenEstimate) -> String {
        var parts = [loc(r.kind.title), e.model]
        if let f = r.format { parts.append(f.name) }
        if let d = r.duration { parts.append(String(format: loc("%d s"), Int(d))) }
        return parts.joined(separator: " · ")
    }
}

/// Kinds made in another panel (the voice-over, in Voce), so nothing reported by the providers is hidden.
private struct Elsewhere: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject var model: GenerateState

    var body: some View {
        let rows = GenOffer.elsewhere(model.providers)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(rows, id: \.provider.id) { row in
                    let a = row.provider.availability(row.kind)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "waveform").font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                        VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                            Text(verbatim: String(format: loc("Voce fuori campo con %@: si fa nel pannello Voce."), row.provider.name))
                                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                            if let why = a.reason {
                                Text(verbatim: why).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn).fixedSize(horizontal: false, vertical: true)
                            }
                            AccentLinkButton(title: loc("Apri Voce")) { store.select(.voice) }
                        }
                    }
                }
            }
            .padding(.top, Ed.Space.xxs)
        }
    }
}

// MARK: - Recent

/// The project's generated files, newest first: drag one to the timeline, click to see it in the Source monitor, or use
/// its words again.
private struct GenRecentList: View {
    @ObservedObject var model: GenerateState

    var body: some View {
        RSection("Generati di recente", rows: true) {
            ForEach(model.recent.prefix(12)) { g in GenRecentRow(model: model, item: g) }
            Text(verbatim: loc("Sono in Media: trascinali sulla timeline."))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).padding(.top, Ed.Space.xs)
        }
        .id("recent")
    }
}

private struct GenRecentRow: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var media: MediaCache
    @ObservedObject var model: GenerateState
    let item: GenRecent

    var body: some View {
        let asset = store.project?.asset(item.assetID)
        let _ = media.revision
        PickRow(title: item.prompt.isEmpty ? (asset?.name ?? item.assetID) : item.prompt, detail: meta, mark: .none,
                link: item.kind?.hasPrompt == true
                    ? RowLink(title: "Usa di nuovo", tip: "Rimette queste parole e questo generatore nel modulo") { model.useAgain(item) } : nil) {
            RowThumb(width: 40, height: 40) {
                if let a = asset, a.video != nil, let img = media.picture(a, at: min(1, a.duration.seconds / 2)) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.kind?.symbol ?? "sparkles").font(Ed.icon(Ed.TypeSize.control, .light)).foregroundStyle(Ed.text3)
                }
            }
        } action: { if asset?.video != nil { store.sourceAssetID = item.assetID } }
        .draggable(MediaDrop.assetPrefix + item.assetID) {
            Label(asset?.name ?? item.assetID, systemImage: item.kind?.symbol ?? "sparkles")
                .font(Ed.ui(Ed.TypeSize.body)).padding(6).background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.control))
        }
    }

    private var meta: String {
        var parts = [GenProvider(id: item.provider, paid: item.paid, kinds: [:]).name]
        if let k = item.kind { parts.append(loc(k.title)) }
        if item.duration > 0 { parts.append(clockTime(item.duration)) }
        if item.paid { parts.append(GenWords.credits(item.cost)) }
        if let d = item.created { parts.append(EditorStore.ageFormatter.localizedString(for: d, relativeTo: Date())) }
        return parts.joined(separator: " · ")
    }
}
