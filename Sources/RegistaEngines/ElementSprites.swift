import CoreGraphics
import CoreImage
import Foundation
import RegistaCore

/// Pictures for dragging an element on the preview (issue #21): the element alone, drawn by the export compositor
/// (so what moves under the pointer is exactly what will be rendered), and the frame without it (laid over the
/// element's old place while it is dragged away).
public enum ElementSprites {
    /// The element alone at timeline time `t`, cropped to its box (output pixels, a few pixels of margin): the image
    /// and the box it covers [x, y, w, h]. Captions show their whole line.
    public static func sprite(_ project: Project, element: CanvasElement, at t: MediaTime) -> (image: CGImage, box: [Double])? {
        let preset = ExportPreset.named(nil, project: project)
        let canvas = CGRect(x: 0, y: 0, width: preset.width, height: preset.height)
        var picture: CIImage?
        if let cid = element.clipID {
            let job = RenderJob(project: project, preset: preset, captions: false)
            guard let drawer = try? FrameDrawer(job: job, trackIDs: [:], orientations: [:]),
                  let layer = job.layers(at: t).first(where: { $0.clipID == cid }) else { return nil }
            picture = drawer.picture(layer, source: { _ in nil })
        } else if let ci = element.chunk {
            var job = RenderJob(project: project, preset: preset)
            guard var c = job.captions, c.chunks.indices.contains(ci) else { return nil }
            // The whole line (every word revealed), alone.
            c.style.reveal = "chunk"
            job.captions = c
            guard let drawer = try? FrameDrawer(job: job, trackIDs: [:], orientations: [:]),
                  let start = c.chunks[ci].words.first?.start else { return nil }
            picture = drawer.captionBand(at: max(start, t))
        }
        guard let picture else { return nil }
        let b = element.box
        let rect = CGRect(x: b[0] - 6, y: Double(preset.height) - b[1] - b[3] - 6, width: b[2] + 12, height: b[3] + 12).integral.intersection(canvas)
        guard !rect.isEmpty,
              let cg = context.createCGImage(picture.cropped(to: rect), from: rect, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) else { return nil }
        return (cg, [rect.minX, Double(preset.height) - rect.maxY, rect.width, rect.height])
    }

    /// The whole frame at `t` drawn without the element (the camera picture included).
    public static func frameWithout(_ project: Project, element: CanvasElement, at t: MediaTime) -> CGImage? {
        var p = project
        var captions = true
        if let cid = element.clipID, let loc = p.locate(clip: cid) { p.tracks[loc.track].clips.remove(at: loc.clip) } else { captions = false }
        let job = RenderJob(project: p, preset: ExportPreset.named(nil, project: project), captions: captions)
        return try? AVRenderer().renderImages(job, at: [t]).first
    }

    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
}
