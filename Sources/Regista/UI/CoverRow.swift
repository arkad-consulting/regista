import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

/// The commands behind Esporta › Copertina (the same calls a test replays).
enum CoverCalls {
    static func set(_ params: [String: JSONValue]) -> StepCall { StepCall(id: "cover.set", params: .object(params)) }
    static func make(output: String) -> StepCall { StepCall(id: "cover.make", params: ["output": .string(output), "inline": false]) }
}

/// The cover as the row shows it: a render of it (cover.make into a scratch file) and its check, after every change of
/// the project — a change Claude makes shows here at once.
@MainActor
final class CoverModel: ObservableObject {
    @Published var image: NSImage?
    @Published var check: JSONValue?
    @Published var failure: String?
    weak var store: EditorStore?
    private let file = FileManager.default.temporaryDirectory.appendingPathComponent("regista-cover-row-\(UUID().uuidString.prefix(8)).png")

    func refresh() async {
        guard let store, store.project?.cover != nil else { image = nil; check = nil; failure = nil; return }
        do {
            let r = try await store.silent("cover.make", CoverCalls.make(output: file.path).params)
            image = NSImage(contentsOf: file)
            check = r["check"]
            failure = nil
        } catch {
            failure = StepError.readable(error)
        }
    }

    deinit { try? FileManager.default.removeItem(at: file) }
}

/// Esporta › Copertina (#42): used once per video, so one compact row; open, the cover with the two crops drawn on it
/// (the Instagram grid's 3:4 and the Shorts shelf's 2:3), «Usa questo fotogramma» (the playhead), the title, its place,
/// the kit's title style and «Salva copertina…». Every control runs cover.set or cover.make.
struct CoverRow: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @StateObject private var model = CoverModel()
    @State private var open = false
    @State private var draft = ""
    @AppStorage("export.lastFolder") private var lastFolder = ""

    static let thumbWidth: CGFloat = 108

    var body: some View {
        let cover = store.project?.cover
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: Ed.Space.s) {
                    thumbnail(width: 27, guides: false)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(verbatim: loc("Copertina")).font(Ed.ui(Ed.TypeSize.label, .medium)).foregroundStyle(Ed.text)
                            Image(systemName: "chevron.right").font(Ed.icon(Ed.TypeSize.tiny, .semibold)).foregroundStyle(Ed.text3)
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                        Text(verbatim: summary(cover)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(passes ? Ed.text3 : Ed.warn)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(loc("Copertina"))
            if open { details(cover) }
        }
        .task(id: "\(store.projectVersion)") {
            model.store = store
            await model.refresh()
            draft = store.project?.cover?.title ?? ""
        }
    }

    @ViewBuilder private func details(_ cover: Cover?) -> some View {
        HStack(alignment: .top, spacing: Ed.Space.m) {
            thumbnail(width: Self.thumbWidth, guides: true)
            VStack(alignment: .leading, spacing: Ed.Space.s) {
                if let cover {
                    Text(verbatim: shortTime(cover.time.seconds)).font(Ed.mono(Ed.TypeSize.small)).foregroundStyle(Ed.text2)
                }
                if let line = checkLine {
                    HStack(alignment: .firstTextBaseline, spacing: Ed.Space.xs) {
                        Image(systemName: passes ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        Text(verbatim: line).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(passes ? Ed.ok : Ed.warn)
                }
                if let f = model.failure { Text(verbatim: f).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.warn).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        EdButton(title: "Usa questo fotogramma", symbol: "scope", fill: true, disabled: store.project == nil) {
            let call = CoverCalls.set(["time": .number(playhead.time)])
            store.run(call.id, call.params)
        }
        if cover != nil {
            // The growing editor every title uses (#125): Invio saves, ⌥Invio starts a new line, Esc restores.
            RTextEditor(placeholder: "Titolo della copertina", text: $draft, kind: .grows(1...3), size: Ed.TypeSize.control,
                        onSubmit: commitTitle, onExit: { draft = store.project?.cover?.title ?? "" })
            RChips(items: Cover.Place.allCases.map { .init(id: $0, title: Self.placeTitle($0)) }, selection: cover?.place, columns: 3) { p in
                let call = CoverCalls.set(["place": .string(p.rawValue)])
                store.run(call.id, call.params)
            }
            if let kit = store.project?.brand, !kit.titles.isEmpty {
                VStack(alignment: .leading, spacing: Ed.Space.xs) {
                    Text(verbatim: loc("Stile del titolo")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                    RChips(items: kit.titles.keys.sorted().map { .init(id: $0, title: $0) }, selection: cover?.preset ?? (kit.titles["hook"] != nil ? "hook" : nil),
                           flow: true) { name in
                        let call = CoverCalls.set(["preset": .string(name)])
                        store.run(call.id, call.params)
                    }
                }
            }
            EdButton(title: "Salva copertina…", symbol: "square.and.arrow.down", fill: true) { save() }
        }
    }

    /// The cover's render, `width` wide in the project's proportions; with `guides`, the two crops drawn on it.
    private func thumbnail(width: CGFloat, guides: Bool) -> some View {
        let s = store.project?.settings
        let ratio = CGFloat(s?.height ?? 1920) / CGFloat(max(s?.width ?? 1080, 1))
        let h = width * ratio
        return ZStack {
            RoundedRectangle(cornerRadius: Ed.Radius.s).fill(Ed.well)
            if let img = model.image { Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit) }
            else { Image(systemName: "photo").font(Ed.icon(width > 40 ? Ed.TypeSize.label : Ed.TypeSize.tiny)).foregroundStyle(Ed.text3) }
            if guides, model.image != nil {
                // The two crops, centred: the Instagram grid keeps 3:4 of the width, the Shorts shelf 2:3.
                Rectangle().strokeBorder(Ed.gold, style: StrokeStyle(lineWidth: 1, dash: [3, 2])).frame(width: width, height: width * 4 / 3)
                Rectangle().strokeBorder(Ed.text2, style: StrokeStyle(lineWidth: 1, dash: [1, 2])).frame(width: width, height: width * 3 / 2)
            }
        }
        .frame(width: width, height: h)
        .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.s))
        .overlay(alignment: .bottomLeading) {
            if guides, model.image != nil {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: loc("Instagram 3:4")).foregroundStyle(Ed.gold)
                    Text(verbatim: loc("Shorts 2:3")).foregroundStyle(Ed.text2)
                }
                .font(Ed.ui(Ed.TypeSize.micro, .medium)).lineLimit(1).fixedSize()
                .offset(y: 30)
            }
        }
        .padding(.bottom, guides ? 32 : 0)
        .accessibilityHidden(true)
    }

    static func placeTitle(_ p: Cover.Place) -> String {
        switch p {
        case .top: loc("In alto")
        case .center: loc("Al centro")
        case .bottom: loc("In basso")
        }
    }

    private var passes: Bool { model.check?["pass"]?.boolValue ?? true }

    private func summary(_ cover: Cover?) -> String {
        guard let cover else { return loc(open ? "Nessuna copertina: porta la testina sul fotogramma e premi «Usa questo fotogramma»." : "Nessuna copertina") }
        let words = cover.title.map { loc("«%@»", $0.replacingOccurrences(of: "\n", with: " ")) } ?? loc("senza titolo")
        let state = model.check == nil ? "" : (passes ? loc("nei due ritagli") : loc("esce dai ritagli"))
        return [shortTime(cover.time.seconds), words, state].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The check in words, in the interface language: where the title leaves the band, by how much, and the fix.
    private var checkLine: String? {
        guard let c = model.check, store.project?.cover?.title != nil else { return nil }
        if c["pass"]?.boolValue == true { return loc("Il titolo resta nei due ritagli: la griglia di Instagram (3:4) e lo scaffale degli Shorts (2:3).") }
        let parts = (c["overflows"]?.arrayValue ?? []).compactMap { o -> String? in
            let n = String(Int(o["pixels"]?.doubleValue ?? 0))
            switch o["side"]?.stringValue {
            case "top": return String(format: loc("%@ px in alto"), n)
            case "bottom": return String(format: loc("%@ px in basso"), n)
            case "left": return String(format: loc("%@ px a sinistra"), n)
            case "right": return String(format: loc("%@ px a destra"), n)
            default: return nil
            }
        }
        let leaves = String(format: loc("Il titolo esce dalla zona che resta in entrambi i ritagli: %@."), parts.joined(separator: ", "))
        if let place = c["fix"]?["place"]?.stringValue.flatMap(Cover.Place.init(rawValue:)) {
            return leaves + " " + String(format: loc("Con «%@» rientra."), Self.placeTitle(place))
        }
        return leaves + " " + loc("Accorcia il titolo o mandalo a capo (⌥Invio).")
    }

    private func commitTitle() {
        guard draft != (store.project?.cover?.title ?? "") else { return }
        store.run(CoverCalls.set(["title": .string(draft)]).id, CoverCalls.set(["title": .string(draft)]).params)
    }

    /// «Salva copertina…»: the save panel (the project's name, the last export folder), then cover.make into that file.
    private func save() {
        commitTitle()
        let p = NSSavePanel()
        p.allowedContentTypes = [.png]
        p.canCreateDirectories = true
        p.message = loc("Salva la copertina")
        p.nameFieldStringValue = Paths.safeFilename(store.project?.name ?? loc("Senza titolo")) + "-" + loc("copertina") + ".png"
        p.directoryURL = lastFolder.isEmpty ? FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
                                            : URL(fileURLWithPath: lastFolder, isDirectory: true)
        guard p.runModal() == .OK, let url = p.url else { return }
        lastFolder = url.deletingLastPathComponent().path
        store.run(CoverCalls.make(output: url.path).id, CoverCalls.make(output: url.path).params)
    }
}
