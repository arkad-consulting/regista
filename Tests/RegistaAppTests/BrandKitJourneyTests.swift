import AppKit
import RegistaCore
import RegistaMCP
import SwiftUI
import Testing
@testable import Regista

// Journey 14: a brand kit made by hand in Settings › Brand kit and used on an open reel, by clicks, in the test process's
// scratch kit folder (never the owner's kits): name, colours by their code fields (the colour wells are on the skip
// list), a font, logos for dark and light footage, the corner; applied from Marca; a title, a call to action and the logo
// added afterwards in its style, a title added before it; the kit's check; the kit changed while the project is open;
// exported and imported again; deleted while the project uses it; and the same kit through brandkit.list on the socket.

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct BrandKitJourneyTests {
    /// 14. A brand kit made by hand and used.
    @Test func aBrandKitIsMadeByHandAndUsed() async throws {
        let j = try await Journey("14-brand-kit-by-hand", project: "rich")
        defer { j.close() }
        try await j.brandKitByHand()
    }
}
}

extension Journey {
    /// Settings › Brand kit as its window shows it (hosted on its own, beside the main window).
    func brandKitWindow() async -> MouseRig {
        let s = MouseRig(BrandKitSettings(demo: false).environmentObject(store)
                            .frame(width: SettingsView.size.width, height: SettingsView.size.height)
                            .environment(\.colorScheme, .dark).background(Color(nsColor: .windowBackgroundColor)),
                         size: SettingsView.size, language: language)
        s.pump(0.4)
        await app.idle(0.3)
        return s
    }

    /// A native control of the form found by its label, title or value.
    func formControl(_ s: MouseRig, _ text: String, role: String? = nil, index: Int = 0) -> RigElement? {
        let all = s.elements().filter { (role == nil || $0.role == role) && ($0.label == text || $0.title == text || $0.value == text || $0.label.hasPrefix(text + ",")) }
        return all.indices.contains(index) ? all[index] : nil
    }

    /// Types `text` in a native field of the form (focused through accessibility, its text replaced), then Return.
    func typeIn(_ s: MouseRig, _ field: RigElement, _ text: String) async {
        // Focused (the field itself, not the one typed in before), its text selected (the Edit menu's ⌘A is not hosted).
        s.takeKey()
        if let v = (field.ref as? NSView) ?? (field.ref as? NSCell)?.controlView { s.window.makeFirstResponder(v) }
        s.pump(0.1)
        (s.window.firstResponder as? NSTextView)?.selectAll(nil)
        s.type(text)
        s.key(.returnKey)
        s.pump(0.2)
        await app.settle()
        await app.idle(0.3)
    }

    /// Picks `title` in a native pop-up of the form (its accessibility path: the menu's own item).
    func pick(_ s: MouseRig, popUp: RigElement, _ title: String) async -> Bool {
        guard let o = popUp.ref as? NSObject,
              let cell = (o as? NSPopUpButtonCell) ?? ((o as? NSPopUpButton)?.cell as? NSPopUpButtonCell), let menu = cell.menu else { return false }
        if let d = menu.delegate as AnyObject?, d.responds(to: NSSelectorFromString("popUpButtonCell:willShowMenu:")) {
            _ = d.perform(NSSelectorFromString("popUpButtonCell:willShowMenu:"), with: cell, with: menu)
        }
        menu.update()
        guard let i = menu.items.firstIndex(where: { $0.title == title }) else { return false }
        menu.performActionForItem(at: i)
        s.pump(0.2)
        await app.settle()
        await app.idle(0.3)
        return true
    }

    func shotKit(_ s: MouseRig, _ tag: String) { shot(s, tag) }

    /// Clicks a button of the form, the form scrolled first when the button is below its fold (an accessibility press
    /// reached the button but not its action, seen on Esporta… and Scegli…). `find` finds it again after a scroll.
    func press(_ s: MouseRig, _ find: () -> RigElement?) async {
        guard var e = find() else { return }
        if e.frame.maxY > Double(s.size.height) - 10 {
            _ = s.scrollContent(at: CGPoint(x: 460, y: 300), by: CGFloat(e.frame.maxY - Double(s.size.height) + 120))
            s.pump(0.2)
            e = find() ?? e
        } else if e.frame.minY < 10 {
            _ = s.scrollContent(at: CGPoint(x: 460, y: 300), by: CGFloat(e.frame.minY - 120))
            s.pump(0.2)
            e = find() ?? e
        }
        s.click(e.centre)
        s.pump(0.2)
        await app.settle()
        await app.idle(0.3)
        // A panel's button whose click did not reach it (the list's borderless Importa…): its accessibility press.
        if RigGuard.panelAnswer != nil, let again = find(), s.performAccessibility(again) != nil {
            await app.settle()
            await app.idle(0.3)
        }
    }

    /// Journey 14 (BrandKitJourneyTests.aBrandKitIsMadeByHandAndUsed).
    func brandKitByHand() async throws {
        let library = BrandKitLibrary.shared
        let media = try RigProject.media.get()
        let font = try #require(["/System/Library/Fonts/Supplemental/Georgia.ttf", "/System/Library/Fonts/Supplemental/Arial.ttf"].first { FileManager.default.fileExists(atPath: $0) },
                                "no system font to copy")
        let fontCopy = scratch.appendingPathComponent("Titoli.ttf")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: font), to: fontCopy)
        let dark = media.appendingPathComponent("card.png"), light = scratch.appendingPathComponent("logo-chiaro.png")
        try FileManager.default.copyItem(at: dark, to: light)
        await open(Navigation(activity: .graphics, rightTab: .inspector))
        let earlyTitle = try #require(store.project?.tracks.flatMap(\.clips).first { $0.title?.text == "TITOLO" }, "the reel has no title of its own")
        step("Opens a reel with a title of its own («TITOLO»)", sees: "the reel, «Marca: nessuna»")

        // 1. Settings › Brand kit: Nuovo kit, its name.
        let s = await brandKitWindow()
        defer { s.close() }
        let before = Set(library.kits.map(\.id))
        let new = try #require(formControl(s, loc("Nuovo kit")), "no «Nuovo kit»: \(screen(s))")
        _ = s.performAccessibility(new)
        #expect(await until(5) { library.kits.contains { !before.contains($0.id) } }, "Nuovo kit made no kit: \(screen(s))")
        let id = try #require(library.kits.first { !before.contains($0.id) }?.id)
        s.pump(0.3)
        let nameField = try #require(s.elements().first { $0.visible && $0.role == "AXTextField" && $0.value == loc("Nuovo kit") }, "no name field: \(screen(s))")
        await typeIn(s, nameField, "Forno Rosa")
        #expect(await until(5) { library.kit(id)?.name == "Forno Rosa" }, "the kit is named «\(library.kit(id)?.name ?? "?")»")
        step("Settings › Brand kit: Nuovo kit, names it «Forno Rosa»", sees: "the kit in the list, saved in the scratch kits folder")

        // 2. Colours by their code fields.
        let colours = ["primary": "#C8102E", "accent": "#F2A900", "ink": "#1B1B1B", "paper": "#FFF6EC"]
        for (role, hex) in colours {
            let label = loc(BrandKitSettings.roleNames.first { $0.0 == role }!.1)
            guard let field = s.elements().first(where: { $0.role == "AXTextField" && $0.label.contains(String(format: loc("%@, codice esadecimale"), label)) }) else {
                Issue.record("no code field for «\(label)»: \(screen(s))"); continue
            }
            await typeIn(s, field, hex)
        }
        #expect(await until(5) { colours.allSatisfy { library.kit(id)?.colors[$0.key] == $0.value } }, "the kit's colours are \(library.kit(id)?.colors ?? [:])")
        shotKit(s, "02-colours")
        step("Types the four colours' codes (Principale, Accento, Inchiostro, Carta)", sees: "\(colours.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")

        // 3. A font for the titles, the logos (dark and light footage), the corner.
        // The form scrolls: its controls are pressed through accessibility wherever they are (as the click audit does).
        let choose = s.elements().filter { $0.title == loc("Scegli…") || $0.label == loc("Scegli…") }
        #expect(choose.count >= 6, "the form has \(choose.count) «Scegli…» buttons: \(screen(s))")
        let chooser = { (i: Int) -> RigElement? in
            let all = s.elements().filter { $0.title == loc("Scegli…") || $0.label == loc("Scegli…") }
            return all.indices.contains(i) ? all[i] : nil
        }
        if choose.count >= 6 {
            let logoBefore = library.kit(id)?.logoPathIfSet("onDark")
            RigGuard.panelAnswer = [fontCopy]
            await press(s) { chooser(0) }
            #expect(await until(5) { library.kit(id)?.fonts["display"]?.hasSuffix("Titoli.ttf") == true }, "the titles' font is \(library.kit(id)?.fonts["display"] ?? "none")")
            RigGuard.panelAnswer = [dark]
            await press(s) { chooser(4) }
            RigGuard.panelAnswer = [light]
            await press(s) { chooser(5) }
            #expect(await until(5) { library.kit(id)?.logoPathIfSet("onDark") != logoBefore && library.kit(id)?.logoPathIfSet("onLight") != nil },
                    "the logos are not the scratch files: \(library.kit(id)?.logoPathIfSet("onDark") ?? "none")")
        }
        // The corner's pop-up reads as its choice (the form's first pop-up, then the animation's).
        if let corner = s.elements().first(where: { $0.role == "AXPopUpButton" }) {
            #expect(await pick(s, popUp: corner, loc("In alto a destra")), "no «In alto a destra» in the corner's menu")
            #expect(await until(5) { library.kit(id)?.logoPlacement?.corner == "topRight" }, "the corner is \(library.kit(id)?.logoPlacement?.corner ?? "none")")
        } else {
            Issue.record("no corner pop-up: \(screen(s))")
        }
        s.pump(0.3)
        shotKit(s, "03-font-logo-corner")
        step("Scegli… the titles' font, the logo on dark and on light footage; Angolo: In alto a destra", sees: "font \(URL(fileURLWithPath: library.kit(id)?.fonts["display"] ?? "").lastPathComponent), logos \(BrandKit.logoVariants.filter { library.kit(id)?.logoPathIfSet($0) != nil }), corner \(library.kit(id)?.logoPlacement?.corner ?? "?")")

        // 4. Marca › Forno Rosa on the open reel: the tab names it.
        try await tap("Marca del progetto: il brand kit di sottotitoli, titoli e logo")
        let picker = try #require(await popover(), "Marca opened no picker")
        try await tap("Forno Rosa", in: picker)
        #expect(await until { store.project?.brand?.id == id }, "the kit was not applied")
        #expect(await until { shows("Forno Rosa") }, "the window does not name the kit: \(screen())")
        let early = store.project?.tracks.flatMap(\.clips).first { $0.id == earlyTitle.id }?.title
        let earlyFollows = early?.color != earlyTitle.title?.color || early?.font != earlyTitle.title?.font
        step("Marca › Forno Rosa", sees: "«Marca: Forno Rosa»; the title added before the kit \(earlyFollows ? "takes" : "keeps") its look: colour \(early?.color ?? "?") (was \(earlyTitle.title?.color ?? "?")), font \(URL(fileURLWithPath: early?.font ?? "?").lastPathComponent) (was \(earlyTitle.title?.font ?? "?")); the window says nothing about it")
        let kit = try #require(library.kit(id))
        let kitColours = Set(kit.colors.values.map { $0.uppercased() })

        // 5. A title and a call to action added afterwards (Grafica › Effetti › Titolo, Etichetta): the kit's colours and font.
        store.preview.seek(3.2)
        await app.settle()
        func addText(_ row: String, _ text: String) async throws -> Title? {
            let before = Set(store.project?.tracks.flatMap(\.clips).map(\.id) ?? [])
            rig.takeKey()
            guard let found = await reveal(row, at: CGPoint(x: 200, y: 600)) else { Issue.record("no «\(row)» in Grafica: \(screen())"); return nil }
            rig.click(found.centre)
            await app.settle()
            await app.idle(0.4)
            if !(await until(3) { control("Aggiungi") != nil }) { _ = await reveal("Aggiungi", at: CGPoint(x: 200, y: 600)) }
            if rig.isTyping { rig.type(text) }
            try await tap("Aggiungi")
            _ = await until(5) { store.project?.tracks.flatMap(\.clips).contains { !before.contains($0.id) && $0.title != nil } == true }
            return store.project?.tracks.flatMap(\.clips).first { !before.contains($0.id) && $0.title != nil }?.title
        }
        try await tap("Grafica")
        try await tap("Effetti")
        let late = try await addText(loc("Titolo"), "DOPO")
        let cta = try await addText(loc("Etichetta"), "ORDINA ORA")
        func inKit(_ t: Title?) -> Bool { t.map { kitColours.contains($0.color.uppercased()) || kit.colors[$0.color] != nil } ?? false }
        #expect(inKit(late) && (late?.font.contains("Titoli") == true || late?.font == kit.font("display") || late?.font == "display"),
                "the title added after the kit is \(late?.color ?? "?") in \(late?.font ?? "?"), not the kit's (\(kit.colors), \(kit.font("display")))")
        #expect(inKit(cta), "the call to action is \(cta?.color ?? "?"), not a colour of the kit")
        step("Grafica › Effetti › Titolo, Etichetta (each with its form's text), Aggiungi", sees: "«\(late?.text ?? "?")» \(late?.color ?? "?") in \(URL(fileURLWithPath: late?.font ?? "?").lastPathComponent), «\(cta?.text ?? "?")» \(cta?.color ?? "?"): the kit's")

        // 6. The logo from Grafica › Logo: the kit's logo in its corner.
        try await tap("Logo")
        let logoSwitch = rig.elements().first { $0.isControl && $0.visible && $0.label.hasPrefix(loc("Logo nel video")) && ["0", "1"].contains($0.value) }
        if let logoSwitch, logoSwitch.value == "0" { rig.click(logoSwitch.centre); await app.settle() }
        let logo = store.project?.tracks.first { $0.role == "logo" }?.clips.last
        let corner = logo?.placement.map { $0.x > 0.5 && $0.y < 0.5 } ?? false
        #expect(logo != nil && corner, "the logo is not in the kit's corner (top right): \(String(describing: logo?.placement))")
        step("Grafica › Logo, «Logo nel video»", sees: "the logo at \(logo?.placement.map { "\(Int($0.x * 100))%, \(Int($0.y * 100))%" } ?? "nowhere") (the kit's corner: top right)")

        // 7. The kit's check (the window has no button for it: run as the panel's commands run, on the tab's queue).
        let pass = try await store.perform("brandkit.check")
        step("brandkit.check (no button in the window: run on the tab)", sees: "pass \(pass["pass"]?.boolValue == true)")
        let off = try await store.perform("title.add", ["text": "FUORI MARCA", "start": 0.5, "duration": 1, "color": "#00FF00"])
        let offID = off.value(at: "clip.id")?.stringValue ?? "?"
        let broken = try await store.perform("brandkit.check")
        let names = broken.text().contains(offID)
        withKnownIssue("brandkit.check looks at fonts, the captions' keyword box and the logo's zone, not at the titles' colours (#97)") {
            #expect(broken["pass"] == false && names, "a title in a colour outside the kit passes the kit's check: \(broken.text().prefix(300))")
        }
        step("A title «FUORI MARCA» in #00FF00, brandkit.check again", sees: "pass \(broken["pass"]?.boolValue == true), the clip \(names ? "named" : "not named")")

        // 8. The kit changed in Settings while the project is open: does the project follow, and does the window say so?
        let projectBefore = store.project?.brand?.colors["primary"]
        if let field = s.elements().first(where: { $0.role == "AXTextField" && $0.label.contains(String(format: loc("%@, codice esadecimale"), loc("Principale"))) }) {
            await typeIn(s, field, "#2E7D32")
        }
        #expect(await until(5) { library.kit(id)?.colors["primary"] == "#2E7D32" }, "the kit's primary did not change")
        await app.settle()
        let projectAfter = store.project?.brand?.colors["primary"]
        withKnownIssue("an open project keeps its copy of the kit when the kit changes in Settings, and the window does not say which it shows (#98)", isIntermittent: true) {
            #expect(projectAfter == "#2E7D32", "the open project still has \(projectAfter ?? "?") after the kit changed")
        }
        step("Settings: Principale #2E7D32 while the reel is open", sees: "the kit #2E7D32; the open project \(projectBefore ?? "?") → \(projectAfter ?? "?"); «Marca: Forno Rosa» unchanged, nothing says which version the reel shows")

        // 9. Through the socket: brandkit.list has the kit with the form's fields.
        // Claude connects as regista-mcp does (the pill is in the snapshot: with the Settings window beside it, the main
        // window's accessibility tree reads the pill by its tooltip only).
        rig.takeKey()
        let socket = EngineSocket.defaultPath()
        final class LinkHolder: @unchecked Sendable { var link: ClaudeLink?; var done = false }
        let holder = LinkHolder()
        Task.detached { holder.link = try? ClaudeLink(socket: socket); holder.done = true }
        _ = await until(10) { holder.done }
        let link = try #require(holder.link, "Claude could not connect to the app's socket")
        let listed = await claude(link, "brandkit.list")
        let entry = listed.reply.result?["kits"]?.arrayValue?.first { $0["id"]?.stringValue == id }
        #expect(entry?["name"]?.stringValue == "Forno Rosa", "brandkit_list does not list «Forno Rosa»: \(listed.reply.text.prefix(300))")
        #expect(entry.map { e in colours.merging(["primary": "#2E7D32"]) { $1 }.allSatisfy { e.value(at: "colors.\($0.key)")?.stringValue == $0.value } } == true,
                "brandkit_list's colours differ from the form's: \(entry?["colors"]?.text() ?? "none")")
        step("brandkit_list on the socket", sees: "«Forno Rosa» with the form's colours, font and logos")

        // 10. Esporta… and Importa… (scratch files).
        let file = scratch.appendingPathComponent("forno-rosa.registakit")
        RigGuard.panelAnswer = [file]
        if formControl(s, loc("Esporta…")) != nil { await press(s) { formControl(s, loc("Esporta…")) } } else { Issue.record("no «Esporta…» in the form: \(screen(s))") }
        #expect(await until(5) { FileManager.default.fileExists(atPath: file.path) }, "Esporta… wrote no kit file")
        let kitsBefore = Set(library.kits.map(\.id))
        RigGuard.panelAnswer = [file]
        if formControl(s, loc("Importa…")) != nil { await press(s) { formControl(s, loc("Importa…")) } } else { Issue.record("no «Importa…»: \(screen(s))") }
        #expect(await until(5) { library.kits.contains { !kitsBefore.contains($0.id) && $0.name == "Forno Rosa" } }, "Importa… added no copy of the kit: \(library.kits.map { "\($0.id) \($0.name)" })")
        let copy = library.kits.first { !kitsBefore.contains($0.id) }?.id
        step("Esporta… then Importa… the .registakit", sees: "the file written; the kit imported again as «\(copy ?? "?")»")

        // 11. The kit deleted while the reel uses it: the tab, Grafica, Esporta.
        if let copy { _ = try? await store.perform("brandkit.delete", ["kit": .string(copy)]) }   // the imported copy goes first, not part of the question
        _ = try await store.perform("brandkit.delete", ["kit": .string(id)])
        library.reload()
        await app.settle()
        let stillNamed = shows("Forno Rosa")
        let brand = store.project?.brand
        try await tap("Esporta")
        await app.idle(0.5)
        withKnownIssue("a project whose kit was deleted keeps showing it with no word that it is gone (#98)", isIntermittent: true) {
            #expect(!stillNamed || brand == nil, "the tab still says «Marca: Forno Rosa» for a kit that no longer exists")
        }
        #expect(brand?.name.isEmpty != true, "the project's kit has a blank name after the delete")
        step("Deletes «Forno Rosa» (the reel uses it); Esporta", sees: "the tab \(stillNamed ? "still names «Forno Rosa»" : "names no kit"); the project's kit \(brand.map { "«\($0.name)», its own copy" } ?? "none"); Esporta opens with no word about it")
        try? FileManager.default.removeItem(at: fontCopy)
    }
}
