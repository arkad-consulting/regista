import Foundation

/// The folders an agent without file tools may browse (media.list) and read text from (text.read):
/// the default `~/Movies/Regista`, folders given to the host (`--media-root`, `REGISTA_MEDIA_ROOT`) and the
/// output directory. Paths outside them are refused; `..` is resolved before the check.
public struct MediaLibrary: Sendable {
    public static let defaultRoot = "~/Movies/Regista"

    /// Standardized absolute folders, in order (the first existing one is where relative paths resolve).
    public private(set) var roots: [URL]
    /// Where projects and exports should go (the host's working directory when it was given explicitly).
    public var outputDirectory: URL?

    public init(roots: [String] = [], includeDefault: Bool = true, outputDirectory: String? = nil) {
        var all = roots
        if includeDefault { all.append(Self.defaultRoot) }
        let out = outputDirectory.map { URL(fileURLWithPath: EngineConfig.expand($0)).standardizedFileURL }
        if let out { all.append(out.path) }
        var seen = Set<String>()
        self.roots = all.map { URL(fileURLWithPath: EngineConfig.expand($0)).standardizedFileURL }.filter { seen.insert($0.path).inserted }
        self.outputDirectory = out
    }

    /// Where an agent saves: the output directory when the host gave one, else the first media root.
    public var saveDirectory: URL? { outputDirectory ?? roots.first }
    /// Projects and exports: in the output directory when the host gave one; otherwise where the app keeps them,
    /// `Progetti` and `Export` inside the first media root (project.save and export.render create them).
    public var projectsDirectory: URL? { outputDirectory ?? roots.first?.appendingPathComponent("Progetti", isDirectory: true) }
    public var exportsDirectory: URL? { outputDirectory ?? roots.first?.appendingPathComponent("Export", isDirectory: true) }

    /// Roots from `--media-root <dir>` arguments (repeatable), `REGISTA_MEDIA_ROOT` (colon-separated) and
    /// `--output-dir <dir>` / `REGISTA_OUTPUT_DIR`, plus the default root.
    public static func from(arguments: [String], environment: [String: String]) -> MediaLibrary {
        var roots: [String] = [], output: String?
        var it = arguments.makeIterator()
        while let a = it.next() {
            if a == "--media-root", let v = it.next() { roots.append(v) }
            else if a == "--output-dir", let v = it.next() { output = v }
        }
        roots += (environment["REGISTA_MEDIA_ROOT"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        if output == nil, let o = environment["REGISTA_OUTPUT_DIR"], !o.isEmpty { output = o }
        return MediaLibrary(roots: roots, outputDirectory: output)
    }

    /// Whether `url` lies inside `root`: lexically (after resolving `.` and `..`, so a link the operator put
    /// in a root is followed), or once both have their symlinks resolved (/tmp vs /private/tmp).
    static func contains(_ root: URL, _ url: URL) -> Bool {
        let r = root.standardizedFileURL.pathComponents, u = url.standardizedFileURL.pathComponents
        if u.starts(with: r) { return true }
        return url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
            .starts(with: root.standardizedFileURL.resolvingSymlinksInPath().pathComponents)
    }

    /// An absolute path, or one relative to a root (the first root where it exists), checked to be inside a root.
    public func resolve(_ path: String, command: String) throws -> URL {
        let expanded = EngineConfig.expand(path.trimmingCharacters(in: .whitespaces))
        guard !expanded.isEmpty else { throw CommandError.invalid("\(command): empty path") }
        let url: URL
        if expanded.hasPrefix("/") { url = URL(fileURLWithPath: expanded).standardizedFileURL }
        else {
            let candidates = roots.map { $0.appendingPathComponent(expanded).standardizedFileURL }
            url = candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first ?? URL(fileURLWithPath: expanded)
        }
        guard roots.contains(where: { Self.contains($0, url) }) else {
            throw CommandError.invalid("\(command): \(path) is outside the media folders (\(roots.map(\.path).joined(separator: ", "))) — call media.list to see them")
        }
        return url
    }

    static let kinds: [String: Set<String>] = [
        "video": ["mov", "mp4", "m4v", "mkv", "avi", "webm", "mts"],
        "audio": ["wav", "m4a", "mp3", "aac", "aif", "aiff", "flac", "caf"],
        "image": ["png", "jpg", "jpeg", "heic", "webp"],
        "text": ["md", "txt", "srt", "json"],
        "project": ["regista"],
        "shotcut": ["mlt"],
    ]

    static func kind(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return kinds.first { $0.value.contains(ext) }?.key
    }
}

enum MediaList: Command {
    static let id = "media.list"
    static let summary = "Use this first to find footage, scripts and earlier projects when you have no file tools: lists the media folders Regista may read (the roots) and the video, audio, image, text (.md/.txt/.srt/.json), project (.regista) and Shotcut (.mlt) files in them, with size and date. A screen recording made in Regista is a folder with a session.json (pass the folder to recording.import). Returns roots (and whether each exists), projectsDirectory (pass it to project.new as directory), exportsDirectory (where export.render / export.srt files go), outputDirectory (their parent, for anything else) and files [{path, kind, bytes, modified}]; pass a path to media.import, script.set, text.read or project.open."
    static let kind = CommandKind.query
    static let maxFiles = 500
    static let params: [ParamSpec] = [
        .optional("path", .string, "Only this folder (absolute, or relative to a root); default: every root."),
        .optional("kinds", .array(.oneOf(Array(MediaLibrary.kinds.keys).sorted())), "Only these kinds (default: all)."),
        .optional("depth", .integer, "How many folder levels to descend (default 3)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let library = ctx.services.library
        let folders = try p.string("path").map { [try library.resolve($0, command: id)] } ?? library.roots
        let wanted = p.strings("kinds").map(Set.init)
        let depth = max(0, p.int("depth") ?? 3)
        let fm = FileManager.default
        var files: [JSONValue] = [], truncated = false

        func visit(_ dir: URL, level: Int) {
            guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                                            options: [.skipsHiddenFiles]) else { return }
            // Paths are reported under the root as given (contentsOfDirectory may resolve /var → /private/var).
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let url = dir.appendingPathComponent(entry.lastPathComponent)
                guard files.count < maxFiles else { truncated = true; return }
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = values?.isDirectory ?? false
                let kind = MediaLibrary.kind(of: url)
                if isDir && kind != "project" {
                    if level < depth { visit(url, level: level + 1) }
                    continue
                }
                guard let kind, wanted == nil || wanted!.contains(kind) else { continue }
                var row: [String: JSONValue] = ["path": .string(url.path), "kind": .string(kind)]
                if !isDir, let size = values?.fileSize { row["bytes"] = .number(Double(size)) }
                if let date = values?.contentModificationDate { row["modified"] = .string(ISO8601DateFormatter().string(from: date)) }
                files.append(.object(row))
            }
        }
        for f in folders { visit(f, level: 1) }
        return ["roots": .array(library.roots.map { ["path": .string($0.path), "exists": .bool(fm.fileExists(atPath: $0.path))] }),
                "outputDirectory": library.saveDirectory.map { .string($0.path) } ?? .null,
                "projectsDirectory": library.projectsDirectory.map { .string($0.path) } ?? .null,
                "exportsDirectory": library.exportsDirectory.map { .string($0.path) } ?? .null,
                "files": .array(files), "count": .number(Double(files.count)), "truncated": .bool(truncated)]
    }
}

enum TextRead: Command {
    static let id = "text.read"
    static let summary = "Read a text file (.md, .txt, .srt, .json) from the media folders: the script the speaker read, notes, a keywords list, an exported .srt to proof-read. Use it when you have no file tools; media.list shows what is there. Returns {path, bytes, text}."
    static let kind = CommandKind.query
    static let maxBytes = 256 * 1024
    static let params: [ParamSpec] = [
        .required("path", .string, "File inside a media folder (absolute, or relative to a root)."),
    ]

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let url = try ctx.services.library.resolve(p.requiredString("path"), command: id)
        guard MediaLibrary.kind(of: url) == "text" else {
            throw CommandError.invalid("\(id): only .md, .txt, .srt and .json files can be read, not \(url.lastPathComponent)")
        }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CommandError.notFound("\(id): no file at \(url.path)") }
        guard data.count <= maxBytes else { throw CommandError.invalid("\(id): \(url.lastPathComponent) is \(data.count) bytes, the limit is \(maxBytes)") }
        return ["path": .string(url.path), "bytes": .number(Double(data.count)), "text": .string(String(decoding: data, as: UTF8.self))]
    }
}
