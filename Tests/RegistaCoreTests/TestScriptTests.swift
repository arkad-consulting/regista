import Foundation
import Testing

// #19: scripts/test.sh on a crashed test process (signal 11). A fake `swift` plays the cases: a crash in a run that
// compiled (maybe a stale build: one clean rebuild and one retry), a crash with nothing compiled (the code's: no
// retry), an ordinary failure (no retry, no crash talk), a process that ends with 0 before the run's summary (the run
// did not finish: one more run, never green by itself) and a test that hangs (stopped after the time limit). The crashed thread of the crash
// report is printed. Also what test.sh sets for every run: the parallelism cap (#80).

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let fakeSwift = #"""
#!/bin/bash
n=$(( $(cat "$FAKE_STATE" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE_STATE"
echo "width=$SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
crash() {
  printf '%s\n%s\n' '{"app_name":"swiftpm-testing-helper"}' \
    '{"exception":{"type":"EXC_BAD_ACCESS","subtype":"KERN_INVALID_ADDRESS at 0x10"},"usedImages":[{"name":"RegistaPackageTests"}],"threads":[{"queue":"regista.export.video","triggered":true,"frames":[{"imageIndex":0,"symbol":"closure #2 in AVRenderer.export"}]}]}' \
    > "$REGISTA_CRASH_REPORTS/swiftpm-testing-helper-$n.ips"
  echo "error: Process 'swiftpm-testing-helper' exited with unexpected signal code 11"
  exit 1
}
case "$FAKE_MODE:$n" in
  stale:1) echo "[3/9] Compiling RegistaCore Engine.swift"; crash ;;
  stale:*) echo "[3/9] Compiling RegistaCore Engine.swift"; echo "✔ Test run with 1 test passed"; exit 0 ;;
  code:*) crash ;;
  fail:*) echo "✘ Test run with 1 test failed"; exit 1 ;;
  quit:*) echo "◇ Test aTest() started."; exit 0 ;;
  quitonce:1) echo "◇ Test aTest() started."; exit 0 ;;
  quitonce:*) echo "✔ Test run with 1 test passed"; exit 0 ;;
  hang:*) echo "◇ Test aTest() started."; sleep 60 ;;
esac
"""#

private func runTestScript(_ mode: String) throws -> (status: Int32, output: String, calls: Int, debugKept: Bool) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-testsh-\(UUID().uuidString)")
    let fm = FileManager.default
    defer { try? fm.removeItem(at: dir) }
    for sub in ["scripts", "reports", "bin", ".build/arm64-apple-macosx/debug"] {
        try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try fm.copyItem(at: repo.appendingPathComponent("scripts/test.sh"), to: dir.appendingPathComponent("scripts/test.sh"))
    let swift = dir.appendingPathComponent("bin/swift")
    try fakeSwift.write(to: swift, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
    let debug = dir.appendingPathComponent(".build/arm64-apple-macosx/debug/marker")
    fm.createFile(atPath: debug.path, contents: Data())
    let state = dir.appendingPathComponent("calls")

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [dir.appendingPathComponent("scripts/test.sh").path]
    var env = ProcessInfo.processInfo.environment
    env["REGISTA_SWIFT"] = swift.path
    env["REGISTA_CRASH_REPORTS"] = dir.appendingPathComponent("reports").path
    env["FAKE_MODE"] = mode
    if mode == "hang" { env["REGISTA_TEST_TIMEOUT"] = "1" } else { env.removeValue(forKey: "REGISTA_TEST_TIMEOUT") }
    env["FAKE_STATE"] = state.path
    env.removeValue(forKey: "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH")
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let calls = Int((try? String(contentsOf: state, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    return (p.terminationStatus, String(decoding: data, as: UTF8.self), calls, fm.fileExists(atPath: debug.path))
}

@Test func testScriptRetriesASignal11OnceFromACleanBuildOnlyWhenItCompiled() throws {
    let stale = try runTestScript("stale")
    #expect(stale.status == 0 && stale.calls == 2, "\(stale.output)")
    #expect(!stale.debugKept)                                                  // the debug build was wiped
    #expect(stale.output.contains("crashed with signal 11") && stale.output.contains("closure #2 in AVRenderer.export"))
    #expect(stale.output.contains("passed after a clean rebuild"))
    // Tests leave a third of Swift's cooperative pool to AVFoundation (#80).
    let width = stale.output.split(separator: "\n").first { $0.hasPrefix("width=") }.flatMap { Int($0.dropFirst(6)) }
    #expect(width.map { $0 >= 2 && $0 <= max(2, ProcessInfo.processInfo.activeProcessorCount * 2 / 3) } == true, "\(stale.output)")

    let code = try runTestScript("code")
    #expect(code.status != 0 && code.calls == 1, "\(code.output)")
    #expect(code.debugKept)
    #expect(code.output.contains("not a stale build") && code.output.contains("closure #2 in AVRenderer.export"))

    let fail = try runTestScript("fail")
    #expect(fail.status != 0 && fail.calls == 1 && fail.debugKept)
    #expect(!fail.output.contains("signal 11"))

    // The test process ended with 0 before the run's summary: not a green run. The suite runs once more; a second
    // unfinished run fails, a finished one decides.
    let quit = try runTestScript("quit")
    #expect(quit.status != 0 && quit.calls == 2 && quit.output.contains("did not finish either"), "\(quit.output)")
    let once = try runTestScript("quitonce")
    #expect(once.status == 0 && once.calls == 2 && once.output.contains("ONCE more"), "\(once.output)")

    // A test that hangs: the run is stopped after the time limit and fails, it does not block for ever.
    let started = Date()
    let hang = try runTestScript("hang")
    #expect(hang.status != 0 && hang.calls == 1 && hang.output.contains("a test hangs"), "\(hang.output)")
    #expect(Date().timeIntervalSince(started) < 20)
}
