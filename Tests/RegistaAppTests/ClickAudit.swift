import AppKit
import SwiftUI
import Testing
@testable import Regista

// The click audit (#29): a screen's controls found in its accessibility tree (not from anyone's memory of where they
// are), each one clicked in turn with a real mouse event on a fresh copy of the screen, and what happened written
// down — a command in the activity log, a navigation change, a state of the store, a window, a panel, a change in
// what the screen shows — or NOTHING. Every NOTHING must be a disabled control or a no-op the test names with its
// reason; anything else fails the test. The tables are written as Markdown to $REGISTA_CLICK_AUDIT (or a temporary
// folder) and printed.

/// What the window and the store look like, to tell what a click changed.
@MainActor
struct AuditState {
    var commands: [String]
    var nav: Navigation
    var ui: [String: String]
    var events: [RigGuard.Event]
    var tree: [String]
    var responder: String
    var undo: Int

    init(_ app: AppRig) {
        let s = app.store
        commands = s.activity.map(\.command)
        nav = s.nav
        ui = [
            "tool": s.tool.rawValue, "selection": s.selection.sorted().joined(separator: ","),
            "captionPick": s.captionPick.map { "\($0)" } ?? "", "canvasSelection": s.canvasSelection ?? "",
            "sourceAsset": s.sourceAssetID ?? "", "safeZones": "\(s.safeZones)", "zoom": String(format: "%.2f", s.pxPerSec),
            "autoFit": "\(s.autoFit)", "words": s.wordSelection.map { "\($0)" } ?? "", "captionScope": "\(s.captionScope)",
            "brandKits": "\(s.showBrandKits)", "voiceSetup": "\(s.showVoiceSetup)", "error": s.errorMessage ?? "",
            "playing": "\(s.preview.isPlaying)", "playhead": String(format: "%.3f", s.preview.playhead.time),
            "tabs": "\(s.bench.tabs.count)/\(s.bench.activeID)", "jobs": "\(s.jobs.jobs.count)",
            "solo": s.preview.solo.sorted().joined(separator: ","), "dirty": "\(s.dirty)",
            "sourcePlaying": "\(FrameSourceTime.shared.playing)", "sourceTime": String(format: "%.2f", FrameSourceTime.shared.time),
            "settingsTab": UserDefaults.standard.string(forKey: SettingsRoute.tabKey) ?? "",
            "recorder": "\(app.recorder.sources)".hashValue.description,
            "graphics": { let g = GraphicsState.shared; return "\(g.intensity)|\(g.query)|\(g.clipScope)|\(g.motionItem ?? "")|\(g.textItem ?? "")|\(g.appliedSelection ?? "")" }(),
            "prompter": { let p = TeleprompterController.shared
                return "visible \(p.isVisible) playing \(p.isPlaying) size \(p.fontSize) speed \(p.speed) mirror \(p.mirror) mode \(p.mode)" }(),
            "sidePanel": "\(UserDefaults.standard.object(forKey: ShellPrefs.sideShown) as? Bool ?? true)",
            "rightPanel": "\(UserDefaults.standard.object(forKey: ShellPrefs.rightShown) as? Bool ?? true)",
            "sheet": app.rig.window.attachedSheet.map { "\(type(of: $0))" } ?? "",
            // What reaches the rig's stand-ins (#35): a take, the installer, the pasteboard, the Trash.
            "recorder state": "recording \(app.recorder.isRecording) error \(app.recorder.errorMessage ?? "")",
            "installer": rigOutside.installs.last ?? "",
            "engine files": "\((FileManager.default.enumerator(atPath: rigOutside.enginesFolder.path)?.allObjects.count) ?? 0)", "pasteboard": "\(RigPasteboard.writes) writes", "trash": RigTrash.taken.last ?? "",
            "claude": "claude command \(((try? String(contentsOf: rigOutside.claudeLog, encoding: .utf8)) ?? "").count) bytes, Claude Desktop configuration \(FileManager.default.contents(atPath: rigOutside.desktopConfig.path)?.count ?? 0) bytes",
            "engines.json": (try? String(contentsOf: rigOutside.enginesFile, encoding: .utf8)).map { "\($0.hashValue)" } ?? "",
            "generation": "\(s.generation.pending != nil) \(s.generation.problem ?? "")",
            "popover": NSApp.windows.filter { $0.isVisible && $0 !== app.rig.window && String(describing: type(of: $0)).contains("Popover") }.count.description,
        ]
        events = RigGuard.events
        tree = app.rig.elements().filter(\.visible).map { "\($0.role)|\($0.name)|\($0.value)|\($0.valueDescription)|\($0.selected)|\($0.enabled)" }
        responder = app.rig.window.firstResponder.map { String(describing: type(of: $0)) } ?? ""
        undo = s.undoNames.count
    }

    /// The differences from `before`, in words; empty when nothing changed.
    func changes(since before: AuditState) -> [String] {
        var out: [String] = []
        if commands.count > before.commands.count { out.append("command " + commands.dropFirst(before.commands.count).joined(separator: ", ")) }
        if nav != before.nav {
            var n: [String] = []
            if nav.activity != before.nav.activity { n.append("activity \(nav.activity.rawValue)") }
            if nav.level != before.nav.level { n.append("level \(nav.level.rawValue)") }
            if nav.rightTab != before.nav.rightTab { n.append("right tab \(nav.rightTab.rawValue)") }
            if nav.textsTab != before.nav.textsTab { n.append("texts tab \(nav.textsTab.rawValue)") }
            if nav.graphicsSection != before.nav.graphicsSection { n.append("graphics \(nav.graphicsSection.rawValue)") }
            if nav.soundTab != before.nav.soundTab { n.append("sound tab \(nav.soundTab.rawValue)") }
            out.append("navigation: " + n.joined(separator: ", "))
        }
        for (k, v) in ui.sorted(by: { $0.key < $1.key }) where before.ui[k] != v {
            out.append(k == "error" ? "error shown «\(v.prefix(60))»" : "\(k) \(before.ui[k] ?? "") → \(v)")
        }
        if events.count > before.events.count { out += events.dropFirst(before.events.count).map(\.description) }
        if responder != before.responder, responder.contains("Text") { out.append("typing (\(responder))") }
        let added = Set(tree).subtracting(before.tree), removed = Set(before.tree).subtracting(tree)
        if !added.isEmpty || !removed.isEmpty {
            let sample = added.compactMap { $0.split(separator: "|").dropFirst().first.map(String.init) }.filter { !$0.isEmpty }.prefix(2)
            out.append("screen changed (+\(added.count) −\(removed.count)\(sample.isEmpty ? "" : ": " + sample.map { "«\($0.prefix(30))»" }.joined(separator: " ")))")
        }
        return out
    }
}

/// The click audits of whole screens take most of the suite's time (about six of its nine minutes). The commit hook
/// skips them (`REGISTA_SKIP_CLICK_AUDIT=1`) and the push hook runs them: every control is still clicked before
/// anything is published, once per push instead of once per commit.
let clickAuditEnabled = ProcessInfo.processInfo.environment["REGISTA_SKIP_CLICK_AUDIT"] == nil

extension MouseSuites {
    /// Every click audit of whole screens and windows (ScreenClickTests, MoreScreenClickTests, WindowsClickTests) and the
    /// whole journeys (JourneyTests), inside
    /// the proof of #35: the owner's side is the same after them as before, no process was refused, the clipboard was
    /// not written.
    @Suite(.serialized, .ownerSideUntouched, .enabled(if: clickAuditEnabled, "skipped in the commit hook, run by the push hook"))
    struct ClickAudits {}
}

@MainActor
struct ClickAudit {
    struct Row {
        let control: String
        let at: CGPoint
        var effect: String
        /// Nothing changed (and the control is enabled).
        var nothing = false
        /// Why a NOTHING (or a control not clicked) is right.
        var reason: String?
        /// The control was not clicked.
        var skipped = false
        /// A defect: covered by another element, gone after its own click, a disabled control that reacted.
        var problem: String?
    }

    let app: AppRig
    let screen: String
    /// Controls not clicked (prefix of the name → why: a capture would start, a paid call, a modal tracking loop…).
    var skip: [String: String] = [:]
    /// Controls whose click is right to change nothing here (prefix of the name → why).
    var noOps: [String: String] = [:]
    /// Run after each click, before the screen is rebuilt (put back what the click changed outside the store).
    var restore: () -> Void = {}
    /// Run after the screen was rebuilt (state its views reset when they appear, such as a pending estimate).
    var afterReset: () async -> Void = {}
    /// Controls not clicked whose name contains a text (text → why).
    var skipContaining: [String: String] = [:]
    /// Roles not clicked (role → why).
    var skipRoles: [String: String] = [:]
    /// Only the controls inside this rect of the window (nil: all).
    var area: CGRect? = nil
    /// AppKit's own controls (the Settings form's pop-ups, check boxes, bordered buttons, text fields) are driven through
    /// their accessibility actions instead of a click (#36): synthetic events do not drive them reliably, an assistive
    /// client's actions do. The table says which action.
    var nativeByAccessibility = false
    /// Targets the accessibility tree does not expose (a tile with a tap gesture, a clip drawn on a canvas): a name and
    /// the point to click, clicked after the controls the tree lists.
    var extra: [(name: String, at: CGPoint)] = []

    private final class Box<T> { var value: T?; init() {} }
    private let prompterBox = Box<(mode: TeleprompterController.Mode, speed: Double, fontSize: Double, mirror: Bool, language: String,
                                   redoWords: String, stopWords: String)>()
    private var prompter: (mode: TeleprompterController.Mode, speed: Double, fontSize: Double, mirror: Bool, language: String,
                           redoWords: String, stopWords: String)? {
        get { prompterBox.value }
        nonmutating set { prompterBox.value = newValue }
    }

    private let sourcesBox = Box<RecordingSources>()

    /// The controls on screen inside `area` (all of them without one), in the tree's order.
    private func controlsInArea() -> [RigElement] {
        app.rig.controls().filter { area == nil || area!.contains($0.centre) }
    }

    private func match(_ name: String, _ table: [String: String]) -> String? {
        table.first { !$0.key.isEmpty && name.hasPrefix($0.key) }?.value
    }

    /// Clicks every control of the screen once, each on the screen as it was at the start.
    func run() async -> [Row] {
        let rig = app.rig!
        rig.host.layoutSubtreeIfNeeded()
        await app.idle(0.15)
        let p = TeleprompterController.shared
        prompter = (p.mode, p.speed, p.fontSize, p.mirror, p.language, p.redoWords, p.stopWords)
        sourcesBox.value = app.recorder.sources
        let base = AuditState(app)
        let baseNav = app.store.nav
        let targets = controlsInArea()
        var seen: [String: Int] = [:]
        var rows: [Row] = []
        // The screen is rebuilt only after a click that changed something (a click that changed nothing left it as it was).
        var dirty = true
        for t in targets {
            let n = seen[t.key, default: 0]
            seen[t.key] = n + 1
            if let why = match(t.name, skip) ?? skipRoles[t.role] ?? skipContaining.first(where: { t.name.contains($0.key) })?.value {
                rows.append(Row(control: t.description, at: t.centre, effect: "not clicked", reason: why, skipped: true))
                continue
            }
            if dirty { await back(to: base, nav: baseNav) }
            dirty = true
            // Found again among the controls of the audited area, by name and index there (#48): a control of the same
            // name outside the area (the activity bar's «Voce» beside the Gobbo's) is not the one to click.
            // A list that loads after the screen is rebuilt (the sound bank): wait for the control a moment.
            var found = controlsInArea().filter({ $0.key == t.key })[safe: n]
            for _ in 0..<10 where found == nil {
                await app.idle(0.1)
                found = controlsInArea().filter({ $0.key == t.key })[safe: n]
            }
            guard let e = found else {
                rows.append(Row(control: t.description, at: t.centre, effect: "not found again on a fresh screen", problem: "unstable"))
                continue
            }
            if let why = match(e.name, skip) ?? skipRoles[e.role] ?? skipContaining.first(where: { e.name.contains($0.key) })?.value {
                rows.append(Row(control: e.description, at: e.centre, effect: "not clicked", reason: why, skipped: true))
                continue
            }
            // A slider: a click 70 % along it (its middle may already be its value; past the bars of an intensity bar
            // lies its "tanto" label).
            // A labelled RSlider is one element with its label row above the 18 pt track: the click goes on the track.
            let p = e.role == "AXUnknown" && e.frame.width > e.frame.height * 2
                ? CGPoint(x: e.frame.minX + e.frame.width * 0.7, y: e.frame.height > 24 ? e.frame.maxY - 9 : e.frame.midY) : e.centre
            var problem: String?
            if let hit = rig.elementAt(p), hit !== e.ref, !(hit.isEqual(e.ref)), let over = rig.elements().first(where: { $0.ref === hit }),
               over.isControl {
                problem = "covered by \(over.description)"
            }
            let before = AuditState(app)
            let refused = RigProcesses.refused.count
            let action = nativeByAccessibility ? rig.performAccessibility(e) : nil
            // A slider that says its value (#36: Export's bit rate) is dragged along its track, from 30 % to 70 %, and its
            // value read before and after as an assistive client reads it.
            let slider = action == nil && e.role == "AXUnknown" && e.frame.width > e.frame.height * 2 && !e.valueDescription.isEmpty
            var moved: String?
            if slider {
                let from = CGPoint(x: e.frame.minX + e.frame.width * 0.3, y: p.y)
                rig.drag(from: from, by: CGSize(width: e.frame.width * 0.4, height: 0))
                await app.settle()
                let after = controlsInArea().first { $0.key == e.key }?.valueDescription ?? "?"
                if after != e.valueDescription { moved = "value «\(e.valueDescription)» → «\(after)» (dragged)" }
            } else if action == nil { rig.click(p) }
            await app.settle()
            // An alert the click's command opened (its error) animates in: its stop lands in a loop of ours (#40).
            if before.ui["sheet"] == "", rig.window.attachedSheet != nil { rig.hold() }
            var changes = AuditState(app).changes(since: before)
            if let moved { changes.insert(moved, at: 0) }
            if changes.isEmpty {
                // A tap that also answers a double tap, a popover: they come after the double-click interval.
                await app.idle(NSEvent.doubleClickInterval + 0.1)
                await app.settle()
                changes = AuditState(app).changes(since: before)
            }
            // Still there: the same control (by name) or a control of its role where it was (a switch named by its value).
            let still = controlsInArea().contains { $0.key == e.key || ($0.role == e.role && abs($0.centre.x - e.centre.x) < 2 && abs($0.centre.y - e.centre.y) < 2) }
                || changes.contains { $0.hasPrefix("navigation") || $0.hasPrefix("command") }
            if !still, !changes.isEmpty { changes.append("the control left the screen") }
            var row = Row(control: e.description + (e.enabled ? "" : " [disabled]") + (action.map { " (\($0))" } ?? ""), at: p,
                          effect: changes.isEmpty ? "NOTHING" : changes.joined(separator: "; "))
            dirty = !changes.isEmpty
            if !e.enabled {
                if !changes.isEmpty, changes.contains(where: { $0.hasPrefix("command") || $0.hasPrefix("navigation") }) {
                    row.problem = "a disabled control reacted"
                } else {
                    row.effect = changes.isEmpty ? "nothing (disabled)" : row.effect
                    row.reason = "disabled"
                }
            } else if changes.isEmpty {
                row.nothing = true
                row.reason = match(e.name, noOps)
            }
            if let problem { row.problem = problem }
            if RigProcesses.refused.count > refused { row.problem = "refused process: " + RigProcesses.refused.dropFirst(refused).joined(separator: "; ") }
            rows.append(row)
            // A click that opened an alert (a confirmation): each of its buttons is clicked too, each on the alert opened
            // again from a fresh screen.
            let buttons = rig.sheetButtons().map(\.title)
            if !buttons.isEmpty {
                for title in buttons {
                    rows.append(await clickInAlert(opener: e, at: p, button: title, base: base, nav: baseNav))
                }
                dirty = true
            }
        }
        for x in extra {
            await back(to: base, nav: baseNav)
            if let why = match(x.name, skip) {
                rows.append(Row(control: x.name, at: x.at, effect: "not clicked", reason: why, skipped: true))
                continue
            }
            let before = AuditState(app)
            rig.click(x.at)
            // A tap that also answers a double tap fires after the double-click interval.
            await app.idle(NSEvent.doubleClickInterval + 0.1)
            await app.settle()
            let changes = AuditState(app).changes(since: before)
            var row = Row(control: x.name + " (by position)", at: x.at, effect: changes.isEmpty ? "NOTHING" : changes.joined(separator: "; "))
            if changes.isEmpty { row.nothing = true; row.reason = match(x.name, noOps) }
            rows.append(row)
        }
        await back(to: base, nav: baseNav)
        write(rows)
        return rows
    }

    /// Opens the alert again with a click on `opener` and clicks its button `title`.
    private func clickInAlert(opener e: RigElement, at p: CGPoint, button title: String, base: AuditState, nav: Navigation) async -> Row {
        let rig = app.rig!
        let name = e.description + " › «\(title)»"
        await back(to: base, nav: nav)
        rig.click(p)
        await app.settle()
        guard let button = rig.sheetButtons().first(where: { $0.title == title }) else {
            return Row(control: name, at: p, effect: "the alert did not open again", problem: "unstable")
        }
        if let why = match(title, skip) {
            return Row(control: name, at: p, effect: "not clicked", reason: why, skipped: true)
        }
        let before = AuditState(app)
        let refused = RigProcesses.refused.count
        rig.click(button)
        await app.settle()
        await app.idle(0.3)
        await app.settle()
        let changes = AuditState(app).changes(since: before)
        var row = Row(control: name, at: p, effect: changes.isEmpty ? "NOTHING" : changes.joined(separator: "; "))
        if changes.isEmpty { row.nothing = true; row.reason = match(title, noOps) }
        if RigProcesses.refused.count > refused { row.problem = "refused process: " + RigProcesses.refused.dropFirst(refused).joined(separator: "; ") }
        return row
    }

    /// The screen as it was: sheets and popovers closed, the store's UI state and the project put back, the tree rebuilt.
    private func back(to base: AuditState, nav: Navigation) async {
        let rig = app.rig!
        let s = app.store
        // The teleprompter is one for the whole app: hidden, stopped and set back as it was.
        let p = TeleprompterController.shared
        if p.isVisible { p.hide() }
        if let v = prompter {
            if p.mode != v.mode { p.mode = v.mode }
            if p.speed != v.speed { p.speed = v.speed }
            if p.fontSize != v.fontSize { p.fontSize = v.fontSize }
            if p.mirror != v.mirror { p.mirror = v.mirror }
            if p.language != v.language { p.language = v.language }
            if p.redoWords != v.redoWords { p.redoWords = v.redoWords }
            if p.stopWords != v.stopWords { p.stopWords = v.stopWords }
        }
        if let sheet = rig.window.attachedSheet {
            rig.window.endSheet(sheet)
            rig.hold()
        }
        for w in NSApp.windows where w !== rig.window && w.isVisible && !(w is RigWindow) { w.orderOut(nil) }
        restore()
        // A take the click started stops (the capture stand-in writes nothing); its message goes.
        if app.recorder.isRecording {
            app.recorder.stop()
            for _ in 0..<20 where app.recorder.isRecording { await app.idle(0.05) }
        }
        app.recorder.errorMessage = nil
        if let src = sourcesBox.value, app.recorder.sources != src { app.recorder.sources = src }
        // The Graphics panel's state is one for the app: back to how the screen started.
        let g = GraphicsState.shared
        if g.intensity != 0.5 { g.intensity = 0.5 }
        if !g.query.isEmpty { g.query = "" }
        if g.clipScope { g.clipScope = false }
        if g.motionItem != nil { g.motionItem = nil }
        if g.textItem != nil { g.textItem = nil }
        if g.appliedSelection != nil { g.appliedSelection = nil }
        if s.preview.isPlaying { s.preview.togglePlay() }
        if FrameSourceTime.shared.playing { FrameSourceTime.shared.toggle() }
        // Tabs a click opened go, the tab of the screen comes back on screen, a project a click closed is reopened.
        let tabs = base.ui["tabs"] ?? ""
        let activeID = String(tabs.split(separator: "/").last ?? "")
        for t in s.bench.tabs where t !== s { _ = await s.bench.close(t) }
        if s.bench.activeID != activeID { s.bench.select(activeID) }
        if s.project == nil, let path = app.projectPath { _ = try? await s.perform("project.open", ["path": .string(path.path)]) }
        for _ in 0..<20 where s.undoNames.count > base.undo { _ = try? await s.perform("history.undo") }
        s.nav = nav
        s.tool = EditorStore.Tool(rawValue: base.ui["tool"] ?? "select") ?? .select
        s.selection = Set((base.ui["selection"] ?? "").split(separator: ",").map(String.init))
        s.captionPick = nil
        s.canvasSelection = nil
        s.wordSelection = nil
        s.showBrandKits = false
        s.showVoiceSetup = false
        s.errorMessage = nil
        s.preview.solo = []
        s.safeZones = base.ui["safeZones"] == "true"
        if let z = Double(base.ui["zoom"] ?? "") { s.pxPerSec = z }
        s.autoFit = base.ui["autoFit"] == "true"
        s.preview.seek(Double(base.ui["playhead"] ?? "0") ?? 0)
        FrameSourceTime.shared.seek(Double(base.ui["sourceTime"] ?? "0") ?? 0)
        UserDefaults.standard.set(base.ui["sidePanel"] == "true", forKey: ShellPrefs.sideShown)
        UserDefaults.standard.set(base.ui["rightPanel"] == "true", forKey: ShellPrefs.rightShown)
        if let tab = base.ui["settingsTab"], !tab.isEmpty { UserDefaults.standard.set(tab, forKey: SettingsRoute.tabKey) }
        else { UserDefaults.standard.removeObject(forKey: SettingsRoute.tabKey) }
        rig.window.makeFirstResponder(nil)
        app.reset.bump()
        await app.settle()
        // AppKit-backed controls (native buttons, text fields) of the rebuilt tree are placed a moment later.
        rig.host.layoutSubtreeIfNeeded()
        await app.idle(0.15)
        await afterReset()
    }

    /// The table, as Markdown, in $REGISTA_CLICK_AUDIT (or a temporary folder).
    private func write(_ rows: [Row]) {
        var md = "### \(screen)\n\n| Control | Clicked at | Effect observed |\n|---|---|---|\n"
        for r in rows {
            var effect = r.effect
            if let p = r.problem { effect = "**DEFECT: \(p)** — " + effect }
            if let why = r.reason, r.nothing || r.skipped { effect += " — \(r.skipped ? "" : "justified: ")\(why)" }
            md += "| \(r.control.replacingOccurrences(of: "|", with: "/")) | \(Int(r.at.x)),\(Int(r.at.y)) | \(effect.replacingOccurrences(of: "|", with: "/")) |\n"
        }
        let dir = ProcessInfo.processInfo.environment["REGISTA_CLICK_AUDIT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("regista-click-audit")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? md.write(to: dir.appendingPathComponent("\(screen).md"), atomically: true, encoding: .utf8)
    }

    /// The test's verdict: no defect, and every NOTHING justified.
    static func check(_ rows: [Row], screen: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(!rows.isEmpty, "the audit found no control on \(screen)", sourceLocation: sourceLocation)
        for r in rows {
            if let p = r.problem { Issue.record("\(screen): \(r.control) — \(p) (\(r.effect))", sourceLocation: sourceLocation) }
            if r.nothing, r.reason == nil { Issue.record("\(screen): \(r.control) — a click changed NOTHING", sourceLocation: sourceLocation) }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
