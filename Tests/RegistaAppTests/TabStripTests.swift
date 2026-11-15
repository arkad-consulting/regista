import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #38: with many projects open the tab strip stays inside the main area. The tabs keep their natural widths while they
// fit, then shrink like a browser's down to a minimum, then the strip scrolls from the first tab; "+" always shows.

/// Natural widths while they fit; then the widest shrink to one width; never under the minimum.
@Test func tabWidthsShrinkLikeABrowserThenStopAtTheMinimum() {
    #expect(TabsLayout.widths([100, 150, 200], available: 500) == [100, 150, 200])
    // 400 for three: the 100 tab keeps its width, the two others share the rest.
    #expect(TabsLayout.widths([100, 150, 200], available: 400) == [100, 150, 150])
    #expect(TabsLayout.widths([200, 200, 200], available: 450) == [150, 150, 150])
    // Under the minimum: every wide tab at the minimum, the row wider than the room (it scrolls).
    let w = TabsLayout.widths(Array(repeating: 200, count: 12), available: 300)
    #expect(w.allSatisfy { $0 == TabsLayout.minWidth } && w.reduce(0, +) > 300)
}

/// Long and short names, the first one the owner saw cut.
private let tabNames = ["able-orchestra", "Tutorial Regista completo", "Intervista", "Reel lancio prodotto", "Video senza volto",
                        "Confronto v2", "Podcast puntata 14", "Demo", "Corso di montaggio lezione 3", "Spot estate", "Backstage", "Intro canale"]

extension MouseSuites {
@Suite(.serialized) @MainActor struct TabStripTests {
    /// `n` tabs at the default window width (1440) and at the minimum one (1024), clicked through.
    @Test(arguments: [2, 6, 12], [1440.0, 1024.0])
    func manyTabs(_ n: Int, width: Double) async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let bench = app.store.bench
        bench.saveDecision = { _ in .discard }
        let dir = rigTempDir("tabs")
        for (i, name) in tabNames.prefix(n).enumerated() {
            let t = i == 0 ? app.store : bench.newTab()
            try await t.perform("project.new", ["name": .string(name), "directory": .string(dir.path)])
        }
        for _ in 0..<200 where bench.tabs.contains(where: { $0.project == nil }) { try await Task.sleep(for: .milliseconds(50)) }
        #expect(bench.tabs.count == n)
        app.hostEditor(Navigation(activity: .media, rightTab: .inspector), size: CGSize(width: width, height: 700))
        await app.settle()

        // The main area, where the strip lives (title row 40 pt, activity bar, side panel, right panel).
        let side = SplitSize.resolve(UserDefaults.standard.double(forKey: ShellPrefs.sideWidth), automatic: Chrome.sideDefault, in: Chrome.sideRange(width))
        let main = CGRect(x: Chrome.activityWidth + side, y: Chrome.titleHeight, width: width - Chrome.activityWidth - side - Chrome.rightWidth,
                          height: Chrome.tabsHeight)
        let room = main.width - PlusTab.width
        let scrolls = CGFloat(n) * TabsLayout.minWidth > room
        func plus() throws -> RigElement { try #require(app.rig.element("Nuova scheda"), "no + on screen") }
        // A tab's texts read as its tooltip (the full name, then where it is saved): the leftmost one is the name.
        func name(_ s: String) -> RigElement? {
            app.rig.elements().filter { $0.role == "AXStaticText" && $0.value.hasPrefix(s + "\n") && $0.visible && main.contains($0.centre) }
                .min { $0.frame.minX < $1.frame.minX }
        }
        /// The × of the tab whose name is `text`: the first small button right of the name.
        func close(of text: RigElement) -> RigElement? {
            app.rig.elements().filter { $0.role == "AXButton" && $0.frame.width <= 20 && $0.visible && abs($0.centre.y - text.centre.y) < 6 && $0.frame.minX >= text.frame.maxX }
                .min { $0.frame.minX < $1.frame.minX }
        }
        let tag = "\(n) tabs at \(Int(width)) pt"

        // The strip starts at the first tab, its name from its first letter; "+" inside the main area.
        let first = try #require(name(tabNames[0]), "\(tag): the first tab's name is not on screen")
        #expect(first.frame.minX >= main.minX + 14 - 1, "\(tag): the first tab's name starts at \(first.frame.minX), the main area at \(main.minX)")
        let p = try plus()
        #expect(p.frame.minX >= main.minX && p.frame.maxX <= main.maxX + 0.5, "\(tag): + at \(p.frame), main area \(main)")
        // While the tabs fit at their natural or shrunk width, every name shows; otherwise the strip ends at "+".
        let shown = tabNames.prefix(n).filter { name($0) != nil }
        if !scrolls { #expect(shown.count == n, "\(tag): only \(shown) on screen") }
        // The tabs scroll inside their own area, which ends where "+" begins (a tab cut at its edge is clipped there).
        let area = try #require(app.rig.elements().first { $0.role == "AXScrollArea" && main.contains($0.centre) }, "\(tag): no tab scroll area")
        #expect(area.frame.minX >= main.minX - 0.5 && area.frame.maxX <= p.frame.minX + 0.5, "\(tag): the tabs' area \(area.frame), + at \(p.frame.minX)")

        // Selecting the last tab brings it fully into view.
        let lastName = tabNames[n - 1]
        bench.select(bench.tabs[n - 1].tabID)
        await app.settle()
        await app.idle(0.4)   // the scroll's animation
        let last = try #require(name(lastName), "\(tag): the last tab, selected, is not on screen")
        let lastClose = try #require(close(of: last), "\(tag): the last tab's × is not on screen")
        let plusNow = try plus()
        #expect(last.frame.minX >= main.minX && lastClose.frame.maxX <= plusNow.frame.minX + 0.5,
                "\(tag): the active tab is not fully in view (\(last.frame) … \(lastClose.frame), + at \(plusNow.frame.minX))")

        // Every tab on screen selects with a click on it and closes with its ×, until one is left.
        var guardRounds = 0
        while bench.tabs.count > 1, guardRounds < 2 * n {
            guardRounds += 1
            // The names shown whole (one cut at the strip's left edge lies against the side panel's splitter).
            let visible = tabNames.prefix(n).compactMap { s in name(s).map { (s, $0) } }.filter { $0.1.frame.minX >= main.minX }
            let target = try #require(visible.first { pair in bench.tabs.first { $0.project?.name == pair.0 }?.tabID != bench.activeID } ?? visible.first,
                                      "\(tag): no tab on screen")
            let tab = try #require(bench.tabs.first { $0.project?.name == target.0 })
            app.rig.click(target.1.centre)
            await app.settle()
            #expect(bench.activeID == tab.tabID, "\(tag): a click on «\(target.0)» did not select it")
            await app.idle(0.3)
            let text = try #require(name(target.0), "\(tag): «\(target.0)» left the screen when selected")
            let x = try #require(close(of: text), "\(tag): «\(target.0)» has no × on screen")
            let count = bench.tabs.count
            app.rig.click(x.centre)
            await app.idle(0.3)
            await app.settle()
            #expect(bench.tabs.count == count - 1 && !bench.tabs.contains { $0 === tab }, "\(tag): the × of «\(target.0)» did not close it")
        }
        #expect(bench.tabs.count == 1, "\(tag): \(bench.tabs.count) tabs left")
        // "+" opens a new tab, selected.
        app.rig.click(try plus().centre)
        await app.settle()
        #expect(bench.tabs.count == 2 && bench.active.isEmpty, "\(tag): + did not open a tab")
    }

    /// A narrow tab drops its duration first and keeps its dot, its name (truncated in the middle) and its ×.
    @Test func aNarrowTabDropsTheDurationFirst() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let info = TabInfo(id: "t", name: "Corso di montaggio lezione 3", duration: 228, state: .saved, active: true, path: nil, hasProject: true)
        for (width, durationShown) in [(320.0, true), (TabsLayout.minWidth, false)] {
            app.host(HStack(spacing: 0) { TabLabel(info: info).frame(width: width); Spacer(minLength: 0) }.background(Ed.bar),
                     size: CGSize(width: 400, height: Chrome.tabsHeight))
            await app.settle()
            // The tab's texts (they read as its tooltip): the name, then the duration when it shows.
            let texts = app.rig.elements().filter { $0.role == "AXStaticText" && $0.visible && $0.value.hasPrefix(info.name + "\n") }
                .sorted { $0.frame.minX < $1.frame.minX }
            #expect(texts.count == (durationShown ? 2 : 1), "at \(width) pt: \(texts.map(\.frame))")
            let title = try #require(texts.first, "at \(width) pt the name is gone")
            #expect(title.frame.maxX <= width, "at \(width) pt the name overflows the tab: \(title.frame)")
            #expect(app.rig.elements().contains { $0.role == "AXButton" && $0.frame.width <= 20 && $0.frame.maxX <= width && $0.visible },
                    "at \(width) pt the × is gone")
            app.rig.close()
        }
    }
}
}
