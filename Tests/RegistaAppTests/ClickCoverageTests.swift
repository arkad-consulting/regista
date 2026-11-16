import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// What the click audit could not drive yet (#36), driven with the mouse on the real views: Export's bit rate slider read
// as an assistive client reads it.

extension MouseSuites {
@Suite(.serialized) @MainActor struct ClickCoverageTests {
    /// Esporta › Bit rate: its value reads as an assistive client reads it, and a drag along it changes it once, to
    /// where the drag let go.
    @Test func theBitRateSliderReadsItsValueAndADragChangesIt() async throws {
        let options = ExportOptions.shared
        let saved = options.bitrate
        defer { options.bitrate = saved }
        options.bitrate = 14
        let app = try await AppRig()
        defer { app.close() }
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
        await app.settle()
        func slider() -> RigElement? { app.rig.elements().first { $0.label == "Bit rate" && $0.visible } }
        let s = try #require(slider(), "no Bit rate slider on Esporta")
        #expect(s.valueDescription == "14 Mbps", "the slider reads «\(s.valueDescription)»")
        // A press on the track at 30 %, dragged to 80 % (the track is the bottom 18 pt of the labelled slider).
        let y = s.frame.maxY - 9
        let from = CGPoint(x: s.frame.minX + s.frame.width * 0.3, y: y)
        var seen: [Double] = []
        let watch = options.$bitrate.dropFirst().removeDuplicates().sink { seen.append($0) }
        app.rig.drag(from: from, by: CGSize(width: s.frame.width * 0.5, height: 0))
        await app.settle()
        watch.cancel()
        // 6…30 Mbps by 1: 80 % along is 25.2 → 25.
        #expect(options.bitrate == 25, "the drag left the bit rate at \(options.bitrate)")
        #expect(slider()?.valueDescription == "25 Mbps", "after the drag the slider reads «\(slider()?.valueDescription ?? "nothing")»")
        #expect(seen.first.map { abs($0 - 13) <= 1 } == true && seen.last == 25, "the value went \(seen)")
        // Released, it stays: a second look changes nothing.
        await app.idle(0.3)
        #expect(options.bitrate == 25 && slider()?.valueDescription == "25 Mbps")
    }

    /// Testi e sottotitoli › Trascrizione: a word's click reads its own modifiers (#36). ⌘-click selects a word, ⇧-click
    /// extends the selection to another, ⌥-click starts again from a word, a plain click goes to the word.
    @Test func theTranscriptWordsReadTheClicksModifiers() async throws {
        let app = try await AppRig()
        defer { app.close() }
        var nav = Navigation(activity: .texts, rightTab: .inspector)
        nav.textsTab = .transcript
        app.hostEditor(nav)
        await app.settle()
        func word(_ w: String) throws -> CGPoint {
            try #require(app.rig.elements().first { $0.role == "AXStaticText" && $0.name.trimmingCharacters(in: .whitespaces) == w && WindowPart.side.contains($0.centre) },
                         "no word «\(w)» in the transcript").centre
        }
        let words = app.store.words.map(\.text)
        let regista = try #require(words.firstIndex(of: "Regista")), il = try #require(words.firstIndex(of: "il")), oggi = try #require(words.firstIndex(of: "Oggi"))
        app.rig.click(try word("Regista"), modifiers: .command)
        await app.settle()
        #expect(app.store.wordSelection == regista...regista, "⌘-click did not select «Regista»: \(String(describing: app.store.wordSelection))")
        app.rig.click(try word("il"), modifiers: .shift)
        await app.settle()
        #expect(app.store.wordSelection == regista...il, "⇧-click did not extend to «il»: \(String(describing: app.store.wordSelection))")
        app.rig.click(try word("Oggi"), modifiers: .option)
        await app.settle()
        #expect(app.store.wordSelection == oggi...oggi, "⌥-click did not start again from «Oggi»: \(String(describing: app.store.wordSelection))")
        app.rig.click(try word("il"))
        await app.settle()
        #expect(app.store.wordSelection == nil, "a plain click kept a selection")
        #expect(abs(app.store.preview.playhead.time - app.store.words[il].start.seconds) < 0.05, "a plain click did not go to «il»")
    }

    /// Impostazioni › Generale keeps the Mac's own form controls: driven through their accessibility actions (#36), each
    /// changes its setting once — the format of new projects (a pop-up's pick), the spoken language (another pop-up),
    /// autosave (a check box's press).
    @Test func theSettingsFormIsDrivenThroughAccessibility() async throws {
        let keys = [GeneralPrefs.formatKey, GeneralPrefs.spokenLanguageKey, GeneralPrefs.autoSaveKey]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer { for (k, v) in saved { UserDefaults.standard.set(v, forKey: k) } }
        UserDefaults.standard.set("9:16", forKey: GeneralPrefs.formatKey)
        UserDefaults.standard.set("fr", forKey: GeneralPrefs.spokenLanguageKey)
        UserDefaults.standard.set(false, forKey: GeneralPrefs.autoSaveKey)
        let app = try await AppRig()
        defer { app.close() }
        let status = try await app.store.silent("engines.status")
        app.host(SettingsView(engines: EnginesDemo(status: status, tier: nil), voiceProfiles: VoiceDemo.profiles).environment(\.colorScheme, .dark),
                 size: SettingsView.size)
        await app.settle()
        func control(_ role: String, _ name: String) throws -> RigElement {
            try #require(app.rig.controls().first { $0.role == role && $0.name == name }, "no \(role) «\(name)»: \(app.rig.controls().map(\.description))")
        }
        var changes = 0
        let watch = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { _ in changes += 1 }
        defer { NotificationCenter.default.removeObserver(watch) }

        let format = try control("AXPopUpButton", GeneralPrefs.formatName("9:16"))
        #expect(app.rig.performAccessibility(format) == "accessibility action: pick «\(GeneralPrefs.formatName("4:5"))»")
        await app.settle()
        #expect(UserDefaults.standard.string(forKey: GeneralPrefs.formatKey) == "4:5", "the format is \(UserDefaults.standard.string(forKey: GeneralPrefs.formatKey) ?? "unset")")
        #expect(app.rig.controls().contains { $0.role == "AXPopUpButton" && $0.name == GeneralPrefs.formatName("4:5") }, "the pop-up does not show the new format")

        let spoken = try control("AXPopUpButton", StepSettings.languageName("fr"))
        #expect(app.rig.performAccessibility(spoken)?.hasPrefix("accessibility action: pick «") == true)
        await app.settle()
        let language = UserDefaults.standard.string(forKey: GeneralPrefs.spokenLanguageKey)
        #expect(language != nil && language != "fr", "the spoken language is still \(language ?? "unset")")

        let autosave = try #require(app.rig.controls().filter { $0.role == "AXCheckBox" }.min { $0.frame.minY < $1.frame.minY }, "no check box")
        let before = changes
        #expect(app.rig.performAccessibility(autosave) == "accessibility action: press")
        await app.settle()
        #expect(UserDefaults.standard.bool(forKey: GeneralPrefs.autoSaveKey), "autosave did not turn on")
        #expect(changes >= before + 1, "the press changed no setting")
        // Once: a second look changes nothing more.
        await app.idle(0.3)
        #expect(UserDefaults.standard.bool(forKey: GeneralPrefs.autoSaveKey) && UserDefaults.standard.string(forKey: GeneralPrefs.formatKey) == "4:5")
    }

    /// A scroll-wheel event scrolls a SwiftUI scroll view by its delta (#50): with the main display awake `scrollContent`
    /// turns the wheel, it does not move the clip view itself. The rig's window is back where it was (off every display)
    /// afterwards.
    @Test func aWheelEventScrollsASwiftUIScrollView() async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        app.host(ScrollView { VStack(spacing: 0) { ForEach(0..<60, id: \.self) { i in Text(verbatim: "row \(i)").frame(height: 30) } } }
            .frame(width: 300, height: 300), size: CGSize(width: 300, height: 300))
        await app.settle()
        let p = CGPoint(x: 150, y: 150)
        var v = app.rig.viewAt(p)
        while let x = v, !(x is NSScrollView) { v = x.superview }
        let sv = try #require(v as? NSScrollView, "no scroll view")
        let origin = app.rig.window.frame.origin, misses = MouseRig.wheelMisses
        #expect(app.rig.scrollContent(at: p, by: 60))
        #expect(abs(sv.contentView.bounds.origin.y - 60) < 1, "a 60 pt wheel turn scrolled to \(sv.contentView.bounds.origin.y)")
        #expect(app.rig.scrollContent(at: p, by: -30))
        #expect(abs(sv.contentView.bounds.origin.y - 30) < 1, "a turn back scrolled to \(sv.contentView.bounds.origin.y)")
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            withKnownIssue("#50: the main display is asleep, so SwiftUI would apply a wheel event only when it wakes: the rig moved the clip view") {
                #expect(MouseRig.wheelMisses == misses)
            }
        } else {
            #expect(MouseRig.wheelMisses == misses, "the wheel event did not scroll: the clip view was moved instead")
        }
        #expect(app.rig.window.frame.origin == origin && app.rig.window.alphaValue == 1, "the rig's window was not put back")
        #expect(!NSScreen.screens.contains { $0.frame.intersects(app.rig.window.frame) }, "the rig's window stayed on a display")
    }
}
}
