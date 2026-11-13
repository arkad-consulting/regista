import Foundation

/// The transcript as the timeline plays it: the words of each clip's source (or of the file it was
/// derived from, e.g. the cleaned voice) mapped from source time to timeline time. A word belongs to a
/// clip when its middle lies inside the clip's source range; its times are clamped to the clip.
public struct TimelineWord: Hashable, Sendable {
    public var index: Int
    public var text: String
    public var start: MediaTime
    public var end: MediaTime
    public var clipID: String
    /// Source times in the transcribed asset.
    public var sourceStart: MediaTime
    public var sourceEnd: MediaTime
}

public enum TimelineTranscript {
    /// The transcript of an asset, or of the asset it was made from (same time base).
    public static func transcript(of asset: MediaAsset, in project: Project) -> Transcript? {
        if let t = asset.analysis?.transcript { return t }
        return asset.origin.flatMap { project.asset($0.assetID) }.flatMap { $0.analysis?.transcript }
    }

    /// The track words are read from when none is given: the first video track with clips, else the first audio one —
    /// preferring, in that order, a track that carries transcribed words. A screen recording keeps its words on the
    /// microphone track and a voice-over on the Voce track, under a picture track that says nothing.
    public static func defaultTrack(in project: Project) -> Track? {
        let candidates = project.tracks.filter { $0.kind == .video && !$0.clips.isEmpty }
            + project.tracks.filter { $0.kind == .audio && !$0.clips.isEmpty }
        return candidates.first { !words(of: $0, in: project).isEmpty } ?? candidates.first
    }

    public static func words(of track: Track, in project: Project) -> [TimelineWord] {
        var out: [TimelineWord] = []
        for clip in track.clips {
            guard let asset = project.asset(clip.assetID), let t = transcript(of: asset, in: project) else { continue }
            for w in t.words {
                let mid = MediaTime(ticks: (w.start.ticks + w.end.ticks) / 2)
                guard mid >= clip.sourceIn, mid < clip.sourceOut else { continue }
                let s = max(w.start, clip.sourceIn), e = min(w.end, clip.sourceOut)
                // Retimed clips map through their speed; reversed and frozen ones say no words.
                guard clip.speed?.reverse != true, clip.speed?.freeze != true,
                      let ts = clip.timelineTime(ofSource: s), let te = clip.timelineTime(ofSource: e) else { continue }
                out.append(TimelineWord(index: out.count, text: w.text, start: ts, end: te, clipID: clip.id, sourceStart: w.start, sourceEnd: w.end))
            }
        }
        return out
    }
}
