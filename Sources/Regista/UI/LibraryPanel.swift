import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Media

struct MediaTab: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var media: MediaCache

    var body: some View {
        let assets = store.project?.assets ?? []
        VStack(spacing: 0) {
            if assets.isEmpty {
                EmptyHint(symbol: "square.and.arrow.down", text: loc("Importa video, audio o immagini (⌘I) o trascinali qui"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 84, maximum: 120), spacing: Ed.Space.s)], spacing: 10) {
                        ForEach(assets, id: \.id) { a in tile(a) }
                    }
                    .padding(10)
                }
                .continuesCue()
                if let a = store.sourceAssetID.flatMap({ store.project?.asset($0) }) { details(a) }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { store.importMedia([url]) } }
                }
            }
            return true
        }
    }

    /// What Regista knows about the selected file (and what the engines already did with it).
    private func details(_ a: MediaAsset) -> some View {
        // (label key, value already in the user's language)
        var rows: [(String, String)] = []
        if let v = a.video {
            let fps = String(format: "%g", (v.frameRate.doubleValue * 100).rounded() / 100)
            rows.append(("Video", "\(v.width)×\(v.height) · \(fps) fps · \(v.codec)"))
        }
        if let au = a.audio {
            let channels = au.channels == 1 ? loc("mono") : loc("%@ canali", String(au.channels))
            rows.append(("Audio", "\(au.sampleRate / 1000) kHz · " + channels + " · " + au.codec))
        }
        if let o = a.origin { rows.append(("Origine", loc("%@ di %@", o.process, store.project?.asset(o.assetID)?.name ?? o.assetID))) }
        if let t = a.analysis?.transcript { rows.append(("Trascrizione", loc("%@ parole · %@", String(t.words.count), t.engine))) }
        if let f = a.analysis?.faces { rows.append(("Volto", loc("%@/%@ fotogrammi", String(f.detected), String(f.frames)))) }
        return VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: a.name).font(Ed.ui(Ed.TypeSize.small, .semibold)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
            ForEach(rows, id: \.0) { k, v in
                HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                    Text(verbatim: loc(k)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3).lineLimit(1).minimumScaleFactor(0.8)
                        .frame(width: 80, alignment: .leading)
                    Text(verbatim: v).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text2).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ed.header)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    private func tile(_ a: MediaAsset) -> some View {
        let selected = store.sourceAssetID == a.id
        let _ = media.revision
        return VStack(alignment: .leading, spacing: Ed.Space.xs) {
            // The picture fills the tile without widening it (a wide still used to push the tile out of the grid).
            Ed.well
                .frame(height: 76)
                .overlay {
                    if a.video != nil, let img = media.picture(a, at: min(1, a.duration.seconds / 2)) {
                        Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: a.video == nil ? "waveform" : "film").font(Ed.icon(Ed.TypeSize.heading, .light)).foregroundStyle(Ed.text3)
                    }
                }
            .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.s))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(selected ? Ed.gold : Ed.line, lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .bottomTrailing) {
                Text(verbatim: a.image?.kind == .still ? loc("Immagine") : shortTime(a.duration.seconds)).font(Ed.mono(Ed.TypeSize.micro, .medium)).foregroundStyle(Ed.text)
                    .padding(.horizontal, Ed.Space.xs).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(Color.black.opacity(0.65)))
                    .padding(Ed.Space.xs)
            }
            HStack(spacing: Ed.Space.xs) {
                if a.origin != nil { Image(systemName: "sparkle").font(Ed.icon(Ed.TypeSize.tiny)).foregroundStyle(Ed.gold) }
                Text(verbatim: a.name).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text2).lineLimit(1).truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.sourceAssetID = a.id }
        .onTapGesture { store.sourceAssetID = a.id }
        // Drag it onto a track of the timeline (E1 #53).
        .draggable(MediaDrop.assetPrefix + a.id) {
            Label(a.name, systemImage: a.image != nil ? "photo" : a.video == nil ? "waveform" : "film")
                .font(Ed.ui(Ed.TypeSize.body)).padding(6).background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(Ed.control))
        }
        .contextMenu {
            Button(loc("Mostra in Sorgente")) { store.sourceAssetID = a.id }
            Button(loc("Metti in timeline al cursore")) { store.placeAtPlayhead(asset: a.id) }
            Button(loc("Mostra nel Finder")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: a.path)]) }
        }
        .groupTip(a.origin.map { loc("Generato (%@) da %@", $0.process, $0.assetID) } ?? a.path)
    }
}

// MARK: Testi (script + captions)

struct TextsTab: View {
    @EnvironmentObject private var store: EditorStore

    /// «5 blocchi · stile Talking head · 2 parole chiave»: the style named as its chip names it, never its id (#83).
    static func captionsLine(_ c: RegistaCore.Captions) -> String {
        let base = CaptionStyle.all.first { c.style.id == $0.id || c.style.id.hasPrefix($0.id + "+") }?.id ?? c.style.id
        return loc("%@ · stile %@ · %@", CommandLines.count(c.chunks.count, "1 blocco", "%@ blocchi"), captionStyleName(base),
                   CommandLines.count(c.keywords.count, "1 parola chiave", "%@ parole chiave"))
    }

    var body: some View {
        let captions = store.project?.tracks.first { $0.kind == .caption && $0.captions != nil }?.captions
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("Sottotitoli") {
                    if let c = captions {
                        Text(verbatim: Self.captionsLine(c))
                            .font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                        // Caption style presets (issue #22): the approved look and the three round-2 styles.
                        RChips(items: CaptionStyle.all.map { .init(id: $0.id, title: captionStyleName($0.id),
                                                                  tip: "Cambia lo stile dei sottotitoli (parole chiave e posizioni restano)") },
                               selection: CaptionStyle.all.first { c.style.id == $0.id || c.style.id.hasPrefix($0.id + "+") }?.id, flow: true) {
                            store.run("captions.setStyle", ["style": .string($0)])
                        }
                        FlowLayout(spacing: Ed.Space.xs, lineSpacing: Ed.Space.xs) {
                            ForEach(c.keywords, id: \.self) { k in
                                Button { store.run("captions.setKeywords", ["remove": [.string(k)]]) } label: {
                                    HStack(spacing: 3) {
                                        Text(verbatim: k).font(Ed.ui(Ed.TypeSize.caption, .semibold))
                                        Image(systemName: "xmark").font(Ed.icon(Ed.TypeSize.tiny, .bold))
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, Ed.Space.xxs)
                                    .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(Ed.keyword.opacity(0.85)))
                                }
                                .buttonStyle(.plain)
                                .tip("Togli dalle parole chiave")
                            }
                        }
                        VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                            ForEach(Array(c.chunks.enumerated()), id: \.offset) { _, ch in
                                Button { store.preview.seek(ch.words.first?.start.seconds ?? 0) } label: {
                                    HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                                        Text(verbatim: shortTime(ch.words.first?.start.seconds ?? 0)).font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
                                            .frame(width: 40, alignment: .leading)
                                        chunkText(ch)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.vertical, Ed.Space.xxs)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    } else {
                        // No captions yet: the step (or the step missing first), never a command name (E2 #54).
                        StepOffer(step: .captions, compact: true)
                    }
                }
                section("Copione") {
                    if let s = store.project?.script {
                        ForEach(Array(s.lines.enumerated()), id: \.offset) { i, line in
                            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                                Text(verbatim: "\(i + 1)").font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.gold).frame(width: 16, alignment: .trailing)
                                Text(verbatim: line).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } else {
                        Text(verbatim: loc("Nessun copione: incollalo o crealo dal parlato nei Passi (è facoltativo).")).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
                        AccentLinkButton(title: loc("Apri il passo Copione")) { store.nav.textsTab = .steps }
                    }
                }
            }
            .padding(Ed.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The name of a caption style preset (looked up).
    private func chunkText(_ ch: RegistaCore.CaptionChunk) -> Text {
        ch.words.enumerated().reduce(Text(verbatim: "")) { acc, item in
            let w = Text(verbatim: (item.offset > 0 ? " " : "") + item.element.text)
                .font(Ed.ui(Ed.TypeSize.small, item.element.keyword ? .bold : .regular))
                .foregroundColor(item.element.keyword ? Ed.keyword : Ed.text)
            return acc + w
        }
    }
}

func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: Ed.Space.s) {
        SectionLabel(title)
        content()
    }
}

// MARK: Cronologia

struct HistoryTab: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                EdButton(title: "menu.undo", symbol: "arrow.uturn.backward", disabled: store.undoNames.isEmpty) { store.undo() }
                EdButton(title: "menu.redo", symbol: "arrow.uturn.forward", disabled: store.redoNames.isEmpty) { store.redo() }
                Spacer()
            }
            .padding(10)
            if store.undoNames.isEmpty && store.redoNames.isEmpty {
                EmptyHint(symbol: "clock.arrow.circlepath", text: "Ogni modifica (tua o di Claude) è un passo annullabile.")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(store.redoNames.enumerated()).reversed(), id: \.offset) { _, name in row(name, done: false, current: false) }
                        ForEach(Array(store.undoNames.enumerated()).reversed(), id: \.offset) { i, name in
                            row(name, done: true, current: i == store.undoNames.count - 1)
                        }
                    }
                    .padding(.horizontal, 10)
                }
            }
        }
    }

    private func row(_ name: String, done: Bool, current: Bool) -> some View {
        HStack(spacing: Ed.Space.s) {
            Circle().fill(current ? Ed.gold : (done ? Ed.text3 : .clear)).frame(width: 6, height: 6)
                .overlay(Circle().strokeBorder(Ed.text3, lineWidth: done ? 0 : 1))
            Text(verbatim: CommandTitles.title(name)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(done ? (current ? Ed.text : Ed.text2) : Ed.text3)
                .strikethrough(!done, color: Ed.text3)
            Spacer()
        }
        .frame(height: 22)
    }
}

// MARK: - Panels (open / save dialogs → commands)

@MainActor
enum Panels {
    /// `newProject`: the files start a new project (Inizio); `level`: then show Monta at that level.
    static func importMedia(_ store: EditorStore, newProject: Bool = false, level: EditorStore.Workspace? = nil) {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.allowedContentTypes = [.movie, .audio, .image]
        // Regista's folder, made now when nothing made it yet (a downloaded app has no installer to make it, #112).
        p.directoryURL = Paths.ensure(Paths.root)
        guard p.runModal() == .OK else { return }
        store.importMedia(p.urls, newProject: newProject)
        if let level { store.workspace = level } else if newProject { store.showEditor() }
    }

    static func openProject(_ store: EditorStore) {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.treatsFilePackagesAsDirectories = false
        p.message = loc("Scegli una cartella di progetto .regista")
        p.directoryURL = EditorStore.projectsFolder
        guard p.runModal() == .OK, let url = p.url else { return }
        store.openProject(url)
    }

    static func newProject(_ store: EditorStore) {
        let p = NSSavePanel()
        p.nameFieldStringValue = loc("Nuovo reel")
        p.directoryURL = EditorStore.projectsFolder
        p.message = loc("Nome e cartella del nuovo progetto")
        guard p.runModal() == .OK, let url = p.url else { return }
        // In this tab when it is empty, otherwise in a new tab (S2 #76).
        let tab = store.tabForNewProject()
        tab.run("project.new", GeneralPrefs.newProject(name: url.deletingPathExtension().lastPathComponent, directory: url.deletingLastPathComponent()))
        tab.showEditor()
    }

    static func save(_ store: EditorStore) {
        guard store.project != nil else { return }
        if store.projectURL != nil { return store.run("project.save") }
        guard let url = askProjectFolder(store) else { return }
        store.run("project.save", ["path": .string(url.path)])
    }

    /// Where to save a project that has no folder yet (nil = cancelled).
    static func askProjectFolder(_ store: EditorStore) -> URL? {
        let p = NSSavePanel()
        p.nameFieldStringValue = (store.project?.name ?? loc("Progetto")) + ".regista"
        p.directoryURL = EditorStore.projectsFolder
        guard p.runModal() == .OK else { return nil }
        return p.url
    }

    /// File › Salva con nome…: project.save with a new folder (the project then lives there, and joins the recents).
    static func saveAs(_ store: EditorStore) {
        guard store.project != nil else { return }
        let p = NSSavePanel()
        p.nameFieldStringValue = (store.project?.name ?? loc("Progetto")) + ".regista"
        p.directoryURL = store.projectURL?.deletingLastPathComponent() ?? EditorStore.projectsFolder
        p.canCreateDirectories = true
        p.message = loc("Nome e cartella della copia del progetto")
        guard p.runModal() == .OK, var url = p.url else { return }
        if url.pathExtension != ProjectStore.fileExtension { url.appendPathExtension(ProjectStore.fileExtension) }
        store.run("project.save", ["path": .string(url.path)])
    }

    /// Aggiungi musica…: a file goes on the Musica lane through audio.addMusic (fitted to the edit, faded, ducked under
    /// the voice), then the check under the voice, as a job (E3 #55).
    static func addMusic(_ store: EditorStore) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.message = loc("Scegli la musica: va sulla pista Musica e si abbassa quando parli")
        guard p.runModal() == .OK, let url = p.url else { return }
        store.addMusic(url)
    }
}
