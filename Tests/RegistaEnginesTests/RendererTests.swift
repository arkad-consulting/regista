import AVFoundation
import CoreImage
import Foundation
import ImageIO
import Testing
@testable import RegistaCore
@testable import RegistaEngines

/// A 1 s 1080×1920 30 fps H.264 clip: top half red, bottom half blue.
func syntheticClip() throws -> URL {
    let url = TemporaryFolder.url.appendingPathComponent("regista-synth-\(UUID().uuidString).mov")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1080, AVVideoHeightKey: 1920])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 1080, kCVPixelBufferHeightKey as String: 1920])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    for f in 0..<30 {
        while !input.isReadyForMoreMediaData { usleep(1000) }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        let buffer = pb!
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = CVPixelBufferGetBaseAddress(buffer)!.bindMemory(to: UInt8.self, capacity: CVPixelBufferGetDataSize(buffer))
        let row = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<1920 {
            for x in 0..<1080 {
                let o = y * row + 4 * x
                (base[o], base[o + 1], base[o + 2], base[o + 3]) = y < 960 ? (0, 0, 220, 255) : (220, 0, 0, 255)   // BGRA
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    return url
}

func project(_ clip: URL) -> Project {
    var p = Project(name: "synth")
    p.assets = [MediaAsset(id: "a1", name: "synth", path: clip.path, duration: MediaTime(seconds: 1),
                           video: VideoInfo(width: 1080, height: 1920, frameRate: Rational(30), codec: "h264"), audio: nil)]
    var v = Track(id: "t1", kind: .video, name: "V1")
    var c = Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: MediaTime(seconds: 1), start: .zero)
    c.transform = Transform(crop: [540, 960, 270, 960], sourceWidth: 1080, sourceHeight: 1920)   // bottom half: all blue
    v.clips = [c]
    p.tracks = [v]
    p.idCounters = ["a": 1, "t": 1, "c": 1]   // commands run on it make new ids
    return p
}

func pixel(_ png: URL, _ x: Int, _ y: Int) throws -> (Int, Int, Int) {
    let src = try #require(CGImageSourceCreateWithURL(png as CFURL, nil))
    let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
    let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let p = ctx.data!.bindMemory(to: UInt8.self, capacity: img.width * img.height * 4)
    let o = (y * img.width + x) * 4
    return (Int(p[o]), Int(p[o + 1]), Int(p[o + 2]))
}

@Test func compositorCropsGradesAndDrawsCaptions() throws {
    let clip = try syntheticClip()
    defer { try? FileManager.default.removeItem(at: clip) }
    var p = project(clip)
    let words: [(text: String, start: MediaTime, end: MediaTime)] = [("prova", .zero, MediaTime(seconds: 0.4)), ("sito", MediaTime(seconds: 0.5), MediaTime(seconds: 0.9))]
    let chunks = CaptionBuilder.build(words: words, style: .talkingHeadV1, keywords: ["SITO"], fixes: [:])
    var caps = Track(id: "t2", kind: .caption, name: "C1")
    caps.captions = Captions(style: .talkingHeadV1, keywords: ["SITO"], fixes: [:], sourceTrack: "t1", sourceSignature: "", chunks: chunks)
    p.tracks.append(caps)
    let job = RenderJob(project: p, preset: .vertical)
    let dir = TemporaryFolder.url.appendingPathComponent("regista-render-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let a = dir.appendingPathComponent("a.png"), b = dir.appendingPathComponent("b.png")
    try AVRenderer().renderFrames(job, at: [MediaTime(seconds: 0.2), MediaTime(seconds: 0.6)], to: [a, b])
    // The crop shows only the blue half, scaled to fill the frame.
    let top = try pixel(a, 540, 100), bottom = try pixel(a, 540, 1800)
    #expect(top.2 > 180 && top.0 < 40 && bottom.2 > 180)
    // Captions: the keyword box is pink once its word starts, inside the band.
    let boxes = try AVRenderer().captionLayout(job)
    #expect(boxes.count == 1 && boxes[0].count == 2)
    let kw = boxes[0][1]
    #expect(kw[1] >= 1244 && kw[1] + kw[3] <= 1444)
    let pink = try pixel(b, Int(kw[0] + 6), Int(kw[1] + 4))
    #expect(abs(pink.0 - 255) < 12 && abs(pink.1 - 45) < 12 && abs(pink.2 - 111) < 12)
    let before = try pixel(a, Int(kw[0] + 6), Int(kw[1] + 4))
    #expect(before.2 > 180)   // not shown yet at 0.2 s
    // Grade: the ffmpeg eq matrix keeps grey grey and lifts it by ~ the brightness.
    let grey = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
    var out = [Float](repeating: 0, count: 4)
    CIContext(options: [.workingColorSpace: NSNull()]).render(FrameDrawer.grade(grey, ColorAdjust(brightness: 0.02, contrast: 1.06, saturation: 1.08)),
                                                              toBitmap: &out, rowBytes: 16, bounds: grey.extent, format: .RGBAf, colorSpace: nil)
    #expect(abs(out[0] - out[1]) < 1e-4 && abs(out[1] - out[2]) < 1e-4 && out[0] > 0.51 && out[0] < 0.53)
}

@Test func exportWritesFastStartH264() throws {
    let clip = try syntheticClip()
    defer { try? FileManager.default.removeItem(at: clip) }
    let out = TemporaryFolder.url.appendingPathComponent("regista-export-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: out) }
    let report = try AVRenderer().export(RenderJob(project: project(clip), preset: .square), audio: nil, to: out, bitrate: 4_000_000)
    #expect(report.frames == 30)
    let asset = AVURLAsset(url: out)
    let track = try #require(VisionFaceTracker.load({ try await asset.loadTracks(withMediaType: .video) })?.first)
    let size = VisionFaceTracker.load({ try await track.load(.naturalSize) })
    #expect(size == CGSize(width: 1080, height: 1080))
    let atoms = MediaCheck.atoms(out)
    #expect(atoms.contains("moov") && atoms.firstIndex(of: "moov")! < atoms.firstIndex(of: "mdat")!)
}

/// Titles, image overlays and frame effects through the real compositor (issue #5).
@Test func titlesOverlaysAndFlashAreDrawnByTheCompositor() throws {
    let clip = try syntheticClip()
    defer { try? FileManager.default.removeItem(at: clip) }
    var p = project(clip)
    // A white 200×100 PNG overlay at the centre of the top band, a yellow box title lower down.
    let dir = TemporaryFolder.url.appendingPathComponent("regista-gfx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let png = dir.appendingPathComponent("white.png")
    let c = CaptionRasterizer.context(200, 100)
    c.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    c.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    try CaptionRasterizer.writePNG(c.makeImage()!, to: png)
    p.assets.append(MediaAsset(id: "a2", name: "white", path: png.path, duration: ImageSource.stillDuration,
                               video: VideoInfo(width: 200, height: 100, frameRate: Rational(30), codec: "png"), audio: nil,
                               image: ImageSource(kind: .still, path: png.path)))
    var o = Track(id: "t2", kind: .overlay, name: "O1")
    var still = Clip(id: "c2", assetID: "a2", sourceIn: .zero, sourceOut: MediaTime(seconds: 1), start: .zero)
    still.placement = Placement(fit: .native, x: 0.5, y: 375.0 / 1920)
    o.clips = [still]
    var title = Title(text: "HELLO", font: "Helvetica-Bold", size: 80, color: "#000000")
    title.background = TitleBackground(kind: "box", color: "#FFFF00", padX: 30, padY: 20, radius: 0)
    var tt = Track(id: "t3", kind: .overlay, name: "Titles")
    var tc = Clip(id: "c3", assetID: "", sourceIn: .zero, sourceOut: MediaTime(seconds: 1), start: .zero)
    tc.title = title
    tc.placement = Placement(fit: .native, x: 0.5, y: 0.5)
    tt.clips = [tc]
    p.tracks += [o, tt]
    p.transitions = [Transition(id: "tr1", kind: .flash, at: MediaTime(seconds: 0.8), duration: MediaTime(seconds: 0.2))]
    let renderer = AVRenderer()
    let box = try renderer.titleBox(title, outputWidth: 1080)
    #expect(box.width > 200 && box.width < 600 && box.height > 100 && box.height < 160)
    let f0 = dir.appendingPathComponent("f0.png"), f1 = dir.appendingPathComponent("f1.png")
    try renderer.renderFrames(RenderJob(project: p, preset: .vertical), at: [MediaTime(seconds: 0.2), MediaTime(seconds: 0.8)], to: [f0, f1])
    let white = try pixel(f0, 540, 375), outside = try pixel(f0, 540, 300), corner = try pixel(f0, 540 - Int(box.width / 2) + 6, 960)
    #expect(white.0 > 240 && white.1 > 240 && white.2 > 240)          // the still, native size, centred in the top band
    #expect(outside.2 > 150 && outside.0 < 60)                        // video (blue) above it
    #expect(corner.0 > 230 && corner.1 > 230 && corner.2 < 40)        // the title's yellow box
    let flash = try pixel(f1, 100, 1500)
    #expect(flash.0 > 200 && flash.1 > 200)                           // the flash peaks on the cut
    // MLT helper: one layer drawn alone on a transparent frame.
    let layer = dir.appendingPathComponent("layer.png")
    try renderer.writeLayerImage(RenderJob(project: p, preset: .vertical), clipID: "c3", at: MediaTime(seconds: 0.5), to: layer)
    #expect(try pixel(layer, 540, 960 - Int(box.height / 2) + 4).1 > 230)
}

@Test func behindSubjectLayersGoUnderThePersonMatte() throws {
    let clip = try syntheticClip()
    defer { try? FileManager.default.removeItem(at: clip) }
    var p = project(clip)
    p.tracks[0].clips[0].transform = nil   // whole frame: red top, blue bottom
    // Matte: the left half of the frame is "the person".
    let dir = TemporaryFolder.url.appendingPathComponent("regista-matte-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let mask = (0..<96 * 54).map { $0 % 54 < 27 ? UInt8(255) : 0 }
    for i in 0..<30 { try VisionPersonSegmenter.writeGray(mask, width: 54, height: 96, to: dir.appendingPathComponent(String(format: "%06d.png", i))) }
    p.assets[0].analysis = AssetAnalysis()
    p.assets[0].analysis?.matte = MatteTrack(directory: dir.path, width: 54, height: 96, frameRate: 30, ranges: [[0, 29]], engine: "test")

    func title(_ id: String, _ color: String, y: Double, behind: Bool) -> Clip {
        var t = Title(text: "XXXX", font: "Helvetica-Bold", size: 200, color: color)
        t.background = TitleBackground(kind: "box", color: color, padX: 400, padY: 60)
        var c = Clip(id: id, assetID: "", sourceIn: .zero, sourceOut: MediaTime(seconds: 1), start: .zero)
        c.title = t
        c.placement = Placement(fit: .native, x: 0.5, y: y)
        c.behindSubject = behind ? true : nil
        return c
    }
    var titles = Track(id: "t2", kind: .overlay, name: "Titles")
    titles.clips = [title("c2", "#00FF00", y: 0.25, behind: true)]
    var above = Track(id: "t3", kind: .overlay, name: "Titles 2")
    above.clips = [title("c3", "#FFFF00", y: 0.75, behind: false)]
    p.tracks += [titles, above]

    let out = TemporaryFolder.url.appendingPathComponent("regista-behind-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: out) }
    let a = out.appendingPathComponent("a.png")
    try AVRenderer().renderFrames(RenderJob(project: p, preset: .vertical), at: [MediaTime(seconds: 0.5)], to: [a])
    let personTop = try pixel(a, 200, 480), backgroundTop = try pixel(a, 880, 480)
    #expect(personTop.0 > 180 && personTop.1 < 40)          // the person (red) stays in front of the behind-subject title
    #expect(backgroundTop.1 > 200 && backgroundTop.0 < 60)  // the title shows where there is no person
    let personBottom = try pixel(a, 200, 1440)
    #expect(personBottom.0 > 200 && personBottom.1 > 200)   // an ordinary title above is drawn over the person

    // A full-frame insert between the camera and the title has no matte: the title shows everywhere.
    var inserts = Track(id: "t4", kind: .overlay, name: "Inserts")
    let still = out.appendingPathComponent("grey.png")
    try VisionPersonSegmenter.writeGray([UInt8](repeating: 128, count: 54 * 96), width: 54, height: 96, to: still)
    p.assets.append(MediaAsset(id: "a2", name: "grey", path: still.path, duration: ImageSource.stillDuration,
                               video: VideoInfo(width: 54, height: 96, frameRate: Rational(30), codec: "png"), audio: nil,
                               image: ImageSource(kind: .still, path: still.path)))
    inserts.clips = [Clip(id: "c4", assetID: "a2", sourceIn: .zero, sourceOut: MediaTime(seconds: 1), start: .zero)]
    p.tracks.insert(inserts, at: 1)
    #expect(RenderJob.subjects(RenderJob(project: p, preset: .vertical).layers(at: MediaTime(seconds: 0.5))) == [2: nil])
    let b = out.appendingPathComponent("b.png")
    try AVRenderer().renderFrames(RenderJob(project: p, preset: .vertical), at: [MediaTime(seconds: 0.5)], to: [b])
    let over = try pixel(b, 200, 480)
    #expect(over.1 > 200 && over.0 < 60)
}

@Test func captionsPlacedByHandAreDrawnWhereAsked() throws {
    let clip = try syntheticClip()
    defer { try? FileManager.default.removeItem(at: clip) }
    var p = project(clip)
    let words: [(text: String, start: MediaTime, end: MediaTime)] = [("prova", .zero, MediaTime(seconds: 0.4)), ("sito", MediaTime(seconds: 0.5), MediaTime(seconds: 0.9))]
    var caps = Track(id: "t2", kind: .caption, name: "C1")
    var c = Captions(style: .talkingHeadV1, keywords: ["SITO"], fixes: [:], sourceTrack: "t1", sourceSignature: "",
                     chunks: CaptionBuilder.build(words: words, style: .talkingHeadV1, keywords: ["SITO"], fixes: [:]))
    let plain = try AVRenderer().captionLayout({ var j = RenderJob(project: p, preset: .vertical); j.captions = c; return j }())[0]
    // Top-left, left edge at x 60, centred on y 300, 1.5× bigger.
    c.place = CaptionPlace(x: 60, y: 300, scale: 1.5, align: .left)
    caps.captions = c
    p.tracks.append(caps)
    let job = RenderJob(project: p, preset: .vertical)
    let boxes = try AVRenderer().captionLayout(job)[0]
    let line = try #require(FaceFraming.union(boxes)), before = try #require(FaceFraming.union(plain))
    #expect(abs(line[0] - 60) <= 1 && abs(line[1] + line[3] / 2 - 300) <= 2)
    #expect(abs(line[2] / before[2] - 1.5) < 0.03 && abs(line[3] / before[3] - 1.5) < 0.03)
    // The bands and timing templates follow the chunk (scaled band, own origin).
    let band = try AVRenderer().captionBands(job)[0]
    #expect(band[3] == 300 && band[2] == 1620)
    let states = try AVRenderer().captionStates(job, downscale: 2)
    #expect(states[0].width == 810 && states[0].height == 150)
    // Drawn there: pink keyword box at its new place, the old band clean (blue).
    let dir = TemporaryFolder.url.appendingPathComponent("regista-place-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let b = dir.appendingPathComponent("b.png")
    try AVRenderer().renderFrames(job, at: [MediaTime(seconds: 0.6)], to: [b])
    let kw = boxes[1]
    let pink = try pixel(b, Int(kw[0] + 8), Int(kw[1] + 6))
    #expect(abs(pink.0 - 255) < 12 && abs(pink.1 - 45) < 12 && abs(pink.2 - 111) < 12)
    let old = try pixel(b, Int(plain[1][0] + 8), Int(plain[1][1] + 6))
    #expect(old.2 > 180 && old.0 < 40)
}

/// effects.preview renders an item on a throwaway copy: the image comes back, the edit and the history do not change.
@Test func effectsPreviewRendersWithoutTouchingTheEdit() throws {
    let clip = try syntheticClip()
    defer { try? FileManager.default.removeItem(at: clip) }
    let e = Engine(scratch: project(clip), services: .live())
    let before = e.project
    let r = try e.execute("effects.preview", params: ["item": "look-ink", "at": 0.5, "intensity": 1])
    #expect(r["command"] == "look.apply" && r["images"]?.arrayValue?.count == 1)
    let png = try #require(r["path"]?.stringValue)
    let (red, green, blue) = try pixel(URL(fileURLWithPath: png), 540, 960)
    #expect(abs(red - green) < 6 && abs(green - blue) < 6)   // black and white, while the clip is blue
    let sheet = try e.execute("effects.preview", params: ["item": "sticker-fire", "at": 0.1, "frames": 4])
    #expect(sheet["times"]?.arrayValue?.count == 4 && sheet["path"]?.stringValue?.hasSuffix(".jpg") == true)
    #expect(e.project == before && e.context.history.undoStack.isEmpty)
}
