import Foundation
import RegistaCore
import Testing
@testable import Regista

// K1 (#7): the guides in four languages, shipped in the app and opened from the Help menu in a window that renders their
// Markdown. Every label a guide quotes (in bold) is the exact text of that language's table.

private let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func table(_ lang: String) -> [String: String] {
    let url = repoRoot.appendingPathComponent("Resources/Localization/\(lang).lproj/Localizable.strings")
    return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
}

private func guide(_ lang: String, _ g: HelpGuide) -> String {
    (try? String(contentsOf: repoRoot.appendingPathComponent("docs/\(lang)/\(g.file)"), encoding: .utf8)) ?? ""
}

@Test func everyGuideExistsInEveryLanguage() {
    for lang in HelpLibrary.languages {
        for g in HelpGuide.allCases {
            let text = guide(lang, g)
            #expect(!text.isEmpty, "docs/\(lang)/\(g.file) is missing")
            #expect(text.hasPrefix("# "), "docs/\(lang)/\(g.file) starts with its title")
        }
    }
}

@Test func everyQuotedLabelIsInThatLanguagesTable() {
    // A bold run is a UI label: the exact text of the table (a menu path "A › B" is checked part by part). A run may wrap
    // onto the next line of its paragraph, as the help window joins them (#122): it is read whole, its line break a space.
    let bold = try! NSRegularExpression(pattern: #"\*\*([^*]+?)\*\*"#)
    var problems: [String] = []
    for lang in HelpLibrary.languages {
        let values = Set(table(lang).values)
        #expect(!values.isEmpty)
        for g in HelpGuide.allCases {
            let text = guide(lang, g) as NSString
            for m in bold.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let raw = text.substring(with: m.range(at: 1))
                guard !raw.contains("\n\n") else { continue }   // never across paragraphs
                let label = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let line = text.substring(to: m.range.location).filter { $0 == "\n" }.count + 1
                for part in label.components(separatedBy: " › ") where !values.contains(part) {
                    problems.append("docs/\(lang)/\(g.file):\(line): «\(part)» is not a label of \(lang).lproj")
                }
            }
        }
    }
    #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
}

/// #119: the install guide opens with what a person who downloaded the disk image needs — the app from the image, what
/// is already in it, «Per cominciare» with the transcription model and «Collega…» — and the source install, unchanged,
/// below it.
@Test func theInstallGuideLeadsWithTheDownloadedApp() {
    for lang in HelpLibrary.languages {
        let text = guide(lang, .install)
        let t = table(lang)
        let sections = text.components(separatedBy: "\n## ")
        let first = sections.count > 1 ? sections[1] : ""
        #expect(first.contains("Regista-<") && first.contains(".dmg") && first.contains("whisper.cpp"), "\(lang): the opening is not the downloaded app")
        for key in ["Per cominciare", "Scarica", "Collega…", "Non uso Claude", "Modello per trascrivere e fare i sottotitoli"] {
            #expect(first.contains("**\(t[key] ?? key)**"), "\(lang): the opening does not name «\(t[key] ?? key)»")
        }
        #expect(!first.contains("git clone") && !first.contains("xcode-select"), "\(lang): the opening asks for developer tools")
        // The source install follows, once; the opening is the only place that tells the first open.
        let clone = text.range(of: "git clone https://github.com/arkad-consulting/regista.git ~/code/regista && ~/code/regista/scripts/install.sh")
        #expect(clone != nil && clone!.lowerBound > text.range(of: first)!.upperBound, "\(lang): the source install is not below the opening")
        #expect(text.components(separatedBy: "**\(t["Per cominciare"] ?? "")**").count == 2, "\(lang): «Per cominciare» is told twice")
    }
}

@Test func linksInTheGuidesLeadSomewhere() {
    let link = try! NSRegularExpression(pattern: #"\]\(([^)\s]+)\)"#)
    var problems: [String] = []
    for lang in HelpLibrary.languages {
        for g in HelpGuide.allCases {
            let text = guide(lang, g)
            for m in link.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let target = (text as NSString).substring(with: m.range(at: 1))
                guard let url = URL(string: target) else { problems.append("\(lang)/\(g.file): \(target)"); continue }
                if ["http", "https"].contains(url.scheme ?? "") { continue }
                if HelpGuide(link: url) == nil { problems.append("\(lang)/\(g.file): \(target) is neither a guide nor a web link") }
            }
        }
    }
    #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
}

@Test func theHelpWindowFindsTheGuidesInEveryLanguage() {
    for lang in HelpLibrary.languages {
        #expect(HelpLibrary.folder(lang) != nil, "no guides for \(lang)")
        for g in HelpGuide.allCases {
            let text = HelpLibrary.text(g, language: lang)
            #expect(text == guide(lang, g), "\(lang)/\(g.file)")
        }
    }
    // A language without guides falls back to English.
    #expect(HelpLibrary.text(.voice, language: "de") == guide("en", .voice))
    #expect(HelpGuide(link: URL(string: "voice.md")!) == .voice)
    #expect(HelpGuide(link: URL(string: "../en/troubleshooting.md#logs")!) == .troubleshooting)
    #expect(HelpGuide(link: URL(string: "https://example.invalid/voice.md")!) == nil)
}

@Test func theMarkdownReaderKnowsTheGuidesBlocks() {
    let text = """
    <!-- a comment
    over two lines -->
    # Title

    A paragraph
    on two lines with **bold**.

    - one
      continued
    - two
      - nested
    1. first
    2. second

    > a quote

    ```
    code line
    ```
    ---
    ### Small
    """
    let b = Markdown.blocks(text)
    #expect(b == [.heading(level: 1, text: "Title"), .paragraph("A paragraph on two lines with **bold**."),
                  .bullet(level: 0, text: "one continued"), .bullet(level: 0, text: "two"), .bullet(level: 1, text: "nested"),
                  .numbered(number: 1, level: 0, text: "first"), .numbered(number: 2, level: 0, text: "second"),
                  .quote("a quote"), .code("code line"), .rule, .heading(level: 3, text: "Small")])
    #expect(Markdown.title(b) == "Title")
    // Inline: bold, code and links keep their meaning; the link stays a link.
    let a = Markdown.inline("see [the voice guide](voice.md) and `doctor.sh`")
    #expect(String(a.characters) == "see the voice guide and doctor.sh")
    #expect(a.runs.contains { $0.link?.absoluteString == "voice.md" })
    // Every real guide parses into a title and some sections.
    for lang in HelpLibrary.languages {
        for g in HelpGuide.allCases {
            let blocks = Markdown.blocks(guide(lang, g))
            #expect(Markdown.title(blocks) != nil && blocks.filter { if case .heading(2, _) = $0 { true } else { false } }.count >= 3,
                    "\(lang)/\(g.file)")
        }
    }
}

@Test func theHelpMenuHasEveryGuideAndItsWordsInEveryLanguage() throws {
    // The menu bar and the one table it is drawn from (#36).
    let app = try ["RegistaApp.swift", "MenuCommands.swift"].map {
        try String(contentsOf: repoRoot.appendingPathComponent("Sources/Regista/App/\($0)"), encoding: .utf8)
    }.joined(separator: "\n")
    #expect(app.contains("CommandGroup(replacing: .help)"), "the standard Help menu")
    #expect(app.contains("HelpCenter.open(") && app.contains("HelpCenter.reportProblem()") && app.contains("SettingsRoute.open(.shortcuts"))
    let keys = HelpGuide.allCases.map(\.title) + ["Aiuto", "Scorciatoie da tastiera", "Segnala un problema…"]
    for lang in HelpLibrary.languages {
        let t = table(lang)
        for k in keys { #expect(!(t[k] ?? "").isEmpty, "\(lang): \(k)") }
    }
    #expect(AppShortcuts.all.contains { $0.id == "help" && $0.display == "⌘?" })
    #expect(HelpLibrary.issuesURL.absoluteString == "https://github.com/arkad-consulting/regista/issues")
    // The window is a ui.screenshot workspace, one per guide, and build-app.sh ships the guides of every language.
    let workspaces = Engine().descriptors.first { $0.id == "ui.screenshot" }?.params.first { $0.name == "workspace" }
    guard case .oneOf(let names)? = workspaces?.type else { Issue.record("ui.screenshot workspace is not a list"); return }
    for g in HelpGuide.allCases { #expect(names.contains(g.screenshotName), "\(g.screenshotName)") }
    let build = try String(contentsOf: repoRoot.appendingPathComponent("scripts/build-app.sh"), encoding: .utf8)
    #expect(build.contains("Contents/Resources/Help/$lang") && build.contains("docs/$lang/*.md"))
}
