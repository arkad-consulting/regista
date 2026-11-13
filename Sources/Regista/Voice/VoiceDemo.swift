import Foundation
import RegistaCore

/// ui.screenshot's voice states (V1 #61, V2 #62): a demo VoiceModel built from a value — never the owner's profile,
/// never a command. `state` names a Voce panel state, a step of the recording flow or the Settings section.
@MainActor
enum VoiceDemo {
    static let panelStates = ["engine-missing", "no-profile", "no-voice", "ready", "rendering", "placed", "lexicon"]
    static let setupStates = ["profile", "language", "consent", "record", "check-good", "check-poor", "train", "train-low-ram", "training"]

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
        case "ready", "rendering", "placed":
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
            m.setup.language = state == "language" || state == "profile" ? nil : "fr"
            m.setup.consent = "Je m'appelle Léa, et j'accepte que Regista apprenne ma voix pour en faire un clone qui parle pour moi."   // l10n-ignore
            m.setup.lines = ["neutral": sampleLines]
            m.setup.forced = switch state {
            case "check-good", "check-poor": .check
            case "train", "train-low-ram": .overview
            default: VoiceSetupStep(rawValue: state)
            }
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
        s.tier = tier ?? (state == "engine-missing" ? "base" : (state == "train-low-ram" ? "medium" : "pro"))
        s.engineAvailable = state != "engine-missing" && s.tier != "base"
        s.engineReason = s.engineAvailable ? nil : "needs the medium tier"   // l10n-ignore
        s.trainerAvailable = s.tier == "pro"
        s.trainerReason = s.trainerAvailable ? nil : "tier"
        switch state {
        case "no-profile", "profile", "engine-missing":
            return s
        case "no-voice", "language", "consent":
            s.profile = "Léa"   // l10n-ignore
            return s
        case "record":
            s.profile = "Léa"   // l10n-ignore
            s.languages = [VoiceLanguageState(code: "fr")]
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
        if state == "training" { fr.trained = false; fr.training = .running(step: 425, steps: 1000, minutesLeft: 71) }
        if state == "train" || state == "train-low-ram" || state.hasPrefix("check") { fr.trained = false; fr.tones = ["neutral", "calm"] }
        if state == "check-poor" { fr.recorded["serious"] = nil }
        var it = VoiceLanguageState(code: "it", ready: true, tones: ["neutral"])
        it.consent = true
        it.zeroShotReady = true
        it.recorded = ["neutral": 3.2]
        it.seconds = 192
        s.languages = [it, fr]
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

    /// The profiles the Settings render lists.
    static let profiles: [ProfileSettings.ProfileRow] = [.init(id: "lea", name: "Léa", active: true, locked: false)]   // l10n-ignore
}
