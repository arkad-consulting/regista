import Foundation
import Testing
@testable import RegistaCore

@Test func registryListsTheStandardCommands() {
    let ids = Engine(prober: FakeProber()).descriptors.map(\.id)
    #expect(ids == ids.sorted())
    for id in ["project.new", "project.open", "project.save", "project.state", "media.import", "track.add", "track.set",
               "timeline.place", "timeline.cut", "timeline.trim", "timeline.move", "timeline.delete",
               "history.undo", "history.redo"] {
        #expect(ids.contains(id), "\(id)")
    }
}

@Test func schemaIsBuiltFromTheParamDescription() {
    let d = TimelineTrim.descriptor
    let s = d.inputSchema
    #expect(s["type"] == "object")
    #expect(s["additionalProperties"] == false)
    #expect(s["required"] == ["clipId", "edge", "to"])
    #expect(s.value(at: "properties.edge.enum") == ["start", "end"])
    #expect(s.value(at: "properties.to.type") == "number")
    #expect(s.value(at: "properties.ripple.type") == "boolean")
    #expect(s.value(at: "properties.clipId.description") != nil)
}

@Test func everyCommandHasADescribedSchema() {
    for d in Engine(prober: FakeProber()).descriptors {
        #expect(!d.summary.isEmpty, "\(d.id)")
        for p in d.params { #expect(!p.description.isEmpty, "\(d.id).\(p.name)") }
    }
}

/// #44: `project` is the tab target every project-scoped command takes at the routing layer (ProjectTarget), taken out
/// of the params before the command runs: a command that declared a parameter of that name would never see it.
@Test func noProjectScopedCommandDeclaresAParameterNamedProject() {
    let all = Engine(prober: FakeProber()).descriptors
    #expect(all.contains { $0.id == "graphics.hyperframes" })
    for d in all where ProjectTarget.accepts(d.id) {
        #expect(!d.params.contains { $0.name == ProjectTarget.param }, "\(d.id) declares '\(ProjectTarget.param)', which is the tab target")
    }
}

@Test func validationErrorsAreClear() throws {
    let e = try editingEngine()
    func message(_ id: String, _ params: JSONValue) -> String {
        do { try e.execute(id, params: params); return "" } catch { return "\(error)" }
    }
    #expect(message("timeline.cut", [:]).contains("missing required parameter 'at'"))
    #expect(message("timeline.cut", ["at": "ten"]).contains("parameter 'at': expected number (seconds), got string"))
    #expect(message("timeline.cut", ["at": -1]).contains("seconds ≥ 0"))
    #expect(message("timeline.cut", ["at": 1, "clip": "c1"]).contains("unknown parameter 'clip'"))
    #expect(message("track.add", ["kind": "music"]).contains("expected one of video, audio, caption, overlay"))
    #expect(message("track.add", ["kind": "video", "index": 1.5]).contains("expected an integer"))
    #expect(message("timeline.split", ["at": 1]).contains("Unknown command 'timeline.split' — did you mean"))
    #expect(message("project.state", "x").contains("params must be a JSON object"))
}

@Test func failedCommandsLeaveTheEngineUntouchedAndAreLogged() throws {
    let e = try editingEngine()
    let before = e.project
    #expect(throws: CommandError.self) { try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "nope"]) }
    #expect(e.project == before)
    #expect(e.log.last?.command == "timeline.place")
    #expect(e.log.last?.error?.contains("No track 'nope'") == true)
}

@Test func commandsNeedAProject() {
    let e = Engine(prober: FakeProber())
    #expect(throws: CommandError(.noProject, "No project open: call project.new or project.open first")) {
        try e.execute("track.add", params: ["kind": "video"])
    }
}
