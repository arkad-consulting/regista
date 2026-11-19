import Foundation
import RegistaCore

/// The step buttons, "Fai tutto" and the export as jobs of this tab (E2 #54): each runs existing commands through the
/// tab's queue (logged, undoable, the same effect as the MCP tool) inside a `CommandJob`, so the engines' progress
/// reaches the job and its Cancel kills their processes; the edit changes only when a command finishes.
extension EditorStore {
    /// Starts long work as a job of this tab. `work` gets the job's handle and the `CommandJob` its commands run in
    /// (`performInJob`); Cancel stops the command running now and every later one.
    @discardableResult
    func startJob(kind: String, title: String, _ work: @escaping @MainActor (JobCenter.Handle, CommandJob) async throws -> Void) -> UUID {
        final class Ref: @unchecked Sendable { var id: UUID? }
        let ref = Ref()
        let command = CommandJob(estimates: { [weak jobs] fraction, detail, estimated in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let id = ref.id else { return }
                    if let fraction { jobs?.update(id, progress: fraction, detail: nil, estimated: estimated) }
                    else if let detail { jobs?.update(id, progress: nil, detail: JobWords.detail(detail)) }   // what it waits for; the bar stays
                    else { jobs?.progressUnknown(id) }
                }
            }
        })
        let id = jobs.start(kind: kind, title: title, tab: tabTitle, onCancel: { command.cancel() }) { h in
            try await work(h, command)
        }
        ref.id = id
        return id
    }

    /// Runs one command on the tab's queue inside `job`, its progress mapped into [lo, hi] of the job. Throws
    /// CancellationError once the job was cancelled (nothing more starts).
    @discardableResult
    func performInJob(_ call: StepCall, _ job: CommandJob, from lo: Double = 0, to hi: Double = 1) async throws -> JSONValue {
        try Task.checkCancellation()
        if job.isCancelled { throw CancellationError() }
        let result: Result<JSONValue, Error> = await withCheckedContinuation { cont in
            queue.async { [self] in
                let r = CommandJob.$current.withValue(job) {
                    CommandJob.stage(lo, hi) { execute(call.id, call.params, source: "Tu", agent: false) }
                }
                cont.resume(returning: r)
            }
        }
        if job.isCancelled { throw CancellationError() }
        return try result.get()
    }

    /// The steps as they are now (running ones from this tab's jobs).
    var textSteps: TextSteps {
        var running = Set(TextStep.allCases.filter { jobs.latest($0.jobKind)?.isRunning == true })
        if let all = jobs.latest(TextStep.allJobKind), all.isRunning, let s = Self.allSteps(all) { running.insert(s) }
        return TextSteps.compute(project, running: running)
    }

    /// The step job running in this tab (one at a time: they share the tab's queue and its project).
    var runningStepJob: JobCenter.Job? { jobs.jobs.last { $0.isRunning && $0.kind.hasPrefix("step.") } }

    private static func allSteps(_ job: JobCenter.Job) -> TextStep? {
        guard job.steps.indices.contains(job.stepIndex) else { return nil }
        return TextStep.allCases.first { $0.title() == job.steps[job.stepIndex] }
    }

    /// The driver of this tab's steps: commands on the tab's queue inside `job`, the job's line and progress on `h`.
    func driver(_ h: JobCenter.Handle, _ job: CommandJob) -> StepDriver {
        StepDriver(project: { [weak self] in self?.project },
                   perform: { [weak self] call, lo, hi in
                       guard let self else { throw CancellationError() }
                       return try await self.performInJob(call, job, from: lo, to: hi)
                   },
                   suggest: { [weak self] style in await self?.suggestKeywords(style: style) ?? [] },
                   detail: { h.update(detail: $0) }, progress: { h.update(progress: $0) }, step: { h.step($0) })
    }

    /// One step's button: its commands as one job ("Trascrivi" = extract the audio if needed, then transcribe).
    func runStep(_ step: TextStep, settings: StepSettings, keywords: [String] = []) {
        guard runningStepJob == nil, let p = project else { return }
        let calls = StepCalls.plan(step, project: p, settings: settings, keywords: keywords)
        guard !calls.isEmpty else { return }
        startJob(kind: step.jobKind, title: step.title()) { [weak self] h, job in
            guard let self else { return }
            try await self.driver(h, job).run(calls, settings: settings, from: 0, to: 1)
            h.update(detail: self.textSteps[step].line)
        }
    }

    /// A single command as a step job (the copione from pasted text or a file, a take picked again…).
    func runStepCall(_ call: StepCall, step: TextStep) {
        guard runningStepJob == nil else { return }
        startJob(kind: step.jobKind, title: step.title()) { [weak self] h, job in
            guard let self else { return }
            try await self.driver(h, job).run([call], settings: StepSettings.saved(project: self.project), from: 0, to: 1)
            h.update(detail: self.textSteps[step].line)
        }
    }

    /// The suggested caption keywords for `style` (captions.generate dryRun: changes nothing, stays out of the log).
    func suggestKeywords(style: String) async -> [String] {
        let c = StepCalls.suggestKeywords(style: style)
        let r = try? await silent(c.id, c.params)
        return (r?["suggestedKeywords"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    // MARK: Fai tutto

    /// The steps "Fai tutto" runs, in order (the copione only when there is a text to use: otherwise Riprese builds it
    /// from the speech).
    nonisolated static func allSteps(hasScriptText: Bool) -> [TextStep] {
        [.transcribe] + (hasScriptText ? [.script] : []) + [.takes, .cut, .clean, .captions]
    }

    /// "Fai tutto": the steps in order as one job with sub-steps, skipping those already done; stops at the first
    /// error (in words) or on Cancel. `script`: the teleprompter's text, used as the copione when the project has none.
    /// `steps`: the steps to run (default: all of them); `extras`: commands run after them on the project they left (the
    /// Semplice level's light grade), shown as one more sub-step titled `extrasTitle`.
    func runAll(settings: StepSettings, script: String?, steps only: [TextStep]? = nil,
                extras: @escaping @MainActor (Project?) -> [StepCall] = { _ in [] }, extrasTitle: String? = nil) {
        guard runningStepJob == nil, project != nil else { return }
        let text = project?.script == nil ? script?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let steps = only ?? Self.allSteps(hasScriptText: !(text ?? "").isEmpty)
        startJob(kind: TextStep.allJobKind, title: loc("Fai tutto")) { [weak self] h, job in
            guard let self else { return }
            h.steps(steps.map { $0.title() } + (extrasTitle.map { [$0] } ?? []))
            try await self.driver(h, job).runAll(steps, settings: settings, script: text, extras: extras)
            h.update(detail: loc("Fatto: montaggio, voce e sottotitoli pronti. Rivedili prima di esportare."))
        }
    }

    // MARK: Export

    /// Esporta video…: export.render as a job (progress by frames written, Cancel removes the partial file).
    func exportVideo(_ params: JSONValue, to url: URL) {
        guard jobs.latest("export")?.isRunning != true else { return }
        startJob(kind: "export", title: String(format: loc("Esporto «%@»"), url.lastPathComponent)) { [weak self] h, job in
            guard let self else { return }
            h.update(detail: loc("Mix dell'audio e fotogrammi…"))
            do { try await self.performInJob(StepCall(id: "export.render", params: params), job) }
            catch is CancellationError { throw CancellationError() }
            catch { throw StepError(message: StepError.readable(error)) }
            h.update(detail: String(format: loc("Salvato in %@"), url.deletingLastPathComponent().lastPathComponent))
        }
    }
}

/// Runs steps through closures — the tab's queue in the app, a headless engine in the tests — so the buttons, "Fai
/// tutto" and the scenario test run exactly the same commands in the same order.
@MainActor
struct StepDriver {
    /// The project as it is now (read again after every command).
    var project: () -> Project?
    /// Runs a command, its progress mapped into [lo, hi] of the job.
    var perform: (StepCall, Double, Double) async throws -> JSONValue
    /// The suggested caption keywords for a style (captions.generate dryRun).
    var suggest: (String) async -> [String]
    var detail: (String) -> Void = { _ in }
    var progress: (Double) -> Void = { _ in }
    /// The sub-step running now ("Fai tutto").
    var step: (Int) -> Void = { _ in }

    /// A step's commands as parts of [lo, hi] (extracting the audio or building the script weighs little next to the
    /// rest); a failure becomes a sentence a person can act on.
    func run(_ calls: [StepCall], settings: StepSettings, from lo: Double, to hi: Double) async throws {
        let weights = calls.map { $0.id == "media.extractAudio" || $0.id == "script.fromTranscript" ? 0.1 : 1.0 }
        let total = weights.reduce(0, +)
        var at = lo
        for (call, w) in zip(calls, weights) {
            let end = at + (hi - lo) * w / total
            detail(Self.detail(call, settings: settings))
            do { _ = try await perform(call, at, end) }
            catch is CancellationError { throw CancellationError() }
            catch { throw StepError(message: StepError.readable(error)) }
            at = end
        }
    }

    /// What a command is doing, in words, for the job's line.
    nonisolated static func detail(_ call: StepCall, settings: StepSettings) -> String {
        switch call.id {
        case "media.extractAudio": return loc("Estraggo l'audio…")
        case "transcript.run":
            return settings.language == "auto" ? loc("Trascrivo il parlato e riconosco la lingua…")
                : String(format: loc("Trascrivo il parlato (%@)…"), StepSettings.languageName(settings.language))
        case "script.fromTranscript": return loc("Creo il copione dal parlato…")
        case "script.set": return loc("Uso il copione…")
        case "takes.list": return loc("Cerco le letture di ogni riga…")
        case "edit.autoCut": return loc("Taglio le pause e monto le riprese…")
        case "audio.clean": return loc("Tolgo il rumore e porto la voce a −15 LUFS…")
        case "captions.generate": return loc("Creo i sottotitoli…")
        default: return CommandTitles.title(call.id)
        }
    }

    /// "Fai tutto": each step in order, recomputed on the project left by the previous one; done steps are skipped, a
    /// blocked one stops with its reason, Cancel (a CancellationError from `perform`) stops before the next command.
    /// `extras`: commands run afterwards on the project the steps left (none: nothing more runs).
    func runAll(_ steps: [TextStep], settings: StepSettings, script: String?,
                extras: (Project?) -> [StepCall] = { _ in [] }) async throws {
        for (i, step) in steps.enumerated() {
            self.step(i)
            try Task.checkCancellation()
            let lo = Double(i) / Double(steps.count), hi = Double(i + 1) / Double(steps.count)
            let state = TextSteps.compute(project())[step]
            if state.status == .done { progress(hi); continue }
            if state.status == .blocked { throw StepError(message: "\(step.title()): \(state.line)") }
            guard let p = project() else { throw CancellationError() }
            let calls: [StepCall]
            switch step {
            case .script: calls = [StepCalls.scriptText(script ?? "")]
            case .captions:
                detail(loc("Scelgo le parole chiave…"))
                calls = StepCalls.plan(.captions, project: p, settings: settings, keywords: await suggest(settings.style))
            default: calls = StepCalls.plan(step, project: p, settings: settings, keywords: [])
            }
            try await run(calls, settings: settings, from: lo, to: hi)
        }
        step(steps.count)
        let more = extras(project())
        guard !more.isEmpty else { return }
        try Task.checkCancellation()
        try await run(more, settings: settings, from: 1, to: 1)
        step(steps.count + 1)
    }
}

/// A step that cannot run, in words (the job shows it).
struct StepError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }

    /// A command's error in words a person can act on. The engine's message only as the last resort, and then after a
    /// translated lead (`fallback`, a format key with one `%@`): never the raw message alone.
    static func readable(_ error: Error, _ lookup: (String) -> String = loc, fallback: String = "Non è riuscito: %@") -> String {
        let raw = JobCenter.message(error)
        // What the engine says (English matchers, not UI) and what the person reads.
        let says = [  // l10n-ignore-begin
            "cancelled",
            "not found at",
            "no uv project",
            "cannot detect the language",
            "tier, this Mac",
            "returned no words",
            "has no audio",
            "no take chosen",
            "no sentences",
            "no script lines",
            "mixes several sources",
            "timeline is empty",
            "No project",
            "is not installed",
            "install it in Settings › Motori",
        ]  // l10n-ignore-end
        let reads = [
            lookup("Annullato: niente è stato modificato."),
            lookup("Il motore che serve non è installato su questo Mac: Impostazioni › Motori dice come installarlo."),
            lookup("Il motore che serve non è installato su questo Mac: Impostazioni › Motori dice come installarlo."),
            lookup("Con questo motore la lingua non si riconosce da sola: scegli la lingua e trascrivi di nuovo."),
            lookup("Questo Mac non ha abbastanza memoria per il motore scelto."),
            lookup("Non ho sentito parole: controlla che il video abbia l'audio e che la lingua sia quella giusta."),
            lookup("Questo video non ha l'audio: importa la registrazione con la voce."),
            lookup("Nessuna riga ha una ripresa scelta: rivedi le riprese."),
            lookup("Nel parlato non ho trovato frasi da usare come copione: incolla il copione."),
            lookup("Il copione è vuoto: incolla il testo, una frase per riga."),
            lookup("La prima pista audio mescola più file: la voce si pulisce da un file solo."),
            lookup("La timeline è vuota: non c'è niente da esportare."),
            lookup("Apri o crea prima un progetto."),
            lookup("Il motore che serve non è installato su questo Mac: Impostazioni › Motori dice come installarlo."),
            lookup("Il motore che serve non è installato su questo Mac: Impostazioni › Motori dice come installarlo."),
        ]
        if let sentence = refusal(raw, lookup) { return sentence }
        let known = Array(zip(says, reads))
        if let hit = known.first(where: { raw.contains($0.0) }) { return hit.1 }
        return String(format: lookup(fallback), raw)
    }

    /// The refusals the recipes meet (#88), whose sentence carries what the engine's text names: the rule as the rules
    /// card names it, the profile, the language by its name, the file. nil when `raw` is none of them.
    static func refusal(_ raw: String, _ lookup: (String) -> String = loc) -> String? {
        func match(_ pattern: String) -> [String]? {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
                  let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)) else { return nil }
            return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: raw).map { String(raw[$0]) } ?? "" }
        }
        // The engine's own words (English matchers, not UI).
        let rules = #"breaks (\d+) editing rules? of its kind \([^)]*\):\s*\n- ([a-z0-9-]+) at "#  // l10n-ignore
        let language = #"^voice (.+) has no ([a-z]{2,3}) \(it speaks"#  // l10n-ignore
        let noVoice = #"^(.+) has no voice yet:"#  // l10n-ignore
        let noProfile = "no profile on this Mac yet"  // l10n-ignore
        let paid = #"is paid \(.*needs the human's approval"#  // l10n-ignore
        let noFile = #"no file at (.+)$"#  // l10n-ignore
        let noLogo = #"kit "(.+)" has no logo yet:"#  // l10n-ignore
        if let m = match(rules), let count = Int(m[0]), let spec = RuleCheckSpec.named(m[1]) {
            let name = lookup(spec.title)
            return count == 1 ? String(format: lookup("Export rifiutato: 1 regola non rispettata — %@"), name)
                : String(format: lookup("Export rifiutato: %1$@ regole non rispettate — la prima: %2$@"), "\(count)", name)
        }
        if let m = match(language) {
            return String(format: lookup("Il profilo «%1$@» non ha una voce in %2$@: registrala nel pannello Voce."), m[0], languageInWords(m[1], lookup))
        }
        if let m = match(noVoice) {
            return String(format: lookup("Il profilo «%@» non ha ancora una voce: registrala nel pannello Voce."), m[0])
        }
        if raw.contains(noProfile) {
            return lookup("Su questo Mac non c'è ancora un profilo: crealo in Impostazioni › Profilo e voce, poi registra la voce nel pannello Voce.")
        }
        if match(paid) != nil {
            return lookup("Una generazione a pagamento parte solo dopo che hai visto il costo e l'hai approvata in Regista.")
        }
        if let m = match(noLogo) { return noLogoLine(m[0], lookup) }
        if let m = match(noFile) {
            return String(format: lookup("Il file «%@» non c'è: forse è stato spostato o rinominato."), (m[0] as NSString).lastPathComponent)
        }
        return nil
    }

    /// A kit without a logo, where the logo would go (#99): the refusal of logo.add and logo.animate, and the reason the
    /// logo switch and the logo animations give before a click.
    static func noLogoLine(_ kit: String, _ lookup: (String) -> String = loc) -> String {
        String(format: lookup("Il kit «%@» non ha ancora un logo: sceglilo in Impostazioni › Brand kit."), kit)
    }

    /// A voice's language by its name in the interface language («inglese», «anglais»).
    static func languageInWords(_ code: String, _ lookup: (String) -> String = loc) -> String {
        switch code {
        case "it": return lookup("italiano")
        case "en": return lookup("inglese")
        case "fr": return lookup("francese")
        case "pt": return lookup("portoghese")
        default: return Words.locale.localizedString(forLanguageCode: code) ?? code
        }
    }
}
