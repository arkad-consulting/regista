import Foundation
import Testing
@testable import Regista

// #36: the shortcut hints written outside the catalog — the status bar's line, the tooltips that name a key
// (`shortcut:`), the menus of a clip, the guides under docs/<lang>/ — name keys of the catalog (`AppShortcuts`, the
// source of the menu bar, Settings › Shortcuts and docs/reference), so they cannot drift from what the keys do.

private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The keys a text names: modifier glyphs followed by a key («⇧⌘R», «⌥Spazio», «⌘1»), or a bare key glyph («⌫»).
/// A modifier written before a click («⇧clic», «⌥-click») is a mouse gesture, not a key.
func shortcutTokens(_ text: String, space: String) -> [String] {
    let names = [space, "Spazio", "Space", "Espace", "Espaço"].map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    let re = try! NSRegularExpression(pattern: "([⌃⌥⇧⌘]+)(\(names)|[⇥←→↑↓⌫⌦↖↘⎋]|[A-Za-z0-9,.\\[\\]\\\\=\\-?`/]|−|\\+)(?![A-Za-z\\-])|(?<![⌃⌥⇧⌘])([⌫⌦⎋])")
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
        guard let r = Range(m.range, in: text) else { return nil }
        let token = String(text[r])
        // Spelled with the catalog's name of the space bar.
        return token.replacingOccurrences(of: #"(Spazio|Space|Espace|Espaço)$"#, with: "Spazio", options: .regularExpression)
    }
}

/// The catalog's keys, as `AppShortcut.display` writes them with the Italian key names.
@MainActor private var catalogKeys: Set<String> {
    Set(AppShortcuts.all.map { s in
        var m = ""
        if s.modifiers.contains(.control) { m += "⌃" }
        if s.modifiers.contains(.option) { m += "⌥" }
        if s.modifiers.contains(.shift) { m += "⇧" }
        if s.modifiers.contains(.command) { m += "⌘" }
        return m + (s.key == .space ? "Spazio" : AppShortcut.keyName(s.key))
    })
}

/// Keys of macOS or of another app that the guides tell a person to press (not Regista's).
private let otherApps: Set<String> = ["⌘Q", "⇧⌘4", "⇧⌘5"]
/// Keys named with their ⇧ variant in a catalog title («⇧⌫ elimina e chiude il vuoto», «⇧: un secondo»).
private let variants: Set<String> = ["⇧⌫", "⇧←", "⇧→"]

@Test @MainActor func everyShortcutHintNamesAKeyOfTheCatalog() throws {
    let keys = catalogKeys.union(variants)
    var problems: [String] = []
    func check(_ text: String, _ where_: String, extra: Set<String> = []) {
        for t in shortcutTokens(text, space: "Spazio") where !keys.contains(t) && !extra.contains(t) {
            problems.append("\(where_): «\(t)» in «\(text.prefix(90))»")
        }
    }
    // The status bar's line, in every language (its keys are the Italian texts in Shell.swift).
    let shell = try String(contentsOf: root.appendingPathComponent("Sources/Regista/UI/Shell.swift"), encoding: .utf8)
    let hintBlock = try #require(shell.range(of: "private var hint: String {").map { shell[$0.upperBound...] }.map { String($0.prefix(1500)) })
    let hints = try NSRegularExpression(pattern: #"loc\("([^"]+)"\)"#).matches(in: hintBlock, range: NSRange(hintBlock.startIndex..., in: hintBlock))
        .compactMap { Range($0.range(at: 1), in: hintBlock).map { String(hintBlock[$0]) } }
    #expect(hints.count >= 6, "the status bar's hints were not found")
    for lang in ["it", "en", "fr", "pt"] {
        let table = MouseRig.table(lang)
        for h in hints { check(table.localizedString(forKey: h, value: h, table: nil), "status bar (\(lang))") }
    }
    // Every tooltip and menu line that names its key in the sources.
    let sources = FileManager.default.enumerator(at: root.appendingPathComponent("Sources/Regista"), includingPropertiesForKeys: nil)!
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    let named = try NSRegularExpression(pattern: #"shortcut: "([^"]+)""#)
    var tooltips = 0
    for f in sources {
        let text = try String(contentsOf: f, encoding: .utf8)
        for m in named.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            tooltips += 1
            let hint = String(text[r]).replacingOccurrences(of: "\\\\", with: "\\")   // the source's "\\" is one backslash
            // A hint is keys only, separated by spaces: each one is the catalog's.
            for part in hint.split(separator: " ").map(String.init) where !keys.contains(part) {
                problems.append("\(f.lastPathComponent): shortcut «\(part)» of «\(hint)»")
            }
        }
    }
    #expect(tooltips >= 20, "the tooltips' shortcuts were not found (\(tooltips))")
    // The guides, in every language.
    for lang in ["it", "en", "fr", "pt"] {
        let dir = root.appendingPathComponent("docs/\(lang)")
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where f.pathExtension == "md" {
            check(try String(contentsOf: f, encoding: .utf8), "docs/\(lang)/\(f.lastPathComponent)", extra: otherApps)
        }
    }
    #expect(problems.isEmpty, "hints that name no key of the catalog:\n\(problems.joined(separator: "\n"))")
}

@Test func shortcutTokensAreReadAsAPersonReadsThem() {
    #expect(shortcutTokens("⇧⌘R registra/stop · ⇧⌘P pausa · ⌥Spazio avvia", space: "Spazio") == ["⇧⌘R", "⇧⌘P", "⌥Spazio"])
    #expect(shortcutTokens("⌘1…⌘9 cambiano attività · ⌘N nuovo", space: "Spazio") == ["⌘1", "⌘9", "⌘N"])
    #expect(shortcutTokens("selezioni (⌥clic, ⇧clic) e le togli con ⌫", space: "Spazio") == ["⌫"])
    #expect(shortcutTokens("press ⌥Space or ⇧-click", space: "Space") == ["⌥Spazio"])
}
