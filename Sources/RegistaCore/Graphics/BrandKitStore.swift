import Foundation

/// The user's brand kits on disk: one folder per kit, `<directory>/<id>/kit.json` + `assets/` (logos, fonts),
/// asset paths in `kit.json` relative to the folder. A `.registakit` file is that folder zipped, to share a kit
/// with partners. Older single-file kits (`<directory>/<id>.json`) still load.
public struct BrandKitStore {
    public var directory: URL

    public init(directory: URL = BrandKit.userDirectory) { self.directory = directory }

    public static let fileExtension = "registakit"
    static let fontExtensions: Set<String> = ["ttf", "otf", "woff2", "woff", "ttc"]
    static let logoExtensions: Set<String> = ["svg", "png"]

    /// Kits saved by the user (folders first; a legacy JSON with the same id loses).
    public func userKits() -> [BrandKit] {
        let fm = FileManager.default
        let entries = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        var kits: [String: BrandKit] = [:]
        for f in entries where f.pathExtension == "json" {
            if let kit = try? BrandKit.load(f.path) { kits[kit.id] = kit }
        }
        for f in entries where fm.fileExists(atPath: f.appendingPathComponent("kit.json").path) {
            if let kit = try? BrandKit.load(f.path) { kits[kit.id] = kit }
        }
        return kits.values.sorted { $0.id < $1.id }
    }

    public func folder(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    /// A kit id from a name: lowercase ASCII words joined by "-".
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let words = folded.split { !($0.isLetter && $0.isASCII) && !$0.isNumber }
        let s = words.joined(separator: "-")
        return s.isEmpty ? "kit" : s
    }

    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.allSatisfy { ($0.isLetter && $0.isASCII && $0.isLowercase) || $0.isNumber || $0 == "-" }
    }

    /// Writes the kit into its folder: assets outside the folder (built-in or absolute paths) are copied into
    /// `assets/` first, so the folder stands alone. Returns the kit as stored (directory set, paths relative).
    @discardableResult
    public func save(_ kit: BrandKit) throws -> BrandKit {
        guard Self.validID(kit.id) else { throw CommandError.invalid("brand kit id \"\(kit.id)\": use lowercase letters, digits and -") }
        let dir = folder(kit.id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("assets/fonts"), withIntermediateDirectories: true)
        var k = kit
        func localize(_ p: String, sub: String) throws -> String {
            let src = kit.assetPath(p)
            if src.hasPrefix(dir.path + "/") { return String(src.dropFirst(dir.path.count + 1)) }
            guard fm.fileExists(atPath: src) else { return p }   // a missing file stays as written (reported as missing)
            let rel = "\(sub)/\(URL(fileURLWithPath: src).lastPathComponent)"
            let dest = dir.appendingPathComponent(rel)
            if dest.standardizedFileURL.path != URL(fileURLWithPath: src).standardizedFileURL.path {
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: URL(fileURLWithPath: src), to: dest)
            }
            return rel
        }
        k.fonts = try kit.fonts.mapValues { BrandKit.isFontFile($0) ? try localize($0, sub: "assets/fonts") : $0 }
        k.logo = try kit.logo.map { try localize($0, sub: "assets") }
        k.logos = try kit.logos?.mapValues { try localize($0, sub: "assets") }
        k.directory = dir
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(k).write(to: dir.appendingPathComponent("kit.json"), options: .atomic)
        return k
    }

    /// Removes a user kit folder (a built-in with the same id shows again).
    public func delete(_ id: String) throws {
        let dir = folder(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw CommandError.notFound("brand kit \(id): no user kit folder") }
        try FileManager.default.removeItem(at: dir)
    }

    /// Copies a logo file into the kit's assets as `logo-<variant>.<ext>` and points the variant at it.
    public func setLogo(_ kit: BrandKit, file: URL, variant: String) throws -> BrandKit {
        let ext = file.pathExtension.lowercased()
        guard Self.logoExtensions.contains(ext) else { throw CommandError.invalid("logo must be .svg or .png (got .\(ext))") }
        guard BrandKit.logoVariants.contains(variant) else { throw CommandError.invalid("logo variant is one of \(BrandKit.logoVariants.joined(separator: ", "))") }
        guard FileManager.default.fileExists(atPath: file.path) else { throw CommandError.notFound("no file at \(file.path)") }
        var k = try save(kit)
        let rel = "assets/logo-\(variant).\(ext)"
        let dest = folder(k.id).appendingPathComponent(rel)
        // Another extension for the same variant would be stale.
        for e in Self.logoExtensions { try? FileManager.default.removeItem(at: folder(k.id).appendingPathComponent("assets/logo-\(variant).\(e)")) }
        try FileManager.default.copyItem(at: file, to: dest)
        var logos = k.logos ?? [:]
        logos[variant] = rel
        k.logos = logos
        return try save(k)
    }

    /// Copies a font file into `assets/fonts/` and assigns it to a role.
    public func setFont(_ kit: BrandKit, file: URL, role: String) throws -> BrandKit {
        let ext = file.pathExtension.lowercased()
        guard Self.fontExtensions.contains(ext) else { throw CommandError.invalid("font must be .ttf, .otf or .woff2 (got .\(ext))") }
        guard FileManager.default.fileExists(atPath: file.path) else { throw CommandError.notFound("no file at \(file.path)") }
        var k = try save(kit)
        let rel = "assets/fonts/\(file.lastPathComponent)"
        let dest = folder(k.id).appendingPathComponent(rel)
        if dest.standardizedFileURL.path != file.standardizedFileURL.path {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: file, to: dest)
        }
        k.fonts[role] = rel
        return try save(k)
    }

    // MARK: Sharing

    /// Zips the kit (self-contained: outside assets copied in) into one `.registakit` file.
    public func export(_ kit: BrandKit, to file: URL) throws -> URL {
        let out = file.pathExtension == Self.fileExtension ? file : file.appendingPathExtension(Self.fileExtension)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("regista-kit-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: staging) }
        let stored = try BrandKitStore(directory: staging).save(kit)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        try Subprocess.check(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--keepParent", folder(stored.id, in: staging).path, out.path])
        return out
    }

    /// Unpacks a `.registakit` (or copies a kit folder / reads a kit JSON) into the store. An existing user kit
    /// with the same id is replaced only with `replace`; otherwise the id gets a numeric suffix.
    public func importKit(from file: URL, replace: Bool = false) throws -> BrandKit {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: file.path, isDirectory: &isDir) else { throw CommandError.notFound("no kit at \(file.path)") }
        let staging = fm.temporaryDirectory.appendingPathComponent("regista-kit-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: staging) }
        var kit: BrandKit
        if isDir.boolValue || file.pathExtension == "json" {
            kit = try BrandKit.load(file.path)
        } else {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            try Subprocess.check(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", file.path, staging.path])
            let found = try Self.findKitJSON(in: staging)
            kit = try BrandKit.load(found.path)
            // Nothing may point outside the unpacked folder.
            for p in Array(kit.fonts.values.filter(BrandKit.isFontFile)) + (kit.logos.map { Array($0.values) } ?? []) + (kit.logo.map { [$0] } ?? [])
            where p.contains("..") {
                throw CommandError.invalid("kit file \(file.lastPathComponent): asset path \(p) leaves the kit folder")
            }
        }
        if !Self.validID(kit.id) { kit.id = Self.slug(kit.name) }
        if !replace {
            var n = 2
            let base = kit.id
            // A kit with a built-in's id (a partner's Arkad kit) replaces the built-in, like any user kit.
            while fm.fileExists(atPath: folder(kit.id).path) { kit.id = "\(base)-\(n)"; n += 1 }
        } else {
            try? fm.removeItem(at: folder(kit.id))
        }
        return try save(kit)
    }

    func folder(_ id: String, in root: URL) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    static func findKitJSON(in root: URL) throws -> URL {
        let direct = root.appendingPathComponent("kit.json")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        let subs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for s in subs where !s.lastPathComponent.hasPrefix("__MACOSX") {
            let k = s.appendingPathComponent("kit.json")
            if FileManager.default.fileExists(atPath: k.path) { return k }
        }
        throw CommandError.invalid("not a Regista kit: no kit.json inside")
    }
}

/// A user kit folder as bytes (kit.json and its assets), nil when the folder does not exist: what a kit command
/// changed, so history.undo can put the folder back (brand kits live outside the project, #3).
public struct KitSnapshot: Sendable, Equatable {
    /// Paths relative to the kit folder → contents.
    public var files: [String: Data]

    /// The folder as it is now (nil: no such folder).
    public static func read(_ folder: URL) throws -> KitSnapshot? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        var files: [String: Data] = [:]
        let root = folder.standardizedFileURL.path
        for case let url as URL in fm.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) ?? FileManager.DirectoryEnumerator() {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            files[String(path.dropFirst(root.count + 1))] = try Data(contentsOf: url)
        }
        return KitSnapshot(files: files)
    }

    /// Makes `folder` hold exactly `snapshot` (nil removes the folder).
    public static func restore(_ snapshot: KitSnapshot?, to folder: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
        guard let snapshot else { return }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        for (rel, data) in snapshot.files {
            let url = folder.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }
}

/// One kit command's change to a user kit folder: undone and redone by history.undo / history.redo.
public struct KitChange: Sendable {
    public var kit: String
    public var folder: URL
    public var before: KitSnapshot?
    public var after: KitSnapshot?

    /// Runs `body` (which writes the kit `id` in `store`) and returns its result with the change it made.
    static func record<T>(_ id: String, in store: BrandKitStore, _ body: () throws -> T) throws -> (T, KitChange) {
        let folder = store.folder(id)
        let before = try KitSnapshot.read(folder)
        let result = try body()
        return (result, KitChange(kit: id, folder: folder, before: before, after: try KitSnapshot.read(folder)))
    }
}

