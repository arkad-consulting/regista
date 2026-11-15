import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// The window from its default size down to its minimum (1024×640, RegistaApp's window), both panels shown, in Italian and
// French, driven with real mouse events (MouseRig). #41: the right panel keeps the height it gets at every tab (its tab
// bar at the top, under the title row) and the Gobbo tab scrolls to its last control.

/// A window size a test renders (the default, one between, the minimum).
struct RigWindowSize: Sendable, CustomTestStringConvertible {
    let width: CGFloat, height: CGFloat
    var size: CGSize { CGSize(width: width, height: height) }
    var testDescription: String { "\(Int(width))×\(Int(height))" }

    static let standard = RigWindowSize(width: 1440, height: 900)
    static let between = RigWindowSize(width: 1200, height: 800)
    /// The main window's minimum size (RegistaApp: `.frame(minWidth: 1024, minHeight: 640)`); a render draws its title row
    /// inside it, so the panels get a little less height than in the live window.
    static let minimum = RigWindowSize(width: 1024, height: 640)
}

/// The parts of a render of the editor window `size` large (as EditorRoot lays them out, both panels shown).
@MainActor
enum RenderParts {
    static func side(_ size: CGSize) -> CGFloat {
        SplitSize.resolve(UserDefaults.standard.double(forKey: ShellPrefs.sideWidth), automatic: Chrome.sideDefault, in: Chrome.sideRange(size.width))
    }

    static func top() -> CGFloat { WindowChrome.shared.titleBar }

    static func main(_ size: CGSize) -> CGRect {
        let x = Chrome.activityWidth + side(size), y = top()
        return CGRect(x: x, y: y, width: size.width - Chrome.rightWidth - x, height: size.height - Chrome.statusHeight - y)
    }

    static func right(_ size: CGSize) -> CGRect {
        CGRect(x: size.width - Chrome.rightWidth, y: top(), width: Chrome.rightWidth, height: size.height - Chrome.statusHeight - top())
    }

    /// The side panel and the main area together.
    static func content(_ size: CGSize) -> CGRect {
        CGRect(x: Chrome.activityWidth, y: top(), width: size.width - Chrome.rightWidth - Chrome.activityWidth, height: size.height - Chrome.statusHeight - top())
    }
}

/// `key` in `language`, as the window shows it.
private func word(_ key: String, _ language: String) -> String {
    MouseRig.table(language).localizedString(forKey: key, value: key, table: nil)
}

private func inside(_ frame: CGRect, _ area: CGRect) -> Bool { area.insetBy(dx: -0.5, dy: -0.5).contains(frame) }

extension MouseSuites {
@Suite(.serialized) @MainActor struct NarrowWindowTests {
    static let languages = ["it", "fr"]

    /// #41: at the default and the minimum size, on every tab (the Ispettore with a clip too), the right panel's tab bar is
    /// at its top, under the title row, nothing of the panel is above it, and each tab answers.
    @Test(arguments: [RigWindowSize.standard, .minimum], languages)
    func theRightPanelKeepsItsTabBarAtTheTop(_ window: RigWindowSize, _ language: String) async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .media, rightTab: .prompter), size: window.size, language: language)
        await app.settle()
        let right = RenderParts.right(window.size)
        let keys: [Navigation.RightTab: String] = [.prompter: "Gobbo", .claude: "Claude", .inspector: "Ispettore"]
        let titles = Navigation.RightTab.allCases.map { (tab: $0, name: word(keys[$0]!, language)) }

        func check(_ state: String) {
            for t in titles {
                guard let b = app.rig.elements().first(where: { $0.name == t.name && $0.role == "AXButton" && right.contains($0.centre) }) else {
                    Issue.record("\(window) \(language) \(state): no tab «\(t.name)» in the right panel"); continue
                }
                #expect(abs(b.frame.minY - right.minY) <= 1 && abs(b.frame.height - Chrome.headerHeight) <= 1,
                        "\(window) \(language) \(state): the tab «\(t.name)» is at \(b.frame), the panel starts at \(right.minY)")
            }
            // Nothing of the panel reaches into the title row (the title row's own controls end above it).
            let across = app.rig.elements().filter { $0.visible && right.contains(CGPoint(x: $0.frame.midX, y: right.midY))
                && $0.frame.minY < right.minY - 0.5 && $0.frame.maxY > right.minY + 0.5 }
            #expect(across.isEmpty, "\(window) \(language) \(state): drawn across the right panel's top: \(across.prefix(3).map { "\($0) \($0.frame)" })")
        }

        check("Gobbo")
        for t in titles.reversed() + titles.prefix(1) {
            #expect(app.rig.click(t.name, role: "AXButton"), "\(window) \(language): no tab «\(t.name)»")
            await app.settle()
            #expect(app.store.nav.rightTab == t.tab, "\(window) \(language): the tab «\(t.name)» did not answer")
            check(t.name)
        }
        // The Ispettore on a clip: its sections are longer than the panel at the minimum size.
        app.store.selection = [app.clips.first { $0.assetID == "a1" }?.id ?? ""]
        #expect(app.rig.click(titles[2].name, role: "AXButton"))
        await app.settle()
        check("Ispettore on a clip")
    }

    /// #41, every screen at the minimum size: the side panel and the right panel keep the height they get on every
    /// activity (and every tab of Testi e sottotitoli): nothing of them reaches into the title row or under the status bar's
    /// top, and the right panel's tab bar stays at its top.
    @Test(arguments: languages)
    func everyPanelKeepsItsHeightAtTheMinimumSize(_ language: String) async throws {
        let size = RigWindowSize.minimum.size
        let right = RenderParts.right(size), content = RenderParts.content(size)
        var screens: [(String, Navigation)] = Navigation.Activity.allCases.map { ("\($0.rawValue)", Navigation(activity: $0, rightTab: .prompter)) }
        for tab in Navigation.TextsTab.allCases {
            var nav = Navigation(activity: .texts, rightTab: .prompter)
            nav.textsTab = tab
            screens.append(("texts-\(tab.rawValue)", nav))
        }
        for (name, nav) in screens {
            let app = try await AppRig()
            defer { app.close() }
            app.hostEditor(nav, size: size, language: language)
            await app.settle()
            let panels = app.rig.elements().filter { $0.visible && ($0.centre.x < content.maxX ? $0.centre.x > Chrome.activityWidth : right.contains(CGPoint(x: $0.centre.x, y: right.midY))) }
            let top = panels.filter { $0.frame.minY < right.minY - 0.5 && $0.frame.maxY > right.minY + 0.5 }
            let bottom = panels.filter { $0.frame.minY < right.maxY - 0.5 && $0.frame.maxY > right.maxY + 0.5 && $0.frame.height < size.height / 2 }
            #expect(top.isEmpty, "\(name) \(language): drawn across the panels' top: \(top.prefix(3).map { "\($0) \($0.frame)" })")
            #expect(bottom.isEmpty, "\(name) \(language): drawn across the status bar's top: \(bottom.prefix(3).map { "\($0) \($0.frame)" })")
            let tab = app.rig.elements().first { $0.role == "AXButton" && right.contains($0.centre) && $0.name == word("Gobbo", language) }
            #expect(tab.map { abs($0.frame.minY - right.minY) <= 1 } == true, "\(name) \(language): the right panel's tab bar is at \(String(describing: tab?.frame))")
        }
    }

    /// #41: at the minimum size the Gobbo tab is taller than the panel: it scrolls, and its last control («Ricomincia»)
    /// comes into the panel by scrolling and answers (the script's cursor goes back to the start).
    @Test(arguments: languages)
    func theGobboScrollsToItsLastControl(_ language: String) async throws {
        let app = try await AppRig()
        defer { app.close() }
        let p = TeleprompterController.shared
        let text = p.text
        defer { p.text = text; p.restart() }
        p.text = "1. Oggi Regista monta il reel.\n2. Le pause spariscono da sole.\n3. Poi si esporta."
        app.hostEditor(Navigation(activity: .media, rightTab: .prompter), size: RigWindowSize.minimum.size, language: language)
        await app.settle()
        let right = RenderParts.right(RigWindowSize.minimum.size)
        let restart = word("Ricomincia", language)
        func button() -> RigElement? { app.rig.elements().first { $0.name == restart && $0.role == "AXButton" } }
        let first = try #require(button(), "\(language): no «\(restart)» in the Gobbo tab")
        #expect(first.frame.minY > right.maxY, "\(language): «\(restart)» is already in view at the minimum size (\(first.frame)): the test proves nothing")
        // The editor gets a sensible height.
        // The editor gets its minimum height (its well, the text area inside it less its margins).
        let editor = try #require(app.rig.elements().first { $0.role == "AXScrollArea" && right.contains($0.centre) && $0.frame.width < right.width - 20 })
        #expect(editor.frame.height >= PrompterEditorView.editorMin - 2 * Ed.Space.s - 1, "\(language): the script editor is \(editor.frame.height) pt high")
        // Scroll the tab, over the settings (not over the script, which scrolls its own text), until the button is in the panel.
        for _ in 0..<30 {
            guard let b = button(), !(b.visible && right.insetBy(dx: 0, dy: 1).contains(b.frame)) else { break }
            #expect(app.rig.scrollContent(at: CGPoint(x: right.midX, y: right.maxY - 30), by: 80), "\(language): the Gobbo tab does not scroll")
            await app.settle()
        }
        let b = try #require(button())
        #expect(b.visible && inside(b.frame, right), "\(language): «\(restart)» did not come into the panel by scrolling (\(b.frame), panel \(right))")
        p.jump(toToken: 4)
        #expect(p.follower.cursor == 4)
        app.rig.click(b.centre)
        await app.settle()
        #expect(p.follower.cursor == 0, "\(language): «\(restart)» did not answer (the cursor is at \(p.follower.cursor))")
        // The tab bar stayed at the top while the tab scrolled.
        let tab = app.rig.elements().first { $0.name == word("Gobbo", language) && $0.role == "AXButton" }
        #expect(tab.map { abs($0.frame.minY - right.minY) <= 1 } == true, "\(language): the tab bar moved while the Gobbo scrolled (\(String(describing: tab?.frame)))")
    }
}
}
