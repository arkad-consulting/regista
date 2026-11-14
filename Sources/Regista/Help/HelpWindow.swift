import AppKit
import SwiftUI

/// The help window (K1 #7): the guides on the left, the chosen one on the right, read from the copy shipped in the app in
/// the app's language. Links between guides open the other guide here; web links open in the browser.
struct HelpView: View {
    @ObservedObject var center: HelpCenter
    /// The guides' language (the app's, unless a render asks for another).
    var language: String = HelpLibrary.language
    @Environment(\.openSettings) private var openSettings

    static let size = CGSize(width: 960, height: 700)
    static let listWidth: CGFloat = 248

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PanelHeader(title: "Aiuto")
                VStack(alignment: .leading, spacing: Ed.Space.xxs) {
                    ForEach(HelpGuide.allCases) { g in
                        SideRow(symbol: g.symbol, title: g.title, on: g == center.guide) { center.guide = g }
                    }
                }
                .padding(Ed.Space.s)
                Spacer(minLength: Ed.Space.l)
                VStack(alignment: .leading, spacing: Ed.Space.s) {
                    AccentLinkButton(title: "Scorciatoie da tastiera") { SettingsRoute.open(.shortcuts, with: openSettings) }
                    AccentLinkButton(title: "Segnala un problema…") { HelpCenter.reportProblem() }
                }
                .padding(Ed.Space.l)
            }
            .frame(width: Self.listWidth)
            .frame(maxHeight: .infinity)
            .background(Ed.side)
            Ed.rule.frame(width: 1)
            ScrollView {
                Group {
                    if let text = HelpLibrary.text(center.guide, language: language) {
                        MarkdownView(blocks: Markdown.blocks(text))
                    } else {
                        EmptyHint(symbol: "book", text: loc("Questa guida manca da questa installazione: reinstalla l'app."))
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(.horizontal, Ed.Space.xxl)
                .padding(.vertical, Ed.Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(center.guide)
            .background(Ed.main)
        }
        .environment(\.openURL, OpenURLAction { url in
            if let g = HelpGuide(link: url) { center.guide = g; return .handled }
            if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
                return .handled
            }
            return .discarded
        })
        .environment(\.colorScheme, .dark)
    }
}
