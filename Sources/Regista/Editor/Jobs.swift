import Foundation

/// Long work the user started (issue #54): a voice render, a voice take being checked,
/// a training; later transcription, render and downloads (node E2 surfaces this list in the top bar). Each job has a
/// title, a progress (nil: indeterminate), a line of detail, a Cancel that really stops the work when the job has one,
/// and ends done, failed (with a readable message) or cancelled. The window never waits on a job.
@MainActor
final class JobCenter: ObservableObject {
    enum State: Equatable {
        case running, done, cancelled
        case failed(String)
    }

    struct Job: Identifiable, Equatable {
        let id: UUID
        /// What it is about ("voice", "voice-take", "voice-training"): panels find their job by kind.
        var kind: String
        /// A human title in the user's language (a lookup key is fine too: JobCard draws loc(title)).
        var title: String
        var detail = ""
        /// 0…1, nil while unknown.
        var progress: Double?
        var state: State = .running
        var cancellable: Bool
        var started = Date()
        /// The tab it belongs to (its project's name), for the jobs list of the whole window.
        var tab = ""
        /// The steps of a job made of several ("Fai tutto": Trascrivi, Riprese…) and the one running now.
        var steps: [String] = []
        var stepIndex = 0

        var isRunning: Bool { state == .running }
    }

    /// What a job's work sees: report progress, ask whether it was cancelled.
    @MainActor
    struct Handle {
        let id: UUID
        weak var center: JobCenter?

        func update(progress: Double? = nil, detail: String? = nil) { center?.update(id, progress: progress, detail: detail) }
        var isCancelled: Bool { center?.job(id)?.state == .cancelled }
        /// The sub-steps of the job, and which one runs now.
        func steps(_ titles: [String]) { center?.setSteps(id, titles) }
        func step(_ index: Int) { center?.setStep(id, index) }
    }

    @Published private(set) var jobs: [Job] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var cancelHooks: [UUID: () -> Void] = [:]

    init(jobs: [Job] = []) { self.jobs = jobs }

    /// Starts `work` as a job. `onCancel` stops what runs outside this task (a process); the task is cancelled too.
    @discardableResult
    func start(kind: String, title: String, tab: String = "", cancellable: Bool = true, onCancel: (() -> Void)? = nil,
               _ work: @escaping @MainActor (Handle) async throws -> Void) -> UUID {
        let id = UUID()
        jobs.removeAll { $0.kind == kind && !$0.isRunning }   // one finished job per kind stays visible
        jobs.append(Job(id: id, kind: kind, title: title, cancellable: cancellable, tab: tab))
        if let onCancel { cancelHooks[id] = onCancel }
        let handle = Handle(id: id, center: self)
        tasks[id] = Task { @MainActor [weak self] in
            do {
                try await work(handle)
                self?.finish(id, .done)
            } catch {
                self?.finish(id, error is CancellationError ? .cancelled : .failed(JobCenter.message(error)))
            }
        }
        return id
    }

    func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    /// The newest job of a kind (running or the last finished one).
    func latest(_ kind: String) -> Job? { jobs.last { $0.kind == kind } }

    func update(_ id: UUID, progress: Double?, detail: String?) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isRunning else { return }
        if let progress { jobs[i].progress = min(max(progress, 0), 1) }
        if let detail { jobs[i].detail = detail }
    }

    /// The work runs on with no measurable progress for now: an indeterminate bar (with the elapsed time).
    func progressUnknown(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isRunning else { return }
        jobs[i].progress = nil
    }

    func setSteps(_ id: UUID, _ titles: [String]) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[i].steps = titles
    }

    func setStep(_ id: UUID, _ index: Int) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isRunning else { return }
        jobs[i].stepIndex = index
    }

    /// Cancel: the job shows cancelled at once; the hook stops the process; whatever the work returns afterwards is ignored.
    func cancel(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isRunning, jobs[i].cancellable else { return }
        jobs[i].state = .cancelled
        cancelHooks.removeValue(forKey: id)?()
        tasks.removeValue(forKey: id)?.cancel()
    }

    /// Cancels every running job (its tab is closing).
    func cancelAll() {
        for j in jobs where j.isRunning { cancel(j.id) }
    }

    /// Removes a finished job from the list.
    func dismiss(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), !jobs[i].isRunning else { return }
        jobs.remove(at: i)
    }

    private func finish(_ id: UUID, _ state: State) {
        tasks[id] = nil
        cancelHooks[id] = nil
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].isRunning else { return }
        jobs[i].state = state
        if state == .done { jobs[i].progress = 1 }
    }

    /// A readable message for an error (the command's message without the command id prefix).
    nonisolated static func message(_ error: Error) -> String {
        var s = "\(error)"
        if let r = s.range(of: #"^[a-z]+(\.[a-zA-Z]+)+: "#, options: .regularExpression) { s.removeSubrange(r) }  // l10n-ignore
        return s
    }
}
