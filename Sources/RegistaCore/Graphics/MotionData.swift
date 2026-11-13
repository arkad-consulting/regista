import Foundation

// Real edit data for motion templates (issue #22, round 3): templates such as receipt, cut-visualizer, sfx-callout
// and logo-tile show what Regista knows about the edit — cuts, seconds removed, durations, the sound effects on the
// timeline, the brand logo — instead of asking the user to type numbers. A resolver fills the fields the caller did
// not set, when motion.add runs (so the numbers are those of the edit at that moment; add the template again after
// re-cutting).

public enum MotionData {
    public typealias Resolver = (_ fields: inout [String: JSONValue], _ given: Set<String>, _ start: MediaTime, _ end: MediaTime,
                                 _ ctx: inout CommandContext) throws -> Void

    /// Template id → resolver. Register next to the template's other Core needs (most templates have none).
    static let resolvers: [String: Resolver] = [
        "receipt": receipt, "cut-visualizer": cuts, "sfx-callout": sfx, "logo-tile": logo, "chat-window": clipName,
    ]

    /// The stats of the edit: the main picture track's clips against the source they come from.
    public struct EditStats: Sendable {
        public var rawSeconds: Double
        public var finalSeconds: Double
        public var cuts: Int
        public var removedSeconds: Double
        /// Kept source ranges of the main asset, fractions of its length, sorted.
        public var kept: [[Double]]
        public var captionWords: Int
        public var soundEffects: Int
        public var graphics: Int
    }

    public static func stats(_ p: Project) -> EditStats {
        let main = p.tracks.first { $0.kind == .video && !$0.clips.isEmpty }
        let clips = main?.clips.filter { !$0.isGenerated } ?? []
        // The asset most of the picture comes from.
        let byAsset = Dictionary(grouping: clips, by: \.assetID)
        let assetID = byAsset.max { a, b in a.value.reduce(0) { $0 + $1.sourceDuration.seconds } < b.value.reduce(0) { $0 + $1.sourceDuration.seconds } }?.key
        let asset = assetID.flatMap { p.asset($0) }
        let raw = asset?.duration.seconds ?? clips.reduce(0) { $0 + $1.sourceDuration.seconds }
        let mine = clips.filter { $0.assetID == assetID }
        let kept = mine.map { [$0.sourceIn.seconds / max(raw, 1e-9), $0.sourceOut.seconds / max(raw, 1e-9)] }.sorted { $0[0] < $1[0] }
        let used = mine.reduce(0) { $0 + $1.sourceDuration.seconds }
        let words = p.tracks.compactMap(\.captions).flatMap(\.chunks).reduce(0) { $0 + $1.words.count }
        let sfx = p.tracks.filter { $0.kind == .audio && $0.role == "sfx" }.reduce(0) { $0 + $1.clips.count }
        let graphics = p.tracks.filter { $0.kind == .overlay }.reduce(0) { $0 + $1.clips.count }
        return EditStats(rawSeconds: raw, finalSeconds: main?.end.seconds ?? 0, cuts: max(clips.count - 1, 0), removedSeconds: max(raw - used, 0),
                         kept: kept, captionWords: words, soundEffects: sfx, graphics: graphics)
    }

    /// "1:42"
    public static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func set(_ fields: inout [String: JSONValue], _ given: Set<String>, _ k: String, _ v: JSONValue) {
        if !given.contains(k) { fields[k] = v }
    }

    static func receipt(_ f: inout [String: JSONValue], _ given: Set<String>, _ start: MediaTime, _ end: MediaTime, _ ctx: inout CommandContext) throws {
        guard let p = ctx.project else { return }
        let s = stats(p)
        guard s.rawSeconds > 0 else { return }
        var rows: [JSONValue] = [.string("Cuts: \(s.cuts)"), .string("Seconds removed: \(Int(s.removedSeconds.rounded()))")]
        if s.captionWords > 0 { rows.append(.string("Captions: \(s.captionWords) words")) }
        if s.soundEffects > 0 { rows.append(.string("Sound effects: \(s.soundEffects)")) }
        if s.graphics > 0 { rows.append(.string("Graphics: \(s.graphics)")) }
        set(&f, given, "rows", .array(rows))
        set(&f, given, "total", .string("\(clock(s.rawSeconds)) → \(clock(s.finalSeconds))"))
    }

    static func cuts(_ f: inout [String: JSONValue], _ given: Set<String>, _ start: MediaTime, _ end: MediaTime, _ ctx: inout CommandContext) throws {
        guard let p = ctx.project else { return }
        let s = stats(p)
        guard !s.kept.isEmpty else { return }
        set(&f, given, "kept", .array(s.kept.flatMap { $0 }.map { .number(($0 * 10000).rounded() / 10000) }))
        set(&f, given, "raw", .string(clock(s.rawSeconds)))
        set(&f, given, "final", .string(clock(s.finalSeconds)))
    }

    static func sfx(_ f: inout [String: JSONValue], _ given: Set<String>, _ start: MediaTime, _ end: MediaTime, _ ctx: inout CommandContext) throws {
        guard let p = ctx.project else { return }
        // The sound effect playing in (or nearest after the start of) the window.
        let effects = p.tracks.filter { $0.kind == .audio && $0.role == "sfx" }.flatMap(\.clips).sorted { $0.start < $1.start }
        guard let c = effects.first(where: { $0.end > start && $0.start < end }) ?? effects.first(where: { $0.start >= start }) else { return }
        let name = p.asset(c.assetID).map { URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent } ?? "effect"
        set(&f, given, "name", .string(name.replacingOccurrences(of: "-", with: " ").uppercased()))
        // Where the effect sits in the strip (the strip shows the clip window), fractions.
        let span = max((end - start).seconds, 0.1)
        set(&f, given, "block", .array([.number(max((c.start - start).seconds / span, 0)), .number(min((c.end - start).seconds / span, 1))]))
    }

    static func logo(_ f: inout [String: JSONValue], _ given: Set<String>, _ start: MediaTime, _ end: MediaTime, _ ctx: inout CommandContext) throws {
        guard !given.contains("logo"), let kit = ctx.project?.brand, let path = kit.logoPath("mark") ?? kit.logoPath() else { return }
        if path.lowercased().hasSuffix(".svg"), let images = ctx.services.images {
            let png = try ctx.mediaDirectory().appendingPathComponent("\(kit.id)-logo-tile.png")
            _ = try images.rasterizeSVG(URL(fileURLWithPath: path), width: 600, to: png)
            f["logo"] = .string(png.path)
        } else {
            f["logo"] = .string(path)
        }
    }

    static func clipName(_ f: inout [String: JSONValue], _ given: Set<String>, _ start: MediaTime, _ end: MediaTime, _ ctx: inout CommandContext) throws {
        guard let p = ctx.project, let main = p.tracks.first(where: { $0.kind == .video && !$0.clips.isEmpty }),
              let c = main.clips.first(where: { $0.start <= start && start < $0.end }) ?? main.clips.first, let a = p.asset(c.assetID) else { return }
        set(&f, given, "attachment", .string(a.name))
        set(&f, given, "attachmentLength", .string(clock(stats(p).rawSeconds)))
    }
}
