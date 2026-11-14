import Foundation
import SwiftUI

/// A small Markdown reader for the guides (K1 #7), drawn with the design system's tokens, no web view.
/// Supported: headings `#`, `##`, `###`; paragraphs; bullet (`-`, `*`) and numbered (`1.`) lists, nested by indentation;
/// block quotes (`>`); fenced code blocks (long lines wrap); `---`; inline **bold**, *italic*, `code` and [links](…) (Foundation's inline
/// Markdown). Not supported: tables (their lines show as plain paragraphs), images, raw HTML (comments are skipped),
/// setext headings, nested quotes, reference-style links.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(level: Int, text: String)
    case numbered(number: Int, level: Int, text: String)
    case quote(String)
    case code(String)
    case rule
}

enum Markdown {
    /// The blocks of `text`, in order.
    static func blocks(_ text: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        var paragraph: [String] = [], quote: [String] = [], code: [String] = []
        var item: (block: MarkdownBlock, lines: [String])?
        var inCode = false, inComment = false

        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: " "))); quote = [] }
            if let (b, lines) = item {
                let t = lines.joined(separator: " ")
                switch b {
                case .bullet(let level, _): out.append(.bullet(level: level, text: t))
                case .numbered(let n, let level, _): out.append(.numbered(number: n, level: level, text: t))
                default: break
                }
                item = nil
            }
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if inCode {
                if trimmed.hasPrefix("```") { out.append(.code(code.joined(separator: "\n"))); code = []; inCode = false }
                else { code.append(line) }
                continue
            }
            if inComment {
                if trimmed.contains("-->") { inComment = false }
                continue
            }
            if trimmed.hasPrefix("<!--") {
                flush()
                if !trimmed.contains("-->") { inComment = true }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); inCode = true; continue }
            if trimmed.isEmpty { flush(); continue }
            if trimmed == "---" || trimmed == "***" { flush(); out.append(.rule); continue }
            let indent = line.prefix { $0 == " " }.count
            if let h = heading(trimmed) { flush(); out.append(h); continue }
            if trimmed.hasPrefix(">") {
                if !paragraph.isEmpty || item != nil { flush() }
                quote.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                continue
            }
            if let (marker, rest) = listMarker(trimmed) {
                flush()
                let level = indent / 2 >= 1 ? 1 : 0
                item = (marker.map { .numbered(number: $0, level: level, text: "") } ?? .bullet(level: level, text: ""), [rest])
                continue
            }
            if item != nil, indent > 0 { item?.lines.append(trimmed); continue }
            if !quote.isEmpty { flush() }
            if item != nil { flush() }
            paragraph.append(trimmed)
        }
        if inCode { out.append(.code(code.joined(separator: "\n"))) }
        flush()
        return out
    }

    private static func heading(_ s: String) -> MarkdownBlock? {
        let hashes = s.prefix { $0 == "#" }.count
        guard (1...3).contains(hashes), s.dropFirst(hashes).first == " " else { return nil }
        return .heading(level: hashes, text: String(s.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces))
    }

    /// (number or nil for a bullet, the text after the marker).
    private static func listMarker(_ s: String) -> (Int?, String)? {
        if s.hasPrefix("- ") || s.hasPrefix("* ") { return (nil, String(s.dropFirst(2))) }
        let digits = s.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, s.dropFirst(digits.count).hasPrefix(". "), let n = Int(digits) else { return nil }
        return (n, String(s.dropFirst(digits.count + 2)))
    }

    /// Inline Markdown (bold, italic, code, links) as styled text; the plain text when it does not parse.
    static func inline(_ s: String) -> AttributedString {
        var a = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for range in a.runs.filter({ $0.link != nil }).map(\.range) { a[range].foregroundColor = Ed.gold }
        let runs = a.runs.compactMap { run in run.inlinePresentationIntent.map { (run.range, $0) } }
        for (range, intent) in runs {
            if intent.contains(.code) {
                a[range].font = Ed.mono(Ed.TypeSize.body)
                a[range].foregroundColor = Ed.text
            } else if intent.contains(.stronglyEmphasized) {
                a[range].foregroundColor = Ed.text
            }
        }
        return a
    }

    /// The text of the first heading (the guide's title).
    static func title(_ blocks: [MarkdownBlock]) -> String? {
        for b in blocks { if case .heading(_, let t) = b { return t } }
        return nil
    }
}

/// The blocks of a guide, laid out for reading.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: Ed.Space.s) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                block(b).padding(.top, topPadding(b, first: i == 0))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .tint(Ed.gold)   // links in the accent
    }

    private func topPadding(_ b: MarkdownBlock, first: Bool) -> CGFloat {
        guard !first, case .heading(let level, _) = b else { return 0 }
        return level == 2 ? Ed.Space.l : Ed.Space.s
    }

    private func inline(_ s: String, size: CGFloat = Ed.TypeSize.title, color: Color = Ed.text2) -> some View {
        Text(Markdown.inline(s))  // l10n-ignore — the guide's own text, already in the app's language
            .font(Ed.ui(size)).foregroundStyle(color).lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func block(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(1, let t):
            Text(Markdown.inline(t)).font(Ed.display(Ed.TypeSize.display)).foregroundStyle(Ed.text)  // l10n-ignore — the guide's text
                .fixedSize(horizontal: false, vertical: true).padding(.bottom, Ed.Space.xs)
        case .heading(2, let t):
            Text(Markdown.inline(t)).font(Ed.ui(Ed.TypeSize.heading, .semibold)).foregroundStyle(Ed.text)  // l10n-ignore — the guide's text
                .fixedSize(horizontal: false, vertical: true)
        case .heading(_, let t):
            Text(Markdown.inline(t)).font(Ed.ui(Ed.TypeSize.title, .semibold)).foregroundStyle(Ed.text)  // l10n-ignore — the guide's text
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let t):
            inline(t)
        case .bullet(let level, let t):
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                Text(verbatim: level == 0 ? "•" : "◦").font(Ed.ui(Ed.TypeSize.title)).foregroundStyle(Ed.text3)
                inline(t)
            }
            .padding(.leading, level == 0 ? Ed.Space.xs : Ed.Space.xl)
        case .numbered(let n, let level, let t):
            HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
                Text(verbatim: "\(n).").font(Ed.mono(Ed.TypeSize.body, .medium)).foregroundStyle(Ed.gold).frame(minWidth: 18, alignment: .trailing)
                inline(t)
            }
            .padding(.leading, level == 0 ? 0 : Ed.Space.xl)
        case .quote(let t):
            HStack(spacing: Ed.Space.m) {
                RoundedRectangle(cornerRadius: Ed.Radius.xs).fill(Ed.gold.opacity(0.7)).frame(width: 3)
                inline(t, color: Ed.text)
            }
            .padding(.vertical, Ed.Space.xs)
        case .code(let t):
            // Long lines wrap (a command to paste must be seen whole); selecting copies them as they are written.
            Text(verbatim: t).font(Ed.mono(Ed.TypeSize.body)).foregroundStyle(Ed.text).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .rCard(.well)
        case .rule:
            Ed.line.frame(height: 1).padding(.vertical, Ed.Space.s)
        }
    }
}
