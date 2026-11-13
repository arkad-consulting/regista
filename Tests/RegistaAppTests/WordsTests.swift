import Foundation
import RegistaCore
import Testing
@testable import Regista

// L0 (#48): every command has a human title in every UI language, and the tables agree with each other.

private let localization = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Localization")

/// The entries of `<lang>.lproj/Localizable.strings` (the plist form Foundation reads the file in).
private func table(_ lang: String) -> [String: String] {
    let url = localization.appendingPathComponent("\(lang).lproj/Localizable.strings")
    return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
}

/// The complete languages: the same list as LANGS in scripts/l10n.py (Portuguese joins both when pt.lproj is done).
private let languages = ["it", "en", "fr"]

@Test func everyCommandHasATitleInEveryLanguage() {
    let ids = Set(RegistaCore.Commands.all.map { $0.id }).union(CommandTitles.ids)
    var missing: [String] = []
    for lang in languages {
        let t = table(lang)
        #expect(!t.isEmpty, "\(lang).lproj/Localizable.strings is missing or unreadable")
        for id in ids.sorted() {
            guard let key = CommandTitles.key(id) else { missing.append("\(id): no title"); continue }
            if (t[key] ?? "").isEmpty { missing.append("\(id) (\(key)): no \(lang) text") }
        }
        if (t[CommandTitles.fallbackKey] ?? "").isEmpty { missing.append("fallback: no \(lang) text") }
    }
    #expect(missing.isEmpty, "command titles missing:\n\(Set(missing).sorted().joined(separator: "\n"))")
}

@Test func theTablesHaveTheSameKeys() {
    let it = Set(table("it").keys)
    for lang in languages.dropFirst() {
        let keys = Set(table(lang).keys)
        #expect(keys == it, "\(lang) differs from it: only in \(lang) \(keys.subtracting(it).sorted().prefix(10)), missing \(it.subtracting(keys).sorted().prefix(10))")
    }
}

@Test func undoAndCancelAreDifferentWords() {
    // #65: the Edit menu's undo used the Italian key "Annulla", which is Cancel in English.
    for lang in languages.dropFirst() {
        let t = table(lang)
        #expect(t["menu.undo"] != nil && t["menu.undo"] != t["Annulla"] || lang == "fr", "\(lang): Undo and Cancel are the same word")
    }
    #expect(table("en")["menu.undo"] == "Undo")
}
