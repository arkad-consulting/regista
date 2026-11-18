import AppKit
import RegistaCore
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
}
}
