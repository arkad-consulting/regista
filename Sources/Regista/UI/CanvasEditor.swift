import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI

// Direct manipulation on the Program monitor and the Semplice monitor (issue #21): click a caption, title, sticker or
// logo, drag it, resize it (corner handle, trackpad pinch, ⌥-scroll), rotate it (titles, stickers, logos). Snap guides
// and Instagram's interface zones show while dragging. Every gesture ends in ONE command (captions.place / clip.place):
// one undo step, visible in the Agent log, the same thing the agent can do. Everything drawn on the frame answers (#30):
// the full-frame picture (selected by a click before a drag can move it), layout boxes, callouts; a halo or a motion
// template is only selected.

/// What a caption drag moves.
enum CaptionScope: String { case all, one }

/// Arrow nudges and ⌥-scroll resizing waiting to be committed (a burst becomes one command).
struct CanvasPending: Equatable {
    var id: String
    var dx = 0.0
    var dy = 0.0
    var scale = 1.0
}

/// A selection or drag drawn without a mouse, for ui.screenshot (the offscreen copy of the window cannot be clicked).
struct CanvasDemo: Equatable {
    /// "caption" or a clip id.
    var select: String
    /// Drag translation, frame pixels.
    var drag: [Double]?
    var scale: Double?
    var scope: CaptionScope?
}

private struct CanvasDemoKey: EnvironmentKey { static let defaultValue: CanvasDemo? = nil }
extension EnvironmentValues {
    var canvasDemo: CanvasDemo? {
        get { self[CanvasDemoKey.self] }
        set { self[CanvasDemoKey.self] = newValue }
    }
}

/// The selection key of an element: captions are selected as a track (whichever chunk shows), clips by id.
func canvasKey(_ e: CanvasElement) -> String { e.kind == .caption ? "caption:\(e.trackID)" : e.id }

// MARK: - Commands

extension EditorStore {
    /// One gesture → one command. `dx`/`dy` in frame pixels, `scale` a factor on the element's current size,
    /// `rotation` degrees added.
    func commitCanvas(_ e: CanvasElement, dx: Double, dy: Double, scale: Double = 1, rotation: Double = 0) {
        let moved = abs(dx) >= 0.5 || abs(dy) >= 0.5, resized = abs(scale - 1) > 0.002, turned = abs(rotation) > 0.05
        guard moved || resized || turned else { return }
        func r(_ v: Double) -> JSONValue { .number((v * 10).rounded() / 10) }
        if e.kind == .caption, let ci = e.chunk {
            var o: [String: JSONValue] = ["trackId": .string(e.trackID)]
            if captionScope == .one {
                o["chunk"] = .number(Double(ci))
                if moved { o["dx"] = r(dx); o["dy"] = r(dy) }
            } else if moved {
                // The whole track: where this line now is (its anchor for the track's alignment, and its centre).
                let c = project?.tracks.first { $0.id == e.trackID }?.captions
                let align = c?.place?.align ?? .center
                let x: Double = switch align {
                case .left: e.box[0] + dx
                case .center: e.center[0] + dx
                case .right: e.box[0] + e.box[2] + dx
                }
                o["x"] = r(x)
                o["y"] = r(e.center[1] + dy)
            }
            if resized { o["scale"] = .number((min(max(e.scale * scale, 0.3), 4) * 1000).rounded() / 1000) }
            run("captions.place", .object(o))
        } else if let cid = e.clipID {
            var o: [String: JSONValue] = ["clipId": .string(cid)]
            if moved { o["dx"] = r(dx); o["dy"] = r(dy) }
            if resized { o["scale"] = .number((min(max(e.scale * scale, 0.05), 20) * 1000).rounded() / 1000) }
            if turned {
                var a = (e.rotation + rotation).truncatingRemainder(dividingBy: 360)
                if a > 180 { a -= 360 } else if a <= -180 { a += 360 }
                o["rotation"] = r(a)
            }
            run("clip.place", .object(o))
        }
    }

    /// Back to automatic (captions) or to where the clip was before it was first moved.
    func resetCanvas(_ e: CanvasElement) {
        if e.kind == .caption, let ci = e.chunk {
            var o: [String: JSONValue] = ["trackId": .string(e.trackID), "reset": true]
            if captionScope == .one { o["chunk"] = .number(Double(ci)) }
            run("captions.place", .object(o))
        } else if let cid = e.clipID {
            run("clip.place", ["clipId": .string(cid), "reset": true])
        }
    }

    /// Arrow keys (⇧ = 10 px) and Esc while something is selected on the preview. Returns true when handled.
    func handleCanvasKey(_ code: UInt16, shift: Bool) -> Bool {
        guard canvasSelection != nil else { return false }
        if code == 53 { canvasSelection = nil; return true }   // esc
        guard let e = canvasElement, canvasKey(e) == canvasSelection, e.movable, !preview.isPlaying else { return false }
        let step = shift ? 10.0 : 1.0
        let (dx, dy): (Double, Double)
        switch code {
        case 123: (dx, dy) = (-step, 0)
        case 124: (dx, dy) = (step, 0)
        case 125: (dx, dy) = (0, step)
        case 126: (dx, dy) = (0, -step)
        default: return false
        }
        var p = canvasPending ?? CanvasPending(id: canvasKey(e))
        p.dx += dx
        p.dy += dy
        canvasPending = p
        scheduleCanvasCommit()
        return true
    }

    /// ⌥-scroll over the preview resizes the selection.
    func canvasScroll(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.option), canvasHover, let e = canvasElement, canvasKey(e) == canvasSelection, e.movable else { return false }
        let d = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
        var p = canvasPending ?? CanvasPending(id: canvasKey(e))
        p.scale = min(max(p.scale * exp(Double(d) * 0.004), 0.2), 5)
        canvasPending = p
        scheduleCanvasCommit()
        return true
    }

    private func scheduleCanvasCommit() {
        canvasCommit?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let p = self.canvasPending, let e = self.canvasElement, canvasKey(e) == p.id else {
                    self?.canvasPending = nil
                    return
                }
                self.commitCanvas(e, dx: p.dx, dy: p.dy, scale: p.scale)
                // Keep the nudged picture until the preview shows the committed edit.
                let version = self.projectVersion
                self.afterCommit(since: version) { self.canvasPending = nil }
            }
        }
        canvasCommit = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Calls back once the project changed after `version` and the preview plays it (or after 3 s).
    func afterCommit(since version: Int, _ done: @escaping () -> Void) {
        var fired = false
        func fire() { if !fired { fired = true; done() } }
        func poll(_ n: Int) {
            if projectVersion != version { preview.whenCurrent { fire() }; return }
            guard n < 60 else { return fire() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll(n + 1) } }
        }
        poll(0)
    }

    /// The ⌥-scroll monitor (installed once).
    static var scrollMonitor: Any?
    func installCanvasScroll() {
        guard Self.scrollMonitor == nil else { return }
        Self.scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, MainActor.assumeIsolated({ self.canvasScroll(event) }) else { return event }
            return nil
        }
    }
}

// MARK: - Model

/// The grabbable elements at the playhead (cached per project version and frame) and the pictures a drag moves.
@MainActor
final class CanvasModel: ObservableObject {
    struct Sprite { var key: String; var image: CGImage; var box: [Double] }
    struct Clean { var key: String; var image: CGImage }

    @Published private(set) var elements: [CanvasElement] = []
    @Published var hovered: String?
    @Published private(set) var sprite: Sprite?
    @Published private(set) var clean: Clean?
    private var cacheKey: String?
    private var spriteKey: String?
    private let renderer = AVRenderer()
    nonisolated private static let queue = DispatchQueue(label: "regista.canvas.sprites", qos: .userInitiated) // l10n-ignore

    func refresh(_ store: EditorStore, time: Double) {
        guard let p = store.project else { elements = []; cacheKey = nil; return }
        let rate = p.settings.frameRate
        let t = MediaTime(seconds: time).snapped(to: rate)
        let key = "\(store.projectVersion)@\(t.ticks)" // l10n-ignore
        guard key != cacheKey else { return }
        cacheKey = key
        elements = CanvasLayout.elements(p, at: t, renderer: renderer)
        if let sel = store.canvasSelection {
            store.canvasElement = elements.last { canvasKey($0) == sel }
        }
    }

    /// Renders the element alone and the frame without it, in the background, for the drag.
    func prepare(_ store: EditorStore, _ e: CanvasElement, time: Double) {
        guard let project = store.project else { return }
        let key = "\(store.projectVersion)@\(Int((time * 1000).rounded()))#\(e.id)" // l10n-ignore
        guard key != spriteKey else { return }
        spriteKey = key
        let t = MediaTime(seconds: time).snapped(to: project.settings.frameRate)
        Self.queue.async {
            let s = ElementSprites.sprite(project, element: e, at: t)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if let s, let self, self.spriteKey == key { self.sprite = Sprite(key: key, image: s.image, box: s.box) } }
            }
            let c = ElementSprites.frameWithout(project, element: e, at: t)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if let c, let self, self.spriteKey == key { self.clean = Clean(key: key, image: c) } }
            }
        }
    }

    func ready(_ e: CanvasElement) -> Bool { sprite?.key.hasSuffix("#\(e.id)") == true }
}

/// A gesture in progress on the selected element, frame pixels / factors.
struct CanvasGesture: Equatable {
    var key: String
    var dx = 0.0
    var dy = 0.0
    var scale = 1.0
    var rotation = 0.0
    var guides: [Snapper.Guide] = []
    /// Waiting for the preview to show the committed command (the picture stays where it was dropped).
    var committed = false
}

// MARK: - Overlay

/// Sits exactly over the picture of a monitor (`size` = the picture's size in points).
struct CanvasOverlay: View {
    @EnvironmentObject private var store: EditorStore
    @EnvironmentObject private var playhead: Playhead
    @Environment(\.canvasDemo) private var demo
    @StateObject private var model = CanvasModel()
    @State private var gesture: CanvasGesture?
    /// Where a mouse-down started: the element under it, if any (`select`: a full-frame picture not selected yet, which
    /// a click selects and a drag leaves where it is).
    @State private var press: (key: String?, start: CGPoint, dragging: Bool, select: String?)?
    @State private var barScale = 1.0
    /// The bar's size slider is being dragged: the bar stays (a pointer gesture on the picture hides it).
    @State private var sliding = false
    let size: CGSize

    private var frameSize: (Int, Int) { (store.project?.settings.width ?? 1080, store.project?.settings.height ?? 1920) }
    private var mapping: PreviewMapping {
        PreviewMapping(viewWidth: size.width, viewHeight: size.height, frameWidth: frameSize.0, frameHeight: frameSize.1)
    }
    /// Instagram's zones apply to a 9:16 frame only (#52).
    private var vertical: Bool { MonitorFit.showsInstagramZones(width: frameSize.0, height: frameSize.1) }
    private var selected: CanvasElement? {
        guard let sel = store.canvasSelection else { return nil }
        return model.elements.last { canvasKey($0) == sel }
    }
    /// The live change: the mouse gesture, else pending nudges / ⌥-scroll.
    private var live: CanvasGesture? {
        if let gesture { return gesture }
        if let p = store.canvasPending { return CanvasGesture(key: p.id, dx: p.dx, dy: p.dy, scale: p.scale) }
        return nil
    }

    var body: some View {
        let m = mapping
        ZStack(alignment: .topLeading) {
            // The picture's own gestures sit on a layer under the handles and the bar, never on the stack: as a
            // parent's gesture they took the clicks meant for the bar (the element under it was selected and moved, #28).
            Color.clear.contentShape(Rectangle())
                .gesture(mainDrag(m))
                .simultaneousGesture(pinch)
            if let e = selected, let g = live, g.key == canvasKey(e) { dragLayer(e, g, m) }
            if let h = model.hovered, h != store.canvasSelection, let e = model.elements.last(where: { canvasKey($0) == h }), !store.preview.isPlaying,
               !(e.needsSelection && coversFrame(e)) {
                outline(e, CanvasGesture(key: h), m, color: Color.white.opacity(0.7), dash: [3, 3])
            }
            if let e = selected, !store.preview.isPlaying || gesture != nil {
                let g = live.flatMap { $0.key == canvasKey(e) ? $0 : nil } ?? CanvasGesture(key: canvasKey(e))
                selection(e, g, m)
                if e.movable, gesture == nil || gesture?.committed == true || sliding { bar(e, m) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(.named("canvas"))
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                store.canvasHover = true
                guard !store.preview.isPlaying, gesture == nil else { return }
                // Over the bar the pointer is on the bar, not on what lies under it.
                if let e = selected, barFrame(e, m).rect.insetBy(dx: -4, dy: -4).contains(p) { model.hovered = nil; return }
                model.refresh(store, time: playhead.time)
                let f = m.toFrame((p.x, p.y))
                model.hovered = CanvasLayout.hit(model.elements, at: f, margin: 6 / m.scale).map(canvasKey)
            case .ended:
                store.canvasHover = false
                model.hovered = nil
            }
        }
        .onDisappear { if gesture != nil { store.canvasDragging = false } }
        .onAppear {
            store.installCanvasScroll()
            model.refresh(store, time: playhead.time)
            if let demo { applyDemo(demo) }
        }
        .onChange(of: store.projectVersion) { model.refresh(store, time: playhead.time); prepareSelection() }
        .onChange(of: playhead.time) { if store.canvasSelection != nil, !store.preview.isPlaying { model.refresh(store, time: playhead.time); prepareSelection() } }
        .onChange(of: store.canvasSelection) { model.refresh(store, time: playhead.time); prepareSelection(); barScale = selected?.scale ?? 1 }
        .onChange(of: selected?.scale) { barScale = selected?.scale ?? 1 }
        .onChange(of: gesture == nil || gesture?.committed == true) { store.canvasDragging = !(gesture == nil || gesture?.committed == true) }
    }

    private func prepareSelection() {
        if let e = selected { store.canvasElement = e; model.prepare(store, e, time: playhead.time) }
    }

    // MARK: Geometry

    /// The element's centre, size and rotation after a gesture, frame pixels.
    private func moved(_ e: CanvasElement, _ g: CanvasGesture) -> (c: [Double], s: [Double], r: Double, box: [Double]) {
        let c = [e.center[0] + g.dx, e.center[1] + g.dy], s = [e.size[0] * g.scale, e.size[1] * g.scale], r = e.rotation + g.rotation
        let a = r * .pi / 180
        let bw = abs(cos(a)) * s[0] + abs(sin(a)) * s[1], bh = abs(sin(a)) * s[0] + abs(cos(a)) * s[1]
        return (c, s, r, [c[0] - bw / 2, c[1] - bh / 2, bw, bh])
    }

    /// The element covers the whole frame (a picture at its full size).
    private func coversFrame(_ e: CanvasElement) -> Bool {
        let W = Double(frameSize.0), H = Double(frameSize.1)
        return e.box[0] <= 0.5 && e.box[1] <= 0.5 && e.box[0] + e.box[2] >= W - 0.5 && e.box[1] + e.box[3] >= H - 0.5
    }

    private func inInstagramZone(_ box: [Double]) -> Bool {
        vertical && !RegistaCore.SafeZones.instagramHits(box, width: frameSize.0, height: frameSize.1).isEmpty
    }

    // MARK: Layers

    /// While dragging: the frame without the element over its old place, the element's picture where it goes,
    /// the Instagram zones in red and the snap guides.
    @ViewBuilder
    private func dragLayer(_ e: CanvasElement, _ g: CanvasGesture, _ m: PreviewMapping) -> some View {
        let k = m.scale
        if let clean = model.clean, model.ready(e) {
            let b = m.toView(box: e.box.enumerated().map { $0.offset < 2 ? $0.element - 4 : $0.element + 8 })
            Image(decorative: clean.image, scale: 1).resizable().interpolation(.high)
                .frame(width: size.width, height: size.height)
                .mask(alignment: .topLeading) { Rectangle().frame(width: b[2], height: b[3]).offset(x: b[0], y: b[1]) }
                .allowsHitTesting(false)
        }
        if let s = model.sprite, model.ready(e) {
            // The sprite's centre relative to the element's, moved and scaled with it.
            let off = [s.box[0] + s.box[2] / 2 - e.center[0], s.box[1] + s.box[3] / 2 - e.center[1]]
            let c = m.toView((e.center[0] + g.dx + off[0] * g.scale, e.center[1] + g.dy + off[1] * g.scale))
            Image(decorative: s.image, scale: 1).resizable().interpolation(.high)
                .frame(width: s.box[2] * k * g.scale, height: s.box[3] * k * g.scale)
                .rotationEffect(.degrees(g.rotation))
                .position(x: c.x, y: c.y)
                .allowsHitTesting(false)
        }
        if vertical, !g.committed { instagramZones(m, hot: inInstagramZone(moved(e, g).box)) }
        ForEach(Array(g.guides.enumerated()), id: \.offset) { _, guide in
            let p = guide.position * k
            Path { path in
                if guide.vertical { path.move(to: CGPoint(x: p, y: 0)); path.addLine(to: CGPoint(x: p, y: size.height)) }
                else { path.move(to: CGPoint(x: 0, y: p)); path.addLine(to: CGPoint(x: size.width, y: p)) }
            }
            .stroke(guide.kind == .element ? Ed.keyword : Ed.gold, style: StrokeStyle(lineWidth: 1, dash: guide.kind == .third ? [4, 3] : []))
            .allowsHitTesting(false)
        }
    }

    private func instagramZones(_ m: PreviewMapping, hot: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(RegistaCore.SafeZones.instagramZones(width: frameSize.0, height: frameSize.1), id: \.name) { z in
                let r = m.toView(box: z.rect)
                Rectangle().fill(Ed.danger.opacity(hot ? 0.34 : 0.2))
                    .overlay(Rectangle().strokeBorder(Ed.danger.opacity(0.7), lineWidth: 1))
                    .frame(width: r[2], height: r[3]).offset(x: r[0], y: r[1])
                Text(verbatim: loc(zoneLabel(z.name)).uppercased(with: Locale.current)).font(Ed.mono(Ed.TypeSize.tiny, .semibold)).foregroundStyle(Color.white.opacity(0.85))
                    .rotationEffect(.degrees(z.name == "right" ? -90 : 0))
                    .fixedSize()
                    .position(x: r[0] + r[2] / 2, y: r[1] + r[3] / 2)
            }
        }
        .allowsHitTesting(false)
    }

    private func zoneLabel(_ name: String) -> String {
        switch name {
        case "top": "Barra account"
        case "bottom": "Pulsanti e didascalia"
        default: "Azioni"
        }
    }

    private func outline(_ e: CanvasElement, _ g: CanvasGesture, _ m: PreviewMapping, color: Color, dash: [CGFloat] = []) -> some View {
        let (c, s, r, _) = moved(e, g)
        let v = m.toView((c[0], c[1]))
        var rect = CGRect(x: v.x - s[0] * m.scale / 2 - 4, y: v.y - s[1] * m.scale / 2 - 4, width: s[0] * m.scale + 8, height: s[1] * m.scale + 8)
        // Kept just inside the picture: around an element as large as the frame it would be drawn outside it (#30).
        if r == 0 {
            let inside = rect.intersection(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
            if !inside.isNull, inside.width > 2, inside.height > 2 { rect = inside }
        }
        return Rectangle().strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: dash))
            .frame(width: rect.width, height: rect.height)
            .rotationEffect(.degrees(r))
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
    }

    /// The selection box with its corner handles (resize) and, for titles/stickers/logos, the rotation handle.
    @ViewBuilder
    private func selection(_ e: CanvasElement, _ g: CanvasGesture, _ m: PreviewMapping) -> some View {
        let (c, s, r, box) = moved(e, g)
        let hot = gesture != nil && !g.committed && inInstagramZone(box)
        let color = hot ? Ed.danger : Ed.gold
        outline(e, g, m, color: color)
        if e.movable { handles(e, g, m, c: c, s: s, r: r, box: box, hot: hot, color: color) }
    }

    /// The corner handles, the rotation knob and the Instagram warning of a selection that can move.
    @ViewBuilder
    private func handles(_ e: CanvasElement, _ g: CanvasGesture, _ m: PreviewMapping, c: [Double], s: [Double], r: Double, box: [Double], hot: Bool,
                         color: Color) -> some View {
        let v = m.toView((c[0], c[1]))
        let hw = s[0] * m.scale / 2 + 4, hh = s[1] * m.scale / 2 + 4
        let a = r * .pi / 180
        // Handles stay inside the picture: the corners of an element as large as the frame (or larger) are on its
        // edge or outside it, where nothing can be grabbed (#28). The resize follows the pointer's distance from
        // the centre, so a handle works from wherever it is drawn.
        let rotated = { (x: Double, y: Double) -> CGPoint in
            CGPoint(x: min(max(v.x + x * cos(a) - y * sin(a), 7), max(size.width - 7, 7)), y: min(max(v.y + x * sin(a) + y * cos(a), 7), max(size.height - 7, 7)))
        }
        ForEach(0..<4, id: \.self) { i in
            let p = rotated(i % 2 == 0 ? -hw : hw, i < 2 ? -hh : hh)
            Circle().fill(Color.white).frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(color, lineWidth: 1.5))
                .shadow(color: .black.opacity(0.4), radius: 1.5)
                .contentShape(Rectangle().size(width: 18, height: 18).offset(x: -4.5, y: -4.5))
                .tip("Trascina per ridimensionare")
                .position(p)
                .gesture(resizeDrag(e, m))
        }
        if e.rotatable {
            let top = rotated(0, -hh), knob = rotated(0, -hh - 22)
            Path { $0.move(to: top); $0.addLine(to: knob) }.stroke(color, lineWidth: 1).allowsHitTesting(false)
            Circle().fill(color).frame(width: 11, height: 11)
                .overlay(Image(systemName: "arrow.clockwise").font(Ed.icon(Ed.TypeSize.tiny, .bold)).foregroundStyle(Color.black.opacity(0.75)))
                .shadow(color: .black.opacity(0.4), radius: 1.5)
                .contentShape(Rectangle().size(width: 19, height: 19).offset(x: -4, y: -4))
                .tip("Trascina per ruotare")
                .position(knob)
                .gesture(rotateDrag(e, m))
        }
        if hot {
            Text(verbatim: loc("Zona interfaccia Instagram")).font(Ed.ui(Ed.TypeSize.micro, .semibold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, Ed.Space.xxs)
                .background(Capsule().fill(Ed.danger))
                .fixedSize()
                .position(x: v.x, y: max(m.toView((0, box[1])).y - 12, 8))
                .allowsHitTesting(false)
        }
    }

    /// Where the floating bar goes: under the selection, over it when there is no room below.
    private func barFrame(_ e: CanvasElement, _ m: PreviewMapping) -> (rect: CGRect, compact: Bool) {
        Self.barFrame(box: m.toView(box: e.box), kind: e.kind, view: size)
    }

    /// The bar for a selection whose box is `b` (view points) on a picture of `view` points: under it, over it when
    /// there is no room below, inside the picture near the bottom of the selection when there is room neither below
    /// nor above (a full-frame picture), clear of the corner handles.
    static func barFrame(box b: [Double], kind: CanvasElement.Kind, view size: CGSize) -> (rect: CGRect, compact: Bool) {
        // A narrow monitor (the Pro workspace's 9:16 column) stacks the bar on two rows.
        let compact = kind == .caption && size.width < 380
        let width = min(kind == .caption ? (compact ? 214.0 : 370.0) : 220.0, size.width - 8)
        let height = compact ? 62.0 : 34.0
        let y: Double
        if b[1] + b[3] + 14 + height < size.height { y = b[1] + b[3] + 14 + height / 2 }
        else if b[1] - 14 - height >= 0 { y = b[1] - 14 - height / 2 }
        else { y = max(min(b[1] + b[3], size.height) - 20 - height / 2, height / 2) }
        let x = min(max(b[0] + b[2] / 2, width / 2 + 4), size.width - width / 2 - 4)
        return (CGRect(x: x - width / 2, y: y - height / 2, width: width, height: height), compact)
    }

    /// The floating bar under (or over) the selection.
    private func bar(_ e: CanvasElement, _ m: PreviewMapping) -> some View {
        let (rect, compact) = barFrame(e, m)
        let width = rect.width, height = rect.height, x = rect.midX, y = rect.midY
        return CanvasBar(element: e, compact: compact, scale: $barScale, onScale: { live in
            sliding = live
            if live { gesture = CanvasGesture(key: canvasKey(e), scale: barScale / max(e.scale, 0.01)); model.prepare(store, e, time: playhead.time) }
            else { commit(e, CanvasGesture(key: canvasKey(e), scale: barScale / max(e.scale, 0.01))) }
        }, onReset: { store.resetCanvas(e) })
        .frame(width: width, height: height)
        .position(x: x, y: y)
    }

    // MARK: Gestures

    private func hit(_ p: CGPoint, _ m: PreviewMapping) -> CanvasElement? {
        CanvasLayout.hit(model.elements, at: m.toFrame((p.x, p.y)), margin: 6 / m.scale)
    }

    /// Click: select (or play/pause on empty picture); double-click: reset; drag: move with snapping.
    private func mainDrag(_ m: PreviewMapping) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                if press == nil {
                    model.refresh(store, time: playhead.time)
                    let e = hit(v.startLocation, m)
                    if let e, e.needsSelection, store.canvasSelection != canvasKey(e) {
                        // A full-frame picture is never moved by accident: the click selects it, a drag leaves it alone.
                        press = (nil, v.startLocation, false, canvasKey(e))
                    } else {
                        press = (e.map(canvasKey), v.startLocation, false, nil)
                        if let e { select(e) }
                    }
                }
                guard var pr = press, let key = pr.key, let e = model.elements.last(where: { canvasKey($0) == key }), e.movable else { return }
                let t = v.translation
                if !pr.dragging, hypot(t.width, t.height) < 3 { return }
                pr.dragging = true
                press = pr
                var g = CanvasGesture(key: key, dx: t.width / m.scale, dy: t.height / m.scale)
                // Snap the moved box to the frame's centre lines and thirds and to the other elements (⌘ = no snapping).
                if !NSEvent.clickModifiers.contains(.command) {
                    let others = model.elements.filter { canvasKey($0) != key }.map(\.box)
                    let guides = Snapper.targets(width: frameSize.0, height: frameSize.1, others: others)
                    let snapped = Snapper.snap(moved(e, g).box, to: guides, threshold: 6 / m.scale)
                    g.dx += snapped.dx
                    g.dy += snapped.dy
                    g.guides = snapped.guides
                }
                gesture = g
            }
            .onEnded { v in
                defer { press = nil }
                guard let pr = press else { return }
                if pr.dragging, let key = pr.key, let e = model.elements.last(where: { canvasKey($0) == key }), let g = gesture {
                    commit(e, g)
                    return
                }
                if let key = pr.select {
                    if hypot(v.translation.width, v.translation.height) < 3, let e = model.elements.last(where: { canvasKey($0) == key }) { select(e) }
                    return
                }
                // A click.
                let double = (NSApp.currentEvent?.clickCount ?? 1) >= 2
                if let key = pr.key, let e = model.elements.last(where: { canvasKey($0) == key }) {
                    if double, e.movable { store.resetCanvas(e) }
                } else if store.canvasSelection != nil {
                    store.canvasSelection = nil
                } else if store.project?.duration ?? .zero > .zero {
                    store.preview.togglePlay()
                }
            }
    }

    /// Selects an element (the playback stops, its pictures for a drag are prepared).
    private func select(_ e: CanvasElement) {
        if store.preview.isPlaying { store.preview.togglePlay() }
        store.canvasSelection = canvasKey(e)
        store.canvasElement = e
        model.prepare(store, e, time: playhead.time)
    }

    /// A corner handle: uniform resize around the centre.
    private func resizeDrag(_ e: CanvasElement, _ m: PreviewMapping) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let c = m.toView((e.center[0], e.center[1]))
                let d0 = hypot(v.startLocation.x - c.x, v.startLocation.y - c.y), d1 = hypot(v.location.x - c.x, v.location.y - c.y)
                guard d0 > 2 else { return }
                gesture = CanvasGesture(key: canvasKey(e), scale: max(d1 / d0, 0.05))
            }
            .onEnded { _ in if let g = gesture { commit(e, g) } }
    }

    /// The rotation knob: the angle of the pointer around the centre (snaps to every 45° within 3°).
    private func rotateDrag(_ e: CanvasElement, _ m: PreviewMapping) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("canvas"))
            .onChanged { v in
                let c = m.toView((e.center[0], e.center[1]))
                let a0 = atan2(v.startLocation.y - c.y, v.startLocation.x - c.x), a1 = atan2(v.location.y - c.y, v.location.x - c.x)
                var delta = (a1 - a0) * 180 / .pi
                let total = e.rotation + delta
                let nearest = (total / 45).rounded() * 45
                if abs(total - nearest) < 3 { delta = nearest - e.rotation }
                gesture = CanvasGesture(key: canvasKey(e), rotation: delta)
            }
            .onEnded { _ in if let g = gesture { commit(e, g) } }
    }

    /// Trackpad pinch on the selection.
    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                guard let e = selected, press?.dragging != true else { return }
                gesture = CanvasGesture(key: canvasKey(e), scale: max(v.magnification, 0.05))
                model.prepare(store, e, time: playhead.time)
            }
            .onEnded { _ in if let e = selected, let g = gesture { commit(e, g) } }
    }

    private func commit(_ e: CanvasElement, _ g: CanvasGesture) {
        var done = g
        done.committed = true
        done.guides = []
        gesture = done
        let version = store.projectVersion
        store.commitCanvas(e, dx: g.dx, dy: g.dy, scale: g.scale, rotation: g.rotation)
        let changed = abs(g.dx) >= 0.5 || abs(g.dy) >= 0.5 || abs(g.scale - 1) > 0.002 || abs(g.rotation) > 0.05
        if changed { store.afterCommit(since: version) { if gesture?.committed == true { gesture = nil } } } else { gesture = nil }
    }

    private func applyDemo(_ d: CanvasDemo) {
        if let s = d.scope { store.captionScope = s }
        guard let e = model.elements.last(where: { d.select == "caption" ? $0.kind == .caption : $0.clipID == d.select }) else { return }
        store.canvasSelection = canvasKey(e)
        model.prepare(store, e, time: playhead.time)
        guard d.drag != nil || d.scale != nil else { return }
        var g = CanvasGesture(key: canvasKey(e), dx: d.drag?.first ?? 0, dy: d.drag?.last ?? 0, scale: d.scale ?? 1)
        let others = model.elements.filter { canvasKey($0) != canvasKey(e) }.map(\.box)
        let snapped = Snapper.snap(moved(e, g).box, to: Snapper.targets(width: frameSize.0, height: frameSize.1, others: others), threshold: 6 / mapping.scale)
        g.dx += snapped.dx
        g.dy += snapped.dy
        g.guides = snapped.guides
        gesture = g
    }
}

/// "Tutti i sottotitoli / Solo questo", size, Ripristina.
struct CanvasBar: View {
    @EnvironmentObject private var store: EditorStore
    let element: CanvasElement
    var compact = false
    @Binding var scale: Double
    /// true while the slider moves (live preview), false on release (commit).
    let onScale: (Bool) -> Void
    let onReset: () -> Void

    var body: some View {
        Group {
            if compact {
                VStack(spacing: Ed.Space.xs) {
                    scope
                    HStack(spacing: Ed.Space.s) { sizeAndReset }
                }
            } else {
                HStack(spacing: Ed.Space.s) {
                    if element.kind == .caption { scope }
                    sizeAndReset
                }
            }
        }
        .padding(.horizontal, Ed.Space.s)
        .padding(.vertical, Ed.Space.xs)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l).fill(Ed.panel.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l).strokeBorder(Ed.line2))
        .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
    }

    private var scope: some View {
        RSegmented(items: [(CaptionScope.all, "Tutti i sottotitoli"), (.one, "Solo questo")],
                   selection: Binding(get: { store.captionScope }, set: { store.captionScope = $0 }), height: 24, fill: false,
                   tips: [.all: "Sposta e ridimensiona tutti i sottotitoli", .one: "Sposta e ridimensiona solo questa frase"])
    }

    @ViewBuilder private var sizeAndReset: some View {
        // Text reads its size as a letter; a picture, a sticker or a logo as a frame that grows.
        Image(systemName: element.kind == .caption || element.kind == .title ? "textformat.size" : "arrow.up.left.and.arrow.down.right")
            .font(Ed.icon(Ed.TypeSize.caption, .medium)).foregroundStyle(Ed.text3)
        RSlider(value: Binding(get: { scale }, set: { scale = $0; onScale(true) }),
                range: element.kind == .caption ? 0.3...3 : 0.1...4, step: 0.01,
                format: { String(format: "%.0f%%", $0 * 100) }, onCommit: { _ in onScale(false) })
            .frame(minWidth: 60)
            .tip("Dimensione (anche pizzico sul trackpad o ⌥ + rotella)")
        IconButton(symbol: "arrow.uturn.backward",
                   help: element.kind == .caption ? "Ripristina la posizione automatica (anche doppio clic)" : "Ripristina la posizione originale (anche doppio clic)",
                   action: onReset)
    }
}
