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
            "prompter": "\(TeleprompterController.shared.isVisible)/\(TeleprompterController.shared.isPlaying)",
            "sidePanel": "\(UserDefaults.standard.object(forKey: ShellPrefs.sideShown) as? Bool ?? true)",
            "rightPanel": "\(UserDefaults.standard.object(forKey: ShellPrefs.rightShown) as? Bool ?? true)",
            "sheet": app.rig.window.attachedSheet.map { "\(type(of: $0))" } ?? "",
            "popover": NSApp.windows.filter { $0.isVisible && $0 !== app.rig.window && String(describing: type(of: $0)).contains("Popover") }.count.description,
        ]
        events = RigGuard.events
        tree = app.rig.elements().filter(\.visible).map { "\($0.role)|\($0.name)|\($0.value)|\($0.selected)|\($0.enabled)" }
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
    /// Only the controls inside this rect of the window (nil: all).
    var area: CGRect? = nil
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

    private func match(_ name: String, _ table: [String: String]) -> String? {
        table.first { !$0.key.isEmpty && name.hasPrefix($0.key) }?.value
    }

    /// Clicks every control of the screen once, each on the screen as it was at the start.
    func run() async -> [Row] {
        let rig = app.rig!
        let p = TeleprompterController.shared
        prompter = (p.mode, p.speed, p.fontSize, p.mirror, p.language, p.redoWords, p.stopWords)
        sourcesBox.value = app.recorder.sources
        let base = AuditState(app)
        let baseNav = app.store.nav
        let targets = rig.controls().filter { area == nil || area!.contains($0.centre) }
        var seen: [String: Int] = [:]
        var rows: [Row] = []
        for t in targets {
            let n = seen[t.key, default: 0]
            seen[t.key] = n + 1
            await back(to: base, nav: baseNav)
            // A list that loads after the screen is rebuilt (the sound bank): wait for the control a moment.
            var found = rig.controls().filter({ $0.key == t.key })[safe: n]
            for _ in 0..<10 where found == nil {
                try? await Task.sleep(for: .milliseconds(100))
                rig.pump(0.02)
                found = rig.controls().filter({ $0.key == t.key })[safe: n]
            }
            guard let e = found else {
                rows.append(Row(control: t.description, at: t.centre, effect: "not found again on a fresh screen", problem: "unstable"))
                continue
            }
            if let why = match(e.name, skip) {
                rows.append(Row(control: e.description, at: e.centre, effect: "not clicked", reason: why, skipped: true))
                continue
            }
            // A slider: a click three quarters along its track (its middle may already be its value).
            let p = e.role == "AXUnknown" && e.frame.width > e.frame.height * 3 ? CGPoint(x: e.frame.minX + e.frame.width * 0.8, y: e.frame.midY) : e.centre
            var problem: String?
            if let hit = rig.elementAt(p), hit !== e.ref, !(hit.isEqual(e.ref)), let over = rig.elements().first(where: { $0.ref === hit }),
               over.isControl {
                problem = "covered by \(over.description)"
            }
            let before = AuditState(app)
            rig.click(p)
            await app.settle()
            let after = AuditState(app)
            var changes = after.changes(since: before)
            let still = rig.controls().contains { $0.key == e.key } || changes.contains { $0.hasPrefix("navigation") || $0.hasPrefix("command") }
            if !still, !changes.isEmpty { changes.append("the control left the screen") }
            var row = Row(control: e.description + (e.enabled ? "" : " [disabled]"), at: p, effect: changes.isEmpty ? "NOTHING" : changes.joined(separator: "; "))
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
            rows.append(row)
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
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
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
        if let sheet = rig.window.attachedSheet { rig.window.endSheet(sheet) }
        for w in NSApp.windows where w !== rig.window && w.isVisible && !(w is RigWindow) { w.orderOut(nil) }
        restore()
        if let src = sourcesBox.value, app.recorder.sources != src { app.recorder.sources = src }
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
        s.selection = []
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
        UserDefaults.standard.removeObject(forKey: SettingsRoute.tabKey)
        rig.window.makeFirstResponder(nil)
        app.reset.bump()
        await app.settle()
        rig.pump(0.1)
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
