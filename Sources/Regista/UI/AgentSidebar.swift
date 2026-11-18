import RegistaCore
import SwiftUI

/// The activity log (the right panel's Claude tab), the transcript synced to the playhead (click to seek, select and
/// delete = transcript.deleteWords) and the takes to approve or override (Testi e sottotitoli).

// MARK: - Activity

/// The activity log as rows: commands that change something keep their own row; consecutive looks (ui.screenshot,
/// project.state, frame.render… — read-only commands that write nothing the user keeps) by the same source collapse into
/// one quiet row, so an agent reviewing the window does not fill the log.
enum ActivityFeed {
    enum Row: Identifiable, Equatable {
        case step(EditorStore.Activity)
        case looks([EditorStore.Activity])
        var id: UUID {
            switch self {
            case .step(let a): a.id
            case .looks(let l): l[0].id
            }
        }
    }

    /// Read-only commands that still produce something the user keeps (files, brand kits, a paid estimate, a voice
    /// preview): they keep their own row.
    static let visibleQueries: Set<String> = ["export.render", "export.srt", "export.mlt", "brandkit.create", "brandkit.update",
                                              "brandkit.setLogo", "brandkit.setFont", "brandkit.export", "brandkit.import",
                                              "brandkit.delete", "generate.estimate", "recording.synthesize", "voice.preview"]

    /// Whether a command only looks.
    static func isLook(_ id: String, kind: CommandKind?) -> Bool { kind == .query && !visibleQueries.contains(id) }

    /// Consecutive looks by the same source become one row; a failed look stays on its own (the error matters).
    static func rows(_ items: [EditorStore.Activity]) -> [Row] {
        var out: [Row] = []
        for a in items {
            guard a.readOnly, a.status != .failed else { out.append(.step(a)); continue }
            if case .looks(var group)? = out.last, group[0].source == a.source {
                group.append(a)
                out[out.count - 1] = .looks(group)
            } else {
                out.append(.looks([a]))
            }
        }
        return out
    }

    /// Who did it, in words: "Claude" for an agent (whatever name its socket client gave, e.g. "client"), "Tu" for the user.
    static func who(_ a: EditorStore.Activity) -> String { a.isAgent ? "Claude" : loc("Tu") }

    /// "Claude · Guarda la finestra · 17 volte", or "Claude · 5 controlli" when the looks differ.
    static func summary(_ looks: [EditorStore.Activity]) -> String {
        let ids = Set(looks.map(\.command))
        let who = who(looks[0])
        guard ids.count == 1, let id = ids.first else { return String(format: loc("%@ · %d controlli"), who, looks.count) }
        let title = CommandTitles.title(id)
        return looks.count == 1 ? "\(who) · \(title)" : String(format: loc("%@ · %@ · %d volte"), who, title, looks.count)
    }
}

struct ActivityLog: View {
    @EnvironmentObject private var store: EditorStore
    var compact: Bool
    @State private var agentOnly = false
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let items = agentOnly ? store.activity.filter(\.isAgent) : store.activity
        let rows = ActivityFeed.rows(items)
        VStack(spacing: 0) {
            if items.isEmpty {
                EmptyHint(symbol: "sparkles", text: store.agentConnected
                          ? loc("Collegato. I passi di Claude compaiono qui mentre li fa.")
                          : loc("Collega Claude Desktop o Claude Code in Impostazioni › Claude. Lo stato diventa «collegato» alla prima richiesta di Claude."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                switch row {
                                case .step(let a): ActivityRow(a: a, compact: compact).id(row.id)
                                case .looks(let l):
                                    LooksRow(looks: l, open: expanded.contains(row.id)) {
                                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                                    }
                                    .id(row.id)
                                }
                            }
                        }
                        .padding(.vertical, Ed.Space.xs)
                    }
                    .onChange(of: store.activity.last?.id) {
                        if let last = rows.last?.id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) } }
                    }
                    .onAppear { if let last = rows.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
                }
            }
            if !compact {
                HStack {
                    // As wide as its label in each language (#81: a fixed 150 pt cut «Claude seulement»).
                    RToggle(title: loc("Solo Claude"), isOn: $agentOnly).fixedSize()
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 26)
                .overlay(alignment: .top) { Ed.line.frame(height: 1) }
            }
        }
    }
}

/// One quiet row for consecutive looks: what was looked at, how many times, when last; a click lists them.
struct LooksRow: View {
    let looks: [EditorStore.Activity]
    let open: Bool
    let toggle: () -> Void
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button(action: toggle) {
                HStack(spacing: Ed.Space.s) {
                    Image(systemName: "eye").font(Ed.icon(Ed.TypeSize.micro)).foregroundStyle(Ed.text3).frame(width: 10)
                    Text(verbatim: ActivityFeed.summary(looks)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: Ed.Space.xs)
                    Text(verbatim: Self.clock.string(from: looks[looks.count - 1].started)).font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
                    if looks.count > 1 {
                        Image(systemName: open ? "chevron.down" : "chevron.right").font(Ed.icon(Ed.TypeSize.tiny, .semibold)).foregroundStyle(Ed.text3)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(looks.count < 2)
            if open {
                ForEach(looks) { a in
                    HStack(spacing: Ed.Space.s) {
                        Color.clear.frame(width: 10, height: 1)
                        Text(verbatim: CommandTitles.title(a.command)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).lineLimit(1)
                        Spacer(minLength: Ed.Space.xs)
                        Text(verbatim: Self.clock.string(from: a.started)).font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
                    }
                    .help(a.params)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Ed.Space.xs)
    }
}

struct ActivityRow: View {
    let a: EditorStore.Activity
    var compact: Bool
    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        HStack(alignment: .top, spacing: Ed.Space.s) {
            status.frame(width: 10, height: 14)
            VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                HStack(spacing: 6) {
                    Text(verbatim: a.note ?? CommandTitles.title(a.command)).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(a.isAgent ? Ed.text : Ed.text2)
                        .lineLimit(a.note == nil ? 1 : 3)
                    // Ran in a tab the user was not looking at (S2 #76).
                    if let p = a.project {
                        Text(verbatim: String(format: loc("in «%@»"), p)).font(Ed.ui(Ed.TypeSize.micro)).foregroundStyle(Ed.text3).lineLimit(1).truncationMode(.middle)
                    }
                    if !a.isAgent { Text("tu").font(Ed.ui(Ed.TypeSize.micro)).foregroundStyle(Ed.text3) }
                    Spacer(minLength: Ed.Space.xs)
                    Text(verbatim: a.status == .running ? "…" : (a.seconds >= 0.1 ? String(format: "%.1f s", a.seconds) : ""))
                        .font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
                    if !compact { Text(verbatim: Self.clock.string(from: a.started)).font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3) }
                }
                if !a.result.isEmpty {
                    Text(verbatim: a.result).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(a.status == .failed ? Ed.danger : Ed.text2)
                        .lineLimit(a.status == .failed ? 3 : 1).truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(a.status == .running ? Ed.goldSoft.opacity(0.5) : .clear)
        .overlay(alignment: .leading) { if a.isAgent { Rectangle().fill(Ed.gold.opacity(0.7)).frame(width: 2) } }
        .help([a.params, a.details].filter { !$0.isEmpty }.joined(separator: "\n"))   // the details stay one hover away
    }

    @ViewBuilder private var status: some View {
        switch a.status {
        case .running: ProgressView().controlSize(.mini).scaleEffect(0.7)
        case .ok: Image(systemName: "checkmark").font(Ed.icon(Ed.TypeSize.tiny, .bold)).foregroundStyle(Ed.ok).padding(.top, Ed.Space.xxs)
        case .failed: Image(systemName: "xmark").font(Ed.icon(Ed.TypeSize.tiny, .bold)).foregroundStyle(Ed.danger).padding(.top, Ed.Space.xxs)
        }
    }
}

// MARK: - Transcript

struct TranscriptView: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @State private var current = -1
    @State private var anchor: Int?
    /// The paragraph being corrected (its first word index) and the text typed so far.
    @State private var editing: Int?
    @State private var draft = ""

    var body: some View {
        let words = store.words
        VStack(spacing: 0) {
            if words.isEmpty {
                // Not transcribed yet (or nothing on the timeline): the step that makes the words, not a command name.
                StepOffer(step: store.textSteps[.transcribe].status == .done ? .cut : .transcribe, symbol: "text.word.spacing")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(paragraphs(words), id: \.first) { para in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(verbatim: shortTime(words[para.first!].start.seconds)).font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
                                        Spacer()
                                        if editing != para.first {
                                            IconButton(symbol: "pencil", help: "Correggi il testo (sottotitoli inclusi)", size: 18) {
                                                draft = para.map { words[$0].text }.joined(separator: " ")
                                                editing = para.first
                                            }
                                        }
                                    }
                                    if editing == para.first {
                                        editor(para, words)
                                    } else {
                                        FlowLayout(spacing: 0, lineSpacing: Ed.Space.xxs) {
                                            ForEach(para, id: \.self) { i in word(i, words[i]).id(i) }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(Ed.Space.m)
                    }
                    .onChange(of: current) {
                        if store.preview.isPlaying, current >= 0 { proxy.scrollTo(current, anchor: .center) }
                    }
                }
                if let sel = store.wordSelection {
                    HStack(spacing: Ed.Space.s) {
                        Text(verbatim: sel.count == 1 ? loc("1 parola") : loc("%@ parole", String(sel.count))).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text2)
                        Spacer()
                        EdButton(title: "Annulla") { store.wordSelection = nil; anchor = nil }
                        EdButton(title: "Elimina dal montaggio", symbol: "scissors", prominent: true) { store.deleteWords(sel); anchor = nil }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 38)
                    .background(Ed.header)
                    .overlay(alignment: .top) { Ed.line.frame(height: 1) }
                }
            }
        }
        .onReceive(playhead.$time) { t in
            let i = words.lastIndex { $0.start.seconds <= t + 0.001 } ?? -1
            if i != current { current = i }
        }
    }

    /// The text of one paragraph in a field: Invio saves (transcript.editText: only the words change, captions follow).
    private func editor(_ para: [Int], _ words: [TimelineWord]) -> some View {
        let original = para.map { words[$0].text }.joined(separator: " ")
        return VStack(alignment: .leading, spacing: 6) {
            RTextEditor(text: $draft, kind: .grows(1...6), editing: true, onSubmit: { save(para, original) }, onExit: { editing = nil })
            HStack(spacing: 6) {
                Spacer()
                EdButton(title: "Annulla", quiet: true) { editing = nil }
                EdButton(title: "Salva", symbol: "checkmark", prominent: true,
                         disabled: draft.trimmingCharacters(in: .whitespacesAndNewlines) == original) { save(para, original) }
            }
        }
    }

    private func save(_ para: [Int], _ original: String) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editing = nil
        guard text != original, let first = para.first, let last = para.last else { return }
        store.run("transcript.editText", ["from": .number(Double(first)), "to": .number(Double(last)),
                                          "text": .string(text), "expect": .string(original)])
    }

    /// Word indices grouped by clip.
    private func paragraphs(_ words: [TimelineWord]) -> [[Int]] {
        var out: [[Int]] = []
        for (i, w) in words.enumerated() {
            if i > 0, words[i - 1].clipID == w.clipID { out[out.count - 1].append(i) } else { out.append([i]) }
        }
        return out
    }

    private func word(_ i: Int, _ w: TimelineWord) -> some View {
        let selected = store.wordSelection?.contains(i) ?? false
        let isCurrent = i == current
        return Text(verbatim: w.text + " ")
            .font(Ed.ui(Ed.TypeSize.body, isCurrent ? .semibold : .regular))
            .foregroundStyle(selected ? Color.black : (isCurrent ? Ed.gold : (i < current ? Ed.text : Ed.text2)))
            .padding(.horizontal, 1)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.xs).fill(selected ? Ed.gold.opacity(0.9) : .clear))
            .contentShape(Rectangle())
            .onTapGesture {
                let keys = NSEvent.clickModifiers
                if keys.contains(.shift), let a = anchor ?? store.wordSelection?.lowerBound {
                    store.wordSelection = min(a, i)...max(a, i)
                } else if keys.contains(.command) || keys.contains(.option) {
                    anchor = i
                    store.wordSelection = i...i
                } else {
                    anchor = i
                    store.wordSelection = nil
                    store.preview.seek(w.start.seconds)
                }
            }
            .help(loc("%@ · clic: vai qui · ⌥clic: seleziona · ⇧clic: estendi · ⌫ elimina", shortTime(w.start.seconds)))
    }
}

// MARK: - Takes

struct TakesView: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        if let takes = store.project?.takes, !takes.lines.isEmpty {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(takes.lines.enumerated()), id: \.offset) { i, line in row(i + 1, line).id(i) }
                    }
                }
                HStack(spacing: Ed.Space.s) {
                    Text("Dopo una scelta: rifai il taglio").font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).lineLimit(1)
                    Spacer()
                    EdButton(title: loc("Rifai il taglio"), symbol: "scissors", disabled: store.runningStepJob != nil) {
                        store.runStep(.cut, settings: StepSettings.saved(project: store.project))
                    }
                    .tip("Rimonta con le riprese scelte (poi riapplica voce pulita e inquadrature)")
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Ed.header)
                .overlay(alignment: .top) { Ed.line.frame(height: 1) }
            }
        } else {
            StepOffer(step: .takes)
        }
    }

    private func row(_ n: Int, _ line: TakeLine) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                Text(verbatim: "\(n)").font(Ed.mono(Ed.TypeSize.caption, .semibold)).foregroundStyle(Ed.gold).frame(width: 16, alignment: .trailing)
                Text(verbatim: line.text).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Ed.Space.xs) {
                Color.clear.frame(width: 16, height: 1)
                if line.takes.isEmpty { Text("mai letta").font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.danger) }
                ForEach(Array(line.takes.enumerated()), id: \.offset) { k, take in chip(n, k, take, line) }
                Spacer(minLength: Ed.Space.xs)
                if let c = line.chosen {
                    IconButton(symbol: "checkmark.circle", help: loc("Approva la ripresa %@", String(c + 1)), size: 20) {
                        store.run("takes.select", ["line": .number(Double(n)), "take": .number(Double(c + 1))])
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Ed.Space.s)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }

    /// Word error rate, a technical measure: the same abbreviation in every language.
    private static let wer = "WER "   // l10n-ignore

    private func chip(_ line: Int, _ k: Int, _ take: Take, _ l: TakeLine) -> some View {
        let chosen = l.chosen == k
        return Button {
            store.run("takes.select", ["line": .number(Double(line)), "take": .number(Double(k + 1))])
        } label: {
            HStack(spacing: 3) {
                Text(verbatim: loc("R%@", String(k + 1))).font(Ed.mono(Ed.TypeSize.caption, .semibold))
                if l.auto == k { Circle().fill(Ed.gold).frame(width: 4, height: 4) }
            }
            .foregroundStyle(chosen || take.complete ? Ed.text : Ed.text3)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(chosen ? Ed.goldSoft : Ed.raised))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(chosen ? Ed.gold.opacity(0.6) : (take.complete ? .clear : Ed.text3),
                                                                    style: StrokeStyle(lineWidth: 1, dash: take.complete || chosen ? [] : [2, 2])))
        }
        .buttonStyle(.plain)
        .tip(loc("Ripresa %@: %@–%@", String(k + 1), shortTime(take.start.seconds), shortTime(take.end.seconds))
             + " · " + (take.complete ? loc("completa") : loc("incompleta")) + " · " + Self.wer + String(format: "%.2f", take.wer)
             + (l.auto == k ? " · " + loc("scelta automatica") : "") + "\n" + take.text)
    }
}
