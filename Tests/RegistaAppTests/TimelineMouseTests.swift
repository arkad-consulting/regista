import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The timeline driven with the mouse and the keyboard (#29): select a clip, move it, trim its edge, cut it with the
// razor, scrub the ruler, deselect on the empty lane, a caption word made a keyword with the Text tool, the clip's
// right-click menu, and the editor's keys (docs/reference/shortcuts.md, "In the timeline"), on the whole editor window.

@MainActor
private final class TimelineRig {
    let app: AppRig
    var rig: MouseRig { app.rig }
    var store: EditorStore { app.store }

    init() async throws {
        app = try await AppRig()
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector))
        // A known zoom: 40 pt per second, scrolled to the start.
        store.pxPerSec = 40
        store.autoFit = false
        rig.pump(0.2)
        KeyMonitor.install(store.bench)
    }

    func close() { app.close() }

    /// The lanes: the right edge of the track headers, where time 0 sits 12 pt in.
    var lanesX: CGFloat {
        let header = rig.elements().first { $0.role == "AXStaticText" && $0.value == "V1" }!
        return header.frame.minX - 14 + TimelinePanel.headerWidth
    }

    /// The vertical centre of a lane, by its header's label ("V1", "A2", "T1").
    func laneY(_ label: String) -> CGFloat {
        rig.elements().first { $0.role == "AXStaticText" && $0.value == label }!.centre.y
    }

    /// The ruler's centre line.
    var rulerY: CGFloat { laneY("T1") - 15 - TimelinePanel.rulerHeight / 2 }

    func x(_ t: Double) -> CGFloat { lanesX + TimelinePanel.originX + CGFloat(t * store.pxPerSec) }

    var footage: Clip { store.project!.tracks.first { $0.kind == .video }!.clips[0] }
}

@Suite(.serialized) @MainActor struct TimelineMouseTests {
    @Test func aClickSelectsAClipAndTheEmptyLaneLetsGo() async throws {
        let t = try await TimelineRig()
        defer { t.close() }
        t.rig.click(CGPoint(x: t.x(2), y: t.laneY("V1")))
        await t.app.settle()
        #expect(t.store.selection == [t.footage.id], "a click on the clip did not select it")
        // Below the last lane: nothing there.
        t.rig.click(CGPoint(x: t.x(8), y: t.laneY("V2")))
        await t.app.settle()
        #expect(t.store.selection.isEmpty, "a click on an empty lane did not deselect")
    }

    @Test func aDragMovesAClipAndAnEdgeTrimsIt() async throws {
        let t = try await TimelineRig()
        defer { t.close() }
        let n = t.store.activity.count
        t.rig.drag(from: CGPoint(x: t.x(2), y: t.laneY("V1")), by: CGSize(width: 40, height: 0))
        await t.app.settle()
        #expect(t.app.commands(since: n).contains("timeline.move"), "a drag on a clip did not move it")
        #expect(abs(t.footage.start.seconds - 1) < 0.05, "the clip starts at \(t.footage.start.seconds)")
        let m = t.store.activity.count
        let end = t.footage.end.seconds
        t.rig.drag(from: CGPoint(x: t.x(end) - 3, y: t.laneY("V1")), by: CGSize(width: -40, height: 0))
        await t.app.settle()
        #expect(t.app.commands(since: m).contains("timeline.trim"), "a drag on the clip's end did not trim it")
        #expect(abs(t.footage.end.seconds - (end - 1)) < 0.05, "the clip ends at \(t.footage.end.seconds)")
    }

    @Test func theRazorCutsWhereItClicks() async throws {
        let t = try await TimelineRig()
        defer { t.close() }
        #expect(t.rig.click("Lama"))
        #expect(t.store.tool == .razor)
        t.rig.click(CGPoint(x: t.x(3), y: t.laneY("V1")))
        await t.app.settle()
        let clips = t.store.project!.tracks.first { $0.kind == .video }!.clips
        #expect(clips.count == 2, "the razor did not cut (\(clips.count) clips)")
        #expect(abs((clips.first?.end.seconds ?? 0) - 3) < 0.05)
    }

    @Test func theRulerScrubs() async throws {
        let t = try await TimelineRig()
        defer { t.close() }
        t.rig.drag(from: CGPoint(x: t.x(1), y: t.rulerY), by: CGSize(width: 80, height: 0))
        await t.app.settle()
        #expect(abs(t.store.preview.playhead.time - 3) < 0.1, "the playhead is at \(t.store.preview.playhead.time) after a scrub to 3 s")
    }

    @Test func theTextToolMakesACaptionWordAKeyword() async throws {
        let t = try await TimelineRig()
        defer { t.close() }
        #expect(t.rig.click("Testo: parole chiave dei sottotitoli"))
        let n = t.store.activity.count
        // "Le pause spariscono": the second line starts at 3 s.
        t.rig.click(CGPoint(x: t.x(3.1), y: t.laneY("T1")))
        await t.app.settle()
        #expect(t.app.commands(since: n) == ["captions.setKeywords"])
    }

    @Test func aRightClickOnAClipOpensItsMenuAndItsItemsRun() async throws {
        let t = try await TimelineRig()
        defer { t.close() }
        RigGuard.lastMenu = nil
        t.rig.rightClick(CGPoint(x: t.x(2), y: t.laneY("V1")))
        let menu = try #require(RigGuard.lastMenu, "a right click on a clip opened no menu")
        #expect(t.store.selection == [t.footage.id], "the right click did not select the clip")
        let i = try #require(menu.items.firstIndex { $0.title == "Duplica" })
        let n = t.store.activity.count
        menu.performActionForItem(at: i)
        await t.app.settle()
        #expect(t.app.commands(since: n) == ["timeline.duplicate"])
    }

    /// The editor's keys, through the application as a keyboard sends them.
    @Test func theTimelineKeys() async throws {
        let t = try await TimelineRig()
        defer { t.close() }
        let r = t.rig
        for (key, tool) in [("c", EditorStore.Tool.razor), ("t", .text), ("h", .hand), ("v", .select)] {
            r.key(key, keyCode: 0)
            #expect(t.store.tool == tool, "\(key) did not pick the \(tool) tool")
        }
        t.store.preview.seek(2)
        await t.app.settle()
        r.key(.right)
        await t.app.settle()
        #expect(abs(t.store.preview.playhead.time - (2 + 1.0 / 30)) < 0.01, "→ did not step one frame")
        r.key(.left, modifiers: .shift)
        await t.app.settle()
        #expect(abs(t.store.preview.playhead.time - (1 + 1.0 / 30)) < 0.02, "⇧← did not step one second back")
        let zoom = t.store.pxPerSec
        r.key("=", keyCode: 24)
        #expect(t.store.pxPerSec > zoom, "= did not zoom in")
        r.key("-", keyCode: 27)
        #expect(abs(t.store.pxPerSec - zoom) < 0.01, "- did not zoom back out")
        // ⌘K cuts at the playhead; ⌫ deletes the selection; Space plays and pauses.
        t.store.preview.seek(2)
        await t.app.settle()
        var n = t.store.activity.count
        r.key("k", keyCode: 40, modifiers: .command)
        await t.app.settle()
        #expect(t.app.commands(since: n).contains("timeline.cut"), "⌘K did not cut")
        t.store.selection = [t.store.project!.tracks.first { $0.kind == .video }!.clips[0].id]
        n = t.store.activity.count
        r.key(.delete)
        await t.app.settle()
        #expect(t.app.commands(since: n).contains("timeline.delete"), "⌫ did not delete the selection")
        r.key(.space)
        await t.app.settle()
        #expect(t.store.preview.isPlaying, "Space did not play")
        r.key(.space)
        await t.app.settle()
        #expect(!t.store.preview.isPlaying, "Space did not pause")
    }
}
