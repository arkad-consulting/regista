import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import RegistaCore
@testable import RegistaEngines

// #42: the cover of a reel — the still, its title from the brand kit, the check against both crops, appendCover.

/// An engine on the live compositor with a saved voice-only project (captions at 0–1.2 s) of `seconds`, in a scratch folder.
private func coverEngine(seconds: Double = 2, width: Int = 1080, height: Int = 1920) throws -> (Engine, URL) {
    let dir = TemporaryFolder.url.appendingPathComponent("regista-cover-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let voice = dir.appendingPathComponent("voice.wav")
    try FileManager.default.moveItem(at: try syntheticVoice(seconds: seconds), to: voice)
    let e = Engine(scratch: voiceOnlyProject(voice, seconds: seconds, width: width, height: height), services: .live())
    return (e, dir)
}

private func image(_ url: URL) throws -> CGImage {
    let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    return try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
}

/// Mean absolute difference per channel of two images of the same size, 0…255.
private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
    let x = rgbaBytes(a), y = rgbaBytes(b)
    guard x.count == y.count, !x.isEmpty else { return 255 }
    var sum = 0
    for i in stride(from: 0, to: x.count, by: 4) { sum += abs(Int(x[i]) - Int(y[i])) + abs(Int(x[i + 1]) - Int(y[i + 1])) + abs(Int(x[i + 2]) - Int(y[i + 2])) }
    return Double(sum) / Double(x.count / 4 * 3)
}

@Test func theCoverIsSavedWithTheProjectAndUndone() throws {
    let (e, dir) = try coverEngine()
    defer { try? FileManager.default.removeItem(at: dir) }
    try e.execute("project.save", params: ["path": .string(dir.appendingPathComponent("c.regista").path)])
    #expect(e.project?.cover == nil)
    let r = try e.execute("cover.set", params: ["time": 0.5, "title": "Tre parole qui"])
    #expect(r.value(at: "cover.place") == "center" && r.value(at: "cover.time") == 0.5)
    try e.execute("cover.set", params: ["place": "top"])   // a subset: the rest is kept
    #expect(e.project?.cover == Cover(time: MediaTime(seconds: 0.5), title: "Tre parole qui", place: .top))
    try e.execute("project.save")
    try e.execute("project.open", params: ["path": .string(dir.appendingPathComponent("c.regista").path)])
    #expect(e.project?.cover == Cover(time: MediaTime(seconds: 0.5), title: "Tre parole qui", place: .top), "the cover did not come back from the file")
    try e.execute("cover.set", params: ["title": ""])
    #expect(e.project?.cover?.title == nil)
    try e.execute("history.undo")
    #expect(e.project?.cover?.title == "Tre parole qui", "undo did not bring the title back")
    #expect(try e.execute("project.state").value(at: "cover.title") == "Tre parole qui")
    // A preset needs a kit that has it.
    #expect(throws: CommandError.self) { try e.execute("cover.set", params: ["preset": "hook"]) }
    try e.execute("brandkit.apply", params: ["kit": "cafe-atelier"])
    try e.execute("cover.set", params: ["preset": "kicker"])
    #expect(e.project?.cover?.preset == "kicker")
    #expect(throws: CommandError.self) { try e.execute("cover.set", params: ["preset": "nope"]) }
}

@Test func aCoverIsForAVerticalVideoOnly() throws {
    let (e, dir) = try coverEngine(width: 1920, height: 1080)
    defer { try? FileManager.default.removeItem(at: dir) }
    for (id, params) in [("cover.set", ["time": 0.5] as JSONValue), ("cover.make", ["output": .string(dir.appendingPathComponent("x.png").path)]), ("cover.check", [:])] {
        do {
            try e.execute(id, params: params)
            Issue.record("\(id) answered on a 16:9 project")
        } catch let error as CommandError {
            #expect(error.message.contains("covers are for vertical videos (9:16"), "\(id): \(error.message)")
        }
    }
}

@Test func theCoverIsThePictureWithoutCaptionsAtTheProjectsSize() throws {
    let (e, dir) = try coverEngine()
    defer { try? FileManager.default.removeItem(at: dir) }
    try e.execute("cover.set", params: ["time": 0.3])   // a caption is on screen at 0.3 s
    let out = dir.appendingPathComponent("cover.png")
    let r = try e.execute("cover.make", params: ["output": .string(out.path), "inline": false])
    #expect(r["path"]?.stringValue == out.path && r.value(at: "check.pass") == true)
    let cover = try image(out)
    #expect(cover.width == 1080 && cover.height == 1920)
    let withCaptions = dir.appendingPathComponent("frame.png"), without = dir.appendingPathComponent("frame-nocap.png")
    try e.execute("frame.render", params: ["time": 0.3, "path": .string(withCaptions.path), "inline": false])
    try e.execute("frame.render", params: ["time": 0.3, "path": .string(without.path), "captions": false, "inline": false])
    #expect(brightPixels(try image(withCaptions)) > 500, "the frame has no caption to leave out")
    #expect(brightPixels(cover) == 0, "the cover drew the caption")
    #expect(meanDifference(cover, try image(without)) < 0.5, "the cover is not the frame without captions")
}

@Test func theChecksTitleInsideTooHighAndTooWide() throws {
    let (e, dir) = try coverEngine()
    defer { try? FileManager.default.removeItem(at: dir) }
    let band = Cover.band(width: 1080, height: 1920)
    #expect([band.x0, band.y0, band.x1, band.y1] == [60, 240, 1020, 1680], "the band of a 1080×1920 cover: \(band)")

    try e.execute("cover.set", params: ["time": 0.5, "title": "Tre parole qui", "place": "center"])
    let inside = try e.execute("cover.check")
    #expect(inside.value(at: "check.pass") == true, "\(inside)")
    let box = (inside.value(at: "check.box")?.arrayValue ?? []).compactMap { $0.doubleValue }
    #expect(box.count == 4 && box[1] > 800 && box[1] + box[3] < 1120 && box[2] > 200, "a short centred title's box: \(box)")

    // Five lines at the top: higher than the grid's crop keeps; the centre fits.
    try e.execute("cover.set", params: ["title": "uno\\ndue\\ntre\\nquattro\\ncinque", "place": "top"])
    let high = try e.execute("cover.make", params: ["output": .string(dir.appendingPathComponent("high.png").path), "inline": false])
    #expect(high.value(at: "check.pass") == false)
    let over = try #require(high.value(at: "check.overflows")?.arrayValue?.first)
    #expect(over["side"] == "top" && (over["pixels"]?.doubleValue ?? 0) >= 20, "\(over)")
    #expect(high.value(at: "check.fix.place") == "center")
    let sentence = high.value(at: "check.sentence")?.stringValue ?? ""
    #expect(sentence.contains("\(Int(over["pixels"]?.doubleValue ?? 0)) px at the top") && sentence.contains("cover.set {place: \"center\"}"), "\(sentence)")
    try e.execute("cover.set", params: ["place": "center"])
    #expect(try e.execute("cover.check").value(at: "check.pass") == true, "the place the check named does not fit")

    // One word wider than the frame: both sides, and the fix is a shorter title (no place makes it fit).
    try e.execute("cover.set", params: ["title": "ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGH"])
    let wide = try e.execute("cover.check")
    let sides = Set((wide.value(at: "check.overflows")?.arrayValue ?? []).compactMap { $0["side"]?.stringValue })
    #expect(wide.value(at: "check.pass") == false && sides == ["left", "right"], "\(wide)")
    #expect(wide.value(at: "check.fix.title") == "shorter" && wide.value(at: "check.fix.place") == nil)
}

@Test func appendCoverAddsThreeFramesOfTheCoverAndTheRulesReadTheSame() throws {
    let (e, dir) = try coverEngine(seconds: 2)
    defer { try? FileManager.default.removeItem(at: dir) }
    try e.execute("cover.set", params: ["time": 1.5, "title": "Tre parole qui"])
    let png = dir.appendingPathComponent("cover.png")
    try e.execute("cover.make", params: ["output": .string(png.path), "inline": false])
    let plain = dir.appendingPathComponent("plain.mp4"), covered = dir.appendingPathComponent("covered.mp4")
    let a = try e.execute("export.render", params: ["path": .string(plain.path), "exportAnyway": true])
    let b = try e.execute("export.render", params: ["path": .string(covered.path), "exportAnyway": true, "appendCover": true])
    #expect(a["frames"] == 60 && b["frames"] == 63, "frames: \(a["frames"] ?? .null) and \(b["frames"] ?? .null)")
    #expect(a["rules"] == b["rules"], "the rules read differently with the cover appended")
    #expect(e.project?.duration == MediaTime(seconds: 2), "the project changed")
    // The last three frames are the cover, the one before is the edit.
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: covered))
    gen.requestedTimeToleranceBefore = .zero
    gen.requestedTimeToleranceAfter = .zero
    let cover = try image(png)
    for f in [60, 61, 62] {
        let frame = try gen.copyCGImage(at: CMTime(value: CMTimeValue(f), timescale: 30), actualTime: nil)
        #expect(meanDifference(frame, cover) < 3, "frame \(f) is not the cover (\(meanDifference(frame, cover)))")
    }
    let before = try gen.copyCGImage(at: CMTime(value: 59, timescale: 30), actualTime: nil)
    #expect(meanDifference(before, cover) > 1, "frame 59 is already the cover")
    // Silent: the sound ends with the edit.
    let duration = VisionFaceTracker.load({ try await AVURLAsset(url: covered).load(.duration) })?.seconds ?? 0
    #expect(abs(duration - 2.1) < 0.04, "the file lasts \(duration) s")
    // Without a cover, appendCover says what to do.
    try e.execute("history.undo")
    #expect(throws: CommandError.self) { try e.execute("export.render", params: ["path": .string(plain.path), "exportAnyway": true, "appendCover": true]) }
}
