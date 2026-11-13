import Foundation
import Testing
@testable import RegistaCore

/// A media root with a take, a script, a nested folder, a project folder and a secret file next to it.
private func libraryEngine() throws -> (Engine, root: URL, outside: URL) {
    let base = tempDir()
    let root = base.appendingPathComponent("media"), outside = base.appendingPathComponent("secret.txt")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("day2/deep/deeper/deepest"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("old.regista/media"), withIntermediateDirectories: true)
    for (name, text) in [("take.MOV", ""), ("script.md", "1. Ciao.\n"), ("day2/b.wav", ""), ("day2/notes.bin", ""),
                         ("day2/deep/deeper/deepest/far.mp4", ""), ("old.regista/media/x.wav", ""), (".hidden.md", "")] {
        FileManager.default.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(text.utf8))
    }
    try "password".write(to: outside, atomically: true, encoding: .utf8)
    var services = FakeServices().make()
    services.library = MediaLibrary(roots: [root.path], includeDefault: false)
    return (Engine(prober: FakeProber(), services: services), root, outside)
}

@Test func libraryResolvesInsideRootsAndRejectsTraversal() throws {
    let (e, root, outside) = try libraryEngine()
    let lib = e.context.services.library
    #expect(try lib.resolve("script.md", command: "t").path == root.appendingPathComponent("script.md").path)
    #expect(try lib.resolve(root.appendingPathComponent("day2/../script.md").path, command: "t").path == root.appendingPathComponent("script.md").path)
    for bad in ["../secret.txt", root.appendingPathComponent("../secret.txt").path, outside.path, "/etc/passwd",
                "day2/../../secret.txt", root.path + "-evil/x.md", "~/.ssh/id_rsa", ""] {
        #expect(throws: CommandError.self, "\(bad) should be refused") { try lib.resolve(bad, command: "t") }
    }
    // The same folder through a symlinked parent (/tmp → /private/tmp) is inside.
    let resolved = root.resolvingSymlinksInPath()
    #expect(MediaLibrary.contains(root, resolved.appendingPathComponent("take.MOV")))
    #expect(!MediaLibrary.contains(root, root.deletingLastPathComponent().appendingPathComponent("mediaX")))
}

@Test func libraryRootsComeFromArgumentsEnvironmentAndTheDefault() {
    let lib = MediaLibrary.from(arguments: ["--media-root", "/a", "--output-dir", "/out", "--media-root", "/b/../c"],
                                environment: ["REGISTA_MEDIA_ROOT": "/d::/a"])
    #expect(lib.roots.map(\.path) == ["/a", "/c", "/d", EngineConfig.expand(MediaLibrary.defaultRoot), "/out"])
    #expect(lib.outputDirectory?.path == "/out" && lib.projectsDirectory?.path == "/out" && lib.exportsDirectory?.path == "/out")
    #expect(MediaLibrary.from(arguments: [], environment: ["REGISTA_OUTPUT_DIR": "/o"]).outputDirectory?.path == "/o")
    #expect(MediaLibrary().roots.map(\.path) == [EngineConfig.expand(MediaLibrary.defaultRoot)] && MediaLibrary().outputDirectory == nil)
}

@Test func mediaListShowsMediaInsideTheRootsOnly() throws {
    let (e, root, _) = try libraryEngine()
    let r = try e.execute("media.list")
    let files = try #require(r["files"]?.arrayValue)
    let rel = files.compactMap { $0["path"]?.stringValue?.replacingOccurrences(of: root.path + "/", with: "") }
    // Sorted per folder, hidden files and unknown extensions skipped, .regista listed as a project and not entered,
    // depth 3 by default (deepest/far.mp4 is at level 4).
    #expect(rel == ["day2/b.wav", "old.regista", "script.md", "take.MOV"])
    #expect(files.map { $0["kind"]?.stringValue } == ["audio", "project", "text", "video"])
    #expect(r.value(at: "roots.0.exists") == true)
    // No output directory given by the host: the agent still learns where to save, as the app files things.
    #expect(r["outputDirectory"]?.stringValue == root.path)
    #expect(r["projectsDirectory"]?.stringValue == root.appendingPathComponent("Progetti").path)
    #expect(r["exportsDirectory"]?.stringValue == root.appendingPathComponent("Export").path)
    let videos = try e.execute("media.list", params: ["kinds": ["video"], "depth": 5])
    #expect(videos["files"]?.arrayValue?.compactMap { $0["path"]?.stringValue?.components(separatedBy: "/").last } == ["far.mp4", "take.MOV"])
    let sub = try e.execute("media.list", params: ["path": "day2"])
    #expect(sub["count"] == 1)
    #expect(throws: CommandError.self) { try e.execute("media.list", params: ["path": "../"]) }
}

@Test func textReadReadsScriptsInsideTheRootsOnly() throws {
    let (e, root, outside) = try libraryEngine()
    let r = try e.execute("text.read", params: ["path": "script.md"])
    #expect(r["text"] == "1. Ciao.\n" && r["path"] == .string(root.appendingPathComponent("script.md").path))
    #expect(throws: CommandError.self) { try e.execute("text.read", params: ["path": .string(outside.path)]) }
    #expect(throws: CommandError.self) { try e.execute("text.read", params: ["path": "../secret.txt"]) }
    #expect(throws: CommandError.self) { try e.execute("text.read", params: ["path": "take.MOV"]) }   // not text
    #expect(throws: CommandError.self) { try e.execute("text.read", params: ["path": "missing.md"]) }
}

/// Records what it was asked to draw and writes small files.
final class FakeImages: ImageToolkit {
    var sheets: [(images: [URL], labels: [String])] = []
    func writePreview(of image: URL, maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int) {
        FileManager.default.createFile(atPath: output.path, contents: Data([0xFF, 0xD8]))
        return (maxWidth, maxWidth * 16 / 9)
    }
    func writeContactSheet(_ images: [URL], labels: [String], maxWidth: Int, maxHeight: Int, to output: URL) throws -> (width: Int, height: Int) {
        #expect(images.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        sheets.append((images, labels))
        FileManager.default.createFile(atPath: output.path, contents: Data([0xFF, 0xD8]))
        return (maxWidth, maxHeight)
    }
}

@Test func frameRenderAndContactSheetReturnImages() throws {
    let renderer = FakeRenderer(), images = FakeImages()
    var services = FakeServices().make()
    services.renderer = renderer
    services.images = images
    let dir = tempDir()
    let e = Engine(prober: FakeProber(), services: services)
    try e.execute("project.new", params: ["name": "s", "directory": .string(dir.path)])
    try e.execute("media.import", params: ["path": .string(fakeMedia())])
    try e.execute("track.add", params: ["kind": "video"])
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": "t1", "sourceIn": 0, "sourceOut": 12])

    let f = try e.execute("frame.render", params: ["times": [1, 2]])
    #expect(f["frames"]?.arrayValue?.count == 2)
    let previews = try #require(f["images"]?.arrayValue)
    #expect(previews.count == 2 && previews[0]["mimeType"] == "image/jpeg" && previews[0]["width"] == 540)
    #expect(try e.execute("frame.render", params: ["time": 1, "inline": false])["images"] == nil)

    let sheet = try e.execute("frame.contactSheet", params: ["count": 4])
    #expect(sheet["times"] == [1.5, 4.5, 7.5, 10.5])   // centres of 4 equal parts of 12 s
    #expect(images.sheets.last?.labels == ["1.50 s", "4.50 s", "7.50 s", "10.50 s"])
    let path = try #require(sheet["path"]?.stringValue)
    #expect(path == dir.appendingPathComponent("s.regista/previews/contact-1.jpg").path && FileManager.default.fileExists(atPath: path))
    #expect(sheet.value(at: "images.0.path") == .string(path))
    let range = try e.execute("frame.contactSheet", params: ["count": 2, "from": 4, "to": 8])
    #expect(range["times"] == [5, 7] && range["path"] == .string(dir.appendingPathComponent("s.regista/previews/contact-2.jpg").path))
    #expect(try e.execute("frame.contactSheet", params: ["times": [0, 99]])["times"] == [0, 11.966667])   // clamped to the last frame
    #expect(throws: CommandError.self) { try e.execute("frame.contactSheet", params: ["from": 5, "to": 5]) }
}
