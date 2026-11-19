import Foundation
import RegistaCore

/// The texts that name a script of the source folder (scripts/install.sh, scripts/build-app.sh…) and what a release build
/// says instead (#113): a downloaded app has no source folder; it can be installed again from its disk image, and Settings
/// › Claude reconnects Claude to it. Both are keys of the tables; `pick` chooses by the bundle's `RegistaRelease`.
enum ReleaseWords {
    static let forRelease: [String: String] = [
        "Non incluso in questa build: installa l'app con scripts/install.sh":
            "Non incluso in questa copia: installa di nuovo Regista dalla sua immagine disco",
        "Non trovo regista-mcp: esegui scripts/install.sh":
            "Non trovo regista-mcp: installa di nuovo Regista dalla sua immagine disco",
        "Questa copia di Regista non contiene l'installatore: usa scripts/install.sh":
            "Questa copia di Regista non contiene l'installatore: installala di nuovo dalla sua immagine disco",
        "Questa app è più vecchia del server MCP collegato: chiudi Regista, esegui scripts/build-app.sh --install e riaprila.":
            "L'app e il server MCP collegato vengono da copie diverse di Regista: in Impostazioni › Claude ricollega Claude a questa app, poi riavvia la sessione di Claude.",
        "Il server MCP collegato è più vecchio di questa app: esegui scripts/build-mcp.sh e riavvia la sessione di Claude.":
            "L'app e il server MCP collegato vengono da copie diverse di Regista: in Impostazioni › Claude ricollega Claude a questa app, poi riavvia la sessione di Claude.",
        "Questa app e il server MCP collegato vengono da build diverse: esegui scripts/build-app.sh --install, riapri Regista e riavvia la sessione di Claude.":
            "L'app e il server MCP collegato vengono da copie diverse di Regista: in Impostazioni › Claude ricollega Claude a questa app, poi riavvia la sessione di Claude.",
        // An install step of the engine manifest (Settings › Motori › ComfyUI, keyed by its English text).
        "Check it: ask Claude for generate.check (or run scripts/install.sh --with comfyui). It lists every missing node pack and model file, with the ComfyUI folder it goes in.":
            "Check it: ask Claude for generate.check. It lists every missing node pack and model file, with the ComfyUI folder it goes in.",
    ]

    /// `key`, or what a release build says instead when `bundle` is one.
    static func pick(_ key: String, bundle: Bundle = .main) -> String {
        ReleaseBuild.isRelease(bundle) ? forRelease[key] ?? key : key
    }
}
