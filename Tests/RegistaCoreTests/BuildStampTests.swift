import Testing
@testable import RegistaCore

// Which side to rebuild when the app and regista-mcp come from different builds (#45).

@Test func sameBuildIsNoMismatch() {
    let b = BuildStamp(id: "3551262", commitTime: 100)
    #expect(BuildStamp.mismatch(app: b, mcp: b) == nil)
    #expect(BuildStamp.warning(app: b, mcp: b) == nil)
    #expect(BuildStamp.mismatch(app: nil, mcp: nil) == nil)
}

@Test func theOlderCommitIsTheOneToRebuild() {
    let old = BuildStamp(id: "aaaaaaa", commitTime: 100), new = BuildStamp(id: "bbbbbbb", commitTime: 200)
    #expect(BuildStamp.mismatch(app: old, mcp: new) == .rebuildApp)
    #expect(BuildStamp.mismatch(app: new, mcp: old) == .rebuildMCP)
    let w = BuildStamp.warning(app: old, mcp: new) ?? ""
    #expect(w.contains("aaaaaaa") && w.contains("bbbbbbb") && w.contains("scripts/build-app.sh --install"))
    #expect(BuildStamp.warning(app: new, mcp: old)?.contains("scripts/build-mcp.sh") == true)
}

@Test func missingOrUnstampedSideIsTheOneToRebuild() {
    let b = BuildStamp(id: "3551262", commitTime: 100)
    #expect(BuildStamp.mismatch(app: nil, mcp: b) == .rebuildApp)          // an app from before build ids
    #expect(BuildStamp.mismatch(app: b, mcp: nil) == .rebuildMCP)
    #expect(BuildStamp.mismatch(app: BuildStamp(id: BuildStamp.unstamped), mcp: b) == .rebuildApp)
    #expect(BuildStamp.mismatch(app: b, mcp: BuildStamp(id: BuildStamp.unstamped)) == .rebuildMCP)
}

@Test func sameCommitDifferentChangesRebuildsBoth() {
    let a = BuildStamp(id: "3551262-dirty.aaaaaa", commitTime: 100), b = BuildStamp(id: "3551262-dirty.bbbbbb", commitTime: 100)
    #expect(BuildStamp.mismatch(app: a, mcp: b) == .rebuildBoth)
    #expect(BuildStamp.mismatch(app: a, mcp: BuildStamp(id: "other")) == .rebuildBoth)   // commit time unknown
}

@Test func buildStampRoundTripsThroughJSON() {
    let b = BuildStamp(id: "3551262-dirty.abcdef", commitTime: 1_794_470_398)
    #expect(BuildStamp(json: .object(b.json)) == b)
    #expect(BuildStamp(json: ["ok": true]) == nil)
}

@Test func enginesStatusReportsThisProcessBuild() throws {
    let r = try Engine().execute("engines.status")
    #expect(r["build"]?.stringValue == BuildStamp.current.id)
}
