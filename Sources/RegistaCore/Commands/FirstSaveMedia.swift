import Foundation

/// A project's first save takes along the files Regista generated for it (#139). Until a project has a folder, what
/// Regista makes for it (extracted audio, cleaned voice, face tracks, mattes, rendered graphics) goes to a temporary
/// media folder (`CommandContext.mediaDirectory`). The first `project.save` to a folder moves those files into
/// `<project>.regista/media` and points every path of the project (and of its undo history, and of the analysis files
/// that name them) at their new place, so the saved project never depends on the temporary folder. Only the items of
/// that temporary media folder move: the person's own files stay where they are.
enum FirstSaveMedia {
    struct Move: Equatable {
        let from: URL
        let to: URL
    }

    /// Moves every item of `scratch` into `media` (a name already taken there gets a free one: nothing in the folder is
    /// replaced). On a failure the items already moved go back and the error is thrown.
    static func move(from scratch: URL, into media: URL) throws -> [Move] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: scratch.path)) ?? []).sorted()
        guard !names.isEmpty else { return [] }
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        var moves: [Move] = []
        do {
            for name in names {
                let from = scratch.appendingPathComponent(name)
                let to = free(name, in: media)
                try fm.moveItem(at: from, to: to)
                moves.append(Move(from: from, to: to))
            }
        } catch {
            putBack(moves)
            throw error
        }
        return moves
    }

    /// The moves undone (a save that failed after moving).
    static func putBack(_ moves: [Move]) {
        for m in moves.reversed() { try? FileManager.default.moveItem(at: m.to, to: m.from) }
    }

    /// `name` in `folder`, or `name-2`, `name-3`… (before the extension) when taken.
    static func free(_ name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var url = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: url.path) || (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
            url = folder.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            n += 1
        }
        return url
    }

    /// The project with every path inside a moved item pointing at its new place.
    static func rewrite(_ project: Project, _ moves: [Move]) throws -> Project {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let text = String(decoding: try e.encode(project), as: UTF8.self)
        let rewritten = rewrite(text, moves)
        guard rewritten != text else { return project }
        return try JSONDecoder().decode(Project.self, from: Data(rewritten.utf8))
    }

    /// `text` (JSON) with every path inside a moved item pointing at its new place: a path is a whole JSON string or
    /// starts one, with its slashes escaped or not; the temporary folder may be written with or without `/private`.
    static func rewrite(_ text: String, _ moves: [Move]) -> String {
        var out = text
        for m in moves {
            let to = escaped(m.to.path)
            for from in spellings(of: m.from) {
                let old = escaped(from)
                for (o, n) in [(old, to), (old.replacingOccurrences(of: "/", with: "\\/"), to.replacingOccurrences(of: "/", with: "\\/"))] {
                    for end in ["\"", "/", "\\/"] {
                        out = out.replacingOccurrences(of: "\"" + o + end, with: "\"" + n + end)
                    }
                }
            }
        }
        return out
    }

    /// The JSON files among the moved items (sidecars: face tracks, hand tracks…) with the paths they name rewritten.
    static func rewriteFiles(_ moves: [Move]) {
        let fm = FileManager.default
        var files: [URL] = []
        for m in moves {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: m.to.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                files += (fm.enumerator(at: m.to, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            } else {
                files.append(m.to)
            }
        }
        for file in files where file.pathExtension.lowercased() == "json" {
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size < 64 << 20, let data = fm.contents(atPath: file.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let rewritten = rewrite(text, moves)
            if rewritten != text { try? Data(rewritten.utf8).write(to: file, options: .atomic) }
        }
    }

    /// The ways a path of the temporary folder can be written (as made, symlinks resolved, with or without `/private`).
    private static func spellings(of url: URL) -> [String] {
        let made = url.path, resolved = url.resolvingSymlinksInPath().path
        var out = [made, resolved]
        for p in [made, resolved] {
            if p.hasPrefix("/private/") { out.append(String(p.dropFirst("/private".count))) } else { out.append("/private" + p) }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// A string as it is written inside a JSON string (without the quotes, slashes not escaped).
    private static func escaped(_ s: String) -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        let quoted = String(decoding: (try? e.encode(s)) ?? Data("\"\(s)\"".utf8), as: UTF8.self)
        return String(quoted.dropFirst().dropLast())
    }
}
