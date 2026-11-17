import Foundation
import Testing
@testable import RegistaCore

// E2 (#54): long commands run inside a CommandJob — engines report their progress to it and its Cancel kills their
// processes for real, leaving no partial file; plus the parameters the hand-made steps needed (edit.autoCut pause
// settings, captions.generate dryRun with keyword suggestions, transcript.run language "auto").

/// A fake engine executable: a shell script in a temp folder.
private func script(_ body: String) throws -> URL {
    let url = tempDir().appendingPathComponent("fake-engine")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

/// An engine whose audio is the real ffmpeg adapter pointed at `ffmpeg` (a fake), the rest fakes.
private func ffmpegEngine(_ ffmpeg: URL) throws -> Engine {
    var config = EngineConfig()
    config.ffmpeg = ffmpeg.path
    config.cacheDirectory = tempDir().path
    let services = EngineServices(config: config, tier: .base, audio: FFmpegAudio(config: config),
                                  transcribers: [FakeTranscriber(words: [Word("uno", 1.0, 1.4)])], cleaner: FakeCleaner(), faces: nil)
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "jobs", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    return e
}

/// Collects what a job reports, from any thread.
private final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ f: Double?) { if let f { lock.withLock { values.append(f) } } }
    var all: [Double] { lock.withLock { values } }
}

@Test func engineProgressLinesAreRead() {
    #expect(CommandJob.ffmpegSeconds("out_time_us=7529188") == 7.529188)
    #expect(CommandJob.ffmpegSeconds("out_time_ms=1500000") == 1.5)
    #expect(CommandJob.ffmpegSeconds("out_time=00:01:02.500000") == 62.5)
    #expect(CommandJob.ffmpegSeconds("out_time_us=N/A") == nil && CommandJob.ffmpegSeconds("speed=2x") == nil)
    #expect(CommandJob.whisperPercent("whisper_print_progress_callback: progress =  45%") == 45)
    #expect(CommandJob.whisperPercent("output_json: saving output") == nil)
}

@Test func stagesMapProgressIntoTheWholeJobAndNeverGoBack() {
    let reports = Reports()
    let job = CommandJob { f, _ in reports.add(f) }
    CommandJob.$current.withValue(job) {
        CommandJob.stage(0, 0.5) {
            CommandJob.report(0.5)                       // 0.25 of the job
            CommandJob.stage(0.5, 1) { CommandJob.report(0.5) }   // 0.375
        }
        CommandJob.stage(0.5, 1) {
            CommandJob.report(0.2)                       // 0.6
            CommandJob.report(0.1)                       // a step back: not reported
        }
    }
    let r = reports.all
    #expect(r.contains(0.25) && r.contains(0.375) && r.contains { abs($0 - 0.6) < 1e-9 })
    #expect(r == r.sorted() && r.last == 1)
    // No job bound: everything is a no-op.
    CommandJob.report(0.5)
    #expect(CommandJob.stage(0, 1) { 42 } == 42)
}

@Test func ffmpegProgressReachesTheJob() throws {
    let wav = tempDir().appendingPathComponent("tone.wav")
    try syntheticSpeech([(1, 2)], duration: 3).write16(to: wav)
    // Prints its position like ffmpeg -progress pipe:1 (the fake asset lasts 94.7 s), then writes the wav.
    let ffmpeg = try script("""
    for last; do :; done
    for t in 10000000 30000000 60000000 90000000; do echo "out_time_us=$t"; sleep 0.05; done
    echo "progress=end"
    cp '\(wav.path)' "$last"
    """)
    let e = try ffmpegEngine(ffmpeg)
    let reports = Reports()
    let job = CommandJob { f, _ in reports.add(f) }
    try CommandJob.$current.withValue(job) { _ = try e.execute("media.extractAudio", params: ["assetId": "a1"]) }
    let r = reports.all
    // Two passes (16 kHz, then 48 kHz), each half of the job: 10/94.7 of the first half is ≈ 0.053.
    #expect(r.contains { abs($0 - 10 / 94.703 / 2) < 0.002 })
    #expect(r.contains { $0 > 0.5 && $0 < 1 } && r == r.sorted() && r.last == 1)
}

@Test func cancelKillsTheEngineProcessAndLeavesNoPartialFile() throws {
    let pidFile = tempDir().appendingPathComponent("pid")
    // Writes half an output file, then works "forever" (exec: the pid stays the engine's).
    let ffmpeg = try script("""
    for last; do :; done
    echo partial > "$last"
    echo $$ > '\(pidFile.path)'
    exec sleep 60
    """)
    let e = try ffmpegEngine(ffmpeg)
    let before = e.project
    let job = CommandJob()
    // A thread of its own: in the full parallel suite the global queues can be saturated for many seconds.
    Thread.detachNewThread { Thread.sleep(forTimeInterval: 1); job.cancel() }
    let started = Date()
    #expect { try CommandJob.$current.withValue(job) { try e.execute("media.extractAudio", params: ["assetId": "a1"]) } }
        throws: { "\($0)".contains("cancelled") }
    #expect(Date().timeIntervalSince(started) < 20)   // well under the engine's 60 s: the cancel stopped it
    let pid = Int32((try String(contentsOf: pidFile, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines))!
    var gone = false
    for _ in 0..<50 where !gone {   // SIGTERM at once (SIGKILL 3 s later at the latest)
        gone = kill(pid, 0) != 0
        if !gone { Thread.sleep(forTimeInterval: 0.1) }
    }
    #expect(gone)
    let media = e.context.projectURL!.appendingPathComponent("media")
    let left = (try? FileManager.default.contentsOfDirectory(atPath: media.path)) ?? []
    #expect(!left.contains { $0.hasSuffix(".wav") })   // the half-written wav is gone
    #expect(e.project == before)                       // and the edit did not change
    // A cancelled job starts nothing more.
    #expect { try CommandJob.$current.withValue(job) { try e.execute("media.extractAudio", params: ["assetId": "a1"]) } }
        throws: { "\($0)".contains("cancelled") }
}

@Test func autoCutPauseSettingsRecomputeTheCutKeepingThePicks() throws {
    let e = try takesEngine()
    try e.execute("takes.list")
    try e.execute("takes.select", params: ["line": 1, "take": 1])
    let tight = try e.execute("edit.autoCut")
    // Line 2's chosen take has a 1 s pause: cut out at the default 0.7 s.
    #expect(tight["segments"]?.arrayValue?.count == 4)
    let loose = try e.checkUndoRedo("edit.autoCut", ["replace": true, "maxPause": 1.5, "keepPause": 0.2])
    #expect(loose["segments"]?.arrayValue?.count == 3)
    #expect(e.project?.takes?.options.maxPause == 1.5 && e.project?.takes?.options.keepPause == 0.2)
    #expect(e.project?.takes?.lines[1].chosen == 1)   // the pick survives the new cut points
    try e.execute("takes.select", params: ["line": 2, "take": 1])
    try e.execute("edit.autoCut", params: ["replace": true, "maxPause": 1.5, "keepPause": 0.2])
    #expect(e.project?.takes?.lines[1].chosen == 0)
}

/// #14: edit.autoCut says what it does: its summary and its result name the chosen takes and the pauses it cut out, never
/// a filler removal it does not make (filler words stay; transcript.deleteWords removes them).
@Test func autoCutSaysOnlyWhatItDid() throws {
    #expect(!EditAutoCut.summary.lowercased().contains("fillers and"), "the summary still announces a filler removal")
    #expect(EditAutoCut.summary.contains("filler words stay"))
    #expect(!Recipes.all.contains { $0.text().contains("fillers and long pauses removed") })
    let e = try takesEngine()
    try e.execute("takes.list")
    try e.execute("takes.select", params: ["line": 1, "take": 1])
    let r = try e.execute("edit.autoCut")   // line 2's chosen take has a 1 s pause, cut out
    let notes = r["segments"]?.arrayValue?.compactMap { $0["note"]?.stringValue } ?? []
    #expect(notes.contains { $0.hasPrefix("pause ") })                               // the pause it cut out is named
    #expect(notes.allSatisfy { $0.isEmpty || ($0.hasPrefix("pause ") && $0.hasSuffix(" removed")) }, "\(notes)")
    #expect(!"\(r)".lowercased().contains("filler"))
}

@Test func captionsDryRunSuggestsKeywordsAndChangesNothing() throws {
    var fakes = FakeServices()
    fakes.words = spoken("Oggi Regista monta 3 reel. Le pause spariscono da sole e i sottotitoli arrivano.", at: 1.0)
    let e = try analysisEngine(fakes)
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1"])
    let before = e.project
    let r = try e.execute("captions.generate", params: ["dryRun": true])
    #expect(e.project == before)
    let k = r["suggestedKeywords"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(k == ["3", "SOTTOTITOLI"])   // the number in the first sentence, the longest word of the second
    #expect(r["chunks"]?.doubleValue ?? 0 > 0)
    let made = try e.execute("captions.generate", params: ["keywords": .array(k.map { .string($0) })])
    #expect((made["keywordsShown"]?.doubleValue ?? 0) >= 2)
}

@Test func keywordSuggestionsFollowTheHouseRule() {
    let s = KeywordSuggest.sentences(["Ciao", "a", "tutti.", "Oggi", "vi", "mostro", "Regista", "in", "tre", "minuti."])
    #expect(s.count == 2)
    let k = KeywordSuggest.suggest(sentences: s, language: "it", display: { $0.trimmingCharacters(in: .punctuationCharacters).uppercased() },
                                   first: ["WESITES"])
    // The script's keyword first; "Ciao a tutti" has no word worth it; then the name in the middle of the sentence.
    #expect(k == ["WESITES", "REGISTA"])
}

@Test func transcribeDetectsTheLanguageOnlyWhereAnEngineCan() throws {
    var fakes = FakeServices()
    fakes.tier = .base
    let e = try analysisEngine(fakes)
    let r = try e.execute("transcript.run", params: ["assetId": "a1", "language": "auto"])
    #expect(r["language"] == "auto")   // the fake passes it through; whisper.cpp reports the detected one
    fakes.tier = .pro                  // whisperx by default: it needs whisper.cpp's detection, absent here
    let pro = try analysisEngine(fakes)
    #expect { try pro.execute("transcript.run", params: ["assetId": "a1", "language": "auto"]) }
        throws: { "\($0)".contains("cannot detect the language") }
}
