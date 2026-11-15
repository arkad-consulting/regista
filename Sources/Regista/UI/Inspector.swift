import AppKit
import RegistaCore
import SwiftUI

// Ispettore (E1 #53): the selected item of the active tab and its settings. Calm rows — a label, the value in mono
// that can be typed, a thin slider under it — in sections with small caps headers. Every change is one command
// (InspectorEdits) through the tab's store; slider drags commit once, on release.

private struct InspectorDemoKey: EnvironmentKey { static let defaultValue: InspectorSelection? = nil }

extension EnvironmentValues {
    /// A selection an offscreen render shows in the inspector instead of the real one (ui.screenshot `inspector`).
    var inspectorDemo: InspectorSelection? {
        get { self[InspectorDemoKey.self] }
        set { self[InspectorDemoKey.self] = newValue }
    }
}

extension EditorStore {
    /// What the inspector shows: the clips selected on the timeline (else the one picked on the monitor), or a caption block.
    var inspectorSelection: InspectorSelection {
        if let pick = captionPick { return InspectorSelection(caption: pick) }
        if !selection.isEmpty { return InspectorSelection(clips: selection) }
        if let c = canvasSelection {
            if c.hasPrefix("caption:"), let t = project?.tracks.first(where: { $0.id == String(c.dropFirst(8)) }), let caps = t.captions {
                let now = MediaTime(seconds: preview.time)
                let k = caps.chunks.firstIndex { ($0.words.first?.start ?? .zero) <= now && now < $0.end } ?? 0
                return InspectorSelection(caption: CaptionPick(trackID: t.id, chunk: k))
            }
            if project?.locate(clip: c) != nil { return InspectorSelection(clips: [c]) }
        }
        return InspectorSelection()
    }
}

struct InspectorPanel: View {
    @EnvironmentObject private var store: EditorStore
    @Environment(\.inspectorDemo) private var demo
    @State private var drafts = InspectorDrafts()
    @State private var effectDrafts: [String: Double] = [:]
    /// Clips whose picture and sound fades are set apart (#79); by default they move together.
    @State private var fadesApart: Set<String> = []

    var body: some View {
        let p = store.project
        let target = InspectorTarget.resolve(demo ?? store.inspectorSelection, in: p)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let p {
                    content(target, p)
                } else {
                    InspectorEmpty(symbol: "film", title: loc("Nessun progetto aperto"),
                                   text: loc("Apri o crea un progetto: qui vedrai le regolazioni della clip selezionata."))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: store.projectVersion) { drafts.clear(); effectDrafts = [:] }
        .onChange(of: target.clipIDs) { drafts.clear(); effectDrafts = [:] }
    }

    @ViewBuilder private func content(_ target: InspectorTarget, _ p: Project) -> some View {
        let sections = target.sections(in: p)
        InspectorHeader(target: target, project: p)
        ForEach(sections, id: \.self) { s in
            section(s, target, p)
        }
        if [.image, .title, .sticker, .motion, .graphic].contains(target.kind) {
            InspectorHint(symbol: "hand.draw", text: loc("Trascinalo sul monitor per spostarlo; gli angoli lo ridimensionano."))
        }
    }

    // MARK: Values and commands

    private func value(_ f: InspectorField, _ target: InspectorTarget, _ p: Project) -> Double {
        guard let first = target.items.first else { return 0 }
        return drafts.value(f, else: InspectorEdits.value(f, first, in: p))
    }

    private func commit(_ f: InspectorField, _ v: Double, _ target: InspectorTarget, _ p: Project) {
        if let first = target.items.first, target.items.count == 1, abs(InspectorEdits.value(f, first, in: p) - v) < 1e-6 { return }
        guard let cmd = InspectorEdits.command(f, v, target, in: p) else { return }
        store.run(cmd.id, cmd.params)
    }

    private func run(_ cmd: InspectorCommand?) { if let cmd { store.run(cmd.id, cmd.params) } }

    /// A slider row bound to a field: drags write the draft, release runs the command.
    private func slider(_ label: String, _ f: InspectorField, _ target: InspectorTarget, _ p: Project, range: ClosedRange<Double>,
                        step: Double = 0, format: @escaping (Double) -> String, parse: ((String) -> Double?)? = nil) -> some View {
        InspectorSlider(label: label, value: value(f, target, p), range: range, step: step, format: format,
                        parse: parse ?? { Double($0.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }) },
                        onDrag: { drafts.drag(f, $0) },
                        onCommit: { v in drafts.drag(f, v); commit(f, v, target, p) })
    }

    // MARK: Sections

    @ViewBuilder private func section(_ s: InspectorPart, _ target: InspectorTarget, _ p: Project) -> some View {
        switch s {
        case .project: projectSection(p)
        case .timing: timingSection(target, p)
        case .text: textSection(target, p)
        case .transform: transformSection(target, p)
        case .crop: cropSection(target, p)
        case .color: colorSection(target, p)
        case .speed: speedSection(target, p)
        case .fades: fadesSection(target, p)
        case .screen:
            if let t = ScreenLook.target(target, in: p) { ScreenLookSection(target: t, project: p) }
        case .audio: audioSection(target, p)
        case .effects: effectsSection(target, p)
        case .follow: followSection(target, p)
        case .captionStyle: captionStyleSection(target)
        case .captionText: captionTextSection(target)
        case .multi:
            InspectorGroup(title: loc("Insieme")) {
                Text(verbatim: loc("Le modifiche valgono per tutte le clip selezionate, in un solo passo annullabile."))
                    .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            }
        case .opacity:
            InspectorGroup(title: loc("Opacità")) {
                slider(loc("Opacità"), .opacity, target, p, range: 0...1, step: 0.01, format: Fmt.percent, parse: Fmt.parsePercent)
            }
        }
    }

    private func projectSection(_ p: Project) -> some View {
        let s = p.settings
        return VStack(alignment: .leading, spacing: 0) {
            InspectorGroup(title: loc("Progetto")) {
                InspectorInfoRow(label: loc("Formato"), value: Fmt.ratio(s.width, s.height) + " · \(s.width)×\(s.height)")
                InspectorInfoRow(label: loc("Fotogrammi"), value: String(Int(s.frameRate.doubleValue.rounded())) + " fps")
                InspectorInfoRow(label: loc("Durata"), value: clockTime(p.duration.seconds))
                InspectorInfoRow(label: loc("Clip"), value: "\(p.tracks.flatMap(\.clips).count)")
                InspectorInfoRow(label: loc("Marca"), value: p.brand?.name ?? loc("nessuna"))
            }
            InspectorHint(symbol: "cursorarrow.click", text: loc("Seleziona una clip nella timeline per regolarla qui. Con ⇧ ne scegli più di una: i valori comuni cambiano insieme."))
        }
    }

    private func timingSection(_ target: InspectorTarget, _ p: Project) -> some View {
        let fps = p.settings.frameRate.doubleValue
        return InspectorGroup(title: loc("Tempo")) {
            HStack(spacing: Ed.Space.s) {
                InspectorTimeField(label: loc("Da"), seconds: value(.start, target, p), fps: fps) { commit(.start, $0, target, p) }
                InspectorTimeField(label: loc("A"), seconds: value(.end, target, p), fps: fps) { commit(.end, $0, target, p) }
                InspectorTimeField(label: loc("Durata"), seconds: value(.duration, target, p), fps: fps) { commit(.duration, $0, target, p) }
            }
        }
    }

    @ViewBuilder private func textSection(_ target: InspectorTarget, _ p: Project) -> some View {
        if let it = target.item {
            if let title = it.clip.title {
                InspectorGroup(title: loc("Testo")) {
                    InspectorTextEditor(text: title.text) { store.run("clip.set", ["clipId": .string(it.clip.id), "text": .string($0)]) }
                }
            } else if let m = it.clip.motion, let spec = MotionRegistry.spec(m.template) {
                InspectorGroup(title: spec.label) {
                    InspectorMotionFields(spec: spec, fields: m.fields) { k, v in
                        store.run("clip.set", ["clipId": .string(it.clip.id), "fields": [k: v]])
                    }
                }
            }
        }
    }

    private func transformSection(_ target: InspectorTarget, _ p: Project) -> some View {
        let W = Double(p.settings.width), H = Double(p.settings.height)
        return InspectorGroup(title: loc("Posizione e dimensione")) {
            slider("X", .x, target, p, range: -W...W * 2, step: 1, format: Fmt.pixels)
            slider("Y", .y, target, p, range: -H...H * 2, step: 1, format: Fmt.pixels)
            slider(loc("Scala"), .scale, target, p, range: 0.1...4, step: 0.01, format: Fmt.percent, parse: Fmt.parsePercent)
            slider(loc("Rotazione"), .rotation, target, p, range: -180...180, step: 1, format: Fmt.degrees)
            slider(loc("Opacità"), .opacity, target, p, range: 0...1, step: 0.01, format: Fmt.percent, parse: Fmt.parsePercent)
        }
    }

    private func cropSection(_ target: InspectorTarget, _ p: Project) -> some View {
        InspectorGroup(title: loc("Ritaglia"), reset: target.item.flatMap { it in
            (it.clip.transform.map { $0.cropLeft + $0.cropTop + $0.cropRight + $0.cropBottom > 0 } ?? false) ? { run(InspectorEdits.resetCrop(it, in: p)) } : nil
        }) {
            slider(loc("Sinistra"), .cropLeft, target, p, range: 0...0.45, step: 0.005, format: Fmt.percent, parse: Fmt.parsePercent)
            slider(loc("Destra"), .cropRight, target, p, range: 0...0.45, step: 0.005, format: Fmt.percent, parse: Fmt.parsePercent)
            slider(loc("Sopra"), .cropTop, target, p, range: 0...0.45, step: 0.005, format: Fmt.percent, parse: Fmt.parsePercent)
            slider(loc("Sotto"), .cropBottom, target, p, range: 0...0.45, step: 0.005, format: Fmt.percent, parse: Fmt.parsePercent)
        }
    }

    private func colorSection(_ target: InspectorTarget, _ p: Project) -> some View {
        InspectorGroup(title: loc("Colore")) {
            slider(loc("Luminosità"), .brightness, target, p, range: -0.3...0.3, step: 0.005, format: Fmt.signed)
            slider(loc("Contrasto"), .contrast, target, p, range: 0.5...1.5, step: 0.01, format: Fmt.factor)
            slider(loc("Saturazione"), .saturation, target, p, range: 0...2, step: 0.01, format: Fmt.factor)
            if let it = target.item, let look = it.clip.grade?.look {
                HStack(spacing: 6) {
                    Image(systemName: "camera.filters").font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.gold)
                    Text(verbatim: loc("Look: %@", loc(Look.named(look)?.label ?? look))).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.text)
                    Spacer()
                    IconButton(symbol: "xmark", help: "Togli il look", size: 18) {
                        store.run("look.apply", ["look": "none", "clipIds": [.string(it.clip.id)]])
                    }
                }
                .padding(.top, Ed.Space.xxs)
                slider(loc("Intensità"), .lookAmount, target, p, range: 0...1, step: 0.01, format: Fmt.percent, parse: Fmt.parsePercent)
            }
        }
    }

    @ViewBuilder private func speedSection(_ target: InspectorTarget, _ p: Project) -> some View {
        if let it = target.item {
            let sp = it.clip.speed
            let special = sp?.ramp != nil || sp?.freeze == true || sp?.reverse == true
            InspectorGroup(title: loc("Velocità"), reset: sp != nil ? { store.run("clip.speed", ["clipId": .string(it.clip.id), "preset": "normal"]) } : nil) {
                if special {
                    Text(verbatim: sp?.freeze == true ? loc("Fermo immagine") : sp?.reverse == true ? loc("All'indietro") : loc("Rampa di velocità"))
                        .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2)
                }
                // A log scale: 0.25× … 4× with 1× in the middle.
                InspectorSlider(label: loc("Velocità"), value: log2(value(.speed, target, p)), range: -2...2, step: 0.01,
                                format: { String(format: "%.2f×", pow(2, $0)) },
                                parse: { s in Double(s.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }).map { log2(max($0, 0.1)) } },
                                onDrag: { drafts.drag(.speed, pow(2, $0)) },
                                onCommit: { v in let r = (pow(2, v) * 100).rounded() / 100; drafts.drag(.speed, r); commit(.speed, r, target, p) })
                if p.asset(it.clip.assetID)?.audio != nil {
                    let pitch = (sp?.audio ?? .pitch) == .pitch
                    RToggle(title: loc("Mantieni l'intonazione"), isOn: Binding(get: { pitch }, set: { on in
                        store.run("clip.speed", ["clipId": .string(it.clip.id), "rate": .number(sp?.rate ?? 1), "audio": .string(on ? "pitch" : "mute")])
                    }), subtitle: loc("Altrimenti l'audio tace mentre la velocità cambia."))
                }
            }
        }
    }

    /// Picture fades (from / to black, or transparent off a full-frame video track) and, for a clip with linked sound,
    /// its audio fades: together by default (one clip.set for both), apart on request (#79).
    @ViewBuilder private func fadesSection(_ target: InspectorTarget, _ p: Project) -> some View {
        let sound = target.item.map { InspectorEdits.linkedAudio(of: $0.clip, in: p) } ?? []
        let key = target.clipIDs.joined(separator: ",")
        let apart = fadesApart.contains(key) || sound.isEmpty
        let black = target.item.map { $0.track.kind == .video && ($0.clip.placement == nil || $0.clip.isFullFramePicture) } ?? false
        InspectorGroup(title: loc("Dissolvenze")) {
            if apart {
                if !sound.isEmpty { subhead(loc("Immagine")) }
                slider(loc("Entrata"), .pictureFadeIn, target, p, range: 0...3, step: 0.05, format: Fmt.seconds)
                slider(loc("Uscita"), .pictureFadeOut, target, p, range: 0...3, step: 0.05, format: Fmt.seconds)
                if !sound.isEmpty {
                    subhead(loc("Audio"))
                    slider(loc("Entrata"), .fadeIn, target, p, range: 0...3, step: 0.05, format: Fmt.seconds)
                    slider(loc("Uscita"), .fadeOut, target, p, range: 0...3, step: 0.05, format: Fmt.seconds)
                }
            } else {
                linkedFade(loc("Entrata"), .pictureFadeIn, target, p)
                linkedFade(loc("Uscita"), .pictureFadeOut, target, p)
            }
            if !sound.isEmpty {
                RToggle(title: loc("Audio insieme all'immagine"), isOn: Binding(get: { !apart }, set: { on in
                    if on { fadesApart.remove(key) } else { fadesApart.insert(key) }
                }), subtitle: loc("Una sola dissolvenza per l'immagine e il suo audio."))
            }
            Text(verbatim: black ? loc("L'immagine parte dal nero e torna al nero.") : loc("L'immagine compare e scompare in trasparenza."))
                .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A fade slider that moves the picture and its sound together.
    private func linkedFade(_ label: String, _ f: InspectorField, _ target: InspectorTarget, _ p: Project) -> some View {
        // The picture's fade, else (none yet) its sound's.
        let picture = value(f, target, p)
        let shown = drafts.release(f) ?? (picture > 0 ? picture : value(f == .pictureFadeIn ? .fadeIn : .fadeOut, target, p))
        return InspectorSlider(label: label, value: shown, range: 0...3, step: 0.05, format: Fmt.seconds,
                        parse: { Double($0.replacingOccurrences(of: ",", with: ".").filter { "0123456789.".contains($0) }) },
                        onDrag: { drafts.drag(f, $0) },
                        onCommit: { v in
                            drafts.drag(f, v)
                            run(InspectorEdits.linkedFade(in: f == .pictureFadeIn, v, target, in: p))
                        })
    }

    private func subhead(_ text: String) -> some View {
        Text(verbatim: text).font(Ed.ui(Ed.TypeSize.small, .medium)).foregroundStyle(Ed.text3).padding(.top, Ed.Space.xxs)
    }

    private func audioSection(_ target: InspectorTarget, _ p: Project) -> some View {
        InspectorGroup(title: loc("Audio")) {
            slider(loc("Volume"), .gain, target, p, range: -30...12, step: 0.5, format: Fmt.decibels)
            slider(loc("Dissolvenza in entrata"), .fadeIn, target, p, range: 0...3, step: 0.05, format: Fmt.seconds)
            slider(loc("Dissolvenza in uscita"), .fadeOut, target, p, range: 0...3, step: 0.05, format: Fmt.seconds)
            if let it = target.item {
                let track = it.track
                RToggle(title: loc("Pista %@ muta", loc(track.name)), isOn: Binding(get: { track.muted }, set: { store.setTrack(track.id, "muted", $0) }))
                if track.ducking != nil || (track.role != nil && track.role != "voice") {
                    RToggle(title: loc("Abbassa sotto la voce"), isOn: Binding(get: { track.ducking != nil }, set: { on in
                        store.run("audio.duck", ["trackId": .string(track.id), "duck": .number(on ? -12 : 0)])
                    }), subtitle: loc("La pista scende mentre qualcuno parla."))
                    if track.ducking != nil {
                        slider(loc("Quanto scende"), .duck, target, p, range: -30...(-3), step: 1, format: Fmt.wholeDecibels)
                    }
                }
            }
        }
    }

    @ViewBuilder private func effectsSection(_ target: InspectorTarget, _ p: Project) -> some View {
        if let it = target.item {
            InspectorGroup(title: loc("Effetti applicati")) {
                ForEach(it.clip.effects ?? [], id: \.id) { e in
                    let (label, symbol) = AppliedItems.effectLabels[e.kind] ?? (e.kind.rawValue, "sparkles")
                    VStack(alignment: .leading, spacing: Ed.Space.xs) {
                        HStack(spacing: 6) {
                            Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.gold).frame(width: 16)
                            Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.text)
                            Spacer()
                            IconButton(symbol: "xmark", help: "Togli l'effetto", size: 18) {
                                store.run("effect.remove", ["clipId": .string(it.clip.id), "effectId": .string(e.id)])
                            }
                        }
                        if e.keyframes == nil {
                            InspectorSlider(label: loc("Intensità"), value: effectDrafts[e.id] ?? e.amount, range: 0...1, step: 0.01, format: Fmt.percent,
                                            parse: Fmt.parsePercent, onDrag: { effectDrafts[e.id] = $0 },
                                            onCommit: { v in
                                                effectDrafts[e.id] = v
                                                guard abs(v - e.amount) > 1e-6 else { return }
                                                store.run("clip.set", ["clipId": .string(it.clip.id), "effectId": .string(e.id), "effectAmount": .number(v)])
                                            })
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func followSection(_ target: InspectorTarget, _ p: Project) -> some View {
        if let it = target.item {
            InspectorGroup(title: loc("Segui il volto")) {
                Text(verbatim: loc("Il volto è stato rilevato nel video sotto: l'elemento può seguirlo per tutta la sua durata."))
                    .font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    EdButton(title: loc("Segui il volto"), symbol: "face.dashed") {
                        store.run("clip.follow", ["clipId": .string(it.clip.id), "target": "face"])
                    }
                    EdButton(title: loc("Sopra la testa"), symbol: "arrow.up.to.line") {
                        store.run("clip.follow", ["clipId": .string(it.clip.id), "target": "face", "point": "top"])
                    }
                }
            }
        }
    }

    @ViewBuilder private func captionStyleSection(_ target: InspectorTarget) -> some View {
        if let caps = target.captionTrack?.captions {
            InspectorGroup(title: loc("Stile dei sottotitoli")) {
                RChips(items: CaptionStyle.all.map { .init(id: $0.id, title: Fmt.captionStyle($0.id)) },
                       selection: CaptionStyle.all.first { caps.style.id == $0.id || caps.style.id.hasPrefix($0.id + "+") }?.id, columns: 2) { id in
                    store.run("captions.setStyle", ["trackId": .string(target.captionTrack!.id), "style": .string(id)])
                }
            }
        }
    }

    @ViewBuilder private func captionTextSection(_ target: InspectorTarget) -> some View {
        if let caps = target.captionTrack?.captions, let k = target.chunk {
            let chunk = caps.chunks[k]
            let range = InspectorEdits.words(of: chunk, in: store.words)
            InspectorGroup(title: String(format: loc("Blocco %d di %d"), k + 1, caps.chunks.count)) {
                if let range {
                    let original = store.words[range].map(\.text).joined(separator: " ")
                    InspectorTextEditor(text: original) { text in
                        store.run("transcript.editText", ["from": .number(Double(range.lowerBound)), "to": .number(Double(range.upperBound)),
                                                          "text": .string(text), "expect": .string(original)])
                    }
                    Text(verbatim: loc("Correggi le parole: cambia il testo, non i tempi. Invio per salvare."))
                        .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
                }
                Text(verbatim: loc("Parole chiave")).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).padding(.top, Ed.Space.xs)
                FlowLayout(spacing: Ed.Space.xs, lineSpacing: Ed.Space.xs) {
                    ForEach(Array(chunk.words.enumerated()), id: \.offset) { _, w in
                        Button {
                            store.run("captions.setKeywords", w.keyword ? ["remove": [.string(w.text)]] : ["add": [.string(w.text)]])
                        } label: {
                            Text(verbatim: w.text).font(Ed.ui(Ed.TypeSize.body, w.keyword ? .semibold : .regular))
                                .foregroundStyle(w.keyword ? .white : Ed.text2)
                                .padding(.horizontal, 7).frame(height: 22)
                                .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(w.keyword ? Ed.keyword.opacity(0.85) : Ed.control))
                        }
                        .buttonStyle(.plain)
                        .tip(w.keyword ? "Togli dalle parole chiave" : "Metti in evidenza (parola chiave)")
                    }
                }
            }
        }
    }
}

// MARK: - Pieces

/// The selected item: a tile in its timeline colour, its name, time range and track.
struct InspectorHeader: View {
    let target: InspectorTarget
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.control, .medium)).foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(tint.opacity(0.16)))
            VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                Text(verbatim: title).font(Ed.ui(Ed.TypeSize.control, .semibold)).foregroundStyle(Ed.text).lineLimit(1).truncationMode(.middle)
                Text(verbatim: subtitle).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Ed.Space.l).padding(.top, 14).padding(.bottom, Ed.Space.m)
        .overlay(alignment: .bottom) { Ed.rule2.frame(height: 1) }
    }

    private var tint: Color {
        guard let it = target.item else { return target.kind == .captions ? ClipPalette.edge(.caption) : Ed.text2 }
        return ClipPalette.edge(ClipPalette.kind(it.clip, track: it.track))
    }

    private var symbol: String {
        switch target.kind {
        case .none: "film.stack"
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .title: "textformat" // l10n-ignore
        case .sticker: "face.smiling"
        case .motion: "sparkles.rectangle.stack"
        case .graphic: "arrow.up.right"
        case .captions: "captions.bubble"
        case .multi: "square.stack.3d.up"
        }
    }

    private var title: String {
        switch target.kind {
        case .none: return project.name
        case .captions: return loc("Sottotitoli")
        case .multi: return String(format: loc("%d clip selezionate"), target.items.count)
        default:
            guard let c = target.item?.clip else { return "" }
            if let t = c.title { return t.text.replacingOccurrences(of: "\n", with: " ") }
            if let m = c.motion { return loc(MotionRegistry.spec(m.template)?.label ?? m.template) }
            if c.sticker != nil { return loc("Sticker") }
            if let sh = c.shape { return loc(AppliedItems.shapeLabel(sh.kind).0) }
            return project.asset(c.assetID)?.name ?? c.id
        }
    }

    private var subtitle: String {
        switch target.kind {
        case .none: return loc("Nessuna clip selezionata")
        case .captions:
            let n = target.captionTrack?.captions?.chunks.count ?? 0
            return String(format: loc("%d blocchi · pista %@"), n, loc(target.captionTrack?.name ?? ""))
        case .multi:
            let a = target.items.map(\.clip.start.seconds).min() ?? 0, b = target.items.map(\.clip.end.seconds).max() ?? 0
            return "\(shortTime(a)) – \(shortTime(b))"
        default:
            guard let it = target.item else { return "" }
            return "\(shortTime(it.clip.start.seconds)) – \(shortTime(it.clip.end.seconds)) · " + loc(it.track.name)
        }
    }
}

/// A section: small caps title, an optional reset arrow, its rows.
struct InspectorGroup<Content: View>: View {
    let title: String
    var reset: (() -> Void)? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title)
                Spacer()
                if let reset { IconButton(symbol: "arrow.counterclockwise", help: "Ripristina", size: 18, action: reset) }
            }
            .frame(height: 18)
            content
        }
        .padding(.horizontal, Ed.Space.l).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Ed.rule2.frame(height: 1) }
    }
}

/// Label, slider and the value (click to type it) on one line.
struct InspectorSlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    let format: (Double) -> String
    let parse: (String) -> Double?
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void

    var body: some View {
        // One line, as in a code editor's settings: the name, the slider, the value (click to type it).
        HStack(spacing: 10) {
            Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2).lineLimit(2).minimumScaleFactor(0.8)
                .frame(width: 86, alignment: .leading)
            RSlider(value: Binding(get: { min(max(value, range.lowerBound), range.upperBound) }, set: { onDrag($0) }),
                    range: range, step: step, format: format, onCommit: onCommit)
            InspectorValueField(text: format(value), width: 66) { s in
                if let v = parse(s) { onCommit(min(max(v, range.lowerBound), range.upperBound)) }
            }
        }
        .frame(height: 24)
    }
}

/// A timecode with its label above: clicks to type "HH:MM:SS:FF", "SS:FF" or seconds.
struct InspectorTimeField: View {
    let label: String
    let seconds: Double
    let fps: Double
    let onCommit: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3)
            InspectorValueField(text: timecode(frames: seconds, fps: fps), width: 92, alignment: .leading) { s in
                if let v = Fmt.parseTimecode(s, fps: fps) { onCommit(v) }
            }
            .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(Ed.control.opacity(0.5)))
        }
    }
}

/// A read-only row: label and value.
struct InspectorInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(verbatim: loc(label)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2)
            Spacer()
            Text(verbatim: value).font(Ed.mono(Ed.TypeSize.body)).foregroundStyle(Ed.text).lineLimit(1)
        }
    }
}

/// A multi-line text: Invio saves (⌥Invio for a new line), Esc restores.
struct InspectorTextEditor: View {
    let text: String
    let onCommit: (String) -> Void
    @State private var draft = ""

    var body: some View {
        RTextEditor(text: $draft, kind: .grows(1...6), size: Ed.TypeSize.control, onSubmit: save, onExit: { draft = text })
            .onAppear { draft = text }
            .onChange(of: text) { draft = text }
    }

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != text else { draft = text; return }
        onCommit(t)
    }
}

/// The form fields of a motion template clip (the gallery form's 3–5 fields), each saved on its own.
struct InspectorMotionFields: View {
    let spec: MotionSpec
    let fields: [String: JSONValue]
    let onCommit: (String, JSONValue) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(spec.form, id: \.self) { name in
                if let f = spec.field(name), f.type != "images", f.type != "image" { row(f) }
            }
        }
    }

    @ViewBuilder private func row(_ f: EffectsCatalog.Field) -> some View {
        let label = loc(MotionForm.labels[f.name] ?? f.name)
        let v = fields[f.name] ?? f.example
        VStack(alignment: .leading, spacing: Ed.Space.xs) {
            if f.type != "boolean" { Text(verbatim: label).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text2) }
            switch f.type {
            case "boolean":
                RToggle(title: label, isOn: Binding(get: { v.boolValue ?? false }, set: { onCommit(f.name, .bool($0)) }))
            case "choice":
                RSegmented(items: (f.choices ?? []).map { ($0, MotionForm.choiceLabel($0)) },
                           selection: Binding(get: { v.stringValue ?? "" }, set: { onCommit(f.name, .string($0)) }))
            case "number":
                InspectorTextEditor(text: v.doubleValue.map { $0.formatted() } ?? "") { s in
                    if let d = Double(s.replacingOccurrences(of: ",", with: ".")) { onCommit(f.name, .number(d)) }
                }
            case "numbers":
                InspectorTextEditor(text: (v.arrayValue ?? []).compactMap(\.doubleValue).map { $0.formatted() }.joined(separator: "  ")) { s in
                    onCommit(f.name, .array(s.split(whereSeparator: { $0 == " " || $0 == ";" }).compactMap { Double($0) }.map { .number($0) }))
                }
            case "list":
                InspectorTextEditor(text: (v.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")) { s in
                    onCommit(f.name, .array(s.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 != .string("") }))
                }
            default:
                InspectorTextEditor(text: v.stringValue ?? "") { onCommit(f.name, .string($0)) }
            }
        }
    }
}

/// A quiet hint at the end of the panel.
struct InspectorHint: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Ed.Space.s) {
            Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.text3).frame(width: 14)
            Text(verbatim: loc(text)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Ed.Space.l).padding(.vertical, 14)
    }
}

/// The panel with nothing to show.
struct InspectorEmpty: View {
    let symbol: String
    let title: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(Ed.icon(Ed.TypeSize.heading, .light)).foregroundStyle(Ed.text3)
                .frame(width: 52, height: 52).background(Circle().fill(Ed.control))
            Text(verbatim: loc(title)).font(Ed.ui(Ed.TypeSize.control, .semibold)).foregroundStyle(Ed.text)
            Text(verbatim: loc(text)).font(Ed.ui(Ed.TypeSize.body)).foregroundStyle(Ed.text3).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 240)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }
}

/// Number formats of the inspector.
enum Fmt {
    static func percent(_ v: Double) -> String { String(format: "%.0f %%", v * 100) }
    static func parsePercent(_ s: String) -> Double? {
        Double(s.replacingOccurrences(of: ",", with: ".").filter { "0123456789.-".contains($0) }).map { $0 / 100 }
    }
    static func pixels(_ v: Double) -> String { String(format: "%.0f px", v) }
    static func degrees(_ v: Double) -> String { String(format: "%.0f°", v) }
    static func seconds(_ v: Double) -> String { String(format: "%.2f s", v) }
    static func decibels(_ v: Double) -> String { String(format: "%+.1f dB", v) }
    /// "−12 dB": a ducking depth (whole dB, so it fits the value column).
    static func wholeDecibels(_ v: Double) -> String { String(format: "%.0f dB", v).replacingOccurrences(of: "-", with: "−") }
    static func signed(_ v: Double) -> String { String(format: "%+.0f", v * 100) }
    static func factor(_ v: Double) -> String { String(format: "%.2f", v) }
    /// "−14,9", "19": one decimal at most, in the user's locale, with a true minus sign.
    static func number(_ v: Double, decimals: Int = 1) -> String {
        let r = (v * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
        return r.formatted(.number.precision(.fractionLength(0...decimals))).replacingOccurrences(of: "-", with: "−")
    }

    static func ratio(_ w: Int, _ h: Int) -> String {
        switch Double(w) / Double(max(h, 1)) {
        case 0.55...0.58: "9:16"
        case 0.79...0.81: "4:5"
        case 0.99...1.01: "1:1"
        case 1.76...1.79: "16:9"
        default: "\(w)×\(h)"
        }
    }

    /// "00:00:12:07", "12:07" (seconds:frames) or plain seconds ("12.5").
    static func parseTimecode(_ s: String, fps: Double) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = t.split(separator: ":").map(String.init)
        if parts.count == 1 { return Double(t) }
        let nums = parts.compactMap(Double.init)
        guard nums.count == parts.count, nums.count <= 4 else { return nil }
        let frames = nums.last!
        let rest = nums.dropLast().reversed().enumerated().reduce(0.0) { $0 + $1.element * pow(60, Double($1.offset)) }
        return rest + frames / fps
    }

    static func captionStyle(_ id: String) -> String {
        switch id {
        case "elegant-serif": loc("Serif elegante")
        case "bold-keyword": loc("Bold + parola chiave")
        case "ghost-karaoke": loc("Karaoke fantasma")
        default: loc("Talking head")
        }
    }
}
