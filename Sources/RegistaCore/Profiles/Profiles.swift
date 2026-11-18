import CryptoKit
import Foundation
import IOKit

// Voice profiles (issue #41). A profile is the person whose voice Regista may
// clone on this Mac: their recordings, clips, LoRAs and lexicons live under profiles/<id>/, outside the repo and the
// app, so a shared Regista starts with no profile and no voice. Generation only ever uses the active profile.

/// Consent spoken at the start of the first take of a language.
public struct VoiceConsent: Codable, Hashable, Sendable {
    public var text: String
    /// The take it was heard in.
    public var take: String
    /// ISO 8601.
    public var date: String
}

public struct VoiceProfile: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// ISO 8601.
    public var created: String
    /// Hash of the hardware UUID of the Mac the profile belongs to.
    public var machine: String
    /// Language → voice setup (LoRA, reference clips, trained tones).
    public var voices: [String: VoiceLanguage]
    /// Language → consent heard in the first take.
    public var consents: [String: VoiceConsent]?
}

/// One profile as seen from this Mac.
public struct ProfileEntry: Sendable {
    public var profile: VoiceProfile
    public var directory: URL
    /// Created on another Mac (copied folder): listed, never used, until adopted.
    public var locked: Bool
}

/// The profiles folder. Every read goes to disk: the app, the MCP server and the CLI may all change it.
public struct ProfileStore: Sendable {
    public let directory: URL
    /// Hash identifying this Mac (injected in tests).
    public let machine: String

    public init(directory: URL, machine: String = ProfileStore.currentMachine) {
        self.directory = directory
        self.machine = machine
    }

    public static var defaultDirectory: URL {
        Generation.defaultStateDirectory.appendingPathComponent("profiles")
    }

    /// SHA-256 of the hardware UUID (never stored raw); falls back to the host name when IOKit has none.
    public static let currentMachine: String = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? String ?? ProcessInfo.processInfo.hostName
        return SHA256.hash(data: Data("regista-profile|\(uuid)".utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }()

    var activeFile: URL { directory.appendingPathComponent("active") }

    public func folder(_ id: String) -> URL { directory.appendingPathComponent(id) }

    func file(_ id: String) -> URL { folder(id).appendingPathComponent("profile.json") }

    public func all() throws -> [ProfileEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        return try names.sorted().compactMap { name in
            guard let d = fm.contents(atPath: file(name).path) else { return nil }
            do {
                let p = try JSONDecoder().decode(VoiceProfile.self, from: d)
                return ProfileEntry(profile: p, directory: folder(name), locked: p.machine != machine)
            } catch {
                throw CommandError(.io, "unreadable profile \(file(name).path): \(error)")
            }
        }
    }

    public func entry(_ id: String) throws -> ProfileEntry? { try all().first { $0.profile.id == id } }

    public var activeID: String? {
        (try? String(contentsOf: activeFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// The active profile, or nil when there is none (a fresh Regista). A locked or missing one is an error.
    public func active() throws -> ProfileEntry? {
        guard let id = activeID else { return nil }
        guard let e = try entry(id) else { return nil }
        return e
    }

    /// The active profile for using its voice: missing → how to create one; locked → how to adopt it.
    public func requireActive(command: String) throws -> ProfileEntry {
        guard let e = try active() else {
            throw CommandError.invalid("\(command): no profile on this Mac yet — create yours with profile.create {name}, then the voice: the person records it in Regista: the Voce panel's button to clone the voice, or Settings › Profile and voice (voice.enroll.script gives the text to read for a recording made elsewhere)")
        }
        guard !e.locked else {
            throw CommandError.conflict("\(command): profile \(e.profile.name) was created on another Mac and is locked here; its owner adopts it in the Regista app (Settings → Profile) if this is their new Mac")
        }
        return e
    }

    static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        let s = folded.map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { out, c in
            if c != "-" || (out.last != "-" && !out.isEmpty) { out.append(c) }
        }
        let t = s.hasSuffix("-") ? String(s.dropLast()) : s
        return t.isEmpty ? "profile" : String(t.prefix(32))
    }

    /// Creates a profile; it becomes active when no profile is active.
    public func create(name: String) throws -> (entry: ProfileEntry, activated: Bool) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw CommandError.invalid("profile.create: name is empty") }
        let existing = Set(try all().map(\.profile.id))
        var id = Self.slug(clean), n = 2
        while existing.contains(id) || FileManager.default.fileExists(atPath: folder(id).path) { id = "\(Self.slug(clean))-\(n)"; n += 1 }
        let p = VoiceProfile(id: id, name: clean, created: Generation.now(), machine: machine, voices: [:], consents: nil)
        try save(p)
        let activate = (try active()) == nil
        if activate { try setActive(id) }
        return (ProfileEntry(profile: p, directory: folder(id), locked: false), activate)
    }

    public func save(_ p: VoiceProfile) throws {
        try FileManager.default.createDirectory(at: folder(p.id), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(p).write(to: file(p.id), options: .atomic)
    }

    /// Reads, changes and writes one profile under a lock (the app and the MCP server may race).
    @discardableResult
    public func update(_ id: String, _ body: (inout VoiceProfile) throws -> Void) throws -> VoiceProfile {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try FileLock.with(directory.appendingPathComponent(".lock")) {
            guard let e = try entry(id) else { throw CommandError.notFound("no profile \(id)") }
            var p = e.profile
            try body(&p)
            try save(p)
            return p
        }
    }

    public func setActive(_ id: String) throws {
        guard let e = try entry(id) else { throw CommandError.notFound("no profile \(id)") }
        guard !e.locked else { throw CommandError.conflict("profile \(e.profile.name) belongs to another Mac: adopt it first") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(id.utf8).write(to: activeFile, options: .atomic)
    }

    /// Binds a profile copied from another Mac to this one (the owner's own migration).
    public func adopt(_ id: String) throws -> VoiceProfile {
        try update(id) { $0.machine = machine }
    }

    /// Moves the profile folder to the Trash; clears the active marker when it was active.
    public func delete(_ id: String) throws -> URL? {
        guard try entry(id) != nil else { throw CommandError.notFound("no profile \(id)") }
        var trashed: NSURL?
        do { try FileManager.default.trashItem(at: folder(id), resultingItemURL: &trashed) }
        catch { throw CommandError(.io, "cannot move \(folder(id).path) to the Trash: \(error.localizedDescription)") }
        if activeID == id { try? FileManager.default.removeItem(at: activeFile) }
        return trashed as URL?
    }

    /// The lexicon file of a language in a profile.
    public func lexiconFile(_ entry: ProfileEntry, language: String) -> URL {
        entry.directory.appendingPathComponent("voice/lexicon-\(language).json")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
