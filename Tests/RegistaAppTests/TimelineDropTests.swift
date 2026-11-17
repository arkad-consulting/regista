import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #36: drag and drop from Media (or the Finder) to the timeline. A real drag session would use the session's pasteboard
// and draw on the screen of the person at the Mac, so none is started: the drop is tested at the function the timeline's
// drop delegate calls (`TimelinePanel.drop`), with item providers of the test's own — a Media tile's payload, a scratch
// file — at a point over a track and over the empty area under the tracks. The Media panel's own way to the timeline,
// its tile's «Metti in timeline al cursore», gives the same clip: its action here, and clicked (right click, menu item)
// with the click audits (a right click on a SwiftUI context menu is a window-server matter: see #57).

extension MouseSuites {
@Suite(.serialized) @MainActor struct TimelineDropTests {
    /// A timeline lane's middle at `seconds` (content coordinates of the timeline, as the drop delegate gets them).
    static func point(_ seconds: Double, pps: CGFloat, rows: [LaneRow], lane: (LaneRow) -> Bool) -> CGPoint? {
        var top = TimelinePanel.rulerHeight
        for r in rows {
            if lane(r) { return CGPoint(x: TimelinePanel.originX + CGFloat(seconds) * pps, y: top + r.height / 2) }
            top += r.height
        }
        return nil
    }

    @Test func aDropFromMediaAndTheMediaMenuGiveTheSameClip() async throws {
        let app = try await AppRig(project: "empty")
        defer { app.close() }
        let store = app.store
        let take = rigTempDir("drop").appendingPathComponent("ripresa.mov")
        try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: take)
        let asset = try #require(try await store.perform("media.import", ["path": .string(take.path)]).value(at: "asset.id")?.stringValue)
        app.hostEditor(Navigation(activity: .media, level: .pro, rightTab: .inspector))
        await app.settle()
        func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        /// The clips of the timeline as a person compares them: what, where, how long, on which kind of track.
        func clips() -> [String] {
            (store.project?.tracks ?? []).flatMap { t in t.clips.map { c in
                "\(t.kind.rawValue) \(c.assetID.isEmpty ? "-" : c.assetID) \(String(format: "%.2f", c.start.seconds))–\(String(format: "%.2f", c.end.seconds)) in \(String(format: "%.2f", c.sourceIn.seconds))"
            } }.sorted()
        }
        let pps = CGFloat(store.pxPerSec)
        func point(_ seconds: Double, lane: (LaneRow) -> Bool, rows: [LaneRow]) -> CGPoint? { Self.point(seconds, pps: pps, rows: rows, lane: lane) }

        // A Media tile dropped on the empty V1 lane at 0:00: the picture there, its sound on A1.
        var rows = LaneRow.rows(store.project)
        let v1 = try #require(point(0, lane: { $0.role == .footage }, rows: rows), "no V1 lane: \(rows.map(\.label))")
        #expect(TimelinePanel.dropTarget(at: v1, rows: rows) == .slot(.video))
        #expect(TimelinePanel.drop([NSItemProvider(object: (MediaDrop.assetPrefix + asset) as NSString)], at: v1, rows: rows, store: store, pps: pps))
        #expect(await until { store.project?.tracks.flatMap(\.clips).count == 2 }, "the dropped tile is not on the timeline: \(clips())")
        await app.settle()
        let dropped = clips()
        #expect(dropped.contains { $0.hasPrefix("video \(asset) 0.00–") } && dropped.contains { $0.hasPrefix("audio \(asset) 0.00–") }, "\(dropped)")

        // The same tile through what the Media panel's «Metti in timeline al cursore» runs, with the playhead at 0:00
        // (the menu itself is clicked in theMediaTilesMenuPutsTheSameClip, which the push hook runs).
        for _ in 0..<4 where store.project?.tracks.flatMap(\.clips).isEmpty == false { _ = try await store.perform("history.undo", [:]) }
        #expect(store.project?.tracks.flatMap(\.clips).isEmpty == true, "the drop was not undone: \(clips())")
        store.preview.seek(0)
        await app.settle()
        store.placeAtPlayhead(asset: asset)
        #expect(await until { store.project?.tracks.flatMap(\.clips).count == 2 }, "the tile's menu action put nothing on the timeline: \(clips())")
        await app.settle()
        #expect(clips() == dropped, "the menu's action gave \(clips()), the drop \(dropped)")

        // Over the empty area under the tracks: a new track of the clip's kind, at the drop's time.
        rows = LaneRow.rows(store.project)
        let below = CGPoint(x: TimelinePanel.originX + 2 * pps, y: TimelinePanel.rulerHeight + rows.reduce(0) { $0 + $1.height } + 30)
        #expect(TimelinePanel.dropTarget(at: below, rows: rows) == .below)
        let tracks = store.project?.tracks.count ?? 0
        #expect(TimelinePanel.drop([NSItemProvider(object: (MediaDrop.assetPrefix + asset) as NSString)], at: below, rows: rows, store: store, pps: pps))
        #expect(await until { (store.project?.tracks.count ?? 0) > tracks }, "a drop under the tracks made no track: \(clips())")
        await app.settle()
        #expect(clips().contains { $0.hasPrefix("video \(asset) 2.00–") }, "the drop under the tracks is not at 0:02: \(clips())")

        // A file from the Finder (a scratch copy) over the A1 track at 0:08: imported, then placed there.
        rows = LaneRow.rows(store.project)
        let file = rigTempDir("drop").appendingPathComponent("altra.mov")
        try FileManager.default.copyItem(at: take, to: file)
        let a1 = try #require(point(8, lane: { $0.label == "A1" }, rows: rows), "no A1 lane: \(rows.map(\.label))")
        let assets = store.project?.assets.count ?? 0
        #expect(TimelinePanel.drop([NSItemProvider(object: file as NSURL)], at: a1, rows: rows, store: store, pps: pps))
        #expect(await until(10) { (store.project?.assets.count ?? 0) == assets + 1 }, "the dropped file was not imported")
        await app.settle()
        let imported = try #require(store.project?.assets.last?.id)
        #expect(await until { clips().contains { $0.contains(" \(imported) 8.00–") } }, "the dropped file is not at 0:08: \(clips())")
    }
}
}

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct MediaTileMenuScreenClickTests {   // in the push hook's filter (…ScreenClickTests)
    /// The Media panel's own way to the timeline, clicked: a right click on the tile, «Metti in timeline al cursore» with
    /// the playhead at 0:00, gives the clip a Media tile dropped on the empty V1 lane at 0:00 gives (#36).
    @Test func theMediaTilesMenuPutsTheSameClip() async throws {
        let app = try await AppRig(project: "empty")
        defer { app.close() }
        let store = app.store
        let take = rigTempDir("drop").appendingPathComponent("ripresa.mov")
        try FileManager.default.copyItem(at: try RigProject.media.get().appendingPathComponent("take.mov"), to: take)
        let asset = try #require(try await store.perform("media.import", ["path": .string(take.path)]).value(at: "asset.id")?.stringValue)
        app.hostEditor(Navigation(activity: .media, level: .pro, rightTab: .inspector))
        await app.settle()
        func until(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !condition() {
                if Date() > end { return false }
                await app.idle(0.05)
            }
            return true
        }
        func clips() -> [String] {
            (store.project?.tracks ?? []).flatMap { t in t.clips.map { c in
                "\(t.kind.rawValue) \(c.assetID) \(String(format: "%.2f", c.start.seconds))–\(String(format: "%.2f", c.end.seconds)) in \(String(format: "%.2f", c.sourceIn.seconds))"
            } }.sorted()
        }
        // The drop, then taken back.
        let rows = LaneRow.rows(store.project), pps = CGFloat(store.pxPerSec)
        let v1 = try #require(MouseSuites.TimelineDropTests.point(0, pps: pps, rows: rows) { $0.role == .footage })
        #expect(TimelinePanel.drop([NSItemProvider(object: (MediaDrop.assetPrefix + asset) as NSString)], at: v1, rows: rows, store: store, pps: pps))
        #expect(await until { store.project?.tracks.flatMap(\.clips).count == 2 })
        await app.settle()
        let dropped = clips()
        for _ in 0..<4 where store.project?.tracks.flatMap(\.clips).isEmpty == false { _ = try await store.perform("history.undo", [:]) }
        store.preview.seek(0)
        await app.settle()
        // The tile (its picture, or before the thumbnail is drawn its name under it), right-clicked.
        var found: RigElement?
        _ = await until {
            let side = app.rig.elements().filter { WindowPart.side.contains($0.centre) && $0.visible }
            found = side.first { $0.role == "AXImage" && $0.frame.minY < 200 }
                ?? side.filter { $0.role == "AXStaticText" && $0.name == "ripresa.mov" }.min { $0.frame.minY < $1.frame.minY }
            return found != nil
        }
        let tile = try #require(found, "no Media tile")
        RigGuard.lastMenu = nil
        app.rig.rightClick(tile.centre)
        let menu = try #require(RigGuard.lastMenu, "the Media tile has no menu")
        let place = try #require(menu.items.firstIndex { $0.title == "Metti in timeline al cursore" }, "no «Metti in timeline al cursore» in \(menu.items.map(\.title))")
        menu.performActionForItem(at: place)
        #expect(await until { store.project?.tracks.flatMap(\.clips).count == 2 }, "the menu put nothing on the timeline: \(clips())")
        await app.settle()
        #expect(clips() == dropped, "the menu gave \(clips()), the drop \(dropped)")
    }
}
}
