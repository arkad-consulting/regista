import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #107: Settings › Motori in an app that ships its engines: ffmpeg, ffprobe, whisper.cpp and DeepFilterNet read as part of
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
        if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
            try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("n25-motori-shipped-\(language).png"))
        }
    }
}
}
