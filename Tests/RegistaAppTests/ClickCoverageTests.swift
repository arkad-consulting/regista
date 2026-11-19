import AppKit
import RegistaCore
@testable import RegistaEngines
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
        // The export follows the slider: the panel's export button (or «Esporta lo stesso» when a rule fails) runs
        // export.render with 25 Mbps, into the file the save panel is answered with.
        let out = rigTempDir("bitrate-export").appendingPathComponent("bitrate.mp4")
        RigGuard.panelAnswer = [out]
        defer { RigGuard.panelAnswer = nil }
        let n = app.store.activity.count
        let button = try #require(app.rig.element("Esporta lo stesso") ?? app.rig.element("Esporta video…"), "no export button on Esporta")
        app.rig.click(button.centre)
        for _ in 0..<600 where !(FileManager.default.fileExists(atPath: out.path) && app.store.jobs.latest("export")?.isRunning == false) {
            await app.idle(0.1)
        }
        let run = app.store.activity.dropFirst(n).first { $0.command == "export.render" }
        #expect(run?.params.contains("bitrate: 25") == true, "the export ran with «\(run?.params ?? "no export.render")»")
        #expect(app.store.jobs.latest("export")?.state == .done && FileManager.default.fileExists(atPath: out.path), "the export did not end with a file")
        // In the interface language: the number and its unit.
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector), language: "fr")
        await app.settle()
        let fr = MouseRig.table("fr").localizedString(forKey: "Bit rate", value: "Bit rate", table: nil)
        let french = app.rig.elements().first { $0.label == fr && $0.visible }
        #expect(french?.valueDescription == "25 Mbit/s", "in French the slider reads «\(french?.valueDescription ?? "nothing")»")
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

    /// #116 from the app: a frame that never comes once, before the first second, does not cost the person the export. The
    /// Esporta button's export (the save panel answered) stops the first attempt after the start timeout, starts again
    /// once and ends done with its file. Nothing new shows while it works (the job's card and its progress, as always);
    /// the only trace is the export's row in the activity (also under «Ultimo export»), whose details, one hover away,
    /// say it started again and at which frame.
    @Test func anExportStuckOnceFromTheEsportaButtonStartsAgainAndEndsDone() async throws {
        let app = try await AppRig()
        defer { app.close() }
        let name = try #require(app.store.project?.name)
        let release = DispatchSemaphore(value: 0)
        let held = HeldOnce()
        TimelineCompositor.testHook.set(name) { t in
            guard t >= MediaTime(seconds: 0.5), held.first() else { return }
            release.wait()   // only the first attempt's frame at 0.5 s never comes
        }
        defer {
            TimelineCompositor.testHook.set(name, nil)
            for _ in 0..<64 { release.signal() }
        }
        app.hostEditor(Navigation(activity: .export, rightTab: .inspector))
        await app.settle()
        let out = rigTempDir("restart-export").appendingPathComponent("restart.mp4")
        RigGuard.panelAnswer = [out]
        defer { RigGuard.panelAnswer = nil }
        let n = app.store.activity.count, events = RigGuard.events.count
        let button = try #require(app.rig.element("Esporta lo stesso") ?? app.rig.element("Esporta video…"), "no export button on Esporta")
        let began = Date()
        app.rig.click(button.centre)
        for _ in 0..<1200 where !(FileManager.default.fileExists(atPath: out.path) && app.store.jobs.latest("export")?.isRunning == false) {
            await app.idle(0.1)
        }
        let seconds = Date().timeIntervalSince(began)
        await app.settle()
        #expect(held.happened, "the frame at 0.5 s was never asked for")
        #expect(app.store.jobs.latest("export")?.state == .done && FileManager.default.fileExists(atPath: out.path),
                "the export did not end done with its file (\(String(describing: app.store.jobs.latest("export")?.state)), \(Int(seconds)) s)")
        #expect(seconds < 90, "the export took \(Int(seconds)) s")
        let run = try #require(app.store.activity.dropFirst(n).first { $0.command == "export.render" }, "no export.render in the activity")
        #expect(run.status == .ok)
        let phrase = loc("ripartito una volta dal fotogramma %@").replacingOccurrences(of: "%@", with: "")
        #expect(run.result.contains("restart.mp4") && !run.result.contains(phrase), "the row's line is not the usual one: «\(run.result)»")
        let after = try #require(run.details.range(of: phrase), "the details do not say the export started again: «\(run.details)»")
        let frame = Int(run.details[after.upperBound...].prefix { $0.isNumber }) ?? 99
        #expect(frame < 30, "restarted at frame \(frame), after the first second")
        #expect(RigGuard.events.dropFirst(events).allSatisfy { $0.kind == .panel }, "something besides the save panel showed: \(RigGuard.events.dropFirst(events))")
        print("ClickCoverageTests: the stuck export ended done in \(String(format: "%.1f", seconds)) s; activity details «\(run.details)»")
    }

    /// #119 in the help window: the install guide opens, in Italian and in French, on what a person who downloaded the
    /// disk image needs — its first section's heading and its «Per cominciare» are on screen at the window's own size,
    /// in that language. REGISTA_UI_SNAPSHOTS keeps the renders (help-install-<lang>.png) for a look.
    @Test(arguments: ["it", "fr"]) func theInstallGuideOpensOnTheDownloadedApp(_ lang: String) async throws {
        let app = try await AppRig(project: nil)
        defer { app.close() }
        let center = HelpCenter()
        center.guide = .install
        app.host(HelpView(center: center, language: lang), size: HelpView.size, language: lang)
        await app.settle()
        let text = try #require(HelpLibrary.text(.install, language: lang), "no install guide in \(lang)")
        let heading = try #require(text.components(separatedBy: "\n## ").dropFirst().first?.components(separatedBy: "\n").first, "no first section")
        let start = MouseRig.table(lang).localizedString(forKey: "Per cominciare", value: "Per cominciare", table: nil)
        let shown = app.rig.elements().filter { $0.visible && $0.frame.minX >= HelpView.listWidth }.map(\.name)
        #expect(shown.contains { $0.contains(heading) }, "\(lang): the first section «\(heading)» is not on screen: \(shown.prefix(12))")
        #expect(shown.contains { $0.contains(start) }, "\(lang): «\(start)» is not on screen at the window's size")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("help-install-\(lang).png"))
        }
    }
}
}

/// The first caller gets true, every later one false (a frame held once, whichever thread asks first).
final class HeldOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    var happened: Bool { lock.lock(); defer { lock.unlock() }; return done }
}
