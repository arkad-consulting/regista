import AppKit
import RegistaCore
import RegistaEngines
import SwiftUI
import Testing
@testable import Regista

// The defects journey 14 left open in Settings › Brand kit and in the window's use of a kit, each driven by the mouse on
// the real views, in the test process's scratch kit folder (never the owner's kits).

extension MouseSuites {
@Suite(.serialized) @MainActor struct BrandKitDefectsTests {
    /// #99: «Nuovo kit» makes a kit with no logo of another brand (each logo row reads «Nessun logo»), and on a project
    /// with that kit the logo switch and the logo animations say, in the window's language, that the kit has no logo yet;
    /// a click on the switch adds nothing.
    @Test func aNewKitHasNoLogoAndTheLogoControlSaysSo() async throws {
        let j = try await Journey("n23-new-kit-no-logo", project: "rich")
        defer { j.close() }
        let library = BrandKitLibrary.shared
        library.reload()
        await j.open(Navigation(activity: .graphics, rightTab: .inspector))
        let before = Set(library.kits.map(\.id))
        let s = await j.brandKitWindow()
        let plus = try #require(j.formControl(s, loc("Nuovo kit")), "no «Nuovo kit»: \(j.screen(s))")
        s.click(plus.centre)
        #expect(await j.until(5) { library.kits.contains { !before.contains($0.id) } }, "the click on «Nuovo kit» made no kit: \(j.screen(s))")
        let id = try #require(library.kits.first { !before.contains($0.id) }?.id)
        defer { _ = try? BrandKitStore().delete(id) }
        #expect(library.kits.count == before.count + 1, "one click made \(library.kits.count - before.count) kits")
        let kit = try #require(library.kit(id))
        #expect(kit.logo == nil && (kit.logos ?? [:]).isEmpty && kit.logoPath() == nil, "the new kit has logos: \(kit.logos ?? [:]), \(kit.logo ?? "-")")
        let assets = (try? FileManager.default.subpathsOfDirectory(atPath: BrandKitStore().folder(id).appendingPathComponent("assets").path)) ?? []
        #expect(!assets.contains { ["svg", "png"].contains(($0 as NSString).pathExtension.lowercased()) }, "the new kit's folder holds a logo file: \(assets)")
        #expect(kit.colors == BrandKit.arkad.colors, "the new kit does not start from the default kit's colours: \(kit.colors)")
        s.pump(0.3)
        let none = s.elements().filter { $0.role == "AXStaticText" && $0.value == loc("Nessun logo") }
        #expect(none.count == 3, "«Nessun logo» on \(none.count) rows: \(j.screen(s))")
        _ = s.scrollContent(at: CGPoint(x: 460, y: 300), by: 700)
        s.pump(0.3)
        j.shot(s, "settings-it")
        s.close()

        // The project takes the kit; Grafica › Logo.
        _ = try await j.store.perform("brandkit.apply", ["kit": .string(id)])
        await j.app.settle()
        for language in ["it", "fr"] {
            j.language = language
            await j.open(Navigation(activity: .graphics, rightTab: .inspector))
            try await j.tap("Logo")
            await j.app.idle(0.3)
            let sentence = StepError.noLogoLine(kit.name)
            #expect(sentence.contains(kit.name) && sentence != "Il kit «%@» non ha ancora un logo: sceglilo in Impostazioni › Brand kit.")
            #expect(j.shows(sentence), "\(language): the logo section does not say «\(sentence)»: \(j.screen())")
            let logoSwitch = try #require(j.rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix(loc("Logo nel video")) },
                                          "\(language): no «Logo nel video»: \(j.screen())")
            j.rig.click(logoSwitch.centre)
            await j.app.settle()
            #expect(j.store.project?.tracks.allSatisfy { $0.role != "logo" || $0.clips.isEmpty } == true, "\(language): the switch put a logo in")
            #expect(j.rig.elements().contains { $0.isControl && $0.visible && $0.label.hasPrefix(loc("Logo nel video")) }, "\(language): the switch is gone")
            // The logo animations (a sting) give the same reason.
            if let sting = EffectsCatalog.named("logo-sting") {
                #expect(GraphicsCatalog.unavailable(sting, project: j.store.project, blender: false) == sentence)
            }
            j.step("\(language): Grafica › Logo with a kit made by «Nuovo kit»", sees: "«\(sentence)»; the switch adds nothing")
        }
        j.language = "it"
        let settingsFr = MouseRig(BrandKitSettings(demo: false).environmentObject(j.store)
                                    .frame(width: SettingsView.size.width, height: SettingsView.size.height)
                                    .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)),
                                  size: SettingsView.size, language: "fr")
        settingsFr.pump(0.4)
        _ = settingsFr.scrollContent(at: CGPoint(x: 460, y: 300), by: 700)
        settingsFr.pump(0.3)
        j.shot(settingsFr, "settings-fr")
        settingsFr.close()
    }

    /// #97: with a kit applied, Esporta's «Controlli» list has a row «Marca» that counts the titles outside the kit's
    /// colours; a click on it selects the first one named and moves the playhead to it, once, and the row stays. Without
    /// a title outside the kit it is a tick with the kit's name.
    @Test func theBrandRowNamesATitleOutsideTheKitAndAClickGoesToIt() async throws {
        let j = try await Journey("n23-brand-row", project: "rich")
        defer { j.close() }
        _ = try await j.store.perform("brandkit.apply", ["kit": "cafe-atelier"])
        // The reel's own titles go, so the one in green is the only one outside the kit.
        let titles = j.app.clips.filter { $0.title != nil }.map { JSONValue.string($0.id) }
        if !titles.isEmpty { _ = try await j.store.perform("timeline.delete", ["clipIds": .array(titles)]) }
        let kit = try #require(j.store.project?.brand)
        for language in ["it", "fr"] {
            j.language = language
            await j.open(Navigation(activity: .export, rightTab: .inspector))
            await j.app.idle(0.4)
            func brandRow() -> RigElement? {
                j.rig.elements().first { $0.visible && ($0.role == "AXStaticText" && $0.value == loc("Marca") || $0.isControl && $0.label.hasPrefix(loc("Marca"))) }
            }
            if !kit.offKitTitles(in: j.store.project!).isEmpty { Issue.record("\(language): titles outside the kit before the green one: \(kit.offKitTitles(in: j.store.project!))") }
            _ = await j.reveal(loc("Marca"), at: CGPoint(x: 200, y: 500))
            #expect(brandRow() != nil && j.shows(kit.name), "\(language): no tick «Marca» with the kit's name: \(j.screen())")
            j.step("\(language): Esporta with the kit applied, no title outside its colours", sees: "«\(loc("Marca"))» \(kit.name), a tick")

            let green = try await j.store.perform("title.add", ["text": "FUORI MARCA", "start": 2, "duration": 2, "color": "#00FF00"])
            let greenID = try #require(green.value(at: "clip.id")?.stringValue)
            await j.app.settle()
            await j.app.idle(0.3)
            let count = loc("1 titolo fuori dai colori del kit")
            #expect(j.shows(count), "\(language): the row does not say «\(count)»: \(j.screen())")
            let row = try #require(j.rig.elements().first { $0.isControl && $0.visible && ($0.label.contains(count) || $0.label.hasPrefix(loc("Marca"))) },
                                   "\(language): the row is not a control: \(j.screen())")
            j.store.selection = []
            j.store.preview.seek(0)
            await j.app.settle()
            let commands = j.store.activity.count
            j.rig.click(row.centre)
            await j.app.settle()
            #expect(j.store.selection == [greenID], "\(language): the click selected \(j.store.selection)")
            #expect(abs(j.store.preview.playhead.time - 2) < 0.05, "\(language): the playhead is at \(j.store.preview.playhead.time)")
            #expect(j.store.activity.count == commands, "\(language): the click ran \(j.app.commands(since: commands))")
            #expect(j.rig.elements().contains { $0.isControl && $0.visible && ($0.label.contains(count) || $0.label.hasPrefix(loc("Marca"))) },
                    "\(language): the row is gone after the click")
            #expect(j.rig.elements().contains { $0.isControl && $0.visible && $0.name == loc("Esporta video…") || $0.name == loc("Esporta lo stesso") },
                    "\(language): the warning blocks the export: \(j.screen())")
            j.step("\(language): a title «FUORI MARCA» in #00FF00; a click on the row", sees: "«\(count)»; the title selected, the playhead at 2 s")
            _ = try await j.store.perform("timeline.delete", ["clipIds": [.string(greenID)]])
        }
    }

    /// #98: a project keeps its copy of the kit. The kit changed after it was applied: the Marca tab reads «· copia del
    /// progetto», its popover says so and «Aggiorna dal kit» applies the kit again (one command, one undo step; ⌘Z brings
    /// the old colour back); a kit changed and put back is not different. The kit deleted: «· kit eliminato», the popover
    /// says the project keeps its copy, no «Aggiorna»; Esporta names the kit the same way.
    @Test func aProjectKeepsItsCopyOfTheKitAndSaysSo() async throws {
        let j = try await Journey("n23-kit-copy", project: "rich")
        defer { j.close() }
        let titles = j.app.clips.filter { $0.title != nil }.map { JSONValue.string($0.id) }
        if !titles.isEmpty { _ = try await j.store.perform("timeline.delete", ["clipIds": .array(titles)]) }
        let marcaTip = "Marca del progetto: il brand kit di sottotitoli, titoli e logo"
        for language in ["it", "fr"] {
            j.language = language
            let id = "n23-copia-\(language)", name = "Copia \(language.uppercased())"
            _ = try? BrandKitStore().delete(id)
            _ = try await j.store.perform("brandkit.create", ["name": .string(name), "id": .string(id), "from": "cafe-atelier"])
            _ = try await j.store.perform("brandkit.apply", ["kit": .string(id)])
            await j.open(Navigation(activity: .graphics, rightTab: .inspector))
            let old = try #require(j.store.project?.brand?.colors["primary"])
            let tab = { (label: String) in String(format: loc("Marca: %@"), label) }
            /// The Marca tab reads `text` (its words are its accessibility value: its label is its tooltip).
            func reads(_ text: String) -> Bool { j.rig.elements().contains { $0.isControl && $0.label.hasPrefix(loc(marcaTip)) && $0.value == text } }
            let copyLabel = String(format: loc("%@ · copia del progetto"), name), goneLabel = String(format: loc("%@ · kit eliminato"), name)
            #expect(reads(tab(name)), "\(language): the tab does not read «\(tab(name))»: \(j.screen())")

            // Changed and put back: not different.
            _ = try await j.store.perform("brandkit.update", ["kit": .string(id), "colors": ["primary": "#2E7D32"]])
            await j.app.settle()
            #expect(await j.until(3) { reads(tab(copyLabel)) }, "\(language): the tab does not read «\(tab(copyLabel))»: \(j.screen())")
            j.step("\(language): the kit changed after it was applied", sees: "«\(tab(copyLabel))»")
            _ = try await j.store.perform("brandkit.update", ["kit": .string(id), "colors": ["primary": .string(old)]])
            await j.app.settle()
            #expect(await j.until(3) { reads(tab(name)) }, "\(language): a kit put back still reads as changed: \(j.screen())")
            _ = try await j.store.perform("brandkit.update", ["kit": .string(id), "colors": ["primary": "#2E7D32"]])
            await j.app.settle()

            // The popover: the line and «Aggiorna dal kit».
            try await j.tap(marcaTip)
            let picker = try #require(await j.popover(), "\(language): Marca opened no picker")
            let line = loc("Il kit è cambiato dopo che l'hai applicato a questo progetto.")
            #expect(!picker.elements(containing: line).isEmpty, "\(language): the popover does not say «\(line)»: \(j.screen(picker))")
            j.shot(picker, "\(language)-changed")
            let update = try #require(j.control("Aggiorna dal kit", in: picker), "\(language): no «Aggiorna dal kit»: \(j.screen(picker))")
            let commands = j.store.activity.count
            picker.click(update.centre)
            await j.app.settle()
            #expect(j.app.commands(since: commands) == ["brandkit.apply"], "\(language): the click ran \(j.app.commands(since: commands))")
            #expect(j.store.project?.brand?.colors["primary"] == "#2E7D32", "\(language): the project has \(j.store.project?.brand?.colors["primary"] ?? "?")")
            j.store.showBrandKits = false
            await j.app.idle(0.4)
            #expect(await j.until(3) { reads(tab(name)) }, "\(language): after «Aggiorna dal kit» the tab reads: \(j.screen())")
            j.step("\(language): the kit changed; Marca › Aggiorna dal kit", sees: "«\(tab(copyLabel))», then «\(tab(name))» with the kit's new colour")
            j.store.undo()
            await j.app.settle()
            #expect(j.store.project?.brand?.colors["primary"] == old, "\(language): ⌘Z left \(j.store.project?.brand?.colors["primary"] ?? "?")")

            // Deleted: the project keeps its copy and says so; no «Aggiorna».
            _ = try await j.store.perform("brandkit.delete", ["kit": .string(id)])
            await j.app.settle()
            #expect(await j.until(3) { reads(tab(goneLabel)) }, "\(language): the tab does not read «\(tab(goneLabel))»: \(j.screen())")
            #expect(j.store.project?.brand?.name == name && j.store.project?.brand?.colors["primary"] == old, "\(language): the project lost its copy")
            try await j.tap(marcaTip)
            let picker2 = try #require(await j.popover(), "\(language): Marca opened no picker")
            // The copy of a kit made from Café Atelier holds its files (system fonts, logos Regista ships): the video does not change (#101).
            let gone = String(format: loc("Il kit «%@» è stato eliminato: il progetto tiene la sua copia e il video non cambia."), name)
            #expect(!picker2.elements(containing: gone).isEmpty, "\(language): the popover does not say «\(gone)»: \(j.screen(picker2))")
            #expect(j.control("Aggiorna dal kit", in: picker2) == nil, "\(language): «Aggiorna dal kit» for a deleted kit")
            j.shot(picker2, "\(language)-deleted")
            j.store.showBrandKits = false
            await j.app.idle(0.4)
            try await j.tap("Esporta")
            await j.app.idle(0.4)
            _ = await j.reveal(loc("Marca"), at: CGPoint(x: 200, y: 500))
            #expect(j.shows(goneLabel), "\(language): Esporta does not name the kit «\(goneLabel)»: \(j.screen())")
            j.step("\(language): the kit deleted; Esporta", sees: "«\(tab(goneLabel))»; «\(gone)»; Esporta «\(goneLabel)»")
        }
        for language in ["it", "en", "fr", "pt"] {
            let table = MouseRig.table(language)
            for key in ["%@ · copia del progetto", "%@ · kit eliminato", "Il kit è cambiato dopo che l'hai applicato a questo progetto.", "Aggiorna dal kit",
                        "Il kit «%@» è stato eliminato: il progetto tiene la sua copia dei colori. Il logo e i caratteri del kit possono mancare nel video.", "Il kit «%@» è stato eliminato: il progetto tiene la sua copia e il video non cambia."] {
                let text = table.localizedString(forKey: key, value: "", table: nil)
                #expect(!text.isEmpty && (language == "it" || text != key), "\(language): «\(key)» has no text")
            }
        }
    }

    /// #101: the project's copy of a kit holds the kit's own files and still reads as the kit (the copied file is compared
    /// as the kit's file it came from); a change of the kit reads as one. Deleted, the kit leaves the video as it was:
    /// «il video non cambia» — except for a copy that still points at the kit's files (a project the kit was applied to
    /// before its files were copied), which keeps the line that the logo and fonts may be missing.
    @Test func aCopyHoldingItsFilesIsTheKitAndADeletedKitLeavesTheVideo() throws {
        _ = rigKitsDirectory
        let dir = rigTempDir("n24-copy-status")
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = Engine(services: .live())
        try e.execute("project.new", params: ["name": "copy-status", "directory": .string(dir.path)])
        let font = dir.appendingPathComponent("StatoDisplay.ttf")
        try FileManager.default.copyItem(atPath: BrandKit.bundled("Fonts/Fraunces.ttf"), toPath: font.path)
        let id = "n24-stato"
        _ = try? BrandKitStore().delete(id)
        defer { _ = try? BrandKitStore().delete(id) }
        try e.execute("brandkit.create", params: ["name": "Stato", "id": .string(id)])
        try e.execute("brandkit.setFont", params: ["kit": .string(id), "path": .string(font.path), "role": "display"])
        try e.execute("brandkit.apply", params: ["kit": .string(id)])
        let library = BrandKitLibrary()
        let copy = try #require(e.project?.brand)
        // A copy as projects kept it before the kit's files were copied: the kit's own paths.
        let legacy = try #require(library.kit(id)).absolutized()
        #expect(copy.fonts["display"] != legacy.fonts["display"], "the copy still refers to the kit's font file")
        #expect(library.status(of: copy) == .same, "a copy holding the kit's files reads as changed")
        #expect(library.status(of: legacy) == .same)
        try e.execute("brandkit.update", params: ["kit": .string(id), "colors": ["primary": "#2E7D32"]])
        library.reload()
        #expect(library.status(of: copy) == .changed, "a changed kit reads as the copy")
        try e.execute("brandkit.delete", params: ["kit": .string(id)])
        library.reload()
        #expect(library.status(of: copy) == .deleted, "the copy holding its files: \(copy.missingFiles)")
        #expect(library.status(of: legacy) == .deletedFilesMissing, "the copy pointing at the deleted kit's files")
        #expect(library.label(copy) == String(format: loc("%@ · kit eliminato"), "Stato") && library.label(legacy) == library.label(copy))
    }

    /// Follow-up of #96: a colour's code typed and then left — by a click on another field, or by Tab — is committed as
    /// Return commits it: a valid code is one brandkit.update; an invalid one puts the kit's code back and says why.
    @Test func aTypedColourCodeIsKeptWhenTheFieldIsLeft() async throws {
        let j = try await Journey("n23-hex-leave", project: "rich")
        defer { j.close() }
        await j.open(Navigation(activity: .graphics, rightTab: .inspector))
        let id = "n23-codice"
        _ = try? BrandKitStore().delete(id)
        _ = try await j.store.perform("brandkit.create", ["name": "Codice", "id": .string(id), "from": "cafe-atelier"])
        defer { _ = try? BrandKitStore().delete(id) }
        _ = try await j.store.perform("brandkit.apply", ["kit": .string(id)])
        let library = BrandKitLibrary.shared
        library.reload()
        for language in ["it", "fr"] {
            j.language = language
            let s = await j.brandKitWindow()
            defer { s.close() }
            func codeField(_ role: String) -> RigElement? {
                let label = loc(BrandKitSettings.roleNames.first { $0.0 == role }!.1)
                return s.elements().first { $0.role == "AXTextField" && $0.label.contains(String(format: loc("%@, codice esadecimale"), label)) }
            }
            /// Types in a field that has the keyboard (focused through accessibility, its text selected), no Return.
            func type(_ field: RigElement, _ text: String) {
                s.takeKey()
                if let v = (field.ref as? NSView) ?? (field.ref as? NSCell)?.controlView { s.window.makeFirstResponder(v) }
                s.pump(0.1)
                (s.window.firstResponder as? NSTextView)?.selectAll(nil)
                s.type(text)
                s.pump(0.2)
            }
            let primary = try #require(codeField("primary"), "\(language): no code field for the primary colour: \(j.screen(s))")
            let code = language == "it" ? "#1A6B3C" : "#5B2A86"
            type(primary, code)
            #expect(library.kit(id)?.colors["primary"] != code, "\(language): the code was committed before the field was left")
            // A click on another field (the kit's name).
            let commands = j.store.activity.count
            let name = try #require(s.elements().first { $0.visible && $0.role == "AXTextField" && $0.value == "Codice" }, "\(language): no name field")
            s.click(name.centre)
            s.pump(0.2)
            await j.app.settle()
            #expect(await j.until(5) { library.kit(id)?.colors["primary"] == code }, "\(language): leaving the field by a click kept \(library.kit(id)?.colors["primary"] ?? "?")")
            #expect(j.app.commands(since: commands) == ["brandkit.update"], "\(language): leaving the field ran \(j.app.commands(since: commands))")
            #expect(codeField("primary")?.value == code, "\(language): the field reads \(codeField("primary")?.value ?? "?")")

            // An invalid code left by Tab: the kit's code back, the red line.
            let accent = try #require(codeField("accent"))
            let before = library.kit(id)?.colors["accent"]
            let tabCommands = j.store.activity.count
            type(accent, "verde")
            s.key(.tab)
            s.pump(0.3)
            await j.app.settle()
            let why = String(format: loc("«%@» non è un colore: scrivilo come #RRGGBB."), "verde")
            #expect(await j.until(3) { codeField("accent")?.value == before }, "\(language): the field reads «\(codeField("accent")?.value ?? "?")», not the kit's \(before ?? "?")")
            // The red line is at the foot of the form.
            _ = s.scrollContent(at: CGPoint(x: 460, y: 300), by: 2000)
            s.pump(0.3)
            #expect(await j.until(3) { !s.elements(containing: why).isEmpty }, "\(language): no «\(why)»: \(j.screen(s))")
            #expect(library.kit(id)?.colors["accent"] == before && j.app.commands(since: tabCommands).isEmpty, "\(language): an invalid code changed the kit")
            j.shot(s, "\(language)-left")
        }
    }
}
}
