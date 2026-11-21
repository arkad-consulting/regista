import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI
import Testing
@testable import Regista

// The mouse path of the preview (#28): click, drag, the corner handles, the rotation knob and the floating bar of the
// Program picture, driven with real mouse events (MouseRig). #30: the same gestures on everything drawn on the frame —
// the full-frame camera, a full-frame insert, a callout, a layout box — and a full-frame picture never moved by accident.

private func scratchDefaults() -> UserDefaults { TestDefaults.make("tests") }

/// The kinds made grabbable by #30, as a CanvasRig puts them on the frame.
enum CanvasGrab: String, CaseIterable, CustomStringConvertible, Sendable {
    /// A synthetic camera take filling the frame.
    case camera
    /// An opaque picture filling the frame (overlay.add fit fill).
    case insert
    /// A box callout in the middle of the frame.
    case callout
    /// The camera in a picture-in-picture bubble (layout.speaker pip-bubble).
    case layoutBox
    var description: String { rawValue }
}

/// The Program picture with one overlay on the timeline (and, with `under`, a second one as wide as the frame lying
/// under the first and under its floating bar), or one element of a kind made grabbable by #30.
@MainActor
private final class CanvasRig {
    let store: EditorStore
    let rig: MouseRig
    let clipID: String
    let dir: URL
    /// The monitor: the picture with the 10 pt margin it has in the Program monitor.
    static let view = CGSize(width: 320, height: 540)
    static let margin = 10.0

    private static func setUp() throws -> (EditorStore, URL) {
        _ = NSApplication.shared
        let dir = TemporaryFolder.url.appendingPathComponent("regista-canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("REGISTA_ENGINE_SOCKET", dir.appendingPathComponent("e.sock").path, 1)
        return (EditorStore(defaults: scratchDefaults(), seedFolders: []), dir)
    }

    /// An opaque PNG of one colour.
    static func png(_ url: URL, width: Int, height: Int, red: Double, green: Double, blue: Double) throws {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try #require(NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])).write(to: url)
    }

    init(scale: Double, at centre: [Double] = [540, 960], under: Bool = false) async throws {
        (store, dir) = try Self.setUp()
        // A 1080×600 picture: fitted in the frame it is as wide as the frame.
        let png = dir.appendingPathComponent("card.png")
        try Self.png(png, width: 1080, height: 600, red: 0.2, green: 0.4, blue: 0.9)
        try await store.perform("project.new", ["name": "canvas"])
        if under {
            try await store.perform("overlay.add", ["path": .string(png.path), "start": 0, "duration": 3, "fit": "contain", "position": [540, 960]])
        }
        let r = try await store.perform("overlay.add", ["path": .string(png.path), "start": 0, "duration": 3, "fit": "contain", "scale": .number(scale),
                                                         "position": .array(centre.map { .number($0) })])
        let id = try #require(r.value(at: "clip.id")?.stringValue)
        clipID = id
        for _ in 0..<200 where store.project?.tracks.flatMap(\.clips).contains(where: { $0.id == id }) != true { try await Task.sleep(for: .milliseconds(50)) }
        rig = MouseRig(ProgramPicture().padding(Self.margin)
            .environmentObject(store).environmentObject(store.preview).environmentObject(store.preview.playhead), size: Self.view)
    }

    /// The synthetic camera take, written once per test run and imported by every rig after the first.
    private static var take: URL?

    /// Puts the camera take on V1, filling the frame; returns its clip.
    private static func camera(_ store: EditorStore) async throws -> String {
        let r: JSONValue
        if let take {
            r = try await store.perform("media.import", ["path": .string(take.path)])
        } else {
            let url = TemporaryFolder.url.appendingPathComponent("regista-canvas-take-\(UUID().uuidString)/take.mov")
            r = try await store.perform("media.synthesize", ["path": .string(url.path), "duration": 3])
            take = url
        }
        let asset = try #require(r.value(at: "asset.id")?.stringValue)
        let t = try await store.perform("track.add", ["kind": "video"])
        let track = try #require(t.value(at: "track.id")?.stringValue)
        let placed = try await store.perform("timeline.place", ["assetId": .string(asset), "trackId": .string(track)])
        return try #require(placed.value(at: "clip.id")?.stringValue)
    }

    init(_ grab: CanvasGrab) async throws {
        (store, dir) = try Self.setUp()
        try await store.perform("project.new", ["name": .string("canvas-\(grab)")])
        var id: String
        switch grab {
        case .camera:
            id = try await Self.camera(store)
        case .insert:
            let png = dir.appendingPathComponent("insert.png")
            try Self.png(png, width: 1080, height: 1920, red: 0.1, green: 0.6, blue: 0.3)
            let r = try await store.perform("overlay.add", ["path": .string(png.path), "start": 0, "duration": 3, "fit": "fill"])
            id = try #require(r.value(at: "clip.id")?.stringValue)
        case .callout:
            let r = try await store.perform("callout.add", ["kind": "box", "start": 0, "duration": 3, "rect": [240, 760, 600, 400], "drawOn": 0])
            id = try #require(r.value(at: "clip.id")?.stringValue)
        case .layoutBox:
            id = try await Self.camera(store)
            try await store.perform("layout.speaker", ["preset": "pip-bubble"])
        }
        for _ in 0..<200 where store.project?.tracks.flatMap(\.clips).contains(where: { $0.id == id }) != true { try await Task.sleep(for: .milliseconds(50)) }
        if grab == .layoutBox {
            // The bubble's clip (the layout may have cut the take at the range edges).
            for _ in 0..<100 where CanvasLayout.elements(store.project!, at: .zero, renderer: nil).contains(where: { $0.kind == .layoutBox }) != true {
                try await Task.sleep(for: .milliseconds(50))
            }
            id = try #require(CanvasLayout.elements(store.project!, at: .zero, renderer: nil).first { $0.kind == .layoutBox }?.clipID)
        }
        clipID = id
        rig = MouseRig(ProgramPicture().padding(Self.margin)
            .environmentObject(store).environmentObject(store.preview).environmentObject(store.preview.playhead), size: Self.view)
    }

    /// Runs a command (another element on the frame) and waits for the store to show it; returns the clip it added.
    @discardableResult
    func add(_ id: String, _ params: JSONValue) async throws -> String {
        let before = store.projectVersion
        let r = try await store.perform(id, params)
        let cid = try #require(r.value(at: "clip.id")?.stringValue)
        for _ in 0..<200 where store.project?.tracks.flatMap(\.clips).contains(where: { $0.id == cid }) != true { try await Task.sleep(for: .milliseconds(50)) }
        try await settle(since: before)
        return cid
    }

    func close() { rig.close() }

    var clip: Clip { store.project!.tracks.flatMap(\.clips).first { $0.id == clipID }! }
    func clip(_ id: String) -> Clip? { store.project!.tracks.flatMap(\.clips).first { $0.id == id } }
    var element: CanvasElement { element(clipID) }
    func element(_ id: String) -> CanvasElement {
        CanvasLayout.elements(store.project!, at: .zero, renderer: nil).first { $0.clipID == id }!
    }

    /// View points per frame pixel.
    var pointsPerPixel: Double { (viewPoint((1080, 0)).x - viewPoint((0, 0)).x) / 1080 }
    /// The picture in the hosting view.
    var picture: CGRect {
        let o = viewPoint((0, 0)), end = viewPoint((1080, 1920))
        return CGRect(x: o.x, y: o.y, width: end.x - o.x, height: end.y - o.y)
    }

    /// A frame point in the hosting view (top-left origin).
    func viewPoint(_ frame: (x: Double, y: Double)) -> CGPoint {
        let inner = CGSize(width: Self.view.width - 2 * Self.margin, height: Self.view.height - 2 * Self.margin)
        let fitted = MonitorFit.size(aspect: MonitorFit.aspect(store.project), in: inner)
        let m = PreviewMapping(viewWidth: fitted.width, viewHeight: fitted.height, frameWidth: 1080, frameHeight: 1920)
        let p = m.toView(frame)
        return CGPoint(x: Self.margin + (inner.width - fitted.width) / 2 + p.x, y: Self.margin + (inner.height - fitted.height) / 2 + p.y)
    }

    /// A point drawn around the selection, kept 7 pt inside the picture like the handles.
    private func inPicture(_ p: CGPoint) -> CGPoint {
        let o = viewPoint((0, 0)), end = viewPoint((1080, 1920))
        return CGPoint(x: min(max(p.x, o.x + 7), end.x - 7), y: min(max(p.y, o.y + 7), end.y - 7))
    }

    /// The bottom-right corner handle: 4 pt outside the element's corner.
    var handle: CGPoint {
        let e = element
        let p = viewPoint((e.center[0] + e.size[0] / 2, e.center[1] + e.size[1] / 2))
        return inPicture(CGPoint(x: p.x + 4, y: p.y + 4))
    }

    /// The rotation knob: 22 pt above the top edge of the selection box.
    var knob: CGPoint {
        let e = element
        let p = viewPoint((e.center[0], e.center[1] - e.size[1] / 2))
        return inPicture(CGPoint(x: p.x, y: p.y - 4 - 22))
    }

    /// The floating bar of the selection, where the picture draws it (under it, over it, or inside the picture): its
    /// middle (the size slider) and its reset button.
    var barRect: CGRect {
        let e = element, o = picture.origin, k = pointsPerPixel
        let p = viewPoint((e.box[0], e.box[1]))
        return CanvasOverlay.barFrame(box: [p.x - o.x, p.y - o.y, e.box[2] * k, e.box[3] * k], kind: e.kind, view: picture.size).rect
            .offsetBy(dx: o.x, dy: o.y)
    }
    var bar: CGPoint { CGPoint(x: barRect.midX, y: barRect.midY) }
    var reset: CGPoint { CGPoint(x: barRect.maxX - 8 - 11, y: barRect.midY) }
    /// The bar's reset button as the accessibility tree finds it on screen (nil: no bar).
    var resetButton: RigElement? { rig.element(loc("Ripristina la posizione originale (anche doppio clic)")) }

    /// A click on the overlay: selected, its handles drawn.
    func select() { rig.click(viewPoint((element.center[0], element.center[1]))) }

    /// A drag, then the command it ends in.
    func drag(from: CGPoint, by delta: CGSize) async throws {
        let before = store.projectVersion
        rig.drag(from: from, by: delta)
        try await settle(since: before)
    }

    /// Undo takes the last gesture back in one step (`before`: the clip before it); redo puts it back.
    func expectOneUndoStep(_ before: Clip, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let after = clip
        #expect(after != before, "\(what) changed nothing", sourceLocation: sourceLocation)
        var v = store.projectVersion
        store.undo()
        try await settle(since: v)
        #expect(clip == before, "undo after \(what) did not restore the clip in one step", sourceLocation: sourceLocation)
        v = store.projectVersion
        store.redo()
        try await settle(since: v)
        #expect(clip == after, "redo after \(what) did not put it back", sourceLocation: sourceLocation)
    }

    func settle(since version: Int) async throws {
        for _ in 0..<40 where store.projectVersion == version { try await Task.sleep(for: .milliseconds(50)); rig.pump(0.01) }
        // The picture draws the new snapshot (handles where the element now is) before the next gesture starts there:
        // on a busy machine the store was ahead of the view and a second drag missed the handle.
        try await Task.sleep(for: .milliseconds(100))
        rig.pump(0.15)
        rig.drain()
    }
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct CanvasMouseTests {
    /// Press on an overlay nobody selected and drag: it is selected and moves.
    @Test func aDragOnAnOverlayMovesIt() async throws {
        let c = try await CanvasRig(scale: 0.5)
        defer { c.close() }
        try await c.drag(from: c.viewPoint((540, 960)), by: CGSize(width: 0, height: 40))
        #expect(c.store.canvasSelection == c.clipID)
        #expect(c.clip.placement!.y > 0.52)
    }

    /// A drag snaps the box to the frame's centre lines; with ⌘ held on the drag's own events it does not (#36: the
    /// gesture reads the click's modifiers, not the keyboard's).
    @Test func aCommandDragDoesNotSnap() async throws {
        let c = try await CanvasRig(scale: 0.5)
        defer { c.close() }
        c.select()
        // 4 pt to the right: past the drag's start (3 pt), inside the snapping distance (6 pt).
        try await c.drag(from: c.viewPoint((540, 960)), by: CGSize(width: 4, height: 0))
        let snapped = c.clip.placement?.x ?? 0.5
        #expect(abs(snapped - 0.5) < 0.001, "a plain drag did not snap back to the centre line (x \(snapped))")
        let before = c.store.projectVersion
        c.rig.drag(from: c.viewPoint((540, 960)), by: CGSize(width: 4, height: 0), modifiers: .command)
        try await c.settle(since: before)
        let free = c.clip.placement?.x ?? 0.5
        #expect(free > 0.5 + 2 / (c.pointsPerPixel * 1080), "a ⌘-drag snapped (x \(free))")
    }

    /// Once selected (handles and bar on screen) it still moves, and a click on the empty picture deselects it.
    @Test func aSelectedOverlayStillMovesAndDeselects() async throws {
        let c = try await CanvasRig(scale: 0.5)
        defer { c.close() }
        c.select()
        #expect(c.store.canvasSelection == c.clipID)
        try await c.drag(from: c.viewPoint((540, 960)), by: CGSize(width: 0, height: 40))
        #expect(c.clip.placement!.y > 0.52)
        c.rig.click(c.viewPoint((540, 200)))
        #expect(c.store.canvasSelection == nil)
        #expect(!c.store.preview.isPlaying)
    }

    /// A corner handle resizes the overlay: one smaller than the frame, one as wide as the frame (its corners are on
    /// the edge of the picture), one wider than the frame (its corners are outside the picture).
    @Test(arguments: [0.5, 1.0, 1.35])
    func aCornerHandleResizesAnOverlay(scale: Double) async throws {
        let c = try await CanvasRig(scale: scale)
        defer { c.close() }
        c.select()
        #expect(abs((c.clip.transform?.scale ?? 1) - scale) < 1e-6)
        try await c.drag(from: c.handle, by: CGSize(width: 14, height: 8))
        #expect((c.clip.transform?.scale ?? 1) > scale * 1.05, "the handle did not resize an overlay at scale \(scale)")
        #expect(!c.store.preview.isPlaying, "the click on the handle started the playback")
        // And back down, from where the handle now is.
        let grown = c.clip.transform?.scale ?? 1
        try await c.drag(from: c.handle, by: CGSize(width: -30, height: -17))
        #expect((c.clip.transform?.scale ?? 1) < grown * 0.95, "the handle did not shrink an overlay at scale \(scale)")
    }

    /// The knob above the selection turns the overlay.
    @Test func theKnobRotatesAnOverlay() async throws {
        let c = try await CanvasRig(scale: 0.5)
        defer { c.close() }
        c.select()
        try await c.drag(from: c.knob, by: CGSize(width: 30, height: 12))
        #expect(abs(c.clip.transform?.rotation ?? 0) > 5)
    }

    /// The size slider of the floating bar resizes the selection, also where the bar lies over another element: the
    /// click is the bar's, never the element's underneath. The bar stays while its slider moves.
    @Test func theBarSliderResizesAndKeepsTheClick() async throws {
        let c = try await CanvasRig(scale: 0.3, at: [540, 760], under: true)
        defer { c.close() }
        c.select()
        #expect(c.store.canvasSelection == c.clipID)
        let other = try #require(c.store.project?.tracks.flatMap(\.clips).first { $0.id != c.clipID })
        try await c.drag(from: c.bar, by: CGSize(width: 12, height: 0))
        #expect(c.store.canvasSelection == c.clipID, "the click on the bar selected what lies under it")
        #expect((c.clip.transform?.scale ?? 1) > 0.5, "the slider did not resize the selection")
        #expect(c.store.project?.tracks.flatMap(\.clips).first { $0.id == other.id } == other)
        // A second pull on the slider: the bar is still there.
        let once = c.clip.transform?.scale ?? 1
        try await c.drag(from: CGPoint(x: c.bar.x + 12, y: c.bar.y), by: CGSize(width: -30, height: 0))
        #expect((c.clip.transform?.scale ?? 1) < once - 0.2, "the slider did not answer a second time")
    }

    /// The bar's reset button puts a moved overlay back.
    @Test func theBarResetButtonPutsItBack() async throws {
        let c = try await CanvasRig(scale: 0.3, at: [540, 760], under: true)
        defer { c.close() }
        let home = c.clip.placement
        try await c.drag(from: c.viewPoint((540, 760)), by: CGSize(width: 0, height: -30))
        #expect(c.clip.placeOrigin != nil && c.clip.placement != home)
        let version = c.store.projectVersion
        c.rig.click(c.reset)
        try await c.settle(since: version)
        #expect(c.clip.placeOrigin == nil && c.clip.placement == home)
        #expect(c.store.canvasSelection == c.clipID)
    }

    // MARK: Everything drawn on the frame (#30)

    /// On the full-frame camera, a full-frame insert, a callout and a layout box: a click selects it with its handles
    /// and bar inside the picture; a drag moves it by the drag; a corner makes it larger and smaller; the bar's slider
    /// resizes it (twice: the bar stays); the bar's reset puts it back. Each gesture is one command, one undo step.
    @Test(arguments: CanvasGrab.allCases)
    func everyGestureAnswersOnEachKind(_ grab: CanvasGrab) async throws {
        let c = try await CanvasRig(grab)
        defer { c.close() }
        let original = c.clip
        let k = c.pointsPerPixel
        c.select()
        #expect(c.store.canvasSelection == c.clipID, "\(grab): the click did not select it")
        #expect(c.picture.contains(c.handle), "\(grab): the corner handle is outside the picture")
        let reset = try #require(c.resetButton, "\(grab): no floating bar after the click")
        #expect(c.picture.insetBy(dx: -0.5, dy: -0.5).contains(reset.frame), "\(grab): the bar is outside the picture (\(reset.frame) in \(c.picture))")
        // A drag moves it by the drag (snapping may pull it a few pixels).
        var before = c.clip
        let e0 = c.element
        try await c.drag(from: c.viewPoint((e0.center[0], e0.center[1])), by: CGSize(width: -20, height: -40))
        let e1 = c.element
        #expect(abs(e1.center[0] - e0.center[0] + 20 / k) < 8 / k && abs(e1.center[1] - e0.center[1] + 40 / k) < 8 / k,
                "\(grab): moved by \(e1.center[0] - e0.center[0]), \(e1.center[1] - e0.center[1]) for a drag of \(-20 / k), \(-40 / k)")
        #expect(c.store.canvasSelection == c.clipID)
        try await c.expectOneUndoStep(before, "\(grab): the drag")
        // A corner: larger, then smaller.
        before = c.clip
        let s0 = c.element.scale
        try await c.drag(from: c.handle, by: CGSize(width: 14, height: 8))
        #expect(c.element.scale > s0 * 1.04, "\(grab): the corner did not make it larger")
        try await c.expectOneUndoStep(before, "\(grab): the corner (larger)")
        before = c.clip
        let s1 = c.element.scale
        try await c.drag(from: c.handle, by: CGSize(width: -30, height: -17))
        #expect(c.element.scale < s1 * 0.95, "\(grab): the corner did not make it smaller")
        try await c.expectOneUndoStep(before, "\(grab): the corner (smaller)")
        // The bar's slider, twice: the bar stays under the pointer.
        before = c.clip
        let s2 = c.element.scale
        try await c.drag(from: c.bar, by: CGSize(width: 12, height: 0))
        #expect(c.store.canvasSelection == c.clipID, "\(grab): the click on the bar selected something else")
        #expect(c.element.scale > s2 + 0.1, "\(grab): the slider did not resize it")
        try await c.expectOneUndoStep(before, "\(grab): the slider")
        let s3 = c.element.scale
        try await c.drag(from: CGPoint(x: c.bar.x + 12, y: c.bar.y), by: CGSize(width: -30, height: 0))
        #expect(c.element.scale < s3 - 0.2, "\(grab): the slider did not answer a second time")
        // The bar's reset button: as it was.
        before = c.clip
        let version = c.store.projectVersion
        c.rig.click(c.reset)
        try await c.settle(since: version)
        #expect(c.clip == original, "\(grab): reset did not put it back")
        #expect(c.store.canvasSelection == c.clipID)
        try await c.expectOneUndoStep(before, "\(grab): reset")
    }

    /// A drag that starts on a full-frame picture nobody selected moves nothing; a click selects it, Esc lets it go.
    @Test(arguments: [CanvasGrab.camera, .insert])
    func aDragOnAnUnselectedFullFramePictureMovesNothing(_ grab: CanvasGrab) async throws {
        let c = try await CanvasRig(grab)
        defer { c.close() }
        let before = c.clip, version = c.store.projectVersion
        c.rig.drag(from: c.viewPoint((540, 960)), by: CGSize(width: 30, height: 60))
        try await Task.sleep(for: .milliseconds(300))
        c.rig.pump(0.2)
        #expect(c.clip == before && c.store.projectVersion == version, "\(grab): a drag on the unselected picture moved it")
        #expect(c.store.canvasSelection == nil, "\(grab): a drag selected it")
        c.select()
        #expect(c.store.canvasSelection == c.clipID)
        #expect(c.store.handleCanvasKey(53, shift: false) && c.store.canvasSelection == nil, "Esc did not deselect it")
    }

    /// An overlay and a title lying over the full-frame camera are still the ones hit and moved; the camera is
    /// selected where nothing lies over it.
    @Test func elementsOverAFullFramePictureAreStillTheOnesHit() async throws {
        let c = try await CanvasRig(.camera)
        defer { c.close() }
        let png = c.dir.appendingPathComponent("card.png")
        try CanvasRig.png(png, width: 1080, height: 600, red: 0.9, green: 0.4, blue: 0.2)
        let card = try await c.add("overlay.add", ["path": .string(png.path), "start": 0, "duration": 3, "fit": "contain", "scale": 0.3, "position": [540, 700]])
        let title = try await c.add("title.add", ["text": "CIAO", "start": 0, "duration": 3, "position": [540, 1300], "animIn": "none"])
        let camera = c.clip
        c.rig.click(c.viewPoint((540, 700)))
        #expect(c.store.canvasSelection == card, "the overlay over the camera was not the one hit")
        let y0 = c.clip(card)!.placement!.y
        try await c.drag(from: c.viewPoint((540, 700)), by: CGSize(width: 0, height: 30))
        #expect(c.clip(card)!.placement!.y > y0 + 0.02 && c.clip == camera, "the drag moved the camera, not the overlay")
        let t = c.element(title)
        c.rig.click(c.viewPoint((t.center[0], t.center[1])))
        #expect(c.store.canvasSelection == title, "the title over the camera was not the one hit")
        c.rig.click(c.viewPoint((200, 300)))
        #expect(c.store.canvasSelection == c.clipID, "the camera was not selected where nothing lies over it")
        #expect(c.clip == camera)
    }

    /// A motion template cannot be placed by hand: a click selects its clip (no handles, no bar), a drag moves nothing.
    @Test func aMotionTemplateIsSelectedByAClickAndNeverMoved() async throws {
        MotionLibrary.registerAll()
        let c = try await CanvasRig(scale: 0.3, at: [540, 400])
        defer { c.close() }
        let motion = try await c.add("motion.add", ["template": "counter", "start": 0, "duration": 3])
        #expect(c.element(motion).kind == .motion && !c.element(motion).movable)
        let before = c.clip(motion), version = c.store.projectVersion
        c.rig.click(c.viewPoint((540, 1500)))
        #expect(c.store.canvasSelection == motion, "the click did not select the motion template")
        #expect(c.resetButton == nil, "a motion template shows the bar")
        c.rig.drag(from: c.viewPoint((540, 1500)), by: CGSize(width: 20, height: 30))
        try await Task.sleep(for: .milliseconds(300))
        c.rig.pump(0.2)
        #expect(c.clip(motion) == before && c.store.projectVersion == version)
        // The overlay over it is still the one hit.
        c.select()
        #expect(c.store.canvasSelection == c.clipID)
    }
}
}
