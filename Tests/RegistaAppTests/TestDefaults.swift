import Foundation

// A test's own defaults suite (#137). A suite named `regista-<kind>-<UUID>` kept its property list in the Preferences
// folder of whoever ran the tests, one file per test, for ever: removing the domain empties the file but leaves it, and
// a file deleted at the end of a test comes back, because the preferences daemon writes a changed domain to disk a while
// after the change (up to about half a minute, also after the process has exited; synchronizing does not force the
// write). So the suite's file lives in a scratch folder of the test process instead (a suite named by an absolute path
// is kept at that path): `<temporary folder>/regista-tests-defaults-<pid>/regista-<kind>-<UUID>.plist`. At its end a
// suite's domain is removed and its file deleted; at the process's exit every suite not ended yet is ended and the
// folder goes, and the daemon never creates a missing folder, so a late write lands nowhere.

enum TestDefaults {
    /// The test process's folder of suites (named after the pid, like the other scratch folders of the test targets).
    static let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("regista-tests-defaults-\(ProcessInfo.processInfo.processIdentifier)",
                                                                                 isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { TestDefaults.endAll() }
        return url
    }()

    private static let lock = NSLock()
    /// The suites made and not ended yet, by object: the defaults stay alive until their end.
    nonisolated(unsafe) private static var open: [ObjectIdentifier: (defaults: UserDefaults, domain: String)] = [:]

    /// A new, empty suite `regista-<kind>-<UUID>`.
    static func make(_ kind: String) -> UserDefaults {
        let domain = folder.appendingPathComponent("regista-\(kind)-\(UUID().uuidString)").path
        let defaults = UserDefaults(suiteName: domain)!
        lock.withLock { open[ObjectIdentifier(defaults)] = (defaults, domain) }
        return defaults
    }

    /// The domain of a suite `make` gave and not ended yet (another defaults object on the same suite reads and writes it:
    /// what a relaunched app sees).
    static func domain(of defaults: UserDefaults) -> String? {
        lock.withLock { open[ObjectIdentifier(defaults)]?.domain }
    }

    /// The suite's property list file.
    static func file(of domain: String) -> URL { URL(fileURLWithPath: domain + ".plist") }

    /// Ends a suite `make` gave: its domain removed, the change synchronized, its file deleted. A second end does nothing.
    static func end(_ defaults: UserDefaults) {
        guard let entry = lock.withLock({ open.removeValue(forKey: ObjectIdentifier(defaults)) }) else { return }
        remove(entry.domain, entry.defaults)
    }

    private static func remove(_ domain: String, _ defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: domain)
        defaults.synchronize()
        CFPreferencesAppSynchronize(domain as CFString)
        try? FileManager.default.removeItem(at: file(of: domain))
    }

    /// Every suite still open, then the folder (the process exits).
    private static func endAll() {
        let left = lock.withLock { () -> [(defaults: UserDefaults, domain: String)] in
            defer { open.removeAll() }
            return Array(open.values)
        }
        for entry in left { remove(entry.domain, entry.defaults) }
        try? FileManager.default.removeItem(at: folder)
    }
}
