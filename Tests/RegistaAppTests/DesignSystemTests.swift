import Foundation
import Testing

// D0 (#46): one design system. Scans the app's sources (Sources/Regista) so a new screen cannot bring its own palette,
// fonts or stock controls back.
//
// Rules and their allowed exceptions:
// - No native `Picker` / `Toggle` / `Slider` / `Stepper` (nor a picker or toggle style) outside Sources/Regista/Settings/:
//   the main window uses the control set of Controls.swift; the Settings window keeps the native grouped form on purpose.
// - No colour literal outside UI/Tokens.swift: `Color(hex:)`, `Color(red:…)`, `Color(white:)`, `Color(hue:…)`,
//   `Color(.sRGB…)` and their NSColor forms. Allowed: `Color(hexString:)` (colours that are data: a brand kit's
//   palette, a backdrop the user chose) and the neutral `.white` / `.black` / `.clear` (shadows, scrims, drawn media).
// - No font literal outside UI/Tokens.swift: `.system(size:)`, `Font.system(`, `.custom(`, `NSFont(name:)`,
//   `NSFont.systemFont(`, `NSFont(descriptor:)`. Views use `Ed.ui`, `Ed.mono`, `Ed.display`, `Ed.icon`.
// - One type each of segmented control, slider, toggle and switch: the structs named like one are exactly the set below.

private let appSources: [(path: String, text: String)] = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("Sources/Regista")
    let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
    return files.map { (String($0.path.dropFirst(dir.path.count + 1)), try! String(contentsOf: $0, encoding: .utf8)) }
        .sorted { $0.path < $1.path }
}()

/// The source without comments and string literals' contents (a pattern in a doc comment or a string is not a use).
private func code(_ s: String) -> String {
    var out = "", i = s.startIndex
    while i < s.endIndex {
        let rest = s[i...]
        if rest.hasPrefix("//") { i = s[i...].firstIndex(of: "\n") ?? s.endIndex; continue }
        if rest.hasPrefix("/*") { i = s.range(of: "*/", range: i..<s.endIndex)?.upperBound ?? s.endIndex; continue }
        if s[i] == "\"" {
            out.append("\"\"")
            var j = s.index(after: i)
            while j < s.endIndex, s[j] != "\"", s[j] != "\n" { if s[j] == "\\" { j = s.index(after: j) }; if j < s.endIndex { j = s.index(after: j) } }
            i = j < s.endIndex ? s.index(after: j) : j
            continue
        }
        out.append(s[i]); i = s.index(after: i)
    }
    return out
}

/// `file:line: text` for every match of `pattern` in the files `where` accepts.
private func hits(_ pattern: String, where accept: (String) -> Bool) -> [String] {
    let re = try! NSRegularExpression(pattern: pattern)
    var out: [String] = []
    for (path, text) in appSources where accept(path) {
        for (n, line) in code(text).components(separatedBy: "\n").enumerated() {
            let r = NSRange(line.startIndex..., in: line)
            if re.firstMatch(in: line, range: r) != nil { out.append("\(path):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))") }
        }
    }
    return out
}

@Test func noNativePickerToggleOrSliderOutsideSettings() {
    let found = hits(#"(?<![A-Za-z0-9_.])(Picker|Toggle|Slider|Stepper)\s*\(|\.(pickerStyle|toggleStyle)\("#,
                     where: { !$0.hasPrefix("Settings/") })
    #expect(found.isEmpty, "native controls outside Settings (use RSegmented / RToggle / RSlider):\n\(found.joined(separator: "\n"))")
}

@Test func colourLiteralsLiveInTheTokenFile() {
    let found = hits(#"(?<![A-Za-z0-9_])(NS)?Color\s*\(\s*(hex:|red:|white:|hue:|\.sRGB|srgbRed:|calibratedRed:|calibratedWhite:|displayP3Red:)"#,
                     where: { $0 != "UI/Tokens.swift" })
    #expect(found.isEmpty, "colour literals outside UI/Tokens.swift (add a token to Ed):\n\(found.joined(separator: "\n"))")
}

@Test func fontLiteralsLiveInTheTokenFile() {
    let found = hits(#"\.system\s*\(\s*size:|Font\.system\s*\(|\.custom\s*\(|NSFont\s*\(\s*(name|descriptor):|NSFont\.(systemFont|monospacedSystemFont|boldSystemFont)\s*\("#,
                     where: { $0 != "UI/Tokens.swift" })
    #expect(found.isEmpty, "font literals outside UI/Tokens.swift (use Ed.ui / Ed.mono / Ed.display / Ed.icon):\n\(found.joined(separator: "\n"))")
}

@Test func oneSegmentedControlSliderAndToggle() {
    let re = try! NSRegularExpression(pattern: #"\bstruct\s+([A-Za-z]*(Segment|Slider|Toggle|Switch)[A-Za-z]*)\b[^{]*\bView\b"#)
    var names = Set<String>()
    for (_, text) in appSources {
        let c = code(text)
        for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) { names.insert(String(c[Range(m.range(at: 1), in: c)!])) }
    }
    // RSwitch is the switch alone, SwitchKnob its drawing, RSwitchRow a source row with its switch; InspectorSlider is the
    // Ispettore's labelled row around an RSlider; PanelToggle is the title row's show / hide button (an icon button).
    let allowed: Set = ["RSegmented", "RSlider", "RToggle", "RSwitch", "SwitchKnob", "RSwitchRow", "InspectorSlider", "PanelToggle"]
    #expect(names.subtracting(allowed).isEmpty, "a second segmented / slider / toggle type: \(names.subtracting(allowed).sorted())")
}
