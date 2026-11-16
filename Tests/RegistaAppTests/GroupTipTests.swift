import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #32: a tooltip on a group is help text only (`groupTip`): the controls and texts inside keep their own names for an
// assistive client. Read on the real views of the editor window, in Italian and in French.

/// `key` in `language`, as the window shows it.
private func word(_ key: String, _ language: String) -> String {
    MouseRig.table(language).localizedString(forKey: key, value: key, table: nil)
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct GroupTipTests {
    /// The project tab: its close button reads «Chiudi la scheda», its name and its duration read as themselves; the
    /// project's path (its tooltip) names none of them.
    @Test(arguments: ["it", "fr"])
    func theProjectTabReadsAsItsParts(_ language: String) async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector), language: language)
        await app.settle()
        let project = try #require(app.store.project)
        let strip = CGRect(x: WindowPart.main.minX, y: Chrome.titleHeight, width: WindowPart.main.width, height: Chrome.tabsHeight)
        let inTab = app.rig.elements().filter { $0.visible && strip.contains($0.centre) }
        let path = app.store.projectURL?.path ?? "clicks.regista"
        #expect(!inTab.contains { $0.name.contains(path) || $0.name.contains("\n") },
                "\(language): an element of the tab reads as its tooltip: \(inTab.map(\.description))")
        let name = try #require(inTab.first { $0.role == "AXStaticText" && $0.name == "clicks" },
                                "\(language): no text reads as the project's name: \(inTab.map(\.description))")
        let duration = clockTime(project.duration.seconds)
        #expect(inTab.contains { $0.role == "AXStaticText" && $0.name == duration && $0.frame.minX > name.frame.minX },
                "\(language): no text reads as the duration \(duration): \(inTab.map(\.description))")
        let close = word("Chiudi la scheda", language) + " (⌘W)"
        let button = try #require(inTab.first { $0.role == "AXButton" && $0.name == close },
                                  "\(language): the tab's × does not read «\(close)»: \(inTab.map(\.description))")
        // The control named so is the one that closes the tab: a click on it (a second tab keeps the window).
        let bench = app.store.bench
        bench.saveDecision = { _ in .discard }
        _ = bench.newTab()
        bench.select(app.store.tabID)
        await app.settle()
        let tabs = bench.tabs.count
        app.rig.click(button.centre)
        await app.idle(0.3)
        await app.settle()
        #expect(bench.tabs.count == tabs - 1 && !bench.tabs.contains { $0 === app.store }, "\(language): a click on «\(close)» did not close the project's tab")
    }

    /// Testi e sottotitoli › Sottotitoli: each caption style chip reads as its style; the group's tooltip is their hint.
    @Test(arguments: ["it", "fr"])
    func theCaptionStyleChipsReadAsTheirStyles(_ language: String) async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .texts, rightTab: .inspector)
        nav.textsTab = .captions
        app.hostEditor(nav, language: language)
        await app.settle()
        let controls = app.rig.controls().filter { WindowPart.side.contains($0.centre) }
        let tip = word("Cambia lo stile dei sottotitoli (parole chiave e posizioni restano)", language)
        #expect(!controls.contains { $0.name == tip }, "\(language): a control reads as the chips' tooltip: \(controls.map(\.description))")
        for style in CaptionStyle.all {
            let title = word(captionStyleNameKey(style.id), language)
            let chip = try #require(controls.first { $0.name == title }, "\(language): no chip reads «\(title)»: \(controls.map(\.description))")
            // The chip is the one it is named after: a click on it sets that style (the current one changes nothing).
            if app.store.project?.tracks.first(where: { $0.kind == .caption })?.captions?.style.id == style.id { continue }
            let n = app.store.activity.count
            app.rig.click(chip.centre)
            await app.settle()
            #expect(app.commands(since: n) == ["captions.setStyle"], "\(language): «\(title)» ran \(app.commands(since: n))")
            #expect(app.store.project?.tracks.first(where: { $0.kind == .caption })?.captions?.style.id.hasPrefix(style.id) == true,
                    "\(language): «\(title)» did not set the style \(style.id)")
            _ = try? await app.store.perform("history.undo")
            await app.settle()
        }
    }
}
}

/// The Italian key of a caption style's name (captionStyleName looks it up in the window's language).
private func captionStyleNameKey(_ id: String) -> String {
    switch id {
    case "elegant-serif": "Serif elegante"
    case "bold-keyword": "Bold + parola chiave"
    case "ghost-karaoke": "Karaoke fantasma"
    default: "Talking head"
    }
}
