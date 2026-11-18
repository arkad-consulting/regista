import AppKit
import RegistaCore
import Testing
@testable import Regista

// Journey 9: the app in French, from the first launch to the exported file (the rig's own language setting, never the
// owner's defaults). After each step: no Italian or English word left in what a person reads (controls, status lines,
// the rules card, the tooltip of a clicked control, the Claude panel's lines), no label cut or wrapped at 1440×900; then
// every screen walked again at the minimum window, and the same screens rendered in Portuguese.

/// The words of the other interface languages that must not show in `language`: a table's text that differs from the
/// `language` table's text for the same key, and is no text of `language` at all (so «Clip», «Logo», «Pro» never count).
@MainActor
struct WordsAudit {
    let language: String
    private var wrong: [String: String] = [:]
    private var formats: [(NSRegularExpression, String, String)] = []
    /// The keys SwiftUI looks up itself (`Text("…")`, `Button("…")`, `.help("…")`, `.accessibilityLabel("…")`…): in the
    /// app they are read from the app bundle's table of the Mac's language, which the rig's language setting cannot
    /// reach (it sets the table `loc` reads), so in the rig's window they show their Italian key. Not counted here.
    let swiftUIKeys: Set<String>

    static func table(_ lang: String) -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization/\(lang).lproj/Localizable.strings")
        return (NSDictionary(contentsOf: url) as? [String: String]) ?? [:]
    }

    init(_ language: String) {
        self.language = language
        var keys: Set<String> = []
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let call = try! NSRegularExpression(pattern: "(?<![A-Za-z_.])(?:Text|Button|Label|Toggle|Section|Menu|TextField|LabeledContent|\\.help|\\.accessibilityLabel|\\.navigationTitle)\\(\\s*\"((?:[^\"\\\\]|\\\\.)*)\"")
        if let files = FileManager.default.enumerator(at: root.appendingPathComponent("Sources/Regista"), includingPropertiesForKeys: nil) {
            for case let f as URL in files where f.pathExtension == "swift" {
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
                let ns = text as NSString
                for m in call.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    keys.insert(ns.substring(with: m.range(at: 1)).replacingOccurrences(of: "\\n", with: "\n"))
                }
            }
        }
        swiftUIKeys = keys
        let own = Self.table(language)
        let ownTexts = Set(own.values)
        let placeholder = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?[-+ #0]*\\d*(?:\\.\\d+)?(?:ll|l|h)?[@dDuUxXfFeEgGcs]")
        for other in ["it", "en", "pt", "fr"] where other != language {
            for (k, v) in Self.table(other) {
                guard let mine = own[k], mine != v, !ownTexts.contains(v) else { continue }
                if v.contains("%") {
                    let ns = v as NSString
                    let skeleton = placeholder.stringByReplacingMatches(in: v, range: NSRange(location: 0, length: ns.length), withTemplate: "")
                    guard skeleton.filter(\.isLetter).count >= 6 else { continue }
                    var pattern = "", last = 0
                    for m in placeholder.matches(in: v, range: NSRange(location: 0, length: ns.length)) {
                        pattern += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: last, length: m.range.location - last))) + ".+?"
                        last = m.range.location + m.range.length
                    }
                    pattern += NSRegularExpression.escapedPattern(for: ns.substring(from: last))
                    if let r = try? NSRegularExpression(pattern: "^" + pattern.replacingOccurrences(of: "%%", with: "%") + "$") { formats.append((r, other, v)) }
                } else if v.filter(\.isLetter).count >= 3 {
                    wrong[v] = other
                }
            }
        }
    }

    /// The texts of `texts` that are another language's words (with that language and the key's text).
    func leftovers(_ texts: [String]) -> [String] {
        var out: [String] = []
        for t in Set(texts) where !t.isEmpty && !swiftUIKeys.contains(t) {
            if let lang = wrong[t] { out.append("«\(t)» (\(lang))"); continue }
            let ns = t as NSString
            if let f = formats.first(where: { $0.0.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) != nil }) {
                out.append("«\(t)» (\(f.1): «\(f.2)»)")
            }
        }
        return out.sorted()
    }
}

extension Journey {
    /// What a person reads in the window: every visible element's label, title, value and value description, and the
    /// parts of a label (a row's name and detail, a tooltip's lines).
    func readable(_ r: MouseRig? = nil) -> [String] {
        var out: [String] = []
        // (An image's label is the system's description of its symbol, in the system's language: not the app's words.)
        for e in (r ?? rig).elements() where e.visible && e.role != "AXImage" {
            for s in [e.label, e.title, e.value, e.valueDescription] where !s.isEmpty {
                out.append(s)
                out += s.components(separatedBy: CharacterSet(charactersIn: "\n")).flatMap { $0.components(separatedBy: ", ") }
                if let p = s.range(of: " (") { out.append(String(s[..<p.lowerBound])) }   // «Nome (⌘X)»
            }
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Labels drawn cut or wrapped: a text whose words need more room than its frame gives at the app's smallest type
    /// (so a narrower frame is surely cut), and a short label without a line break drawn on more than two lines.
    func clippedLabels(_ r: MouseRig? = nil, data: Set<String> = []) -> [String] {
        let font = NSFont.systemFont(ofSize: Ed.TypeSize.tiny)
        var out: [String] = []
        // The status bar's hint gives way to its neighbours by design (it ends with «…»): not a label.
        let bar = Double((r ?? rig).size.height) - Double(Chrome.statusHeight)
        for e in (r ?? rig).elements() where e.visible && e.role == "AXStaticText" && e.frame.minY < bar - 1 {
            let text = e.value.isEmpty ? e.label : e.value
            guard !text.isEmpty, !text.contains("\n"), e.frame.width > 0, !data.contains(text) else { continue }
            let natural = (text as NSString).size(withAttributes: [.font: font])
            // Not cut by the edge of a scroll area or the window (that is scrolling, not a label too narrow).
            guard e.clip.insetBy(dx: -1, dy: -1).contains(e.frame) else { continue }
            if natural.width > e.frame.width + 2, e.frame.height < natural.height * 1.8 {
                out.append("«\(text)» cut: \(Int(e.frame.width)) pt for \(Int(natural.width)) pt")
            }
        }
        return out
    }
}

extension MouseSuites.ClickAudits {
@Suite(.serialized) @MainActor struct LanguageJourneyTests {
    /// 9. The app in French, from the first launch to the exported file: Enregistrer › Visage seul with the prompter and a
    /// French script typed in it; record, pause, resume, stop; the automatic edit; the transcript; a caption style;
    /// Montage › Simple, each step; Graphismes: a title and the logo of a built-in kit; Audio: a music with ducking;
    /// Exporter: the rules card, the fixes, the file. After each step: no Italian or English word in what a person reads,
    /// no label cut at 1440×900. Then each screen at the minimum window, and in Portuguese (renders).
    @Test func theAppInFrenchToTheExportedFile() async throws {
        let j = try await Journey("9-french", project: nil)
        j.language = "fr"
        let prompter = TeleprompterController.shared
        let d = UserDefaults.standard
        let saved = (text: prompter.text, mode: prompter.mode, autoEdit: d.object(forKey: Prefs.autoEditKey),
                     storedText: d.object(forKey: "prompterText"), storedMode: d.object(forKey: "prompterMode"))
        defer {
            prompter.text = saved.text
            prompter.mode = saved.mode
            d.set(saved.storedText, forKey: "prompterText")
            d.set(saved.storedMode, forKey: "prompterMode")
            d.set(saved.autoEdit, forKey: Prefs.autoEditKey)
            j.close()
        }
        try await j.french()
    }
}
}

extension Journey {
    /// Journey 9 (LanguageJourneyTests.theAppInFrenchToTheExportedFile).
    func french() async throws {
        let audit = WordsAudit("fr")
        let prompter = TeleprompterController.shared
        var findings: [String] = []
        var data: Set<String> = []
        var names: [String] = []
        /// The step's words and labels checked; findings gathered (each its own defect), the step written.
        func check(_ did: String, sees: String, tooltip: String? = nil) {
            // The project's own names and files are data, not the app's words.
            if let p = store.project {
                data.insert(p.name)
                data.formUnion(p.assets.flatMap { [$0.name, ($0.path as NSString).lastPathComponent] })
            }
            let words = audit.leftovers(readable().filter { !data.contains($0) } + (tooltip.map { [$0] } ?? []))
            let cut = clippedLabels(data: data)
            for w in words {
                let text = w.components(separatedBy: "»").first.map { String($0.dropFirst()) } ?? w
                let where_ = rig.elements().filter { $0.visible && ($0.label.contains(text) || $0.value.contains(text) || $0.title.contains(text)) }.prefix(2)
                FileHandle.standardError.write(Data("journey 9 \(did): \(w) in \(where_.map { "\($0.role) «\($0.label)» «\($0.value)» \($0.frame)" })\n".utf8))
            }
            findings += words.map { "\(did): \($0)" } + cut.map { "\(did): \($0)" }
            step(did, sees: sees + (words.isEmpty ? "" : "; other language: \(words.joined(separator: ", "))") + (cut.isEmpty ? "" : "; cut: \(cut.joined(separator: ", "))"))
        }
        /// Clicks the control of key `key` (in French on screen) and returns its tooltip, for the audit.
        @discardableResult
        func press(_ key: String, in r: MouseRig? = nil) async throws -> String {
            let e = control(loc(key), in: r)
            let help = (e?.ref as AnyObject?).flatMap { ($0.accessibilityHelp?() ?? nil) } ?? ""
            try await tap(loc(key), in: r)
            return help
        }

        UserDefaults.standard.set(true, forKey: Prefs.autoEditKey)
        app.capture.take = try take()
        app.followRecorder()
        let bench = app.store.bench
        await open(Navigation(activity: .home, rightTab: .inspector))
        #expect(store.project == nil && store.nav.activity == .home, "the empty app: \(screen())")
        check("Opens the app in French", sees: "Accueil, an empty tab")

        // Enregistrer › Visage seul.
        var tip = try await press("Registra")
        #expect(store.nav.activity == .record)
        tip += try await press("Solo volto")
        #expect(control(loc("Solo volto"))?.selected == true && app.recorder.sources.camera && !app.recorder.sources.screen)
        check("Clicks Enregistrer, Visage seul", sees: "the camera and the microphone on", tooltip: tip)

        // The prompter: a French script typed in Prompteur, its own speed, its switch on.
        let width = Double(rig.size.width)
        let gobbo = loc("Gobbo")
        let tab = try #require(rig.elements().first { $0.isControl && $0.visible && $0.name == gobbo && $0.frame.minX > width - 340 }, "no «\(gobbo)» tab: \(screen())")
        rig.click(tab.centre)
        await app.settle()
        let editor = try #require(rig.elements().first { $0.role == "AXTextArea" && $0.visible && $0.frame.minX > width - 340 }, "no script editor: \(screen())")
        rig.click(editor.centre)
        await app.settle()
        let typing = try #require(rig.window.firstResponder as? NSTextView, "the click did not put the cursor in the script")
        typing.selectAll(nil)
        let script = "Aujourd'hui Regista monte la vidéo. Les pauses disparaissent toutes seules."
        data.insert(script)
        rig.type(script)
        await app.settle()
        #expect(prompter.text == script, "the script typed is «\(prompter.text)»")
        tip = try await press("Velocità")
        #expect(prompter.mode == .speed)
        let gobboSwitch = { self.rig.elements().first { $0.isControl && $0.visible && $0.label == gobbo && $0.frame.maxX < width - 340 && ["0", "1"].contains($0.value) } }
        if let s = gobboSwitch(), s.value == "0" { rig.click(s.centre); await app.settle() }
        #expect(app.recorder.sources.prompter, "the prompter is not on for the take")
        check("Prompteur: types a French script, Vitesse; the Prompteur switch on", sees: "the script counted, the switch on", tooltip: tip)

        // Record, pause, resume, stop.
        #expect(await until { app.recorder.isReady && control(loc("Avvia / Ferma registrazione"))?.enabled == true }, "Record is not ready: \(screen())")
        tip = try await press("Avvia / Ferma registrazione")
        #expect(await until { app.recorder.isRecording }, "Record did not start")
        await app.idle(1.1)
        check("Clicks Record", sees: "the take running, the clock in the status bar", tooltip: tip)
        tip = try await press("Pausa / Riprendi")
        #expect(await until { app.recorder.isPaused }, "Pause did not pause")
        await app.idle(0.3)
        check("Clicks Pause", sees: "the take paused", tooltip: tip)
        tip = try await press("Pausa / Riprendi")
        #expect(await until { !app.recorder.isPaused })
        await app.idle(1.1)
        check("Clicks Resume", sees: "the take running again", tooltip: tip)
        tip = try await press("Avvia / Ferma registrazione")
        #expect(await until(20) { bench.notice != nil && store.project?.tracks.flatMap(\.clips).count == 2 }, "the take went nowhere: \(screen())")
        await app.settle()
        let project = try #require(store.project)
        data.insert(project.name)
        data.formUnion(project.assets.map(\.name))
        data.formUnion(project.assets.map { ($0.path as NSString).lastPathComponent })
        names.append("project «\(project.name)»; take «\(project.assets.first?.name ?? "")»; tracks \(project.tracks.map { "«\($0.name)» → «\(loc($0.name))»" }.joined(separator: ", "))")
        check("Clicks Stop", sees: "the new project «\(project.name)», the notice", tooltip: tip)

        // The automatic edit.
        #expect(await until(5) { store.jobs.latest(TextStep.allJobKind) != nil }, "the automatic edit did not start")
        #expect(await until(90) { store.jobs.latest(TextStep.allJobKind)?.isRunning == false }, "the automatic edit did not finish")
        await app.settle()
        let edited = try #require(store.project)
        data.formUnion(edited.tracks.flatMap(\.clips).compactMap { $0.title?.text })
        data.formUnion(edited.assets.flatMap { $0.analysis?.transcript?.words.map(\.text) ?? [] })
        data.formUnion(edited.script?.lines ?? [])
        data.formUnion(edited.tracks.compactMap(\.captions).flatMap { $0.chunks.map(\.text) })
        check("Waits for the automatic edit", sees: "the job done, the edit with its captions (\(String(format: "%.1f", edited.duration.seconds)) s)")

        // Textes et sous-titres › Transcription, then a caption style.
        tip = try await press("Testi e sottotitoli")
        tip += try await press("Trascrizione")
        check("Textes et sous-titres › Transcription", sees: "the take's words", tooltip: tip)
        tip = try await press("Sottotitoli")
        let before = edited.tracks.first { $0.captions != nil }?.captions?.style.id ?? ""
        let other = try #require(CaptionStyle.all.first { !(before == $0.id || before.hasPrefix($0.id + "+")) })
        tip += try await press(captionStyleName(other.id))
        #expect(await until { store.project?.tracks.first { $0.captions != nil }?.captions?.style.id.hasPrefix(other.id) == true }, "the style did not change")
        check("Sous-titres › «\(loc(captionStyleName(other.id)))»", sees: "the captions in the new style", tooltip: tip)

        // Montage › Simple: each step.
        tip = try await press("Semplice")
        #expect(await until { store.nav.level == .simple && stepRow(.cut) != nil }, "no steps: \(screen())")
        check("Clicks Simple", sees: "the six steps", tooltip: tip)
        for s in SimpleStep.allCases {
            try await openRow(s)
            if s == .look, control(loc("Luce leggera")) != nil { tip = try await press("Luce leggera") } else { tip = "" }
            check("Simple › \(s.title())", sees: "the step's panel", tooltip: tip)
        }
        tip = try await press("Pro")
        #expect(await until { store.nav.level == .pro })

        // Marque › a built-in kit; Graphismes: a title, the logo.
        try await tap(loc("Marca del progetto: il brand kit di sottotitoli, titoli e logo"))
        let picker = try #require(await popover(), "Marque opened no picker")
        check("Clicks Marque", sees: "the kits")
        let words = readable(picker)
        findings += audit.leftovers(words).map { "Marque picker: \($0)" }
        try await tap("Café Atelier", in: picker)
        #expect(await until { store.project?.brand?.id == "cafe-atelier" }, "the kit was not applied")
        data.formUnion(store.project?.assets.map { ($0.path as NSString).lastPathComponent } ?? [])
        try await toStart()
        tip = try await press("Grafica")
        let title = try await addTitle(loc("Titolo"), "BONJOUR")
        data.insert("BONJOUR")
        #expect(title.start.seconds < 0.05)
        check("Graphismes › Titre «BONJOUR», Ajouter", sees: "the title at 0:00", tooltip: tip)
        tip = try await press("Logo")
        tip += try await press("Logo nel video")
        #expect(await until { store.project?.tracks.contains { $0.role == "logo" && !$0.clips.isEmpty } == true }, "no logo: \(screen())")
        check("Graphismes › Logo › Logo dans la vidéo", sees: "the kit's logo", tooltip: tip)

        // Audio: a music, under the voice.
        tip = try await press("Audio")
        RigGuard.panelAnswer = [try music("musique.wav")]
        data.insert("musique.wav")
        tip += try await press("Aggiungi musica…")
        #expect(await until(30) { store.project.flatMap(AudioCalls.musicTrack) != nil && store.jobs.latest(AudioCalls.musicJob)?.isRunning == false }, "no music: \(screen())")
        await app.settle()
        #expect(store.project.flatMap(AudioCalls.musicTrack)?.ducking != nil, "the music does not go down under the voice")
        check("Audio › Ajouter une musique… musique.wav", sees: "the music on its track, ducked under the voice", tooltip: tip)

        // Exporter: the rules card, the fixes, the file.
        tip = try await press("Esporta")
        #expect(await until(6) { control(loc("Esporta video…")) != nil || control(loc("Sistema tutto ed esporta")) != nil }, "no way to export: \(screen())")
        await app.idle(0.5)
        check("Clicks Exporter", sees: "the rules card", tooltip: tip)
        let out = scratch.appendingPathComponent("video-fr.mp4")
        RigGuard.panelAnswer = [out]
        if control(loc("Sistema tutto ed esporta")) != nil { tip = try await press("Sistema tutto ed esporta") } else { tip = try await press("Esporta video…") }
        #expect(await until(180) { FileManager.default.fileExists(atPath: out.path) && store.jobs.latest("export")?.isRunning == false }, "no exported file: \(screen())")
        await app.settle()
        let movie = try await Journey.probe(out)
        check("Exporter › the file", sees: "the file \(movie.width)×\(movie.height), \(String(format: "%.1f", movie.seconds)) s", tooltip: tip)

        // The Claude panel: the lines of the steps, in French.
        tip = try await press("Claude")
        check("The right panel's Claude tab", sees: "the steps taken, each with its line", tooltip: tip)

        // Every screen walked again at the minimum window.
        for activity in [Navigation.Activity.home, .record, .media, .texts, .graphics, .audio, .export] {
            await open(Navigation(activity: activity, rightTab: .claude), size: RigWindowSize.minimum.size)
            await app.idle(0.3)
            let cut = clippedLabels(data: data)
            findings += cut.map { "\(activity) at the minimum window: \($0)" }
            findings += audit.leftovers(readable().filter { !data.contains($0) }).map { "\(activity) at the minimum window: \($0)" }
            step("\(activity) at 1024×640", sees: cut.isEmpty ? "nothing cut" : "cut: \(cut.joined(separator: ", "))")
        }

        // The same screens in Portuguese, rendered (read at full size in the report).
        language = "pt"
        for activity in [Navigation.Activity.home, .record, .media, .texts, .graphics, .audio, .export] {
            await open(Navigation(activity: activity, rightTab: .claude))
            await app.idle(0.3)
            step("\(activity) in Portuguese", sees: "render")
        }
        FileHandle.standardError.write(Data(("journey 9 names: " + names.joined(separator: " | ") + "\njourney 9 findings:\n" + findings.joined(separator: "\n") + "\n").utf8))
        #expect(findings.isEmpty, "\(findings.count) words in another language or labels cut:\n\(findings.joined(separator: "\n"))")
    }
}
