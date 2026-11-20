import AppKit
import Foundation
import Testing
@testable import Regista
@testable import RegistaCore
import RegistaEngines

// E4 (#3): one Graphics panel. Every item of the effects catalog is listed in it (a new catalog entry cannot be
// forgotten), has a plain name and a line in every language, and its click — or its form's Applica / Aggiungi —
// resolves to a valid command; an effect, a look and a motion template applied the panel's way are in the rendered
// frame, and undo takes them out again.

private let localization = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/Localization")

private func table(_ lang: String) -> [String: String] {
    (NSDictionary(contentsOf: localization.appendingPathComponent("\(lang).lproj/Localizable.strings")) as? [String: String]) ?? [:]
}

/// A 9:16 project with one synthetic talking head on V1 (6 s), on the real engines.
private func footageEngine() throws -> Engine {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("regista-e4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let e = Engine(services: .live())
    try e.execute("project.new", params: ["name": "grafica", "directory": .string(dir.path)])
    let a = try e.execute("media.synthesize", params: ["path": .string(dir.appendingPathComponent("head.mov").path), "duration": 6])
    let asset = try #require(a.value(at: "asset.id")?.stringValue)
    let t = try e.execute("track.add", params: ["kind": "video"])
    let track = try #require(t.value(at: "track.id")?.stringValue)
    try e.execute("timeline.place", params: ["assetId": .string(asset), "trackId": .string(track)])
    return e
}

/// The click path of an item as the panel runs it: the item at once, or its form's button with the form's defaults.
private func panelCommand(_ item: EffectsCatalog.Item, project: Project, at time: Double) -> (command: String, params: JSONValue)? {
    switch GraphicsCatalog.action(item) {
    case .apply:
        return GraphicsActions.command(item.id, project: project, at: time)
    case .titleForm:
        return GraphicsActions.command(item.id, project: project, at: time,
                                       overrides: ["text": .string(loc(TitleForm.placeholder(item))), "duration": 2.5])
    case .motionForm:
        guard let spec = MotionRegistry.spec(item.id) else { return nil }
        return ("motion.add", MotionForm.params(spec, values: [:], at: time))
    }
}

@Test func everyCatalogItemIsListedOnceWithItsWordsAndAValidClick() throws {
    MotionLibrary.registerAll()
    let catalog = EffectsCatalog.items
    #expect(catalog.count > 100)
    // Every category in exactly one section, every item listed exactly once.
    let listed = Navigation.GraphicsSection.allCases.flatMap { GraphicsCatalog.items(in: $0) }.map(\.id)
    #expect(listed.count == Set(listed).count, "an item is listed twice")
    #expect(Set(listed) == Set(catalog.map(\.id)), "not in the panel: \(Set(catalog.map(\.id)).subtracting(listed).sorted())")
    // Plain words in every language: the name and the one line (never a command id).
    let tables = ["it", "en", "fr", "pt"].map { ($0, table($0)) }
    var missing: [String] = []
    for item in catalog {
        let line = CatalogLines.line(item)
        if line.isEmpty { missing.append("\(item.id): no line") }
        for (lang, t) in tables {
            if (t[item.label] ?? "").isEmpty { missing.append("\(item.id): label «\(item.label)» not in \(lang)") }
            if !line.isEmpty, (t[line] ?? "").isEmpty { missing.append("\(item.id): line not in \(lang)") }
        }
        #expect(!loc(item.label).contains("."), "\(item.id): the name reads like an id")
    }
    #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
    // The click (or the form's button with its defaults) resolves to the item's own command with valid params.
    let e = try footageEngine()
    let project = try #require(e.project)
    let commands = Dictionary(uniqueKeysWithValues: RegistaCore.Commands.all.map { ($0.id, $0) })
    for item in catalog {
        let r = try #require(panelCommand(item, project: project, at: 1.5), "\(item.id): no click")
        #expect(r.command == item.command, "\(item.id): \(r.command) ≠ \(item.command)")
        let command = try #require(commands[r.command], "\(item.id): unknown command \(r.command)")
        #expect(throws: Never.self, "\(item.id)") { _ = try CommandParams(validating: r.params, for: command.descriptor) }
    }
    // Nothing is hidden: an item that cannot run now says why (a 3D title without Blender, a caption style before
    // captions exist), the others are enabled.
    let blenderItem = try #require(catalog.first { $0.engine == "blender" })
    #expect(GraphicsCatalog.unavailable(blenderItem, project: project, blender: false) != nil)
    #expect(GraphicsCatalog.unavailable(blenderItem, project: project, blender: true) == nil)
    #expect(GraphicsCatalog.unavailable(try #require(EffectsCatalog.named("caption-elegant-serif")), project: project, blender: true) != nil)
    #expect(GraphicsCatalog.unavailable(try #require(EffectsCatalog.named("fx-glow")), project: project, blender: false) == nil)
}

/// A template's field as the catalogue names it (`fields.rows`) goes inside the command's `fields` (#89): the resolved
/// motion.add and graphics.blender3d accept it and the clip carries the value.
@Test func aTemplateFieldNamedByTheCatalogueReachesTheTemplate() throws {
    MotionLibrary.registerAll()
    let e = try footageEngine()
    let rows: JSONValue = ["Uno", "Due", "Tre"]
    let r = try e.execute("effects.catalog", params: ["item": "checklist", "start": 1, "fields": ["fields.rows": rows]])
    #expect(r.value(at: "params.fields.rows") == rows, "the field did not land inside fields: \(r["params"]?.text() ?? "")")
    #expect(r["params"]?["fields.rows"] == nil)
    let added = try e.execute(try #require(r["command"]?.stringValue), params: try #require(r["params"]))
    let id = try #require(added.value(at: "clip.id")?.stringValue)
    #expect(e.project?.tracks.flatMap(\.clips).first { $0.id == id }?.motion?.fields["rows"] == rows)
    // A 3D template's field too (resolved only: Blender is not needed to read the params).
    let three = try #require(EffectsCatalog.items.first { $0.command == "graphics.blender3d" })
    let name = try #require(three.fields.first { $0.name.hasPrefix("fields.") })
    let resolved = try e.execute("effects.catalog", params: ["item": .string(three.id), "start": 1, "fields": .object([name.name: name.example])])
    let command = try #require(RegistaCore.Commands.all.first { $0.id == "graphics.blender3d" })
    #expect(throws: Never.self) { _ = try CommandParams(validating: try #require(resolved["params"]), for: command.descriptor) }
}

/// An effect on a moment resolves with the clip under it through effects.catalog, as the panel's click does (#90), and a
/// sticker (a moment too) still gets no clip.
@Test func anEffectOnAMomentResolvesWithItsClip() throws {
    let e = try footageEngine()
    let main = try #require(e.project?.tracks.first { $0.kind == .video && !$0.clips.isEmpty }?.clips.first)
    for id in ["zoom-punch", "zoom-shake", "fx-glitch", "fx-flash", "fx-blur", "fx-glow"] {
        let r = try e.execute("effects.catalog", params: ["item": .string(id), "start": 1.5])
        #expect(r.value(at: "params.clipId")?.stringValue == main.id, "\(id) resolves without the clip: \(r["params"]?.text() ?? "")")
        #expect(throws: Never.self, "\(id)") { _ = try e.execute(try #require(r["command"]?.stringValue), params: try #require(r["params"])) }
    }
    let sticker = try #require(EffectsCatalog.items.first { $0.command == "sticker.add" && $0.needs == .moment })
    let r = try e.execute("effects.catalog", params: ["item": .string(sticker.id), "start": 1.5])
    #expect(r.value(at: "params.clipId") == nil, "a sticker resolves with a clip")
}

/// A 3D template's font role under a kit whose fonts are installed fonts, not files (#91): the installed font's file.
@Test func aThreeDTemplateFindsAnInstalledFontsFile() throws {
    let font = BrandKit.cafeAtelier.font("text")
    let file = try #require(GraphicsBlender3D.fontFile(font), "«\(font)» did not resolve to a file")
    #expect(FileManager.default.fileExists(atPath: file))
    #expect(GraphicsBlender3D.fontFile("NoSuchFont-Regular") == nil)
}

/// Mean absolute difference of two frames, 0…255.
private func difference(_ a: CGImage, _ b: CGImage) -> Double {
    func rgba(_ i: CGImage) -> [UInt8] {
        let w = 108, h = 192
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(i, in: CGRect(x: 0, y: 0, width: w, height: h))
        return px
    }
    let x = rgba(a), y = rgba(b)
    return Double(zip(x, y).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }) / Double(x.count)
}

private func frame(_ e: Engine, at t: Double) throws -> CGImage {
    let p = try #require(e.project)
    return try #require(try AVRenderer().renderImages(RenderJob(project: p, preset: .named(nil, project: p)), at: [MediaTime(seconds: t)]).first)
}

@Test func anEffectALookAndAMotionTemplateFromThePanelAreInTheFrameAndUndoRemovesThem() throws {
    let e = try footageEngine()
    // (item, moment of the click, moment to look at)
    for (id, at, look) in [("fx-flash", 2.0, 2.06), ("look-ink", 2.0, 2.0), ("counter", 1.0, 2.2)] {
        let item = try #require(EffectsCatalog.named(id))
        let before = try frame(e, at: look)
        let project = try #require(e.project)
        let r = try #require(panelCommand(item, project: project, at: at))
        try e.execute(r.command, params: r.params)
        let applied = try frame(e, at: look)
        #expect(difference(before, applied) > 4, "\(id): the frame did not change (\(difference(before, applied)))")
        try e.execute("history.undo")
        let undone = try frame(e, at: look)
        #expect(difference(before, undone) < 0.5, "\(id): undo left \(difference(before, undone))")
    }
}

/// The Studio overlay is gone: no view, mode or screenshot workspace of it is left, and the kit is no longer edited
/// in the editor (one Marca picker; kits are made in Settings through the brandkit.* commands, no view writes kit files).
@Test func noStudioOverlayAndNoKitWritesBehindTheCommands() throws {
    let root = localization.deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    let sources = fm.enumerator(at: root.appendingPathComponent("Sources/Regista"), includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    #expect(!sources.isEmpty)
    for f in sources {
        let text = try String(contentsOf: f, encoding: .utf8)
        for word in ["EffectsStudio", "StudioMode", "openStudio", "BrandKitSheet", "BrandKitStore().save", "BrandKitStore().delete", "BrandKitStore().setLogo",
                     "BrandKitStore().setFont", "BrandKitStore().importKit", "BrandKitStore().export", "watermark"] {
            #expect(!text.contains(word), "\(f.lastPathComponent) still has \(word)")
        }
    }
    let shots = try String(contentsOf: root.appendingPathComponent("scripts/ui-shots.sh"), encoding: .utf8)
    for name in ["effects-filters", "effects-adjust", "effects-effects", "effects-styles", "brandkits", "brandkit-editor", "brand-inspector"] {
        #expect(!shots.contains(name + " "), "scripts/ui-shots.sh still renders \(name)")
    }
    for name in Navigation.GraphicsSection.allCases.map({ "graphics-\($0.rawValue)" }) + ["brand-picker", "settings-brand"] {
        #expect(shots.contains(name), "scripts/ui-shots.sh renders \(name)")
    }
}

/// #22: follow-face and follow-hand-object are greyed with the reason instead of failing in the engine — first a placed
/// overlay must be selected (the follower), then the video under it needs its face / hand track, which the row's link
/// makes with a valid command; once tracked, the item can run.
@Test func followItemsAreGreyedWithWhatTheyNeedFirst() throws {
    let e = try footageEngine()
    let face = try #require(EffectsCatalog.named("follow-face")), hand = try #require(EffectsCatalog.named("follow-hand-object"))
    var project = try #require(e.project)
    for item in [face, hand] {
        #expect(GraphicsCatalog.followNeed(item, project: project, selection: []) == .follower)
        #expect(GraphicsCatalog.unavailable(item, project: project, blender: true, selection: []) != nil)
    }
    // The main video clip itself fills the frame: it cannot follow.
    let main = try #require(project.tracks.first { $0.kind == .video }?.clips.first?.id)
    #expect(GraphicsCatalog.followNeed(face, project: project, selection: [main]) == .follower)
    // A sticker placed the panel's way is a follower.
    let sticker = try #require(EffectsCatalog.items.first { $0.command == "sticker.add" })
    let before = Set(project.tracks.flatMap(\.clips).map(\.id))
    let (command, params) = try #require(GraphicsActions.command(sticker.id, project: project, at: 1))
    try e.execute(command, params: params)
    project = try #require(e.project)
    let follower = try #require(project.tracks.flatMap(\.clips).map(\.id).first { !before.contains($0) })
    let commands = Dictionary(uniqueKeysWithValues: RegistaCore.Commands.all.map { ($0.id, $0) })
    for (item, expected) in [(face, "faces.track"), (hand, "hands.track")] {
        guard case .track(let c, let p)? = GraphicsCatalog.followNeed(item, project: project, selection: [follower]) else {
            Issue.record("\(item.id): no track step"); continue
        }
        #expect(c == expected)
        let descriptor = try #require(commands[c]).descriptor
        #expect(throws: Never.self) { _ = try CommandParams(validating: p, for: descriptor) }
        #expect(GraphicsCatalog.unavailable(item, project: project, blender: true, selection: [follower]) != nil)
    }
    // Once the face is tracked, follow-face can run.
    guard case .track(let c, let p)? = GraphicsCatalog.followNeed(face, project: project, selection: [follower]) else { return }
    try e.execute(c, params: p)
    project = try #require(e.project)
    #expect(GraphicsCatalog.followNeed(face, project: project, selection: [follower]) == nil)
    #expect(GraphicsCatalog.unavailable(face, project: project, blender: true, selection: [follower]) == nil)
}

// #16: by hand, the Grafica panel's Applica uses motion.add's default place, so a template added with a click lands off
// the face. A real click on the real panel; the footage is the synthetic head with its face track, cropped so the face
// sits on the right third at the height of the top cards (where stat-card goes by default).
extension MouseSuites {
@Suite(.serialized) @MainActor struct MotionFaceMouseTests {
    @Test func aTemplateAddedWithAClickLandsOffTheFace() async throws {
        MotionLibrary.registerAll()
        let app = try await AppRig(project: "empty")
        defer { app.close() }
        let dir = rigTempDir("faceclear")
        let head = try await app.store.perform("media.synthesize", ["path": .string(dir.appendingPathComponent("head.mov").path), "duration": 4, "faces": true])
        let asset = try #require(head.value(at: "asset.id")?.stringValue)
        let v = try #require(try await app.store.perform("track.add", ["kind": "video"]).value(at: "track.id")?.stringValue)
        try await app.store.perform("timeline.place", ["assetId": .string(asset), "trackId": .string(v), "sourceIn": 0, "sourceOut": 4])
        let clip = try #require(app.store.project?.tracks.first { $0.id == v }?.clips.first?.id)
        try await app.store.perform("clip.set", ["clipId": .string(clip), "crop": [720, 1280, 60, 466]])
        var nav = Navigation(activity: .graphics, rightTab: .inspector)
        nav.graphicsSection = .motion
        app.hostEditor(nav)
        GraphicsState.shared.motionItem = "stat-card"   // its form open, as a click on its tile opens it
        defer { GraphicsState.shared.motionItem = nil }
        await app.settle()
        let before = app.clips.filter { $0.motion != nil }.count
        let apply = try #require(app.rig.elements().first { $0.isControl && $0.visible && $0.name == "Applica" }, "no Applica")
        app.rig.click(apply.centre)
        await app.settle()
        let added = app.clips.filter { $0.motion?.template == "stat-card" }
        #expect(added.count == before + 1, "the click added \(added.count - before) templates")
        // Mirrored to the left: the default right-hand place is on the face.
        #expect(added.last?.motion?.fields["position"] == [290, 540], "\(String(describing: added.last?.motion?.fields["position"]))")
        #expect(app.rig.elements().contains { $0.isControl && $0.visible && $0.name == "Applica" })   // still there
    }
}
}

// #76: Grafica's sections shared one scroll position, so Logo opened scrolled as far as Effetti was, its switch above
// the top edge. Each section opens at its top.
extension MouseSuites {
@Suite(.serialized) @MainActor struct GraphicsSectionScrollMouseTests {
    /// #132: the line under the list says what a click does on the tab on screen: the click-or-drag sentence on Filtri,
    /// Regola, Effetti and Motion, the style's Applica on Stili, the logo's controls and motions on Logo — never another
    /// tab's. Each tab is opened by a click on its chip.
    @Test(arguments: ["it", "en", "fr", "pt"])
    func eachTabShowsItsOwnFooter(_ language: String) async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .graphics, rightTab: .inspector)
        nav.graphicsSection = .filters
        app.hostEditor(nav, language: language)
        await app.settle()
        let footers = Set(Navigation.GraphicsSection.allCases.map { GraphicsPanel.footer($0) })
        #expect(footers.count == 3, "\(language): \(footers)")
        let snapshots = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"]
        for section in Navigation.GraphicsSection.allCases.reversed() {
            let title = loc(GraphicsCatalog.title(section))
            let chip = try #require(app.rig.controls().first { $0.visible && ($0.label == title || $0.title == title) }, "\(language): no chip «\(title)»")
            app.rig.click(chip.centre)
            await app.settle()
            #expect(app.store.nav.graphicsSection == section, "\(language): the chip «\(title)» opened \(app.store.nav.graphicsSection)")
            let shown = app.rig.elements().filter { $0.visible && $0.role == "AXStaticText" && footers.contains($0.value) }.map(\.value)
            #expect(shown == [GraphicsPanel.footer(section)], "\(language) \(section): the footer reads \(shown)")
            if let snapshots, [.styles, .logo, .effects].contains(section) {
                try? app.snapshot(to: URL(fileURLWithPath: snapshots).appendingPathComponent("graphics-footer-\(section.rawValue)-\(language).png"))
            }
        }
        #expect(GraphicsPanel.footer(.styles).contains(loc("Applica")) && GraphicsPanel.footer(.logo).contains(loc("Sting finale")),
                "\(language): the footers do not name the button and the motion as the tab shows them")
    }

    @Test func aSectionOpensAtItsTop() async throws {
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .graphics, rightTab: .inspector))
        await app.settle()
        // Effetti scrolled well down, as a person does to reach Titolo and Etichetta.
        for _ in 0..<12 { _ = app.rig.scrollContent(at: CGPoint(x: 200, y: 600), by: 120); await app.idle(0.05) }
        let switchInView = {
            app.rig.elements().contains { $0.isControl && $0.visible && $0.label.hasPrefix("Logo nel video") && $0.clip.insetBy(dx: -1, dy: -1).contains($0.frame) }
        }
        #expect(!switchInView())
        let chip = try #require(app.rig.elements().first { $0.isControl && $0.visible && $0.title == "Logo" || $0.isControl && $0.visible && $0.label == "Logo" }, "no Logo chip")
        app.rig.click(chip.centre)
        await app.settle()
        #expect(app.store.nav.graphicsSection == .logo, "the chip opened \(app.store.nav.graphicsSection)")
        #expect(switchInView(), "Logo opened without «Logo nel video» in view: \(app.rig.elements().filter { $0.label.hasPrefix("Logo nel video") }.map { "\($0.frame) in \($0.clip)" })")
    }
}
}
