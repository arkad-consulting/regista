import AVFoundation
import AppKit
import Foundation
import RegistaCore
import Testing
@testable import Regista

// E3 (#55): music, sound effects and level by hand. The Audio panel's controls run commands through the tab's store:
// music from "Aggiungi musica…" lands on the Musica track with its role and the ducking on, and measures lower under
// the voice than without ducking (real ffmpeg, a synthetic project); a sound chosen in the browser lands on the Effetti
// track at the playhead; a preview never touches the project.

private func tempDir() -> URL {
    let url = TemporaryFolder.url.appendingPathComponent("regista-audio-tests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func scratchDefaults() -> UserDefaults { TestDefaults.make("audio-tests") }

/// A store of its own (its own socket, scratch defaults): never the owner's app or projects.
@MainActor
private func scratchStore() -> EditorStore {
    _ = NSApplication.shared
    setenv("REGISTA_ENGINE_SOCKET", tempDir().appendingPathComponent("e.sock").path, 1)
    return EditorStore(defaults: scratchDefaults(), seedFolders: [])
}

/// Waits (up to `seconds`) until `done` is true, letting the main queue run (the store publishes its snapshots there).
@MainActor
private func waitUntil(_ seconds: Double = 60, _ done: () -> Bool) async {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
}

/// An 8 s voice made of speech-like bursts (a 220 Hz tone with a syllable envelope) and a 3 s music loop (a chord with
/// some noise), as 48 kHz wav files.
private func synthAudio(in dir: URL) throws -> (voice: URL, music: URL) {
    let rate = 48_000
    let voice = (0..<(8 * rate)).map { i -> Float in
        let t = Double(i) / Double(rate)
        let syllable = 0.5 + 0.5 * sin(2 * .pi * 4 * t)
        return Float(0.25 * syllable * sin(2 * .pi * 220 * t))
    }
    var seed: UInt64 = 7
    let music = (0..<(3 * rate)).map { i -> Float in
        let t = Double(i) / Double(rate)
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        let noise = Double(Int64(bitPattern: seed >> 11) % 1000) / 1000
        return Float(0.12 * (sin(2 * .pi * 261.6 * t) + sin(2 * .pi * 329.6 * t) + sin(2 * .pi * 392 * t)) / 3 + 0.03 * noise)
    }
    let v = dir.appendingPathComponent("voice.wav"), m = dir.appendingPathComponent("music.wav")
    try WAVAudio(sampleRate: rate, channels: 1, samples: voice).write16(to: v)
    try WAVAudio(sampleRate: rate, channels: 1, samples: music).write16(to: m)
    return (v, m)
}

/// A project with the voice on A1 in two pieces (0–3 s and 5–8 s: a pause in between).
@MainActor
private func voiceProject(_ store: EditorStore, _ dir: URL, voice: URL) async throws {
    try await store.perform("project.new", ["name": "musica", "directory": .string(dir.path)])
    let asset = try await store.perform("media.import", ["path": .string(voice.path)]).value(at: "asset.id")?.stringValue ?? ""
    let track = try await store.perform("track.add", ["kind": "audio"]).value(at: "track.id")?.stringValue ?? ""
    try await store.perform("timeline.place", ["assetId": .string(asset), "trackId": .string(track), "start": 0, "sourceIn": 0, "sourceOut": 3])
    try await store.perform("timeline.place", ["assetId": .string(asset), "trackId": .string(track), "start": 5, "sourceIn": 5, "sourceOut": 8])
    await waitUntil { store.project?.tracks.first?.clips.count == 2 }
}

@MainActor
@Test func musicFromTheButtonLandsOnMusicaDuckedAndMeasuresLowerUnderTheVoice() async throws {
    guard FileManager.default.isExecutableFile(atPath: EngineConfig.expand(EngineConfig().ffmpeg)) else { return }   // needs ffmpeg
    let store = scratchStore()
    let dir = tempDir()
    let audio = try synthAudio(in: dir)
    try await voiceProject(store, dir, voice: audio.voice)

    // What "Aggiungi musica…" does once a file is chosen.
    store.addMusic(audio.music)
    await waitUntil { store.jobs.latest(AudioCalls.musicJob).map { !$0.isRunning } ?? false }
    let job = try #require(store.jobs.latest(AudioCalls.musicJob))
    #expect(job.state == .done, "\(job.state)")
    let music = try #require(AudioCalls.musicTrack(store.project))
    #expect(music.role == "music" && music.ducking?.depth == AudioCalls.defaultDepth)
    #expect(music.ducking?.sourceTrack == store.project?.tracks.first?.id)
    #expect(music.clips.count >= 3)                                                   // a 3 s loop filling 8 s
    #expect(abs(music.end.seconds - 8) < 0.05 && (music.clips[0].fadeIn?.seconds ?? 0) > 0)
    #expect(store.musicCheck?.signature == AudioCalls.signature(store.project))       // the check ran on this audio
    #expect(store.undoNames.contains("audio.addMusic"))

    // The music under the voice, rendered through the export mix: ducked, then with the ducking off.
    let ducked = try await store.perform(AudioCalls.checkDucking.id)
    let off = AudioCalls.duck(trackID: music.id, depth: 0)
    try await store.perform(off.id, off.params)
    await waitUntil { AudioCalls.musicTrack(store.project)?.ducking == nil }
    let flat = try await store.perform(AudioCalls.checkDucking.id)
    let underDucked = try #require(ducked["musicUnderSpeechLUFS"]?.doubleValue)
    let underFlat = try #require(flat["musicUnderSpeechLUFS"]?.doubleValue)
    print("E3 ducking measurement: music under speech \(underDucked) LUFS ducked vs \(underFlat) LUFS without ducking; "
          + "voice \(ducked["voiceLUFS"]?.doubleValue ?? .nan) LUFS; under the voice by \(ducked["underDB"]?.doubleValue ?? .nan) dB (pass \(ducked["pass"]?.boolValue ?? false))")
    #expect(underDucked < underFlat - 9)                                              // −12 dB of ducking, ramps included
    #expect(ducked["pass"]?.boolValue == true)
}

@MainActor
@Test func aSoundFromTheBrowserLandsOnTheEffettiTrackAtThePlayhead() async throws {
    let store = scratchStore()
    let dir = tempDir()
    try await store.perform("project.new", ["name": "effetti", "directory": .string(dir.path)])
    await waitUntil { store.project != nil }
    let sound = try #require(SoundLibrary.bank().first { $0.group == "pop" })
    store.preview.playhead.set(2.0)
    store.addSoundEffect(sound.name)                                                 // "+" on the row
    await waitUntil { store.project?.tracks.contains { $0.role == "sfx" } == true }
    let track = try #require(store.project?.tracks.first { $0.role == "sfx" })
    #expect(track.clips.count == 1 && abs(track.clips[0].start.seconds - 2.0) < 1e-6)
    #expect(store.project?.asset(track.clips[0].assetID)?.path == sound.path)
    #expect(abs((track.clips[0].gain ?? 0) - 20 * log10(0.3)) < 1e-9)               // sfx.add's default volume
    #expect(store.undoNames.last == "sfx.add")
    #expect(AudioCalls.addSFX(name: sound.name, at: 1.23456) == StepCall(id: "sfx.add", params: ["name": .string(sound.name), "at": 1.235]))
}

@MainActor
@Test func aPreviewNeverTouchesTheProject() async throws {
    let store = scratchStore()
    try await store.perform("project.new", ["name": "ascolto", "directory": .string(tempDir().path)])
    await waitUntil { store.project != nil }
    let before = store.project, undo = store.undoNames
    // The longest whoosh: a short one can end during the pause below on a busy Mac, and the second click then starts it again.
    let sound = try #require(SoundLibrary.bank().filter { $0.group == "whoosh" }.max { ($0.duration ?? 0) < ($1.duration ?? 0) })
    let player = SoundPreview.shared
    RigGuard.install()   // muted: nothing is heard on the machine running the tests
    player.toggle(sound)
    #expect(player.playing == sound.name)
    try? await Task.sleep(nanoseconds: 200_000_000)
    player.toggle(sound)                                                             // a second click stops it
    #expect(player.playing == nil)
    #expect(store.project == before && store.undoNames == undo && store.engine.project == before)
}

@Test func theDuckingCheckReadsInWords() {
    let lookup = { (s: String) in s }
    let ok = AudioCalls.duckingResult(["pass": true, "underDB": 19.4, "minUnder": 15], lookup: lookup)
    #expect(ok.pass && ok.line.contains("19"))
    let loud = AudioCalls.duckingResult(["pass": false, "underDB": 8, "minUnder": 15], lookup: lookup)
    #expect(!loud.pass && loud.line.contains("8") && loud.line.contains("15"))
    #expect(!ok.line.contains("audio.") && !loud.line.contains("audio."))             // no command ids in the words
}

/// The suite is silent: every player a test starts is muted by the rig's guard before it plays.
@MainActor
@Test func aTestRunPlaysNothingAloud() throws {
    RigGuard.install()
    let started = AVPlayer(), shuttled = AVPlayer()
    started.play()
    shuttled.rate = 2
    #expect(started.isMuted && shuttled.isMuted)
    started.pause(); shuttled.pause()
    let sound = try #require(SoundLibrary.bank().first)
    let effect = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: sound.path))
    effect.play()
    #expect(effect.volume == 0)
    effect.stop()
}

/// A track's default name is never what the window reads (#92): the voice track is «Voce» on its lane and in the Audio
/// panel's list, every graphics lane without a name of its own is «Grafica / IA», a renamed track keeps its name.
@MainActor
@Test func defaultTrackNamesReadAsTheirLanes() throws {
    let e = Engine(services: .live())
    _ = try e.execute("project.new", params: ["name": "piste", "directory": .string(tempDir().path)])
    for kind in ["video", "audio", "overlay", "overlay", "overlay"] { _ = try e.execute("track.add", params: ["kind": .string(kind)]) }
    var p = try #require(e.project)
    let overlays = p.tracks.filter { $0.kind == .overlay }
    let renamed = try #require(overlays.last?.id)
    if let i = p.tracks.firstIndex(where: { $0.id == renamed }) { p.tracks[i].name = "Cartelli" }
    let rows = LaneRow.rows(p)
    let voice = try #require(p.tracks.first { $0.kind == .audio })
    #expect(AudioMixTab.trackName(voice, in: p) == loc("Voce"), "the Audio panel names the voice track «\(AudioMixTab.trackName(voice, in: p))»")
    let titles = overlays.map { o in rows.first { $0.track?.id == o.id }?.title ?? "?" }
    #expect(titles.dropLast() .allSatisfy { $0 == "Grafica / IA" }, "graphics lanes read \(titles)")
    #expect(titles.last == "Cartelli", "a renamed graphics lane reads «\(titles.last ?? "?")»")
    #expect(!rows.contains { $0.title.range(of: #"^[VAOC]\d+$"#, options: .regularExpression) != nil }, "a lane reads a default name: \(rows.map(\.title))")
}

/// #95: beside the generated voice (the «Voce» track voice.say makes), a default-named voice lane carries the footage's own
/// sound and reads «Audio della ripresa», on its lane and in the Audio panel; the footage's sound alone, or the generated
/// voice alone, reads «Voce» as before, and a name of the person's own stays.
@MainActor
@Test func theFootageSoundBesideAGeneratedVoiceSaysWhatItIs() throws {
    func project(_ audio: [String?]) throws -> Project {
        let e = Engine(services: .live())
        _ = try e.execute("project.new", params: ["name": "voci", "directory": .string(tempDir().path)])
        _ = try e.execute("track.add", params: ["kind": "video"])
        for _ in audio { _ = try e.execute("track.add", params: ["kind": "audio"]) }
        var p = try #require(e.project)
        let ids = p.tracks.filter { $0.kind == .audio }.map(\.id)
        for (id, name) in zip(ids, audio) { if let name, let i = p.tracks.firstIndex(where: { $0.id == id }) { p.tracks[i].name = name } }
        return p
    }
    /// The lane titles and the Audio panel's names of the audio tracks, in order.
    func names(_ p: Project) -> (lanes: [String], panel: [String]) {
        let rows = LaneRow.rows(p)
        let audio = p.tracks.filter { $0.kind == .audio }
        return (audio.map { t in rows.first { $0.track?.id == t.id }?.title ?? "?" }, audio.map { AudioMixTab.trackName($0, in: p) })
    }
    let both = names(try project([nil, "Voce"]))
    #expect(both.lanes == ["track.footageSound", "Voce"], "footage sound + generated voice: \(both.lanes)")
    #expect(both.panel == [loc("track.footageSound"), loc("Voce")] && both.panel[0] != both.panel[1], "the Audio panel: \(both.panel)")
    let voiceFirst = names(try project(["Voce", nil]))
    #expect(voiceFirst.lanes == ["Voce", "track.footageSound"], "generated voice first: \(voiceFirst.lanes)")
    let footage = names(try project([nil]))
    #expect(footage.lanes == ["Voce"] && footage.panel == [loc("Voce")], "footage sound alone: \(footage)")
    let generated = names(try project(["Voce"]))
    #expect(generated.lanes == ["Voce"] && generated.panel == [loc("Voce")], "generated voice alone: \(generated)")
    let own = names(try project(["Intervista", "Voce"]))
    #expect(own.lanes == ["Intervista", "Voce"], "a name of the person's own: \(own.lanes)")
    for language in ["it", "en", "fr", "pt"] {
        let table = MouseRig.table(language)
        let word = table.localizedString(forKey: "track.footageSound", value: nil, table: nil)
        #expect(word != "track.footageSound" && word != table.localizedString(forKey: "Voce", value: nil, table: nil), "\(language): «\(word)»")
    }
}

// #95 on screen: the rich reel's voice lane (the footage's sound, a default name) beside a generated-voice «Voce» track,
// in the window's language: the timeline and the Audio panel read «Audio della ripresa» and «Voce».
extension MouseSuites {
@Suite(.serialized) @MainActor struct VoiceLaneNamesMouseTests {
    @Test func theFootageSoundLaneReadsAsSuchBesideTheVoice() async throws {
        let j = try await Journey("n23-voice-lanes", project: "rich")
        defer { j.close() }
        let added = try await j.store.perform("track.add", ["kind": "audio"])
        let id = try #require(added.value(at: "track.id")?.stringValue)
        _ = try await j.store.perform("track.set", ["trackId": .string(id), "name": "Voce"])
        for language in ["it", "fr", "pt"] {
            j.language = language
            await j.open(Navigation(activity: .audio, rightTab: .inspector))
            await j.app.idle(0.3)
            let sound = loc("track.footageSound"), voice = loc("Voce")
            #expect(sound != "track.footageSound", "\(language): no word for the footage sound")
            // On its lane header and in the Audio panel's list: at least twice each.
            #expect(j.rig.elements(containing: sound).count >= 2, "\(language): «\(sound)» is not on the lane and in the panel: \(j.screen())")
            #expect(j.rig.elements().filter { $0.role == "AXStaticText" && $0.value == voice }.count >= 2, "\(language): «\(voice)» is not on the lane and in the panel: \(j.screen())")
            j.step("\(language): the Audio panel and the timeline of a reel with its footage's sound and a generated voice", sees: "«\(sound)» and «\(voice)»")
        }
    }
}
}
