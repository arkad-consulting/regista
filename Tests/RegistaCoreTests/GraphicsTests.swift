import Foundation
import Testing
@testable import RegistaCore

// Graphics layer (issue #5, X1): easing and keyframes, presets, effects, transitions, ducking, titles in bands,
// brand kits, overlays, sound effects, reference time mapping.

@Test func easingCurvesStartAtZeroEndAtOneAndHaveTheirShape() {
    for e in Easing.allCases {
        #expect(abs(e.apply(0)) < 1e-9, "\(e) at 0")
        #expect(abs(e.apply(1) - 1) < 1e-9, "\(e) at 1")
    }
    #expect(Easing.easeIn.apply(0.5) < 0.5)
    #expect(Easing.easeOut.apply(0.5) > 0.5)
    #expect(abs(Easing.easeInOut.apply(0.5) - 0.5) < 1e-9)
    #expect(Easing.expoOut.apply(0.3) > 0.85)
    #expect(Easing.hold.apply(0.99) == 0)
    // backOut overshoots past the target before settling.
    let peak = stride(from: 0.0, through: 1.0, by: 0.01).map { Easing.backOut.apply($0) }.max()!
    #expect(peak > 1.05 && peak < 1.15)
    #expect(Easing.linear.apply(1.7) == 1 && Easing.linear.apply(-1) == 0)
}

@Test func keyframesInterpolateWithTheEasingOfTheKeyframeTheyLeave() {
    var a = Transform(), b = Transform()
    b.scale = 2; b.opacity = 0
    var clip = Clip(id: "c1", assetID: "a1", sourceIn: .zero, sourceOut: t(4), start: t(10))
    clip.keyframes = [Keyframe(time: t(0), transform: a, easing: .easeIn), Keyframe(time: t(1), transform: b)]
    #expect(abs(clip.transform(at: t(0.5)).scale - 1.125) < 1e-9)   // 1 + easeIn(0.5) = 1 + 0.125
    #expect(abs(clip.transform(at: t(0.5)).opacity - 0.875) < 1e-9)
    #expect(clip.transform(at: t(3)).scale == 2)                      // held after the last keyframe
    clip.keyframes![0].easing = nil
    #expect(abs(clip.transform(at: t(0.25)).scale - 1.25) < 1e-9)    // linear by default
    a.x = 0.1
    clip.keyframes = [Keyframe(time: t(0), transform: a, easing: .hold), Keyframe(time: t(1), transform: b)]
    #expect(clip.transform(at: t(0.9)).x == 0.1)                      // hold: jumps at the next keyframe
    #expect(clip.transform(at: t(1)).x == 0)
}

@Test func presetsWriteEntranceAndExitKeyframesAroundTheRestState() throws {
    var rest = Transform()
    rest.y = -0.2
    let d = t(3)
    let pop = try #require(AnimationPreset.combined(in: .pop, out: .fade, rest: rest, duration: d, inDuration: nil, outDuration: nil))
    #expect(pop.first?.time == .zero && pop.first?.transform.opacity == 0 && pop.first?.transform.scale == 0.6)
    #expect(pop.first?.easing == .backOut)
    #expect(pop.contains { abs($0.time.seconds - 0.35) < 1e-9 && $0.transform == rest })
    #expect(pop.last?.time == d && pop.last?.transform.opacity == 0 && pop.last?.transform.scale == 1)
    #expect(zip(pop, pop.dropFirst()).allSatisfy { $0.time < $1.time })
    var clip = Clip(id: "c", assetID: "", sourceIn: .zero, sourceOut: d, start: .zero)
    clip.keyframes = pop
    #expect(clip.transform(at: t(1.5)) == rest)
    #expect(clip.transform(at: t(2.98)).opacity < 0.5)
    // Overshoot of the pop: bigger than the rest state shortly after the start.
    #expect(stride(from: 0.05, to: 0.35, by: 1.0 / 30).map { clip.transform(at: t($0)).scale }.max()! > 1.02)

    let slide = try #require(AnimationPreset.slideUp.keyframes(rest: rest, duration: d))
    #expect(abs(slide.first!.transform.y - (rest.y + 0.04)) < 1e-9)
    #expect(AnimationPreset.none.keyframes(rest: rest, duration: d) == nil)
    let ken = try #require(AnimationPreset.combined(in: .kenBurns, out: nil, rest: rest, duration: d, inDuration: nil, outDuration: nil))
    #expect(ken.count == 2 && abs(ken.last!.transform.scale - 1.08) < 1e-9)
    // Very short clip: in + out never overlap.
    let short = try #require(AnimationPreset.pop.keyframes(rest: rest, duration: t(0.4)))
    #expect(zip(short, short.dropFirst()).allSatisfy { $0.time <= $1.time } && short.last!.time == t(0.4))
}

@Test func effectStrengthFollowsItsWindowRampsAndKeyframes() {
    var e = Effect(id: "fx1", kind: .punchZoom, amount: 1)
    e.start = t(1); e.end = t(2); e.attack = 0.1; e.release = 0.2; e.easing = .linear
    let d = t(5)
    #expect(e.strength(at: t(0.99), clipDuration: d) == 0)
    #expect(abs(e.strength(at: t(1.05), clipDuration: d) - 0.5) < 1e-6)
    #expect(e.strength(at: t(1.5), clipDuration: d) == 1)
    #expect(abs(e.strength(at: t(1.9), clipDuration: d) - 0.5) < 1e-6)
    #expect(e.strength(at: t(2), clipDuration: d) == 0)
    e.keyframes = [ScalarKey(time: t(0), value: 0), ScalarKey(time: t(1), value: 0.8)]
    #expect(abs(e.strength(at: t(0.5), clipDuration: d) - 0.4) < 1e-9)
}

@Test func punchZoomShakeAndTransitionsReachTheRenderPlan() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 4])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 10, "sourceOut": 14])
    try e.checkUndoRedo("effect.add", ["kind": "punchZoom", "clipId": "c1", "start": 1, "end": 2, "zoom": 1.2])
    try e.execute("effect.add", params: ["kind": "blur", "clipId": "c2", "radius": 10, "amount": 0.5])
    try e.checkUndoRedo("transition.add", ["kind": "flash", "clipId": "c2"])
    try e.execute("transition.add", params: ["kind": "whip", "at": 2, "direction": "left"])
    let job = RenderJob(project: e.project!, preset: .vertical)
    #expect(abs(job.layers(at: t(1.5))[0].scale - 1.2) < 1e-6)
    #expect(job.layers(at: t(0.5))[0].scale == 1)
    let blur = try #require(job.layers(at: t(5)).first?.effects.first)
    #expect(blur.kind == .blur && blur.strength == 0.5 && blur.radius == 10)
    #expect(abs(job.frameFX(at: t(4)).flash - 0.9) < 1e-6)        // the cut c1 → c2
    #expect(job.frameFX(at: t(4.2)).flash == 0)
    let before = job.frameFX(at: MediaTime(seconds: 1.9)), after = job.frameFX(at: MediaTime(seconds: 2.1))
    #expect(before.shiftX < 0 && after.shiftX > 0 && before.blur > 0)
    #expect(job.frameFX(at: t(3)).isIdentity)
    // The flash follows its clip when the cut moves.
    try e.execute("timeline.move", params: ["clipId": "c2", "start": 6])
    #expect(RenderJob(project: e.project!, preset: .vertical).frameFX(at: t(6)).flash > 0.8)
    try e.execute("effect.remove", params: ["clipId": "c1"])
    #expect(e.project!.tracks[0].clips[0].effects == nil)
}

@Test func duckingEnvelopeIsDownDuringSpeechAndRampsSmoothly() {
    let regions = DuckingEnvelope.merge([(1.0, 1.4), (1.5, 2.0), (3.5, 4.0)], gap: 0.3)
    #expect(regions.count == 2 && regions[0] == (1.0, 2.0) && regions[1] == (3.5, 4.0))
    let d = Ducking(sourceTrack: "t2", depth: -12, attack: 0.2, release: 0.4)
    #expect(DuckingEnvelope.gain(at: 0.5, regions: regions, ducking: d) == 0)
    #expect(DuckingEnvelope.gain(at: 1.5, regions: regions, ducking: d) == -12)
    #expect(DuckingEnvelope.gain(at: 1.0, regions: regions, ducking: d) == -12)     // fully down when the word starts
    let mid = DuckingEnvelope.gain(at: 0.9, regions: regions, ducking: d)            // halfway through the attack
    #expect(abs(mid + 6) < 1e-9)
    #expect(abs(DuckingEnvelope.gain(at: 2.2, regions: regions, ducking: d) + 6) < 1e-9)
    #expect(DuckingEnvelope.gain(at: 2.5, regions: regions, ducking: d) == 0)
    // Samples: same curve as linear gain, monotonic in the ramps.
    let rate = 1000
    let s = DuckingEnvelope.samples(regions: regions, ducking: d, rate: rate, length: 5000)
    #expect(s.count == 5000 && s[500] == 1)
    #expect(abs(Double(s[1500]) - pow(10, -12.0 / 20)) < 1e-6)
    #expect(abs(Double(s[2200]) - pow(10, -6.0 / 20)) < 1e-4)
    #expect((800..<1000).allSatisfy { s[$0 + 1] <= s[$0] })
    #expect((2000..<2399).allSatisfy { s[$0 + 1] >= s[$0] })
}

@Test func musicBedIsLevelledLoopedAndDuckedUnderTheVoiceWords() throws {
    let fakes = FakeServices()
    let e = try analysisEngine(fakes)
    try e.execute("media.extractAudio", params: ["assetId": "a1"])
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 6])
    let music = fakeMedia("bed.wav")
    fakes.audio.measured = Loudness(integrated: -14, truePeak: -1, range: 4, threshold: -24)
    let r = try e.checkUndoRedo("audio.addMusic", ["path": .string(music), "start": 0, "end": 5])
    #expect(r["gain"] == -8)          // -22 target - (-14) measured
    #expect(r["underSpeechLUFS"] == -34)
    #expect(r["speechRegions"] == 2)  // uno-due (merged) and tre-quattro
    let track = try #require(e.project!.tracks.first { $0.role == "music" })
    #expect(track.ducking?.sourceTrack == "t1" && track.ducking?.depth == -12)
    #expect(track.clips.count == 1 && track.clips[0].fadeIn == t(0.5) && track.clips[0].gain == -8)
    let clips = AudioPlan.clips(e.project!, rate: 48000, envelopes: [track.id: URL(fileURLWithPath: "/tmp/env.wav")])
    #expect(clips.first { $0.gain == -8 }?.envelope?.path == "/tmp/env.wav")
    // Envelope files are written for ducked tracks only.
    let dir = tempDir()
    let env = try AudioPlan.writeEnvelopes(e.project!, rate: 1000, to: dir)
    #expect(env.count == 1)
    let w = try WAVAudio.read(env[track.id]!)
    #expect(w.samples.count == 6000 && abs(Double(w.samples[1200]) - pow(10, -0.6)) < 1e-4 && w.samples[2700] == 1)
}

@Test func soundEffectsGoOnSFXTracksAndOverlapsOpenANewOne() throws {
    let e = try editingEngine()
    let lib = tempDir()
    for n in ["pop", "whoosh"] { _ = fakeMedia("\(n).wav", in: lib) }
    try JSONValue.object(["pop": ["file": "pop.wav", "duration": 0.7, "description": "pop"], "whoosh": ["file": "whoosh.wav"]]).data()
        .write(to: lib.appendingPathComponent("manifest.json"))
    var services = e.context.services
    services.config.sfxLibrary = lib.path
    let engine = Engine(prober: FakeProber(), services: services)
    try engine.execute("project.new", params: ["name": "sfx"])
    let listed = try engine.execute("sfx.library")
    #expect(listed["effects"]?.arrayValue?.filter { $0["source"] == "user" }.count == 2)   // next to the shipped bank
    #expect(try engine.execute("sfx.library", params: ["group": "user"])["effects"]?.arrayValue?.count == 2)
    try engine.checkUndoRedo("sfx.add", ["name": "pop", "at": 1.234, "volume": 0.25, "duration": 0.5])
    try engine.execute("sfx.add", params: ["name": "whoosh", "at": 1.5, "duration": 0.5])   // overlaps the pop
    try engine.execute("sfx.add", params: ["name": "pop", "at": 3, "duration": 0.5])
    let sfx = engine.project!.tracks.filter { $0.role == "sfx" }
    #expect(sfx.count == 2 && sfx[0].clips.count == 2 && sfx[1].clips.count == 1)
    #expect(sfx[0].clips[0].start == t(1.234))                                            // not snapped to frames
    #expect(abs(sfx[0].clips[0].gain! - 20 * log10(0.25)) < 1e-9)
    #expect(throws: CommandError.self) { try engine.execute("sfx.add", params: ["name": "nope", "at": 1]) }
}

@Test func titlesSitInTheTopBandAndTheLayoutCheckGuardsTheCaptionBand() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 10])
    #expect(throws: CommandError.self) { try e.execute("title.add", params: ["text": "X", "start": 0, "preset": "hook"]) }   // no kit yet
    try e.execute("brandkit.apply", params: ["kit": "wesites"])
    let r = try e.checkUndoRedo("title.add", ["text": "AGGIORNATO", "preset": "hook", "start": 0.5, "duration": 3])
    let clip = e.project!.tracks.last!.clips[0]
    #expect(e.project!.tracks.last!.role == "titles" && clip.assetID.isEmpty)
    #expect(clip.title?.font.hasSuffix("young-serif-latin-400-normal.woff2") == true)   // role resolved to the kit's file
    #expect(clip.title?.background?.color == "#002FA7" && clip.title?.color == "#F7F4EC")
    #expect(abs(clip.placement!.y - 375.0 / 1920) < 1e-9)                               // top band centre
    let boxValues = r["box"]?.arrayValue?.compactMap(\.doubleValue)
    let box = try #require(boxValues)
    #expect(box[1] >= 110 && box[1] + box[3] <= 640)
    #expect(r["warnings"]?.arrayValue?.isEmpty == true)
    #expect(try e.execute("graphics.checkLayout")["pass"] == true)

    // A title pushed into the caption band is flagged both when added and by the frame-by-frame check.
    let bad = try e.execute("title.add", params: ["text": "TROPPO IN BASSO", "start": 5, "duration": 2, "position": [540, 1300]])
    #expect(bad["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("caption band") == true } == true)
    let check = try e.execute("graphics.checkLayout")
    #expect(check["pass"] == false)
    #expect(check["violations"]?.arrayValue?.first?["clipId"]?.stringValue == e.project!.tracks.last!.clips[1].id)
    // Pop overshoot is part of the checked extent: the extent is wider than the resting box.
    let extent = check["clips"]?.arrayValue?.first { $0["clipId"]?.stringValue == clip.id }?["extent"]?.arrayValue?.compactMap(\.doubleValue)
    let first = try #require(extent)
    #expect(first[2] - first[0] > box[2])
    // Titles can be trimmed although they have no media.
    try e.execute("timeline.trim", params: ["clipId": .string(clip.id), "edge": "end", "to": 4.5])
    #expect(e.project!.tracks.last!.clips[0].end == t(4.5))
}

@Test func brandKitsLoadResolveRolesAndUserKitsOverrideBuiltIns() throws {
    let kits = BrandKit.all(userDirectory: tempDir())
    #expect(Set(kits.keys) == ["wesites", "arkad", "cafe-atelier"])
    let w = try #require(kits["wesites"])
    #expect(w.colors["primary"] == "#002FA7" && w.captionPreset == "talking-head-v1")
    #expect(Set(["hook", "kicker", "card", "question", "stat"]).isSubset(of: Set(w.titles.keys)))
    let hook = w.resolve(w.titles["hook"]!)
    #expect(hook.color == "#F7F4EC" && hook.background?.color == "#002FA7" && (hook.font.contains("young-serif") || hook.font == "Georgia"))
    #expect(w.resolve(Title(text: "x", font: "Impact", size: 10, color: "#123456")).font == "Impact")   // literals pass through
    // A user kit with the same id replaces the built-in; JSON round trip of the whole kit.
    let dir = tempDir()
    var custom = BrandKit.arkad
    custom.id = "wesites"; custom.name = "Custom"
    try JSONEncoder().encode(custom).write(to: dir.appendingPathComponent("mine.json"))
    #expect(BrandKit.all(userDirectory: dir)["wesites"]?.name == "Custom")
    #expect(try BrandKit.load(dir.appendingPathComponent("mine.json").path) == custom)
    let e = try editingEngine()
    #expect(throws: CommandError.self) { try e.execute("brandkit.apply", params: ["kit": "nope"]) }
    try e.checkUndoRedo("brandkit.apply", ["kit": "arkad"])
    #expect(e.project!.brand?.id == "arkad")
}

@Test func overlaysImportStillsAndSequencesAndPlaceThemWithPresets() throws {
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 10])
    let png = fakeMedia("logo.png")
    let r = try e.checkUndoRedo("overlay.add", ["path": .string(png), "start": 1, "band": "top", "animIn": "pop", "blend": "screen"])
    let asset = try #require(e.project!.assets.first { $0.path.hasSuffix("logo.png") })
    #expect(asset.image?.kind == .still && r["clip"]?["duration"] == 3)
    let clip = e.project!.tracks.last!.clips[0]
    #expect(clip.placement?.fit == .native && clip.blend == .screen && clip.keyframes?.first?.transform.scale == 0.6)
    #expect(e.project!.tracks.last!.role == "overlays")
    // Sequence folder: numbered frames become a printf pattern.
    let dir = tempDir()
    for i in 1...3 { _ = fakeMedia(String(format: "frame_%04d.png", i), in: dir) }
    let seq = try Graphics.sequence(dir.path, command: "test")
    #expect(seq.path.hasSuffix("frame_%04d.png") && seq.first == 1 && seq.count == 3)
    #expect(seq.file(at: t(0.05)).hasSuffix("frame_0002.png"))
    #expect(seq.file(at: t(10)).hasSuffix("frame_0003.png"))                    // held on the last frame
    try e.execute("overlay.add", params: ["path": .string(dir.path), "start": 2, "top": 110])
    let seqClip = e.project!.tracks.flatMap(\.clips).last!
    #expect(seqClip.duration == t(0.1))
    // Full-frame insert: fill, own track under the titles.
    try e.execute("brandkit.apply", params: ["kit": "wesites"])
    try e.execute("title.add", params: ["text": "Ciao", "start": 0])
    try e.execute("overlay.add", params: ["path": .string(fakeMedia("insert.mp4")), "start": 4, "duration": 1, "fullFrame": true])
    let insertTrack = try #require(e.project!.tracks.firstIndex { $0.clips.contains { $0.start == t(4) && $0.placement == nil && $0.assetID != "a1" } })
    #expect(insertTrack < e.project!.tracks.firstIndex { $0.role == "titles" }!)
    let layers = RenderJob(project: e.project!, preset: .vertical).layers(at: t(4.5))
    #expect(layers.last.map { if case .title = $0.source { true } else { false } } != true)   // the title ended at 2.5 s
}

@Test func referenceTimesMapThroughTheSourceFrames() throws {
    let e = try editingEngine()
    // Timeline: source 2–4 s at 0, source 6–8 s at 2. Reference: source 1–5 s then 6–9 s.
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 2, "sourceOut": 4])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 6, "sourceOut": 8])
    let seg = tempDir().appendingPathComponent("segments.json")
    try JSONValue.object(["segments": [["in": 1, "out": 5], ["in": 6, "out": 9]]]).data().write(to: seg)
    let r = try e.execute("timeline.mapTimes", params: ["referenceSegments": .string(seg.path), "times": [1.5, 4.5, 0.2, 5.0]])
    let times = r["times"]!.arrayValue!.compactMap(\.doubleValue)
    #expect(abs(times[0] - 0.5) < 1e-6)            // ref 1.5 = source 2.5 = timeline 0.5
    #expect(abs(times[1] - 2.5) < 1e-6)            // ref 4.5 = source 6.5 = timeline 2.5
    #expect(r["exact"]?.arrayValue?[2] == false)   // source 1.2 was cut: next kept frame (timeline 0)
    #expect(times[2] == 0)
    #expect(abs(times[3] - 3) < 1e-6)              // ref 5.0 = 1 s into the second segment = source 7.0 = timeline 3.0
    let back = try e.execute("timeline.mapTimes", params: ["referenceSegments": .string(seg.path), "times": [0.5, 2.5], "direction": "toReference"])
    #expect(back["times"]!.arrayValue!.compactMap(\.doubleValue).map { ($0 * 1000).rounded() / 1000 } == [1.5, 4.5])
}

@Test func cubeLUTsParse() throws {
    var text = "TITLE \"id\"\nLUT_3D_SIZE 2\nDOMAIN_MIN 0 0 0\n# comment\n"
    for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { text += "\(r) \(g) \(b)\n" } } }
    let lut = try CubeLUT.parse(text)
    #expect(lut.size == 2 && lut.values.count == 24 && lut.values[3] == 1)
    #expect(throws: CommandError.self) { try CubeLUT.parse("LUT_3D_SIZE 3\n0 0 0\n") }
}

@Test func layerGeometryPlacesNativePicturesAroundTheirCentre() {
    var l = VideoLayer(trackID: "t", clipID: "c", assetID: "a", sourceTime: .zero, sourceWidth: 1080, sourceHeight: 540,
                       crop: [1080, 540, 0, 0], scale: 1, x: 0, y: 0, rotation: 0, opacity: 1, color: nil)
    l.placement = Placement(fit: .native, x: 0.5, y: 380.0 / 1920)
    #expect(l.box(width: 1080, height: 1920) == [0, 110, 1080, 540])
    l.scale = 0.5
    #expect(l.box(width: 1080, height: 1920) == [270, 245, 540, 270])
    #expect(l.box(width: 540, height: 960) == [135, 122.5, 270, 135])   // half-size output: everything halves
    l.placement?.fit = .contain
    l.scale = 1
    #expect(l.baseSize(width: 1080, height: 1920) == (1080, 540))
    l.placement = nil
    #expect(l.baseSize(width: 1080, height: 1920) == (1080, 1920))
}

@Test func shotcutExportPlacesOverlaysAndKeyframesTheDucking() throws {
    let fakes = FakeServices()
    let e = try analysisEngine(fakes)
    try e.execute("media.extractAudio", params: ["assetId": "a1"])
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("track.add", params: ["kind": "audio"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 6])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": 0, "sourceOut": 6, "linkTo": "c1"])
    try e.execute("overlay.add", params: ["path": .string(fakeMedia("logo.png")), "start": 1, "duration": 2, "band": "top", "scale": 0.5])
    try e.execute("audio.addMusic", params: ["path": .string(fakeMedia("bed.wav"))])
    try e.execute("sfx.add", params: ["path": .string(fakeMedia("pop.wav")), "at": 2, "volume": 0.5, "duration": 0.5])
    try e.execute("transition.add", params: ["kind": "flash", "at": 3])
    let out = tempDir().appendingPathComponent("p.mlt")
    let r = try e.execute("export.mlt", params: ["path": .string(out.path)])
    let xml = try String(contentsOf: out, encoding: .utf8)
    #expect(xml.contains("<property name=\"mlt_service\">qimage</property>") && xml.contains("affineSizePosition"))
    #expect(xml.contains("transition.rect\">270.0 -105.0 540.0 960.0 1.000"))   // 1080×1920 still at 0.5×, centred on y 375 (375 − 480)
    #expect(xml.contains("<property name=\"level\">-6.02</property>"))           // SFX gain
    #expect(xml.contains("=-12.0;"))                                             // ducking keyframes
    #expect(r["warnings"]?.arrayValue?.contains { $0.stringValue?.contains("transitions") == true } == true)
}

// MARK: Blender 3D templates (issue #34)

@Test func blender3DTemplatesHaveTheirScriptAndCatalogTile() throws {
    #expect(FileManager.default.fileExists(atPath: BrandKit.bundled("Blender/regista3d.py")))
    for spec in Blender3D.templates {
        #expect(FileManager.default.fileExists(atPath: BrandKit.bundled("Blender/templates/\(spec.module).py")), "\(spec.id) has no script")
        #expect(spec.guide.isComplete, "\(spec.id) guide")
        let tile = try #require(EffectsCatalog.named(spec.id))
        #expect(tile.command == "graphics.blender3d" && tile.engine == "blender")
    }
}

@Test func blender3DRejectsUnknownTemplatesAndFieldsBeforeRendering() throws {
    let e = try analysisEngine()
    #expect(throws: CommandError.self) { try e.execute("graphics.blender3d", params: ["template": "nope", "start": 1]) }
    #expect(throws: CommandError.self) {
        try e.execute("graphics.blender3d", params: ["template": "stat-3d", "start": 1, "fields": ["colour": "#fff"]])
    }
    #expect(throws: CommandError.self) {
        try e.execute("graphics.blender3d", params: ["template": "orbit-ring-3d", "start": 1, "fields": ["center": [540]]])
    }
}
