import RegistaCore
import SwiftUI

/// Something put on the reel over a time range — an effect on a clip, a graphic (title, sticker, callout, motion
/// template, picture insert), a transition, a speed change — with what removes it. The Semplice strip draws them as
/// bars and the Graphics panel lists the ones under the playhead, so every click shows where it landed. `label` is in the user's
/// language (looked up when the list is built).
struct AppliedItem: Identifiable, Hashable {
    enum Kind { case effect, graphic, transition, speed }
    let id: String
    let kind: Kind
    let label: String
    let symbol: String
    let start: Double
    let end: Double
    let command: String
    let params: [String: JSONValue]

    var color: Color {
        switch kind {
        case .effect: Ed.gold
        case .graphic: Ed.appliedGraphic
        case .transition: Ed.appliedTransition
        case .speed: Ed.appliedSpeed
        }
    }

    func contains(_ t: Double) -> Bool { start - 0.001 <= t && t < max(end, start + 0.2) }

    static func == (a: AppliedItem, b: AppliedItem) -> Bool { a.id == b.id && a.start == b.start && a.end == b.end && a.label == b.label }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum AppliedItems {
    static func shapeLabel(_ kind: ShapeLayer.Kind) -> (String, String) {
        switch kind {
        case .progressBar: ("Barra di avanzamento", "minus")
        case .statusBar: ("Barra di stato", "record.circle")
        case .audioMeters: ("Vu-meter", "chart.bar.fill")
        case .halo: ("Alone", "circle.dashed")
        default: ("Richiamo", "arrow.up.right")
        }
    }

    static let effectLabels: [Effect.Kind: (String, String)] = [
        .glitch: ("Glitch", "square.grid.3x3"), .flash: ("Lampo", "bolt.fill"), .blur: ("Sfocatura", "drop"),
        .glow: ("Bagliore", "sun.max"), .shake: ("Scossa", "waveform.path"), .punchZoom: ("Punch-in", "plus.magnifyingglass"),
        .vignette: ("Vignettatura", "circle.dashed"), .sharpen: ("Nitidezza", "triangle"), .lut: ("LUT", "camera.filters"),
        .chromaKey: ("Chroma key", "person.crop.rectangle"),
    ]

    static func list(_ project: Project?) -> [AppliedItem] {
        guard let p = project else { return [] }
        var out: [AppliedItem] = []
        let main = p.tracks.first { $0.kind == .video && !$0.clips.isEmpty }?.id
        for track in p.tracks where track.kind == .video || track.kind == .overlay {
            for c in track.clips {
                for e in c.effects ?? [] {
                    let (key, symbol) = effectLabels[e.kind] ?? (e.kind.rawValue, "sparkles")
                    let label = loc(key)
                    let a = c.start.seconds + (e.start?.seconds ?? 0), b = e.end.map { c.start.seconds + $0.seconds } ?? c.end.seconds
                    out.append(AppliedItem(id: "fx-\(c.id)-\(e.id)", kind: .effect, label: label, symbol: symbol, start: a, end: b,
                                           command: "effect.remove", params: ["clipId": .string(c.id), "effectId": .string(e.id)]))
                }
                if let s = c.speed, track.id == main {
                    let label = s.freeze == true ? loc("Fermo immagine") : s.reverse == true ? loc("Indietro") : s.ramp != nil ? loc("Rampa di velocità")
                        : loc("Velocità %@×", String(format: "%g", s.rate ?? 1))
                    out.append(AppliedItem(id: "speed-\(c.id)", kind: .speed, label: label, symbol: "hare", start: c.start.seconds, end: c.end.seconds,
                                           command: "clip.speed", params: ["clipId": .string(c.id), "rate": 1]))
                }
                guard track.id != main else { continue }
                // Everything on the other picture tracks is a graphic or an insert the user can take off.
                let label: String, symbol: String
                if let t = c.title { label = loc("Testo «%@»", String(t.text.replacingOccurrences(of: "\n", with: " ").prefix(24))); symbol = "textformat" }
                else if let m = c.motion { label = loc(MotionRegistry.spec(m.template)?.label ?? m.template); symbol = "sparkles.rectangle.stack" }
                else if c.sticker != nil { label = loc("Sticker"); symbol = "face.smiling" }
                else if let sh = c.shape { let (k, sy) = shapeLabel(sh.kind); label = loc(k); symbol = sy }
                else { label = p.asset(c.assetID)?.name ?? loc("Immagine"); symbol = "photo" }
                out.append(AppliedItem(id: "clip-\(c.id)", kind: .graphic, label: label, symbol: symbol, start: c.start.seconds, end: c.end.seconds,
                                       command: "timeline.delete", params: ["clipIds": .array([.string(c.id)])]))
            }
        }
        for tr in p.transitions ?? [] {
            out.append(AppliedItem(id: "tr-\(tr.id)", kind: .transition, label: loc("Transizione: %@", loc(transitionLabel(tr.kind))), symbol: "rectangle.portrait.on.rectangle.portrait",
                                   start: tr.at.seconds - tr.duration.seconds / 2, end: tr.at.seconds + tr.duration.seconds / 2,
                                   command: "transition.remove", params: ["transitionId": .string(tr.id)]))
        }
        return out.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The name of a transition kind (a lookup key).
    static func transitionLabel(_ k: RegistaCore.Transition.Kind) -> String {
        switch k {
        case .flash: "Lampo"
        case .whip: "Frustata"
        case .dip: "Dissolvenza al nero"
        case .blur: "Sfocatura"
        }
    }

    /// Bars packed into as few rows as possible (a bar goes in the first row it does not overlap).
    static func rows(_ items: [AppliedItem], minimumGap: Double) -> [[AppliedItem]] {
        var rows: [[AppliedItem]] = []
        for it in items {
            if let r = rows.firstIndex(where: { ($0.last.map { max($0.end, $0.start + minimumGap) } ?? -1) <= it.start }) { rows[r].append(it) }
            else { rows.append([it]) }
        }
        return rows
    }
}

/// "Qui, al punto della testina": what is on the reel at the playhead, each with ✕ — and, when nothing is, where the
/// next thing is. The answer to "I clicked a tile, did anything happen?".
struct AppliedHere: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var state = GraphicsState.shared

    var body: some View {
        let all = AppliedItems.list(store.project)
        let here = all.filter { $0.contains(playhead.time) }
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionLabel(loc("Qui, a %@", shortTime(playhead.time)))
                Spacer()
                Text(verbatim: loc("%@ nel video", String(all.count))).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
            }
            if here.isEmpty {
                Text(verbatim: all.isEmpty ? loc("Ancora nessun effetto. Clicca un elemento qui sotto: compare in questo elenco e nella timeline.")
                                 : loc("Niente in questo punto: porta la testina su un effetto per vederlo qui."))
                    .font(Ed.ui(Ed.TypeSize.small)).foregroundStyle(Ed.text3).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(here) { it in row(it) }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.well))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.line))
    }

    private func row(_ it: AppliedItem) -> some View {
        let on = state.appliedSelection == it.id
        return HStack(spacing: Ed.Space.s) {
            RoundedRectangle(cornerRadius: Ed.Radius.xs).fill(it.color).frame(width: 4, height: 22)
            Image(systemName: it.symbol).font(Ed.icon(Ed.TypeSize.small)).foregroundStyle(Ed.text2).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: it.label).font(Ed.ui(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.text).lineLimit(1)
                Text(verbatim: "\(shortTime(it.start)) – \(shortTime(it.end))").font(Ed.mono(Ed.TypeSize.micro)).foregroundStyle(Ed.text3)
            }
            Spacer()
            IconButton(symbol: "xmark", help: "Togli", size: 20) { remove(it) }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.m).fill(on ? Ed.raised : .clear))
        .contentShape(Rectangle())
        .onTapGesture { state.appliedSelection = it.id; store.preview.seek(it.start) }
    }

    private func remove(_ it: AppliedItem) {
        if state.appliedSelection == it.id { state.appliedSelection = nil }
        store.run(it.command, .object(it.params))
    }
}
