import AppKit
import SwiftUI
import Testing
@testable import Regista

// Splitters (issue #2, the owner's feedback "the window edges are all locked"): stored sizes are clamped to what the
// window allows, 0 means automatic, a drag stores the clamped size, double-click (reset) gives automatic back.

@Test func splitSizeClampsResolvesAndResets() {
    let range = SplitSize.range(200, 500)
    #expect(SplitSize.resolve(SplitSize.automatic, automatic: 320, in: range) == 320)
    #expect(SplitSize.resolve(420, automatic: 320, in: range) == 420)
    #expect(SplitSize.resolve(900, automatic: 320, in: range) == 500)
    #expect(SplitSize.resolve(50, automatic: 320, in: range) == 200)
    // The automatic size is kept inside the range too.
    #expect(SplitSize.resolve(SplitSize.automatic, automatic: 640, in: range) == 500)
    // A window too small for both bounds: the minimum wins, never an empty range.
    #expect(SplitSize.range(200, 120) == 200...200)
    // Drags store the clamped, rounded size.
    #expect(SplitSize.dragged(from: 300, by: 37.4, in: range) == 337)
    #expect(SplitSize.dragged(from: 300, by: -400, in: range) == 200)
    #expect(SplitSize.dragged(from: 300, by: 900, in: range) == 500)
}

@Test func proLayoutAutomaticSizes() {
    // 0 everywhere = the sizes computed from the editor's area (the main area of the window shell).
    for size in [CGSize(width: 1440 - 52 - 300 - 320, height: 900 - 38 - 24 - 36 - 40), CGSize(width: 1920 - 52 - 300 - 320, height: 1050 - 38 - 24 - 36 - 40)] {
        let l = ProLayout.compute(size)
        let lower = min(max(size.height * 0.41, 290), 400)
        #expect(l.lower == lower)
        #expect(l.program == max((size.height - lower - 2 - 28 - 58 - 20) * 9 / 16 + 20, 230))
        #expect(size.width - l.program - ProLayout.gutter >= ProLayout.minSource)
    }
}

@Test func proLayoutClampsDraggedSizesToTheWindow() {
    let size = CGSize(width: 768, height: 762)
    let l = ProLayout.compute(size, program: 5000, lower: 5000)
    #expect(l.lower == size.height - ProLayout.gutter - ProLayout.minUpper)
    // Whatever is stored, the source monitor keeps its minimum width.
    #expect(size.width - l.program - ProLayout.gutter >= ProLayout.minSource - 0.5)
    let tiny = ProLayout.compute(size, program: 1, lower: 1)
    #expect(tiny.program == 190 && tiny.lower == 180)
    // Reset = automatic again.
    #expect(ProLayout.compute(size, program: SplitSize.automatic) == ProLayout.compute(size))
}

// Tooltips (owner feedback: "when I hover an icon the function doesn't appear").

@Test func tipContentSeparatesTheShortcut() {
    let undo = TipContent("Annulla ", shortcut: " ⌘Z")
    #expect(undo.text == "Annulla" && undo.shortcut == "⌘Z")
    #expect(undo.spoken == "Annulla (⌘Z)")
    let plain = TipContent("Zone di sicurezza", shortcut: "")
    #expect(plain.shortcut == nil && plain.spoken == "Zone di sicurezza")
    #expect(TipContent("  ").isEmpty)
    #expect(!TipContent("", shortcut: "⌘1").isEmpty)
    #expect(TipContent("", shortcut: "⌘1").spoken == "⌘1")
}

@Test func tipPlacementStaysOnScreen() {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let size = CGSize(width: 120, height: 24)
    // Centred under the control.
    let mid = TipPlacement.frame(size: size, anchor: CGRect(x: 700, y: 500, width: 20, height: 20), screen: screen)
    #expect(mid.midX == 710 && mid.maxY == 494)
    // Near the bottom edge: above the control instead.
    let low = TipPlacement.frame(size: size, anchor: CGRect(x: 700, y: 10, width: 20, height: 20), screen: screen)
    #expect(low.minY == 36)
    // Near the left / right edges: slid inside the screen.
    #expect(TipPlacement.frame(size: size, anchor: CGRect(x: 0, y: 500, width: 20, height: 20), screen: screen).minX == 4)
    #expect(TipPlacement.frame(size: size, anchor: CGRect(x: 1430, y: 500, width: 10, height: 20), screen: screen).maxX == 1436)
}

// Window shell: the side panel's width range follows the window, and never goes below its minimum.

@Test func sidePanelRangeFollowsTheWindow() {
    #expect(Chrome.sideRange(1440) == 240...432)
    #expect(Chrome.sideRange(1920) == 240...440)
    #expect(Chrome.sideRange(700) == 240...240)
    #expect(Chrome.sideRange(1440).contains(Chrome.sideDefault))
}

@MainActor
@Test func trafficLightsAreMeasuredFromTheWindowButtons() {
    _ = NSApplication.shared
    let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                     backing: .buffered, defer: false)
    w.titlebarAppearsTransparent = true
    w.titleVisibility = .hidden
    let edge = WindowChrome.trafficLightsEdge(w)
    #expect(edge != nil)
    if let edge { #expect(edge > 40 && edge < 120) }
    #expect(WindowChrome.trafficLightsEdge(NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)) == nil)
}

/// The tip label draws the function and, apart, the shortcut keycap; long texts wrap within the maximum width.
/// Set REGISTA_UI_SNAPSHOTS=<dir> to keep the PNG (tips live in their own window, ui.screenshot cannot see them).
@MainActor
@Test func tipLabelRendersNameAndShortcut() throws {
    _ = NSApplication.shared
    let samples = [TipContent("Annulla l'ultima modifica", shortcut: "⌘Z"), TipContent("Zone di sicurezza (sottotitoli, interfaccia Instagram)"),
                   TipContent("Registra con camera e gobbo", shortcut: "⌘1"),
                   TipContent("Comandi vocali: «rifaccio» scarta la ripresa e torna all'inizio della frase, «stop» ferma la registrazione.")]
    var reps: [NSBitmapImageRep] = []
    for s in samples {
        let host = NSHostingController(rootView: TipLabel(content: s))
        let size = host.sizeThatFits(in: CGSize(width: TipLabel.maxWidth, height: 2000))
        #expect(size.width <= TipLabel.maxWidth + 1 && size.height >= 20)
        host.view.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: host.view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.contentView = host.view
        host.view.layoutSubtreeIfNeeded()
        let rep = try #require(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
        host.view.cacheDisplay(in: host.view.bounds, to: rep)
        reps.append(rep)
    }
    // The long one wraps onto several lines.
    #expect(reps[3].size.height > reps[0].size.height * 1.3)
    if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
        for (i, rep) in reps.enumerated() {
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("polish-tip-\(i + 1).png"))
        }
    }
}
