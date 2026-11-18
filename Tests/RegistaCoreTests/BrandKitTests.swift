import Foundation
import Testing
@testable import RegistaCore

/// Brand kit commands write to `$REGISTA_BRANDKITS`: the test process's scratch kits folder (TestSupport).
private var kitsDirectory: URL { testKitsDirectory }

/// Writes empty files; SVGs "rasterise" to width × width/4.
private final class SVGImages: ImageToolkit {
    func writePreview(of image: URL, maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int) { (maxWidth, maxHeight) }
    func writeContactSheet(_ images: [URL], labels: [String], maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int) { (maxWidth, maxHeight) }
    func rasterizeSVG(_ svg: URL, width: Int, to output: URL) throws -> (width: Int, height: Int) {
        FileManager.default.createFile(atPath: output.path, contents: Data())
        return (width, width / 4)
    }
}

/// A 3.7 s edit with captions (keyword TRE) on the fake engines, able to import SVG logos.
private func captionedEngine() throws -> Engine {
    var fakes = FakeServices().make()
    fakes.images = SVGImages()
    let e = Engine(prober: FakeProber(), services: fakes)
    try e.execute("project.new", params: ["name": "brand", "directory": .string(tempDir().path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("transcript.run", params: ["assetId": "a1"])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0.9, "sourceOut": 4.6])
    try e.execute("script.prepare", params: ["text": "Uno due tre quattro.", "keywords": ["tre"]])
    try e.execute("captions.generate")
    return e
}

@Test func kitJSONRoundTripsWithEveryField() throws {
    var kit = BrandKit.cafeAtelier
    kit.watermark = true
    kit.logoPlacement = LogoPlacement(corner: "bottomRight", width: 140, margin: 30, opacity: 0.8, animation: "pop", variant: "onLight")
    kit.captionStyle = ["keywordBoxColor": "accent", "font": "AvenirNext-Heavy"]
    let data = try JSONEncoder().encode(kit)
    #expect(try JSONDecoder().decode(BrandKit.self, from: data) == kit)
    #expect(!String(decoding: data, as: UTF8.self).contains("directory"))
    // Stored as a folder: kit.json + assets copied in, paths relative, loads back with its folder.
    let store = BrandKitStore(directory: tempDir())
    let saved = try store.save(kit)
    let json = try String(contentsOf: store.folder("cafe-atelier").appendingPathComponent("kit.json"), encoding: .utf8)
    #expect(json.contains("\"assets/cafe-atelier-placeholder-on-dark.svg\"") && !json.contains("bundle:"))
    let loaded = try BrandKit.load(store.folder("cafe-atelier").path)
    #expect(loaded == saved && loaded.directory?.lastPathComponent == "cafe-atelier")
    #expect(FileManager.default.fileExists(atPath: try #require(loaded.logoPath("onDark"))))
    #expect(BrandKit.all(userDirectory: store.directory)["cafe-atelier"]?.watermark == true)   // the user kit replaces the built-in
    #expect(Set(BrandKit.all(userDirectory: tempDir()).keys) == ["arkad", "wesites", "cafe-atelier"])
}

@Test func kitsExportAsOneFileAndImportOnAnotherMac() throws {
    let src = tempDir()
    let font = src.appendingPathComponent("Brand-Display.ttf")
    try Data(contentsOf: URL(fileURLWithPath: BrandKit.bundled("Fonts/Fraunces.ttf"))).write(to: font)
    let svg = src.appendingPathComponent("logo.svg")
    try ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" fill="#C94963"/></svg>"##.write(to: svg, atomically: true, encoding: .utf8)
    let mine = BrandKitStore(directory: tempDir())
    var kit = BrandKit.arkad
    kit.id = "studio"; kit.name = "Studio"
    kit = try mine.save(kit)
    kit = try mine.setFont(kit, file: font, role: "display")
    kit = try mine.setLogo(kit, file: svg, variant: "onDark")
    #expect(kit.fonts["display"] == "assets/fonts/Brand-Display.ttf" && kit.logos?["onDark"] == "assets/logo-onDark.svg")
    let file = try mine.export(kit, to: tempDir().appendingPathComponent("studio"))
    #expect(file.pathExtension == "registakit" && FileManager.default.fileExists(atPath: file.path))

    let partner = BrandKitStore(directory: tempDir())
    let imported = try partner.importKit(from: file)
    #expect(imported.id == "studio" && imported.name == "Studio")
    #expect(imported.font("display").hasPrefix(partner.folder("studio").path))                // the font travelled
    #expect(imported.fontReport().allSatisfy { !$0.fallback })
    #expect(try #require(imported.logoPath()).hasPrefix(partner.folder("studio").path))
    #expect(FileManager.default.fileExists(atPath: partner.folder("studio").appendingPathComponent("assets/fonts/GeistMono.ttf").path))   // built-in fonts copied too
    // Importing again keeps both; replace overwrites.
    #expect(try partner.importKit(from: file).id == "studio-2")
    #expect(try partner.importKit(from: file, replace: true).id == "studio")
    // Not a kit.
    let junk = tempDir().appendingPathComponent("junk.registakit")
    try Data("nope".utf8).write(to: junk)
    #expect(throws: (any Error).self) { try partner.importKit(from: junk) }
}

@Test func missingFontFilesFallBackToSystemFontsByRole() {
    var kit = BrandKit.wesites
    kit.fonts["display"] = "/nonexistent/Display.woff2"
    kit.fonts["mono"] = "/nonexistent/Mono.ttf"
    #expect(kit.font("display") == "Georgia" && kit.font("mono") == "Menlo-Regular")
    #expect(kit.resolve(kit.titles["hook"]!).font == "Georgia")
    let report = Dictionary(uniqueKeysWithValues: kit.fontReport().map { ($0.role, $0) })
    #expect(report["display"]?.fallback == true && report["mono"]?.fallback == true)
    #expect(BrandKit.cafeAtelier.fontReport().allSatisfy { !$0.fallback })                    // names, not files
    #expect(BrandKit.arkad.fontReport().allSatisfy { !$0.fallback })                           // bundled with Regista
}

@Test func applyingAKitRecoloursCaptionsRestylesPresetTitlesAndSwapsTheLogo() throws {
    _ = kitsDirectory
    let e = try captionedEngine()
    try e.execute("brandkit.apply", params: ["kit": "wesites"])
    var style = try #require(e.project!.tracks.first { $0.kind == .caption }?.captions?.style)
    #expect(style.keywordBoxColor == "#FF2D6F" && style.keywordTextColor == "#FFFFFF" && style.font == "Impact")
    try e.execute("title.add", params: ["text": "Ciao", "start": 0, "preset": "hook"])
    try e.execute("title.add", params: ["text": "Mio", "start": 3, "preset": "kicker", "color": "#00FF00"])   // hand-styled: kept
    try e.execute("logo.add", params: ["path": .string(fakeMedia("mark.png"))])

    let r = try e.checkUndoRedo("brandkit.apply", ["kit": "cafe-atelier"])
    style = try #require(e.project!.tracks.first { $0.kind == .caption }?.captions?.style)
    // Recoloured only (#17): the kit's caption font override does not replace the font the captions already had.
    #expect(style.keywordBoxColor == "#D2603A" && style.keywordTextColor == "#FFFFFF" && style.font == "Impact")
    #expect(style.maxWords == CaptionStyle.talkingHeadV1.maxWords)
    let titles = e.project!.tracks.flatMap(\.clips).compactMap(\.title)
    let hook = try #require(titles.first { $0.text == "Ciao" })
    #expect(hook.font == "Georgia" && hook.background?.color == "#F5EFE4" && hook.color == "#2B2018")
    #expect(titles.first { $0.text == "Mio" }?.color == "#00FF00")
    #expect(r["titlesRestyled"] == 1 && r["logos"] == 1)
    // The logo clip now shows the Café Atelier placeholder, still spanning the timeline.
    let logoTrack = try #require(e.project!.tracks.first { $0.role == "logo" })
    #expect(logoTrack.clips.count == 1 && logoTrack.name == "Logo")
    #expect(e.project!.asset(logoTrack.clips[0].assetID)?.path.contains("cafe-atelier-placeholder") == true)

    // Arkad: gold box, ink text (onHighlight), restyled again.
    try e.execute("brandkit.apply", params: ["kit": "arkad"])
    style = e.project!.tracks.first { $0.kind == .caption }!.captions!.style
    #expect(style.keywordBoxColor == "#F4BD56" && style.keywordTextColor == "#070501")
    #expect(BrandKit.cafeAtelier.captionOverrides()["keywordBoxColor"] == "#D2603A")
    var noText = BrandKit.wesites; noText.colors["onHighlight"] = nil
    #expect(noText.captionOverrides()["keywordTextColor"] == .string(BrandKit.readable(on: "#FF2D6F", ink: "#141414")))
}

@Test func logoPlacementsStayInsideTheSafeZones() throws {
    for corner in LogoPlacement.corners {
        for width in [60.0, 200, 480, 1200] {
            for aspect in [0.5, 1, 3.75, 8] {
                let f = LogoPlacement(corner: corner, width: width).frame(aspect: aspect)
                let box = [f.x - f.width / 2, f.y - f.height / 2, f.width, f.height]
                let problems = LogoOverlay.safeZoneProblems(box, width: 1080, height: 1920)
                #expect(problems.isEmpty, "\(corner) \(width) \(aspect): \(problems)")
                #expect(abs(f.width / f.height - aspect) < 0.01)
            }
        }
    }
    // logo.add on a project: a box inside, defaults from the kit, whole timeline (the rule «logo only at the end» off).
    let e = try editingEngine()
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 10])
    try e.execute("brandkit.apply", params: ["kit": "arkad"])
    try e.execute("rules.set", params: ["kind": "talking-head-reel", "checks": ["logo-end": false]])
    defer { _ = try? e.execute("rules.reset", params: ["kind": "talking-head-reel"]) }
    let r = try e.checkUndoRedo("logo.add", ["path": .string(fakeMedia("logo.png")), "corner": "bottomRight"])
    #expect(r["insideSafeZone"] == true && r["timing"] == nil)
    let clip = try #require(e.project!.tracks.first { $0.role == "logo" }?.clips.first)
    #expect(clip.start == .zero && clip.end == t(10) && clip.keyframes?.first?.transform.opacity == 0)
    #expect(e.project!.tracks.firstIndex { $0.role == "logo" }! > e.project!.tracks.firstIndex { $0.kind == .video }!)
    // A logo motion from the effects gallery as the kit's animation.
    try e.execute("logo.add", params: ["path": .string(fakeMedia("logo2.png")), "replace": true, "animation": "pulse"])
    let pulsing = try #require(e.project!.tracks.first { $0.role == "logo" }?.clips)
    #expect(pulsing.count == 1 && pulsing[0].keyframes == LogoMotion.pulse.keyframes(rest: pulsing[0].transform!, duration: pulsing[0].duration))
    #expect(throws: CommandError.self) { try editingEngine().execute("logo.add", params: [:]) }   // no kit, no path
}

@Test func kitCommandsCreateUpdateExportImportAndDelete() throws {
    _ = kitsDirectory
    let e = Engine(prober: FakeProber())
    let c = try e.execute("brandkit.create", params: ["name": "Pâtisserie Lune", "from": "cafe-atelier", "colors": ["highlight": "#aa3355"],
                                                     "logoPlacement": ["corner": "topRight", "width": 160]])
    #expect(c["kit"]?["id"] == "patisserie-lune" && c["kit"]?["source"] == "user")
    #expect(c["kit"]?["caption"]?["keywordBoxColor"] == "#AA3355")
    #expect(throws: CommandError.self) { try e.execute("brandkit.create", params: ["name": "Pâtisserie Lune"]) }
    #expect(throws: CommandError.self) { try e.execute("brandkit.update", params: ["kit": "patisserie-lune", "colors": ["ink": "blue"]]) }
    let u = try e.execute("brandkit.update", params: ["kit": "patisserie-lune", "name": "Lune", "colors": ["accent": nil], "watermark": true])
    #expect(u["kit"]?["name"] == "Lune" && u["kit"]?["colors"]?["accent"] == nil && u["kit"]?["watermark"] == true)
    let out = tempDir()
    let x = try e.execute("brandkit.export", params: ["kit": "patisserie-lune", "path": .string(out.path)])
    let file = try #require(x["path"]?.stringValue)
    #expect(file.hasSuffix("patisserie-lune.registakit"))
    try e.execute("brandkit.delete", params: ["kit": "patisserie-lune"])
    #expect(BrandKit.all()["patisserie-lune"] == nil)
    let i = try e.execute("brandkit.import", params: ["path": .string(file)])
    #expect(i["kit"]?["name"] == "Lune")
    let list = try e.execute("brandkit.list")
    #expect(list["kits"]?.arrayValue?.compactMap { $0["id"]?.stringValue }.contains("patisserie-lune") == true)
    #expect(throws: CommandError.self) { try e.execute("brandkit.delete", params: ["kit": "arkad"]) }   // built-in
}

/// #99: a kit created without `from` (Settings' «Nuovo kit») has the default kit's colours, fonts and placement and no
/// logo of another brand; the logo commands on a project with it are refused, naming the kit. `from` still copies a kit
/// whole, logos included.
@Test func aNewKitStartsWithNoLogoAndTheLogoCommandsSaySo() throws {
    _ = kitsDirectory
    let e = try captionedEngine()
    let made = try e.execute("brandkit.create", params: ["name": "Senza Logo", "id": "senza-logo"])
    #expect(made["kit"]?["logos"] == .object([:]) && made["kit"]?["logo"] == .null, "\(made.text())")
    let kit = try #require(BrandKit.all()["senza-logo"])
    #expect(kit.colors == BrandKit.arkad.colors && kit.logoPlacement == BrandKit.arkad.logoPlacement && kit.fonts.keys == BrandKit.arkad.fonts.keys)
    #expect(kit.logoPath() == nil && BrandKit.logoVariants.allSatisfy { kit.logoPath($0) == nil })
    let copy = try e.execute("brandkit.create", params: ["name": "Copia Intera", "id": "copia-intera", "from": "arkad"])
    #expect(copy["kit"]?["logos"]?.objectValue?.count == 3, "\(copy.text())")

    try e.execute("brandkit.apply", params: ["kit": "senza-logo"])
    for (command, params) in [("logo.add", [:] as JSONValue), ("logo.add", ["variant": "mark"]), ("logo.animate", ["motion": "sting"])] {
        do {
            try e.execute(command, params: params)
            Issue.record("\(command) was not refused")
        } catch {
            #expect("\(error)".contains("kit \"Senza Logo\" has no logo yet"), "\(command): \(error)")
        }
    }
    #expect(e.project?.tracks.allSatisfy { $0.role != "logo" || $0.clips.isEmpty } == true)
    try e.execute("brandkit.delete", params: ["kit": "senza-logo"])
    try e.execute("brandkit.delete", params: ["kit": "copia-intera"])
}

/// #97: brandkit.check names a title whose text, box or highlight colour is none of the applied kit's colours, with its
/// clip and time; a title in the kit's colours (a hex of any role, or the role's name) is not named.
@Test func theKitCheckNamesATitleOutsideTheKitsColours() throws {
    _ = kitsDirectory
    let e = try captionedEngine()
    try e.execute("brandkit.apply", params: ["kit": "cafe-atelier"])
    #expect(BrandKit.cafeAtelier.colors.values.allSatisfy { $0.uppercased() != "#00FF00" })
    let green = try e.execute("title.add", params: ["text": "FUORI MARCA", "start": 1, "duration": 1, "color": "#00ff00"])
    let greenID = try #require(green.value(at: "clip.id")?.stringValue)
    let boxed = try e.execute("title.add", params: ["text": "SCATOLA", "start": 2, "duration": 1, "color": "#8A5A3C",
                                                    "background": "box", "backgroundColor": "#123456"])
    let boxedID = try #require(boxed.value(at: "clip.id")?.stringValue)
    try e.execute("title.add", params: ["text": "IN MARCA", "start": 0.5, "duration": 1, "color": "#F5EFE4"])
    let r = try e.execute("brandkit.check")
    #expect(r["pass"] == false)
    let named = r["titlesOutside"]?.arrayValue ?? []
    #expect(named.map { $0["clipId"]?.stringValue ?? "?" } == [greenID, boxedID], "\(r["titlesOutside"]?.text() ?? "none")")
    #expect(named.first?["time"] == 1 && named.first?["colors"] == ["#00FF00"] && named.last?["colors"] == ["#123456"])
    #expect(r["problems"]?.arrayValue?.contains { $0.stringValue?.contains(greenID) == true && $0.stringValue?.contains("1.00 s") == true } == true,
            "\(r["problems"]?.text() ?? "")")
    // The same check the window's Marca row reads.
    #expect(e.project?.brand?.offKitTitles(in: e.project!).map(\.clipID) == [greenID, boxedID])
}

/// #17: a caption style the user chose (an elegant serif) survives brandkit.apply; only its colours follow the kit.
@Test func applyingAKitKeepsTheCaptionStyleTheUserChose() throws {
    _ = kitsDirectory
    let e = try captionedEngine()
    try e.execute("captions.setStyle", params: ["style": "elegant-serif"])
    let chosen = try #require(e.project!.tracks.first { $0.kind == .caption }?.captions?.style)
    try e.execute("brandkit.apply", params: ["kit": "cafe-atelier"])
    let style = try #require(e.project!.tracks.first { $0.kind == .caption }?.captions?.style)
    #expect(style.font == chosen.font && style.fontSize == chosen.fontSize && style.reveal == chosen.reveal)
    #expect(style.id == chosen.id)
    #expect(style.keywordBoxColor == "#D2603A")
}

/// #3: a kit edit made through the command is one undo step that puts the kit folder back exactly; redo applies it
/// again; creating, deleting and replacing a logo undo the same way, with or without a project open.
@Test func kitEditsUndoAndRedoThroughTheHistory() throws {
    let store = BrandKitStore(directory: kitsDirectory)
    let e = Engine(prober: FakeProber())
    // No project open: a kit is still created and undone.
    try e.execute("brandkit.create", params: ["name": "Undo Kit", "id": "undo-kit", "from": "cafe-atelier"])
    #expect(FileManager.default.fileExists(atPath: store.folder("undo-kit").path))
    try e.execute("history.undo")
    #expect(!FileManager.default.fileExists(atPath: store.folder("undo-kit").path))
    try e.execute("history.redo")
    let created = try #require(try KitSnapshot.read(store.folder("undo-kit")))

    try e.execute("project.new", params: ["name": "kits", "directory": .string(tempDir().path)])
    try e.execute("brandkit.create", params: ["name": "Undo Kit 2", "id": "undo-kit-2", "from": "cafe-atelier"])
    let before = try #require(try KitSnapshot.read(store.folder("undo-kit-2")))
    let project = e.project
    let u = try e.execute("brandkit.update", params: ["kit": "undo-kit-2", "name": "Changed", "colors": ["highlight": "#112233"]])
    #expect(u["kit"]?["name"] == "Changed")
    #expect(BrandKit.all()["undo-kit-2"]?.colors["highlight"] == "#112233")
    #expect(e.project == project)                                  // the project did not change
    #expect(e.context.history.undoStack.last?.command == "brandkit.update")
    let r = try e.execute("history.undo")
    #expect(r["undone"] == "brandkit.update")
    #expect(try KitSnapshot.read(store.folder("undo-kit-2")) == before)
    #expect(BrandKit.all()["undo-kit-2"]?.name == "Undo Kit 2")
    try e.execute("history.redo")
    #expect(BrandKit.all()["undo-kit-2"]?.colors["highlight"] == "#112233")

    // A logo set and a kit deleted come back with undo.
    let logo = tempDir().appendingPathComponent("mark.svg")
    try Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'/>".utf8).write(to: logo)
    let beforeLogo = try KitSnapshot.read(store.folder("undo-kit-2"))
    try e.execute("brandkit.setLogo", params: ["kit": "undo-kit-2", "path": .string(logo.path), "variant": "mark"])
    #expect(try KitSnapshot.read(store.folder("undo-kit-2")) != beforeLogo)
    try e.execute("history.undo")
    #expect(try KitSnapshot.read(store.folder("undo-kit-2")) == beforeLogo)
    try e.execute("brandkit.delete", params: ["kit": "undo-kit"])
    #expect(BrandKit.all()["undo-kit"] == nil)
    try e.execute("history.undo")
    #expect(try KitSnapshot.read(store.folder("undo-kit")) == created)

    // A built-in edited gets a user copy; undo removes the copy and the built-in shows again.
    try e.execute("brandkit.update", params: ["kit": "cafe-atelier", "name": "Café edited"])
    #expect(BrandKit.all()["cafe-atelier"]?.name == "Café edited")
    try e.execute("history.undo")
    #expect(BrandKit.all()["cafe-atelier"]?.name == BrandKit.cafeAtelier.name)
    #expect(!FileManager.default.fileExists(atPath: store.folder("cafe-atelier").path))
}

