import AppKit
import RegistaCore
import SwiftUI

/// Inizio: "Cosa vuoi fare?" with four ways in, the recent projects, and one line about this Mac (RAM, tier, engines).
struct HomeWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    var body: some View { Content(recents: store.recents) }
}

private struct Content: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var recorder: Recorder
    @ObservedObject var recents: RecentProjects
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Cosa vuoi fare?")
                        .font(Ed.display(Ed.TypeSize.hero, .medium))
                        .foregroundStyle(Ed.text)
                    Text("Scegli da dove partire: Registra, gli strumenti di montaggio ed Esporta restano sempre nella barra a sinistra.")
                        .font(Ed.ui(Ed.TypeSize.control))
                        .foregroundStyle(Ed.text2)
                        .padding(.top, Ed.Space.s)
                    starts.padding(.top, 28)
                    recentSection.padding(.top, 46)
                }
                .frame(maxWidth: 1120, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.top, 52)
                .padding(.bottom, Ed.Space.xxl)
                .frame(maxWidth: .infinity)
            }
            machineLine
        }
        .background(Ed.bg)
        .onAppear {
            recents.refresh()
            store.refreshEngines()
        }
    }

    // MARK: Ways in

    private var starts: some View {
        // Four across when the main area is wide, two by two when the side and right panels leave it narrower.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], spacing: 14) {
            StartCard(glyph: .reel, title: loc("Reel parlato"),
                      text: loc("Tu davanti alla camera, con il gobbo. Apre Registra con camera e microfono."),
                      action: loc("Apri Registra"),
                      secondary: (loc("o importa un video"), { Panels.importMedia(store, newProject: true) })) {
                // Solo volto with the teleprompter; the switches stay free to change in Registra.
                recorder.sources.apply(.face)
                recorder.sources.prompter = true
                store.workspace = .record
            }
            StartCard(glyph: .tutorial, title: loc("Tutorial dello schermo"),
                      text: loc("Registra lo schermo, con il tuo volto in un angolo se vuoi. Apre Registra con lo schermo acceso."),
                      action: loc("Apri Registra")) {
                recorder.sources.apply(.screenOnly)
                store.workspace = .record
            }
            StartCard(glyph: .faceless, title: loc("Video senza volto"),
                      text: loc("Scrivi il testo e Regista lo dice con la tua voce clonata: un progetto nuovo in Monta Pro, sul pannello Voce, poi grafica e musica."),
                      action: loc("Nuovo progetto")) {
                store.newEmptyProject(name: loc("Video senza volto"), activity: .voice)
            }
            StartCard(glyph: .edit, title: loc("Monta un video"),
                      text: loc("Scegli uno o più video già girati: nuovo progetto, e si apre il montaggio Pro."),
                      action: loc("Scegli i video…")) {
                Panels.importMedia(store, newProject: true, level: .pro)
            }
        }
    }

    // MARK: Recent projects

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                SectionLabel("PROGETTI RECENTI")
                if !recents.infos.isEmpty {
                    Text(verbatim: "\(recents.infos.count)").font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3.opacity(0.7))
                }
                Spacer()
                EdButton(title: loc("Apri un altro progetto…"), symbol: "folder") { Panels.openProject(store) }
            }
            if recents.infos.isEmpty {
                VStack(spacing: Ed.Space.s) {
                    Image(systemName: "clock.arrow.circlepath").font(Ed.icon(Ed.TypeSize.heading, .light)).foregroundStyle(Ed.text3)
                    Text("Nessun progetto recente. I progetti che apri o salvi compaiono qui.")
                        .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 130)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.xl, style: .continuous).strokeBorder(Ed.line2, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: Ed.Space.m)], spacing: Ed.Space.m) {
                    ForEach(recents.infos) { info in
                        RecentRow(info: info, open: store.projectURL?.standardizedFileURL.path == info.path) {
                            store.openProject(URL(fileURLWithPath: info.path, isDirectory: true))
                        }
                    }
                }
            }
        }
    }

    // MARK: This Mac

    private var machineLine: some View {
        HStack(spacing: 10) {
            Image(systemName: "memorychip").font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
            Text(verbatim: summaryText).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text2).lineLimit(1)
            Spacer()
            EdButton(title: loc("Motori"), symbol: "cpu") { SettingsRoute.open(.engines, with: openSettings) }
        }
        .padding(.horizontal, 40)
        .frame(height: 44)
        .background(Ed.panel)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    private var summaryText: String {
        guard let s = store.engineSummary else { return loc("Controllo dei motori…") }
        let tier = switch s.tier { case "base": loc("Base"); case "medium": loc("Medio"); default: loc("Pro") }
        return String(format: loc("RAM %d GB · livello %@ · %d motori pronti su %d"), s.memoryGB, tier, s.ready, s.total)
    }
}

/// One way in: an abstract format glyph, a title, what it does, and the action it leads to.
private struct StartCard: View {
    let glyph: FormatGlyph.Kind
    let title: String
    let text: String
    let action: String
    var secondary: (String, () -> Void)? = nil
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FormatGlyph(kind: glyph, lit: hover).frame(height: 48, alignment: .bottomLeading)
            Text(verbatim: title).font(Ed.display(Ed.TypeSize.heading, .medium)).foregroundStyle(Ed.text).padding(.top, 20)
            Text(verbatim: text).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            Spacer(minLength: 14)
            HStack(spacing: 6) {
                Text(verbatim: action).font(Ed.ui(Ed.TypeSize.small, .medium))
                Image(systemName: "arrow.right").font(Ed.icon(Ed.TypeSize.micro, .semibold)).offset(x: hover ? 2 : 0)
            }
            .foregroundStyle(hover ? Ed.gold : Ed.text3)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 224, maxHeight: 224, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.xl, style: .continuous).fill(hover ? Ed.raised.opacity(0.7) : Ed.panel))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.xl, style: .continuous).strokeBorder(hover ? Ed.gold.opacity(0.45) : Ed.line2, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: Ed.Radius.xl))
        .onTapGesture(perform: run)
        .overlay(alignment: .bottomTrailing) {
            if let secondary {
                Button(action: secondary.1) {
                    Text(verbatim: secondary.0).font(Ed.ui(Ed.TypeSize.caption)).underline().foregroundStyle(Ed.text3)
                }
                .buttonStyle(.plain)
                .padding(18)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.14)) { hover = h } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Fine line drawings of the format each way in makes (no illustration: outlines, a dot, a few strokes).
private struct FormatGlyph: View {
    enum Kind { case reel, tutorial, faceless, edit }
    let kind: Kind
    var lit = false

    var body: some View {
        let ink = lit ? Ed.gold : Ed.text3
        let stroke = StrokeStyle(lineWidth: 1.2)
        switch kind {
        case .reel:
            ZStack {
                RoundedRectangle(cornerRadius: Ed.Radius.s).stroke(ink, style: stroke)
                Circle().stroke(ink, style: stroke).frame(width: 10, height: 10).offset(y: -8)
                Capsule().fill(ink).frame(width: 14, height: 1.6).offset(y: 12)
            }
            .frame(width: 27, height: 48)
        case .tutorial:
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: Ed.Radius.s).stroke(ink, style: stroke)
                VStack(alignment: .leading, spacing: Ed.Space.xs) {
                    Capsule().fill(ink.opacity(0.7)).frame(width: 26, height: 1.4)
                    Capsule().fill(ink.opacity(0.7)).frame(width: 18, height: 1.4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(7)
                Circle().stroke(ink, style: stroke).frame(width: 12, height: 12).padding(5)
            }
            .frame(width: 72, height: 40)
        case .faceless:
            ZStack {
                RoundedRectangle(cornerRadius: Ed.Radius.s).stroke(ink, style: stroke)
                VStack(spacing: Ed.Space.xs) {
                    Capsule().fill(ink).frame(width: 15, height: 1.6)
                    Capsule().fill(ink).frame(width: 10, height: 1.6)
                    Capsule().fill(ink.opacity(0.6)).frame(width: 13, height: 1.6)
                }
            }
            .frame(width: 27, height: 48)
        case .edit:
            ZStack(alignment: .leading) {
                HStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: Ed.Radius.xs).stroke(ink, style: stroke).frame(width: 17, height: 30) }
                }
                Rectangle().fill(lit ? Ed.gold : Ed.text2).frame(width: 1.4, height: 44).offset(x: 29)
            }
            .frame(width: 60, height: 48)
        }
    }
}

/// A recent project: thumbnail in the project's shape, name, date and duration. Click opens it in Monta.
private struct RecentRow: View {
    let info: RecentProjects.Info
    let open: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                thumbnail
                VStack(alignment: .leading, spacing: Ed.Space.xs) {
                    Text(verbatim: info.name).font(Ed.ui(Ed.TypeSize.control, .medium)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text(info.modified, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        if info.duration > 0 { Text(verbatim: "·"); Text(verbatim: shortTime(info.duration)).font(Ed.mono(Ed.TypeSize.caption)) }
                    }
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).lineLimit(1)
                }
                Spacer(minLength: 6)
                if open {
                    Text(verbatim: loc("aperto")).font(Ed.mono(Ed.TypeSize.micro, .medium)).tracking(1).foregroundStyle(Ed.gold)
                }
                Image(systemName: "arrow.right").font(Ed.icon(Ed.TypeSize.caption, .semibold))
                    .foregroundStyle(hover ? Ed.gold : .clear)
            }
            .padding(.horizontal, Ed.Space.m)
            .frame(height: 80)
            .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(hover ? Ed.raised.opacity(0.7) : Ed.panel))
            .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).strokeBorder(hover ? Ed.line2 : Ed.line, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .contextMenu {
            Button("Mostra nel Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: info.path)]) }
        }
        .tip(info.path)
    }

    /// The first video clip's frame, fitted in a 56×56 box in the project's aspect; a neutral tile otherwise.
    private var thumbnail: some View {
        let aspect = info.size.height > 0 ? info.size.width / info.size.height : 9 / 16
        let box: CGFloat = 56
        let size = aspect < 1 ? CGSize(width: box * aspect, height: box) : CGSize(width: box, height: box / aspect)
        return ZStack {
            Ed.well
            if let t = info.thumbnail {
                Image(decorative: t, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "film").font(Ed.icon(Ed.TypeSize.control, .light)).foregroundStyle(Ed.text3)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: Ed.Radius.s, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s, style: .continuous).strokeBorder(Ed.line2, lineWidth: 0.5))
        .frame(width: box, height: box)
    }
}
