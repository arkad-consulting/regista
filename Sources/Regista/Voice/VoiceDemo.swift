import Foundation
import RegistaCore

/// ui.screenshot's voice states (V1 #61, V2 #62, V3): a demo VoiceModel built from a value — never the owner's profile,
/// never a command. `state` names a Voce panel state, a page of the "Gestisci voci" window or the Settings section.
@MainActor
enum VoiceDemo {
    /// The panel: engine missing, the way into cloning (no profile, no voice), the text tool with one tone, with several
    /// tones (trained: no hint), with the training hint, rendering, placed, the lexicon, a model made outside the app.
    static let panelStates = ["engine-missing", "no-profile", "no-voice", "one-tone", "ready", "hint", "rendering", "placed", "lexicon", "imported"]
    /// The window: the profile, the intro of a new language, consent, recording a tone, the checks, a language's overview
    /// (on Pro, on Medium), a training running, a model made outside the app.
    static let setupStates = ["profile", "intro", "consent", "record", "check-good", "check-poor", "overview", "overview-low-ram", "training", "imported"]

    static let sampleText = "Vous publiez une vidéo par semaine ? Avec WeSites, votre site se met à jour tout seul, sans toucher une ligne de code.\n\nAujourd'hui, je vous montre comment ça marche, en moins d'une minute."   // l10n-ignore

    /// `tier` overrides the Mac's tier (base, medium, pro).
    static func model(_ state: String, tier: String?) -> VoiceModel {
        var jobs: [JobCenter.Job] = []
        if state == "rendering" {
            jobs.append(.init(id: UUID(), kind: "voice", title: loc("Voce: 2 paragrafi"), detail: String(format: loc("Paragrafo %d di %d"), 1, 2),
                              progress: 0.38, cancellable: true))
        }
        if state == "training" {
            jobs.append(.init(id: UUID(), kind: "voice-training", title: String(format: loc("Allenamento della voce · %@"), VoiceLanguages.name("fr")),
                              detail: String(format: loc("Passo %d di %d · circa %d min"), 425, 1000, 71), progress: 0.425, cancellable: false))
        }
        let m = VoiceModel(store: nil, demo: true, jobs: JobCenter(jobs: jobs))
        m.snapshot = snapshot(state, tier: tier)
        switch state {
        case "one-tone", "ready", "hint", "rendering", "placed", "imported":
            m.text = sampleText
            m.language = "fr"
            if state == "placed" { m.placed = .init(trackId: "t4", clipIds: ["c12", "c13"], seconds: 14.6, text: sampleText) }
        case "lexicon":
            m.pane = .lexicon
            m.language = "fr"
            m.lexiconLanguage = "fr"
            m.lexicon = [.init(word: "WeSites", say: "We Sites", pending: false), .init(word: "Wi-Fi", say: "Oui-Fi", pending: false),   // l10n-ignore
                         .init(word: "Claude Code", say: "Clode Code", pending: false), .init(word: "Kimi", say: "Ki-mi", pending: true)]   // l10n-ignore
        default: break
        }
        if setupStates.contains(state) {
            let newLanguage = state == "intro" || state == "consent" || state == "check-good"
            m.setup.language = newLanguage ? "pt" : "fr"
            m.setup.started = state == "consent"
            m.setup.consent = newLanguage
                ? "Eu me chamo Léa e aceito que o Regista aprenda a minha voz para criar um clone que fale por mim."   // l10n-ignore
                : "Je m'appelle Léa, et j'accepte que Regista apprenne ma voix pour en faire un clone qui parle pour moi."   // l10n-ignore
            // The record page's block (a few sample lines); elsewhere the times are the shipped scripts' lengths.
            if state == "record" { m.setup.pendingTone = "enthusiastic"; m.setup.lines = ["enthusiastic": enthusiasticLines] }
            if state == "check-good" {
                m.setup.check = VoiceTakeCheck(tone: "neutral", result: ["accepted": 46, "total": 50, "missing": [], "consent": true,
                                                                         "languageMinutes": 9.4, "reference": "refs/neutral.wav"])
            }
            if state == "check-poor" {
                m.setup.check = VoiceTakeCheck(tone: "serious", result: ["accepted": 4, "total": 12, "consent": true, "languageMinutes": 9.8,
                                                                         "missing": .array(sampleLines.prefix(8).map { .string($0) })])
            }
        }
        return m
    }

    static func snapshot(_ state: String, tier: String?) -> VoiceSnapshot {
        var s = VoiceSnapshot()
        s.loaded = true
        let medium = state == "overview-low-ram" || state == "one-tone"
        s.tier = tier ?? (state == "engine-missing" ? "base" : (medium ? "medium" : "pro"))
        s.engineAvailable = state != "engine-missing" && s.tier != "base"
        s.engineReason = s.engineAvailable ? nil : "needs the medium tier"   // l10n-ignore
        s.trainerAvailable = s.tier == "pro"
        s.trainerReason = s.trainerAvailable ? nil : "tier"
        switch state {
        case "no-profile", "profile", "engine-missing":
            return s
        case "no-voice":
            s.profile = "Léa"   // l10n-ignore
            return s
        case "imported":
            // A voice trained outside the app: French, neutral, a model and no recorded minutes in the profile.
            s.profile = "Léa"   // l10n-ignore
            s.languages = [VoiceLanguageState(code: "fr", ready: true, trained: true, tones: ["neutral"])]
            return s
        default:
            s.profile = "Léa"   // l10n-ignore
        }
        var fr = VoiceLanguageState(code: "fr", ready: true, trained: state == "ready" || state == "rendering" || state == "placed" || state == "lexicon",
                                    tones: ["neutral", "serious", "calm"], lexiconEntries: 4, lexiconPending: 1)
        fr.consent = true
        fr.zeroShotReady = true
        fr.recorded = ["neutral": 9.4, "serious": 2.1, "calm": 1.8]
        fr.seconds = 13.3 * 60
        fr.trainEstimateMinutes = 107
        if state == "training" { fr.training = .running(step: 425, steps: 1000, minutesLeft: 71) }
        if state == "one-tone" { fr.tones = ["neutral"]; fr.recorded = ["neutral": 9.4]; fr.seconds = 9.4 * 60 }
        if state == "check-poor" { fr.recorded["serious"] = nil; fr.tones = ["neutral", "calm"] }
        var it = VoiceLanguageState(code: "it", ready: true, tones: ["neutral"])
        it.consent = true
        it.zeroShotReady = true
        it.recorded = ["neutral": 3.2]
        it.seconds = 192
        s.languages = state == "one-tone" ? [fr] : [it, fr]
        if state == "check-good" {
            var pt = VoiceLanguageState(code: "pt", ready: true, tones: ["neutral"])
            pt.consent = true
            pt.zeroShotReady = true
            pt.recorded = ["neutral": 9.4]
            pt.seconds = 9.4 * 60
            s.languages.append(pt)
        }
        return s
    }

    static let sampleLines = [
        // l10n-ignore-begin (sample script lines: user content)
        "Le site est en ligne depuis ce matin, et tout fonctionne comme prévu.",
        "Votre téléphone affiche la page d'accueil en moins d'une seconde.",
        "On regarde ensemble les réglages de la newsletter avant de l'envoyer.",
        "Chaque article publié apparaît tout de suite dans le menu principal.",
        "Si quelque chose ne va pas, vous recevez un message avec la solution.",
        "La facture du mois arrive le premier, toujours au même montant.",
        "Vous pouvez changer les couleurs du site en deux clics, sans développeur.",
        "Les photos sont compressées automatiquement pour rester nettes et légères.",
        // l10n-ignore-end
    ]

    static let enthusiasticLines = [
        // l10n-ignore-begin (sample script lines: user content)
        "C'est en ligne ! Le site est sorti ce matin, et tout fonctionne du premier coup.",
        "Regardez ça : la page s'affiche en moins d'une seconde sur votre téléphone.",
        "Et le meilleur, c'est que vous n'avez plus rien à faire : tout se met à jour tout seul.",
        "Franchement, on ne pensait pas y arriver aussi vite.",
        // l10n-ignore-end
    ]

    /// The profiles the Settings render lists.
    static let profiles: [ProfileSettings.ProfileRow] = [.init(id: "lea", name: "Léa", active: true, locked: false)]   // l10n-ignore
}
