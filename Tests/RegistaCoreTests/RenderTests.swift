import Foundation
import Testing
@testable import RegistaCore

final class FakeRenderer: VideoRenderer {
    var exports: [(job: RenderJob, audio: URL?, output: URL)] = []
    var frames: [MediaTime] = []
    func export(_ job: RenderJob, audio: URL?, to output: URL, bitrate: Int) throws -> ExportReport {
        exports.append((job, audio, output))
        FileManager.default.createFile(atPath: output.path, contents: Data())
        return ExportReport(frames: job.frameCount, seconds: 0)
    }
    func renderFrames(_ job: RenderJob, at times: [MediaTime], to outputs: [URL]) throws {
        frames += times
        for u in outputs { FileManager.default.createFile(atPath: u.path, contents: Data()) }
    }
    func captionLayout(_ job: RenderJob) throws -> [[[Double]]] { [] }
    func captionStates(_ job: RenderJob, downscale: Int) throws -> [CaptionRaster] { [] }
    func writeCaptionImages(_ job: RenderJob, to directory: URL) throws -> [URL] {
        (job.captions?.states ?? []).indices.map { directory.appendingPathComponent("cap\($0).png") }
    }
}

private func renderEngine(_ renderer: FakeRenderer) throws -> (Engine, FakeServices) {
    let fakes = FakeServices()
    var services = fakes.make()
    services.renderer = renderer
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "r", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0.9, "sourceOut": 4.6])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": 0.9, "sourceOut": 4.6, "linkTo": "c1"])
    try e.execute("clip.set", params: ["clipId": "c1", "crop": [864, 1536, 152, 384], "brightness": 0.02])
    try e.execute("clip.set", params: ["clipId": "c2", "fadeIn": 0.015, "fadeOut": 0.015])
    return (e, fakes)
}

@Test func renderJobLayersReframeByCrop() throws {
    let (e, _) = try renderEngine(FakeRenderer())
    let p = e.project!
    let vertical = RenderJob(project: p, preset: .vertical)
    let l = try #require(vertical.layers(at: t(1)).first)
    #expect(l.crop.map { $0.rounded() } == [864, 1536, 152, 384] && l.sourceTime == t(1.9) && l.color?.brightness == 0.02)
    // 1:1 keeps the crop's width and centre; 16:9 shortens it further.
    let square = RenderJob(project: p, preset: .square).layers(at: t(1))[0]
    #expect(square.crop.map { $0.rounded() } == [864, 864, 152, 720])
    let wide = RenderJob(project: p, preset: .landscape).layers(at: t(1))[0]
    #expect(wide.crop.map { $0.rounded() } == [864, 486, 152, 909])
    #expect(vertical.layers(at: t(3.7)).isEmpty && vertical.frameCount == 111)
    #expect(RenderJob.fit([1080, 1920, 0, 0], aspect: 1, within: (1080, 1920)) == [1080, 1080, 0, 420])
}

@Test func audioPlanIsSampleExactWithFades() throws {
    let (e, _) = try renderEngine(FakeRenderer())
    let clips = AudioPlan.clips(e.project!, rate: 48000)
    #expect(clips.count == 1)
    #expect(clips[0].sourceStart == 43200 && clips[0].sourceEnd == 220800 && clips[0].timelineStart == 0)
    #expect(clips[0].fadeIn == 0.015 && clips[0].channels == 2)
    try e.execute("track.set", params: ["trackId": "t2", "muted": true])
    #expect(AudioPlan.clips(e.project!, rate: 48000).isEmpty)
}

@Test func exportAndFrameRenderGoThroughTheRenderer() throws {
    let renderer = FakeRenderer()
    let (e, fakes) = try renderEngine(renderer)
    try e.execute("captions.generate")
    let dir = tempDir()
    let r = try e.execute("export.render", params: ["path": .string(dir.appendingPathComponent("out.mp4").path), "preset": "1:1"])
    #expect(r["frames"] == 111 && r["width"] == 1080 && r["height"] == 1080 && r["captions"] == true && r["audioClips"] == 1)
    #expect(r.value(at: "loudness.integrated") == -15.1)
    #expect(fakes.audio.mixes.last?.ceiling == -2.0 && fakes.audio.mixes.last?.length == 177600)
    #expect(renderer.exports.last?.audio != nil && renderer.exports.last?.job.captions != nil)
    // The mix is temporary.
    #expect(FileManager.default.fileExists(atPath: renderer.exports.last!.audio!.path) == false)
    let f = try e.execute("frame.render", params: ["times": [0.51, 2, 99], "directory": .string(dir.path), "captions": false])
    #expect(renderer.frames == [t(0.5), t(2), t(3.7 - 1.0 / 30)])
    #expect(f.value(at: "frames.0.path")?.stringValue?.hasSuffix("frame-0000.500.png") == true)
    // Stale captions are reported.
    try e.execute("timeline.move", params: ["clipId": "c1", "start": 1])
    let again = try e.execute("frame.render", params: ["time": 1.5, "path": .string(dir.appendingPathComponent("one.png").path)])
    #expect(again["warnings"]?.arrayValue?.count == 1)
    let none = Engine(prober: FakeProber(), services: FakeServices().make())
    try none.execute("project.new", params: ["name": "x"])
    #expect(throws: CommandError.self) { try none.execute("frame.render", params: ["time": 0, "path": "/tmp/x.png"]) }
}

@Test func mltProjectHasClipsFiltersCaptionsAndTransitions() throws {
    let renderer = FakeRenderer()
    let (e, _) = try renderEngine(renderer)
    try e.execute("captions.generate")
    let url = tempDir().appendingPathComponent("p.mlt")
    let r = try e.execute("export.mlt", params: ["path": .string(url.path)])
    #expect(r["captionImages"] == 4 && r["frames"] == 111)
    let xml = try String(contentsOf: url, encoding: .utf8)
    #expect(XMLParser(data: Data(xml.utf8)).parse())
    // The last caption's hold would run past the timeline (3.7 s = 111 frames): the caption playlist is clamped.
    let captionList = try #require(xml.components(separatedBy: "<playlist ").first { $0.contains(">Captions<") })
    let ints = { (pattern: String) -> [Int] in
        let re = try! NSRegularExpression(pattern: pattern)
        return re.matches(in: captionList, range: NSRange(captionList.startIndex..., in: captionList)).map { m in
            (1..<m.numberOfRanges).map { Int((captionList as NSString).substring(with: m.range(at: $0)))! }.reduce(0) { $1 - $0 }
        }
    }
    let blanks = ints(#"blank length="(\d+)""#), entries = ints(#"entry producer="\w+" in="(\d+)" out="(\d+)""#)
    let blankFrames: Int = blanks.reduce(0, +)
    let entryFrames: Int = entries.reduce(0) { $0 + $1 + 1 }
    #expect(blankFrames + entryFrames == 111)
    for needle in ["<property name=\"mlt_service\">crop</property>", "<property name=\"top\">384</property>",
                   "<property name=\"left\">152</property>", "<property name=\"right\">64</property>",
                   "<property name=\"av.brightness\">0.02</property>", "fadeInVolume", "fadeOutVolume",
                   "<entry producer=\"chain0\" in=\"27\" out=\"137\"/>", "qimage", "<property name=\"shotcut:name\">Captions</property>",
                   "<property name=\"mlt_service\">qtblend</property>", "hide=\"video\"", "frame_rate_num=\"30\""] {
        #expect(xml.contains(needle), "missing \(needle)")
    }
}

@Test func probeReadsAtomOrder() throws {
    let url = tempDir().appendingPathComponent("x.mp4")
    func atom(_ name: String, _ body: Int) -> Data {
        var d = Data([0, 0, 0, UInt8(8 + body)]); d.append(Data(name.utf8)); d.append(Data(count: body)); return d
    }
    try (atom("ftyp", 8) + atom("moov", 4) + atom("mdat", 16)).write(to: url)
    #expect(MediaCheck.atoms(url) == ["ftyp", "moov", "mdat"])
}
