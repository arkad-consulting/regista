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
func loc(_ key: String) -> String { Bundle.main.localizedString(forKey: key, value: key, table: nil) }

/// A format key filled with `args` (`%@` placeholders take strings: format numbers before, `shortTime`, `"\(n)"`).
func loc(_ format: String, _ args: CVarArg...) -> String {
    String(format: loc(format), locale: Locale.current, arguments: args)
}
