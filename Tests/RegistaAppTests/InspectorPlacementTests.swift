import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #53: one position and one size per picture. The handles on the Program picture write the clip's placement
// (clip.place); for a clip placed by hand the Inspector's X, Y and Scala are a view of that placement and write through
// clip.place too. Real mouse and key events on the whole window (Journey on AppRig), on the video, a title and a logo:
// after a corner drag the Inspector shows what is drawn; after a new Scala typed in the Inspector the picture is drawn
// at it and its corner handle sits there (a drag from it resizes it); one undo takes back one step in both; the reset
// of the picture's bar brings the Inspector back to 100 %.

/// What the Inspector's row named `label` shows (the value at the right end of the row).
@MainActor
func inspectorValue(_ j: Journey, _ label: String) -> String? {
    let all = j.rig.elements().filter { $0.role == "AXStaticText" && $0.visible }
    guard let name = all.first(where: { $0.value == label && $0.frame.minX > j.rig.size.width - Chrome.rightWidth }) else { return nil }
    return all.filter { abs($0.centre.y - name.centre.y) < 6 && $0.frame.minX > name.frame.maxX }.max { $0.frame.minX < $1.frame.minX }?.value
}

/// How bright the window is at a point (0 black … 1 white), from what it draws.
@MainActor
func colour(_ j: Journey, at p: CGPoint) -> (r: Double, g: Double, b: Double) {
    let v = j.rig.host
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return (-1, -1, -1) }
    v.cacheDisplay(in: v.bounds, to: rep)
    let sx = Double(rep.pixelsWide) / v.bounds.width, sy = Double(rep.pixelsHigh) / v.bounds.height
    guard let c = rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sy))?.usingColorSpace(.sRGB) else { return (-1, -1, -1) }
    return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
}

@MainActor
func brightness(_ j: Journey, at p: CGPoint) -> Double {
    let v = j.rig.host
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return -1 }
    v.cacheDisplay(in: v.bounds, to: rep)
    let sx = Double(rep.pixelsWide) / v.bounds.width, sy = Double(rep.pixelsHigh) / v.bounds.height
    guard let c = rep.colorAt(x: Int(p.x * sx), y: Int(p.y * sy))?.usingColorSpace(.sRGB) else { return -1 }
    return Double(max(c.redComponent, c.greenComponent, c.blueComponent))
}

/// The number in an Inspector value ("62 %", "540 px").
func inspectorNumber(_ text: String?) -> Double? {
    text.flatMap { Double($0.filter { "0123456789.-".contains($0) }) }
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct InspectorPlacementTests {
    enum Thing: String, CaseIterable, CustomStringConvertible, Sendable {
        case video, title, logo
        var description: String { rawValue }
    }

    @Test(arguments: Thing.allCases)
    func theInspectorAndTheHandlesAreOnePlacement(_ thing: Thing) async throws {
        let j = try await Journey("inspector-\(thing)", project: "rich")
        defer { j.close() }
        let store = j.app.store
        // The thing on the picture at 0.5 s, nothing animating: the take filling the frame, a title, a logo.
        let clipID: String
        switch thing {
        case .video:
            clipID = try #require(store.project?.tracks.first { $0.kind == .video }?.clips.first?.id)
        case .title:
            let r = try await store.perform("title.add", ["text": "SPOSTAMI", "start": 0, "duration": 6, "position": [540, 520], "animIn": "none", "animOut": "none"])
            clipID = try #require(r.value(at: "clip.id")?.stringValue)
        case .logo:
            let card = try RigProject.media.get().appendingPathComponent("card.png")
            let r = try await store.perform("logo.add", ["path": .string(card.path), "start": 0, "end": 6, "corner": "topLeft", "width": 360, "animation": "none"])
            clipID = try #require(r.value(at: "clip.id")?.stringValue)
        }
        await j.open(Navigation(activity: .media, rightTab: .inspector))
        store.preview.seek(0.5)
        await j.app.idle(0.3)
        let W = Double(try #require(store.project?.settings.width))
        func drawn() throws -> CanvasElement { try #require(j.drawn.first { $0.clipID == clipID }, "\(thing) is not on the picture: \(j.drawn.map(\.clipID))") }
        /// The bottom-right corner handle of what is drawn (4 pt outside the corner, kept 7 pt inside the picture).
        func handle() throws -> CGPoint {
            let e = try drawn(), pic = try #require(j.picture), k = pic.width / W
            return CGPoint(x: min(pic.minX + (e.center[0] + e.size[0] / 2) * k + 4, pic.maxX - 7),
                           y: min(pic.minY + (e.center[1] + e.size[1] / 2) * k + 4, pic.maxY - 7))
        }
        func scala() -> Double? { inspectorNumber(inspectorValue(j, "Scala")) }
        /// The Inspector shows what is drawn: the size in per cent, the centre in pixels.
        /// (A clip never placed by hand keeps the offset rows until it is placed: the video at the start and after the reset.)
        func expectInspectorShowsTheDrawing(_ what: String, position: Bool = true, sourceLocation: SourceLocation = #_sourceLocation) throws {
            let e = try drawn()
            let s = scala(), x = inspectorNumber(inspectorValue(j, "X")), y = inspectorNumber(inspectorValue(j, "Y"))
            #expect(s.map { abs($0 - e.scale * 100) <= 1 } == true, "\(thing), \(what): Scala \(String(describing: s)) for a picture drawn at \(e.scale)",
                    sourceLocation: sourceLocation)
            guard position else { return }
            #expect(x.map { abs($0 - e.center[0]) <= 2 } == true && y.map { abs($0 - e.center[1]) <= 2 } == true,
                    "\(thing), \(what): X \(String(describing: x)), Y \(String(describing: y)) for a centre at \(e.center)", sourceLocation: sourceLocation)
        }

        // Selected on the picture (the video where nothing lies over it).
        let start = try drawn()
        let at = thing == .video ? try #require(j.onPicture(200, 260)) : try #require(j.onPicture(start.center[0], start.center[1]))
        j.rig.click(at)
        await j.app.settle()
        #expect(store.canvasSelection == clipID, "\(thing): a click on it did not select it (\(String(describing: store.canvasSelection)))")
        #expect(inspectorValue(j, "Scala") != nil, "\(thing): the Inspector has no Scala: \(j.screen())")
        try expectInspectorShowsTheDrawing("selected", position: thing != .video)

        // A corner drag on the picture: the Inspector follows.
        var n = store.activity.count
        j.rig.drag(from: try handle(), by: CGSize(width: -24, height: -24))
        await j.app.settle()
        let small = try drawn()
        #expect(small.scale < start.scale * 0.95, "\(thing): the corner did not make it smaller (\(small.scale))")
        #expect(j.app.commands(since: n) == ["clip.place"], "\(thing): the corner ran \(j.app.commands(since: n))")
        try expectInspectorShowsTheDrawing("after a corner drag")
        /// The video is drawn at its size: just outside its edge the monitor is black, just inside it is the picture.
        func expectVideoDrawn(at e: CanvasElement, _ what: String, sourceLocation: SourceLocation = #_sourceLocation) async {
            guard thing == .video, let outside = j.onPicture(e.center[0] + e.size[0] / 2 + 40, e.center[1]),
                  let inside = j.onPicture(e.center[0] + e.size[0] / 2 - 40, e.center[1]) else { return }
            #expect(await j.until(3) { brightness(j, at: outside) < 0.1 && brightness(j, at: inside) > 0.3 },
                    "video, \(what): not drawn at \(e.scale) (outside its edge \(brightness(j, at: outside)), inside \(brightness(j, at: inside)))",
                    sourceLocation: sourceLocation)
        }
        /// The logo (an opaque blue card) is drawn over its whole box: blue near each side of the box.
        func expectLogoDrawn(_ what: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            guard thing == .logo else { return }
            let e = try drawn()
            let points = [(-0.4, 0.0), (0.4, 0.0), (0.0, -0.4), (0.0, 0.4), (0.0, 0.0)].compactMap { j.onPicture(e.center[0] + $0.0 * e.size[0], e.center[1] + $0.1 * e.size[1]) }
            func blue(_ p: CGPoint) -> Bool { let c = colour(j, at: p); return c.b > 0.75 && c.r < 0.5 && c.g < 0.7 }
            #expect(await j.until(3) { points.allSatisfy(blue) },
                    "logo, \(what): not drawn over its box \(e.box): \(points.map { let c = colour(j, at: $0); return String(format: "%.2f,%.2f,%.2f", c.r, c.g, c.b) })",
                    sourceLocation: sourceLocation)
        }
        await expectVideoDrawn(at: small, "after a corner drag")
        try await expectLogoDrawn("after a corner drag")
        j.step("\(thing): drags its corner in on the Program picture", sees: "drawn at \(Int((small.scale * 100).rounded())) %, the Inspector's Scala \(inspectorValue(j, "Scala") ?? "?")")

        // A new Scala typed in the Inspector: drawn at it, through clip.place.
        n = store.activity.count
        let undoCount = store.undoNames.count
        let field = try #require(j.rig.elements().first { $0.role == "AXStaticText" && $0.value == inspectorValue(j, "Scala") && $0.frame.minX > j.rig.size.width - Chrome.rightWidth },
                                 "\(thing): no Scala value to click")
        j.rig.click(field.centre)
        j.rig.pump(0.1)
        #expect(j.rig.isTyping, "\(thing): a click on the Scala value did not make a field")
        j.rig.key("a", keyCode: 0, modifiers: .command)
        j.rig.type("50")
        j.rig.key(.returnKey)
        await j.app.settle()
        #expect(j.app.commands(since: n) == ["clip.place"] && store.undoNames.count == undoCount + 1,
                "\(thing): the Inspector's Scala ran \(j.app.commands(since: n))")
        let half = try drawn()
        #expect(abs(half.scale - 0.5) < 0.005, "\(thing): drawn at \(half.scale) after Scala 50 %")
        #expect(abs(half.center[0] - small.center[0]) < 1 && abs(half.center[1] - small.center[1]) < 1, "\(thing): the new size moved its centre")
        try expectInspectorShowsTheDrawing("after Scala 50 %")
        await expectVideoDrawn(at: half, "after Scala 50 %")
        try await expectLogoDrawn("after Scala 50 %")
        j.step("\(thing): types 50 in the Inspector's Scala", sees: "drawn at 50 %, its handles on the new size")
        // Its corner handle sits on the new size: a drag from there resizes it (then undone).
        j.rig.drag(from: try handle(), by: CGSize(width: 12, height: 12))
        await j.app.settle()
        #expect(try drawn().scale > half.scale * 1.03, "\(thing): no handle at the corner of the new size")
        try await j.tap("Annulla l'ultima modifica")
        #expect(abs(try drawn().scale - 0.5) < 0.005)

        // One undo takes back the Inspector's step, on the picture and in the Inspector.
        try await j.tap("Annulla l'ultima modifica")
        #expect(abs(try drawn().scale - small.scale) < 0.002, "\(thing): one undo did not bring back the size of the corner drag")
        try expectInspectorShowsTheDrawing("after one undo")
        await expectVideoDrawn(at: try drawn(), "after one undo")
        try await expectLogoDrawn("after one undo")
        j.step("\(thing): Annulla once", sees: "the size of the corner drag, on the picture and in the Inspector")

        // The reset of the picture's bar: as it was, the Inspector at 100 %.
        let reset = try #require(j.control("Ripristina la posizione originale (anche doppio clic)"), "\(thing): no reset on the picture's bar: \(j.screen())")
        j.rig.click(reset.centre)
        await j.app.settle()
        #expect(store.project?.tracks.flatMap(\.clips).first { $0.id == clipID }?.placeOrigin == nil, "\(thing): the reset did not put it back")
        // Back to its size before the first move: 100 % for the video and the title; the logo, drawn at the kit's width,
        // is at its own scale of the logo file (what clip.place and the bar's slider call 1 = native size).
        #expect(scala().map { abs($0 - start.scale * 100) < 0.5 } == true, "\(thing): Scala \(String(describing: scala())) after the reset, \(start.scale * 100) before")
        if thing != .logo { #expect(scala().map { abs($0 - 100) < 0.5 } == true, "\(thing): Scala \(String(describing: scala())) after the reset") }
        try expectInspectorShowsTheDrawing("after the reset", position: thing != .video)
        try await expectLogoDrawn("after the reset")
        j.step("\(thing): the reset on the picture's bar", sees: "as it was, the Inspector's Scala \(inspectorValue(j, "Scala") ?? "?")")
    }
}
}
