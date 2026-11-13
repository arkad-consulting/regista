import AVFoundation
import Foundation
import RegistaCore

/// The app's real-time preview: the export's AVMutableComposition and custom compositor
/// (`TimelineCompositor`, the same `FrameDrawer`) played by an AVPlayer, so preview = export = frame.render.
/// Sound: every clip of the unmuted audio tracks on its own composition track, with its edge fades as
/// volume ramps (the export mixes the same clips with ffmpeg and a limiter).
public struct PreviewItem {
    public let item: AVPlayerItem
    /// The project the item was built from.
    public let project: Project
    /// Source assets, kept alive while the player reads them (a composition track does not retain its asset).
    let sources: [AVURLAsset]
}

public enum PreviewPlayer {
    /// Builds a player item for the whole timeline. Blocking (loads the source tracks): call off the main thread.
    public static func makeItem(_ project: Project, preset: ExportPreset? = nil) throws -> PreviewItem {
        let job = RenderJob(project: project, preset: preset ?? ExportPreset.named(nil, project: project))
        let built = try AVRenderer().build(job)
        var sources = built.sources
        var params: [AVMutableAudioMixInputParameters] = []
        let end = AVRenderer.cm(job.duration)
        var audioAssets: [String: AVAssetTrack] = [:]
        for track in project.tracks where track.kind == .audio && !track.muted && !track.clips.isEmpty {
            guard let ct = built.composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            let mix = AVMutableAudioMixInputParameters(track: ct)
            for clip in track.clips {
                guard let asset = project.asset(clip.assetID), asset.audio != nil else { continue }
                if audioAssets[asset.id] == nil {
                    let av = AVURLAsset(url: URL(fileURLWithPath: asset.path))
                    guard let at = VisionFaceTracker.load({ try await av.loadTracks(withMediaType: .audio) })?.first else { continue }
                    audioAssets[asset.id] = at
                    sources.append(av)
                }
                let start = AVRenderer.cm(clip.start)
                if clip.speed?.effectiveAudio == .mute { continue }   // silent while retimed (export: same rule)
                try? AVRenderer.insert(clip, from: audioAssets[asset.id]!, into: ct, frameRate: project.settings.frameRate, step: 0.1)
                if let f = clip.fadeIn, f > .zero {
                    mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1, timeRange: CMTimeRange(start: start, duration: AVRenderer.cm(f)))
                } else {
                    mix.setVolume(1, at: start)   // after the previous clip's fade-out
                }
                if let f = clip.fadeOut, f > .zero {
                    mix.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                                      timeRange: CMTimeRange(start: AVRenderer.cm(clip.end - f), duration: AVRenderer.cm(f)))
                }
            }
            if ct.timeRange.end < end { ct.insertEmptyTimeRange(CMTimeRange(start: ct.timeRange.end, end: end)) }
            params.append(mix)
        }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        item.audioTimePitchAlgorithm = .spectral   // retimed clips keep their pitch
        if !params.isEmpty {
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = params
            item.audioMix = audioMix
        }
        return PreviewItem(item: item, project: project, sources: sources)
    }

    /// A player item for one source file as it is (the Source monitor), with the orientation its frames
    /// need to be displayed upright (video outputs ignore the track's preferred transform). Blocking.
    public static func sourceItem(path: String) -> (item: AVPlayerItem, orientation: CGImagePropertyOrientation) {
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let track = VisionFaceTracker.load({ try await asset.loadTracks(withMediaType: .video) })?.first
        let transform = track.flatMap { t in VisionFaceTracker.load({ try await t.load(.preferredTransform) }) } ?? .identity
        return (AVPlayerItem(asset: asset), VisionFaceTracker.orientation(transform))
    }
}
