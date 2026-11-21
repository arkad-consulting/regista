import Foundation

/// Regista's temporary folder: every temporary file or folder Regista and its tests make goes under `url` (#138).
///
/// `REGISTA_TMPDIR` when it is set and not empty, the system's temporary folder otherwise. Foundation's temporary
/// directory ignores `TMPDIR` on macOS, so a test run cannot move it with the environment alone: scripts/test.sh and the
/// commit hook set `REGISTA_TMPDIR` to a folder of their own run and remove that folder when the run ends. Nothing in
/// the app sets it, so the installed app keeps the system's temporary folder.
///
/// This file is the only place that may name the system's temporary directory (a test reads every Swift file of
/// Sources and Tests for a direct use elsewhere).
public enum TemporaryFolder {
    /// Regista's temporary folder for this process (made when `REGISTA_TMPDIR` names a folder that does not exist yet).
    public static let url: URL = resolve(ProcessInfo.processInfo.environment)

    /// The folder for an environment: `REGISTA_TMPDIR`'s folder when set and not empty, the system's otherwise.
    public static func resolve(_ environment: [String: String]) -> URL {
        guard let path = environment["REGISTA_TMPDIR"], !path.isEmpty else { return FileManager.default.temporaryDirectory }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
