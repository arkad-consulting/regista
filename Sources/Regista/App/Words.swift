import Foundation

// The one lookup for every word the user reads (L0 #48): Resources/Localization/<it|en|fr|pt>.lproj/Localizable.strings,
// in the language macOS gives the app.
//
// Keys. A key is the Italian text itself ("Importa media…"), so the source reads as the Italian UI. Where one Italian
// text has two meanings that other languages tell apart, the key is semantic instead, `area.meaning` ("menu.undo" vs
// "Annulla" = cancel, "track.footage" vs "Riprese" = takes), and the Italian table spells it out. Interpolated texts are
// format keys with `%@` placeholders (`loc("%@ clip in timeline", n)`), written with positions (`%1$@`) when a language
// reorders them. Text that is data (file and project names, the user's words, a transcript) is never looked up on purpose:
// it goes through `Text(verbatim:)`.
//
// The custom controls (Controls.swift) take keys and look them up themselves, so a key built anywhere — a model, a
// table, a track's default name — is translated where it is drawn. `loc` is idempotent: a translated text is never
// another key with a different translation (scripts/l10n.py checks it), so text that is already translated may pass
// through a control again unchanged.

/// The text of `key` in the app's language (the key itself when the table has no entry).
func loc(_ key: String) -> String { Words.table.localizedString(forKey: key, value: key, table: nil) }

/// Where `loc` and the tooltips read their words: the app's own tables. A test lays a window out in another language by
/// setting `override` while that window is hosted (MouseRig), with `applies` saying which callers read it (the window's
/// views, not the other tests running beside it); it is read on the main thread only, so every other thread keeps the
/// app's language.
enum Words {
    nonisolated(unsafe) static var override: Bundle?
    nonisolated(unsafe) static var applies: (() -> Bool)?

    static var table: Bundle {
        guard let o = override, Thread.isMainThread, applies?() ?? true else { return .main }
        return o
    }

    /// The language the words are in ("it", "en", "fr", "pt"): the table's.
    static var language: String {
        let t = table
        if t.bundlePath.hasSuffix(".lproj") { return t.bundleURL.deletingPathExtension().lastPathComponent }
        return t.preferredLocalizations.first ?? "en"
    }

    /// How numbers are written in that language (the Mac's own formats when its language is the same): a decimal comma
    /// in Italian, French and Portuguese, a point in English.
    static var locale: Locale {
        let language = language
        return Locale.current.language.languageCode?.identifier == language ? Locale.current : Locale(identifier: language)
    }

    /// "0,3", "1,25", "28": a number the engine gives as a value (#47), at most two decimals, in the words' language.
    static func number(_ v: Double) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

/// A format key filled with `args` (`%@` placeholders take strings: format numbers before, `shortTime`, `"\(n)"`).
func loc(_ format: String, _ args: CVarArg...) -> String {
    String(format: loc(format), locale: Locale.current, arguments: args)
}
