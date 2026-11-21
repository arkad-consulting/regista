import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #142: a file in Media removed from the project in one click: the tile's trash icon (on hover and on the selected
// tile), its menu, ⌫ while Media has the focus. One command (media.remove), an alert first when the timeline uses the
// file, a notice with Annulla; «Sposta il file nel Cestino» only for a recording Regista made, through the rig's Trash.

extension MouseSuites {
@Suite(.serialized) @MainActor struct MediaRemovalMouseTests {
    /// The rich project on Media, with one more file imported from elsewhere («spare-…») and one recorded by Regista
    /// («Registrazione …», in the workbench's recordings folder): neither is on the timeline.
    private func open() async throws -> (app: AppRig, spare: MediaAsset, own: MediaAsset) {
        let app = try await AppRig()
        let take = try RigProject.media.get().appendingPathComponent("take.mov")
        let spare = rigTempDir("elsewhere").appendingPathComponent("spare-\(UUID().uuidString.prefix(6)).mov")
        try FileManager.default.copyItem(at: take, to: spare)
        let recordings = rigTempDir("recordings")
        app.store.bench.recordingsFolder = recordings
        let own = recordings.appendingPathComponent("Registrazione \(UUID().uuidString.prefix(6)).mov")
        try FileManager.default.copyItem(at: take, to: own)
        for f in [spare, own] { try await app.store.perform("media.import", ["path": .string(f.path)]) }
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector))
        await app.settle()
        let assets = try #require(app.store.project?.assets)
        return (app, try #require(assets.first { $0.path == spare.path }), try #require(assets.first { $0.path == own.path }))
    }

    /// A tile's name under its picture, in the side panel.
    private func tile(_ app: AppRig, _ name: String) async -> RigElement? {
        var found: RigElement?
        _ = await app.until(5) {
            found = app.rig.elements().first { $0.role == "AXStaticText" && $0.visible && $0.name == name && WindowPart.side.contains($0.centre) }
            return found != nil
        }
        return found
    }

    /// The trash icon of the tile whose name is `label` (it sits on the tile's picture, above the name).
    private func trash(_ app: AppRig, over label: RigElement) -> RigElement? {
        app.rig.controls().first { $0.label == "Rimuovi dal progetto" && abs($0.centre.x - label.centre.x) < 70 && $0.centre.y < label.centre.y
            && label.centre.y - $0.centre.y < 110 }
    }

    /// The icon: shown on the selected tile only (and on hover), inside the tile; a click removes a file the timeline
    /// does not use at once (no alert), leaves the file where it is, and the notice offers Annulla but not the Trash
    /// (an imported file); Annulla puts it back.
    @Test func theTrashIconRemovesAnUnusedFileAndAnnullaPutsItBack() async throws {
        let (app, spare, _) = try await open()
        defer { app.close() }
        let label = try #require(await tile(app, spare.name), "no tile «\(spare.name)»")
        #expect(trash(app, over: label) == nil, "the trash icon shows on a tile that is neither selected nor hovered")
        app.rig.click(label.centre)
        await app.idle(NSEvent.doubleClickInterval + 0.1)
        await app.settle()
        #expect(app.store.sourceAssetID == spare.id, "the click did not select the tile")
        let icon = try #require(trash(app, over: label), "no trash icon on the selected tile: \(app.rig.controls().map(\.description))")
        #expect(icon.frame.width <= 24 && icon.frame.height <= 24, "the icon is not small: \(icon.frame)")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("media-tile-selected.png")) }
        let events = RigGuard.events.count, n = app.store.activity.count, count = app.store.project?.assets.count ?? 0
        app.rig.click(icon.centre)
        #expect(await app.until(5) { app.store.bench.notice != nil }, "no notice after the click")
        await app.settle()
        #expect(app.commands(since: n) == ["media.remove"], "\(app.commands(since: n))")
        #expect(!RigGuard.events.dropFirst(events).contains { $0.kind == .alert }, "an alert for a file the timeline does not use")
        #expect(app.store.project?.assets.count == count - 1 && app.store.project?.asset(spare.id) == nil)
        #expect(FileManager.default.fileExists(atPath: spare.path), "the file was touched")
        #expect(app.store.bench.notice?.text == loc("Tolto «%@» dal progetto", spare.name))
        #expect(!app.rig.elements(containing: loc("Tolto «%@» dal progetto", spare.name)).isEmpty, "the notice is not on screen")
        #expect(app.rig.element("Sposta il file nel Cestino di macOS: la rimozione non si potrà più annullare da qui") == nil,
                "an imported file is offered for the Trash")
        // Annulla (the undo of the removal).
        #expect(app.rig.click("Rimetti il file nel progetto"), "no Annulla on the notice")
        #expect(await app.until(5) { app.store.project?.asset(spare.id) != nil }, "Annulla did not put the file back")
        #expect(app.store.bench.notice == nil && app.store.project?.assets.count == count)
    }

    /// Hovering a tile shows its icon too (the pointer moved over the picture, as a real mouse sends it).
    @Test func theTrashIconShowsOnHover() async throws {
        let (app, spare, _) = try await open()
        defer { app.close() }
        let label = try #require(await tile(app, spare.name))
        #expect(app.store.sourceAssetID != spare.id && trash(app, over: label) == nil)
        let over = CGPoint(x: label.centre.x, y: label.centre.y - 40)
        // The pointer enters the tile: the tracking areas under it get their «entered» (a synthetic move does not reach
        // them: AppKit follows the real pointer for those).
        let inWindow = CGPoint(x: over.x, y: app.rig.size.height - over.y)
        func areas(_ v: NSView) -> [(NSView, NSTrackingArea)] {
            v.trackingAreas.filter { $0.rect.contains(v.convert(inWindow, from: nil)) }.map { (v, $0) } + v.subviews.flatMap(areas)
        }
        let root = try #require(app.rig.window.contentView)
        let entered = areas(root)
        for (v, area) in entered {
            guard let e = NSEvent.enterExitEvent(with: .mouseEntered, location: inWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: app.rig.window.windowNumber, context: nil, eventNumber: 0,
                                                 trackingNumber: unsafeBitCast(area, to: Int.self), userData: nil) else { continue }
            (area.owner as? NSResponder ?? v).mouseEntered(with: e)
        }
        await app.settle()
        let icon = try #require(trash(app, over: label), "no trash icon on the hovered tile (\(entered.count) tracking areas entered)")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("media-tile-hovered.png")) }
        app.rig.click(icon.centre)
        #expect(await app.until(5) { app.store.project?.asset(spare.id) == nil }, "the hovered tile's icon did not remove the file")
    }

    /// The tile's menu on the take the timeline uses: the alert first; Annulla keeps everything, Rimuovi takes the file
    /// and its clips (its sound too), leaving the other clips where they were.
    @Test func theMenuAsksFirstWhenTheTimelineUsesTheFile() async throws {
        let (app, _, _) = try await open()
        defer {
            RigGuard.alertAnswer = .alertSecondButtonReturn
            app.close()
        }
        let take = try #require(app.store.project?.asset("a1"))
        let label = try #require(await tile(app, take.name), "no tile «\(take.name)»")
        let before = try #require(app.store.project)
        let using = before.tracks.flatMap(\.clips).filter { $0.assetID == take.id }.count
        #expect(using >= 2, "the take is not on the timeline with its sound")
        func remove() async throws {
            RigGuard.lastMenu = nil
            app.rig.rightClick(label.centre)
            let menu = try #require(RigGuard.lastMenu, "the tile has no menu")
            let item = try #require(menu.items.firstIndex { $0.title == "Rimuovi dal progetto" }, "no «Rimuovi dal progetto» in \(menu.items.map(\.title))")
            menu.performActionForItem(at: item)
            await app.settle()
        }
        var events = RigGuard.events.count
        RigGuard.alertAnswer = .alertSecondButtonReturn
        try await remove()
        let alert = RigGuard.events.dropFirst(events).first { $0.kind == .alert }
        #expect(alert?.detail == loc("Rimuovere «%@»?", take.name), "no alert: \(RigGuard.events.dropFirst(events))")
        await app.idle(0.3)
        #expect(app.store.project == before, "Annulla in the alert changed the project")
        events = RigGuard.events.count
        RigGuard.alertAnswer = .alertFirstButtonReturn
        try await remove()
        #expect(RigGuard.events.dropFirst(events).contains { $0.kind == .alert })
        #expect(await app.until(5) { app.store.project?.asset(take.id) == nil }, "Rimuovi did not remove the take")
        let after = try #require(app.store.project)
        #expect(!after.tracks.flatMap(\.clips).contains { $0.assetID == take.id }, "a clip of the take is left")
        let others = before.tracks.flatMap(\.clips).filter { $0.assetID != take.id && $0.link == nil }
        #expect(others.allSatisfy { c in after.tracks.flatMap(\.clips).contains { $0.id == c.id && $0.start == c.start } }, "another clip moved or went")
        #expect(FileManager.default.fileExists(atPath: take.path))
    }

    /// ⌫ removes the selected tile's file while Media has the focus; with a clip selected on the timeline it deletes the
    /// clip as before.
    @Test func deleteRemovesTheSelectedTileWhileMediaHasTheFocus() async throws {
        let (app, spare, _) = try await open()
        defer { app.close() }
        KeyMonitor.install(app.store.bench)
        let label = try #require(await tile(app, spare.name))
        app.rig.click(label.centre)
        await app.idle(NSEvent.doubleClickInterval + 0.1)
        await app.settle()
        #expect(app.store.sourceAssetID == spare.id && app.store.mediaFocus)
        app.rig.key(.delete)
        #expect(await app.until(5) { app.store.project?.asset(spare.id) == nil }, "⌫ did not remove the selected file")
        // A clip selected: the focus is on the timeline, ⌫ deletes the clip, the file in Source stays.
        let clip = try #require(app.store.project?.tracks.flatMap(\.clips).first { $0.assetID == "a1" })
        app.store.sourceAssetID = "a1"
        app.store.selection = [clip.id]
        #expect(!app.store.mediaFocus)
        app.rig.key(.delete)
        #expect(await app.until(5) { app.store.project?.locate(clip: clip.id) == nil }, "⌫ did not delete the clip")
        #expect(app.store.project?.asset("a1") != nil, "⌫ removed the file instead of the clip")
    }

    /// A recording Regista made: the notice also offers «Sposta il file nel Cestino»; a click sends the file to the
    /// (rig's) Trash and the notice says so, without Annulla.
    @Test func aRecordingRegistaMadeCanGoToTheTrash() async throws {
        let (app, _, own) = try await open()
        defer { app.close() }
        let label = try #require(await tile(app, own.name))
        app.rig.click(label.centre)
        await app.idle(NSEvent.doubleClickInterval + 0.1)
        await app.settle()
        app.rig.click(try #require(trash(app, over: label), "no trash icon").centre)
        #expect(await app.until(5) { app.store.bench.notice?.removal != nil })
        await app.settle()
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] { try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("media-removed-notice.png")) }
        let taken = RigTrash.taken.count
        #expect(app.rig.click("Sposta il file nel Cestino di macOS: la rimozione non si potrà più annullare da qui"), "no Trash button for Regista's own recording")
        #expect(await app.until(5) { RigTrash.taken.count > taken }, "nothing went to the Trash")
        #expect(RigTrash.taken.last == URL(fileURLWithPath: own.path).lastPathComponent && !FileManager.default.fileExists(atPath: own.path))
        #expect(await app.until(5) { app.store.bench.notice?.text == loc("Il file di «%@» è nel Cestino: la rimozione non si annulla più da qui.", own.name) })
        await app.settle()
        #expect(app.rig.element("Rimetti il file nel progetto") == nil, "Annulla is still offered after the Trash")
    }

    /// The alert as macOS draws it (the rig answers alerts without drawing them): its words fit.
    @Test(arguments: ["it", "fr"])
    @MainActor func theRemovalAlertSnapshot(_ language: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] else { return }
        Words.override = MouseRig.table(language)
        defer { Words.override = nil }
        let a = EditorStore.removalAlert("ripresa.mov", clips: 2)
        a.layout()
        let v = try #require(a.window.contentView)
        let rep = try #require(v.bitmapImageRepForCachingDisplay(in: v.bounds))
        v.cacheDisplay(in: v.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("media-remove-alert-\(language).png"))
    }
}
}
