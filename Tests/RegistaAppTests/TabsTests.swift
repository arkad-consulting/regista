import AppKit
import Foundation
import RegistaCore
import RegistaMCP
import Testing
@testable import Regista

// S2 #76: several projects open at once, one engine per tab; the agent's commands go to the active tab or to the one
// they name, without switching the user's view.

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-tabs-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func scratchDefaults() -> UserDefaults {
    let name = "regista-tabs-tests-\(UUID().uuidString)"
    let d = UserDefaults(suiteName: name)!
    d.removePersistentDomain(forName: name)
    return d
}

/// A saved `.regista` project in `dir`.
private func savedProject(_ name: String, in dir: URL) throws -> URL {
    let folder = dir.appendingPathComponent("\(name).regista")
    try ProjectStore.save(Project(name: name, settings: ProjectSettings()), to: folder)
    return folder
}

/// A workbench without the engine socket (tests never reach a running app).
@MainActor
private func bench(_ defaults: UserDefaults = scratchDefaults()) -> Workbench {
    _ = NSApplication.shared
    return Workbench(defaults: defaults, seedFolders: [], socketPath: nil)
}

/// Lets the main queue deliver the snapshots the tab queues posted: waits until `done` holds (polling, up to 20 s). A
/// fixed pause fails when the machine is busy (#80).
@MainActor private func settle(until done: () -> Bool) async throws {
    for _ in 0..<200 where !done() { try await Task.sleep(for: .milliseconds(100)) }
}

/// The agent's command as the socket runs it: off the main thread, routed by the workbench.
private func agent(_ b: Workbench, _ id: String, _ params: JSONValue = [:]) async throws -> JSONValue {
    try await Task.detached { try b.agentExecute(id, params, client: "claude-code") }.value
}

@MainActor
@Test func twoTabsHaveTheirOwnProjectAndUndo() async throws {
    let b = bench(), dir = tempDir()
    let one = b.newTab(), two = b.newTab()
    #expect(one.engine !== two.engine)
    try await one.perform("project.new", ["name": "uno", "directory": .string(dir.path)])
    try await two.perform("project.new", ["name": "due", "directory": .string(dir.path)])
    try await one.perform("track.add", ["kind": "video"])
    try await one.perform("track.add", ["kind": "audio"])
    try await two.perform("track.add", ["kind": "audio"])
    try await settle { one.project?.tracks.count == 2 && two.project?.tracks.count == 1 && one.undoNames.count == 2 && two.undoNames.count == 1 }
    #expect(one.project?.tracks.count == 2 && two.project?.tracks.count == 1)
    #expect(one.undoNames.count == 2 && two.undoNames.count == 1)
    // Undo in one tab leaves the other untouched.
    try await one.perform("history.undo")
    try await settle { one.project?.tracks.count == 1 && one.redoNames == ["track.add"] }
    #expect(one.project?.tracks.count == 1 && one.redoNames == ["track.add"])
    #expect(two.project?.tracks.count == 1 && two.project?.tracks.first?.kind == .audio && two.undoNames.count == 1 && two.redoNames.isEmpty)
    #expect(one.project?.name == "uno" && two.project?.name == "due")
}

@MainActor
@Test func closingADirtyTabAsksAndCancelKeepsIt() async throws {
    let b = bench(), dir = tempDir()
    let one = b.newTab(), two = b.newTab()
    b.select(two.tabID)
    try await two.perform("project.new", ["name": "sporco", "directory": .string(dir.path)])
    try await two.perform("track.add", ["kind": "video"])
    try await settle { two.dirty && two.project?.tracks.count == 1 }
    #expect(two.dirty)
    var asked: [String] = []
    b.saveDecision = { asked.append($0); return .cancel }
    #expect(await b.close(two) == false)
    #expect(asked == ["sporco"] && b.tabs.count == 2 && two.project != nil)
    // Non salvare: the project closes and its tab goes; the other tab is selected.
    b.saveDecision = { asked.append($0); return .discard }
    #expect(await b.close(two) == true)
    #expect(asked.count == 2 && b.tabs.map(\.tabID) == [one.tabID] && b.activeID == one.tabID)
    // A clean tab closes without asking; the last tab stays, empty.
    #expect(await b.close(one) == true)
    #expect(asked.count == 2 && b.tabs.count == 1 && b.active.isEmpty)
}

@MainActor
@Test func openTabsComeBackAtLaunchAndMissingOnesAreSkipped() async throws {
    let defaults = scratchDefaults(), dir = tempDir()
    let a = try savedProject("primo", in: dir), c = try savedProject("terzo", in: dir)
    let missing = dir.appendingPathComponent("sparito.regista").path
    defaults.set([a.path, missing, c.path], forKey: Workbench.tabsKey)
    defaults.set(2, forKey: Workbench.activeTabKey)   // "terzo"
    let b = bench(defaults)
    b.restoreTabs()
    try await settle { b.tabs.count == 2 && b.tabs.allSatisfy { $0.project != nil } }
    #expect(b.tabs.map { $0.project?.name } == ["primo", "terzo"])
    #expect(b.active.project?.name == "terzo")
    #expect(b.activity.contains { $0.note?.contains("sparito") == true })
    // What is stored now: the two tabs, the second selected; the next launch opens them again.
    #expect(defaults.stringArray(forKey: Workbench.tabsKey) == [a, c].map { RecentList.normalized($0.path) })
    #expect(defaults.integer(forKey: Workbench.activeTabKey) == 1)
    let next = bench(defaults)
    next.restoreTabs()
    try await settle { next.tabs.count == 2 && next.tabs.allSatisfy { $0.project != nil } && next.active.project?.name == "terzo" }
    #expect(next.tabs.map { $0.project?.name } == ["primo", "terzo"] && next.active.project?.name == "terzo")
    // Nothing remembered: one empty tab.
    let fresh = bench()
    fresh.restoreTabs()
    #expect(fresh.tabs.count == 1 && fresh.active.isEmpty)
}

@MainActor
@Test func agentCommandsGoToTheActiveTabOrTheNamedOneWithoutSwitching() async throws {
    let b = bench(), dir = tempDir()
    let one = b.newTab(), two = b.newTab()
    try await one.perform("project.new", ["name": "uno", "directory": .string(dir.path)])
    try await one.perform("project.save")
    try await two.perform("project.new", ["name": "due", "directory": .string(dir.path)])
    b.select(two.tabID)
    // No project: the active tab.
    _ = try await agent(b, "track.add", ["kind": "video"])
    try await settle { two.project?.tracks.count == 1 }
    #expect(two.project?.tracks.count == 1 && one.project?.tracks.isEmpty == true)
    // By path and by tab id: that tab, and the selection does not move.
    _ = try await agent(b, "track.add", ["kind": "audio", "project": .string(one.projectURL!.path)])
    _ = try await agent(b, "track.add", ["kind": "video", "project": .string(one.tabID)])
    try await settle { one.project?.tracks.count == 2 }
    #expect(one.project?.tracks.count == 2 && two.project?.tracks.count == 1 && b.activeID == two.tabID)
    // The log says where a command ran when that tab was not on screen.
    #expect(b.activity.last { $0.command == "track.add" }?.project == "uno")
    // Undo by project: only that tab.
    _ = try await agent(b, "history.undo", ["project": .string(one.tabID)])
    try await settle { one.project?.tracks.count == 1 }
    #expect(one.project?.tracks.count == 1 && two.project?.tracks.count == 1)
    // A project that is not open: a clear error, nothing changes.
    await #expect(throws: CommandError.self) { _ = try await agent(b, "track.add", ["kind": "audio", "project": "/tmp/nope.regista"]) }
    // project.list: the tabs in order, the active one, dirty state.
    let list = try await agent(b, "project.list")
    let tabs = try #require(list["tabs"]?.arrayValue)
    #expect(tabs.count == 2 && list["active"]?.stringValue == two.tabID)
    #expect(tabs[0]["id"]?.stringValue == one.tabID && tabs[0]["name"] == "uno" && tabs[0]["active"] == false && tabs[0]["dirty"] == true)
    #expect(tabs[1]["name"] == "due" && tabs[1]["active"] == true && tabs[1]["recording"] == false)
}

@MainActor
@Test func agentOpenAddsASelectedTabAndCloseRemovesTheNamedOne() async throws {
    let b = bench(), dir = tempDir()
    let first = b.newTab()
    b.select(first.tabID)
    let a = try savedProject("alfa", in: dir), c = try savedProject("gamma", in: dir)
    // The empty active tab takes the first project…
    _ = try await agent(b, "project.open", ["path": .string(a.path)])
    try await settle { first.project?.name == "alfa" }
    #expect(b.tabs.count == 1 && first.project?.name == "alfa")
    // …the next one opens in a new tab, selected, and the log says so.
    _ = try await agent(b, "project.open", ["path": .string(c.path)])
    try await settle { b.tabs.count == 2 && b.active.project?.name == "gamma" }
    #expect(b.tabs.count == 2 && b.active.project?.name == "gamma" && b.active !== first)
    #expect(b.activity.contains { $0.isAgent && $0.note?.contains("gamma") == true })
    // An open project is not reloaded: its tab is selected (unsaved edits survive).
    _ = try await agent(b, "track.add", ["kind": "video", "project": .string(first.tabID)])
    let r = try await agent(b, "project.open", ["path": .string(a.path)])
    try await settle { b.activeID == first.tabID && first.project?.tracks.count == 1 }
    #expect(b.tabs.count == 2 && b.activeID == first.tabID && first.project?.tracks.count == 1 && r["name"] == "alfa")
    // project.new from the agent: a new tab too.
    _ = try await agent(b, "project.new", ["name": "delta", "directory": .string(dir.path)])
    try await settle { b.tabs.count == 3 && b.active.project?.name == "delta" }
    #expect(b.tabs.count == 3 && b.active.project?.name == "delta")
    // project.close on another tab: refused while dirty, closes it with discard; the selection stays.
    let delta = b.active
    await #expect(throws: CommandError.self) { _ = try await agent(b, "project.close", ["project": .string(first.tabID)]) }
    _ = try await agent(b, "project.close", ["project": .string(first.tabID), "discard": true])
    try await settle { b.tabs.count == 2 && !b.tabs.contains { $0 === first } }
    #expect(b.tabs.count == 2 && !b.tabs.contains { $0 === first } && b.active === delta)
}

@MainActor
@Test func aRecordingBelongsToItsTabAndASecondOneIsRefused() async throws {
    let b = bench(), dir = tempDir()
    let one = b.newTab(), two = b.newTab()
    b.select(one.tabID)
    try await two.perform("project.new", ["name": "montaggio", "directory": .string(dir.path)])
    b.recordingStarted()   // the recorder started while the first tab was on screen
    #expect(b.recordingTabID == one.tabID && !one.isEmpty)
    b.select(two.tabID)
    #expect(b.recordingRefusal(for: one) == nil)
    let why = try #require(b.recordingRefusal(for: two))
    #expect(why.contains("Nuova scheda"))
    let list = try await agent(b, "project.list")
    let rows = list["tabs"]?.arrayValue ?? []
    #expect(rows.count == 2 && rows[0]["recording"] == true && rows[1]["recording"] == false)
    // Stopped: the take goes to its own tab (still empty), not to the one on screen.
    b.recordingStopped()
    #expect(b.recordingRefusal(for: two) == nil)
    #expect(b.recordingTarget(newProject: true) === one && b.activeID == two.tabID)
    // A screen session started from a tab with a project opens in a new tab (the project is not replaced).
    b.recordingStarted()
    b.recordingStopped()
    let target = b.recordingTarget(newProject: true)
    #expect(target !== two && target.isEmpty && b.tabs.count == 3)
}

@MainActor
@Test func aTabInTheBackgroundLetsGoOfItsPlayer() async throws {
    let b = bench()
    let one = b.newTab(), two = b.newTab()
    b.select(one.tabID)
    #expect(one.isActive && !two.isActive)
    b.select(two.tabID)
    #expect(one.preview.program.player.currentItem == nil && one.preview.source.player.currentItem == nil)
    // Moving and the strip order.
    b.move(two.tabID, to: one.tabID)
    #expect(b.tabs.map(\.tabID) == [two.tabID, one.tabID])
    b.selectNext(1)
    #expect(b.activeID == one.tabID)
    b.selectNext(1)
    #expect(b.activeID == two.tabID)
}

/// The whole MCP path: MCPServer → SocketEngineHost → the workbench's engine socket → the tabs.
@MainActor
@Test func mcpToolsReachTheTabsThroughTheSocket() async throws {
    _ = NSApplication.shared
    // A short path: a Unix socket path is limited to 104 bytes (the temporary folder is too deep).
    let sock = URL(fileURLWithPath: "/tmp/regista-tabs-\(UUID().uuidString.prefix(8)).sock")
    defer { unlink(sock.path) }
    let workbench = Workbench(defaults: scratchDefaults(), seedFolders: [], socketPath: sock)
    let dir = tempDir()
    let first = workbench.newTab()
    workbench.select(first.tabID)
    let transcript = try await Task.detached { () -> [String] in
        let server = MCPServer(host: try SocketEngineHost(path: sock, client: "claude-code"))
        var lines: [String] = []
        var n = 0
        func call(_ tool: String, _ args: JSONValue) -> JSONValue {
            n += 1
            let req: JSONValue = ["jsonrpc": "2.0", "id": .number(Double(n)), "method": "tools/call", "params": ["name": .string(tool), "arguments": args]]
            let reply = server.handle(req) ?? .null
            lines.append("→ \(tool) \(args.text())")
            lines.append("← \(reply.value(at: "result.content.0.text")?.stringValue ?? reply.text())")
            return reply
        }
        _ = call("project_new", ["name": "uno", "directory": .string(dir.path)])
        _ = call("project_new", ["name": "due", "directory": .string(dir.path)])
        _ = call("project_list", [:])
        _ = call("track_add", ["kind": "video", "project": "tab-1"])
        _ = call("track_add", ["kind": "audio"])
        _ = call("project_list", [:])
        let tools = server.handle(["jsonrpc": "2.0", "id": 99, "method": "tools/list"])
        let cut = tools?["result"]?["tools"]?.arrayValue?.first { $0["name"] == "timeline_cut" }
        lines.append("timeline_cut takes project: \(cut?.value(at: "inputSchema.properties.project.type")?.stringValue ?? "no")")
        return lines
    }.value
    try await settle { workbench.tabs.count == 2 && workbench.tabs.allSatisfy { $0.project?.tracks.count == 1 } }
    let tabs = workbench.tabs
    #expect(tabs.count == 2 && tabs[0].project?.name == "uno" && tabs[1].project?.name == "due" && workbench.activeID == tabs[1].tabID)
    #expect(tabs[0].project?.tracks.map(\.kind) == [.video] && tabs[1].project?.tracks.map(\.kind) == [.audio])
    #expect(transcript.last == "timeline_cut takes project: string")
    print(transcript.joined(separator: "\n"))
}
