import AppKit
import SwiftUI

/// Where this copy of Regista.app runs from (#110). A downloaded app opened from Downloads or from its disk image runs
/// from a temporary read-only place macOS picks (App Translocation) or from the image: the path of its regista-mcp that
/// Claude would remember stops working once the app is moved or the Mac restarts. Such a copy offers, once at launch, to
/// move itself into the Applications folder and reopen from there; Settings › Claude does not register it meanwhile.
struct AppLocation: Equatable {
    /// The app bundle (Regista.app).
    let bundle: URL
    /// The Applications folder a move goes to: /Applications when it can be written, else ~/Applications (the rig gives a
    /// scratch folder).
    let applications: URL

    /// The copy a move makes.
    var destination: URL { applications.appendingPathComponent(bundle.lastPathComponent, isDirectory: true) }
    /// A copy is already there: the alert says it is replaced.
    var replaces: Bool { FileManager.default.fileExists(atPath: destination.path) }

    /// The Applications folders a lasting copy lives in.
    static func applicationsFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// Whether `bundle` sits inside an Applications folder (symlinks resolved: /Applications may be reached another way).
    static func isInApplications(_ bundle: URL, folders: [URL] = applicationsFolders()) -> Bool {
        let path = bundle.resolvingSymlinksInPath().standardizedFileURL.path
        return folders.contains { f in path.hasPrefix(f.resolvingSymlinksInPath().standardizedFileURL.path + "/") }
    }

    /// Whether a copy at `bundle` should offer to move itself: an app bundle, outside the Applications folders, and not a
    /// build of the source folder (build.noindex, where scripts/build-app.sh assembles it) nor a test run (no app bundle).
    static func shouldOffer(_ bundle: URL, folders: [URL] = applicationsFolders()) -> Bool {
        guard bundle.pathExtension == "app" else { return false }
        if bundle.pathComponents.contains("build.noindex") { return false }
        return !isInApplications(bundle, folders: folders)
    }

    /// The prompt for this process: nil when the app is where it should be.
    static func current(bundle: URL = Bundle.main.bundleURL) -> AppLocation? {
        guard shouldOffer(bundle) else { return nil }
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let target = FileManager.default.isWritableFile(atPath: system.path) ? system : applicationsFolders()[1]
        return AppLocation(bundle: bundle, applications: target)
    }

    /// Copies the app into the Applications folder (beside it first, then in place of a copy already there, so a failure
    /// leaves the old one), without the download's quarantine (the copy was asked for by the person, as a move in the
    /// Finder would); returns the new copy.
    func move() throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        let part = applications.appendingPathComponent(".\(bundle.lastPathComponent).part", isDirectory: true)
        try? fm.removeItem(at: part)
        try fm.copyItem(at: bundle, to: part)
        Self.removeQuarantine(part)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: part, to: destination)
        return destination
    }

    static func removeQuarantine(_ root: URL) {
        let key = "com.apple.quarantine"
        removexattr(root.path, key, XATTR_NOFOLLOW)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let u = walker?.nextObject() as? URL { removexattr(u.path, key, XATTR_NOFOLLOW) }
    }

    /// Where it runs from, in words for the alert ("Download", the disk image's name, or the folder).
    var placeName: String {
        let path = bundle.path
        if path.contains("/AppTranslocation/") { return loc("una posizione temporanea di macOS") }
        if path.hasPrefix("/Volumes/") { return String(format: loc("l'immagine disco «%@»"), bundle.pathComponents.dropFirst(2).first ?? "") }
        return bundle.deletingLastPathComponent().path
    }
}

/// The launch prompt's state: the location to offer (nil once answered) and what "Sposta e riapri" does after the copy.
@MainActor
final class MovePrompt: ObservableObject {
    @Published var location: AppLocation?
    @Published var error: String?
    /// Opens the new copy and quits this one (the rig records it instead).
    let reopen: (URL) -> Void

    init(location: AppLocation? = AppLocation.current(), reopen: @escaping (URL) -> Void = MovePrompt.reopenAndQuit) {
        self.location = location
        self.reopen = reopen
    }

    var isPresented: Binding<Bool> {
        Binding(get: { self.location != nil }, set: { if !$0 { self.location = nil } })
    }

    func move() {
        guard let l = location else { return }
        location = nil
        do { reopen(try l.move()) } catch { self.error = String(format: loc("Non ho potuto spostare Regista: %@"), error.localizedDescription) }
    }

    /// Quits, then opens `app` once this process has ended (the same way «Riapri Regista» reopens).
    static func reopenAndQuit(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]   // l10n-ignore
        guard (try? p.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    var title: String { loc("Sposta Regista in Applicazioni") }

    var message: String {
        guard let l = location else { return "" }
        var text = String(format: loc("Regista è aperto da %@: da lì Claude non lo ritrova dopo un riavvio. Lo copio nella cartella Applicazioni e lo riapro da lì."), l.placeName)
        if l.replaces { text += " " + loc("Nella cartella Applicazioni c'è già un Regista: lo sostituisco con questa copia.") }
        return text
    }
}

extension View {
    /// The launch alert of an app opened outside an Applications folder (#110).
    func movePrompt(_ prompt: MovePrompt) -> some View {
        modifier(MovePromptModifier(prompt: prompt))
    }
}

private struct MovePromptModifier: ViewModifier {
    @ObservedObject var prompt: MovePrompt

    func body(content: Content) -> some View {
        content
            .alert(prompt.title, isPresented: prompt.isPresented) {
                Button(loc("Sposta e riapri")) { prompt.move() }
                Button(loc("Non ora"), role: .cancel) { prompt.location = nil }
            } message: {
                Text(verbatim: prompt.message)
            }
            .alert(loc("Regista non è stato spostato"), isPresented: Binding(get: { prompt.error != nil }, set: { if !$0 { prompt.error = nil } })) {
                Button(loc("OK")) { prompt.error = nil }
            } message: {
                Text(verbatim: prompt.error ?? "")
            }
    }
}

/// The app bundle the views describe: this process's (a test gives a copy laid out in a scratch folder).
private struct AppBundleKey: EnvironmentKey { static let defaultValue: Bundle = .main }

extension EnvironmentValues {
    var appBundle: Bundle {
        get { self[AppBundleKey.self] }
        set { self[AppBundleKey.self] = newValue }
    }
}
