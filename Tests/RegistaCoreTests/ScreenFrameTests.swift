import Foundation
import Testing
@testable import RegistaCore

// Styled screen frame, keystroke overlay and 4:5 export (issue #44).

// MARK: - Spec encode / decode

@Test func layoutSpecsWithoutAFrameStillDecodeAndFramedOnesRoundTrip() throws {
    // A session.json / project written before the frame existed.
    let old = try JSONDecoder().decode(LayoutSpec.self, from: Data(#"{"kind":"bubble","corner":"topLeft"}"#.utf8))
    #expect(old == LayoutSpec(kind: .bubble, corner: "topLeft") && old.frame == nil)
    let settings = try JSONDecoder().decode(ProjectSettings.self, from: Data(##"{"width":1920,"height":1080,"frameRate":{"num":30,"den":1},"sampleRate":48000,"background":"#0F1013"}"##.utf8))
    #expect(settings.backdrop == nil && settings.background == "#0F1013")

    let framed = LayoutSpec(kind: .screen, frame: ScreenFrame(background: Backdrop.preset("dusk"), padding: 0.08, radius: 0.02, shadow: 0.4))
    let back = try JSONDecoder().decode(LayoutSpec.self, from: JSONEncoder().encode(framed))
    #expect(back == framed)
    #expect(framed.label == "screen framed dusk")
    var s = ProjectSettings()
    s.backdrop = Backdrop(kind: .image, path: "/tmp/wall.jpg")
    #expect(try JSONDecoder().decode(ProjectSettings.self, from: JSONEncoder().encode(s)) == s)
}

@Test func theFrameIsOnlyForScreenAndBubbleAndChecksItsRanges() {
    #expect(throws: CommandError.self) { try LayoutSpec(kind: .split, frame: ScreenFrame()).validate() }
    #expect(throws: CommandError.self) { try LayoutSpec(kind: .screen, frame: ScreenFrame(padding: 0.5)).validate() }
    #expect(throws: CommandError.self) { try LayoutSpec(kind: .screen, frame: ScreenFrame(background: Backdrop(kind: .linear, colors: ["#000000"]))).validate() }
    #expect(throws: CommandError.self) { try LayoutSpec(kind: .screen, frame: ScreenFrame(background: Backdrop(kind: .solid, colors: ["red"]))).validate() }
    #expect(throws: Never.self) { try LayoutSpec(kind: .bubble, frame: ScreenFrame()).validate() }
    #expect(Backdrop.presets.count >= 4 && Backdrop.presets.allSatisfy { (try? $0.backdrop.validate()) != nil })
}

// MARK: - Geometry

@Test func framedScreenIsTheWholeScreenInsideThePaddingWithRoundedCorners() {
    // 16:9 frame, 16:9 screen: padding 0.06 × 1080 = 65 px; the height limits (950 px), never cropped.
    let g = Layouts.geometry(LayoutSpec(kind: .screen, frame: ScreenFrame()), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920))
    let p = g.screen.placement!
    #expect(p.fit == .box && p.x == 0.5 && p.y == 0.5)
    #expect(abs(p.height! * 1080 - 950) < 0.5 && abs(p.width! * 1920 - 1689) < 0.5)
    #expect(g.screen.mask?.shape == .rounded && g.screen.mask?.frame == "float" && g.screen.mask?.shadow == 0.5)
    // Radius 0.016 of the shorter output side, stored as a fraction of the box's shorter side.
    #expect(abs((g.screen.mask?.radius ?? 0) * 950 - 0.016 * 1080) < 1e-9)
    #expect(g.camera.visible == false)
    // 9:16 and 4:5: the width limits (1080 − 130 = 950), the 16:9 screen keeps its aspect.
    for H in [1920, 1350] {
        let v = Layouts.geometry(LayoutSpec(kind: .screen, frame: ScreenFrame()), width: 1080, height: H, screen: (1920, 1080), camera: (1080, 1920)).screen.placement!
        #expect(abs(v.width! * 1080 - 950) < 0.5 && abs(v.height! * Double(H) - 534) < 0.5)
    }
    // No shadow, no radius: a plain rectangle.
    let flat = Layouts.geometry(LayoutSpec(kind: .screen, frame: ScreenFrame(padding: 0.1, radius: 0, shadow: 0)), width: 1920, height: 1080,
                                screen: (1920, 1080), camera: (1080, 1920))
    #expect(flat.screen.mask?.shape == .rect && flat.screen.mask?.frame == nil && abs(flat.screen.placement!.height! * 1080 - 864) < 0.5)
    // Without a frame nothing changes: the screen fills.
    #expect(Layouts.geometry(LayoutSpec(kind: .screen), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920)).screen.placement == nil)
}

@Test func aFramedBubbleStraddlesTheScreenWhenThereIsRoomAndTheCornerOtherwise() {
    let face = [400.0, 500, 300, 360]
    // 16:9: no room around the screen → the usual frame corner.
    let wide = Layouts.geometry(LayoutSpec(kind: .bubble, frame: ScreenFrame()), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920), face: face)
    let plain = Layouts.geometry(LayoutSpec(kind: .bubble), width: 1920, height: 1080, screen: (1920, 1080), camera: (1080, 1920), face: face)
    #expect(wide.camera.placement == plain.camera.placement)
    #expect(wide.screen.placement?.fit == .box)
    // 4:5: the screen (950×534) moves up by d/4 and the bubble (d = 324) sits on its bottom edge, inside its right edge.
    let g = Layouts.geometry(LayoutSpec(kind: .bubble, frame: ScreenFrame()), width: 1080, height: 1350, screen: (1920, 1080), camera: (1080, 1920), face: face)
    let s = g.screen.placement!, c = g.camera.placement!
    let screenCY = s.y * 1350, d = 324.0, m = 49.0
    #expect(abs(screenCY - (675 - d / 4)) < 0.5)
    #expect(abs(c.y * 1350 - (screenCY + 267)) < 0.5)
    #expect(abs(c.x * 1080 - (540 + 475 - 0.6 * m - d / 2)) < 0.5)
    // The pair stays inside the frame.
    #expect(c.y * 1350 + d / 2 < 1350 && screenCY - 267 > 0)
    // A top corner straddles the top edge.
    let top = Layouts.geometry(LayoutSpec(kind: .bubble, corner: "topLeft", frame: ScreenFrame()), width: 1080, height: 1920, screen: (1920, 1080), camera: (1080, 1920), face: face)
    #expect(abs(top.camera.placement!.y * 1920 - (top.screen.placement!.y * 1920 - 267)) < 0.5)
    #expect(top.camera.placement!.x < 0.5)
}

// MARK: - layout.apply / recording.import

@Test func layoutApplyWithAFrameSetsTheBackdropFromTheKitAndUndoes() throws {
    let (e, _) = try recordingEngine(layout: LayoutSpec(kind: .screen))
    #expect(e.project!.settings.backdrop == nil)
    // No kit: graphite.
    try e.checkUndoRedo("layout.apply", ["preset": "screen", "frame": true])
    #expect(e.project!.settings.backdrop == Backdrop.preset("graphite"))
    #expect(e.project!.tracks[0].clips[0].placement?.fit == .box && e.project!.tracks[0].clips[0].mask?.frame == "float")
    #expect(e.project!.recordings?[0].layouts?.last?.layout.frame == ScreenFrame())
    // A kit applied afterwards recolours the default background, and a new apply takes it too.
    try e.execute("brandkit.apply", params: ["kit": "arkad"])
    #expect(e.project!.settings.backdrop == Backdrop.brand(BrandKit.arkad.absolutized()))
    #expect(e.project!.settings.backdrop?.colors?.last == "#070501")
    // Presets, colours and custom gradients.
    try e.execute("layout.apply", params: ["preset": "bubble", "background": "lagoon", "padding": 0.1])
    #expect(e.project!.settings.backdrop?.preset == "lagoon")
    #expect(e.project!.recordings?[0].layouts?.last?.layout.frame?.padding == 0.1)
    try e.execute("layout.apply", params: ["preset": "screen", "background": "#202124"])
    #expect(e.project!.settings.backdrop == Backdrop(kind: .solid, colors: ["#202124"]))
    try e.execute("layout.apply", params: ["preset": "screen", "gradient": ["#101820", "#203040"], "angle": 90])
    #expect(e.project!.settings.backdrop == Backdrop(kind: .linear, colors: ["#101820", "#203040"], angle: 90))
    #expect(throws: CommandError.self) { try e.execute("layout.apply", params: ["preset": "screen", "background": "no-such-thing"]) }
    #expect(throws: CommandError.self) { try e.execute("layout.apply", params: ["preset": "split", "frame": true]) }
    // A layout without a frame over the whole recording takes the backdrop away and the screen fills again.
    try e.execute("layout.apply", params: ["preset": "screen"])
    #expect(e.project!.settings.backdrop == nil && e.project!.tracks[0].clips[0].placement == nil && e.project!.tracks[0].clips[0].mask == nil)
}

@Test func importWithFrameOptionsFramesTheScreenAndBubbleRangesOnly() throws {
    let e = Engine(prober: SessionProber())
    try e.execute("project.new", params: ["name": "t", "width": 1080, "height": 1350])
    let folder = try sessionFolder(layout: LayoutSpec(kind: .bubble), changes: [RecordingSession.LayoutChange(t: 7.25, layout: LayoutSpec(kind: .face))])
    try e.execute("recording.import", params: ["path": .string(folder.path), "background": "sand"])
    let layouts = e.project!.recordings![0].layouts!
    #expect(layouts.map(\.layout.kind) == [.bubble, .face])
    #expect(layouts[0].layout.frame?.background?.preset == "sand" && layouts[1].layout.frame == nil)
    #expect(e.project!.settings.backdrop?.preset == "sand")
}

// MARK: - Keystrokes

@Test func keystrokesParseIntoMacNotationAndShortcutsAreDetected() {
    let k = KeyStroke(parsing: "cmd+shift+k")
    #expect(k.modifiers == ["cmd", "shift"] && k.key == "k" && k.glyphs == "⇧⌘K" && k.isShortcut)
    #expect(KeyStroke(parsing: "ctrl+alt+cmd+t").glyphs == "⌃⌥⌘T")
    #expect(KeyStroke(parsing: "cmd++").glyphs == "⌘+")
    #expect(KeyStroke(parsing: "cmd+ ").glyphs == "⌘Space")
    #expect(KeyStroke(parsing: "k36").glyphs == "↩" && KeyStroke(parsing: "k36").isSpecial && !KeyStroke(parsing: "k36").isShortcut)
    #expect(KeyStroke(parsing: "cmd+\u{F702}").glyphs == "⌘←")
    #expect(KeyStroke(parsing: "\u{F708}").glyphs == "F5" && KeyStroke(parsing: "\u{F708}").isShortcut)
    #expect(KeyStroke(parsing: "\u{1b}").glyphs == "⎋")
    // Typing: letters (shift = capital) are not shortcuts.
    #expect(!KeyStroke(parsing: "a").isShortcut && !KeyStroke(parsing: "shift+a").isShortcut && !KeyStroke(parsing: "a").isSpecial)
    #expect(KeyStroke(parsing: "shift+a").typed == "A" && KeyStroke(parsing: "k").typed == "k")
}

func keyEvents(_ keys: [(Double, String)]) -> [RecordingSession.Event] {
    keys.map { RecordingSession.Event(kind: "key", t: $0.0, key: $0.1) } + [RecordingSession.Event(kind: "click", t: 1, x: 10, y: 10)]
}

@Test func onlyShortcutsByDefaultWithRepeatsCollapsed() {
    let events = keyEvents([(1, "cmd+c"), (2, "h"), (2.1, "i"), (3, "cmd+z"), (3.3, "cmd+z"), (3.6, "cmd+z"), (6, "k36"), (8, "cmd+z")])
    let b = KeyOverlay.badges(events)
    #expect(b.map { $0.text() } == ["⌘C", "⌘Z ×3", "⌘Z"])
    #expect(b.allSatisfy { $0.kind == .shortcut })
    // Each badge lasts hold (1 s) after its last key, at least 0.7 s, and never runs into the next one.
    #expect(b[0].start == 1 && b[0].end == 2)
    #expect(b[1].start == 3 && abs(b[1].end - 4.6) < 1e-9)
    var o = KeyOverlay.Options()
    o.hold = 5
    let long = KeyOverlay.badges(events, o)
    #expect(long[0].end == 3 && long[1].end == 8)
}

@Test func allKeysCollapsesTypingRunsAndShowsSpecialKeys() {
    var o = KeyOverlay.Options()
    o.allKeys = true
    let events = keyEvents([(1, "h"), (1.1, "e"), (1.2, "l"), (1.3, "l"), (1.4, "o"), (1.5, " "), (1.6, "w"), (1.7, "\u{7f}"), (1.8, "shift+w"),
                            (2.0, "k36"), (2.2, "k36"), (5, "cmd+s"), (6, "a"), (9, "b"), (9.1, "c")])
    let b = KeyOverlay.badges(events, o)
    #expect(b.map { $0.text() } == ["hello W", "↩ ×2", "⌘S", "a", "bc"])
    #expect(b.map(\.kind) == [.typing, .special, .shortcut, .typing, .typing])
    // Long runs keep their end.
    let many = keyEvents((0..<40).map { (Double($0) * 0.1, "x") })
    #expect(KeyOverlay.badges(many, o).first?.text() == "…" + String(repeating: "x", count: 23))
}

@Test func badgesSitInsideABoxedScreenAndAvoidTheBubble() {
    // Inside the bottom edge of a framed screen box.
    let box = [65.0, 693, 950, 534]
    let y = KeyOverlay.centreY(position: "bottom", width: 1080, height: 1920, screenBox: box, badge: 60)
    #expect(abs(y - (693 + 534 - 0.05 * 534 - 30)) < 1e-9)
    // A full-frame screen: near the bottom of a landscape frame, above the caption band of a tall reel.
    #expect(KeyOverlay.centreY(position: "bottom", width: 1920, height: 1080, screenBox: nil, badge: 60) < 1080 - 60)
    #expect(KeyOverlay.centreY(position: "bottom", width: 1080, height: 1920, screenBox: nil, badge: 60) + 30 <= SafeZones.caption.0)
    #expect(KeyOverlay.centreY(position: "top", width: 1920, height: 1080, screenBox: nil, badge: 60) < 150)
    // Centred, unless that would touch the camera: then in the larger free part.
    #expect(KeyOverlay.centreX(span: (0, 1000), width: 200, y: 900, height: 60, avoid: nil) == 500)
    #expect(KeyOverlay.centreX(span: (0, 1000), width: 200, y: 900, height: 60, avoid: [550, 700, 300, 300]) == (0 + 550 - 24) / 2)
    #expect(KeyOverlay.centreX(span: (0, 1000), width: 200, y: 100, height: 60, avoid: [550, 700, 300, 300]) == 500)
}

@Test func keysOverlayIsTimedThroughCutsAndUndoable() throws {
    let (e, _) = try recordingEngine(layout: LayoutSpec(kind: .screen))
    // Replace the session's keys: a shortcut at session 3, 5 and 9 s (timeline = session − origin 0.25).
    let url = URL(fileURLWithPath: e.project!.recordings![0].session)
    var s = try RecordingSession.load(url)
    s.events = s.events.filter { $0.kind != "key" } + keyEvents([(3, "cmd+c"), (5, "cmd+v"), (9, "cmd+shift+z"), (9.5, "x")])
    try s.write(to: url)
    // Cut out timeline 4–6 s (the cmd+v at 4.75) with a ripple.
    try e.execute("timeline.cut", params: ["at": 4])
    try e.execute("timeline.cut", params: ["at": 6])
    try e.execute("timeline.delete", params: ["clipId": .string(e.project!.tracks[0].clips[1].id), "ripple": true])

    let r = try e.checkUndoRedo("keys.overlay", ["hold": 2])
    let badges = r["badges"]?.arrayValue ?? []
    #expect(badges.map { $0["text"]?.stringValue } == ["⌘C", "⇧⌘Z"])
    #expect(r["dropped"]?.doubleValue == 1)
    // ⌘C: 2.75 s, held 2 s but stopped at the end of its clip (4 s); ⇧⌘Z: 8.75 − 2 = 6.75 s, held 2 s.
    #expect(abs((badges[0]["start"]?.doubleValue ?? 0) - 2.75) < 0.02 && abs((badges[0]["end"]?.doubleValue ?? 0) - 4) < 0.02)
    #expect(abs((badges[1]["start"]?.doubleValue ?? 0) - 6.75) < 0.02 && abs((badges[1]["end"]?.doubleValue ?? 0) - 8.75) < 0.02)
    let p = e.project!
    let track = p.tracks.first { $0.role == "keys" }!
    #expect(track.kind == .overlay && track.name == "Tasti" && track.clips.count == 2)
    #expect(track.clips[0].title?.text == "⌘C" && track.clips[0].title?.background?.kind == "box" && track.clips[0].keyframes != nil)
    // Re-running replaces (same track, no duplicates); allKeys adds the typing; clear removes the track.
    let all = try e.execute("keys.overlay", params: ["allKeys": true])
    #expect(all["badges"]?.arrayValue?.map { $0["text"]?.stringValue } == ["⌘C", "⇧⌘Z", "x"])
    #expect(e.project!.tracks.filter { $0.role == "keys" }.count == 1)
    // Badges follow a brand kit applied later.
    try e.execute("brandkit.apply", params: ["kit": "arkad"])
    #expect(e.project!.tracks.first { $0.role == "keys" }?.clips.first?.title?.color == BrandKit.arkad.colors["paper"])
    try e.execute("keys.overlay", params: ["clear": true])
    #expect(!e.project!.tracks.contains { $0.role == "keys" })
}

// MARK: - 4:5

@Test func theFeedPortraitPresetIs1080By1350Everywhere() throws {
    let p = ExportPreset.named("4:5", project: Project(name: "x"))
    #expect(p.width == 1080 && p.height == 1350 && p.id == "4:5")
    #expect(ExportPreset.all.map(\.id) == ["9:16", "4:5", "1:1", "16:9"])
    for id in ["export.render", "frame.render"] {
        let schema = Engine(prober: FakeProber()).descriptors.first { $0.id == id }?.params.first { $0.name == "preset" }
        if case .oneOf(let values)? = schema?.type { #expect(values.contains("4:5")) } else { Issue.record("\(id) has no preset choice") }
    }
    // Layouts in a 4:5 project stay inside the frame.
    let (e, _) = try recordingEngine(width: 1080, height: 1350)
    let r = try e.execute("layout.presets")
    for preset in r["presets"]?.arrayValue ?? [] {
        for role in ["screen", "camera"] {
            guard let b = preset[role]?.arrayValue?.compactMap(\.doubleValue), b.count == 4 else { continue }
            #expect(b[0] >= -0.5 && b[1] >= -0.5 && b[0] + b[2] <= 1080.5 && b[1] + b[3] <= 1350.5, "\(preset["preset"]?.stringValue ?? "") \(role)")
        }
    }
    #expect(r["frame"]?["backgrounds"]?.arrayValue?.count == Backdrop.presets.count)
}
