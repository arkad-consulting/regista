import Foundation
import RegistaCore

/// What happened, in one sentence a person reads (#79): the second line of a step in the Claude panel (and of «Ultimo
/// export», the same row), built from the command's result in the app's language. Every command a recipe names has
/// one; a command without a sentence of its own shows no second line (its raw fields stay in the row's tooltip,
/// `Summary.details`). Times read as the timeline shows them (`shortTime`), counts carry their noun, in the singular
/// when there is one. The keys are the Italian text (Words.swift); a test walks every command the recipes name.
enum CommandLines {
    /// The sentence for `command`'s result, or nil when the command has none.
    static func line(_ command: String, _ r: JSONValue) -> String? {
        guard case .object = r else { return nil }
        if r["dryRun"] == true { return loc("Solo una prova: niente è cambiato") }
        switch command {
        // Reading and finding
        case "recipe.get":
            if let list = r["recipes"]?.arrayValue { return count(list.count, "1 ricetta disponibile", "%@ ricette disponibili") }
            return loc("Ricetta letta")
        case "media.list": return count(r["files"]?.arrayValue?.count ?? 0, "1 file trovato", "%@ file trovati")
        case "text.read": return loc("Letto «%@»", file(r["path"]))
        case "project.state":
            guard r["open"] == true else { return loc("Nessun progetto aperto") }
            return loc("Durata del progetto: %@", time(r["duration"]))
        case "effects.catalog":
            if r["item"] != nil { return loc("1 voce del catalogo") }
            return count(r["items"]?.arrayValue?.count ?? 0, "1 voce del catalogo", "%@ voci del catalogo")
        case "effects.preview": return loc("Anteprima pronta, il montaggio non cambia")
        case "frame.contactSheet": return count(r["times"]?.arrayValue?.count ?? 0, "Foglio di 1 fotogramma", "Foglio di %@ fotogrammi")
        case "frame.render":
            let n = r["frames"]?.arrayValue?.count ?? int(r["frames"]) ?? (r["path"] != nil ? 1 : 0)
            return count(n, "1 fotogramma disegnato", "%@ fotogrammi disegnati")
        case "frame.elements": return count(r["elements"]?.arrayValue?.count ?? 0, "1 elemento nel fotogramma", "%@ elementi nel fotogramma")
        case "layout.presets": return count(r["presets"]?.arrayValue?.count ?? 0, "1 disposizione per questo formato", "%@ disposizioni per questo formato")
        case "transcript.timeline": return count(int(r["count"]) ?? 0, "1 parola sulla timeline", "%@ parole sulla timeline")
        case "captions.get": return count(r["list"]?.arrayValue?.count ?? int(r["chunks"]) ?? 0, "1 blocco di sottotitoli", "%@ blocchi di sottotitoli")
        case "sfx.library":
            return count(r["effects"]?.arrayValue?.count ?? r["sounds"]?.arrayValue?.count ?? 0, "1 effetto sonoro", "%@ effetti sonori")
        case "brandkit.list": return count(r["kits"]?.arrayValue?.count ?? 0, "1 brand kit", "%@ brand kit")

        // The project
        case "project.new": return loc("Progetto «%@» creato", r["name"]?.stringValue ?? "")
        case "project.save": return loc("Salvato in «%@»", file(r["path"]))
        case "project.format": return loc("Formato %@×%@", "\(int(r["width"]) ?? 0)", "\(int(r["height"]) ?? 0)")
        case "history.undo": return loc("Annullato: %@", CommandTitles.title(r["undone"]?.stringValue ?? ""))
        case "history.redo": return loc("Ripetuto: %@", CommandTitles.title(r["redone"]?.stringValue ?? ""))
        case "profile.create": return loc("Profilo «%@» creato", r.value(at: "profile.name")?.stringValue ?? r["name"]?.stringValue ?? "")
        case "brandkit.apply": return loc("Brand kit «%@» applicato", r["name"]?.stringValue ?? r["kit"]?.stringValue ?? "")
        case "brandkit.check": return pass(r) ? loc("Il brand kit è rispettato") : loc("Il brand kit non è rispettato")

        // Media and words
        case "media.import":
            let name = file(r.value(at: "asset.path") ?? r.value(at: "asset.name"))
            if r["existing"] == true { return loc("«%@» era già nei media", name) }
            if let d = r.value(at: "asset.duration")?.doubleValue, d > 0 { return loc("Importato «%@» · %@", name, shortTime(d)) }
            return loc("Importato «%@»", name)
        case "media.extractAudio": return loc("Audio estratto")
        case "transcript.run": return count(int(r["words"]) ?? 0, "1 parola trascritta", "%@ parole trascritte")
        case "transcript.deleteWords":
            if let pieces = r["ranges"]?.arrayValue { return count(pieces.count, "Tolto 1 pezzo dal montaggio", "Tolti %@ pezzi dal montaggio") }
            return loc("Tolte le parole da %@ a %@", time(r["from"]), time(r["to"]))
        case "transcript.fillers": return count(int(r["count"]) ?? 0, "1 intercalare trovato", "%@ intercalari trovati")
        case "script.set", "script.fromTranscript":
            return count(int(r["count"]) ?? r["lines"]?.arrayValue?.count ?? 0, "1 riga di copione", "%@ righe di copione")
        case "takes.list":
            let lines = r["lines"]?.arrayValue ?? []
            let takes = lines.reduce(0) { $0 + ($1["takes"]?.arrayValue?.count ?? 0) }
            if takes == lines.count { return lines.count == 1 ? loc("1 ripresa trovata") : loc("%@ riprese trovate, una per riga", "\(takes)") }
            return loc("%1$@ per %2$@", count(takes, "1 ripresa", "%@ riprese"), count(lines.count, "1 riga", "%@ righe"))
        case "takes.select": return loc("Riga %@: ripresa %@", "\(int(r["line"]) ?? 0)", "\(int(r["chosen"]) ?? 0)")
        case "recording.import": return loc("Registrazione importata · %@", time(r["duration"]))

        // The edit
        case "edit.autoCut":
            let pieces = r["segments"]?.arrayValue?.count ?? 0
            return pieces == 1 ? loc("Tagliato a %@ in un pezzo", time(r["duration"])) : loc("Tagliato a %@ in %@ pezzi", time(r["duration"]), "\(pieces)")
        case "edit.punchIns":
            return count(r["clips"]?.arrayValue?.count ?? 0, "Inquadratura su 1 clip", "Inquadrature alternate su %@ clip")
        case "edit.autoZoom":
            if r["cleared"]?.arrayValue?.isEmpty == false, r["clicks"]?.arrayValue?.isEmpty != false { return loc("Zoom tolti") }
            return count(r["clicks"]?.arrayValue?.count ?? 0, "Zoom su 1 clic", "Zoom su %@ clic")
        case "edit.beatSync":
            return loc("%@ BPM", Words.number(((r["tempo"]?.doubleValue ?? 0) * 10).rounded() / 10)) + " · "
                + count(r["added"]?.arrayValue?.count ?? int(r["added"]) ?? 0, "1 colpo a tempo", "%@ colpi a tempo")
        case "timeline.place": return loc("Clip messa a %@", time(r.value(at: "clip.start")))
        case "timeline.trim": return loc("Clip rifilata: %@–%@", time(r.value(at: "clip.start")), time(r.value(at: "clip.end")))
        case "timeline.move": return loc("Clip spostata a %@", time(r.value(at: "clip.start")))
        case "timeline.delete": return count(r["deleted"]?.arrayValue?.count ?? 0, "1 clip eliminata", "%@ clip eliminate")
        case "track.add": return loc("Traccia aggiunta")
        case "clip.set": return count(r["clips"]?.arrayValue?.count ?? 0, "1 clip modificata", "%@ clip modificate")
        case "clip.speed": return loc("Nuova durata: %@", time(r["duration"]))
        case "clip.place": return loc("Clip posizionata")
        case "clip.follow": return r["target"] == "hand" ? loc("La clip segue la mano") : loc("La clip segue il volto")
        case "layout.apply", "layout.speaker": return loc("Disposizione da %@ a %@", time(r["from"]), time(r["to"]))
        case "cursor.style": return r["drawn"] == true ? loc("Cursore ridisegnato") : loc("Il cursore resta com'è nel video")
        case "keys.overlay":
            let badges = r["badges"]?.arrayValue?.count ?? 0
            if badges == 0, r["cleared"] == true { return loc("Tasti tolti dal video") }
            return count(badges, "1 tasto nel video", "%@ tasti nel video")

        // Look and graphics
        case "look.apply": return grade(r, project: "Look su tutto il video", one: "Look su 1 clip", many: "Look su %@ clip")
        case "adjust.set": return grade(r, project: "Colore regolato su tutto il video", one: "Colore regolato su 1 clip", many: "Colore regolato su %@ clip")
        case "style.apply":
            let applied = count(r["applied"]?.arrayValue?.count ?? 0, "1 ritocco applicato", "%@ ritocchi applicati")
            let skipped = r["skipped"]?.arrayValue?.count ?? 0
            return skipped == 0 ? applied : applied + " · " + count(skipped, "1 saltato", "%@ saltati")
        case "effect.add": return loc("Effetto aggiunto alla clip")
        case "title.add":
            let text = r.value(at: "clip.title.text")?.stringValue.map { $0.replacingOccurrences(of: "\n", with: " ") } ?? ""
            return loc("Titolo «%@» a %@", text, time(r.value(at: "clip.start")))
        case "overlay.add": return loc("Immagine sopra da %@ a %@", time(r.value(at: "clip.start")), time(r.value(at: "clip.end")))
        case "motion.add": return loc("Animazione da %@ a %@", time(r.value(at: "clip.start")), time(r.value(at: "clip.end")))
        case "sticker.add": return loc("Sticker a %@", time(r.value(at: "clip.start")))
        case "callout.add": return loc("Richiamo a %@", time(r.value(at: "clip.start")))
        case "progress.add": return loc("Barra di avanzamento aggiunta")
        case "status.add": return loc("Stato aggiunto da %@ a %@", time(r.value(at: "clip.start")), time(r.value(at: "clip.end")))
        case "meters.add": return loc("Indicatore aggiunto a %@", time(r.value(at: "clip.start")))
        case "logo.add": return loc("Logo a %@", time(r.value(at: "clip.start")))
        case "logo.animate": return loc("Logo animato a %@", time(r.value(at: "clip.start")))
        case "transition.add": return loc("Transizione a %@", time(r.value(at: "transition.at")))
        case "graphics.blenderTitle": return loc("Titolo 3D pronto")
        case "graphics.hyperframes": return loc("Grafica animata pronta")
        case "matte.track": return count(int(r["frames"]) ?? 0, "Persona ritagliata in 1 fotogramma", "Persona ritagliata in %@ fotogrammi")
        case "hands.track": return loc("Mano trovata in %@ fotogrammi su %@", "\(int(r["withHand"]) ?? 0)", "\(int(r["frames"]) ?? 0)")
        case "faces.track": return loc("Volto trovato in %@ fotogrammi su %@", "\(int(r["detected"]) ?? 0)", "\(int(r["frames"]) ?? 0)")

        // Captions
        case "captions.generate", "captions.setKeywords":
            let chunks = count(int(r["chunks"]) ?? 0, "1 blocco di sottotitoli", "%@ blocchi di sottotitoli")
            let keywords = int(r["keywordsShown"]) ?? r["keywords"]?.arrayValue?.count ?? 0
            return chunks + " · " + count(keywords, "1 parola chiave", "%@ parole chiave")
        case "captions.setStyle": return loc("Sottotitoli in stile «%@»", captionStyleName(r["style"]?.stringValue ?? r["id"]?.stringValue ?? ""))
        case "captions.place":
            if r["scope"] == "chunks" { return count(r["chunks"]?.arrayValue?.count ?? 0, "1 blocco spostato", "%@ blocchi spostati") }
            return loc("Sottotitoli spostati")

        // Sound
        case "audio.clean":
            if r["restored"] == true { return loc("Rimesso l'audio originale") }
            guard let i = r.value(at: "loudness.integrated")?.doubleValue else { return loc("Voce pulita") }
            return loc("Voce pulita a %@ LUFS", signed(i))
        case "audio.addMusic": return loc("Musica aggiunta, abbassata sotto la voce")
        case "sfx.add": return loc("Effetto sonoro a %@", time(r.value(at: "clip.start")))
        case "sfx.onCuts":
            if let removed = int(r["removed"]) { return count(removed, "1 effetto sonoro tolto", "%@ effetti sonori tolti") }
            if (int(r["placed"]) ?? 0) == 0, (int(r["existing"]) ?? 0) > 0 { return loc("Gli effetti sonori sui tagli c'erano già") }
            return count(int(r["placed"]) ?? 0, "1 effetto sonoro sui tagli", "%@ effetti sonori sui tagli")
        case "voice.list":
            if r["profile"] == .null { return loc("Nessun profilo: crealo in Impostazioni") }
            let ready = (r["languages"]?.arrayValue ?? []).filter { $0["ready"] == true }.count
            return ready == 0 ? loc("Nessuna voce pronta: registrala nel pannello Voce") : count(ready, "Voce pronta in 1 lingua", "Voce pronta in %@ lingue")
        case "voice.preview":
            return count(r["paragraphs"]?.arrayValue?.count ?? 0, "1 paragrafo", "%@ paragrafi") + " · " + time(r["seconds"])
        case "voice.say":
            return count(r["clips"]?.arrayValue?.count ?? 0, "1 clip di voce", "%@ clip di voce") + " · " + loc("fino a %@", time(r["end"]))
        case "voice.lexicon":
            return count(r["entries"]?.arrayValue?.count ?? int(r["entries"]) ?? 0, "1 pronuncia salvata", "%@ pronunce salvate")

        // Checks
        case "rules.check": return rules(r)
        case "rules.fix": return count(r["applied"]?.arrayValue?.count ?? 0, "1 correzione applicata", "%@ correzioni applicate") + " · " + rules(r["check"] ?? [:])
        case "captions.checkTiming":
            if pass(r) { return count(int(r["words"]) ?? 0, "Sottotitoli a tempo: 1 parola controllata", "Sottotitoli a tempo: %@ parole controllate") }
            let off = max(0, (int(r["words"]) ?? 0) - (int(r["withinTolerance"]) ?? 0))
            return count(off, "1 parola fuori tempo", "%@ parole fuori tempo")
        case "captions.checkFaces":
            if pass(r) { return loc("Nessun sottotitolo sul volto") }
            return count(int(r["overlappingChunks"]) ?? 0, "1 blocco di sottotitoli sul volto", "%@ blocchi di sottotitoli sul volto")
        case "faces.checkFraming":
            if pass(r) { return loc("Nessuna testa tagliata") }
            return count(int(r["framesCut"]) ?? 0, "Testa tagliata in 1 fotogramma", "Testa tagliata in %@ fotogrammi")
        case "graphics.checkLayout": return pass(r) ? loc("Fascia dei sottotitoli libera") : loc("Grafica nella fascia dei sottotitoli")
        case "graphics.checkBehindSubject": return pass(r) ? loc("Il testo passa dietro la persona") : loc("Il testo non passa dietro la persona")
        case "audio.checkDucking":
            return loc("Musica %@ dB sotto la voce", Words.number(((r["underDB"]?.doubleValue ?? 0) * 10).rounded() / 10))
        case "sfx.checkOnsets":
            return pass(r) ? count(int(r["effects"]) ?? 0, "1 effetto sonoro a tempo", "%@ effetti sonori a tempo") : loc("Effetti sonori fuori tempo")
        case "media.checkSync": return loc("Audio e video sfasati di %@ ms", Words.number(abs(r["lagMs"]?.doubleValue ?? 0)))
        case "media.checkOverlay": return pass(r) ? loc("Immagini sopra al loro posto") : loc("Immagini sopra fuori posto")
        case "effects.check": return pass(r) ? loc("Ogni effetto si vede nel video") : loc("Qualche effetto non si vede nel video")
        case "recording.check": return pass(r) ? loc("Registrazione controllata: tutto a posto") : loc("Registrazione controllata: qualcosa non va")

        // Files out
        case "export.render": return loc("Esportato %@ · %@", file(r["path"]), time(r["duration"]))
        case "cover.set": return loc("Copertina a %@", time(r["cover"]?["time"]))
        case "cover.make": return loc("Copertina salvata: %@", file(r["path"]))
        case "cover.check": return r["check"]?["pass"] == true ? loc("Copertina nei ritagli") : loc("Titolo della copertina fuori dai ritagli")
        case "export.srt": return loc("Esportato %@", file(r["path"])) + " · " + count(int(r["cues"]) ?? 0, "1 blocco", "%@ blocchi")
        case "export.mlt": return loc("Esportato %@ per Shotcut", file(r["path"]))

        // Generation
        case "generate.providers": return count(r["providers"]?.arrayValue?.count ?? 0, "1 generatore", "%@ generatori")
        case "generate.check": return r["ready"] == true ? loc("ComfyUI è pronto") : loc("A ComfyUI manca qualcosa")
        case "generate.estimate":
            guard r["paid"] == true else { return loc("Gratis, su questo Mac") }
            return loc("Costo stimato: %@ crediti", Words.number(r["credits"]?.doubleValue ?? 0))
        case "generate.run", "generate.upscale": return job(r)
        case "generate.status":
            let jobs = r["jobs"]?.arrayValue ?? [r]
            return jobs.count == 1 ? job(jobs[0]) : count(jobs.count, "1 generazione", "%@ generazioni")
        case "generate.list": return count(r["assets"]?.arrayValue?.count ?? 0, "1 file generato", "%@ file generati")
        default: return nil
        }
    }

    // MARK: Pieces

    /// "1 riga" or "2 righe": the singular key, or the plural format key with the count.
    static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? loc(one) : loc(many, "\(n)") }

    private static func int(_ v: JSONValue?) -> Int? { v?.doubleValue.map { Int($0.rounded()) } }

    /// A time as the timeline shows it ("0:03.5").
    private static func time(_ v: JSONValue?) -> String { shortTime(v?.doubleValue ?? 0) }

    private static func file(_ v: JSONValue?) -> String { v?.stringValue.map { ($0 as NSString).lastPathComponent } ?? "" }

    private static func pass(_ r: JSONValue) -> Bool { r["pass"] == true }

    /// "−15", "−14,8": a level with its sign (a true minus), one decimal at most.
    private static func signed(_ v: Double) -> String {
        Words.number((v * 10).rounded() / 10).replacingOccurrences(of: "-", with: "−")
    }

    private static func rules(_ r: JSONValue) -> String {
        if pass(r) { return loc("Controlli rispettati") }
        return count(int(r["failures"]) ?? 0, "1 controllo da sistemare", "%@ controlli da sistemare")
    }

    private static func grade(_ r: JSONValue, project: String, one: String, many: String) -> String {
        r["scope"] == "clips" ? count(r["clips"]?.arrayValue?.count ?? 0, one, many) : loc(project)
    }

    /// A generation job: started, done (its file) or failed.
    private static func job(_ j: JSONValue) -> String {
        switch j["status"]?.stringValue {
        case "done": return loc("Generato «%@»", file(j["path"] ?? j.value(at: "asset.path")))
        case "failed": return loc("Generazione non riuscita")
        default: return loc("Generazione avviata")
        }
    }
}
