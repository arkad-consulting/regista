import AVFoundation
import Foundation
import RegistaCore

/// The commands behind the Audio panel (E3 #55): music through audio.addMusic (fitted to the edit, faded, ducked under
/// the voice by default), its volume and ducking, the ducking check, and sound effects through sfx.add. Pure, so the
/// buttons and the tests run exactly the same calls.
enum AudioCalls {
    /// The job kind of the music work (adding it, checking it under the voice).
    static let musicJob = "audio.music"

    /// Aggiungi musica: the command's own defaults (−22 LUFS bed, loop or trim to the edit, fades, ducking −12 dB).
    static func addMusic(path: String) -> StepCall { StepCall(id: "audio.addMusic", params: ["path": .string(path)]) }
    static let checkDucking = StepCall(id: "audio.checkDucking", params: [:])
    /// The music's volume: every clip of its track (a looped bed is several clips), one undo step.
    static func musicVolume(trackID: String, gain: Double) -> StepCall {
        StepCall(id: "clip.set", params: ["trackId": .string(trackID), "gain": .number((gain * 10).rounded() / 10)])
    }
    /// How far the music goes down under the voice (0 = no ducking).
    static func duck(trackID: String, depth: Double) -> StepCall {
        StepCall(id: "audio.duck", params: ["trackId": .string(trackID), "duck": .number(depth.rounded())])
    }
    static let defaultDepth = -12.0
    /// A sound of the library at a time (the playhead), at sfx.add's default volume.
    static func addSFX(name: String, at time: Double) -> StepCall {
        StepCall(id: "sfx.add", params: ["name": .string(name), "at": .number((max(time, 0) * 1000).rounded() / 1000)])
    }

    /// The music track (the first one with clips).
    static func musicTrack(_ p: Project?) -> Track? { p?.tracks.first { $0.kind == .audio && $0.role == "music" && !$0.clips.isEmpty } }
    /// The voice the music ducks under: the first audio track without a role that has clips.
    static func voiceTrack(_ p: Project?) -> Track? { p?.tracks.first { $0.kind == .audio && ($0.role == nil || $0.role == "voice") && !$0.clips.isEmpty } }

    /// Audio-only media of the project not on any track (a downloaded or generated track): usable as music.
    static func projectMusic(_ p: Project?) -> [MediaAsset] {
        guard let p else { return [] }
        let used = Set(p.tracks.flatMap(\.clips).map(\.assetID))
        return p.assets.filter { $0.video == nil && $0.image == nil && $0.audio != nil && $0.origin == nil && !used.contains($0.id) }
    }

    /// What the ducking check found, in words.
    static func duckingResult(_ r: JSONValue, lookup: (String) -> String = loc) -> MusicCheck {
        let under = r["underDB"]?.doubleValue ?? 0, need = r["minUnder"]?.doubleValue ?? 15
        let pass = r["pass"]?.boolValue ?? false
        let line = pass
            ? String(format: lookup("Ducking OK: sotto la voce la musica sta %@ dB più bassa."), Fmt.number(under))
            : String(format: lookup("Musica troppo alta sotto la voce: %@ dB sotto, ne servono %@. Abbassa il volume o fai scendere di più la musica."),
                     Fmt.number(under), Fmt.number(need))
        return MusicCheck(pass: pass, line: line, signature: 0)
    }

    /// The audio side of a project: a check is shown only while it is unchanged.
    static func signature(_ p: Project?) -> Int { p?.tracks.filter { $0.kind == .audio }.hashValue ?? 0 }
}

/// The last ducking check of a tab and the audio it measured.
struct MusicCheck: Equatable {
    var pass: Bool
    var line: String
    var signature: Int
}

extension EditorStore {
    /// Aggiungi musica…: audio.addMusic, then the check under the voice, as one job of this tab.
    func addMusic(_ url: URL) {
        guard project != nil, jobs.latest(AudioCalls.musicJob)?.isRunning != true else { return }
        startJob(kind: AudioCalls.musicJob, title: loc("Musica")) { [weak self] h, job in
            guard let self else { return }
            h.update(detail: loc("Porto la musica al livello giusto e la abbasso sotto la voce…"))
            do { try await self.performInJob(AudioCalls.addMusic(path: url.path), job, from: 0, to: 0.4) }
            catch is CancellationError { throw CancellationError() }
            catch { throw StepError(message: StepError.readable(error)) }
            try await self.measureMusic(h, job, from: 0.4)
        }
    }

    /// Controlla sotto la voce: audio.checkDucking as a job (it renders the voice and the music stems).
    func checkMusic() {
        guard AudioCalls.musicTrack(project) != nil, jobs.latest(AudioCalls.musicJob)?.isRunning != true else { return }
        startJob(kind: AudioCalls.musicJob, title: loc("Musica")) { [weak self] h, job in
            try await self?.measureMusic(h, job, from: 0)
        }
    }

    private func measureMusic(_ h: JobCenter.Handle, _ job: CommandJob, from lo: Double) async throws {
        guard AudioCalls.voiceTrack(project) != nil else {
            h.update(detail: loc("Nessuna voce nel progetto: la musica resta al suo livello."))
            return
        }
        h.update(detail: loc("Misuro la musica sotto la voce…"))
        let r: JSONValue
        do { r = try await performInJob(AudioCalls.checkDucking, job, from: lo, to: 1) }
        catch is CancellationError { throw CancellationError() }
        catch { throw StepError(message: StepError.readable(error)) }
        var check = AudioCalls.duckingResult(r)
        check.signature = AudioCalls.signature(project)
        musicCheck = check
        h.update(detail: check.line)
    }

    /// A change of the music (volume, ducking) from the panel, then the check again.
    func changeMusic(_ call: StepCall) {
        Task {
            do { try await perform(call.id, call.params) } catch { errorMessage = StepError.readable(error); return }
            checkMusic()
        }
    }

    /// Aggiungi al cursore (or a drop on the timeline at `time`): sfx.add with the command's default volume.
    func addSoundEffect(_ name: String, at time: Double? = nil) {
        guard project != nil else { return }
        let c = AudioCalls.addSFX(name: name, at: time ?? preview.time)
        run(c.id, c.params)
    }
}

/// Plays a sound of the library on its own (AVAudioPlayer): never the edit, never the preview player.
@MainActor
final class SoundPreview: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = SoundPreview()

    /// The sound playing now (its library name).
    @Published private(set) var playing: String?
    private var player: AVAudioPlayer?

    /// Plays `sound`, or stops it when it is the one playing.
    func toggle(_ sound: SoundEffect) {
        if playing == sound.name { return stop() }
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: sound.path)) else { return }
        p.delegate = self
        p.play()
        player = p
        playing = sound.name
    }

    func stop() {
        player?.stop()
        player = nil
        playing = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(p)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let current = self.player, ObjectIdentifier(current) == id { self.player = nil; self.playing = nil }
            }
        }
    }
}

/// A sound of the library dragged onto the timeline (`regista-sfx:<name>`): placed with sfx.add at the drop time.
enum SFXDrop {
    static let prefix = "regista-sfx:"
}
