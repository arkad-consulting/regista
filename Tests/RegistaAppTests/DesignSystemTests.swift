import Foundation
import Testing

// D0 (#46, #2): one design system. Scans the app's sources (Sources/Regista) so a new screen cannot bring its own palette,
// type sizes, radii or stock controls back. Settings/ is out of scope on purpose: the Settings window keeps the native
// grouped form (spec, rule 4). Comments and string contents are ignored (a pattern in a doc comment is not a use).
//
// The rules (the allow-list of each, with the reason, is `allowed` below):
// - No native control in the main window: `Picker`, `Toggle`, `Slider`, `Stepper`, `TextField`, `SecureField`,
//   `TextEditor`, `DatePicker`, `ColorPicker`, `Menu` (outside the menu bar), nor a native picker / toggle / text-field /
//   button style. Views use the control set of UI/Controls.swift (RSegmented, RToggle, RSlider, RTextField, RTextEditor,
//   EdButton…). An AppKit alert's accessory field (the track rename in TimelineView) is a system panel, not a view.
// - No native-looking text button (`Button("…")`, `Button(loc(…))`) outside a menu: context menus, alerts, confirmation
//   dialogs and the menu bar's commands are native by nature; anywhere else a text button is an EdButton.
// - No colour literal and no system colour outside UI/Tokens.swift (`Color(hex:)`, `Color(red:…)`, `Color.blue`,
//   `.foregroundStyle(.secondary)`…). Allowed: `Color(hexString:)` (colours that are data: a brand kit's palette, a
//   backdrop the user chose) and the neutral `.white` / `.black` / `.clear` (shadows, scrims, drawn media).
// - No font literal outside UI/Tokens.swift (`.system(size:)`, `.custom(`, `NSFont…`, `.font(.caption)`), and no literal
//   size in `Ed.ui` / `Ed.mono` / `Ed.icon` / `Ed.display`: sizes are `Ed.TypeSize` values, unchanged (no `+ 0.5`).
// - No literal corner radius (`cornerRadius: 6`): radii are `Ed.Radius` values.
// - One type each of segmented control, slider, toggle / switch, text field and text editor (the structs named like one
//   are exactly the set below), and only UI/Controls.swift declares a ButtonStyle / ToggleStyle / TextFieldStyle.

private let appSources: [(path: String, text: String)] = {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let dir = root.appendingPathComponent("Sources/Regista")
    let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
    return files.map { (String($0.path.dropFirst(dir.path.count + 1)), try! String(contentsOf: $0, encoding: .utf8)) }
        .sorted { $0.path < $1.path }
}()

/// The main window's sources: everything but the Settings window.
private func mainWindow(_ path: String) -> Bool { !path.hasPrefix("Settings/") }

/// The allow-list: rule → file → why the rule does not apply there. Keep it short.
private let allowed: [String: [String: String]] = [
    "native": ["UI/Controls.swift": "the one implementation of RTextField, RTextEditor and InspectorValueField wraps the native field and editor"],
    "colour": ["UI/Tokens.swift": "the token file: the only place with colour values"],
    "font": ["UI/Tokens.swift": "the token file: the only place with font literals (Ed.ui, Ed.mono, Ed.display, Ed.icon, the prompter's face)"],
    "radius": ["UI/Tokens.swift": "the token file"],
    "style": ["UI/Controls.swift": "the control set: EdButtonStyle is the one button style"],
]

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

/// The ranges of code inside a menu: the first `{ … }` after `.contextMenu`, `.alert(`, `.confirmationDialog(`,
/// `CommandMenu(`, `CommandGroup(` (native by nature: a text button there is a menu item or an alert button).
private func menuRegions(_ c: String) -> [Range<String.Index>] {
    let re = try! NSRegularExpression(pattern: #"\.contextMenu\b|\.alert\s*\(|\.confirmationDialog\s*\(|\bCommandMenu\s*\(|\bCommandGroup\s*\("#)
    var out: [Range<String.Index>] = []
    for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
        guard var start = Range(m.range, in: c)?.upperBound else { continue }
        if c[c.index(before: start)] == "(" {   // the arguments first (a Binding's closures), then the content closure
            var parens = 1
            while start < c.endIndex, parens > 0 {
                if c[start] == "(" { parens += 1 } else if c[start] == ")" { parens -= 1 }
                start = c.index(after: start)
            }
        }
        guard let open = c[start...].firstIndex(of: "{") else { continue }
        var depth = 0, i = open
        while i < c.endIndex {
            if c[i] == "{" { depth += 1 } else if c[i] == "}" { depth -= 1; if depth == 0 { break } }
            i = c.index(after: i)
        }
        out.append(open..<i)
    }
    return out
}

/// `file:line: text` for every match of `pattern` in the main window's files, minus the rule's allow-list and, with
/// `outsideMenus`, minus the matches inside a menu.
private func hits(_ pattern: String, rule: String, outsideMenus: Bool = false) -> [String] {
    let re = try! NSRegularExpression(pattern: pattern)
    var out: [String] = []
    for (path, text) in appSources where mainWindow(path) && allowed[rule]?[path] == nil {
        let c = code(text)
        let menus = outsideMenus ? menuRegions(c) : []
        let lines = c.components(separatedBy: "\n")
        for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) {
            guard let r = Range(m.range, in: c), !menus.contains(where: { $0.contains(r.lowerBound) }) else { continue }
            let n = c[..<r.lowerBound].filter { $0 == "\n" }.count
            out.append("\(path):\(n + 1): \(lines[n].trimmingCharacters(in: .whitespaces))")
        }
    }
    return out
}

@Test func noNativeControlInTheMainWindow() {
    let controls = #"(?<![A-Za-z0-9_.])(Picker|Toggle|Slider|Stepper|TextField|SecureField|TextEditor|DatePicker|ColorPicker)\s*[({]"#
    let styles = #"\.(pickerStyle|toggleStyle|textFieldStyle)\(|\.buttonStyle\(\s*\.(bordered|borderedProminent|borderless|link|automatic|accessoryBar)"#
    let found = hits(controls + "|" + styles, rule: "native") + hits(#"(?<![A-Za-z0-9_.])Menu\s*[({]"#, rule: "native", outsideMenus: true)
    #expect(found.isEmpty, "native controls in the main window (use RSegmented / RToggle / RSlider / RTextField / RTextEditor / EdButton):\n\(found.joined(separator: "\n"))")
}

@Test func textButtonsAreEdButtonsOutsideMenus() {
    let found = hits(#"(?<![A-Za-z0-9_.])Button\s*\(\s*(""|loc\(|verbatim:|LocalizedStringKey)"#, rule: "native", outsideMenus: true)
    #expect(found.isEmpty, "a native text button outside a menu (use EdButton, AccentLinkButton or IconButton):\n\(found.joined(separator: "\n"))")
}

@Test func colourLiteralsLiveInTheTokenFile() {
    let literal = #"(?<![A-Za-z0-9_])(NS)?Color\s*\(\s*(hex:|red:|white:|hue:|\.sRGB|srgbRed:|calibratedRed:|calibratedWhite:|displayP3Red:)"#
    let system = #"(?<![A-Za-z0-9_])(Color|NSColor)\.(red|blue|green|orange|yellow|gray|grey|purple|pink|teal|indigo|mint|cyan|brown|accentColor|primary|secondary|controlAccentColor|labelColor|secondaryLabelColor|systemRed|systemBlue|systemGreen|systemOrange|systemYellow|systemGray)\b"#
    let shorthand = #"\.(foregroundStyle|foregroundColor|fill|tint|stroke|strokeBorder|background)\(\s*\.(red|blue|green|orange|yellow|gray|purple|pink|teal|indigo|mint|cyan|brown|accentColor|primary|secondary|tertiary|quaternary)\b"#
    let found = hits(literal + "|" + system + "|" + shorthand, rule: "colour")
    #expect(found.isEmpty, "colour literals or system colours outside UI/Tokens.swift (add a token to Ed):\n\(found.joined(separator: "\n"))")
}

@Test func fontLiteralsAndSizesComeFromTheTokens() {
    let literal = #"\.system\s*\(\s*size:|Font\.system\s*\(|\.custom\s*\(|NSFont\s*\(\s*(name|descriptor):|NSFont\.(systemFont|monospacedSystemFont|boldSystemFont|monospacedDigitSystemFont)\s*\("#
    let textStyle = #"\.font\(\s*\.(largeTitle|title|title2|title3|headline|subheadline|body|callout|footnote|caption|caption2)\b"#
    let rawSize = #"Ed\.(ui|mono|icon|display)\(\s*[-0-9.]|Ed\.(ui|mono|icon|display)\([^()]*\?\s*[0-9]|TypeSize\.[a-z]+\s*[-+*/]\s*[0-9]"#
    let found = hits(literal + "|" + textStyle + "|" + rawSize, rule: "font")
    #expect(found.isEmpty, "font literals or literal type sizes (use Ed.ui / Ed.mono / Ed.display / Ed.icon with an Ed.TypeSize):\n\(found.joined(separator: "\n"))")
}

@Test func cornerRadiiComeFromTheTokens() {
    let found = hits(#"cornerRadius:\s*[0-9]"#, rule: "radius")
    #expect(found.isEmpty, "literal corner radii (use Ed.Radius):\n\(found.joined(separator: "\n"))")
}

@Test func oneTypeOfEachControl() {
    let re = try! NSRegularExpression(pattern: #"\bstruct\s+([A-Za-z]*(Segment|Slider|Toggle|Switch|TextField|TextEditor|Field)[A-Za-z]*)\b[^{]*\bView\b"#)
    var names = Set<String>()
    for (path, text) in appSources where mainWindow(path) {
        let c = code(text)
        for m in re.matches(in: c, range: NSRange(c.startIndex..., in: c)) { names.insert(String(c[Range(m.range(at: 1), in: c)!])) }
    }
    // RSwitch is the switch alone, SwitchKnob its drawing, RSwitchRow a source row with its switch; InspectorSlider is the
    // Ispettore's labelled row around an RSlider; InspectorTextEditor keeps a draft around an RTextEditor (Invio saves, Esc
    // restores); InspectorValueField is a value that becomes a field on click, InspectorTimeField its labelled timecode;
    // InspectorMotionFields lays out a motion template's fields with those controls.
    let set: Set = ["RSegmented", "RSlider", "RToggle", "RSwitch", "SwitchKnob", "RSwitchRow", "RTextField", "RTextEditor",
                    "InspectorSlider", "InspectorTextEditor", "InspectorValueField", "InspectorTimeField", "InspectorMotionFields"]
    #expect(names.subtracting(set).isEmpty, "a second segmented / slider / toggle / field type: \(names.subtracting(set).sorted())")
    let styles = hits(#":\s*(ButtonStyle|ToggleStyle|TextFieldStyle|PickerStyle|LabelStyle)\b"#, rule: "style")
    #expect(styles.isEmpty, "a style outside UI/Controls.swift (use EdButtonStyle):\n\(styles.joined(separator: "\n"))")
}

/// The scanner itself: it sees what it must refuse, and leaves comments, strings and menus alone.
@Test func theScannerSeesWhatItMust() {
    let sample = """
    // Toggle("in a comment") is not a use
    let s = "Picker(in a string)"
    Toggle("Mute", isOn: $x)
    Button("OK") { }
    .contextMenu { Button("Mostra nel Finder") { } }
    Text("a").font(Ed.ui(11.5))
    RoundedRectangle(cornerRadius: 6)
    """
    let c = code(sample)
    #expect(!c.contains("in a comment") && !c.contains("in a string"))
    let menus = menuRegions(c)
    #expect(menus.count == 1)
    let buttons = c.ranges(of: "Button(\"\")")
    #expect(buttons.count == 2)
    #expect(!menus.contains { $0.contains(buttons[0].lowerBound) } && menus.contains { $0.contains(buttons[1].lowerBound) })
    #expect(c.range(of: #"(?<![A-Za-z0-9_.])Toggle\s*\("#, options: .regularExpression) != nil)
    #expect(c.range(of: #"Ed\.(ui|mono|icon|display)\(\s*[-0-9.]"#, options: .regularExpression) != nil)
    #expect(c.range(of: #"cornerRadius:\s*[0-9]"#, options: .regularExpression) != nil)
}
