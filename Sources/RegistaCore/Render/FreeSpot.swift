import Foundation

/// Where a new graphic can go without covering what is already on the frame: the captions, titles, stickers and logos
/// drawn at that moment and the faces of the picture. The gallery uses it so a sticker or a title clicked in the app
/// lands where it can be seen instead of on top of the last one.
public enum FreeSpot {
    /// A centre, on the 1080×1920 reference frame, for a box of `size` (reference pixels) at timeline time `t`: the first
    /// of `candidates` that overlaps nothing, else the one that overlaps least.
    public static func centre(in project: Project, at t: MediaTime, size: [Double], candidates: [[Double]],
                              renderer: VideoRenderer?) -> [Double] {
        guard let first = candidates.first else { return [540, 380] }
        let k = Double(project.settings.width) / SafeZones.referenceWidth
        var taken = CanvasLayout.elements(project, at: t, renderer: renderer).map { $0.box.map { $0 / k } }
        var faces = OutputFaces(job: RenderJob(project: project, preset: ExportPreset.named(nil, project: project), captions: false))
        taken += faces.boxes(at: t).map { $0.map { $0 / k } }
        func overlap(_ c: [Double]) -> Double {
            let margin = 16.0
            let r = (x: c[0] - size[0] / 2 - margin, y: c[1] - size[1] / 2 - margin, w: size[0] + 2 * margin, h: size[1] + 2 * margin)
            return taken.reduce(0) { sum, b in
                let w = min(r.x + r.w, b[0] + b[2]) - max(r.x, b[0]), h = min(r.y + r.h, b[1] + b[3]) - max(r.y, b[1])
                return sum + (w > 0 && h > 0 ? w * h : 0)
            }
        }
        var best = first, bestScore = Double.infinity
        for c in candidates {
            let s = overlap(c)
            if s == 0 { return c }
            if s < bestScore { best = c; bestScore = s }
        }
        return best
    }

    /// Candidate centres by kind of graphic, in order of preference.
    public static let stickerSpots: [[Double]] = [[800, 520], [280, 520], [810, 1010], [270, 1010], [540, 300], [540, 1090]]
    public static let titleSpots: [[Double]] = [[540, 375], [540, 600], [540, 1090], [540, 860]]
}
