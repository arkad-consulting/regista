import AVFoundation
import RegistaCore
import SwiftUI

/// The full editor (FilmCraft / Premiere structure): Source and Program monitors, then tool rail + timeline + loudness
/// meter. The library is the shell's side panel, the inspector and Claude its right panel (S1 #75).
struct ProWorkspace: View {
    @EnvironmentObject private var store: EditorStore
    /// Sizes the user dragged (0 = automatic, see `ProLayout`).
    @AppStorage("layout.pro.program") private var program = SplitSize.automatic
    @AppStorage("layout.pro.lower") private var lower = SplitSize.automatic

    var body: some View {
        GeometryReader { geo in layout(geo.size) }
    }

    private func layout(_ size: CGSize) -> some View {
        let l = ProLayout.compute(size, program: program, lower: lower, aspect: MonitorFit.aspect(store.project))
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                // Takes exactly what the splitter leaves (its transport adapts, see sourceTransport).
                SourceMonitor().frame(minWidth: 0, maxWidth: .infinity).clipped()
                Splitter(orientation: .vertical, stored: $program, current: l.program, range: l.programRange, direction: -1)
                ProgramMonitor().frame(width: l.program)
            }
            .frame(height: size.height - l.lower - ProLayout.gutter)
            Splitter(orientation: .horizontal, stored: $lower, current: l.lower, range: l.lowerRange, direction: -1)
            HStack(spacing: 2) {
                ToolRail().frame(width: 38)
                TimelinePanel()
                MeterPanel().frame(width: 96)
            }
            .frame(height: l.lower)
        }
        .background(Ed.bg)
    }
}

// MARK: - Monitors

struct SourceMonitor: View {
    @EnvironmentObject private var store: EditorStore
    @ObservedObject private var source: FrameSourceTime

    init() { _source = ObservedObject(wrappedValue: FrameSourceTime.shared) }

    var body: some View {
        let asset = store.sourceAssetID.flatMap { store.project?.asset($0) }
        VStack(spacing: 0) {
            PanelHeader(title: "Sorgente", subtitle: asset?.name)
            ZStack {
                Ed.well
                if asset != nil {
                    MonitorView(source: store.preview.source, aspect: aspect(asset))
                        .padding(10)
                } else {
                    EmptyHint(symbol: "film", text: "Doppio clic su un file in Media per vederlo qui")
                }
            }
            MonitorTransport(time: source.time, duration: asset?.duration.seconds ?? 0, playing: source.playing, compact: true,
                             seek: { source.seek($0) }, step: { source.step($0) }, toggle: { source.toggle() })
        }
        .background(Ed.panel)
        .onAppear { source.bind(store.preview.source); store.preview.showSource(asset) }
        .onChange(of: store.sourceAssetID) { store.preview.showSource(asset) }
    }

    private func aspect(_ a: MediaAsset?) -> CGFloat {
        guard let v = a?.video, v.height > 0 else { return 16 / 9 }
        return CGFloat(v.width) / CGFloat(v.height)
    }
}

/// Time and play state of the Source monitor's player.
@MainActor
final class FrameSourceTime: ObservableObject {
    static let shared = FrameSourceTime()
    @Published var time: Double = 0
    @Published var playing = false
    private weak var src: FrameSource?
    private var observer: Any?

    func bind(_ s: FrameSource) {
        guard src !== s else { return }
        src = s
        observer = s.player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 15), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                self?.time = t.seconds.isFinite ? t.seconds : 0
                self?.playing = s.player.rate != 0
            }
        }
    }

    func toggle() { guard let p = src?.player else { return }; p.rate == 0 ? p.play() : p.pause() }
    func step(_ frames: Int) { seek(time + Double(frames) / 30) }
    func seek(_ seconds: Double) {
        guard let p = src?.player else { return }
        p.pause()
        p.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

struct ProgramMonitor: View {
    @EnvironmentObject private var store: EditorStore
    /// Two-row transport for the narrow monitor of the Pro workspace.
    var compactTransport = true

    var body: some View {
        let s = store.project?.settings ?? ProjectSettings()
        let vertical = MonitorFit.showsInstagramZones(width: s.width, height: s.height)
        VStack(spacing: 0) {
            PanelHeader(title: "Programma", subtitle: MonitorFit.label(width: s.width, height: s.height)) {
                IconButton(symbol: "rectangle.dashed",
                           help: vertical ? "Guide: dove Instagram copre il video con i suoi pulsanti. Solo una guida, l'export resta intero."
                                          : "Le guide di Instagram valgono solo per il formato 9:16.",
                           active: vertical && store.safeZones) {
                    store.safeZones.toggle()
                }
                .disabled(!vertical)
                .opacity(vertical ? 1 : 0.4)
            }
            ProgramPicture().padding(10).background(Ed.well)
            TransportBar(compact: compactTransport)
        }
        .background(Ed.panel)
    }
}

/// The picture in the project's format (letterboxed in the monitor, #52), with the safe-zone overlay on a 9:16 frame.
struct ProgramPicture: View {
    @EnvironmentObject private var store: EditorStore
    /// The Semplice level shows the clean picture.
    var zones = true

    var body: some View {
        GeometryReader { geo in
            let aspect = MonitorFit.aspect(store.project)
            let fitted = MonitorFit.size(aspect: aspect, in: geo.size)
            let w = fitted.width, h = fitted.height
            let s = store.project?.settings ?? ProjectSettings()
            ZStack {
                if store.project?.duration ?? .zero > .zero {
                    MonitorView(source: store.preview.program, aspect: aspect)
                        .frame(width: w, height: h)
                    if zones, store.safeZones, !store.canvasDragging, MonitorFit.showsInstagramZones(width: s.width, height: s.height) {
                        SafeZones(captionBand: captionBand).frame(width: w, height: h).allowsHitTesting(false)
                    }
                    // Click, drag, resize and rotate captions and graphics on the picture (issue #21).
                    CanvasOverlay(size: CGSize(width: w, height: h))
                } else {
                    EmptyHint(symbol: "rectangle.portrait", text: "La timeline è vuota. Importa un video o chiedi a Claude di montarlo.")
                }
                if let e = store.preview.buildError {
                    Text(verbatim: loc("Anteprima non disponibile: %@", e)).font(Ed.ui(10)).foregroundStyle(Ed.danger).padding(8).background(Ed.panel.opacity(0.9))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture { store.preview.togglePlay() }
        }
    }

    /// Caption band as fractions of the frame height, from the caption style (or where the captions were moved by hand).
    private var captionBand: ClosedRange<Double> {
        let captions = store.project?.tracks.first { $0.kind == .caption && $0.captions != nil }?.captions
        let style = captions?.style ?? CaptionStyle.talkingHeadV1
        let h = style.bandHeight * (captions?.place?.scale ?? 1)
        let top = captions?.place?.y.map { $0 - h / 2 } ?? style.bandY
        return max(top / style.referenceHeight, 0)...min((top + h) / style.referenceHeight, 1)
    }
}

/// Instagram Reels UI zones on a 1080×1920 frame (top bar, bottom caption/CTA area, right action column; the same
/// limits as `RegistaCore.SafeZones.instagram`, which the layout warnings and the drag overlay use). Guides only: thin
/// dashed lines with a label inside each zone and nothing dimmed, so they never read as a crop (the export is the whole
/// frame); the caption band outlined in gold.
struct SafeZones: View {
    let captionBand: ClosedRange<Double>

    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            let edge = Color.white.opacity(0.55)
            let z = RegistaCore.SafeZones.self
            let top = H * z.topLimit / z.referenceHeight, bottom = H * (z.referenceHeight - z.bottomLimit) / z.referenceHeight
            let colW = W * z.rightMargin / z.referenceWidth, colTop = top
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: top)); p.addLine(to: CGPoint(x: W, y: top))
                    p.move(to: CGPoint(x: 0, y: H - bottom)); p.addLine(to: CGPoint(x: W, y: H - bottom))
                    p.move(to: CGPoint(x: W - colW, y: colTop)); p.addLine(to: CGPoint(x: W - colW, y: H - bottom))
                }
                .stroke(edge, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                label("Instagram: nome account").offset(x: 4, y: top - 12)
                label("Instagram: descrizione e pulsanti").offset(x: 4, y: H - bottom + 3)
                Rectangle()
                    .strokeBorder(Ed.gold.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .frame(width: W * 0.92, height: H * (captionBand.upperBound - captionBand.lowerBound))
                    .offset(x: W * 0.04, y: H * captionBand.lowerBound)
                Text(verbatim: loc("Sottotitoli").uppercased(with: Locale.current)).font(Ed.mono(7, .medium)).foregroundStyle(Ed.gold)
                    .offset(x: W * 0.04 + 3, y: H * captionBand.lowerBound - 10)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(verbatim: loc(text)).font(Ed.mono(7, .medium)).foregroundStyle(Color.white.opacity(0.85))
            .padding(.horizontal, 3).background(Color.black.opacity(0.45))
    }
}

/// Timecode, transport buttons, duration of the Program player.
struct TransportBar: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    var large = false
    /// Two rows (timecodes above the buttons) for the narrow 9:16 monitor.
    var compact = false

    var body: some View {
        let p = store.preview
        MonitorTransport(time: playhead.time, duration: store.project?.duration.seconds ?? 0, playing: p.isPlaying,
                         large: large, compact: compact, shortcuts: true,
                         seek: { p.seek($0) }, step: { p.step(frames: $0) }, toggle: { p.togglePlay() })
    }
}

/// The one transport every player uses (Program, Source, Semplice): gold timecode, the same five buttons, grey duration,
/// so the monitors always read the same.
struct MonitorTransport: View {
    let time: Double
    let duration: Double
    let playing: Bool
    var large = false
    var compact = false
    /// Show the keyboard shortcuts in the tooltips (they drive the Program player only).
    var shortcuts = false
    let seek: (Double) -> Void
    let step: (Int) -> Void
    let toggle: () -> Void

    var body: some View {
        if compact {
            VStack(spacing: 2) {
                HStack {
                    Text(verbatim: timecode(frames: time)).font(Ed.mono(12, .medium)).foregroundStyle(Ed.gold).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(verbatim: timecode(frames: duration)).font(Ed.mono(11)).foregroundStyle(Ed.text3).lineLimit(1)
                }
                HStack(spacing: 4) { buttons }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Ed.panel)
        } else {
            ViewThatFits(in: .horizontal) {
                wideRow(duration: true)
                wideRow(duration: false)
            }
            .padding(.horizontal, 12)
            .frame(height: large ? 46 : 36)
            .background(Ed.panel)
        }
    }

    private func wideRow(duration showDuration: Bool) -> some View {
        HStack(spacing: large ? 14 : 6) {
            Text(verbatim: timecode(frames: time)).font(Ed.mono(large ? 14 : 12, .medium)).foregroundStyle(Ed.gold).fixedSize()
            Spacer(minLength: 4)
            buttons
            Spacer(minLength: 4)
            if showDuration {
                Text(verbatim: timecode(frames: duration)).font(Ed.mono(large ? 14 : 12)).foregroundStyle(Ed.text3).fixedSize()
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        IconButton(symbol: "backward.end.fill", help: "Vai all'inizio", shortcut: shortcuts ? "↖" : nil) { seek(0) }
        IconButton(symbol: "backward.frame.fill", help: "Fotogramma precedente", shortcut: shortcuts ? "←" : nil) { step(-1) }
        IconButton(symbol: playing ? "pause.fill" : "play.fill", help: playing ? "Pausa" : "Riproduci", shortcut: shortcuts ? "Spazio" : nil,
                   size: large ? 34 : 26) { toggle() }
        IconButton(symbol: "forward.frame.fill", help: "Fotogramma successivo", shortcut: shortcuts ? "→" : nil) { step(1) }
        IconButton(symbol: "forward.end.fill", help: "Vai alla fine", shortcut: shortcuts ? "↘" : nil) { seek(duration) }
    }
}

// MARK: - Tool rail

struct ToolRail: View {
    @EnvironmentObject private var store: EditorStore
    var body: some View {
        VStack(spacing: 6) {
            tool(.select, "cursorarrow", "Selezione", "V")
            tool(.razor, "scissors", "Lama", "C")
            tool(.text, "textformat", "Testo: parole chiave dei sottotitoli", "T")
            tool(.hand, "hand.raised", "Mano", "H")
            Spacer()
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity)
        .background(Ed.panel)
    }

    private func tool(_ t: EditorStore.Tool, _ symbol: String, _ help: String, _ key: String) -> some View {
        IconButton(symbol: symbol, help: help, shortcut: key, active: store.tool == t, size: 28) { store.tool = t }
    }
}

// MARK: - Loudness meter

struct MeterPanel: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @EnvironmentObject private var meter: LoudnessMeter

    private let floor = -48.0

    var body: some View {
        let c = meter.curve
        let now = c.at(playhead.time)
        VStack(spacing: 0) {
            PanelHeader(title: "LUFS")
            GeometryReader { g in scale(now, H: g.size.height) }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            VStack(spacing: 3) {
                readout("M", now.m, "LUFS")
                readout("S", now.s, "LUFS")
                readout("I", c.integrated, "LUFS", highlight: true)
                readout("TP", c.truePeak, "dBTP", warn: LoudnessTarget.peakOver(c.truePeak))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Ed.panel)
    }

    private func scale(_ now: (m: Double, s: Double), H: CGFloat) -> some View {
        let y: (Double) -> CGFloat = { db in CGFloat(min(max(db / floor, 0), 1)) * H }
        return HStack(alignment: .top, spacing: 4) {
                    // Scale
                    ZStack(alignment: .topTrailing) {
                        ForEach([0, -6, -12, -18, -24, -30, -36, -42], id: \.self) { d in
                            Text(verbatim: "\(d)").font(Ed.mono(8)).foregroundStyle(Ed.text3).offset(y: y(Double(d)) - 5)
                        }
                    }
                    .frame(width: 20, height: H, alignment: .topTrailing)
                    bar(now.m, H: H, y: y, label: "M")
                    bar(now.s, H: H, y: y, label: "S")
                }
        .overlay(alignment: .topLeading) {
            // The house target (LoudnessTarget; −14 is the platforms' reference).
            Rectangle().fill(Ed.gold.opacity(0.8)).frame(width: 46, height: 1).offset(x: 24, y: y(LoudnessTarget.integrated))
        }
    }

    private func bar(_ db: Double, H: CGFloat, y: (Double) -> CGFloat, label: String) -> some View {
        ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: 1.5).fill(Ed.well)
            if db.isFinite {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(LinearGradient(colors: [Ed.audioWave.opacity(0.85), Ed.audioWave, Ed.gold], startPoint: .bottom, endPoint: .top))
                    .frame(height: max(0, H - y(db)))
            }
        }
        .frame(width: 14, height: H)
        .tip(label == "M" ? "Loudness momentanea (400 ms)" : "Loudness a breve termine (3 s)")
    }

    private func readout(_ k: String, _ v: Double, _ unit: String, highlight: Bool = false, warn: Bool = false) -> some View {
        HStack(spacing: 4) {
            Text(verbatim: k).font(Ed.mono(9.5, .medium)).foregroundStyle(Ed.text3).frame(width: 16, alignment: .leading)
            Spacer(minLength: 0)
            Text(verbatim: v.isFinite ? String(format: "%.1f", v) : (meter.measuring || meter.curve.momentary.isEmpty ? "…" : "–∞"))
                .font(Ed.mono(10, .medium))
                .foregroundStyle(warn ? Ed.danger : (highlight ? Ed.gold : Ed.text2))
            Text(verbatim: unit).font(Ed.mono(7.5)).foregroundStyle(Ed.text3).frame(width: 22, alignment: .leading)
        }
    }
}
