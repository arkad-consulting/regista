import AppKit
import Foundation
import RegistaCore
import RegistaEngines

/// Pictures for the Graphics panel, all drawn by the export compositor: the current frame without any look (the
/// base of the filter thumbnails), the frame through a grade while a slider moves,
/// and the short animated previews of the catalog rows (each tile's command applied to a scratch copy of the
/// project, a few frames rendered). Cached per tile and per source frame, so editing does not re-render them.
@MainActor
final class EffectPreviews: ObservableObject {
    /// The frame at the playhead with no look or adjustment, 540×960.
    @Published private(set) var base: CGImage?
    /// The same frame through each look at full strength, thumbnail size.
    @Published private(set) var lookThumbs: [String: CGImage] = [:]
    /// The frame through the grade being dialled in (nil when no slider is moving).
    @Published private(set) var live: CGImage?
    /// Gallery tile frames by item id.
    @Published private(set) var tiles: [String: [CGImage]] = [:]

    weak var store: EditorStore?
    nonisolated private static let queue = DispatchQueue(label: "regista.effect-previews", qos: .userInitiated) // l10n-ignore
    nonisolated private static let tileQueue = DispatchQueue(label: "regista.effect-tiles", qos: .utility) // l10n-ignore
    private var baseKey: String?
    private var tileKey: String?
    private var pendingTiles: Set<String> = []
    private var liveGeneration = 0
    private var refreshWork: DispatchWorkItem?

    static let thumbSize = (width: 144, height: 256)
    static let baseSize = (width: 540, height: 960)

    /// The project as the "before": no look, no adjustments.
    nonisolated static func ungraded(_ p: Project) -> Project {
        var q = p
        q.grade = nil
        for t in q.tracks.indices { for c in q.tracks[t].clips.indices { q.tracks[t].clips[c].grade = nil } }
        return q
    }

    /// Its tab left the screen (S2 #76): the rendered frames go; the views ask for them again when shown.
    func purge() {
        refreshWork?.cancel()
        liveGeneration += 1
        base = nil
        lookThumbs = [:]
        live = nil
        tiles = [:]
        baseKey = nil
        tileKey = nil
        pendingTiles = []
    }

    /// Re-renders the base frame and the look thumbnails for the playhead (debounced).
    func refresh(at time: Double) {
        refreshWork?.cancel()
        guard store?.isActive != false else { return }   // a tab in the background renders nothing (S2 #76)
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.renderBase(at: time) } }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func renderBase(at time: Double) {
        guard let project = store?.project, project.duration > .zero else { base = nil; lookThumbs = [:]; return }
        let rate = project.settings.frameRate
        let t = min(MediaTime(seconds: time).snapped(to: rate), max(project.duration - MediaTime.frameDuration(at: rate), .zero))
        let plain = Self.ungraded(project)
        var key = plain
        key.markers = []
        let k = "\(key.hashValue)@\(t.ticks)"
        guard k != baseKey else { return }
        baseKey = k
        Self.queue.async {
            let job = RenderJob(project: plain, preset: ExportPreset(id: "graphics", width: Self.baseSize.width, height: Self.baseSize.height), captions: true)
            guard let img = (try? AVRenderer().renderImages(job, at: [t]))?.first else { return }
            let small = Self.scaled(img, width: Self.thumbSize.width, height: Self.thumbSize.height)
            var thumbs: [String: CGImage] = ["none": small ?? img]
            if let small {
                for look in Look.all {
                    thumbs[look.id] = GradePreview.apply(ResolvedGrade(look: look.id, amount: 1, adjust: Adjustments()), to: small, outputWidth: Self.thumbSize.width)
                }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.baseKey == k else { return }
                    self.base = img
                    self.lookThumbs = thumbs
                }
            }
        }
    }

    /// The base frame through `grade` (a slider is moving); nil clears it.
    func showLive(_ grade: ResolvedGrade?) {
        liveGeneration += 1
        let gen = liveGeneration
        guard let grade, let base else { live = nil; return }
        Self.queue.async {
            let img = GradePreview.apply(grade, to: base, outputWidth: Self.baseSize.width)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if let self, self.liveGeneration == gen { self.live = img } }
            }
        }
    }

    // MARK: Gallery tiles

    /// Renders a tile's animated preview once for the frame under the playhead (called when the tile appears).
    func requestTile(_ item: EffectsCatalog.Item, time: Double) {
        guard let store, store.isActive, let project = store.project, project.duration > .zero else { return }
        let rate = project.settings.frameRate
        let t = min(MediaTime(seconds: time).snapped(to: rate), max(project.duration - MediaTime(seconds: 2), .zero))
        // Same source frame → same previews: key on the main clip's media and second, not on the whole edit.
        let main = EffectsCatalog.mainClip(at: t, in: project)
        let key = "\(main?.assetID ?? "-")@\(Int(main.map { $0.sourceTime(atLocal: t - $0.start).seconds } ?? 0))" // l10n-ignore
        if key != tileKey { tileKey = key; tiles = [:]; pendingTiles = [] }
        guard tiles[item.id] == nil, !pendingTiles.contains(item.id) else { return }
        pendingTiles.insert(item.id)
        let services = store.engine.context.services
        let clipID = main?.id
        Self.tileQueue.async {
            let frames = Self.renderTile(item, project: project, clipID: clipID, at: t, services: services)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.tileKey == key else { return }
                    self.pendingTiles.remove(item.id)
                    self.tiles[item.id] = frames
                }
            }
        }
    }

    /// The tile's command on a scratch copy, then 8 frames over the moment it changes.
    nonisolated static func renderTile(_ item: EffectsCatalog.Item, project: Project, clipID: String?, at t: MediaTime, services: EngineServices) -> [CGImage] {
        var p = project
        p.tracks = p.tracks.map { var tr = $0; if tr.kind == .caption { tr.hidden = true }; return tr }
        let scratch = Engine(scratch: p, services: services)
        let target = EffectTarget(clipID: item.needs == .picture ? nil : clipID, start: t, end: nil)
        let (command, params) = EffectsCatalog.resolve(item, target: target, intensity: 0.6, project: p)
        guard let result = try? scratch.execute(command, params: params), let edited = scratch.project else { return [] }
        let (a, b) = window(params: params, result: result, target: target, project: edited)
        let rate = edited.settings.frameRate
        // Starts mid-effect, so the still poster (first frame) already shows it.
        let times = (0..<8).map { k in MediaTime(seconds: a + (b - a) * Double((k + 3) % 8) / 8).snapped(to: rate) }
        let job = RenderJob(project: edited, preset: ExportPreset(id: "tile", width: thumbSize.width, height: thumbSize.height), captions: false)
        return (try? AVRenderer().renderImages(job, at: times)) ?? []
    }

    /// Where a tile's effect shows (the core's definition, shared with effects.preview).
    nonisolated static func window(params: JSONValue, result: JSONValue, target: EffectTarget, project: Project) -> (Double, Double) {
        EffectsCatalog.window(params: params, result: result, target: target, project: project)
    }

    nonisolated static func scaled(_ img: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}
