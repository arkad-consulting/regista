import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

/// Esporta's choices, shared by the side panel (settings) and the main area (program monitor).
@MainActor
final class ExportOptions: ObservableObject {
    static let shared = ExportOptions()
    @Published var preset = "9:16"
    @Published var captions = true
    @Published var bitrate = 14.0
    /// The last file written (Mostra nel Finder).
    @Published var lastFile: URL?
}

/// The commands behind Esporta's buttons (the same calls a test replays).
enum ExportCalls {
    /// Esporta video…: the mix brought to the house loudness (−15 LUFS, also with music and sound effects in it). The
    /// engine checks the editing rules first (#31) and refuses while one fails, unless `anyway`: «Esporta lo stesso», the
    /// person's own choice after the Export card showed what fails.
    static func render(path: String, preset: String, captions: Bool, bitrate: Double, anyway: Bool = false) -> StepCall {
        var params: [String: JSONValue] = ["path": .string(path), "preset": .string(preset), "captions": .bool(captions),
                                           "bitrate": .number(bitrate), "loudness": .number(LoudnessTarget.integrated)]
        if anyway { params["exportAnyway"] = true }
        return StepCall(id: "export.render", params: .object(params))
    }

    /// «Sistema tutto ed esporta»: every safe fix of the failing rules, in one undo step.
    static let fixAll = StepCall(id: "rules.fix", params: ["all": true])
}

/// Esporta's main area: the program monitor, what the export will look like.
struct ExportWorkspace: View {
    var body: some View {
        ProgramMonitor(compactTransport: false).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Esporta's side panel: format, the checks, the files (export.render, export.srt, export.mlt).
struct ExportSettingsPanel: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var meter: LoudnessMeter
    @ObservedObject private var o = ExportOptions.shared
    @ObservedObject private var revision = RulesRevision.shared
    @StateObject private var rules = ExportRulesModel()
    @Environment(\.rulesDemo) private var rulesDemo
    /// The folder of the last export (the save panel opens there next time).
    @AppStorage("export.lastFolder") private var lastFolder = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section("Formato") {
                    RChips(items: [.init(id: "9:16", title: loc("Reel 9:16"), symbol: "rectangle.portrait"), .init(id: "4:5", title: loc("Feed 4:5"), symbol: "rectangle.portrait"),
                                   .init(id: "1:1", title: loc("Quadrato"), symbol: "square"), .init(id: "16:9", title: loc("Orizzontale"), symbol: "rectangle")],
                           selection: o.preset, columns: 2) { o.preset = $0 }
                    RToggle(title: "Sottotitoli impressi", isOn: $o.captions)
                    RSlider(value: $o.bitrate, range: 6...30, step: 1, label: "Bit rate", format: { String(Int($0)) + " Mbps" })
                }
                if let report = rulesDemo ?? rules.report {
                    ExportRulesCard(report: report, model: rules, demo: rulesDemo != nil)
                }
                section("Controlli") {
                    check("Durata", store.project.map { shortTime($0.duration.seconds) } ?? "–", ok: (store.project?.duration ?? .zero) > .zero)
                    check("Loudness", meter.curve.integrated.isFinite ? String(format: "%.1f LUFS", meter.curve.integrated) : "–",
                          ok: LoudnessTarget.verdict(integrated: meter.curve.integrated) == .ok)
                    check("Picco reale", meter.curve.truePeak.isFinite ? String(format: "%.1f dBTP", meter.curve.truePeak) : "–",
                          ok: meter.curve.truePeak.isFinite && !LoudnessTarget.peakOver(meter.curve.truePeak))
                    check("Sottotitoli", staleCaptions ? "da rigenerare" : (hasCaptions ? "aggiornati" : "nessuno"), ok: !staleCaptions)
                }
                section("File") {
                    // Standard Save As: a proposed name, the user picks the name and the folder.
                    ExportJob(jobs: store.jobs)
                    if let report = rulesDemo ?? rules.report, !report.failures.isEmpty {
                        rulesActions(report)
                    } else {
                        EdButton(title: "Esporta video…", symbol: "square.and.arrow.up", prominent: true, fill: true, disabled: exportBusy) {
                            exportVideo(anyway: false)
                        }
                    }
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        EdButton(title: "Sottotitoli .srt…", symbol: "captions.bubble", disabled: !hasCaptions) {
                            guard let url = ask("srt", UTType(filenameExtension: "srt") ?? .plainText, "Esporta i sottotitoli") else { return }
                            store.run("export.srt", ["path": .string(url.path)])
                        }
                        EdButton(title: "Progetto Shotcut…", symbol: "film", disabled: store.project == nil) {
                            guard let url = ask("mlt", UTType(filenameExtension: "mlt") ?? .xml, "Esporta il progetto Shotcut") else { return }
                            store.run("export.mlt", ["path": .string(url.path)])
                        }
                    }
                    if let f = o.lastFile {
                        EdButton(title: "Mostra nel Finder", symbol: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([f])
                        }
                    }
                }
                if let last = store.activity.last(where: { $0.command.hasPrefix("export.") }) {
                    section("Ultimo export") {
                        ActivityRow(a: last, compact: false)
                    }
                }
            }
            .padding(Ed.Space.l)
        }
        .task(id: "\(store.projectVersion)-\(revision.value)") {
            guard rulesDemo == nil else { return }
            rules.store = store
            // A burst of edits checks once, after the last.
            if rules.report != nil { try? await Task.sleep(for: .seconds(ExportRulesModel.pause)) }
            guard !Task.isCancelled else { return }
            await rules.refresh()
        }
    }

    private var exportBusy: Bool { store.project == nil || store.jobs.latest("export")?.isRunning == true }

    /// Asks where, then exports as a job (E2 #54): progress by frames, Cancel removes the partial file; the window stays usable.
    private func exportVideo(anyway: Bool) {
        guard rulesDemo == nil, let url = ask("mp4", .mpeg4Movie, "Esporta il video") else { return }
        store.exportVideo(ExportCalls.render(path: url.path, preset: o.preset, captions: o.captions, bitrate: o.bitrate, anyway: anyway).params, to: url)
    }

    /// A rule fails: «Sistema tutto ed esporta» (when a fix exists: the fixes, then the export, or the card shows what is left)
    /// and «Esporta lo stesso», which is always there.
    private func rulesActions(_ report: RulesReport) -> some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Ed.Space.s) { anywayButton.fixedSize(); if report.fixable { fixAllButton } }
                VStack(spacing: Ed.Space.s) { if report.fixable { fixAllButton }; anywayButton }
            }
            Text(verbatim: loc("Claude non consegna un video con una regola rotta. Tu puoi sempre esportare lo stesso."))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var anywayButton: some View {
        EdButton(title: "Esporta lo stesso", large: true, fill: true, disabled: rulesDemo == nil && exportBusy) { exportVideo(anyway: true) }
    }

    private var fixAllButton: some View {
        EdButton(title: "Sistema tutto ed esporta", prominent: true, large: true, fill: true, disabled: rulesDemo == nil && exportBusy) {
            guard rulesDemo == nil else { return }
            Task { if await rules.fixAll() { exportVideo(anyway: false) } }
        }
    }

    /// The export running (or the last one, until dismissed) with its progress and Cancel.
    private struct ExportJob: View {
        @ObservedObject var jobs: JobCenter
        var body: some View {
            if let j = jobs.latest("export") {
                JobCard(job: j, onCancel: { jobs.cancel(j.id) }, onDismiss: { jobs.dismiss(j.id) })
            }
        }
    }

    private var hasCaptions: Bool { store.project?.tracks.contains { $0.kind == .caption && $0.captions != nil } ?? false }
    private var staleCaptions: Bool {
        guard let p = store.project, let c = p.tracks.first(where: { $0.kind == .caption })?.captions,
              let src = p.tracks.first(where: { $0.id == c.sourceTrack }) else { return false }
        return RegistaCore.Captions.signature(of: src) != c.sourceSignature
    }

    /// Save panel with the project name as the proposed file name, opening in the last export folder (else Movies).
    private func ask(_ ext: String, _ type: UTType, _ title: String) -> URL? {
        let p = NSSavePanel()
        p.allowedContentTypes = [type]
        p.canCreateDirectories = true
        p.message = loc(title)
        let suffix = o.preset == "9:16" || ext != "mp4" ? "" : " " + o.preset.replacingOccurrences(of: ":", with: "x")
        p.nameFieldStringValue = Paths.safeFilename(store.project?.name ?? loc("Senza titolo")) + suffix + "." + ext
        p.directoryURL = lastFolder.isEmpty ? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                                            : URL(fileURLWithPath: lastFolder, isDirectory: true)
        guard p.runModal() == .OK, let url = p.url else { return nil }
        lastFolder = url.deletingLastPathComponent().path
        o.lastFile = url
        return url
    }

    private func check(_ label: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle").font(Ed.icon(Ed.TypeSize.small))
                .foregroundStyle(ok ? Ed.ok : Ed.gold)
            Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2)
            Spacer()
            Text(verbatim: loc(value)).font(Ed.mono(Ed.TypeSize.small)).foregroundStyle(Ed.text)
        }
    }
}
