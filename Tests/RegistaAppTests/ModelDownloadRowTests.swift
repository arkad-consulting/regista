import AppKit
import RegistaCore
import SwiftUI
import Testing
@testable import Regista

// #121: Settings › Motori, a ComfyUI model's detail: «Scarica» on each missing file with a direct URL (its size on the
// same line), «Scarica tutti (N file, X GB)» above several, and while a file downloads its bar, percent and «Annulla» in
// the same place. Every click with the mouse on the real Motori tab; every download comes from a stand-in server of this
// test process into a scratch ComfyUI folder (RigServices' seams), never from the network.

extension MouseSuites {
@Suite(.serialized) @MainActor struct ModelDownloadRowTests {
    /// A scratch ComfyUI folder the rig's Regista knows as a folder.
    static func comfyFolder() throws -> URL {
        let f = rigTempDir("comfyui-models").appendingPathComponent("ComfyUI", isDirectory: true)
        try FileManager.default.createDirectory(at: f.appendingPathComponent("comfy"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: f.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
        try Data().write(to: f.appendingPathComponent("main.py"))
        let py = f.appendingPathComponent(".venv/bin/python")
        try "#!/bin/sh\n".write(to: py, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
        return URL(fileURLWithPath: (f.path as NSString).resolvingSymlinksInPath, isDirectory: true)
    }

    /// The rig on the Pro tier, its ComfyUI at `start`, its downloads from `server`.
    static func rig(start: String, server: StandInFiles) async throws -> AppRig {
        try await AppRig { s in
            s.tier = .pro
            s.config.comfyStart = start
            s.modelSource = ModelFetch.Source(url: { server.url($0.name) }, freeSpace: { _ in 1 << 50 })
        }
    }

    /// The Motori tab, live, with the Real-ESRGAN + RIFE row open (its two files: 67 MB and 23 MB).
    static func openUpscale(_ app: AppRig, language: String) async throws {
        // Taller than the tab's usual render: the open row and its files are at the bottom of the list.
        let size = CGSize(width: SettingsView.size.width, height: CGFloat(SettingsView.enginesRenderHeight + 500))
        app.host(SettingsView(pinned: .engines, height: size.height), size: size, language: language)
        await app.settle()
        let rig = try #require(app.rig)
        let words = MouseRig.table(language)
        let how = words.localizedString(forKey: "Come installarlo", value: nil, table: nil)
        for _ in 0..<50 where rig.elements(containing: "Real-ESRGAN + RIFE").isEmpty { await app.idle(0.2) }
        let name = try #require(rig.elements(containing: "Real-ESRGAN + RIFE").first, "no Real-ESRGAN + RIFE row")
        let button = try #require(rig.elements().filter { $0.role == "AXButton" && $0.visible && $0.name == how }
            .min { abs($0.frame.midY - name.frame.midY) < abs($1.frame.midY - name.frame.midY) }, "no «\(how)» on the row")
        rig.click(button.centre)
        await app.settle()
        for _ in 0..<50 where rig.elements(containing: "RealESRGAN_x4plus.pth").isEmpty { await app.idle(0.2) }
    }

    /// The «Scarica» (or «Annulla») on the line of `file`.
    static func button(_ title: String, of file: String, in app: AppRig) -> RigElement? {
        guard let rig = app.rig, let name = rig.elements(containing: file).first(where: { $0.role == "AXStaticText" }) else { return nil }
        return rig.elements().filter { $0.role == "AXButton" && $0.visible && $0.name == title && abs($0.frame.midY - name.frame.midY) < 12 }.first
    }

    static func wait(_ app: AppRig, _ seconds: Double = 10, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { await app.idle(0.1) }
    }

    @Test(arguments: shotLanguages)
    func aMissingFileIsDownloadedFromItsRowWithItsBarAndCancel(_ language: String) async throws {
        let server = try StandInFiles()
        let rife = try #require(EngineManifest.shared.modelFile("rife_v4.26.safetensors"))
        let esrgan = try #require(EngineManifest.shared.modelFile("RealESRGAN_x4plus.pth"))
        // Bytes of the right size whose checksum is not the publisher's (no model file is ever fetched here).
        server[rife.name] = Data(count: Int(rife.bytes))
        server[esrgan.name] = Data(count: Int(esrgan.bytes))
        let folder = try Self.comfyFolder()
        let app = try await Self.rig(start: folder.path, server: server)
        defer { app.close() }
        try await Self.openUpscale(app, language: language)
        let rig = try #require(app.rig)
        let words = MouseRig.table(language)
        func w(_ key: String) -> String { words.localizedString(forKey: key, value: nil, table: nil) }
        let shots = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
        func shot(_ state: String) throws { if let shots { try app.snapshot(to: shots.appendingPathComponent("n30-motori-download-\(state)-\(language).png")) } }

        // Missing: «Scarica» on each line, «Scarica tutti» above them.
        let all = String(format: w("Scarica tutti (%d file, %@)"), 2, EnginesSettings.localDisk(EngineManifest.sizeText(rife.bytes + esrgan.bytes)))
        #expect(rig.element(all, role: "AXButton") != nil, "\(language): no «\(all)»")
        #expect(Self.button(w("Scarica"), of: rife.name, in: app) != nil && Self.button(w("Scarica"), of: esrgan.name, in: app) != nil)
        try shot("missing")

        // «Scarica» on rife: a download starts, held half-way: its bar, percent and «Annulla» on the same line.
        server.mode = .hold(after: 10_000_000)
        let events = RigGuard.events.count
        rig.click(try #require(Self.button(w("Scarica"), of: rife.name, in: app)).centre)
        let kind = EnginesModel.fetchKind(rife.name)
        await Self.wait(app) { (app.store.jobs.latest(kind)?.progress ?? 0) > 0.4 }
        let job = try #require(app.store.jobs.latest(kind), "«Scarica» started no job")
        #expect(job.isRunning && server.requests.filter { $0.path == "/" + rife.name }.count == 1, "one download of that file")
        #expect(Self.button(w("Annulla"), of: rife.name, in: app) != nil, "«Annulla» in the line")
        #expect(!rig.elements(containing: "%").isEmpty, "the percent")
        #expect(Self.button(w("Scarica"), of: esrgan.name, in: app) != nil, "the other file keeps its «Scarica»")
        #expect(RigGuard.events.dropFirst(events).isEmpty, "nothing else reacted: \(RigGuard.events.dropFirst(events))")
        try shot("downloading")

        // «Annulla»: the job ends cancelled, the partial file stays, «Scarica» is back.
        rig.click(try #require(Self.button(w("Annulla"), of: rife.name, in: app)).centre)
        await Self.wait(app) { app.store.jobs.latest(kind)?.isRunning == false && Self.button(w("Scarica"), of: rife.name, in: app) != nil }
        #expect(app.store.jobs.latest(kind)?.state == .cancelled)
        let part = folder.appendingPathComponent("models/frame_interpolation/\(rife.name).part")
        await Self.wait(app) { ModelDownloads.shared.all.last { $0.file.name == rife.name }?.state == .cancelled }
        #expect(((try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? Int) == 10_000_000, "the partial file is kept")
        #expect(!rig.elements(containing: w("Download annullato: «Scarica» riprende da dove si è fermato.")).isEmpty)

        // «Scarica» again: it resumes with a Range, the whole file is checked, the wrong checksum is said in words.
        server.mode = .normal
        rig.click(try #require(Self.button(w("Scarica"), of: rife.name, in: app)).centre)
        await Self.wait(app) { app.store.jobs.latest(kind).map { !$0.isRunning } == true && app.store.jobs.latest(kind)?.state != .cancelled }
        #expect(server.requests.last { $0.path == "/" + rife.name }?.range == "bytes=10000000-")
        let checksum = w("Il file scaricato non corrisponde al suo checksum e l'ho cancellato: scaricalo di nuovo. Se succede ancora, il file sulla pagina dell'autore è cambiato.")
        if case .failed(let why) = app.store.jobs.latest(kind)?.state { #expect(why == checksum) } else { Issue.record("the job did not fail on the checksum") }
        await Self.wait(app) { !rig.elements(containing: String(checksum.prefix(30))).isEmpty }
        #expect(!rig.elements(containing: String(checksum.prefix(30))).isEmpty, "the failure in words on the line")
        #expect(!FileManager.default.fileExists(atPath: part.path), "the partial file was removed")
        try shot("checksum")

        // «Scarica tutti»: one job per file.
        let before = server.requests.count
        #expect(rig.click(all, role: "AXButton"), "no «\(all)»")
        await Self.wait(app) { server.requests.count >= before + 2 }
        #expect(Set(server.requests.dropFirst(before).map(\.path)) == ["/" + rife.name, "/" + esrgan.name])
        await Self.wait(app) { app.store.jobs.latest(EnginesModel.fetchKind(esrgan.name))?.isRunning == false && app.store.jobs.latest(kind)?.isRunning == false }

        // Done: a file in place with its size (a sparse file here) is not offered again and says to restart ComfyUI.
        let target = folder.appendingPathComponent("models/upscale_models/\(esrgan.name)")
        FileManager.default.createFile(atPath: target.path, contents: nil)
        let h = try FileHandle(forWritingTo: target)
        try h.truncate(atOffset: UInt64(esrgan.bytes))
        try h.close()
        app.store.jobs.jobs.filter { !$0.isRunning }.forEach { app.store.jobs.dismiss($0.id) }
        try await Self.openUpscale(app, language: language)
        let rig2 = try #require(app.rig)
        await Self.wait(app) { !rig2.elements(containing: w("Scaricato: riavvia ComfyUI perché lo veda.")).isEmpty }
        #expect(!rig2.elements(containing: w("Scaricato: riavvia ComfyUI perché lo veda.")).isEmpty, "the done line")
        #expect(Self.button(w("Scarica"), of: esrgan.name, in: app) == nil && rig2.element(all, role: "AXButton") == nil)
        #expect(Self.button(w("Scarica"), of: rife.name, in: app) != nil)
        try shot("done")
    }

    /// ComfyUI started by a program: Regista does not know its folder, so no «Scarica», and one line says what to set.
    @Test func aStartProgramGetsNoDownloadButtonAndSaysWhatToSet() async throws {
        let server = try StandInFiles()
        let start = rigTempDir("comfy-start").appendingPathComponent("start-comfyui")
        try "#!/bin/sh\n".write(to: start, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: start.path)
        let app = try await Self.rig(start: start.path, server: server)
        defer { app.close() }
        try await Self.openUpscale(app, language: "it")
        let rig = try #require(app.rig)
        #expect(!rig.elements(containing: "Regista non sa in quale cartella è ComfyUI").isEmpty, "the line that says what to set")
        #expect(Self.button("Scarica", of: "rife_v4.26.safetensors", in: app) == nil && rig.elements(containing: "Scarica tutti").isEmpty)
        #expect(server.requests.isEmpty)
    }
}
}
