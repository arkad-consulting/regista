import Foundation

// MARK: - Errori

struct RegistaError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Preferenze

enum Prefs {
    static let autoEditKey = "autoEditAfterRecording"
    /// Read once, to carry the old "start the teleprompter with the recording" choice into RecordingSources.
    static let startPrompterKey = "startPrompterWithRecording"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoEditKey: true,
            startPrompterKey: true,
        ])
    }

    static var autoEdit: Bool { UserDefaults.standard.bool(forKey: autoEditKey) }
}

// MARK: - Cartelle

enum Paths {
    /// Regista's folder (projects, recordings, exports): Impostazioni › Generale, default ~/Movies/Regista. REGISTA_FOLDER
    /// replaces it (the tests: what they record or save never lands in the user's folder).
    static var root: URL {
        if let p = ProcessInfo.processInfo.environment["REGISTA_FOLDER"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        if let p = UserDefaults.standard.string(forKey: GeneralPrefs.folderKey), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return defaultRoot
    }
    static var defaultRoot: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appendingPathComponent("Regista", isDirectory: true)
    }
    static var recordings: URL { ensure(root.appendingPathComponent("Registrazioni", isDirectory: true)) }

    @discardableResult
    static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func safeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return s.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Formattazione

func timecode(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}
