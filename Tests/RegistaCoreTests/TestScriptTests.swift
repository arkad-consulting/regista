import Foundation
import RegistaCore
import Testing

// #19: scripts/test.sh on a crashed test process (signal 11). A fake `swift` plays the cases: a crash in a run that
// compiled (maybe a stale build: one clean rebuild and one retry), a crash with nothing compiled (the code's: no
// retry), an ordinary failure (no retry, no crash talk), a process that ends with 0 before the run's summary (the run
// did not finish: taken up again without what passed, never green by itself, a failure before the early end stands) and a test that hangs (stopped after the time limit). The crashed thread of the crash
// report is printed. Also what test.sh sets for every run: the parallelism cap (#80) and a temporary folder of its own,
// removed at the end (#138).

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private let fakeSwift = #"""
#!/bin/bash
if [ "$2" = list ]; then printf '%s\n' 'Mod.Suite/first()' 'Mod.Suite/second(_:)' 'Mod.Other/second(_:)'; exit 0; fi
n=$(( $(cat "$FAKE_STATE" 2>/dev/null || echo 0) + 1 )); echo $n > "$FAKE_STATE"
echo "width=$SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH"
echo "tmpdir=$REGISTA_TMPDIR"; [ -d "$REGISTA_TMPDIR" ] && echo "tmpdir is a folder" && : > "$REGISTA_TMPDIR/made-by-a-test"
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
  resume:1) echo "✔ Test first() passed after 0.1 seconds."; echo "✔ Test second(_:) with 2 test cases passed after 0.1 seconds."; echo "◇ Test third() started."; exit 0 ;;
  resume:*) echo "args=$*"; echo "✔ Test run with 2 tests passed"; exit 0 ;;
  failquit:1) echo "✘ Test first() failed after 0.1 seconds with 1 issue."; echo "◇ Test third() started."; exit 0 ;;
  failquit:*) echo "✔ Test run with 3 tests passed"; exit 0 ;;
  hang:*) echo "◇ Test aTest() started."; sleep 60 ;;
  pass:*) echo "args=$*"; echo "✔ Test run with 1 test passed"; exit 0 ;;
esac
"""#

/// Runs a copy of scripts/test.sh on the fake `swift`. Its system temporary folder (TMPDIR) is `tmp`, a scratch folder
/// `prepare` fills first; `leftInTmp` is what that folder holds when the script has ended.
private func runTestScript(_ mode: String, _ arguments: [String] = [], environment extra: [String: String] = [:],
                           prepare: (_ tmp: URL) throws -> Void = { _ in }) throws
    -> (status: Int32, output: String, calls: Int, debugKept: Bool, tmp: URL, leftInTmp: Set<String>) {
    let dir = TemporaryFolder.url.appendingPathComponent("regista-testsh-\(UUID().uuidString)")
    let fm = FileManager.default
    defer { try? fm.removeItem(at: dir) }
    for sub in ["scripts", "reports", "bin", "tmp", ".build/arm64-apple-macosx/debug"] {
        try fm.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
    }
    try fm.copyItem(at: repo.appendingPathComponent("scripts/test.sh"), to: dir.appendingPathComponent("scripts/test.sh"))
    let swift = dir.appendingPathComponent("bin/swift")
    try fakeSwift.write(to: swift, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: swift.path)
    let debug = dir.appendingPathComponent(".build/arm64-apple-macosx/debug/marker")
    fm.createFile(atPath: debug.path, contents: Data())
    let state = dir.appendingPathComponent("calls")
    let tmp = dir.appendingPathComponent("tmp")
    try prepare(tmp)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [dir.appendingPathComponent("scripts/test.sh").path] + arguments
    var env = ProcessInfo.processInfo.environment
    env["REGISTA_SWIFT"] = swift.path
    env["REGISTA_CRASH_REPORTS"] = dir.appendingPathComponent("reports").path
    env["FAKE_MODE"] = mode
    if mode == "hang" { env["REGISTA_TEST_TIMEOUT"] = "1" } else { env.removeValue(forKey: "REGISTA_TEST_TIMEOUT") }
    env["FAKE_STATE"] = state.path
    env["TMPDIR"] = tmp.path + "/"
    env.removeValue(forKey: "REGISTA_TMPDIR")
    env.removeValue(forKey: "SWT_EXPERIMENTAL_MAXIMUM_PARALLELIZATION_WIDTH")
    env.removeValue(forKey: "REGISTA_PREFERENCES_DIR")
    env.merge(extra) { $1 }
    p.environment = env
    let out = Pipe()
    p.standardOutput = out
    p.standardError = out
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let calls = Int((try? String(contentsOf: state, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
    let left = Set((try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [])
    return (p.terminationStatus, String(decoding: data, as: UTF8.self), calls, fm.fileExists(atPath: debug.path), tmp, left)
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

    // The test process ended with 0 before the run's summary: not a green run. It is taken up again, up to four runs
    // in all; if the last one does not finish either the run fails, a finished one decides.
    let quit = try runTestScript("quit")
    #expect(quit.status != 0 && quit.calls == 4 && quit.output.contains("did not finish after 4 runs"), "\(quit.output)")
    let once = try runTestScript("quitonce")
    #expect(once.status == 0 && once.calls == 2 && once.output.contains("run 2 of at most 4"), "\(once.output)")
    // The run is taken up again without what passed: `first()` is left out; `second(_:)` passed once but two suites
    // have a test of that name, so neither is left out.
    let resume = try runTestScript("resume")
    #expect(resume.status == 0 && resume.calls == 2, "\(resume.output)")
    let resumed = resume.output.split(separator: "\n").first { $0.hasPrefix("args=") }.map(String.init) ?? ""
    #expect(resumed.contains(#"--skip ^Mod\.Suite/first\(\)(/|$)"#) && !resumed.contains("second"), "\(resume.output)")

    // A failure recorded before the early end stands, whatever the run that takes it up again says (#55).
    let failquit = try runTestScript("failquit")
    #expect(failquit.status != 0 && failquit.calls == 2, "\(failquit.output)")
    #expect(failquit.output.contains("a later run does not undo them") && failquit.output.hasSuffix("✘ Test first() failed after 0.1 seconds with 1 issue.\n"), "\(failquit.output)")

    // A test that hangs: the run is stopped after the time limit and fails, it does not block for ever.
    let started = Date()
    let hang = try runTestScript("hang")
    #expect(hang.status != 0 && hang.calls == 1 && hang.output.contains("a test hangs"), "\(hang.output)")
    #expect(Date().timeIntervalSince(started) < 20)
}

/// #137: `--clean-preferences` removes only the property lists test runs left, `regista-<kind>-<UUID>.plist`, from the
/// Preferences folder (a scratch one here), says how many, and the run goes on without the flag; without it nothing is
/// touched.
@Test func testScriptCleansOnlyTheTestSuitesPropertyLists() throws {
    let fm = FileManager.default
    let prefs = TemporaryFolder.url.appendingPathComponent("regista-testsh-prefs-\(UUID().uuidString)")
    try fm.createDirectory(at: prefs, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: prefs) }
    let uuid = "0A1B2C3D-4E5F-6789-ABCD-EF0123456789"
    let gone = ["regista-rig-\(uuid).plist", "regista-tabs-tests-\(uuid).plist", "regista-settings-render-9F8E7D6C-5B4A-3210-FEDC-BA9876543210.plist"]
    // (Case variants with UUIDs of their own: the scratch folder, like Preferences, may ignore case.)
    let kept = ["Regista.plist", "com.arkad.regista.plist", "regista-notes.plist", "regista-rig-1a2b3c4d-5e6f-7089-abcd-ef0123456789.plist",
                "regista-rig-\(uuid).plist.bak", "regista-rig-\(uuid)-2.plist", "regista-Rig-2A1B2C3D-4E5F-6789-ABCD-EF0123456789.plist", "regista-\(uuid).plist",
                "regista-rig-0A1B2C3D4E5F6789ABCDEF0123456789.plist", "other-rig-\(uuid).plist"]
    func fill() { for n in gone + kept { fm.createFile(atPath: prefs.appendingPathComponent(n).path, contents: Data("x".utf8)) } }
    func present() -> Set<String> { Set((try? fm.contentsOfDirectory(atPath: prefs.path)) ?? []) }
    fill()
    let plain = try runTestScript("pass", ["--filter", "x"], environment: ["REGISTA_PREFERENCES_DIR": prefs.path])
    #expect(plain.status == 0 && present() == Set(gone + kept) && !plain.output.contains("--clean-preferences"), "\(plain.output)")

    let clean = try runTestScript("pass", ["--clean-preferences", "--filter", "x"], environment: ["REGISTA_PREFERENCES_DIR": prefs.path])
    #expect(clean.status == 0 && clean.calls == 1, "\(clean.output)")
    #expect(present() == Set(kept), "\(present())")
    #expect(clean.output.contains("--clean-preferences removed 3 file(s)"), "\(clean.output)")
    let args = clean.output.split(separator: "\n").first { $0.hasPrefix("args=") }.map(String.init) ?? ""
    #expect(args.contains("--filter x") && !args.contains("clean"), "\(clean.output)")
    let again = try runTestScript("pass", ["--clean-preferences"], environment: ["REGISTA_PREFERENCES_DIR": prefs.path])
    #expect(again.status == 0 && again.output.contains("removed 0 file(s)") && present() == Set(kept), "\(again.output)")
}

/// #138: every run of test.sh gets a temporary folder of its own, `<system temporary folder>/regista-run-<pid>`, set as
/// REGISTA_TMPDIR for the tests, and removes it when the run ends, whatever the result (passed, failed, stopped after
/// the time limit). Run folders left a day ago (a stopped run) go; a newer one and anything else stay.
@Test func testScriptGivesEachRunATemporaryFolderOfItsOwnAndRemovesIt() throws {
    let fm = FileManager.default
    let twoDaysAgo = Date().addingTimeInterval(-2 * 86_400)
    func prepare(_ tmp: URL) throws {
        for name in ["regista-run-1", "regista-run-2", "regista-media-old", "other-run-3"] {
            let url = tmp.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            if name != "regista-run-2" { try fm.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: url.path) }
        }
    }
    for mode in ["pass", "fail", "hang"] {
        let r = try runTestScript(mode, prepare: prepare)
        let line = r.output.split(separator: "\n").first { $0.hasPrefix("tmpdir=") }.map { String($0.dropFirst(7)) } ?? ""
        #expect(line.hasPrefix(r.tmp.path + "/regista-run-") && Int(line.dropFirst(r.tmp.path.count + 13)) != nil, "\(mode): \(r.output)")
        #expect(r.output.contains("tmpdir is a folder"), "\(mode): \(r.output)")
        #expect(r.leftInTmp == ["regista-run-2", "regista-media-old", "other-run-3"], "\(mode): \(r.leftInTmp.sorted())")
    }
}
