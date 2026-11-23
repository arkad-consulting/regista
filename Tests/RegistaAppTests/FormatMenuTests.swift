import AppKit
@testable import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The format in every edit (#151): the toolbar's format label is a compact menu (9:16, 4:5, 1:1, 16:9, the current one
// checked) and the Inspector's project row has the same choice; a choice runs project.format with that preset, one undo
// step. Driven with the mouse on the real window (AppRig, the rich fixture project, 9:16).

/// The popover the last click opened, driven like the window.
@MainActor func openedPopover(_ app: AppRig) async -> MouseRig? {
    var found: NSWindow?
    _ = await app.until(3) {
        found = NSApp.windows.first { $0 !== app.rig.window && $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
        return found != nil
    }
    guard let w = found else { return nil }
    await app.idle(0.3)
    return MouseRig(adopting: w)
}

/// The window with an open popover drawn under the control that opened it, `anchor` (window points, top-left origin), as
/// macOS shows it (a popover is a window of its own: a snapshot of the main window alone leaves it out; offscreen, its
/// own frame is pushed back on screen and says nothing of where it would show), as a PNG.
@MainActor func snapshot(_ app: AppRig, with popover: NSWindow, below anchor: CGRect, to url: URL) throws {
    func rep(_ v: NSView) -> NSBitmapImageRep? {
        guard let r = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        v.cacheDisplay(in: v.bounds, to: r)
        return r
    }
    guard let base = rep(app.rig.host), let pop = popover.contentView, let over = rep(pop) else { return }
    let size = app.rig.host.bounds.size
    let image = NSImage(size: size)
    image.lockFocus()
    base.draw(in: CGRect(origin: .zero, size: size))
    let w = pop.bounds.width, h = pop.bounds.height
    let origin = CGPoint(x: min(max(anchor.midX - w / 2, 0), size.width - w), y: size.height - anchor.maxY - 2 - h)
    over.draw(in: CGRect(origin: origin, size: pop.bounds.size))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
    try png.write(to: url)
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct FormatMenuTests {
    /// The toolbar's format menu.
    private func menu(_ app: AppRig) -> RigElement? {
        app.rig.elements().first { $0.isControl && $0.visible && $0.value.contains("×") && $0.value.hasSuffix(" fps") }
    }

    private func size(_ app: AppRig) -> String { "\(app.store.project?.settings.width ?? 0)×\(app.store.project?.settings.height ?? 0)" }

    @Test func theToolbarsFormatLabelIsAMenuOfTheFourFormats() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector))
        await app.settle()
        #expect(size(app) == "1080×1920")
        let label = try #require(menu(app), "no format menu in the toolbar")
        #expect(label.value.contains("9:16") && label.value.contains("1080×1920"), "\(label)")
        let undo0 = app.store.undoNames.count
        // Each format in turn: a click opens the list, the choice runs project.format with its preset, the label follows.
        for (preset, expected) in [("16:9", "1920×1080"), ("1:1", "1080×1080"), ("4:5", "1080×1350"), ("9:16", "1080×1920")] {
            app.rig.takeKey()
            app.rig.click(try #require(menu(app)).centre)
            let pop = try #require(await openedPopover(app), "the menu did not open")
            let rows = pop.elements().filter { $0.isControl && $0.visible }
            #expect(rows.count == 4, "the menu lists \(rows.map(\.name))")
            #expect(rows.first { $0.selected }?.name.hasPrefix(ScreenLook.formatID(app.store.project!)!) == true, "the current format is not checked")
            let row = try #require(rows.first { $0.name.hasPrefix(preset) }, "no \(preset) in the menu")
            let n = app.store.activity.count
            pop.click(row.centre)
            await app.until(20) { size(app) == expected && app.store.running == nil }
            await app.settle()
            let ran = app.store.activity.dropFirst(n).filter { $0.command == "project.format" }
            #expect(ran.count == 1 && ran.first?.params.contains(preset) == true, "\(preset): ran \(ran.map(\.params))")
            #expect(size(app) == expected, "\(preset) gave \(size(app))")
            #expect(menu(app)?.value.contains(preset) == true && menu(app)?.value.contains(expected) == true, "the label reads \(menu(app)?.value ?? "nothing")")
        }
        #expect(app.store.undoNames.count == undo0 + 4, "each choice is one undo step")
        // Undo restores the format before.
        app.store.undo()
        await app.until(10) { size(app) == "1080×1350" }
        #expect(size(app) == "1080×1350" && menu(app)?.value.contains("4:5") == true)
    }

    @Test func theInspectorsProjectRowHasTheSameChoice() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector))
        await app.settle()
        let inspector = app.rig.elements().filter { $0.isControl && $0.visible && $0.frame.minX > app.rig.size.width - 330 }
        let square = try #require(inspector.first { $0.name == "1:1" }, "no 1:1 in the Inspector: \(inspector.map(\.name))")
        let n = app.store.activity.count
        app.rig.click(square.centre)
        await app.until(20) { app.store.project?.settings.height == 1080 }
        #expect(app.store.activity.dropFirst(n).filter { $0.command == "project.format" }.count == 1)
        #expect(size(app) == "1080×1080")
        #expect(menu(app)?.value.contains("1:1") == true, "the toolbar label did not follow")
        app.store.undo()
        await app.until(10) { size(app) == "1080×1920" }
        #expect(size(app) == "1080×1920")
    }

    /// Snapshots of the toolbar with the menu open, in Italian and French ($REGISTA_UI_SNAPSHOTS).
    @Test func snapshotsOfTheOpenMenu() async throws {
        guard let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] else { return }
        for language in ["it", "fr"] {
            let app = try await AppRig()
            defer { app.close() }
            app.hostEditor(Navigation(activity: .media, rightTab: .inspector), language: language)
            await app.settle()
            let label = try #require(app.rig.elements().first { $0.isControl && $0.visible && $0.value.contains("1080×1920") }, "no format menu (\(language))")
            app.rig.click(label.centre)
            let pop = try #require(await openedPopover(app))
            try snapshot(app, with: pop.window, below: label.frame, to: URL(fileURLWithPath: dir).appendingPathComponent("format-menu-\(language).png"))
            pop.window.orderOut(nil)
            app.rig.hold(0.5)
        }
    }
}
}
