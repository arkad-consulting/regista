import AppKit
import CoreText
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

/// The teleprompter is private to the speaker: it must never appear in a screen recording,
/// a screenshot or a screen share (NSWindow.sharingType = .none).
@MainActor
@Test func teleprompterWindowIsExcludedFromScreenCapture() {
    _ = NSApplication.shared
    let panel = TeleprompterController.makePanel(frame: NSRect(x: 0, y: 0, width: 640, height: 360), capturable: false)
    #expect(panel.sharingType == .none)
    #expect(panel.level == .floating)
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(panel.styleMask.contains(.nonactivatingPanel))
    // Only the developer flag (--prompter-demo) makes it visible to screenshots.
    #expect(TeleprompterController.makePanel(frame: .zero, capturable: true).sharingType == .readOnly)
}

@MainActor
@Test func teleprompterOpensTopCentreAndRemembersItsPlacePerDisplay() {
    _ = NSApplication.shared
    guard let screen = NSScreen.main else { return }
    let f = TeleprompterController.defaultFrame(on: screen)
    #expect(abs(f.midX - screen.visibleFrame.midX) < 1)
    #expect(abs(f.maxY - (screen.visibleFrame.maxY - 6)) < 1)
    let moved = f.offsetBy(dx: -200, dy: -40)
    let key = "prompterFrame-\((screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber) ?? 0)"
    let previous = UserDefaults.standard.string(forKey: key)
    defer { UserDefaults.standard.set(previous, forKey: key) }
    TeleprompterController.saveFrame(moved, on: screen)
    #expect(TeleprompterController.savedFrame(on: screen) == moved)
}

private let sample = PromptScript.prepare("""
1. Ti hanno detto che un sito è sicuro se lo tieni aggiornato.
2. Mercoledì scorso erano al sicuro quelli che non avevano niente da aggiornare.
3. PHP, il motore sotto ogni sito WordPress, ha chiuso d'urgenza due falle da nove virgola due su dieci.
4. Un sito in HTML statico non aveva niente da sistemare.
""", keywords: ["sicuro", "aggiornare", "PHP", "nove virgola due", "statico"])

/// The window drawn offscreen (what the speaker sees), as an RGBA bitmap.
@MainActor
private func render(mirror: Bool, script: String = sample, size: NSSize = TeleprompterController.defaultSize) -> NSBitmapImageRep {
    _ = NSApplication.shared
    // The brand fonts ship in the app bundle; tests load them from the repository.
    let fonts = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts").standardizedFileURL
    for url in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "ttf" {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
    // The voice-following look the test checks (the word read in gold), whatever mode the process's defaults hold (#64).
    let c = TeleprompterController.preview(text: script, mirror: mirror, fontSize: 40, mode: .voice)
    let view = NSHostingView(rootView: TeleprompterView(controller: c, settled: true))
    view.frame = NSRect(origin: .zero, size: size)
    let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    w.isReleasedWhenClosed = false
    w.appearance = NSAppearance(named: .darkAqua)
    w.contentView = view
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    view.layoutSubtreeIfNeeded()
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    w.contentView = nil
    w.close()
    return rep
}

/// Pixels close to the highlight gold (#F4BD56).
private func goldPixels(_ rep: NSBitmapImageRep) -> [(x: Int, y: Int)] {
    var out: [(x: Int, y: Int)] = []
    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
        for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if c.redComponent > 0.85, abs(c.greenComponent - 0.74) < 0.08, c.blueComponent < 0.45 { out.append((x, y)) }
        }
    }
    return out
}

@MainActor
@Test func teleprompterRendersNormalAndMirrored() throws {
    let normal = render(mirror: false), mirrored = render(mirror: true)
    // Set REGISTA_TELEPROMPTER_SNAPSHOTS=<dir> (and REGISTA_TELEPROMPTER_SCRIPT=<file>) to keep the PNGs.
    if let dir = ProcessInfo.processInfo.environment["REGISTA_TELEPROMPTER_SNAPSHOTS"] {
        let script = ProcessInfo.processInfo.environment["REGISTA_TELEPROMPTER_SCRIPT"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        let pairs: [(String, NSBitmapImageRep)] = script.map { s in [("teleprompter-normal", render(mirror: false, script: s)), ("teleprompter-mirror", render(mirror: true, script: s))] }
            ?? [("teleprompter-normal", normal), ("teleprompter-mirror", mirrored)]
        for (name, rep) in pairs {
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
    // The word being read is highlighted in gold, around the reading line, and moves to the other
    // side when mirrored (the controls do not).
    let g = goldPixels(normal), gm = goldPixels(mirrored)
    let words = { (px: [(x: Int, y: Int)], rep: NSBitmapImageRep) in px.filter { $0.x > 30 && $0.x < rep.pixelsWide - 30 } }
    let wn = words(g, normal), wm = words(gm, mirrored)
    #expect(!wn.isEmpty && !wm.isEmpty)
    let mean = { (px: [(x: Int, y: Int)]) in Double(px.map(\.x).reduce(0, +)) / Double(max(px.count, 1)) }
    let width = Double(normal.pixelsWide)
    #expect(abs(mean(wn) - (width - mean(wm))) < width * 0.08)
    let rowY = Double(wn.map(\.y).reduce(0, +)) / Double(wn.count)
    #expect(rowY > Double(normal.pixelsHigh) * 0.2 && rowY < Double(normal.pixelsHigh) * 0.6)
}

/// #63: Gobbo's line over the script says one take and one word in the singular. #66: it counts the script's lines,
/// one take each, and names them so: two sentences on one line are «1 ripresa», not «1 frase».
@MainActor
@Test func theTeleprompterCountsSayOneInTheSingular() {
    #expect(PrompterEditorView.counts(takes: 1, words: 1) == "1 ripresa · 1 parola · circa 1 min")
    #expect(PrompterEditorView.counts(takes: 1, words: 10) == "1 ripresa · 10 parole · circa 1 min")
    #expect(PrompterEditorView.counts(takes: 3, words: 480) == "3 riprese · 480 parole · circa 3 min")
    let script = PromptScript("Oggi Regista monta il reel. Le pause spariscono da sole.")
    #expect(PrompterEditorView.counts(takes: script.sentences.count, words: 10) == "1 ripresa · 10 parole · circa 1 min")
}
