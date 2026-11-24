import AppKit
import RegistaCore
import Testing
@testable import Regista

// One regia (step 3, #165), with the mouse: on a project whose kind's sheet differs from the defaults (a fast pace, no
// captions, no sound effects) the Simple steps open on those choices and «Fai tutto» uses them; a change in a step is this
// project's own, one undo step, with a dot whose tooltip names what the regia has; «Ripristina» beside the step's title
// takes the step back to the regia. Snapshots of the cut, captions and sound steps ($REGISTA_UI_SNAPSHOTS/journeys) in
// Italian and French.

extension MouseSuites {
@Suite(.serialized) @MainActor struct RegiaStepsTests {
    @Test(arguments: ["it", "fr"])
    func theSimpleStepsFollowTheRegia(_ language: String) async throws {
        let j = try await Journey("regia-\(language)", project: nil)
        j.language = language
        defer { j.close() }
        let store = j.store
        // The person's regia for talking-head reels, then a project of that kind with a take on the timeline.
        try await store.perform("rules.set", ["kind": "talking-head-reel", "choices": ["pace": "fast", "captions": "none", "sfx": "none"]])
        let take = try j.take("parlato.mov")
        try await store.perform("project.new", ["name": "Regia"])
        try await store.perform("media.import", ["path": .string(take.path)])
        try await store.perform("track.add", ["kind": "video"])
        try await store.perform("track.add", ["kind": "audio"])
        try await store.perform("timeline.place", ["assetId": "a1", "trackId": "t1"])
        try await store.perform("timeline.place", ["assetId": "a1", "trackId": "t2", "linkTo": "c1"])
        try await store.perform("project.setKind", ["kind": "talking-head-reel"])
        var nav = Navigation(activity: .media, rightTab: .inspector)
        nav.show(.simple)
        await j.open(nav)

        /// The dot of a choice, found by its tooltip (what the regia has).
        func dot(_ choice: String, _ regia: String) -> RigElement? {
            let spec = RuleChoiceSpec.named(choice)
            let text = String(format: loc("Diverso dalla tua regia (%1$@: %2$@)"), loc(spec?.title ?? ""),
                              loc(spec?.option(regia)?.label ?? regia).lowercased(with: Words.locale))
            return j.rig.elements().first { $0.visible && $0.label == text }
        }
        let restore = "Torna alla tua regia: il passo segue di nuovo Impostazioni › Regia e skill"
        func anyDot() -> Bool { j.rig.elements().contains { $0.visible && $0.label.hasPrefix(String(loc("Diverso dalla tua regia (%1$@: %2$@)").prefix(12))) } }

        // Taglio e riprese opens on the kind's pace; no dot, no «Ripristina»: the project follows its regia.
        #expect(j.openStep == .cut)
        #expect(j.control("Fast")?.selected == true, "the pace does not open on the kind's choice: \(j.screen())")
        #expect(!anyDot() && j.control(restore) == nil)
        j.step("Semplice on a talking-head reel whose sheet says a fast pace, no captions, no sound effects",
               sees: "Taglio e riprese with «\(loc("Fast"))» chosen, no dot")
        // Sottotitoli and Musica e suoni say what the regia wants.
        try await j.openRow(.captions)
        #expect(store.simpleSnapshot[.captions].status == .notNeeded, "\(j.screen())")
        #expect(j.shows(loc("Niente sottotitoli: lo dice la tua regia.")), "the step does not say why: \(j.screen())")
        #expect(j.control(captionStyleName("talking-head-v1"))?.selected != true, "a style is lit with the choice «none»")
        j.step("Sottotitoli", sees: "no captions as the regia says, no style lit")
        try await j.openRow(.sound)
        #expect(j.control("Un whoosh sui tagli")?.value == "0")
        j.step("Musica e suoni", sees: "the whoosh off as the regia says")

        // «Fai tutto» uses the regia: the fast pauses, no captions.
        let doAll = try #require(j.rig.controls().first { $0.name.hasPrefix(String(loc("Taglia, sceglie le riprese, pulisce la voce, mette i sottotitoli e una luce più viva, in ordine").prefix(16))) },
                                 "no «Fai tutto»: \(j.screen())")
        j.rig.click(doAll.centre)
        #expect(await j.until(120) { store.jobs.latest(TextStep.allJobKind)?.isRunning == false }, "«Fai tutto» did not finish: \(j.screen())")
        await j.app.settle()
        let done = try #require(store.project)
        #expect(done.takes?.options.maxPause == 0.4 && done.takes?.options.keepPause == 0.06, "not cut at the fast pace: \(String(describing: done.takes?.options))")
        #expect(!done.tracks.contains { $0.kind == .caption }, "«Fai tutto» drew captions the regia does not want")
        #expect(done.choices == nil, "«Fai tutto» stored choices of its own")
        #expect(store.simpleSnapshot.light, "«Fai tutto» did not put the light grade on (the colour choice, light by default)")

        // A pace picked in the step: this project's own (one command, one undo step), the dot names the regia's.
        try await j.openRow(.cut)
        var n = j.app.store.activity.count
        try await j.tap("Calm")
        #expect(await j.until(10) { store.project?.takes?.options.maxPause == 1.2 }, "the cut did not follow the pace picked")
        #expect(j.app.commands(since: n) == ["project.setChoices"], "the pace ran \(j.app.commands(since: n))")
        #expect(store.project?.choices?["pace"]?.value == "calm")
        #expect(dot("pace", "fast") != nil && j.control(restore) != nil, "no dot or «Ripristina» after a change: \(j.screen())")
        j.step("Taglio e riprese › «\(loc("Calm"))»", sees: "the cut at the calm pace, the dot «\(dot("pace", "fast")?.label ?? "-")», «Ripristina»")
        try await store.perform("history.undo")
        #expect(store.project?.choices == nil && store.project?.takes?.options.maxPause == 0.4, "one undo did not take back the choice and its cut")
        try await store.perform("history.redo")
        await j.app.settle()
        // «Ripristina»: back to the regia, the cut again at its pace, the dot gone.
        n = j.app.store.activity.count
        try await j.tap(restore)
        #expect(await j.until(10) { store.project?.choices == nil && store.project?.takes?.options.maxPause == 0.4 }, "«Ripristina» did not take the cut back to the regia")
        #expect(j.app.commands(since: n) == ["project.setChoices"])
        #expect(dot("pace", "fast") == nil && j.control(restore) == nil && j.control("Fast")?.selected == true)

        // Sottotitoli: a style picked where the regia says none is this project's choice; the switch makes captions in it.
        try await j.openRow(.captions)
        try await j.tap(captionStyleName("elegant-serif"))
        #expect(store.project?.choices?["captions"]?.value == "elegant-serif" && dot("captions", "none") != nil, "\(j.screen())")
        try await j.tap("Sottotitoli nel video")
        #expect(await j.until(30) { store.simpleSnapshot.captionsTrack != nil && store.simpleSnapshot.busy == nil }, "no captions: \(j.screen())")
        #expect(store.project?.tracks.first { $0.captions != nil }?.captions?.style.id == "elegant-serif")
        try await j.tap(restore)
        #expect(await j.until(10) { store.project?.choices == nil && store.simpleSnapshot.captionsTrack == nil }, "«Ripristina» kept the captions the regia does not want")
        #expect(!anyDot())

        // Aspetto: the light grade (the colour choice, light by default: no choice of this project's) taken off is this
        // project's choice «none». (The cut again above made new clips, without the grade.)
        try await j.openRow(.look)
        if !store.simpleSnapshot.light {
            try await j.tap("Luce leggera")
            #expect(await j.until(10) { store.simpleSnapshot.light } && store.project?.choices == nil, "the light the regia wants stored a choice")
        }
        try await j.tap("Luce leggera")
        #expect(await j.until(10) { !store.simpleSnapshot.light } && store.project?.choices?["colour"]?.value == "none" && dot("colour", "light") != nil)
        try await j.tap(restore)
        #expect(await j.until(10) { store.simpleSnapshot.light && store.project?.choices == nil }, "«Ripristina» did not put the light back")

        // Musica e suoni: the whoosh turned on where the regia says none; «Ripristina» takes the sounds off again.
        try await j.openRow(.sound)
        try await j.tap("Un whoosh sui tagli")
        #expect(await j.until(10) { store.simpleSnapshot.effects > 0 }, "no sound on the cuts: \(j.screen())")
        #expect(store.project?.choices?["sfx"]?.value == "sparse" && dot("sfx", "none") != nil)
        j.step("Musica e suoni › Un whoosh sui tagli", sees: "\(store.simpleSnapshot.effects) sounds on the cuts, the dot «\(dot("sfx", "none")?.label ?? "-")»")
        try await j.tap(restore)
        #expect(await j.until(10) { store.simpleSnapshot.effects == 0 && store.project?.choices == nil }, "«Ripristina» left the sounds the regia does not want")

        // Grafica: the logo taken off is this project's choice «off»; «Ripristina» takes the choice back.
        let kit = try await j.brandKit("Regia Kit")
        try await store.perform("brandkit.apply", ["kit": .string(kit)])
        try await j.openRow(.graphics)
        try await j.tap("Logo nel video")
        #expect(await j.until(10) { !store.simpleSnapshot.logoClips.isEmpty }, "no logo: \(j.screen())")
        #expect(store.project?.choices == nil, "the logo the regia wants stored a choice")
        try await j.tap("Logo nel video")
        #expect(await j.until(10) { store.simpleSnapshot.logoClips.isEmpty } && store.project?.choices?["closing-logo"]?.value == "off" && dot("closing-logo", "brand") != nil)
        try await j.tap(restore)
        #expect(await j.until(10) { store.project?.choices == nil } && !anyDot())
        _ = try? await store.silent("brandkit.delete", ["kit": .string(kit)])
    }
}
}
