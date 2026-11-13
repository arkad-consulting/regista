import RegistaCore
import SwiftUI

/// The simple review view (InShot-like): a big 9:16 preview, one filmstrip of the edit, large buttons (what Claude did
/// is in the right panel's Claude tab). The default view of a project the agent edited last.
struct QuickWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var meter: LoudnessMeter
    @State private var panel: QuickPanel?

    enum QuickPanel: String, Identifiable { case takes, captions, graphics, music; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                HStack(spacing: 0) {
                    summary.frame(width: min(340, max(240, g.size.width * 0.3)))
                    VStack(spacing: 10) {
                        ProgramPicture(zones: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        TransportBar(large: true)
                            .frame(maxWidth: 520)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Ed.panel))
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                }
            }
            Filmstrip().frame(height: 128)
            bigButtons
        }
        .background(Ed.bg)
        .popover(item: $panel, arrowEdge: .bottom) { p in
            Group {
                switch p {
                case .takes: TakesView().frame(width: 420, height: 460)
                case .captions: TextsTab().frame(width: 420, height: 460)
                case .graphics: GraphicsTab().frame(width: 360, height: 260)
                case .music: AudioMixTab().frame(width: 360, height: 420)
                }
            }
            .background(Ed.panel)
            .environment(\.colorScheme, .dark)
        }
    }

    private var summary: some View {
        let p = store.project
        let videoClips = p?.tracks.filter { $0.kind == .video }.flatMap(\.clips).count ?? 0
        let captions = p?.tracks.first { $0.kind == .caption }?.captions
        let lastAgent = store.activity.last { $0.isAgent && $0.status == .ok && !$0.readOnly }
        return VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("RELEGGI IL MONTAGGIO")
                Text(verbatim: p?.name ?? loc("Nessun progetto")).font(Ed.display(26, .medium)).foregroundStyle(Ed.text).lineLimit(2)
                if let p, p.duration > .zero {
                    let fps = Int(p.settings.frameRate.doubleValue.rounded())
                    Text(verbatim: "\(shortTime(p.duration.seconds)) · \(p.settings.width)×\(p.settings.height) · \(fps) fps")
                        .font(Ed.mono(11)).foregroundStyle(Ed.text2)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                fact("film.stack", videoClips == 1 ? loc("1 clip in timeline") : loc("%@ clip in timeline", String(videoClips)))
                fact("captions.bubble", captions.map { loc("%@ sottotitoli · %@ parole chiave", String($0.chunks.count), String($0.keywords.count)) }
                     ?? loc("Senza sottotitoli"))
                fact("waveform", meter.curve.integrated.isFinite ? loc("%.1f LUFS · picco %.1f dBTP", meter.curve.integrated, meter.curve.truePeak)
                                                                 : loc("Audio non misurato"))
                fact("list.number", p?.takes.map { t in loc("%@/%@ righe del copione", String(t.lines.filter { $0.chosen != nil }.count), String(t.lines.count)) }
                     ?? loc("Nessun copione"))
            }
            if let lastAgent {
                VStack(alignment: .leading, spacing: 3) {
                    SectionLabel(loc("Ultimo passo di %@", lastAgent.source))
                    Text(verbatim: CommandTitles.title(lastAgent.command)).font(Ed.ui(12, .medium)).foregroundStyle(Ed.gold)
                    Text(lastAgent.started, style: .relative).font(Ed.ui(10.5)).foregroundStyle(Ed.text3)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                EdButton(title: "Apri nel montaggio Pro", symbol: "rectangle.split.3x1") { store.workspace = .pro }
                EdButton(title: "Montaggio automatico", symbol: "wand.and.stars") {
                    store.autoEdit(script: TeleprompterController.shared.text)
                }
                .disabled(store.project?.assets.isEmpty ?? true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ed.panel)
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(Ed.icon(11)).foregroundStyle(Ed.text3).frame(width: 16)
            Text(verbatim: loc(text)).font(Ed.ui(11.5)).foregroundStyle(Ed.text2).lineLimit(2)
        }
    }

    private var bigButtons: some View {
        HStack(spacing: 10) {
            big("Riprese", "person.crop.rectangle.stack") { panel = .takes }
            big("Sottotitoli", "captions.bubble") { panel = .captions }
            big("Grafica", "sparkles.rectangle.stack") { store.studio = .filters }
            big("Musica", "music.note") { panel = .music }
            big("Esporta", "square.and.arrow.up", prominent: true) { store.workspace = .export }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Ed.panel)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    private func big(_ title: String, _ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        BigButton(title: title, symbol: symbol, prominent: prominent, action: action)
    }
}

struct BigButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(Ed.icon(19, .regular)).frame(height: 22)
                Text(verbatim: loc(title)).font(Ed.ui(11.5, .medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(prominent ? Color.black.opacity(0.85) : (hover ? Ed.text : Ed.text2))
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .background(RoundedRectangle(cornerRadius: 10).fill(prominent ? Ed.gold : (hover ? Ed.hover : Ed.raised)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(prominent ? .clear : Ed.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The edit as one strip of frames (each video clip's thumbnails), with the playhead; click to seek.
/// The edit as a strip you can read: a time ruler, the clips as real frames, the playhead with its timecode, and above
/// the frames one bar per effect, graphic, transition or speed change (AppliedItems) — click a bar to go there and
/// pick it, ✕ on the picked bar removes it. Drag on the frames to scrub; drop a gallery tile to apply it there.
struct Filmstrip: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var media: MediaCache
    @EnvironmentObject private var playhead: Playhead
    @ObservedObject private var studio = StudioState.shared
    /// Show the effect bars (the studio); the Quick view keeps them too.
    var effects = true

    static let ruler: CGFloat = 18, lane: CGFloat = 16, maxLanes = 3, pad: CGFloat = 16

    var body: some View {
        GeometryReader { g in
            let p = store.project
            let duration = max(p?.duration.seconds ?? 0, 0.001)
            let W = g.size.width - Self.pad * 2
            let items = effects ? AppliedItems.list(p) : []
            let rows = Array(AppliedItems.rows(items, minimumGap: Double(70 / max(W, 1)) * duration).prefix(Self.maxLanes))
            let lanesH = effects ? CGFloat(max(rows.count, 1)) * Self.lane + 4 : 0
            let framesTop = Self.ruler + lanesH
            let H = max(g.size.height - framesTop - 8, 24)
            let x = { (t: Double) in CGFloat(t / duration) * W }
            let _ = media.revision
            ZStack(alignment: .topLeading) {
                rulerView(duration: duration, width: W)
                if effects {
                    if items.isEmpty {
                        Text("Gli effetti che aggiungi compaiono qui, nel punto dove li hai messi")
                            .font(Ed.ui(10)).foregroundStyle(Ed.text3)
                            .offset(y: Self.ruler + 1)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                        ForEach(row) { it in bar(it, x: x(it.start), width: max(x(it.end) - x(it.start), 6)).offset(y: Self.ruler + CGFloat(r) * Self.lane) }
                    }
                }
                frames(p, duration: duration, width: W, height: H).frame(width: W, height: H).offset(y: framesTop)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        store.preview.seek(Double(min(max(v.location.x, 0), W) / W) * duration)
                    })
                // Playhead through ruler, bars and frames, with its timecode.
                Rectangle().fill(Ed.gold).frame(width: 2, height: g.size.height - 4)
                    .offset(x: x(playhead.time) - 1, y: 2).shadow(color: .black.opacity(0.6), radius: 2).allowsHitTesting(false)
                Text(verbatim: shortTime(playhead.time)).font(Ed.mono(9.5, .semibold)).foregroundStyle(Color.black.opacity(0.85))
                    .padding(.horizontal, 4).frame(height: 14).background(RoundedRectangle(cornerRadius: 3).fill(Ed.gold))
                    .fixedSize().offset(x: min(max(x(playhead.time) - 18, 0), W - 36), y: 1).allowsHitTesting(false)
            }
            .padding(.horizontal, Self.pad)
            .padding(.top, 4)
            // An effects-gallery tile dropped on the strip applies at that moment (issue #16).
            .onDrop(of: [.text], isTargeted: nil) { providers, loc in
                guard let pr = providers.first else { return false }
                let time = Double(min(max(loc.x - Self.pad, 0), W) / W) * duration
                _ = pr.loadObject(ofClass: NSString.self) { s, _ in
                    guard let id = s as? String else { return }
                    DispatchQueue.main.async { Gallery.apply(id, store: store, at: time) }
                }
                return true
            }
        }
        .background(Ed.panel)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    private func rulerView(duration: Double, width W: CGFloat) -> some View {
        // A label every 1, 2, 5, 10… s so labels stay ≥ 60 px apart.
        let step = [1.0, 2, 5, 10, 15, 30, 60].first { CGFloat($0 / duration) * W >= 60 } ?? 60
        return Canvas { ctx, size in
            var t = 0.0
            while t <= duration + 0.001 {
                let px = CGFloat(t / duration) * W
                ctx.fill(Path(CGRect(x: px, y: size.height - 5, width: 1, height: 5)), with: .color(Ed.text3))
                ctx.draw(Text(verbatim: shortTime(t)).font(Ed.mono(9)).foregroundStyle(Ed.text3), at: CGPoint(x: px + 3, y: 6), anchor: .topLeading)
                t += step
            }
        }
        .frame(width: W, height: Self.ruler)
        .allowsHitTesting(false)
    }

    private func bar(_ it: AppliedItem, x: CGFloat, width: CGFloat) -> some View {
        let on = studio.appliedSelection == it.id
        return HStack(spacing: 3) {
            Image(systemName: it.symbol).font(Ed.icon(8, .semibold))
            if width > 46 { Text(verbatim: loc(it.label)).font(Ed.ui(9.5, .semibold)).lineLimit(1) }
            Spacer(minLength: 0)
            if on {
                Button { studio.appliedSelection = nil; store.run(it.command, .object(it.params)) } label: {
                    Image(systemName: "xmark").font(Ed.icon(8, .bold))
                }
                .buttonStyle(.plain).tip("Togli")
            }
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 4)
        .frame(width: max(width, on ? 34 : width), height: Self.lane - 3, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(it.color.opacity(on ? 1 : 0.85)))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(on ? Color.white : .clear, lineWidth: 1.5))
        .offset(x: x)
        .onTapGesture { studio.appliedSelection = it.id; store.preview.seek(it.start) }
        .tip("\(loc(it.label)) · \(shortTime(it.start))–\(shortTime(it.end))")
    }

    private func frames(_ p: Project?, duration: Double, width W: CGFloat, height H: CGFloat) -> some View {
        Canvas { ctx, size in
            MainActor.assumeIsolated {
                guard let p, let track = p.tracks.first(where: { $0.kind == .video }) else { return }
                let pps = W / duration
                for clip in track.clips {
                    guard let a = p.asset(clip.assetID), let v = a.video else { continue }
                    let rect = CGRect(x: clip.start.seconds * pps, y: 0, width: clip.duration.seconds * pps, height: H)
                    let tw = H * CGFloat(v.width) / CGFloat(max(v.height, 1))
                    ctx.drawLayer { l in
                        l.clip(to: Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 4))
                        var x = rect.minX
                        while x < rect.maxX {
                            if let img = media.thumbnail(a.path, at: clip.sourceIn.seconds + Double((x - rect.minX) / pps)) {
                                l.draw(Image(decorative: img, scale: 1), in: CGRect(x: x, y: 0, width: tw, height: H))
                            }
                            x += tw
                        }
                    }
                    ctx.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0), cornerRadius: 4), with: .color(Color.black.opacity(0.85)), lineWidth: 2)
                }
            }
        }
    }
}
