import AppKit
import RegistaCore
import SwiftUI
import UniformTypeIdentifiers

/// One lane of the timeline: a project track, or the empty slot of a standard track
/// (T1 captions · V2 graphics/AI · V1 footage · A1 voice · A2 music · A3 SFX).
struct LaneRow: Identifiable {
    enum Role { case captions, graphics, footage, voice, music, sfx, extra }
    var id: String
    var label: String
    var title: String
    var role: Role
    var kind: TrackKind
    var track: Track?
    var height: CGFloat

    /// An overlay track's lane title by its role (a key): the engine names a second titles track "Titles 2", which is no
    /// key (#75).
    static func roleTitle(_ t: Track) -> String? { ["titles": "Titoli", "logo": "Logo", "inserts": "Piani IA"][t.role ?? ""] }

    static func rows(_ project: Project?) -> [LaneRow] {
        let tracks = project?.tracks ?? []
        let captions = tracks.filter { $0.kind == .caption }
        let overlays = tracks.filter { $0.kind == .overlay }
        let videos = tracks.filter { $0.kind == .video }
        let audios = tracks.filter { $0.kind == .audio }
        var rows: [LaneRow] = []
        if captions.isEmpty {
            rows.append(LaneRow(id: "slot-T1", label: "T1", title: "Sottotitoli", role: .captions, kind: .caption, track: nil, height: 30))
        }
        for (i, t) in captions.enumerated().reversed() {
            rows.append(LaneRow(id: t.id, label: "T\(i + 1)", title: i == 0 ? "Sottotitoli" : t.name, role: .captions, kind: .caption, track: t, height: 30))
        }
        if overlays.isEmpty {
            rows.append(LaneRow(id: "slot-V2", label: "V\(max(videos.count, 1) + 1)", title: "Grafica / IA", role: .graphics, kind: .overlay, track: nil, height: 34))
        }
        for (i, t) in overlays.enumerated().reversed() {
            let byRole = t.kind == .overlay ? roleTitle(t) : nil
            // A default name («O3») is not a name a person reads (#92): every graphics lane without one of its own is Grafica.
            rows.append(LaneRow(id: t.id, label: "V\(max(videos.count, 1) + 1 + i)", title: byRole ?? (i > 0 && renamed(t) ? t.name : "Grafica / IA"),
                                role: .graphics, kind: .overlay, track: t, height: 34))
        }
        if videos.isEmpty {
            rows.append(LaneRow(id: "slot-V1", label: "V1", title: "track.footage", role: .footage, kind: .video, track: nil, height: 54))
        }
        for (i, t) in videos.enumerated().reversed() {
            rows.append(LaneRow(id: t.id, label: "V\(i + 1)", title: i == 0 && !renamed(t) ? "track.footage" : t.name, role: i == 0 ? .footage : .extra,
                                kind: .video, track: t, height: i == 0 ? 54 : 40))
        }
        // Audio by role: voice first (no role), then music, then SFX (audio.addMusic / sfx.add set the roles).
        let voice = audios.filter { $0.role == nil || $0.role == "voice" }
        let music = audios.filter { $0.role == "music" }
        let sfx = audios.filter { $0.role == "sfx" }
        let other = audios.filter { !voice.contains($0) && !music.contains($0) && !sfx.contains($0) }
        var lanes: [(Track?, Role, String, CGFloat)] = []
        if voice.isEmpty { lanes.append((nil, .voice, "Voce", 50)) }
        // The generated voice (voice.say's «Voce» track) beside a default-named voice lane: that lane carries the footage's
        // own sound, and says so (#95: two lanes read «Voce»).
        let generated = voice.contains { $0.name == "Voce" }
        for (i, t) in voice.enumerated() {
            let title = !renamed(t) && generated ? "track.footageSound" : i == 0 && !renamed(t) ? "Voce" : t.name
            lanes.append((t, i == 0 ? .voice : .extra, title, i == 0 ? 50 : 34))
        }
        if music.isEmpty, voice.count < 2 { lanes.append((nil, .music, "Musica", 38)) }
        for t in music { lanes.append((t, .music, "Musica", 38)) }
        if sfx.isEmpty, voice.count < 3 { lanes.append((nil, .sfx, "track.sfx", 30)) }
        for t in sfx { lanes.append((t, .sfx, "track.sfx", 30)) }
        for t in other { lanes.append((t, .extra, t.name, 34)) }
        for (i, lane) in lanes.enumerated() {
            rows.append(LaneRow(id: lane.0?.id ?? "slot-A\(i + 1)", label: "A\(i + 1)", title: lane.2, role: lane.1, kind: .audio,  // l10n-ignore
                                track: lane.0, height: lane.3))
        }
        return rows
    }

    /// A main track the user (or a command) gave its own name: the lane shows it instead of "Riprese" / "Voce". A lane's
    /// title is a lookup key (the default names) or the track's own name, which no key matches: TrackHeader draws loc(title).
    static func renamed(_ t: Track) -> Bool {
        t.name.range(of: #"^[VAOC]\d+$"#, options: .regularExpression) == nil
    }

    /// Spare height goes to the footage and voice lanes (bigger thumbnails and waveforms), up to a limit.
    static func fitted(_ rows: [LaneRow], into available: CGFloat) -> [LaneRow] {
        let extra = available - rows.reduce(0) { $0 + $1.height }
        guard extra > 4 else { return rows }
        return rows.map { r in
            var r = r
            if r.role == .footage { r.height += min(extra * 0.55, 46) }
            if r.role == .voice { r.height += min(extra * 0.45, 30) }
            return r
        }
    }
}

struct TimelinePanel: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var media: MediaCache
    @State private var position = ScrollPosition(edge: .leading)
    @State private var scrollX: CGFloat = 0
    /// The scroll offset when a Hand drag began.
    @State private var handStart: CGFloat?
    @State private var viewWidth: CGFloat = 800
    @State private var drag: DragState?

    static let rulerHeight: CGFloat = 26
    static let headerWidth: CGFloat = 172
    /// Time 0 sits this far from the left edge (room for the playhead head).
    static let originX: CGFloat = 12

    struct DragState {
        enum Kind {
            case scrub, empty, hand, razor(String), keyword, caption
            case move(Clip), trim(Clip, String)
        }
        var kind: Kind
        var start: CGPoint
        var translation: CGSize = .zero
    }

    private var pps: CGFloat { CGFloat(store.pxPerSec) }
    private var fps: Double { store.project?.settings.frameRate.doubleValue ?? 30 }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { outer in
                // More tracks than fit: the whole stack (headers and lanes together) scrolls vertically.
                let rows = LaneRow.fitted(LaneRow.rows(store.project), into: outer.size.height - Self.rulerHeight)
                let content = max(outer.size.height, Self.rulerHeight + rows.reduce(0) { $0 + $1.height })
                ScrollView(.vertical, showsIndicators: content > outer.size.height + 1) {
                    tracks(rows).frame(height: content)
                }
                .scrollDisabled(content <= outer.size.height + 1)
            }
            ZoomBar()
        }
        .background(Ed.panel)
        .onChange(of: store.fitRequest) { fit() }
        .onChange(of: store.project?.duration) { autoFit() }
    }

    /// Where a drop at `loc` lands: the track row under it, the empty slot of a standard track, or the space below.
    static func dropTarget(at loc: CGPoint, rows: [LaneRow]) -> MediaDrop.Target {
        guard let row = row(at: loc.y, rows) else { return .below }
        if let t = row.track { return .track(t.id) }
        return .slot(row.kind)
    }

    /// Media dragged from the Media panel (`regista-asset:<id>`) or files from the Finder: placed at the drop time,
    /// snapped to the playhead and the clip edges.
    private static func dropMedia(_ providers: [NSItemProvider], at loc: CGPoint, rows: [LaneRow], store: EditorStore, pps: CGFloat) -> Bool {
        guard let project = store.project else { return false }
        let raw = max(Double((loc.x - Self.originX) / pps), 0)
        let time = MediaDrop.snap(raw, project: project, playhead: store.preview.time, tolerance: Double(8 / pps))
        let target = dropTarget(at: loc, rows: rows)
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            let group = DispatchGroup()
            final class Box: @unchecked Sendable { var urls: [URL] = [] }
            let box = Box()
            for f in files {
                group.enter()
                _ = f.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { box.urls.append(url) } }
                    group.leave()
                }
            }
            group.notify(queue: .main) { store.dropMedia(assets: [], files: box.urls.sorted { $0.path < $1.path }, at: time, on: target) }
            return true
        }
        return false
    }

    /// What the timeline's drop delegate does with a drop at `loc` (content coordinates): Finder files and Media tiles
    /// placed on the track under the pointer, a sound of the Audio panel, a Graphics row on a clip or a moment. The drop
    /// tests call it with an item provider of their own (#36: a drag session is never started in a test).
    static func drop(_ providers: [NSItemProvider], at loc: CGPoint, rows: [LaneRow], store: EditorStore, pps: CGFloat) -> Bool {
        if dropMedia(providers, at: loc, rows: rows, store: store, pps: pps) { return true }
        guard let p = providers.first else { return false }
        let time = max(Double((loc.x - Self.originX) / pps), 0)
        var y = Self.rulerHeight, clip: String?
        for r in rows {
            if loc.y >= y && loc.y < y + r.height, let t = r.track {
                clip = t.clips.first { $0.start.seconds <= time && time < $0.end.seconds }?.id
            }
            y += r.height
        }
        let target = dropTarget(at: loc, rows: rows)
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let id = s as? String else { return }
            DispatchQueue.main.async {
                if id.hasPrefix(SFXDrop.prefix) {
                    // A sound of the Audio panel's browser: sfx.add at the drop time (snapped like the media).
                    let at = store.project.map { MediaDrop.snap(time, project: $0, playhead: store.preview.time, tolerance: Double(8 / pps)) } ?? time
                    store.addSoundEffect(String(id.dropFirst(SFXDrop.prefix.count)), at: at)
                } else if id.hasPrefix(MediaDrop.assetPrefix), let project = store.project {
                    // A Media tile: the asset goes on the track under the pointer (snapped), linked picture and sound.
                    let at = MediaDrop.snap(time, project: project, playhead: store.preview.time, tolerance: Double(8 / pps))
                    store.dropMedia(assets: [String(id.dropFirst(MediaDrop.assetPrefix.count))], files: [], at: at, on: target)
                } else {
                    GraphicsActions.apply(id, store: store, at: time, clipID: clip)
                }
            }
        }
        return true
    }

    private func tracks(_ rows: [LaneRow]) -> some View {
        let lanesHeight = rows.reduce(0) { $0 + $1.height }
        let duration = store.project?.duration.seconds ?? 0
        return HStack(spacing: 0) {
                VStack(spacing: 0) {
                    TimelineCorner().frame(height: Self.rulerHeight)
                    ForEach(rows) { r in TrackHeader(row: r).frame(height: r.height) }
                    Spacer(minLength: 0)
                }
                .frame(width: Self.headerWidth)
                .background(Ed.panel)
                .overlay(alignment: .trailing) { Ed.line.frame(width: 1) }

                GeometryReader { g in
                    let contentWidth = max(g.size.width, Self.originX + CGFloat(duration) * pps + 240)
                    ScrollView(.horizontal, showsIndicators: true) {
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                Ruler(pps: pps, fps: fps, width: contentWidth).frame(height: Self.rulerHeight)
                                lanes(rows, width: contentWidth, height: lanesHeight)
                                Spacer(minLength: 0)
                            }
                            PlayheadLine(pps: pps, height: g.size.height, follow: { x in follow(x) })
                        }
                        .frame(width: contentWidth, height: g.size.height, alignment: .topLeading)
                        .contentShape(Rectangle())
                        .gesture(gesture(rows))
                        .simultaneousGesture(handGesture)
                        // A Graphics panel row dropped on a clip or a moment (issue #16, E4 #3).
                        // A Media tile or a Finder file: placed on the track under the pointer (E1 #53).
                        .onDrop(of: [.text, .fileURL], isTargeted: nil) { providers, loc in Self.drop(providers, at: loc, rows: rows, store: store, pps: pps) }
                        // Right click on a clip: its actions (E1 #53).
                        .overlay(ContextMenuArea { point in clipMenu(at: point, rows: rows) })
                    }
                    .scrollPosition($position)
                    .coordinateSpace(name: Self.viewport)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollX = x }
                    .onAppear { viewWidth = g.size.width; autoFit() }
                    .onChange(of: g.size.width) { viewWidth = g.size.width }
                }
                .background(Ed.well)
            }
    }

    // MARK: Zoom / scroll

    private func fit() {
        let d = max(store.project?.duration.seconds ?? 0, 5)
        store.pxPerSec = Double(max(viewWidth - 48, 200)) / d
        store.autoFit = true
        position.scrollTo(x: 0)
    }

    private func autoFit() { if store.autoFit { fit() } }

    private func follow(_ x: CGFloat) {
        guard store.preview.isPlaying, viewWidth > 100 else { return }
        if x > scrollX + viewWidth - 40 || x < scrollX { position.scrollTo(x: max(0, x - 60)) }
    }

    // MARK: Drawing

    private func lanes(_ rows: [LaneRow], width: CGFloat, height: CGFloat) -> some View {
        let project = store.project
        let selection = store.selection
        let pick = store.captionPick
        let drag = self.drag
        let pps = self.pps
        let _ = media.revision
        return Canvas { ctx, size in
            MainActor.assumeIsolated {
                var y: CGFloat = 0
                for row in rows {
                    let lane = CGRect(x: 0, y: y, width: size.width, height: row.height)
                    ctx.fill(Path(lane), with: .color(row.track == nil ? Ed.well : Ed.lane))
                    ctx.fill(Path(CGRect(x: 0, y: lane.maxY - 1, width: size.width, height: 1)), with: .color(Ed.line))
                    if let track = row.track, let project {
                        let r = lane.insetBy(dx: 0, dy: 3)
                        if row.kind == .caption, let caps = track.captions {
                            drawCaptions(&ctx, caps, in: r, pps: pps, picked: pick?.trackID == track.id ? pick?.chunk : nil)
                        } else {
                            for clip in track.clips {
                                var c = clip
                                var ghost = false
                                if let d = drag {
                                    switch d.kind {
                                    case .move(let m) where m.id == clip.id || (m.link != nil && m.link == clip.link):
                                        c.start = MediaTime(seconds: max(0, clip.start.seconds + Double(d.translation.width / pps)))
                                        ghost = true
                                    case .trim(let m, let edge) where m.id == clip.id:
                                        let dt = MediaTime(seconds: Double(d.translation.width / pps))
                                        if edge == "start" { c.start += dt; c.sourceIn += dt } else { c.sourceOut += dt }
                                        ghost = true
                                    default: break
                                    }
                                }
                                let rect = CGRect(x: Self.originX + c.start.seconds * pps, y: r.minY, width: max(2, c.duration.seconds * pps), height: r.height)
                                drawClip(&ctx, c, row: row, rect: rect, project: project, selected: selection.contains(clip.id) || ghost)
                                if ghost {
                                    ctx.stroke(Path(roundedRect: rect, cornerRadius: Ed.Radius.s), with: .color(Ed.gold),
                                               style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                }
                            }
                        }
                        if track.hidden || track.muted {
                            ctx.fill(Path(lane), with: .color(Color.black.opacity(0.45)))
                        }
                    }
                    y += row.height
                }
            }
        }
        .frame(width: width, height: height)
    }

    private func drawClip(_ ctx: inout GraphicsContext, _ clip: Clip, row: LaneRow, rect: CGRect, project: Project, selected: Bool) {
        let asset = project.asset(clip.assetID)
        let shape = Path(roundedRect: rect, cornerRadius: Ed.Radius.s)
        let isAudio = row.kind == .audio
        let type = ClipPalette.kind(clip, track: row.track)
        ctx.fill(shape, with: .color(ClipPalette.fill(type)))
        ctx.drawLayer { l in
            l.clip(to: shape)
            if let asset {
                if isAudio {
                    drawWave(&l, clip, asset: asset, rect: rect.insetBy(dx: 0, dy: 2).offsetBy(dx: 0, dy: 5),
                             color: row.role == .voice ? Ed.audioWave : Ed.musicWave)
                } else if let v = asset.video {
                    let top = rect.minY + 13
                    let h = rect.maxY - top
                    let w = max(8, h * CGFloat(v.width) / CGFloat(max(v.height, 1)))
                    var x = rect.minX
                    while x < rect.maxX {
                        let t = clip.sourceIn.seconds + Double((x - rect.minX) / CGFloat(store.pxPerSec))
                        if let img = media.picture(asset, at: t) {
                            l.draw(Image(decorative: img, scale: 1), in: CGRect(x: x, y: top, width: w, height: h))
                        }
                        x += w
                    }
                }
            }
            // Label strip
            let strip = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: isAudio ? 12 : 13)
            l.fill(Path(strip), with: .color(Color.black.opacity(isAudio ? 0.0 : 0.45)))
            if rect.width > (isAudio ? 96 : 74) {
                let name = clip.title.map { "T  " + $0.text.replacingOccurrences(of: "\n", with: " ") }
                    ?? ((asset?.origin != nil ? "✦ " : "") + (asset?.name ?? clip.assetID))
                l.draw(Text(verbatim: name).font(Ed.ui(Ed.TypeSize.micro, .medium)).foregroundColor(Ed.text.opacity(0.9)),
                       at: CGPoint(x: rect.minX + 4, y: rect.minY + 1), anchor: .topLeading)
            }
            if clip.transform != nil || clip.keyframes != nil, !isAudio, rect.width > 60 {
                l.draw(Text(verbatim: clip.keyframes != nil ? "◆" : "⌗").font(Ed.ui(Ed.TypeSize.tiny)).foregroundColor(Ed.gold.opacity(0.9)),
                       at: CGPoint(x: rect.maxX - 4, y: rect.minY + 1), anchor: .topTrailing)
            }
        }
        ctx.stroke(shape, with: .color(selected ? Ed.gold : Color.black.opacity(0.55)), lineWidth: selected ? 1.5 : 1)
        if !isAudio {
            ctx.fill(Path(CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height)), with: .color(ClipPalette.edge(type).opacity(0.8)))
        }
    }

    private func drawWave(_ ctx: inout GraphicsContext, _ clip: Clip, asset: MediaAsset, rect: CGRect, color: Color) {
        guard let peaks = media.peaks(asset.path), !peaks.isEmpty else { return }
        let pps = CGFloat(store.pxPerSec)
        let mid = rect.midY, half = rect.height / 2 - 2
        var path = Path()
        var x = rect.minX
        while x < rect.maxX {
            let t0 = clip.sourceIn.seconds + Double((x - rect.minX) / pps)
            let t1 = t0 + Double(1 / pps)
            let a = max(0, Int(t0 * 100)), b = min(peaks.count, max(a + 1, Int(t1 * 100)))
            var p: Float = 0
            if a < b { for i in a..<b { p = max(p, peaks[i]) } }
            // A gentle curve so quiet speech stays visible.
            let h = CGFloat(sqrt(min(p * 1.4, 1))) * half
            path.addRect(CGRect(x: x, y: mid - h, width: 1, height: max(0.5, 2 * h)))
            x += 1
        }
        ctx.fill(path, with: .color(color.opacity(0.85)))
    }

    private func drawCaptions(_ ctx: inout GraphicsContext, _ caps: RegistaCore.Captions, in r: CGRect, pps: CGFloat, picked: Int? = nil) {
        for (k, ch) in caps.chunks.enumerated() {
            guard let first = ch.words.first else { continue }
            let rect = CGRect(x: Self.originX + first.start.seconds * pps, y: r.minY,
                              width: max(2, (ch.end - first.start).seconds * pps - 1), height: r.height)
            let shape = Path(roundedRect: rect, cornerRadius: Ed.Radius.xs)
            ctx.fill(shape, with: .color(k % 2 == 0 ? Ed.captionClip : Ed.captionClip.opacity(0.7)))
            if ch.words.contains(where: \.keyword) {
                ctx.fill(Path(CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2)), with: .color(Ed.keyword.opacity(0.8)))
            }
            if k == picked { ctx.stroke(shape, with: .color(Ed.gold), lineWidth: 1.5) }
            // The whole chunk when it fits, else its first word, else nothing (the block alone).
            let words = ch.words.map(\.text)
            for candidate in [words.joined(separator: " "), words[0]] {
                let kw = candidate == words[0] ? first.keyword : false
                let text = ctx.resolve(Text(verbatim: candidate).font(Ed.ui(Ed.TypeSize.tiny, .semibold))
                    .foregroundColor(kw ? Ed.keyword : Ed.text.opacity(0.88)))
                if text.measure(in: CGSize(width: 1000, height: 20)).width + 6 <= rect.width {
                    ctx.draw(text, at: CGPoint(x: rect.minX + 3, y: rect.midY), anchor: .leading)
                    break
                }
            }
        }
    }

    // MARK: Interaction

    private func rowAt(_ y: CGFloat, _ rows: [LaneRow]) -> LaneRow? { Self.row(at: y, rows) }

    /// The lane under `y` (content coordinates: the ruler on top).
    static func row(at y: CGFloat, _ rows: [LaneRow]) -> LaneRow? {
        var top = rulerHeight
        for r in rows {
            if y >= top && y < top + r.height { return r }
            top += r.height
        }
        return nil
    }

    private func snap(_ t: Double) -> Double { max(0, (t * fps).rounded() / fps) }

    private func gesture(_ rows: [LaneRow]) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                if drag == nil { drag = begin(v.startLocation, rows) }
                drag?.translation = v.translation
                guard let d = drag else { return }
                switch d.kind {
                case .scrub: store.preview.seek(snap(Double((v.location.x - Self.originX) / pps)))
                default: break   // the Hand tool scrolls in handGesture
                }
            }
            .onEnded { v in
                if let d = drag { finish(d, at: v.location) }
                drag = nil
            }
    }

    /// The scroll view's own space: it does not move with the content.
    private static let viewport = "timelineViewport"

    /// The Hand tool (#56): the drag is measured in the scroll view's space, which does not scroll with the content, so
    /// the view follows the pointer one to one. (In the content's own space each scroll step also moves the pointer's
    /// local position: the view settled at half the drag.)
    private var handGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.viewport))
            .onChanged { v in
                guard store.tool == .hand else { return }
                if handStart == nil { handStart = scrollX }
                position.scrollTo(x: max(0, (handStart ?? 0) - v.translation.width))
            }
            .onEnded { _ in handStart = nil }
    }

    private func begin(_ p: CGPoint, _ rows: [LaneRow]) -> DragState {
        if store.tool == .hand { return DragState(kind: .hand, start: p) }
        if p.y < Self.rulerHeight { return DragState(kind: .scrub, start: p) }
        guard let row = rowAt(p.y, rows), let track = row.track else { return DragState(kind: .empty, start: p) }
        let t = Double((p.x - Self.originX) / pps)
        if store.tool == .text { return DragState(kind: row.kind == .caption ? .keyword : .empty, start: p) }
        if row.kind == .caption, store.tool == .select, let caps = track.captions,
           let k = caps.chunks.firstIndex(where: { ($0.words.first?.start.seconds ?? .infinity) <= t && t < $0.end.seconds }) {
            store.captionPick = CaptionPick(trackID: track.id, chunk: k)
            return DragState(kind: .caption, start: p)
        }
        guard let clip = track.clips.first(where: { $0.start.seconds <= t && t < $0.end.seconds }) else {
            return DragState(kind: .empty, start: p)
        }
        if store.tool == .razor { return DragState(kind: .razor(clip.id), start: p) }
        let shift = NSEvent.clickModifiers.contains(.shift)
        if shift { if store.selection.contains(clip.id) { store.selection.remove(clip.id) } else { store.selection.insert(clip.id) } }
        else if !store.selection.contains(clip.id) { store.selection = [clip.id] }
        let x0 = Self.originX + clip.start.seconds * pps, x1 = Self.originX + clip.end.seconds * pps
        if p.x - x0 < 6, x1 - x0 > 18 { return DragState(kind: .trim(clip, "start"), start: p) }
        if x1 - p.x < 6, x1 - x0 > 18 { return DragState(kind: .trim(clip, "end"), start: p) }
        return DragState(kind: .move(clip), start: p)
    }

    private func finish(_ d: DragState, at p: CGPoint) {
        let moved = abs(d.translation.width) > 2
        let dt = Double(d.translation.width / pps)
        let at = snap(Double((p.x - Self.originX) / pps))
        switch d.kind {
        case .empty:
            store.selection = []
            store.captionPick = nil
            store.wordSelection = nil
            if !moved { store.preview.seek(at) }
        case .scrub: store.preview.seek(at)
        case .hand: break
        case .razor(let id):
            if !moved { store.run("timeline.cut", ["at": .number(at), "clipId": .string(id)]) }
        case .move(let clip):
            if moved { store.run("timeline.move", ["clipId": .string(clip.id), "start": .number(snap(clip.start.seconds + dt))]) }
        case .trim(let clip, let edge):
            if moved {
                let to = snap((edge == "start" ? clip.start.seconds : clip.end.seconds) + dt)
                store.run("timeline.trim", ["clipId": .string(clip.id), "edge": .string(edge), "to": .number(to)])
            }
        case .keyword:
            toggleKeyword(at: at)
        case .caption:
            if !moved { store.preview.seek(at) }
        }
    }

    /// The context menu of the clip under `point` (the lanes' coordinates): selects it first, as Finder does.
    private func clipMenu(at point: CGPoint, rows: [LaneRow]) -> NSMenu? {
        guard let project = store.project, point.y >= Self.rulerHeight, let row = rowAt(point.y, rows), let track = row.track else { return nil }
        let t = Double((point.x - Self.originX) / pps)
        guard let clip = track.clips.first(where: { $0.start.seconds <= t && t < $0.end.seconds }) else { return nil }
        if !store.selection.contains(clip.id) { store.selection = [clip.id] }
        let at = max(0, (t * fps).rounded() / fps)
        return ClipMenu.make(clip: clip, track: track, project: project, store: store, at: at)
    }

    private func toggleKeyword(at t: Double) {
        guard let caps = store.project?.tracks.first(where: { $0.kind == .caption && $0.captions != nil })?.captions,
              let ch = caps.chunks.first(where: { ($0.words.first?.start.seconds ?? .infinity) <= t && t < $0.end.seconds }) else { return }
        let word = ch.words.last { $0.start.seconds <= t } ?? ch.words[0]
        store.run("captions.setKeywords", word.keyword ? ["remove": [.string(word.text)]] : ["add": [.string(word.text)]])
    }
}

// MARK: - Pieces

struct TimelineCorner: View {
    @EnvironmentObject private var playhead: Playhead
    var body: some View {
        HStack {
            Text(verbatim: timecode(frames: playhead.time)).font(Ed.mono(Ed.TypeSize.control, .medium)).foregroundStyle(Ed.gold)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(Ed.header)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
    }
}

struct TrackHeader: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var preview: PreviewController
    let row: LaneRow
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: row.label)
                .font(Ed.mono(Ed.TypeSize.caption, .bold))
                .foregroundStyle(row.track == nil ? Ed.text3 : Ed.text)
                .frame(width: 26, height: 18)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(row.track == nil ? Color.clear : Ed.raised))
                .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(row.track == nil ? Ed.line2 : .clear))
            // «Audio della ripresa» (#95) does not fit one line beside an audio lane's buttons: it takes two.
            Text(verbatim: loc(row.title)).font(Ed.ui(Ed.TypeSize.caption)).foregroundStyle(row.track == nil ? Ed.text3 : Ed.text2)
                .lineLimit(row.title == "track.footageSound" ? 2 : 1).minimumScaleFactor(row.title == "track.footageSound" ? 0.7 : 0.8)
            Spacer(minLength: Ed.Space.xxs)
            if let t = row.track {
                // The bin shows on hover (also: right click → Elimina pista).
                if hover { small("trash", "Elimina pista", false) { delete(t) } }
                small(t.locked ? "lock.fill" : "lock.open", "Blocca", t.locked) { store.setTrack(t.id, "locked", !t.locked) }
                if t.kind == .audio {
                    letter("M", "Muto", t.muted) { store.setTrack(t.id, "muted", !t.muted) }
                    letter("S", "Solo (solo in anteprima)", preview.solo.contains(t.id)) {
                        if preview.solo.contains(t.id) { preview.solo.remove(t.id) } else { preview.solo.insert(t.id) }
                    }
                } else {
                    small(t.hidden ? "eye.slash" : "eye", "Mostra / nascondi", t.hidden) { store.setTrack(t.id, "hidden", !t.hidden) }
                }
            } else if store.project != nil {
                small("plus", row.role == .music ? loc("Aggiungi musica…") : row.role == .sfx ? loc("Scegli un effetto sonoro") : "Crea la pista", false) { create() }
            }
        }
        .padding(.horizontal, Ed.Space.s)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) { Ed.line.frame(height: 1) }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            if let t = row.track {
                if t.kind == .audio {
                    Button(t.muted ? loc("Riattiva l'audio") : loc("Muto")) { store.setTrack(t.id, "muted", !t.muted) }
                    Button(preview.solo.contains(t.id) ? loc("Togli solo") : loc("Solo (solo in anteprima)")) {
                        if preview.solo.contains(t.id) { preview.solo.remove(t.id) } else { preview.solo.insert(t.id) }
                    }
                } else if t.kind != .caption {
                    Button(t.hidden ? loc("Mostra la pista") : loc("Nascondi la pista")) { store.setTrack(t.id, "hidden", !t.hidden) }
                }
                Button(t.locked ? loc("Sblocca la pista") : loc("Blocca la pista")) { store.setTrack(t.id, "locked", !t.locked) }
                Button(loc("Rinomina…")) { rename(t) }
                Divider()
                Button(loc("Elimina pista"), role: .destructive) { delete(t) }
            }
        }
    }

    /// Asks for a new name (track.set name).
    private func rename(_ t: Track) {
        let a = NSAlert()
        a.messageText = loc("Rinomina la pista")
        let field = NSTextField(string: t.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        a.accessoryView = field
        a.addButton(withTitle: loc("Rinomina"))
        a.addButton(withTitle: loc("Annulla"))
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != t.name else { return }
        store.run("track.set", ["trackId": .string(t.id), "name": .string(name)])
    }

    /// Removes the track (track.delete); one holding clips asks first.
    private func delete(_ t: Track) {
        if !t.clips.isEmpty {
            let a = NSAlert()
            a.messageText = Plural.singular(t.clips.count) ? String(format: Plural.one("Eliminare la pista %@ con 1 clip?", t.clips.count), row.label)
                : loc("Eliminare la pista %@ con %@ clip?", row.label, String(t.clips.count))
            a.informativeText = loc("Si può annullare con ⌘Z.")
            a.addButton(withTitle: loc("Elimina"))
            a.addButton(withTitle: loc("Annulla"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        store.run("track.delete", ["trackId": .string(t.id), "force": .bool(!t.clips.isEmpty)])
    }

    private func create() {
        // Musica and Effetti are made by their commands (E3 #55): the music through audio.addMusic (its role, fitted,
        // ducked), the effects from the browser through sfx.add.
        if row.role == .music { return Panels.addMusic(store) }
        if row.role == .sfx {
            store.nav.soundTab = .sfx
            return store.select(.audio)
        }
        switch row.kind {
        case .caption: store.run("captions.generate", ["style": "talking-head-v1"])
        case .overlay: store.run("track.add", ["kind": "overlay", "name": .string(row.label)])
        default:
            store.run("track.add", ["kind": .string(row.kind.rawValue), "name": .string(row.label)])
        }
    }

    private func small(_ symbol: String, _ help: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        IconButton(symbol: symbol, help: help, active: on, size: 19, action: action)
    }

    private func letter(_ s: String, _ help: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: s).font(Ed.mono(Ed.TypeSize.micro, .bold))
                .foregroundStyle(on ? Color.black.opacity(0.85) : Ed.text2)
                .frame(width: 17, height: 17)
                .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(on ? Ed.gold : Ed.raised))
        }
        .buttonStyle(.plain)
        .tip(help)
    }
}

struct Ruler: View {
    let pps: CGFloat
    let fps: Double
    let width: CGFloat

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Ed.header))
            let steps: [Double] = [0.5, 1, 2, 5, 10, 15, 30, 60, 120]
            let major = steps.first { $0 * Double(pps) >= 64 } ?? 120
            let minor = major / 5
            var k = 0
            while TimelinePanel.originX + CGFloat(Double(k) * minor) * pps < size.width {
                let t = Double(k) * minor
                let x = TimelinePanel.originX + CGFloat(t) * pps
                let isMajor = k % 5 == 0
                ctx.fill(Path(CGRect(x: x, y: size.height - (isMajor ? 9 : 4), width: 1, height: isMajor ? 9 : 4)),
                         with: .color(isMajor ? Ed.text3 : Ed.line2))
                if isMajor {
                    let s = Int(t.rounded(.down)), frac = t - Double(s)
                    let label = frac > 0 ? String(format: "%d:%02d.%d", s / 60, s % 60, Int(frac * 10)) : String(format: "%d:%02d", s / 60, s % 60)
                    ctx.draw(Text(verbatim: label).font(Ed.mono(Ed.TypeSize.micro)).foregroundColor(Ed.text3), at: CGPoint(x: x + 3, y: 4), anchor: .topLeading)
                }
                k += 1
            }
            ctx.fill(Path(CGRect(x: 0, y: size.height - 1, width: size.width, height: 1)), with: .color(Ed.line))
        }
        .frame(width: width)
    }
}

struct PlayheadLine: View {
    @EnvironmentObject private var playhead: Playhead
    let pps: CGFloat
    let height: CGFloat
    let follow: (CGFloat) -> Void

    var body: some View {
        let x = TimelinePanel.originX + CGFloat(playhead.time) * pps
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Ed.gold).frame(width: 1, height: height).offset(x: x)
            Path { p in
                p.move(to: CGPoint(x: x - 5.5, y: 6))
                p.addLine(to: CGPoint(x: x + 6.5, y: 6))
                p.addLine(to: CGPoint(x: x + 6.5, y: 16))
                p.addLine(to: CGPoint(x: x + 0.5, y: 24))
                p.addLine(to: CGPoint(x: x - 5.5, y: 16))
                p.closeSubpath()
            }
            .fill(Ed.gold)
        }
        .allowsHitTesting(false)
        .onChange(of: playhead.time) { follow(x) }
    }
}

struct ZoomBar: View {
    @EnvironmentObject private var store: EditorStore

    var body: some View {
        // A narrow timeline (#49): the count gives way first, then the slider shortens; the zoom controls stay whole.
        ViewThatFits(in: .horizontal) {
            row(count: true, slider: 120)
            row(count: false, slider: 120)
            row(count: false, slider: 56)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Ed.header)
        .overlay(alignment: .top) { Ed.line.frame(height: 1) }
    }

    private func row(count: Bool, slider: CGFloat) -> some View {
        HStack(spacing: Ed.Space.s) {
            if count, let p = store.project {
                let clips = p.tracks.filter { $0.kind == .video }.flatMap(\.clips).count
                Text(verbatim: Plural.singular(clips) ? String(format: Plural.one("1 clip · %@", clips), shortTime(p.duration.seconds))
                     : loc("%@ clip · %@", String(clips), shortTime(p.duration.seconds))).font(Ed.mono(Ed.TypeSize.caption)).foregroundStyle(Ed.text3)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            IconButton(symbol: "minus.magnifyingglass", help: "Riduci", shortcut: "-", size: 20) { store.zoom(by: 1 / 1.5) }
            RSlider(value: Binding(get: { log(store.pxPerSec) }, set: { store.pxPerSec = exp($0); store.autoFit = false }),
                    range: log(2.0)...log(400.0), format: { String(Int(exp($0).rounded())) + " px/s" })
                .frame(width: slider)
            IconButton(symbol: "plus.magnifyingglass", help: "Ingrandisci", shortcut: "=", size: 20) { store.zoom(by: 1.5) }
            EdButton(title: "Adatta") { store.zoomToFit() }.tip("Adatta tutta la timeline", shortcut: "\\").fixedSize()
        }
    }
}
