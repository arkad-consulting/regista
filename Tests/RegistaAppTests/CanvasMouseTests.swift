import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The mouse path of the preview (#28): click, drag, the corner handles, the rotation knob and the floating bar of the
// Program picture, driven with real mouse events (MouseRig).

private func scratchDefaults() -> UserDefaults {
    let name = "regista-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// The Program picture with one overlay on the timeline (and, with `under`, a second one as wide as the frame lying
/// under the first and under its floating bar).
@MainActor
private final class CanvasRig {
    let store: EditorStore
    let rig: MouseRig
    let clipID: String
    /// The monitor: the picture with the 10 pt margin it has in the Program monitor.
    static let view = CGSize(width: 320, height: 540)
    static let margin = 10.0

    init(scale: Double, at centre: [Double] = [540, 960], under: Bool = false) async throws {
        _ = NSApplication.shared
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-canvas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv("REGISTA_ENGINE_SOCKET", dir.appendingPathComponent("e.sock").path, 1)
        store = EditorStore(defaults: scratchDefaults(), seedFolders: [])
        // A 1080×600 picture: fitted in the frame it is as wide as the frame.
        let png = dir.appendingPathComponent("card.png")
        let ctx = CGContext(data: nil, width: 1080, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1080, height: 600))
        try #require(NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])).write(to: png)
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

    func close() { rig.close() }

    var clip: Clip { store.project!.tracks.flatMap(\.clips).first { $0.id == clipID }! }
    var element: CanvasElement {
        CanvasLayout.elements(store.project!, at: .zero, renderer: nil).first { $0.clipID == clipID }!
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

    /// The floating bar under the selection: its middle (the size slider) and its reset button.
    var bar: CGPoint {
        let e = element
        let p = viewPoint((e.center[0], e.box[1] + e.box[3]))
        return CGPoint(x: p.x, y: p.y + 14 + 17)
    }
    var reset: CGPoint { CGPoint(x: bar.x + 110 - 8 - 11, y: bar.y) }

    /// A click on the overlay: selected, its handles drawn.
    func select() { rig.click(viewPoint((element.center[0], element.center[1]))) }

    /// A drag, then the command it ends in.
    func drag(from: CGPoint, by delta: CGSize) async throws {
        let before = store.projectVersion
        rig.drag(from: from, by: delta)
        try await settle(since: before)
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
}
}
