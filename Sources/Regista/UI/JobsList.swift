import RegistaCore
import SwiftUI

/// Re-published whenever a job of any tab changes, so the status bar's jobs item follows every tab without making the
/// whole window redraw on each progress step (the workbench owns one; each tab's JobCenter pings it).
@MainActor
final class JobsHub: ObservableObject {}

/// Sample jobs a ui.screenshot render draws instead of the real ones (`jobs`), the list open or closed.
struct JobsDemo {
    var groups: [(tab: String, jobs: [JobCenter.Job])]
    var open: Bool

    /// A transcription at 42 %, an export with no measurable progress yet, a "Fai tutto" on its third step in another
    /// tab, a voice cleaning that failed, a finished render.
    static func samples(open: Bool, lookup: (String) -> String = loc) -> JobsDemo {
        let now = Date()
        let it = StepSettings.languageName("it")
        let launchFile = "Reel lancio.mp4", interviewFile = "Intervista Ada.mp4"   // l10n-ignore: sample file names
        func job(_ kind: String, _ title: String, _ detail: String, _ p: Double?, _ state: JobCenter.State = .running, ago: Double) -> JobCenter.Job {
            var j = JobCenter.Job(id: UUID(), kind: kind, title: title, detail: detail, progress: p, state: state, cancellable: true, started: now - ago)
            j.tab = ""
            return j
        }
        var all = job(TextStep.allJobKind, lookup("Fai tutto"), lookup("Cerco le letture di ogni riga…"), 0.46, ago: 95)
        all.steps = [TextStep.transcribe, .takes, .cut, .clean, .captions].map { $0.title(lookup) }
        all.stepIndex = 1
        return JobsDemo(groups: [
            (lookup("Reel lancio"), [job(TextStep.transcribe.jobKind, lookup("Trascrivi"), String(format: lookup("Trascrivo il parlato (%@)…"), it), 0.42, ago: 48),
                                     job("export", String(format: lookup("Esporto «%@»"), launchFile), lookup("Mix dell'audio e fotogrammi…"), nil, ago: 7),
                                     job(TextStep.clean.jobKind, lookup("Pulisci la voce"),
                                         "", nil, .failed(lookup("Il motore che serve non è installato su questo Mac: Impostazioni › Motori dice come installarlo.")), ago: 300)]),
            (lookup("Intervista Ada"), [all, job("export", String(format: lookup("Esporto «%@»"), interviewFile), String(format: lookup("Salvato in %@"), "Export"), 1, .done, ago: 600)]),
        ], open: open)
    }
}

private struct JobsDemoKey: EnvironmentKey { static let defaultValue: JobsDemo? = nil }

extension EnvironmentValues {
    /// Sample jobs an offscreen render draws (ui.screenshot `jobs`).
    var jobsDemo: JobsDemo? {
        get { self[JobsDemoKey.self] }
        set { self[JobsDemoKey.self] = newValue }
    }
}

/// The status bar's jobs item: the running count and their progress; a click opens every job of every tab with its
/// progress, Cancel and error (rule 6 of the manual-UI spec). Hidden while there is no job.
struct JobsStatusItem: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.jobsDemo) private var demo

    var body: some View { Content(hub: store.bench.jobsHub, bench: store.bench, demo: demo) }

    private struct Content: View {
        @ObservedObject var hub: JobsHub
        let bench: Workbench
        let demo: JobsDemo?
        @State private var open = false
        @State private var hover = false

        private var groups: [(tab: String, jobs: [JobCenter.Job])] {
            demo?.groups ?? bench.tabs.map { ($0.tabTitle, $0.jobs.jobs) }.filter { !$0.1.isEmpty }
        }

        var body: some View {
            let all = groups.flatMap(\.jobs)
            let running = all.filter(\.isRunning)
            let failed = all.contains { if case .failed = $0.state { return true }; return false }
            if !all.isEmpty {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) {
                        if !running.isEmpty {
                            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
                            Text(verbatim: running.count == 1 ? loc(running[0].title) : String(format: loc("%d lavori"), running.count))
                                .foregroundStyle(Ed.text2).lineLimit(1).frame(maxWidth: 180, alignment: .leading).fixedSize()
                            JobProgressBar(progress: Self.overall(running)).frame(width: 54)
                        } else {
                            Image(systemName: failed ? "exclamationmark.triangle.fill" : "checkmark.circle")
                                .font(Ed.icon(Ed.TypeSize.caption)).foregroundStyle(failed ? Ed.warn : Ed.text3)
                            Text(verbatim: loc("Lavori")).foregroundStyle(Ed.text3)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(hover || open ? Ed.control : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hover = $0 }
                .tip("Lavori in corso: avanzamento, Annulla ed errori di ogni scheda")
                .popover(isPresented: $open, arrowEdge: .top) {
                    JobsListView(groups: groups, bench: bench).environment(\.colorScheme, .dark)
                }
                // A render cannot show a popover: the list is drawn above the item instead.
                .overlay(alignment: .bottomTrailing) {
                    if demo?.open == true {
                        JobsListView(groups: groups, bench: nil)
                            .background(RoundedRectangle(cornerRadius: Ed.Radius.xl).fill(Ed.panel))
                            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.xl).strokeBorder(Ed.line2))
                            .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
                            .fixedSize()
                            .offset(y: -(Chrome.statusHeight + 4))
                    }
                }
            }
        }

        /// The mean known progress of the running jobs (nil when none is known: an indeterminate bar).
        static func overall(_ jobs: [JobCenter.Job]) -> Double? {
            let known = jobs.compactMap(\.progress)
            return known.isEmpty ? nil : known.reduce(0, +) / Double(known.count)
        }
    }
}

/// Every job of every tab, grouped by tab, newest last: progress, Cancel, the error; finished ones can be cleared.
struct JobsListView: View {
    let groups: [(tab: String, jobs: [JobCenter.Job])]
    /// nil in a render (the buttons do nothing).
    let bench: Workbench?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("Lavori")
                Spacer()
                if groups.contains(where: { $0.jobs.contains { !$0.isRunning } }) {
                    AccentLinkButton(title: loc("Togli i finiti"), tip: "Togli dalla lista i lavori finiti, annullati o non riusciti") { clearFinished() }
                }
            }
            .padding(.horizontal, Ed.Space.m).frame(height: 32)
            Ed.line.frame(height: 1)
            if groups.isEmpty {
                Text(verbatim: loc("Nessun lavoro in corso.")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).padding(Ed.Space.m)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Ed.Space.s) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                        if groups.count > 1 {
                            Text(verbatim: g.tab).font(Ed.ui(Ed.TypeSize.caption, .semibold)).foregroundStyle(Ed.text2).lineLimit(1)
                                .padding(.top, Ed.Space.xs)
                        }
                        // Running first, then the finished ones; newest first in each.
                        ForEach(g.jobs.sorted { ($0.isRunning ? 1 : 0, $0.started) > ($1.isRunning ? 1 : 0, $1.started) }) { job in
                            JobCard(job: job, onCancel: { center(of: job)?.cancel(job.id) },
                                    onDismiss: { center(of: job)?.dismiss(job.id) })
                        }
                    }
                }
                .padding(Ed.Space.m)
            }
            .frame(maxHeight: 460)
        }
        .frame(width: 360)
        .background(Ed.panel)
    }

    private func center(of job: JobCenter.Job) -> JobCenter? {
        bench?.tabs.first { t in t.jobs.jobs.contains { $0.id == job.id } }?.jobs
    }

    private func clearFinished() {
        for t in bench?.tabs ?? [] { for j in t.jobs.jobs where !j.isRunning { t.jobs.dismiss(j.id) } }
    }
}
