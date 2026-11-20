import AppKit
import Foundation
import RegistaCore
import Testing
@testable import Regista

// #131: the brand kit preview's sample caption is app-made text, so it follows the interface language: the app passes
// the kit's name when it fits a caption line, else «Il tuo brand» in the words' language; an agent calling
// brandkit.preview may pass its own words (`sample`), and without them the engine keeps its default.

/// Café Atelier (a built-in kit) under another name, as a whole definition with absolute asset paths.
private func kit(named name: String? = nil) throws -> (kit: BrandKit, json: JSONValue) {
    var k = BrandKit.cafeAtelier.absolutized()
    if let name { k.name = name }
    return (k, try JSONValue.parse(JSONEncoder().encode(k)))
}

extension MouseSuites {
@Suite(.serialized) @MainActor struct BrandKitSampleTests {
    /// In each language: a kit whose name is too long for a caption line gets the sample in that language, a short name is
    /// used as it is, and the render draws the words the app passes (the command's result says which, the last boxed).
    @Test(arguments: [("it", "Il tuo brand"), ("en", "Your brand"), ("fr", "Votre marque"), ("pt", "Sua marca")])
    func thePreviewCaptionIsInTheInterfaceLanguage(_ language: String, _ sample: String) throws {
        Words.override = MouseRig.table(language)
        Words.applies = { true }
        defer { Words.override = nil; Words.applies = nil }
        let long = try kit(named: "Laboratorio di ceramica del quartiere")
        #expect(BrandKitLibrary.sample(long.kit) == sample, "\(language): «\(BrandKitLibrary.sample(long.kit))»")
        #expect(BrandKitLibrary.sample(try kit().kit) == "Café Atelier", "\(language): a short name is not the caption")

        let dir = ProcessInfo.processInfo.environment["REGISTA_UI_SNAPSHOTS"].map { URL(fileURLWithPath: $0) } ?? rigTempDir("kit-sample")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("brandkit-preview-\(language).png")
        let r = try Engine(services: .live()).execute("brandkit.preview", params: [
            "definition": long.json, "path": .string(out.path), "width": 540, "backdrop": false, "sample": .string(BrandKitLibrary.sample(long.kit))])
        let words = sample.split(separator: " ").map { JSONValue.string(String($0)) }
        #expect(r["sample"] == .array(words) && r["keyword"] == words.last, "\(language): the preview drew \(r["sample"] ?? .null), keyword \(r["keyword"] ?? .null)")
        #expect(FileManager.default.fileExists(atPath: out.path), "\(language): no picture")
    }

    /// An agent's call without `sample`: the engine's own words, unchanged.
    @Test func anAgentWithoutSampleGetsTheEngineDefault() throws {
        let k = try kit()
        let out = rigTempDir("kit-sample").appendingPathComponent("default.png")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let r = try Engine(services: .live()).execute("brandkit.preview", params: ["definition": k.json, "path": .string(out.path), "width": 270, "backdrop": false])
        #expect(r["sample"] == ["IL", "TUO", "BRAND"] && r["keyword"] == "BRAND", "the default drew \(r["sample"] ?? .null)")
    }
}
}
