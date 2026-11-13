import Foundation
import Testing
@testable import RegistaCore

// Effects for users (issue #16): speed, looks and adjustments, callouts, beats, catalogue, styles.

/// V1 + A1 with three linked 2 s clips (sources 10–12, 20–22, 30–32) back to back.
private func threeClips() throws -> Engine {
    let e = try editingEngine()
    for s in [10.0, 20.0, 30.0] {
        let v = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": .number(s), "sourceOut": .number(s + 2)])
        try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t2", "sourceIn": .number(s), "sourceOut": .number(s + 2),
                                                 "linkTo": v.value(at: "clip.id") ?? .null])
    }
    return e
}

// MARK: Speed

@Test func constantSpeedRetimesPictureAndSoundAndRipples() throws {
    let e = try threeClips()
    let first = e.clips(0)[0].id, second = e.clips(0)[1].id
    let r = try e.checkUndoRedo("clip.speed", ["clipId": .string(first), "rate": 0.5])
    #expect(r.value(at: "duration") == 4)
    let v = e.clips(0), a = e.clips(1)
    #expect(v[0].duration == t(4) && a[0].duration == t(4))
    #expect(v[0].sourceDuration == t(2))
    // Later clips on both tracks moved by +2 s.
    #expect(v.first { $0.id == second }!.start == t(4))
    #expect(a[1].start == t(4))
    // Mapping: 1 s into the slowed clip shows source 10.5 s; source 11 s plays at 2 s.
    #expect(abs(v[0].sourceTime(atLocal: t(1)).seconds - 10.5) < 1e-6)
    #expect(abs(v[0].timelineTime(ofSource: t(11))!.seconds - 2) < 1e-6)
    // The renderer reads the mapped source time.
    let job = RenderJob(project: e.project!, preset: .vertical, captions: false)
    #expect(abs(job.layers(at: t(3)).first!.sourceTime.seconds - 11.5) < 1e-6)
    // Sound: one clip time-stretched (pitch kept) to exactly the picture length.
    let mix = AudioPlan.clips(e.project!, rate: 48000)
    #expect(abs(mix[0].tempo - 0.5) < 1e-9)
    #expect(mix[0].timelineLength == 4 * 48000)
    #expect(mix[1].timelineStart == 4 * 48000 && mix[1].tempo == 1)
}

@Test func extremeReversedAndFrozenSpeedsMuteTheSound() throws {
    #expect(Speed(rate: 0.2, duration: t(10)).effectiveAudio == .mute)
    #expect(Speed(rate: 4, duration: t(1)).effectiveAudio == .pitch)
    var rev = Speed(rate: 1, duration: t(2))
    rev.reverse = true
    #expect(rev.effectiveAudio == .mute)
    #expect(rev.sourceOffset(atTimeline: 0.5, span: 2) == 1.5)
    var forcedPitch = Speed(rate: 8, duration: t(1))
    forcedPitch.audio = .pitch
    #expect(forcedPitch.effectiveAudio == .pitch)

    let e = try threeClips()
    try e.execute("clip.speed", params: ["clipId": .string(e.clips(0)[0].id), "rate": 10])
    #expect(e.clips(0)[0].duration == t(0.2))
    #expect(AudioPlan.clips(e.project!, rate: 48000).count == 2)   // the 10× clip is silent
}

@Test func speedRampIntegratesAndInterpolates() throws {
    var s = Speed(duration: .zero)
    s.ramp = [ScalarKey(time: .zero, value: 1, easing: .linear), ScalarKey(time: t(2), value: 0.5)]
    // ∫₀² ds / (1 − s/4) = 4 ln 2.
    #expect(abs(s.timelineSeconds(forSource: 2) - 4 * log(2.0)) < 1e-3)
    s.duration = MediaTime(seconds: s.timelineSeconds(forSource: 2))
    // Monotonic, starts at 0, ends at the span; inverse mapping agrees.
    var prev = -1.0
    for k in 0...20 {
        let tl = s.duration.seconds * Double(k) / 20
        let src = s.sourceOffset(atTimeline: tl, span: 2)
        #expect(src >= prev)
        prev = src
        #expect(abs(s.timelineOffset(atSource: src, span: 2)! - tl) < 2e-3)
    }
    #expect(abs(prev - 2) < 1e-6)
    // Early on the clip plays at ~1×, at the end at ~0.5×.
    #expect(abs(s.sourceOffset(atTimeline: 0.1, span: 2) - 0.1) < 0.005)
    // Pieces tile the timeline and the source without gaps.
    let pieces = s.pieces(span: 2, step: 0.1)
    #expect(abs(pieces.first!.t0) < 1e-9 && abs(pieces.last!.t1 - s.duration.seconds) < 1e-9)
    #expect(abs(pieces.last!.s1 - 2) < 1e-6)
    for (a, b) in zip(pieces, pieces.dropFirst()) { #expect(a.t1 == b.t0 && abs(a.s1 - b.s0) < 1e-12) }

    // Through the command: a hero ramp, its sound split into stretched pieces that start where their picture does.
    let e = try threeClips()
    try e.execute("clip.speed", params: ["clipId": .string(e.clips(0)[0].id), "preset": "hero"])
    let c = e.clips(0)[0]
    #expect(c.duration > t(2) && c.speed?.isRamp == true)
    let mix = AudioPlan.clips(e.project!, rate: 48000)[0]
    #expect(mix.timeMap != nil && mix.timelineLength == Int(c.duration.seconds * 48000))
    // Output sample ↔ source sample follows the picture's mapping.
    for f in [0.0, 0.25, 0.5, 0.9] {
        let tl = c.duration.seconds * f
        let expected = c.sourceTime(atLocal: MediaTime(seconds: tl)).seconds - c.sourceIn.seconds
        #expect(abs(mix.sourceOffset(atOutput: Int(tl * 48000)) / 48000 - expected) < 0.002)
    }
}

@Test func freezeFrameCutsInsertsAndRipples() throws {
    let e = try threeClips()
    let first = e.clips(0)[0]
    let r = try e.checkUndoRedo("clip.speed", ["clipId": .string(first.id), "freezeAt": 1, "freezeDuration": 1.5])
    let v = e.clips(0)
    // Left half, the frozen frame, the right half, then the rest moved by 1.5 s.
    #expect(v.count == 5)
    #expect(v[0].duration == t(1) && v[1].speed?.freeze == true && v[1].duration == t(1.5) && v[1].start == t(1))
    #expect(v[2].start == t(2.5) && abs(v[2].sourceIn.seconds - 11) < 1e-9)
    #expect(v[3].start == t(3.5))
    #expect(abs(v[1].sourceIn.seconds - 11) < 1e-9)
    // The sound has a gap where the frame holds.
    let a = e.clips(1)
    #expect(a.count == 4 && a[1].start == t(2.5))
    #expect(r.value(at: "clip.speed.freeze") == true)
    let job = RenderJob(project: e.project!, preset: .vertical, captions: false)
    #expect(abs(job.layers(at: t(2)).first!.sourceTime.seconds - 11) < 1e-9)
}

@Test func retimedClipsSplitAndTrimThroughTheirSpeed() throws {
    let e = try threeClips()
    let id = e.clips(0)[0].id
    try e.execute("clip.speed", params: ["clipId": .string(id), "rate": 2, "linked": false])
    #expect(e.clips(0)[0].duration == t(1))
    try e.execute("timeline.cut", params: ["at": 0.5, "trackId": "t1"])
    let v = e.clips(0)
    #expect(v[0].duration == t(0.5) && v[1].duration == t(0.5))
    #expect(abs(v[0].sourceOut.seconds - 11) < 1e-9 && abs(v[1].sourceIn.seconds - 11) < 1e-9)
    try e.execute("timeline.trim", params: ["clipId": .string(v[1].id), "edge": "end", "to": 0.8, "linked": false])
    #expect(abs(e.clips(0)[1].sourceOut.seconds - 11.6) < 1e-6)
}

@Test func timeStretchKeepsClicksOnTheirMappedTimes() throws {
    // Clicks every 0.5 s stretched to half speed land on their doubled times (atempo misses by up to 60 ms).
    let rate = 48000
    var x = [Float](repeating: 0, count: rate * 4)
    for k in 0..<8 {
        let t0 = Int((0.25 + Double(k) * 0.5) * Double(rate))
        for i in 0..<240 { x[t0 + i] = Float(0.8 * sin(2 * Double.pi * 1000 * Double(i) / Double(rate)) * exp(-Double(i) / 100)) }
    }
    let out = TimeStretch.stretch(x, channels: 1, length: rate * 8, rate: rate) { Double($0) * 0.5 }
    var onsets: [Double] = []
    var last = -rate
    for (i, v) in out.enumerated() where abs(v) > 0.1 && i - last > rate / 5 { onsets.append(Double(i) / Double(rate)); last = i }
    #expect(onsets.count == 8)
    for (k, o) in onsets.enumerated() { #expect(abs(o - (0.25 + Double(k) * 0.5) * 2) < 0.012, "click \(k) at \(o)") }
}

// MARK: Looks & adjustments

@Test func lookAtIntensityZeroIsTheIdentity() throws {
    #expect(Grade(look: "film", amount: 0).resolved(at: .zero) == nil)
    #expect(Grade(look: "film", amount: 0.5).resolved(at: .zero) != nil)
    // The cube of a zero-intensity look is the identity cube.
    let id = ResolvedGrade(look: "film", amount: 0, adjust: Adjustments())
    let cube = id.cube(size: 9)
    for (i, v) in cube.enumerated() where i % 4 != 3 {
        let n = i / 4, channel = i % 4
        let expected = Float([n % 9, (n / 9) % 9, n / 81][channel]) / 8
        #expect(abs(v - expected) < 1e-6)
    }
    // Every look moves a mid-grey skin tone at full strength, and not at all at 0.
    for look in Look.all {
        let full = ResolvedGrade(look: look.id, amount: 1, adjust: Adjustments()).apply(r: 0.7, g: 0.5, b: 0.4)
        #expect(abs(full.0 - 0.7) + abs(full.1 - 0.5) + abs(full.2 - 0.4) > 0.01, "\(look.id) changes nothing")
        let zero = ResolvedGrade(look: look.id, amount: 0, adjust: Adjustments()).apply(r: 0.7, g: 0.5, b: 0.4)
        #expect(zero == (0.7, 0.5, 0.4))
    }
    // Through the command: amount 0 leaves no grade on the layer.
    let e = try threeClips()
    try e.checkUndoRedo("look.apply", ["look": "riviera", "amount": 0])
    #expect(RenderJob(project: e.project!, preset: .vertical, captions: false).layers(at: t(1)).first!.grade == nil)
    try e.execute("look.apply", params: ["look": "riviera", "amount": 0.6])
    #expect(RenderJob(project: e.project!, preset: .vertical, captions: false).layers(at: t(1)).first!.grade?.amount == 0.6)
}

@Test func adjustmentsValidateTheirRangesAndKeyframe() throws {
    let e = try threeClips()
    #expect(throws: CommandError.self) { try e.execute("adjust.set", params: ["exposure": 1.5]) }
    #expect(throws: CommandError.self) { try e.execute("adjust.set", params: ["sharpness": -0.1]) }
    #expect(throws: CommandError.self) { try e.execute("adjust.set", params: ["keyframes": ["vignette": [["time": 0, "value": 2]]]]) }
    #expect(throws: CommandError.self) { try e.execute("adjust.set", params: ["keyframes": ["sparkle": [["time": 0, "value": 0.5]]]]) }
    let clip = e.clips(0)[1]
    try e.checkUndoRedo("adjust.set", ["clipId": .string(clip.id), "exposure": 0.3, "warmth": -0.4, "vignette": 0.5,
                                       "keyframes": ["contrast": [["time": 2, "value": 0], ["time": 4, "value": 1]]]])
    let g = e.clips(0)[1].grade!
    #expect(g.adjust?.exposure == 0.3 && g.adjust?.warmth == -0.4)
    // Keyframes are clip-relative: timeline 3 s = clip 1 s = halfway.
    #expect(abs((g.resolved(at: t(1))?.adjust.contrast ?? 0) - 0.5) < 1e-9)
    // Every property is clamped to its range by the subscript; sliders are −1…1 except sharpness and vignette.
    var a = Adjustments()
    a["exposure"] = 3
    a["vignette"] = -1
    #expect(a.exposure == 1 && a.vignette == 0)
    #expect(Adjustments.properties.count == 10)
    try e.execute("adjust.set", params: ["clipId": .string(clip.id), "reset": true])
    #expect(e.clips(0)[1].grade == nil)
}

// MARK: Callouts, stickers, logo

@Test func calloutsDrawOnThenHoldAndFade() throws {
    let s = ShapeLayer(kind: .circle, rect: [0.3, 0.3, 0.4, 0.1], color: "#FFD43B", drawOn: 0.4)
    #expect(s.progress(at: .zero, duration: t(2)) == 0)
    #expect(s.progress(at: t(0.2), duration: t(2)) > 0.5)   // ease-out: most of the stroke early
    #expect(s.progress(at: t(0.4), duration: t(2)) == 1 && s.progress(at: t(1.5), duration: t(2)) == 1)
    let bar = ShapeLayer(kind: .progressBar, rect: [0, 0, 1, 0.01], color: "#FFFFFF")
    #expect(abs(bar.progress(at: t(1), duration: t(4)) - 0.25) < 1e-9)

    let e = try threeClips()
    let r = try e.checkUndoRedo("callout.add", ["kind": "circle", "start": 1, "duration": 2, "rect": [300, 500, 400, 150]])
    let id = r.value(at: "clip.id")!.stringValue!
    let job = RenderJob(project: e.project!, preset: .vertical, captions: false)
    func layer(_ s: Double) -> VideoLayer? { job.layers(at: t(s)).first { $0.clipID == id } }
    guard case .shape(_, let p0) = layer(1)!.source, case .shape(_, let p1) = layer(1.6)!.source else { Issue.record("no shape"); return }
    #expect(p0 == 0 && p1 == 1)
    #expect(layer(1.5)!.opacity == 1 && layer(2.97)!.opacity < 0.7)
    #expect(layer(3.1) == nil)
    // A callout in the caption band says so.
    let w = try e.execute("callout.add", params: ["kind": "box", "start": 4, "rect": [200, 1300, 600, 100]])
    #expect(w["warnings"]?.arrayValue?.isEmpty == false)
    // The progress bar spans the picture by default.
    let pb = try e.execute("progress.add", params: [:])
    #expect(pb.value(at: "clip.duration") == 6)
}

@Test func stickersPopAndLogoMotionsKeyframe() throws {
    let e = try threeClips()
    let r = try e.checkUndoRedo("sticker.add", ["sticker": "fire", "start": 1, "animIn": "bounce"])
    let c = e.project!.tracks.flatMap(\.clips).first { $0.id == r.value(at: "clip.id")!.stringValue! }!
    #expect(c.sticker?.value == "🔥" && c.keyframes!.count >= 5 && c.duration == t(1.4))
    #expect(throws: CommandError.self) { try e.execute("sticker.add", params: ["start": 1]) }
    for m in LogoMotion.allCases where m != .none {
        let k = m.keyframes(rest: Transform(), duration: t(2))!
        #expect(k.first!.time == .zero && k.last!.time == t(2), "\(m)")
        #expect(k.last!.transform.opacity == 0, "\(m) ends visible")
    }
    // logo.animate on an existing still overlay; sting adds a short glow.
    let png = fakeMedia("logo.png")
    let o = try e.execute("overlay.add", params: ["path": .string(png), "start": 0, "duration": 2])
    let id = o.value(at: "clip.id")!
    try e.checkUndoRedo("logo.animate", ["clipId": id, "motion": "sting"])
    let logo = e.project!.tracks.flatMap(\.clips).first { $0.id == id.stringValue! }!
    #expect(logo.keyframes?.count == 5 && logo.effects?.first?.kind == .glow)
}

// MARK: Glitch & chroma key

@Test func glitchSeedsAreDeterministicAndChromaKeyKeysTheColour() throws {
    let e = try threeClips()
    let cid = e.clips(0)[0].id
    try e.execute("effect.add", params: ["kind": "glitch", "clipId": .string(cid), "start": 0.5, "end": 1])
    let job = RenderJob(project: e.project!, preset: .vertical, captions: false)
    let a = job.layers(at: t(0.6)).first!.effects.first!, b = job.layers(at: t(0.6)).first!.effects.first!
    #expect(a.kind == .glitch && a.seed == b.seed)
    #expect(job.layers(at: t(1.2)).first!.effects.isEmpty)
    #expect(ChromaKeyCube.alpha(r: 0, g: 1, b: 0, key: (0, 1, 0), tolerance: 0.4) < 0.01)
    #expect(ChromaKeyCube.alpha(r: 0.8, g: 0.6, b: 0.5, key: (0, 1, 0), tolerance: 0.4) > 0.99)   // skin stays
    #expect(ChromaKeyCube.alpha(r: 0.5, g: 0.5, b: 0.5, key: (0, 1, 0), tolerance: 1) > 0.99)    // grey stays
}

// MARK: Beats

@Test func beatDetectionFindsAClickTrack() throws {
    let rate = 22050, bpm = 120.0, first = 0.25
    var x = [Float](repeating: 0, count: rate * 12)
    var truth: [Double] = []
    var tb = first
    while tb < 11.5 {
        truth.append(tb)
        let i0 = Int(tb * Double(rate))
        for i in 0..<Int(0.012 * Double(rate)) where i0 + i < x.count {
            x[i0 + i] = Float(0.8 * sin(2 * Double.pi * 1000 * Double(i) / Double(rate)) * exp(-Double(i) / (0.004 * Double(rate))))
        }
        tb += 60 / bpm
    }
    // A little noise, so silence is not exactly zero.
    var g = SystemRandomNumberGenerator()
    for i in x.indices { x[i] += Float.random(in: -0.001...0.001, using: &g) }
    let r = BeatDetector.detect(x, rate: rate)
    #expect(abs(r.tempo - bpm) < 2, "tempo \(r.tempo)")
    #expect(r.beats.count >= truth.count - 2)
    for b in r.beats {
        let nearest = truth.map { abs($0 - b) }.min()!
        #expect(nearest < 0.02, "beat \(b) is \(nearest) s off")
    }
    #expect(r.onsets.count >= truth.count - 2)
}

@Test func beatSyncPunchesCutsAndMarksGivenBeats() throws {
    let e = try threeClips()
    let beats: JSONValue = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
    let r = try e.checkUndoRedo("edit.beatSync", ["beats": beats, "every": 4])
    #expect(r["added"] == 2)
    #expect(e.clips(0)[0].effects?.first?.kind == .punchZoom && e.clips(0)[1].effects?.first?.kind == .punchZoom)
    try e.execute("history.undo")
    try e.execute("edit.beatSync", params: ["beats": beats, "mode": "cuts", "every": 2, "to": 4])
    #expect(e.clips(0).count == 3 + 4)   // every other beat: cuts at 0.5, 1.5, 2.5, 3.5
    #expect(e.clips(0).contains { ($0.transform?.scale ?? 1) > 1.1 })
    try e.execute("edit.beatSync", params: ["beats": beats, "mode": "markers"])
    #expect(e.project!.markers.count == 8)
    #expect(throws: CommandError.self) { try e.execute("edit.beatSync", params: [:]) }   // no music track
}

// MARK: Catalogue & styles

@Test func everyGalleryTileResolvesToAValidCommand() throws {
    let e = try threeClips()
    let p = e.project!
    #expect(Set(EffectsCatalog.items.map(\.category)).union([.templates]) == Set(EffectsCatalog.Category.allCases))   // templates: registered by the engines
    #expect(Set(EffectsCatalog.items.map(\.id)).count == EffectsCatalog.items.count)
    for item in EffectsCatalog.items {
        let target = EffectTarget(clipID: item.needs == .picture ? nil : e.clips(0)[1].id, start: t(2.5), end: t(3.5))
        for i in [0.0, 0.5, 1.0] {
            let r = EffectsCatalog.resolve(item, target: target, intensity: i, project: p)
            let cmd = try #require(e.registry[r.command], "\(item.id): unknown \(r.command)")
            _ = try CommandParams(validating: r.params, for: cmd.descriptor)
        }
    }
    let q = try e.execute("effects.catalog", params: ["item": "speed-slowmo", "clipId": .string(e.clips(0)[0].id)])
    #expect(q["command"] == "clip.speed" && q.value(at: "params.preset") == "slowmo")
}

@Test func stylesApplyAsOneUndoStep() throws {
    let e = try threeClips()
    try e.execute("brandkit.apply", params: ["kit": "wesites", "captions": false])
    for style in ["pulito", "energico", "tutorial"] {
        let undo = e.context.history.undoStack.count
        let r = try e.checkUndoRedo("style.apply", ["style": .string(style)])
        #expect(e.context.history.undoStack.count == undo + 1, "\(style) is not one step")
        #expect(r["applied"]?.arrayValue?.isEmpty == false, "\(style) applied nothing")
        try e.execute("history.undo")
    }
    // Tutorial without a recording says why it skipped the zooms; the bar takes the brand's primary colour.
    let r = try e.execute("style.apply", params: ["style": "tutorial"])
    #expect(r["skipped"]?.arrayValue?.contains { $0.stringValue?.contains("not a screen recording") == true } == true)
    let bar = e.project!.tracks.flatMap(\.clips).first { $0.shape?.kind == .progressBar }
    #expect(bar?.shape?.color == "#002FA7")
}

/// Issue #22: every catalog item tells the agent what it looks like, when to propose it and when not to, and its
/// fields carry example values that the command it runs accepts.
@Test func everyCatalogItemHasGuidanceAndValidFields() throws {
    let e = try threeClips()
    for item in EffectsCatalog.items {
        #expect(item.guide.isComplete, "\(item.id) lacks description/useWhen/avoid")
        #expect(item.guide.description.count >= 30 && item.guide.useWhen.count >= 20 && item.guide.avoid.count >= 20, "\(item.id): guidance too thin")
        #expect(!item.fields.isEmpty, "\(item.id) lists no fields")
        let cmd = try #require(e.registry[item.command])
        let names = Set(cmd.descriptor.params.map(\.name))
        for f in item.fields {
            #expect(f.example != .null, "\(item.id).\(f.name) has no example")
            #expect(!f.description.isEmpty, "\(item.id).\(f.name) has no description")
            let name = f.name.hasPrefix("fields.") ? "fields" : f.name
            #expect(name == "intensity" || names.contains(name), "\(item.id): field \(f.name) is not a param of \(item.command)")
        }
    }
    // Field values override the resolved params; start moves the target.
    let r = try e.execute("effects.catalog", params: ["item": "sticker-fire", "fields": ["start": 3, "size": 222]])
    #expect(r.value(at: "params.size") == 222 && r.value(at: "params.start") == 3)
    let list = try e.execute("effects.catalog", params: ["category": "styles"])
    #expect(list["items"]?.arrayValue?.count == 4 && list.value(at: "items.0.useWhen")?.stringValue?.isEmpty == false)
    let brief = try e.execute("effects.catalog", params: ["brief": true])
    #expect(brief.value(at: "items.0.useWhen") == nil && brief.value(at: "items.0.description") != nil)
}
