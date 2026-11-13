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
