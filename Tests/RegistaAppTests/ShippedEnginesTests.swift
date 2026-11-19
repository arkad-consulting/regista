import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #107, #114: Settings › Motori in an app that ships its engines: ffmpeg, ffprobe, whisper.cpp and DeepFilterNet read as part of
// the app, with no «Installa» button; CMake as not needed; the Base tier then lacks only the transcription model.

extension MouseSuites {
@Suite(.serialized) @MainActor struct ShippedEnginesTests {
    /// The live engines.status with the shipped flags a release build reports (the rows the Base tier shows).
    static func shippedStatus(_ store: EditorStore) async throws -> JSONValue {
        let live = try await store.silent("engines.status")
        func mark(_ list: [JSONValue]?, _ apply: (inout [String: JSONValue]) -> Void) -> JSONValue {
            .array((list ?? []).map { v in
                guard case .object(var o) = v else { return v }
                apply(&o)
                return .object(o)
            })
        }
        guard case .object(var o) = live else { return live }
        o["tier"] = "base"
        o["engines"] = mark(live["engines"]?.arrayValue) { e in
            switch e["id"]?.stringValue {
            case "ffmpeg", "ffprobe", "whisper.cpp", "deepfilternet": e["shipped"] = true; e["state"] = "installed"
            case "whisper-model": e["state"] = "missing"
            default: break
            }
        }
        o["components"] = mark(live["components"]?.arrayValue) { e in
            if e["id"]?.stringValue == "cmake" { e["notNeeded"] = true; e["state"] = "installed" }
        }
        return .object(o)
    }

    @Test(arguments: ["it", "fr"])
    func theShippedEnginesReadAsPartOfTheApp(_ language: String) async throws {
        let app = try await AppRig()
        defer { app.close() }
        let status = try await Self.shippedStatus(app.store)
        let size = CGSize(width: SettingsView.size.width, height: 1100)
        app.host(SettingsView(pinned: .engines, engines: EnginesDemo(status: status, tier: .base), height: size.height), size: size, language: language)
        await app.settle()
        let words = MouseRig.table(language)
        let part = words.localizedString(forKey: "Incluso nell'app", value: nil, table: nil)
        let notNeeded = words.localizedString(forKey: "Non serve con questa app", value: nil, table: nil)
        #expect(app.rig.elements(containing: part).count >= 4, "\(language): «\(part)» on the four shipped engines")
        #expect(!app.rig.elements(containing: notNeeded).isEmpty, "\(language): CMake reads «\(notNeeded)»")
        let install = words.localizedString(forKey: "Installa", value: nil, table: nil)
        // SwiftUI's own Button titles read the test process's tables (the Italian keys), the app's words the window's.
        let installs = Set([install, "Installa"]).flatMap { app.rig.elements(containing: $0).filter(\.isControl) }
        #expect(installs.count == 1, "\(language): one «\(install)», the transcription model's")
        // #114: the shipped build's licence and size, not the Homebrew formula's (0.21 GB, «… AND GPL-2.0-or-later»).
        #expect(!app.rig.elements(containing: "LGPL-2.1-or-later").isEmpty, "\(language): the shipped ffmpeg's licence")
        #expect(app.rig.elements(containing: "GPL-2.0-or-later").isEmpty, "\(language): a GPL licence for the shipped ffmpeg")
        let shippedSize = EnginesSettings.localDisk(try #require(EngineManifest.shared.shippedDiskText("ffmpeg")))
        #expect(!app.rig.elements(containing: shippedSize).isEmpty, "\(language): the shipped size \(shippedSize)")
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("n26-motori-shipped-\(language).png"))
        }
    }
}
}

// #114: a shipped engine's row states the shipped build's licence and size (the manifest's `shipped` block), the same as
// THIRD-PARTY-LICENSES.md, never the Homebrew formula's.

@Test func theShippedFactsMatchTheThirdPartyLicences() throws {
    let text = try String(contentsOf: RigOutside.repository.appendingPathComponent("THIRD-PARTY-LICENSES.md"), encoding: .utf8)
    // The table's rows: | Program | Version | Licence | Source | How it is made |
    let rows = text.split(separator: "\n").filter { $0.hasPrefix("| `") }.map { $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
    let programs = ["ffmpeg": "`ffmpeg`", "ffprobe": "`ffprobe`", "whisper.cpp": "`whisper-cli`", "deepfilternet": "`deep-filter`"]
    for (id, program) in programs {
        let shipped = try #require(EngineManifest.shared.entry(id)?.shipped, "\(id) has no shipped block")
        let row = try #require(rows.first { $0[0].contains(program) }, "\(program) is not in THIRD-PARTY-LICENSES.md")
        #expect(row[2] == shipped.licence, "\(id): the manifest says \(shipped.licence), THIRD-PARTY-LICENSES.md \(row[2])")
        #expect(shipped.bytes > 1_000_000 && shipped.bytes < 100_000_000, "\(id): \(shipped.bytes) bytes")
    }
    // The catalog row of a shipped engine: the shipped facts; of the same engine installed by Homebrew: the formula's.
    let status: JSONValue = ["tier": "base", "memoryGB": 8, "engines": [["id": "ffmpeg", "state": "installed", "shipped": true]]]
    let row = try #require(EngineCatalog(status: status).row("ffmpeg"))
    #expect(row.licence == "LGPL-2.1-or-later" && row.disk == "8 MB", "\(row.licence) · \(row.disk)")
    let dev = try #require(EngineCatalog(status: ["tier": "base", "memoryGB": 8, "engines": [["id": "ffmpeg", "state": "installed"]]]).row("ffmpeg"))
    #expect(dev.licence == EngineManifest.shared.entry("ffmpeg")?.licence && dev.disk == EngineManifest.shared.diskText("ffmpeg"))
}
