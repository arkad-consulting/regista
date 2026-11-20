import SwiftUI

/// One job as a card: title, a thin progress bar (moving shimmer while the progress is unknown), the detail line,
/// Annulla while it runs (when it can be stopped), the elapsed time, the sub-steps of a job made of several, the error in
/// plain words when it failed. The panels show their job with it; the jobs list of the status bar shows every job (E2).
struct JobCard: View {
    let job: JobCenter.Job
    var onCancel: () -> Void = {}
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            HStack(spacing: Ed.Space.s) {
                stateIcon
                Text(verbatim: loc(job.title)).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text).lineLimit(1)
                Spacer(minLength: Ed.Space.xs)
                if job.isRunning, job.cancellable {
                    EdButton(title: loc("Annulla"), action: onCancel).fixedSize()
                } else if !job.isRunning, let onDismiss {
                    IconButton(symbol: "xmark", help: "Togli dalla lista", size: 18, action: onDismiss)
                }
            }
            if job.isRunning { JobProgressBar(progress: job.progress, estimated: job.estimated) }
            if !job.steps.isEmpty { subSteps }
            if detail != nil || job.isRunning {
                HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                    if let line = detail {
                        Text(verbatim: line).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(lineColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if job.isRunning {
                        // The elapsed time always (an indeterminate bar still says the work is moving), the percent when known,
                        // and "stima" when the percent is an estimate (#13).
                        SwiftUI.TimelineView(.periodic(from: job.started, by: 1)) { t in
                            Text(verbatim: (job.progress.map { JobProgressBar.percent($0, estimated: job.estimated) + " · " } ?? "") + clockTime(t.date.timeIntervalSince(job.started)))
                                .font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).fixedSize()
                        }
                    }
                }
            }
        }
        .rCard(border: job.isRunning ? Ed.gold.opacity(0.28) : nil)
    }

    /// The steps of a job made of several, each with its state (done, running, stopped there, to come).
    private var subSteps: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(job.steps.enumerated()), id: \.offset) { i, title in
                let done = i < job.stepIndex || job.state == .done
                let here = i == job.stepIndex && job.state != .done
                HStack(spacing: 6) {
                    Group {
                        if done { Image(systemName: "checkmark").foregroundStyle(Ed.ok) }
                        else if here && job.isRunning { Circle().fill(Ed.gold).frame(width: 5, height: 5) }
                        else if here, case .failed = job.state { Image(systemName: "xmark").foregroundStyle(Ed.warn) }
                        else { Circle().strokeBorder(Ed.text3, lineWidth: 1).frame(width: 5, height: 5) }
                    }
                    .font(Ed.icon(Ed.TypeSize.tiny, .bold)).frame(width: 10)
                    Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.caption, here ? .semibold : .regular))
                        .foregroundStyle(here ? Ed.text : (done ? Ed.text2 : Ed.text3))
                }
            }
        }
    }

    private var detail: String? {
        switch job.state {
        case .failed(let m): m
        case .cancelled: loc("Annullato: niente è stato modificato.")
        default: job.detail.isEmpty ? nil : job.detail
        }
    }

    private var lineColor: Color {
        if case .failed = job.state { return Ed.warn }
        return Ed.text2
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch job.state {
        case .running: ProgressView().controlSize(.mini).tint(Ed.gold).frame(width: 14, height: 14)
        case .done: Image(systemName: "checkmark.circle.fill").font(Ed.icon(Ed.TypeSize.body)).foregroundStyle(Ed.ok)
        case .cancelled: Image(systemName: "minus.circle").font(Ed.icon(Ed.TypeSize.body)).foregroundStyle(Ed.text3)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.warn)
        }
    }
}

/// A thin capsule filled in the accent; without a known progress, a short segment sweeps across. An estimated progress
/// draws the same bar; an assistive client hears "stima" with its value (#13).
struct JobProgressBar: View {
    let progress: Double?
    var estimated = false

    /// "45 %" (French), "45%" (English, Italian, Portuguese), or "45% · stima" for an estimate: the percent as the
    /// words' language writes it.
    static func percent(_ p: Double, estimated: Bool) -> String {
        ((p * 100).rounded() / 100).formatted(.percent.precision(.fractionLength(0)).locale(Words.locale)) + (estimated ? " · " + loc("stima") : "")
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Ed.well).overlay(Capsule().strokeBorder(Ed.line2, lineWidth: 0.5))
                if let p = progress {
                    Capsule().fill(LinearGradient(colors: [Ed.gold.opacity(0.45), Ed.gold], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * p))
                        .animation(.easeOut(duration: 0.35), value: p)
                } else {
                    TimelineView(.animation) { t in
                        let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule().fill(Ed.gold.opacity(0.8))
                            .frame(width: geo.size.width * 0.28)
                            .offset(x: (geo.size.width * 1.28) * phase - geo.size.width * 0.28)
                    }
                    .clipShape(Capsule())
                }
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel(loc("Avanzamento"))
        .accessibilityValue(progress.map { Self.percent($0, estimated: estimated) } ?? loc("in corso"))
    }
}
