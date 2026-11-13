import Foundation
import Testing
@testable import RegistaCore

@Test func matchers() {
    let check = ScenarioRunner.check
    #expect(check(.number(10.0000001), 10) == nil)
    #expect(check(.number(10.1), 10) != nil)
    #expect(check(.number(94.7033), ["approx": 94.7, "tol": 0.01]) == nil)
    #expect(check(.number(95), ["approx": 94.7]) != nil)
    #expect(check(.array([1, 2]), ["count": 2]) == nil)
    #expect(check(.array([1]), ["count": 2]) != nil)
    #expect(check(nil, ["exists": false]) == nil)
    #expect(check(nil, ["exists": true]) != nil)
    #expect(check("/tmp/basic.regista", ["contains": "basic"]) == nil)
    #expect(check(["a": 1], ["equals": ["a": 1]]) == nil)
    #expect(check(1, ["equal": 1]) == "unknown matcher \"equal\"")
    // includes (#68): the listed elements are there, however long the list grows.
    let engines: JSONValue = [["id": "whisperx", "available": true, "role": "x"], ["id": "ffmpeg", "available": false]]
    #expect(check(engines, ["includes": [["id": "whisperx", "available": true]]]) == nil)
    #expect(check(engines, ["includes": [["id": "whisperx"], ["id": "ffmpeg"]]]) == nil)
    #expect(check(engines, ["includes": [["id": "ffmpeg", "available": true]]]) != nil)
    #expect(check(engines, ["includes": [["id": "nope"]]]) != nil)
    #expect(check(.array([1, 2]), ["includes": [2]]) == nil)
    #expect(check(1, ["includes": [1]]) != nil)
}

@Test func scenarioRunsOnAnEngineWithCapturesAndExpectedErrors() throws {
    let json = try JSONValue.parse(#"""
    {"name": "t", "steps": [
      {"command": "project.new", "params": {"name": "${NAME}"}},
      {"command": "media.import", "params": {"path": "${MEDIA}"}, "capture": {"asset": "result.asset.id"}},
      {"command": "track.add", "params": {"kind": "video"}, "capture": {"track": "result.track"}},
      {"command": "timeline.place", "params": {"assetId": "${asset}", "trackId": "${track.id}", "sourceOut": 30},
       "expect": {"state.tracks.0.clips.0.end": 30, "state.name": "x-${asset}", "result.clip": {"exists": true}}},
      {"command": "timeline.cut", "params": {"at": 99}, "expectError": "no clip spans"}
    ]}
    """#)
    let engine = Engine(prober: FakeProber())
    var lines: [String] = []
    var runner = ScenarioRunner(variables: ["NAME": "x-a1", "MEDIA": .string(fakeMedia())], output: { lines.append($0) },
                                execute: { try engine.execute($0, params: $1) })
    #expect(runner.run(try Scenario(json: json)))
    #expect(lines.last?.hasPrefix("✓ t: 5 steps") == true)
}

@Test func scenarioStopsAtTheFirstFailure() throws {
    let json: JSONValue = ["steps": [
        ["command": "project.new", "params": ["name": "x"], "expect": ["result.name": "y"]],
        ["command": "project.state"],
    ]]
    let engine = Engine(prober: FakeProber())
    var lines: [String] = []
    var runner = ScenarioRunner(output: { lines.append($0) }, execute: { try engine.execute($0, params: $1) })
    #expect(!runner.run(try Scenario(json: json)))
    #expect(lines.contains { $0.contains("result.name: expected \"y\", found \"x\"") })
    #expect(engine.log.count == 1)
}

@Test func footageScenariosSkipWhenTheMediaIsMissing() throws {
    let dir = tempDir()
    let present = fakeMedia("take.mov", in: dir)
    let json: (String) throws -> Scenario = { try Scenario(json: JSONValue.parse($0)) }
    let ok = try json(#"{"requires": ["footage"], "footage": ["${DIR}/take.mov"], "steps": []}"#)
    #expect(ok.missingFootage(environment: ["DIR": dir.path]).isEmpty && FileManager.default.fileExists(atPath: present))
    #expect(ok.missingFootage(environment: ["DIR": "/nope"]) == ["/nope/take.mov"])
    #expect(try json(#"{"requires": ["footage"], "steps": []}"#).missingFootage().count == 1)   // must list its footage
    #expect(try json(#"{"footage": ["/nope"], "steps": []}"#).missingFootage().isEmpty)        // not required
}
