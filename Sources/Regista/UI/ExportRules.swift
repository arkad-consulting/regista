import RegistaCore
import SwiftUI

// The editing rules on the Export panel (#31): the project's kind, the checks that fail with «go to» and «fix», the ones
// that pass in one line. One line when everything passes; it grows only when something fails. The panel then offers
// «fix all and export» (when a fix exists) and «export anyway», which a person can always use.

/// rules.check (and the kinds of rules.list) as the card draws them.
struct RulesReport: Equatable {
    struct Violation: Equatable, Identifiable {
        let id: Int
        let check: String
        /// The check's English title (a lookup key).
        let title: String
        /// In the app's language.
        let message: String
        let time: Double
        let blocking: Bool
        /// The fix's command call, when the engine offers one.
        let fix: StepCall?
    }

    var kind: String
    /// The kind's name as the person reads it.
    var kindTitle: String
    /// The project has no kind of its own: the kind follows its format.
    var followsFormat: Bool
    var violations: [Violation]
    /// The English titles of the checks that ran and passed.
    var passed: [String]
    var problems: [String]
    var kinds: [RulesModel.Sheet]
    /// The checks that could not be measured here (an engine or a render missing): a grey line each, never passed.
    var unchecked: [Unchecked] = []

    /// A check not measured: its English title (a lookup key) and why, in the app's language.
    struct Unchecked: Equatable, Identifiable {
        var id: String { check }
        let check: String
        let title: String
        let reason: String
    }

    var failures: [Violation] { violations.filter(\.blocking) }
    var fixable: Bool { failures.contains { $0.fix != nil } }

    init(kind: String, kindTitle: String, followsFormat: Bool = true, violations: [Violation], passed: [String], problems: [String],
         kinds: [RulesModel.Sheet], unchecked: [Unchecked] = []) {
        self.unchecked = unchecked
        self.kind = kind
        self.kindTitle = kindTitle
        self.followsFormat = followsFormat
        self.violations = violations
        self.passed = passed
        self.problems = problems
        self.kinds = kinds
    }

    init(check c: JSONValue, list: JSONValue?) {
        let kinds = (list?["sheets"]?.arrayValue ?? []).compactMap(RulesModel.sheet).filter { $0.kind != RuleBook.everyVideo }
        let kind = c["kind"]?.stringValue ?? ""
        let checks = c["checks"]?.arrayValue ?? []
        func title(_ id: String) -> String { checks.first { $0["id"]?.stringValue == id }?["title"]?.stringValue ?? id }
        let violations = (c["violations"]?.arrayValue ?? []).enumerated().map { i, v in
            let check = v["check"]?.stringValue ?? ""
            let fix = v["fix"].flatMap { f in f["command"]?.stringValue.map { StepCall(id: $0, params: f["params"] ?? [:]) } }
            return Violation(id: i, check: check, title: title(check), message: loc(message: v), time: v["time"]?.doubleValue ?? 0,
                             blocking: v["severity"]?.stringValue != "warn", fix: fix)
        }
        let passed = checks.filter { $0["ran"]?.boolValue == true && ($0["violations"]?.doubleValue ?? 0) == 0 }.compactMap { $0["title"]?.stringValue }
        let unchecked = checks.filter { $0["on"]?.boolValue != false && $0["ran"]?.boolValue == false && ($0["skipped"] ?? .null) != .null }.map {
            Unchecked(check: $0["id"]?.stringValue ?? "", title: $0["title"]?.stringValue ?? "", reason: loc(message: $0["skipped"]))
        }
        let problems = (c["sheetProblems"]?.arrayValue ?? []).map { loc(message: $0) } + (c["note"].flatMap { $0 == .null ? nil : [loc(message: $0)] } ?? [])
        let shown = kinds.first { $0.kind == kind }?.shownTitle ?? loc(c["kindTitle"]?.stringValue ?? kind)
        self.init(kind: kind, kindTitle: shown, followsFormat: c["kindSource"]?.stringValue != "project", violations: violations, passed: passed,
                  problems: problems, kinds: kinds, unchecked: unchecked)
    }

    /// Sample reports for the renders (ui.screenshot export-rules, export-rules-pass): a reel with three rules broken and one
    /// check it could not measure, and one that passes.
    static func sample(failing: Bool) -> RulesReport {
        let book = RuleBook(directory: URL(fileURLWithPath: "/nonexistent"))
        let kinds = RuleBook.builtInKinds.map { RulesModel.Sheet(kind: $0, title: book.title($0, language: "en"), builtIn: true, edited: false) }
        let all = RuleCheckSpec.all.filter { $0.applies(to: "talking-head-reel") }.map(\.title)
        let reading = RuleCheckSpec.named("reading-time")!.title
        guard failing else {
            return RulesReport(kind: "talking-head-reel", kindTitle: loc("Talking-head reel"), violations: [], passed: all, problems: [], kinds: kinds)
        }
        // l10n-ignore-begin — sample data: the engine's own message keys and values
        let violations = [
            Violation(id: 0, check: "title-captions", title: RuleCheckSpec.all[0].title,
                      message: loc("Captions show while the opening title is on screen (%1$@–%2$@ s).", Words.number(0), Words.number(2)), time: 0.3, blocking: true,
                      fix: StepCall(id: "captions.clear", params: ["from": 0, "to": 2])),
            Violation(id: 1, check: "logo-pause", title: RuleCheckSpec.all[2].title,
                      message: loc("The logo enters %1$@ s before the last spoken word ends: the pause must be at least %2$@ s.", Words.number(0.3), Words.number(0.3)),
                      time: 41.5, blocking: true, fix: StepCall(id: "timeline.move", params: ["clipId": "logo", "start": 42.2])),
            Violation(id: 2, check: "reading-time", title: reading,
                      message: loc("«%1$@» is on screen %2$@ s and needs %3$@ s to be read: %4$@ s missing.", "TRE ERRORI DA EVITARE", Words.number(1.2),
                                   Words.number(2.1), Words.number(0.9)),
                      time: 12.4, blocking: true, fix: StepCall(id: "timeline.trim", params: ["clipId": "title2", "edge": "end", "to": 14.5])),
        ]
        let timing = RuleCheckSpec.named("captions-timing")!.title
        let unchecked = [Unchecked(check: "captions-timing", title: timing, reason: loc("No render of this edit yet: export it, then check again."))]
        // l10n-ignore-end
        let shown = [RuleCheckSpec.all[0].title, RuleCheckSpec.all[2].title, reading, timing]
        return RulesReport(kind: "talking-head-reel", kindTitle: loc("Talking-head reel"), violations: violations,
                           passed: all.filter { !shown.contains($0) }, problems: [], kinds: kinds, unchecked: unchecked)
    }
}

private struct RulesDemoKey: EnvironmentKey { static let defaultValue: RulesReport? = nil }

extension EnvironmentValues {
    /// The Export card drawn from a sample report (ui.screenshot export-rules / export-rules-pass).
    var rulesDemo: RulesReport? {
        get { self[RulesDemoKey.self] }
        set { self[RulesDemoKey.self] = newValue }
    }
}

/// The card's report, checked again when the project changes (after a short pause) and when a rule sheet is written.
@MainActor
final class ExportRulesModel: ObservableObject {
    @Published var report: RulesReport?
    /// The kinds are open under the card's kind button.
    @Published var choosing = false
    weak var store: EditorStore?
    private var list: JSONValue?

    /// Seconds after the last change before the project is checked again.
    static let pause: Double = 0.4

    func refresh() async {
        guard let store, store.project != nil else { report = nil; return }
        guard let check = try? await store.silent("rules.check") else { return }
        list = (try? await store.silent("rules.list")) ?? list
        report = RulesReport(check: check, list: list)
    }

    /// rules.fix {all: true} (one undo step), then the check it returns: true when nothing blocks the export any more.
    func fixAll() async -> Bool {
        guard let store else { return false }
        do {
            let r = try await store.perform(ExportCalls.fixAll.id, ExportCalls.fixAll.params)
            if let c = r["check"] { report = RulesReport(check: c, list: list) }
            return report?.failures.isEmpty ?? false
        } catch {
            store.show(error)
            return false
        }
    }
}

/// The card itself (inside the Export panel's scroll view).
struct ExportRulesCard: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.openSettings) private var openSettings
    let report: RulesReport
    @ObservedObject var model: ExportRulesModel
    /// A render: the links and buttons do nothing.
    var demo = false

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            VStack(alignment: .leading, spacing: 0) {
                if report.failures.isEmpty { compact } else { header }
                if model.choosing { kinds }
                ForEach(report.violations) { v in
                    Ed.line.frame(height: 1)
                    violation(v)
                }
                if !report.failures.isEmpty, !report.passed.isEmpty {
                    Ed.line.frame(height: 1)
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark").font(Ed.icon(Ed.TypeSize.caption, .bold)).foregroundStyle(Ed.ok)
                        Text(verbatim: report.passed.map { loc($0) }.joined(separator: ", "))
                            .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Ed.Space.m).padding(.vertical, 9)
                }
                ForEach(report.problems, id: \.self) { p in
                    Ed.line.frame(height: 1)
                    Label { Text(verbatim: p) } icon: { Image(systemName: "exclamationmark.triangle") }
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Ed.Space.m).padding(.vertical, Ed.Space.s)
                }
            }
            .rCard(.raised, border: report.failures.isEmpty ? nil : Ed.danger.opacity(0.45), padding: 0)
            VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                if report.fixable {
                    Text(verbatim: loc("«Sistema» applica la correzione come un comando qualsiasi: un passo di annulla."))
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                }
                AccentLinkButton(title: "Le regole si cambiano in Impostazioni › Regia e skill") {
                    guard !demo else { return }
                    SettingsRoute.openRules(kind: report.kind, with: openSettings)
                }
            }
        }
    }

    private var kindButton: some View {
        // Named by the kind it shows (a tooltip would name it instead).
        // Whole (the text beside it wraps instead).
        EdButton(title: report.kindTitle, symbol: model.choosing ? "chevron.up" : "chevron.down") { model.choosing.toggle() }
            .fixedSize()
    }

    /// Everything passes: one line, the kind beside it; under it when a long kind's name leaves the line no room (the
    /// words were broken letter by letter beside «Tutorial dello schermo»).
    private var compact: some View {
        let words = Text(verbatim: Plural.text(report.passed.count, "1 controllo rispettato", "%@ controlli rispettati"))
            .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2)
        let check = Image(systemName: "checkmark.circle.fill").font(Ed.icon(Ed.TypeSize.body)).foregroundStyle(Ed.ok)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: Ed.Space.s) {
                check
                words.fixedSize()
                Spacer(minLength: Ed.Space.xs)
                kindButton
            }
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) { check; words.fixedSize(horizontal: false, vertical: true) }
                kindButton
            }
        }
        .padding(.horizontal, Ed.Space.m).padding(.vertical, Ed.Space.s)
    }

    private var header: some View {
        // The title and the count on their lines, the kind whole beside them; under them when there is no room.
        let title = VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: loc("Regole di montaggio")).font(Ed.ui(Ed.TypeSize.control, .bold)).foregroundStyle(Ed.text)
            Text(verbatim: loc("%1$@ da sistemare · %2$@ rispettate", "\(report.failures.count)", "\(report.passed.count)"))
                .font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.danger)
        }
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Ed.Space.s) {
                title.fixedSize()
                Spacer(minLength: Ed.Space.xs)
                kindButton
            }
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                title.fixedSize(horizontal: false, vertical: true)
                kindButton
            }
        }
        .padding(.horizontal, Ed.Space.m).padding(.vertical, 10)
    }

    /// The kinds, under a first entry that leaves the kind to the project's format (project.setKind without a kind, #47),
    /// chosen while the project has no kind of its own; its line names the kind the format gives.
    private var kinds: some View {
        let format = store.project.map { RuleBook.kind(width: $0.settings.width, height: $0.settings.height) }
        let formatTitle = format.flatMap { f in report.kinds.first { $0.kind == f }?.shownTitle }
        let follow = RChoiceList<String>.Item(id: "", title: loc("Segui il formato del progetto"), subtitle: formatTitle, symbol: "aspectratio")
        return RChoiceList(items: [follow] + report.kinds.map { .init(id: $0.kind, title: $0.shownTitle, symbol: RulesSettings.symbol($0.kind)) },
                           selection: report.followsFormat ? "" : report.kind) { k in
            model.choosing = false
            guard !demo else { return }
            if k.isEmpty {
                guard !report.followsFormat else { return }
                store.run("project.setKind")
            } else {
                guard k != report.kind || report.followsFormat else { return }
                store.run("project.setKind", ["kind": .string(k)])
            }
        }
        .padding(.horizontal, Ed.Space.xs).padding(.bottom, Ed.Space.xs)
    }

    /// The checks not measured here, under the card and its buttons (the way on stays right under what fails): a grey
    /// line each with why, never counted as passed, never a control (#145).
    static func unchecked(_ report: RulesReport) -> some View {
        // Checks not measured for the same reason (no face track: the logo and the captions) share one line.
        let groups = report.unchecked.reduce(into: [(reason: String, titles: [String])]()) { g, u in
            if let i = g.firstIndex(where: { $0.reason == u.reason }) { g[i].titles.append(loc(u.title)) } else { g.append((u.reason, [loc(u.title)])) }
        }
        return VStack(alignment: .leading, spacing: Ed.Space.xs) {
            ForEach(groups, id: \.reason) { group in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "circle.dashed").font(Ed.icon(Ed.TypeSize.caption, .bold)).foregroundStyle(Ed.text3)
                    Text(verbatim: loc("%1$@ — non controllato: %2$@", group.titles.joined(separator: " · "), group.reason))
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, Ed.Space.xs)
    }

    private func violation(_ v: RulesReport.Violation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle").font(Ed.icon(Ed.TypeSize.body, .semibold))
                .foregroundStyle(v.blocking ? Ed.danger : Ed.warn).padding(.top, 1)
            VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                Text(verbatim: loc(v.title)).font(Ed.ui(Ed.TypeSize.body, .semibold)).foregroundStyle(Ed.text).fixedSize(horizontal: false, vertical: true)
                Text(verbatim: v.message).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Ed.Space.m) {
                    AccentLinkButton(title: loc("Vai a %@", Self.time(v.time))) {
                        guard !demo else { return }
                        store.preview.seek(v.time)
                    }
                    if let fix = v.fix {
                        AccentLinkButton(title: "Sistema") {
                            guard !demo else { return }
                            store.run(fix.id, fix.params)
                        }
                    }
                }
                .padding(.top, Ed.Space.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Ed.Space.m).padding(.vertical, 10)
    }

    /// "0:41".
    static func time(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
