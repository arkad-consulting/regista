import Foundation
import RegistaCore
import Testing

// #138: every temporary file of Regista and of its tests goes under TemporaryFolder.url, which a test run moves into a
// folder of its own with REGISTA_TMPDIR (Foundation's temporary directory ignores TMPDIR on macOS). Test runs had left
// about 224,000 items, 168 GB, in the system's temporary folder in eight days.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
private let home = "Sources/RegistaCore/TemporaryFolder.swift"

/// The Swift files of Sources and Tests, by path from the repository.
private func swiftFiles() -> [(path: String, url: URL)] {
    ["Sources", "Tests"].flatMap { folder in
        FileManager.default.enumerator(at: repo.appendingPathComponent(folder), includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
            .map { (String($0.path.dropFirst(repo.path.count + 1)), $0) }
    }.sorted { $0.path < $1.path }
}

/// A direct use of the system's temporary directory in code (comments and strings ignored).
private let directUse = #"(?<![A-Za-z0-9_])(temporaryDirectory|NSTemporaryDirectory|_CS_DARWIN_USER_TEMP_DIR)(?![A-Za-z0-9_])"#

private func directUses(_ source: String) -> [String] {
    let text = swiftCode(source)
    let re = try! NSRegularExpression(pattern: directUse)
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
}

@Test func onlyTemporaryFolderNamesTheSystemsTemporaryDirectory() throws {
    let files = swiftFiles()
    #expect(files.count > 300, "the scan found only \(files.count) files")
    var found: [String] = []
    for f in files where f.path != home {
        for use in directUses(try String(contentsOf: f.url, encoding: .utf8)) { found.append("\(f.path): \(use) (use TemporaryFolder.url)") }
    }
    #expect(found.isEmpty, "\(found.joined(separator: "\n"))")
    #expect(!directUses(try String(contentsOf: repo.appendingPathComponent(home), encoding: .utf8)).isEmpty, "the scan no longer sees the one use")
}

/// The installed app keeps the system's folder: nothing in Sources names REGISTA_TMPDIR but the function that reads it.
@Test func nothingInSourcesSetsTheTemporaryFolderVariable() throws {
    let named = try swiftFiles().filter { $0.path.hasPrefix("Sources/") }
        .filter { try String(contentsOf: $0.url, encoding: .utf8).contains("REGISTA_TMPDIR") }.map(\.path)
    #expect(named == [home])
}

/// The scan sees a use, and does not take a comment or a string for one.
@Test func theTemporaryFolderScanReadsCodeNotCommentsOrStrings() {
    let source = """
    // FileManager.default.temporaryDirectory in a comment
    let a = "NSTemporaryDirectory() in a string"
    let b = FileManager.default.temporaryDirectory
    let c = fm.temporaryDirectory.path, d = NSTemporaryDirectory()
    let e = myTemporaryDirectoryName
    """
    #expect(directUses(source) == ["temporaryDirectory", "temporaryDirectory", "NSTemporaryDirectory"])
}

/// REGISTA_TMPDIR when set and not empty (the folder is made), the system's temporary folder otherwise.
@Test func theTemporaryFolderFollowsTheVariable() throws {
    let system = TemporaryFolder.resolve([:])
    #expect(TemporaryFolder.resolve(["REGISTA_TMPDIR": ""]) == system)
    #expect(!system.path.isEmpty)
    let parent = TemporaryFolder.url.appendingPathComponent("regista-tmpdir-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: parent) }
    let run = parent.appendingPathComponent("run", isDirectory: true)
    let resolved = TemporaryFolder.resolve(["REGISTA_TMPDIR": run.path])
    #expect(resolved.standardizedFileURL.path == run.standardizedFileURL.path)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: run.path, isDirectory: &isDirectory) && isDirectory.boolValue)
    // Under scripts/test.sh this process itself runs in the run's folder.
    if let set = ProcessInfo.processInfo.environment["REGISTA_TMPDIR"], !set.isEmpty {
        #expect(TemporaryFolder.url.standardizedFileURL.path == URL(fileURLWithPath: set).standardizedFileURL.path)
    }
}
