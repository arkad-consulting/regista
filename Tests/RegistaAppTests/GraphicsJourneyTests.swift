import AppKit
import RegistaCore
import RegistaMCP
import Testing
@testable import Regista

// Journey 12: Claude dresses a cut reel with the reel-graphics recipe through the tools, the route of journeys 8, 10
// and 11 (an MCP server on the running app's engine socket), from the cut reel of journey 8 (its steps reused): the
// catalogue, a preview that leaves the edit alone, a title on a word, a motion template from the catalogue, a sticker
// and a callout, sound effects on the cuts, music under the voice, the recipe's checks, the rules, the export. After
// each command the window agrees with the result. And every catalogue entry the recipe can apply resolves to a command
// that accepts what the catalogue gives.

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct GraphicsJourneyTests {
    /// 12. The graphics of a reel through the tools, the reel-graphics recipe in its order.
    @Test func claudeAddsTheGraphicsOfAReel() async throws {
        let j = try await Journey("12-claude-reel-graphics", project: nil)
        defer { j.close() }
        try await j.claudeReelGraphics()
    }

    /// Every catalogue entry, resolved by effects.catalog {item, start, fields: its examples} as Claude does, runs on a
    /// scratch copy of a reel dressed with a brand kit (the recipe's first step) without being refused: a refusal is a
    /// defect of the catalogue (#89, #90). An entry whose engine is not on this Mac (Blender: the rig's services have
    /// none) or that needs a step first that its refusal names (a hand or face track before a follow) is listed apart.
    @Test func everyCatalogueEntryIsAccepted() async throws {
        let services = RigServices.make(in: rigTempDir("catalogue-services"))
        let base = Engine(services: services)
        _ = try base.execute("project.open", params: ["path": .string(try RigProject.rich().path)])
        _ = try base.execute("brandkit.apply", params: ["kit": "cafe-atelier"])
        let items = try #require(try base.execute("effects.catalog")["items"]?.arrayValue)
        #expect(items.count > 100, "the catalogue lists \(items.count) entries")
        let card = try RigProject.media.get().appendingPathComponent("card.png").path
        let project = try #require(base.project)
        let mainTrack = try #require(project.tracks.first { $0.kind == .video && !$0.clips.isEmpty })
        let main = try #require(mainTrack.clips.first)
        let overlay = project.tracks.filter { ($0.kind == .video || $0.kind == .overlay) && $0.id != mainTrack.id }.flatMap(\.clips)
            .first { $0.sticker != nil || $0.title != nil }
        var refused: [String] = [], engines: [String] = [], first: [String] = [], tried = 0
        for item in items {
            guard let id = item["id"]?.stringValue else { continue }
            // The fields with the catalogue's own examples; a clip or a picture of the example names one of this reel.
            var fields: [String: JSONValue] = [:]
            for f in item["fields"]?.arrayValue ?? [] {
                guard let name = f["name"]?.stringValue, let example = f["example"] else { continue }
                switch f["type"]?.stringValue {
                // The clip a follow rides (an overlay of the reel), else the main video's.
                case "clip": fields[name] = .string(item["command"] == "clip.follow" ? (overlay?.id ?? main.id) : main.id)
                case "image": fields[name] = .string(card)
                case "images": fields[name] = .array([.string(card), .string(card)])
                default: fields[name] = example
                }
            }
            let resolved: JSONValue
            do { resolved = try base.execute("effects.catalog", params: ["item": .string(id), "start": 1, "fields": .object(fields)]) }
            catch { refused.append("\(id): effects.catalog refused its own item: \(error)"); continue }
            guard let command = resolved["command"]?.stringValue, let params = resolved["params"] else { refused.append("\(id): no command"); continue }
            #expect(Commands.all.contains { $0.id == command }, "\(id) names \(command), which does not exist")
            // On a scratch copy of the reel: nothing reaches the base project.
            let scratch = Engine(services: services)
            _ = try scratch.execute("project.open", params: ["path": .string(try RigProject.rich().path)])
            _ = try scratch.execute("brandkit.apply", params: ["kit": "cafe-atelier"])
            tried += 1
            do { _ = try scratch.execute(command, params: params) } catch {
                let raw = "\(error)"
                if raw.contains("not found at") || raw.contains("Settings › Motori") { engines.append("\(id) (\(command)): \(raw.prefix(120))"); continue }
                if raw.contains("— run ") { first.append("\(id) (\(command)): \(raw.prefix(160))"); continue }
                refused.append("\(id) (\(command) \(params.text().prefix(160))): \(raw.prefix(240))")
            }
        }
        for r in refused { FileHandle.standardError.write(Data("catalogue refused: \(r)\n".utf8)) }
        FileHandle.standardError.write(Data(("catalogue: \(tried) entries run, \(engines.count) need an engine this Mac has not: \(engines.joined(separator: "; ")); \(first.count) need a step first: \(first.joined(separator: "; "))\n").utf8))
        #expect(refused.isEmpty, "catalogue entries refused by their own command:\n\(refused.joined(separator: "\n"))")
    }
}
}

extension Journey {
    /// What the Graphics panel's «Qui, a …» list shows with the playhead at `t` (the Graphics activity, Claude's tab on
    /// the right): the line of the applied item `id` (AppliedItems' id, "clip-<clip id>").
    func graphicsListShows(_ id: String, at t: Double) async -> (shown: Bool, label: String) {
        store.preview.seek(t)
        let back = store.nav
        store.nav = Navigation(activity: .graphics, rightTab: back.rightTab)
        await app.settle()
        let label = AppliedItems.list(store.project).first { $0.id == id }?.label ?? "?"
        // The section's label is drawn in capitals.
        let here = loc("Qui, a %@", shortTime(store.preview.playhead.time)).uppercased()
        let seen = await until(3) { rig.elements().contains { $0.visible && $0.name.uppercased() == here } && shows(label) }
        return (seen, label)
    }

    /// The Audio panel's «Piste» and «Musica» (the Audio activity): whether it reads `text`.
    func audioPanelShows(_ text: String) async -> Bool {
        let back = store.nav
        store.nav = Navigation(activity: .audio, rightTab: back.rightTab)
        await app.settle()
        let seen = await until(3) { shows(text) }
        return seen
    }

    /// Every `tool {param: …}` the recipe writes names parameters the tool accepts (a renamed parameter is a defect of
    /// the recipe). Returns the mismatches.
    func recipeParameters(_ text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: "\\b([a-z]+_[a-zA-Z]+) \\{([^}]*)\\}")
        let ns = text as NSString
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tool = ns.substring(with: m.range(at: 1)), inside = ns.substring(with: m.range(at: 2))
            guard let command = Commands.all.first(where: { MCPServer.toolName($0.id) == tool }) else { continue }
            let accepted = Set(command.descriptor.params.map(\.name))
            let keys = try! NSRegularExpression(pattern: "(?:^|[,{] *)([a-zA-Z]+):").matches(in: inside, range: NSRange(location: 0, length: (inside as NSString).length))
                .map { (inside as NSString).substring(with: $0.range(at: 1)) }
            for k in keys where !accepted.contains(k) { out.append("\(tool) {\(k)} (accepted: \(accepted.sorted().joined(separator: ", ")))") }
        }
        return out
    }

    /// Journey 12 (GraphicsJourneyTests.claudeAddsTheGraphicsOfAReel).
    func claudeReelGraphics() async throws {
        let take = try take("ripresa.mov")
        await open(Navigation(activity: .home, rightTab: .claude))
        let link = try await connectClaude()
        step("Claude connects", sees: "«Claude collegato», the Claude panel open")
        let recipe = await readRecipe(link, "reel-graphics", order: ["brandkit_apply", "transcript_timeline", "title_add", "effects_catalog", "effects_preview",
                                                                    "motion_add", "sticker_add", "sfx_onCuts", "audio_addMusic", "frame_contactSheet",
                                                                    "graphics_checkLayout", "rules_check", "export_render", "audio_checkDucking",
                                                                    "sfx_checkOnsets", "captions_checkTiming", "effects_check", "export_mlt"])
        let wrong = recipeParameters(recipe)
        #expect(wrong.isEmpty, "the recipe names parameters its tools do not accept: \(wrong)")

        // The cut reel of journey 8, its voice and captions.
        let name = "Grafica di Claude"
        try await claudeCutsAReel(link, take: take, name: name)
        let captions = await claude(link, "captions.generate", ["style": "talking-head-v1", "keywords": ["REGISTA", "PAUSE"]])
        #expect(!captions.reply.isError, "captions_generate: \(captions.reply.text.prefix(200))")
        step("captions_generate", sees: await seesClaude("captions.generate", captions.reply))

        // 1. brandkit_list, brandkit_apply: the tab's «Marca: …» names it.
        let kits = await claude(link, "brandkit.list")
        let kitNames = kits.reply.result?["kits"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(kitNames.contains("cafe-atelier"), "brandkit_list does not list the kit the recipe names: \(kitNames)")
        step("brandkit_list", sees: await seesClaude("brandkit.list", kits.reply) + "; \(kitNames.joined(separator: ", "))")
        let kit = await claude(link, "brandkit.apply", ["kit": "cafe-atelier"])
        let kitName = kit.reply.result?["name"]?.stringValue ?? "?"
        // The Marca button reads as its tooltip: the kit's name is what the window shows of it.
        let marca = await until(3) { shows(kitName) && store.project?.brand?.id == "cafe-atelier" }
        #expect(!kit.reply.isError && marca, "the tab does not say «Marca: \(kitName)»: \(screen())")
        step("brandkit_apply {kit: cafe-atelier}", sees: await seesClaude("brandkit.apply", kit.reply) + "; «\(loc("Marca: %@", kitName))»")

        // 2. transcript_timeline: the beats (a title lands on the word).
        let words = await claude(link, "transcript.timeline")
        let list = words.reply.result?["words"]?.arrayValue ?? []
        #expect(!list.isEmpty, "transcript_timeline: \(words.reply.text.prefix(200))")
        let beat = list.first { ($0["text"]?.stringValue ?? "").lowercased().hasPrefix("regista") } ?? list.first
        let wordStart = beat?["start"]?.doubleValue ?? 0.5
        step("transcript_timeline", sees: await seesClaude("transcript.timeline", words.reply) + "; «\(beat?["text"]?.stringValue ?? "?")» at \(shortTime(wordStart))")

        // 3. effects_catalog, then effects_preview: the edit and the history untouched.
        let catalog = await claude(link, "effects.catalog")
        let items = catalog.reply.result?["items"]?.arrayValue ?? []
        #expect(items.count > 100, "effects_catalog: \(catalog.reply.text.prefix(200))")
        step("effects_catalog", sees: await seesClaude("effects.catalog", catalog.reply))
        let template = try #require(items.first { $0["category"] == "templates" }?["id"]?.stringValue, "no motion template in the catalogue")
        let before = store.project, undo = store.undoNames
        let preview = await claude(link, "effects.preview", ["item": .string(template), "at": 2, "frames": 3], timeout: 180)
        #expect(!preview.reply.isError, "effects_preview: \(preview.reply.text.prefix(200))")
        #expect(store.project == before && store.undoNames == undo, "effects_preview changed the edit or the history")
        step("effects_preview {item: \(template)}", sees: await seesClaude("effects.preview", preview.reply) + "; the timeline and the history unchanged")

        // 4. title_add on the word: on its lane at the same times, in the Inspector, in Grafica's «Qui, a …».
        let title = await claude(link, "title.add", ["text": "OGGI", "preset": "hook", "start": .number(wordStart), "duration": 1.5])
        let titleClip = title.reply.result?["clip"]
        let titleID = titleClip?["id"]?.stringValue ?? ""
        let onLane = store.project?.tracks.flatMap(\.clips).first { $0.id == titleID }
        #expect(!title.reply.isError && onLane.map { abs($0.start.seconds - (titleClip?["start"]?.doubleValue ?? -1)) < 0.001 && abs($0.end.seconds - (titleClip?["end"]?.doubleValue ?? -1)) < 0.001 } == true,
                "title_add: the window's clip \(String(describing: onLane.map { ($0.start.seconds, $0.end.seconds) })) is not the reply's: \(title.reply.text.prefix(200))")
        let titleLine = await seesClaude("title.add", title.reply)
        let titleTrack = store.project?.tracks.first { $0.clips.contains { $0.id == titleID } }
        if let onLane, let titleTrack, let x = timelineX((onLane.start.seconds + onLane.end.seconds) / 2), let y = laneY(loc(titleTrack.name)) ?? laneY(titleTrack.name) {
            rig.click(CGPoint(x: x, y: y))
            await app.settle()
            try await tap("Ispettore")
            #expect(await until(3) { shows("OGGI") && store.selection.contains(titleID) }, "the Inspector does not show the title «OGGI»: \(screen())")
            step("title_add «OGGI» on «\(beat?["text"]?.stringValue ?? "?")»; clicks it, the Inspector", sees: titleLine + "; the title selected, its text in the Inspector")
            try await tap("Claude")
        } else {
            Issue.record("the title is not on a lane of the timeline: \(screen())")
        }
        let titleHere = await graphicsListShows("clip-\(titleID)", at: wordStart + 0.5)
        #expect(titleHere.shown, "Grafica's «Qui, a …» does not list «\(titleHere.label)»: \(screen())")
        step("Grafica with the playhead on the title", sees: "«\(loc("Qui, a %@", shortTime(wordStart + 0.5)))»: «\(titleHere.label)»")

        // 5. A motion template, the way the catalogue resolves it.
        let resolved = await claude(link, "effects.catalog", ["item": .string(template), "start": 3])
        let command = resolved.reply.result?["command"]?.stringValue ?? ""
        #expect(command == "motion.add", "effects_catalog {item: \(template)} resolves to «\(command)»")
        let motion = await claude(link, command.isEmpty ? "motion.add" : command, resolved.reply.result?["params"] ?? ["template": .string(template), "start": 3])
        let motionID = motion.reply.result?.value(at: "clip.id")?.stringValue ?? ""
        #expect(!motion.reply.isError && store.project?.tracks.flatMap(\.clips).contains { $0.id == motionID } == true, "motion_add: \(motion.reply.text.prefix(200))")
        let motionLine = await seesClaude("motion.add", motion.reply)
        let motionHere = await graphicsListShows("clip-\(motionID)", at: (motion.reply.result?.value(at: "clip.start")?.doubleValue ?? 3) + 0.3)
        #expect(motionHere.shown, "Grafica's «Qui, a …» does not list «\(motionHere.label)»: \(screen())")
        step("motion_add {template: \(template)} (as effects_catalog resolved it)", sees: motionLine + "; Grafica lists «\(motionHere.label)»")

        // 6. A sticker on a punchline (once the title has left: both live in the top band, and a sticker under a title is
        // drawn under it: effects_check says so) and a callout on what the voice names.
        let sticker = await claude(link, "sticker.add", ["sticker": "fire", "start": 2, "duration": 0.45])
        let stickerID = sticker.reply.result?.value(at: "clip.id")?.stringValue ?? ""
        #expect(!sticker.reply.isError, "sticker_add: \(sticker.reply.text.prefix(200))")
        let stickerLine = await seesClaude("sticker.add", sticker.reply)
        let stickerHere = await graphicsListShows("clip-\(stickerID)", at: 2.2)
        #expect(stickerHere.shown, "Grafica's «Qui, a …» does not list the sticker: \(screen())")
        step("sticker_add {fire, 2 s}", sees: stickerLine + "; Grafica lists «\(stickerHere.label)»")
        let callout = await claude(link, "callout.add", ["kind": "circle", "start": 2.2, "duration": 1, "rect": [380, 700, 320, 200]])
        let calloutID = callout.reply.result?.value(at: "clip.id")?.stringValue ?? ""
        #expect(!callout.reply.isError, "callout_add: \(callout.reply.text.prefix(200))")
        let calloutLine = await seesClaude("callout.add", callout.reply)
        let calloutHere = await graphicsListShows("clip-\(calloutID)", at: 2.6)
        #expect(calloutHere.shown, "Grafica's «Qui, a …» does not list the callout: \(screen())")
        step("callout_add {circle, 2.2 s}", sees: calloutLine + "; Grafica lists «\(calloutHere.label)»")

        // 7. Sound effects on the cuts: the Effetti track in the Audio panel with as many clips.
        let library = await claude(link, "sfx.library")
        step("sfx_library", sees: await seesClaude("sfx.library", library.reply))
        let sfx = await claude(link, "sfx.onCuts")
        #expect(!sfx.reply.isError, "sfx_onCuts: \(sfx.reply.text.prefix(200))")
        let placed = Int(sfx.reply.result?["placed"]?.doubleValue ?? 0)
        let sfxTrack = store.project?.tracks.first { $0.role == "sfx" }
        #expect(sfxTrack?.clips.count == placed, "sfx_onCuts placed \(placed), the Effetti track has \(sfxTrack?.clips.count ?? 0)")
        let sfxLine = await seesClaude("sfx.onCuts", sfx.reply)
        let count = placed == 1 ? loc("1 clip") : String(format: loc("%d clip"), placed)
        #expect(await audioPanelShows(loc("track.sfx")) && shows(count), "the Audio panel does not show the Effetti track with \(count): \(screen())")
        step("sfx_onCuts", sees: sfxLine + "; Audio › Piste: «\(loc("track.sfx"))», \(count)")

        // 8. Music under the voice: the Audio panel's Musica with its file, ducking on.
        let bed = try music("musica.wav", seconds: 8)
        let added = await claude(link, "audio.addMusic", ["path": .string(bed.path)], timeout: 180)
        #expect(!added.reply.isError && store.project?.tracks.contains { $0.role == "music" && !$0.clips.isEmpty } == true, "audio_addMusic: \(added.reply.text.prefix(200))")
        let musicLine = await seesClaude("audio.addMusic", added.reply)
        #expect(await audioPanelShows("musica.wav") && control(loc("Abbassa sotto la voce"))?.value == "1", "the Audio panel does not show the music ducked: \(screen())")
        step("audio_addMusic musica.wav", sees: musicLine + "; Audio › Musica: «musica.wav», «\(loc("Abbassa sotto la voce"))» on")
        store.nav = Navigation(activity: .media, rightTab: .claude)
        await app.settle()

        // 9. Look, then the recipe's checks, the rules, the export and the checks on the file.
        let sheet = await claude(link, "frame.contactSheet", ["times": [.number(wordStart + 0.5), 2.2, 2.6, 3.3]])
        #expect(!sheet.reply.isError, "frame_contactSheet: \(sheet.reply.text.prefix(200))")
        step("frame_contactSheet {the graphics beats}", sees: await seesClaude("frame.contactSheet", sheet.reply))
        let layout = await claude(link, "graphics.checkLayout")
        step("graphics_checkLayout", sees: await seesClaude("graphics.checkLayout", layout.reply) + (layout.reply.isError ? "; refused: \(layout.reply.text.prefix(160))" : "; pass \(layout.reply.result?["pass"]?.boolValue == true)"))
        let check = await claude(link, "rules.check")
        step("rules_check", sees: await seesClaude("rules.check", check.reply))
        if check.reply.result?["pass"] != true {
            let fixed = await claude(link, "rules.fix", ["all": true])
            step("rules_fix {all: true}", sees: await seesClaude("rules.fix", fixed.reply) + "; pass \(fixed.reply.result?.value(at: "check.pass")?.boolValue == true)")
        }
        let movie = scratch.appendingPathComponent("grafica.mp4")
        let export = await claude(link, "export.render", ["path": .string(movie.path), "preset": "9:16", "loudness": -15], timeout: 240)
        #expect(!export.reply.isError && FileManager.default.fileExists(atPath: movie.path), "export_render: \(export.reply.text.prefix(300))")
        step("export_render {9:16, loudness: −15}", sees: await seesClaude("export.render", export.reply) + (export.reply.isError ? "; refused: \(export.reply.text.prefix(160))" : ""))
        guard FileManager.default.fileExists(atPath: movie.path) else { return }
        for (tool, args) in [("audio.checkDucking", [:] as JSONValue), ("sfx.checkOnsets", ["path": .string(movie.path)]),
                             ("captions.checkTiming", ["path": .string(movie.path)]), ("effects.check", ["path": .string(movie.path)])] {
            let r = await claude(link, tool, args, timeout: 180)
            #expect(!r.reply.isError, "\(tool) refused: \(r.reply.text.prefix(300))")
            #expect(r.reply.result?["pass"] != false, "\(tool) does not pass: \(r.reply.text.prefix(600))")
            if r.reply.result?["pass"] == false { FileHandle.standardError.write(Data("journey 12: \(tool) does not pass: \(r.reply.text.prefix(1500))\n".utf8)) }
            step(MCPServer.toolName(tool), sees: await seesClaude(tool, r.reply) + (r.reply.isError ? "; refused: \(r.reply.text.prefix(160))" : "; pass \(r.reply.result?["pass"]?.boolValue.map { "\($0)" } ?? "–")"))
        }
        let mlt = await claude(link, "export.mlt", ["path": .string(scratch.appendingPathComponent("grafica.mlt").path)])
        #expect(!mlt.reply.isError, "export_mlt: \(mlt.reply.text.prefix(200))")
        step("export_mlt", sees: await seesClaude("export.mlt", mlt.reply))
    }
}
