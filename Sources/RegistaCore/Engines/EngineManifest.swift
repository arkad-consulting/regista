import Foundation

/// Every engine, model, tool and provider Regista can use, from `scripts/engines.manifest.json`, with the download facts
/// (version, dates, sha256, size, url) of `scripts/engines.lock`. Both files are compiled into RegistaCore
/// (`Package.swift`, `.embedInCode`), so the app bundle, `regista-mcp` / `regista-engine` and the tests read the same
/// facts as the installer and `docs/reference/engines.md`, with nothing to locate at run time.
public struct EngineManifest: Sendable {
    public struct Tier: Codable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let ramGB: Double
        public let detectFromGB: Double
    }

    public struct Install: Codable, Hashable, Sendable {
        /// installer, homebrew, system, firstUse, manual or cloud.
        public let method: String
        public let step: String?
        public let formula: String?
        public let steps: [String]?
    }

    public struct Entry: Hashable, Sendable {
        public let id: String
        public let name: String
        public let role: String
        public let unlocks: [String]
        /// nil only for planned entries.
        public let minRamGB: Double?
        public let ramInUseGB: Double?
        /// Installed footprint when the manifest states it (`declaresDisk`); nil there = unknown.
        public let diskBytes: Int64?
        public let declaresDisk: Bool
        public let licence: String
        public let nonCommercial: Bool
        /// The licence text to show before an opt-in install (the non-commercial aligners, #20).
        public let licenceUrl: String?
        public let install: Install
        public let artifacts: [String]
        /// What the engine puts in Regista's engines folder, relative to it (the Motori screen removes exactly these).
        public let files: [String]
        public let optional: Bool
        public let dependsOn: [String]
        /// available or planned.
        public let status: String
        public let version: String?
        public let paid: Bool

        public var planned: Bool { status == "planned" }
    }

    /// One row of engines.lock.
    public struct Artifact: Hashable, Sendable {
        public let id: String
        public let version: String
        public let released: String
        public let pinned: String
        public let sha256: String
        public let size: Int64?
        public let url: String
    }

    public let tiers: [Tier]
    public let diskMarginGB: Double
    public let entries: [Entry]
    public let artifacts: [Artifact]

    /// The compiled-in manifest. Its parsing is covered by the tests, so a failure here is a build that skipped them.
    public static let shared: EngineManifest = {
        do {
            return try parse(manifest: Data(PackageResources.engines_manifest_json),
                             lock: String(decoding: PackageResources.engines_lock, as: UTF8.self))
        } catch { fatalError("\(error)") }
    }()

    public struct ParseError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    // MARK: lookups

    public func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }
    public func artifact(_ id: String) -> Artifact? { artifacts.first { $0.id == id } }

    /// The lock rows an entry names (an id ending with ":" = every row with that prefix).
    public func artifacts(of e: Entry) -> [Artifact] {
        e.artifacts.flatMap { a in a.hasSuffix(":") ? artifacts.filter { $0.id.hasPrefix(a) } : artifacts.filter { $0.id == a } }
    }

    /// Installed footprint: the stated size, else the sum of the artifacts' download sizes; nil = unknown.
    public func diskBytes(_ e: Entry) -> Int64? {
        if e.declaresDisk { return e.diskBytes }
        let rows = artifacts(of: e)
        guard !rows.isEmpty else { return nil }
        var total: Int64 = 0
        for r in rows { guard let s = r.size else { return nil }; total += s }
        return total
    }

    /// "4.96 GB", "28 MB", "–" (nothing to download), "?" (unknown): the same rounding as docs/reference/engines.md.
    public func diskText(_ id: String) -> String {
        guard let e = entry(id), let b = diskBytes(e) else { return "?" }
        if b == 0 { return "–" }
        return b < 100_000_000 ? String(format: "%.0f MB", Double(b) / 1e6) : String(format: "%.2f GB", Double(b) / 1e9)
    }

    /// The lowest tier whose RAM covers the entry's minimum (nil = planned).
    public func tier(of e: Entry) -> MachineTier? {
        guard let ram = e.minRamGB else { return nil }
        return tiers.last { $0.ramGB <= ram }.flatMap { MachineTier(rawValue: $0.id) }
    }

    /// The minimum tier of an engine or provider. An id missing from the manifest is a programming error the tests
    /// catch (ManifestTests scans the sources); it falls back to base rather than crash a running app.
    public func minimumTier(_ id: String) -> MachineTier {
        entry(id).flatMap { tier(of: $0) } ?? .base
    }

    public func info(_ tier: MachineTier) -> Tier { tiers.first { $0.id == tier.rawValue }! }

    /// The tier a Mac with that much RAM gets.
    public func tier(forMemoryGB gb: Double) -> MachineTier {
        MachineTier(rawValue: tiers.last { gb >= $0.detectFromGB }?.id ?? tiers[0].id) ?? .base
    }

    /// What scripts/install.sh installs without asking on a tier (scripts/engines.py `installed_by_installer`).
    public func installerEntries(_ tier: MachineTier) -> [Entry] {
        entries.filter { e in
            guard !e.planned, !e.optional, ["installer", "homebrew"].contains(e.install.method), let t = self.tier(of: e) else { return false }
            return t <= tier
        }
    }

    /// Free disk the installer asks for on a tier, whole GB (scripts/engines.py `need_gb`).
    public func installerNeedGB(_ tier: MachineTier) -> Int {
        let total = installerEntries(tier).reduce(Int64(0)) { $0 + (diskBytes($1) ?? 0) }
        return Int((Double(total) / 1e9 + diskMarginGB).rounded(.up))
    }

    // MARK: parsing

    public static func parse(manifest data: Data, lock: String) throws -> EngineManifest {
        let artifacts = try parseLock(lock)
        let raw: RawManifest
        do { raw = try JSONDecoder().decode(RawManifest.self, from: data) }
        catch let error as DecodingError { throw ParseError(description: "engines.manifest.json: \(describe(error, data))") }
        let m = EngineManifest(tiers: raw.tiers, diskMarginGB: raw.diskMarginGB, entries: raw.engines, artifacts: artifacts)
        try m.validate()
        return m
    }

    static func parseLock(_ text: String) throws -> [Artifact] {
        var rows: [Artifact] = []
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let l = String(line)
            if l.trimmingCharacters(in: .whitespaces).isEmpty || l.hasPrefix("#") { continue }
            let c = l.components(separatedBy: " | ")
            guard c.count >= 7 else { throw ParseError(description: "engines.lock line \(n + 1): expected 7 columns separated by \" | \", got \(c.count): \(l)") }
            rows.append(Artifact(id: c[0], version: c[1], released: c[2], pinned: c[3], sha256: c[4], size: Int64(c[5]), url: c[6]))
        }
        return rows
    }

    func validate() throws {
        var problems: [String] = []
        if tiers.map(\.id) != MachineTier.allCases.map(\.rawValue) {
            problems.append("tiers must be \(MachineTier.allCases.map(\.rawValue).joined(separator: ", ")) in that order")
        }
        var seen = Set<String>()
        for e in entries {
            if !seen.insert(e.id).inserted { problems.append("\(e.id): id appears twice") }
            if e.minRamGB == nil && !e.planned { problems.append("\(e.id): minRamGB null is only allowed for planned entries") }
            if !["available", "planned"].contains(e.status) { problems.append("\(e.id): status must be available or planned") }
            if e.licence.trimmingCharacters(in: .whitespaces).isEmpty { problems.append("\(e.id): no licence") }
            for f in e.files where f.isEmpty || f.hasPrefix("/") || f.split(separator: "/").contains("..") {
                problems.append("\(e.id): files must be paths relative to the engines folder (got \(f))")
            }
            for a in e.artifacts where artifacts(of: Entry.withArtifacts([a])).isEmpty {
                problems.append("\(e.id): artifact \(a) is not in engines.lock")
            }
        }
        for e in entries { for d in e.dependsOn where !seen.contains(d) { problems.append("\(e.id): dependsOn \(d) is not in the manifest") } }
        if !problems.isEmpty { throw ParseError(description: "engines.manifest.json: " + problems.joined(separator: "; ")) }
    }

    /// "entry 3 (whisper.cpp): key 'licence' missing" — the path of a decoding error in words.
    static func describe(_ error: DecodingError, _ data: Data) -> String {
        func where_(_ path: [CodingKey]) -> String {
            var parts: [String] = []
            var i = 0
            while i < path.count {
                let k = path[i]
                if k.stringValue == "engines", i + 1 < path.count, let n = path[i + 1].intValue {
                    let ids = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["engines"] as? [[String: Any]]
                    let id = (ids.flatMap { n < $0.count ? $0[n]["id"] as? String : nil }).map { " (\($0))" } ?? ""
                    parts.append("entry \(n + 1)\(id)"); i += 2; continue
                }
                parts.append(k.intValue.map { "[\($0)]" } ?? k.stringValue); i += 1
            }
            return parts.isEmpty ? "top level" : parts.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx): return "\(where_(ctx.codingPath)): key '\(key.stringValue)' missing"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx): return "\(where_(ctx.codingPath)): \(ctx.debugDescription)"
        case .dataCorrupted(let ctx): return "\(where_(ctx.codingPath)): \(ctx.debugDescription) \((ctx.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String ?? "")"
        @unknown default: return "\(error)"
        }
    }

    private struct RawManifest: Decodable {
        let tiers: [Tier]
        let diskMarginGB: Double
        let engines: [Entry]
    }
}

extension EngineManifest.Entry: Decodable {
    private enum K: String, CodingKey {
        case id, name, role, unlocks, minRamGB, ramInUseGB, diskBytes, licence, nonCommercial, licenceUrl, install, artifacts, files, optional,
             dependsOn, status, version, paid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        role = try c.decode(String.self, forKey: .role)
        unlocks = try c.decode([String].self, forKey: .unlocks)
        minRamGB = try c.decodeNil(forKey: .minRamGB) ? nil : try c.decode(Double.self, forKey: .minRamGB)
        ramInUseGB = try c.decodeIfPresent(Double.self, forKey: .ramInUseGB)
        declaresDisk = c.contains(.diskBytes)
        diskBytes = try c.decodeIfPresent(Int64.self, forKey: .diskBytes)
        licence = try c.decode(String.self, forKey: .licence)
        nonCommercial = try c.decode(Bool.self, forKey: .nonCommercial)
        licenceUrl = try c.decodeIfPresent(String.self, forKey: .licenceUrl)
        install = try c.decode(EngineManifest.Install.self, forKey: .install)
        artifacts = try c.decodeIfPresent([String].self, forKey: .artifacts) ?? []
        files = try c.decodeIfPresent([String].self, forKey: .files) ?? []
        optional = try c.decode(Bool.self, forKey: .optional)
        dependsOn = try c.decode([String].self, forKey: .dependsOn)
        status = try c.decode(String.self, forKey: .status)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        paid = try c.decodeIfPresent(Bool.self, forKey: .paid) ?? false
    }

    /// A throwaway entry to resolve artifact patterns during validation.
    static func withArtifacts(_ a: [String]) -> Self {
        .init(id: "", name: "", role: "", unlocks: [], minRamGB: nil, ramInUseGB: nil, diskBytes: nil, declaresDisk: false,
              licence: "", nonCommercial: false, licenceUrl: nil, install: .init(method: "", step: nil, formula: nil, steps: nil), artifacts: a,
              files: [], optional: false, dependsOn: [], status: "", version: nil, paid: false)
    }
}
