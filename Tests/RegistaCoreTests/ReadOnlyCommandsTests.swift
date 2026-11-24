import Foundation
import Testing
@testable import RegistaCore

// #158: a command the MCP server marks read-only writes nothing that stays. Every read-only command runs on an engine
// whose places are all watched — the support folder (rule sheets, skills, voice profiles, generation state), a brand kit
// of this test's own, the project's folder and the media it reads — with the parameters it needs built where they can
// be; afterwards every watched file is as it was and the project is the same. A command that fails must not write
// either, so its failure is no excuse. Its own scratch does not count: the temporary folder, the cache and the project's
// previews (the pictures a look renders).

/// Every file under `root` (but its `previews` folders) with its size and modification date.
private func snapshot(_ root: URL) -> [String: String] {
    var out: [String: String] = [:]
    let fm = FileManager.default
    guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else { return out }
    for case let url as URL in walk {
        if url.lastPathComponent == "previews" { walk.skipDescendants(); continue }
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
        out[url.path] = v?.isDirectory == true ? "dir" : "\(v?.fileSize ?? -1) \(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
    }
    return out
}

@Test func noReadOnlyCommandWrites() throws {
    let support = tempDir(), outputs = tempDir()
    var fakes = FakeServices()
    fakes.tier = .pro
    var s = fakes.make()
    s.rules = RuleBook(directory: support.appendingPathComponent("rules", isDirectory: true))
    s.profiles = ProfileStore(directory: support.appendingPathComponent("profiles", isDirectory: true))
    s.generationState = support.appendingPathComponent("generation", isDirectory: true)
    s.library = MediaLibrary(roots: [outputs.path], includeDefault: false, outputDirectory: outputs.path)
    let e = Engine(prober: FakeProber(), services: s)

    // A project with something in it: a take on the timeline, its transcript, captions, a title, a script; a sheet, a
    // skill and a brand kit of this test's own.
    let projects = tempDir(), media = tempDir()
    let take = fakeMedia("take.mov", in: media)
    try e.execute("project.new", params: ["name": "readonly", "directory": .string(projects.path)])
    try e.execute("media.import", params: ["path": .string(take)])
    let v = try e.execute("track.add", params: ["kind": "video"]).value(at: "track.id")?.stringValue ?? ""
    let a = try e.execute("track.add", params: ["kind": "audio"]).value(at: "track.id")?.stringValue ?? ""
    let clip = try e.execute("timeline.place", params: ["assetId": "a1", "trackId": .string(v), "sourceOut": 10]).value(at: "clip.id")?.stringValue ?? ""
    try e.execute("timeline.place", params: ["assetId": "a1", "trackId": .string(a), "sourceOut": 10, "linkTo": .string(clip)])
    _ = try? e.execute("transcript.run", params: ["assetId": "a1", "language": "it"])
    _ = try? e.execute("captions.generate", params: ["style": "talking-head-v1"])
    _ = try? e.execute("title.add", params: ["text": "TITOLO", "start": 1, "duration": 2])
    _ = try? e.execute("script.set", params: ["text": "1. uno due\n2. tre quattro"])
    try e.execute("rules.set", params: ["kind": "talking-head-reel", "choices": ["pace": "fast"]])
    _ = try? e.execute("skill.create", params: ["name": "Read only"])
    try e.execute("project.save")
    var kit = BrandKit.builtIn[0]
    kit.id = "readonly-\(UUID().uuidString.prefix(8).lowercased())"
    kit.name = "Read only"
    _ = try BrandKitStore().save(kit)
    defer { try? BrandKitStore().delete(kit.id) }

    let skill = try? e.execute("skill.list").value(at: "skills.0.id")?.stringValue
    let captions = e.project?.tracks.first { $0.kind == .caption }?.id
    let title = e.project?.tracks.flatMap(\.clips).first { $0.title != nil }?.id
    /// A value for a required parameter, where one can be built (nil: the command is run without it, and fails).
    func value(_ p: ParamSpec) -> JSONValue? {
        switch p.name {
        case "assetId": "a1"
        case "trackId": .string(captions ?? v)
        case "clipId": .string(title ?? clip)
        case "clipIds": [.string(clip)]
        case "path", "candidate", "reference", "referenceSegments": .string(take)
        case "kind": "talking-head-reel"
        case "kit": .string(kit.id)
        case "skill", "id": skill.map { .string($0) }
        case "language": "it"
        case "text", "prompt", "script", "line1": "uno due"
        case "name", "title": "Read only"
        case "start", "time", "at", "from", "to": 1
        case "times": [1, 2]
        case "preset": "9:16"
        case "style": "talking-head-v1"
        default: nil
        }
    }

    let readOnly = e.descriptors.filter(\.readOnly)
    #expect(readOnly.count > 30, "only \(readOnly.count) read-only commands")
    let watched = [support, projects, media, BrandKitStore().folder(kit.id), outputs]
    var ran = 0
    for d in readOnly {
        var params: [String: JSONValue] = [:]
        for p in d.params where p.required { if let x = value(p) { params[p.name] = x } }
        let before = watched.map(snapshot), project = e.project
        _ = try? e.execute(d.id, params: .object(params))
        ran += 1
        for (root, old) in zip(watched, before) {
            let now = snapshot(root)
            let changed = Set(old.keys).union(now.keys).filter { old[$0] != now[$0] }.map { $0.replacingOccurrences(of: root.path, with: "…") }
            #expect(changed.isEmpty, "\(d.id) is marked read-only and wrote \(changed.sorted())")
        }
        #expect(e.project == project, "\(d.id) is marked read-only and changed the project")
    }
    #expect(ran == readOnly.count)
}
