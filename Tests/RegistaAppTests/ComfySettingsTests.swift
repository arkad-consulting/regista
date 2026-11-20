import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #6: Settings › Motori › ComfyUI lets a person finish the setup: the row's detail has «Indirizzo» and «Cartella di
// ComfyUI» with «Scegli…» (written in engines.json, the rig's scratch copy), the state in words, and each model's files with
// whether ComfyUI sees them.

extension MouseSuites {
@Suite(.serialized) @MainActor struct ComfySettingsTests {
    static func engines() throws -> [String: JSONValue] {
        guard let d = FileManager.default.contents(atPath: EngineConfig.defaultFile.path) else { return [:] }
        return try JSONValue.parse(d).objectValue ?? [:]
    }

    /// Each control of the ComfyUI row, clicked with the mouse in the real Motori tab: it does what it must, once, and is
    /// still there afterwards; nothing else reacts.
    @Test func theComfyUIRowSetsTheAddressAndTheFolder() async throws {
        let before = FileManager.default.contents(atPath: EngineConfig.defaultFile.path)
        defer {   // the rig's scratch engines.json as it was
            if let before { try? before.write(to: EngineConfig.defaultFile) } else { try? FileManager.default.removeItem(at: EngineConfig.defaultFile) }
        }
        let app = try await AppRig()
        defer { app.close() }
        let size = CGSize(width: SettingsView.size.width, height: CGFloat(SettingsView.enginesRenderHeight))
        app.host(SettingsView(pinned: .engines, height: size.height), size: size, language: "it")
        await app.settle()
        let rig = try #require(app.rig)
        for _ in 0..<50 where rig.element("Imposta", role: "AXButton") == nil { await app.idle(0.2) }
        let setUp = try #require(rig.element("Imposta", role: "AXButton"), "no «Imposta» on the ComfyUI row")
        rig.click(setUp.centre)
        await app.settle()
        #expect(!rig.elements(containing: "Cartella di ComfyUI").isEmpty, "the row's detail did not open")
        #expect(!rig.elements(containing: "Spento: non risponde nessuno a questo indirizzo").isEmpty, "the server's state in words")
        #expect(!rig.elements(containing: "Non trovata").isEmpty, "the folder's state in words")

        // «Indirizzo»: type a new address, «Salva» writes comfyServer.
        let field = try #require(rig.elements().first { $0.role == "AXTextField" && $0.visible && $0.value.hasPrefix("http://127.0.0.1") })
        rig.click(field.centre)
        #expect(rig.isTyping, "the address field did not take the focus")
        rig.key(.end)
        for _ in field.value { rig.key(.delete) }   // empty the field as a person would
        rig.type("http://127.0.0.1:8000")
        let events = RigGuard.events.count
        #expect(rig.click("Salva", role: "AXButton"), "no «Salva»")
        await app.settle()
        let written = try Self.engines()["comfyServer"]
        #expect(written == "http://127.0.0.1:8000", "«Salva» did not write the address: \(written.map { $0.text() } ?? "nil"), field \(rig.elements().first { $0.role == "AXTextField" && $0.visible }?.value ?? "?")")
        #expect(rig.element("Salva", role: "AXButton") != nil && rig.element("Imposta", role: "AXButton") != nil, "the controls are still there")
        #expect(RigGuard.events.dropFirst(events).isEmpty, "nothing else reacted: \(RigGuard.events.dropFirst(events))")

        // «Scegli…»: the open panel (the rig answers it with a folder) writes comfyStart, once; «Togli» removes it.
        let folder = rigTempDir("comfyui-folder")
        RigGuard.panelAnswer = [folder]
        #expect(rig.click("Scegli…", role: "AXButton"), "no «Scegli…»")
        await app.settle()
        #expect(try Self.engines()["comfyStart"]?.stringValue == folder.path, "«Scegli…» did not write the folder")
        #expect(RigGuard.events.filter { $0.kind == .panel }.count >= 1)
        #expect(RigGuard.panelAnswer == nil, "one panel only")
        #expect(rig.element("Scegli…", role: "AXButton") != nil)
    }

    /// The ComfyUI row's detail and a model's files, drawn in Italian and French and read at full size.
    @Test(arguments: shotLanguages)
    func theComfyUISetupAndTheModelFilesReadInEachLanguage(_ language: String) async throws {
        let app = try await AppRig()
        defer { app.close() }
        let live = try await app.store.silent("engines.status")
        guard case .object(var o) = live else { return }
        o["tier"] = "pro"
        func mark(_ key: String, _ apply: (inout [String: JSONValue]) -> Void) {
            o[key] = .array((o[key]?.arrayValue ?? []).map { v in
                guard case .object(var e) = v else { return v }
                apply(&e)
                return .object(e)
            })
        }
        mark("engines") { e in
            if e["id"] == "comfyui" { e["running"] = true; e["startedByRegista"] = true; e["configured"] = true; e["path"] = "/Applications/ComfyUI" }
        }
        mark("components") { e in
            guard e["id"] == "comfyui-z-image", case .array(let files)? = e["files"] else { return }
            e["state"] = "missing"
            e["files"] = .array(files.enumerated().map { i, f in
                guard case .object(var x) = f else { return f }
                x["present"] = .bool(i < 2)
                return .object(x)
            })
        }
        let status = JSONValue.object(o)
        let size = CGSize(width: SettingsView.size.width, height: CGFloat(SettingsView.enginesRenderHeight))
        for open in ["comfyui", "comfyui-z-image"] {
            app.host(SettingsView(pinned: .engines, engines: EnginesDemo(status: status, tier: .pro, open: open), height: size.height), size: size, language: language)
            await app.settle()
            let words = MouseRig.table(language)
            func says(_ key: String) -> Bool { !app.rig!.elements(containing: words.localizedString(forKey: key, value: nil, table: nil)).isEmpty }
            if open == "comfyui" {
                #expect(says("Cartella di ComfyUI") && says("Indirizzo") && says("Risponde · avviato da Regista"), "\(language): the setup's words")
                #expect(!app.rig!.elements(containing: "/Applications/ComfyUI").isEmpty)
            } else {
                #expect(!app.rig!.elements(containing: "z_image_turbo_bf16.safetensors").isEmpty && !app.rig!.elements(containing: "models/vae").isEmpty)
                #expect(says("manca") && says("c'è"), "\(language): which files ComfyUI sees")
            }
            if let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"] {
                try app.snapshot(to: URL(fileURLWithPath: dir).appendingPathComponent("n28-motori-\(open)-\(language).png"))
            }
        }
    }
}
}
