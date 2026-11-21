import Foundation

// A small reader of Swift source for the tests that scan Sources and Tests (#135, #138): the code without its comments
// and without the contents of its string literals, so a name in a doc comment or a message is not taken for a use.

/// The source without comments and without the contents of its string literals.
func swiftCode(_ source: String) -> String {
    let c = Array(source)
    var out: [Character] = [], i = 0
    func at(_ s: String) -> Bool { let a = Array(s); return i + a.count <= c.count && Array(c[i..<(i + a.count)]) == a }
    /// Moves past the next `close` (or to the end of the line when `sameLine` and none closes there).
    func skip(to close: String, sameLine: Bool) {
        while i < c.count, !at(close) {
            if sameLine, c[i] == "\n" { return }
            if sameLine, close == "\"", c[i] == "\\" { i += 1 }
            i += 1
        }
        i = min(i + close.count, c.count)
    }
    while i < c.count {
        if at("//") { while i < c.count, c[i] != "\n" { i += 1 } }
        else if at("/*") { i += 2; skip(to: "*/", sameLine: false); out.append(" ") }
        else if at("\"\"\"") { i += 3; skip(to: "\"\"\"", sameLine: false); out.append(" ") }
        else if at("#\"") { i += 2; skip(to: "\"#", sameLine: true); out.append(" ") }
        else if c[i] == "\"" { i += 1; skip(to: "\"", sameLine: true); out.append(" ") }
        else { out.append(c[i]); i += 1 }
    }
    return String(out)
}
