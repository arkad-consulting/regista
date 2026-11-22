import CoreImage
import Foundation
import Testing
@testable import RegistaCore
@testable import RegistaEngines

// Motion templates and 2.5D through the real compositor (issue #22).

/// Pixels (of a 54×96 thumbnail) that differ from `base` by more than 24 levels on any channel.
func changed(_ a: URL, from base: URL) throws -> Int {
    let k = CGImageToolkit()
    let x = try k.rgba(of: a, width: 54, height: 96), y = try k.rgba(of: base, width: 54, height: 96)
    return stride(from: 0, to: x.count, by: 4).filter { i in (0..<3).contains { abs(Int(x[i + $0]) - Int(y[i + $0])) > 24 } }.count
}

/// The synthetic clip with a matte where every pixel (or none) is "the person".
func mattedProject(_ clip: URL, person: Bool, in dir: URL) throws -> Project {
    var p = project(clip)
    p.tracks[0].clips[0].transform = nil
    let mdir = dir.appendingPathComponent(person ? "full" : "none")
    try FileManager.default.createDirectory(at: mdir, withIntermediateDirectories: true)
    for i in 0..<30 {
        try VisionPersonSegmenter.writeGray([UInt8](repeating: person ? 255 : 0, count: 54 * 96), width: 54, height: 96,
                                            to: mdir.appendingPathComponent(String(format: "%06d.png", i)))
    }
    p.assets[0].analysis = AssetAnalysis()
    p.assets[0].analysis?.matte = MatteTrack(directory: mdir.path, width: 54, height: 96, frameRate: 30, ranges: [[0, 29]], engine: "test")
    return p
}

func tempFolder() throws -> URL {
    let d = TemporaryFolder.url.appendingPathComponent("regista-motion-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func templatesAreRegisteredWithGuidanceAndForms() throws {
    MotionLibrary.registerAll()
    let ids = MotionLibrary.templates.map { $0.spec.id }
    #expect(Set(ids).count == ids.count)
    for t in MotionLibrary.templates {
        let s = t.spec
        #expect(s.guide.isComplete && s.guide.description.count > 60, "\(s.id): guidance")
        #expect((1...5).contains(s.form.count) && s.form.allSatisfy { s.field($0) != nil }, "\(s.id): form fields")
        #expect(s.fields.allSatisfy { $0.example != .null && !$0.description.isEmpty }, "\(s.id): field examples")
        #expect(EffectsCatalog.named(s.id)?.category == .templates)
    }
}

@Test func orbitCarouselDrawsItsBackHalfBehindThePerson() throws {
    let clip = try syntheticClip()
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: clip); try? FileManager.default.removeItem(at: dir) }
    var renders: [Bool: URL] = [:]
    let base = dir.appendingPathComponent("base.png")
    try AVRenderer().renderFrames(RenderJob(project: try mattedProject(clip, person: false, in: dir), preset: .vertical), at: [MediaTime(seconds: 0.8)], to: [base])
    for person in [false, true] {
        let e = Engine(scratch: try mattedProject(clip, person: person, in: dir), services: .live())
        let r = try e.execute("motion.add", params: ["template": "orbit-carousel", "start": 0, "duration": 1])
        #expect(r["warnings"]?.arrayValue?.isEmpty == true)
        let layers = RenderJob(project: e.project!, preset: .vertical).layers(at: MediaTime(seconds: 0.8))
        #expect(layers.count == 3 && layers[1].behindSubject && !layers[2].behindSubject)
        let out = dir.appendingPathComponent("p\(person).png")
        try AVRenderer().renderFrames(RenderJob(project: e.project!, preset: .vertical), at: [MediaTime(seconds: 0.8)], to: [out])
        renders[person] = out
    }
    let all = try changed(renders[false]!, from: base), frontOnly = try changed(renders[true]!, from: base)
    #expect(frontOnly > 20 && all > frontOnly + 20, "all cards \(all) px, front only \(frontOnly) px")
}

@Test func spatialTransformsGoThroughTheCompositor() throws {
    let clip = try syntheticClip()
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: clip); try? FileManager.default.removeItem(at: dir) }
    let e = Engine(scratch: project(clip), services: .live())
    let r = try e.execute("title.add", params: ["text": "TILT", "start": 0, "duration": 1, "size": 160, "background": "box", "backgroundColor": "#FFFFFF",
                                                "animIn": "none", "animOut": "none", "band": "middle"])
    let cid = try #require(r.value(at: "clip.id")?.stringValue)
    let flat = dir.appendingPathComponent("flat.png"), tilted = dir.appendingPathComponent("tilted.png")
    try AVRenderer().renderFrames(RenderJob(project: e.project!, preset: .vertical, captions: false), at: [MediaTime(seconds: 0.5)], to: [flat])
    let flatBox = try #require(Graphics.restBox(e.project!.tracks.last!.clips[0], track: e.project!.tracks.last!, project: e.project!, renderer: AVRenderer()))
    try e.execute("clip.set", params: ["clipId": .string(cid), "rotationY": 55, "perspective": 900])
    try AVRenderer().renderFrames(RenderJob(project: e.project!, preset: .vertical, captions: false), at: [MediaTime(seconds: 0.5)], to: [tilted])
    let box = try #require(Graphics.restBox(e.project!.tracks.last!.clips[0], track: e.project!.tracks.last!, project: e.project!, renderer: AVRenderer()))
    #expect(box[2] < flatBox[2] * 0.75)                      // turned away: narrower on screen
    #expect(try changed(tilted, from: flat) > 30)
    // The far (right) edge is shorter: the white box covers less height at its right end than at its left end.
    func whiteRun(_ x: Int) throws -> Int { try (700...1220).filter { y in try pixel(tilted, x, y).0 > 230 && pixel(tilted, x, y).1 > 230 }.count }
    let left = Int(box[0] + 12), right = Int(box[0] + box[2] - 12)
    #expect(try whiteRun(left) > whiteRun(right))
}

/// The motion-gallery scenario applies every registered template (a new template must be added there).
@Test func motionGalleryScenarioCoversEveryTemplate() throws {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Scenarios/motion-gallery.json")
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
    let used = Set((json["steps"]?.arrayValue ?? []).filter { $0["command"] == "motion.add" }.compactMap { $0.value(at: "params.template")?.stringValue })
    for t in MotionLibrary.templates { #expect(used.contains(t.spec.id), "motion-gallery.json does not add \(t.spec.id)") }
}

@Test func counterWritesThousandsLikeTheCaptions() {
    #expect(Counter.format(11000, clock: false, decimals: 0) == "11,000")
    #expect(Counter.format(11000, clock: false, decimals: 0, separator: ".") == "11.000")
    #expect(Counter.format(9.2, clock: false, decimals: 1, separator: ".") == "9,2")
}

/// The quote card (the proof beat "a quote" of the presenter rhythm): a paper card in the top band, ink in dark theme,
/// nothing in the caption band; long quotes wrap into lines no wider than the card.
@Test func quoteCardDrawsAPaperCardInTheTopBand() throws {
    let clip = try syntheticClip()
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(at: clip); try? FileManager.default.removeItem(at: dir) }
    var seen: [String: (Int, Int, Int)] = [:]
    for theme in ["light", "dark"] {
        let e = Engine(scratch: project(clip), services: .live())
        let r = try e.execute("motion.add", params: ["template": "quote-card", "start": 0, "duration": 1,
                                                    "fields": ["quote": "We cut the editing time of every reel in half.", "theme": .string(theme)]])
        #expect(r["warnings"]?.arrayValue?.isEmpty == true && r["template"] == "quote-card")
        let out = dir.appendingPathComponent("\(theme).png")
        try AVRenderer().renderFrames(RenderJob(project: e.project!, preset: .vertical, captions: false), at: [MediaTime(seconds: 0.6)], to: [out])
        seen[theme] = try pixel(out, 540, 235)   // the card's top margin, above the words
        let band = try pixel(out, 540, 1340)
        #expect(band.2 > 180 && band.0 < 60, "\(theme): the caption band is not the clip's blue: \(band)")
    }
    let paper = try #require(seen["light"]), ink = try #require(seen["dark"])
    #expect(paper.0 > 220 && paper.1 > 215 && paper.2 > 200, "the light card is not paper: \(paper)")
    #expect(ink.0 < 50 && ink.1 < 50 && ink.2 < 50, "the dark card is not ink: \(ink)")
    let lines = QuoteCard.wrap("one two three four five six seven eight nine ten", width: 14) { Double($0.count) }
    #expect(lines == ["one two three", "four five six", "seven eight", "nine ten"])
    #expect(lines.allSatisfy { $0.count <= 14 })
}

/// The talking-head recipe's presenter rhythm (#144) names only templates of the catalog, every beat has one, and a beat
/// uses a template for what it draws: a screen proof can show the user's picture, what repeats per point may repeat.
@Test func presenterRhythmNamesOnlyCatalogTemplates() throws {
    MotionLibrary.registerAll()
    let specs = Dictionary(uniqueKeysWithValues: MotionRegistry.all.map { ($0.id, $0) })
    let text = Recipes.talkingHeadReel.text()
    let start = try #require(text.range(of: "15. Presenter rhythm"), "the talking-head recipe has no presenter rhythm step")
    let end = try #require(text.range(of: "## Moving captions", range: start.upperBound..<text.endIndex))
    let step = String(text[start.lowerBound..<end.lowerBound])
    func words(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.lowercaseLetters.union(CharacterSet(charactersIn: "-_")).inverted).filter { !$0.isEmpty }
    }
    let notTemplates: Set<String> = Set(Recipes.all.map(\.name))
    let hyphenated = Set(words(step).filter { $0.contains("-") && !$0.hasPrefix("-") && !$0.hasSuffix("-") }).subtracting(notTemplates)
    #expect(!hyphenated.isEmpty && hyphenated.isSubset(of: specs.keys), "not in the catalog: \(hyphenated.subtracting(specs.keys).sorted())")

    // The beats, each with its continuation lines.
    var beats: [(name: String, templates: Set<String>)] = []
    for line in step.components(separatedBy: "\n").drop(while: { !$0.contains("What serves each beat") }).dropFirst() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Real material only") { break }
        let ids = Set(words(t)).intersection(specs.keys)
        if t.hasPrefix("- "), let colon = t.firstIndex(of: ":") {
            beats.append((String(t[..<colon].dropFirst(2)), ids))
        } else if !beats.isEmpty {
            beats[beats.count - 1].templates.formUnion(ids)
        }
    }
    #expect(beats.count == 6, "\(beats.map(\.name))")
    for b in beats { #expect(!b.templates.isEmpty, "the beat «\(b.name)» names no template") }
    let screen = try #require(beats.first { $0.name == "proof, a screen" }?.templates)
    for id in screen {
        let s = try #require(specs[id])
        #expect(s.consumesBelow || s.fields.contains { $0.type == "image" || $0.type == "images" }, "\(id) cannot show the user's own screen")
    }
}
