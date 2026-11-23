import Foundation
import Testing
import RegistaCore
@testable import RegistaMCP

// The person's skills through the tools (#157): the calls a Claude makes, over MCP, on a scratch support folder — a skill
// written, read back, used by a project, changed, exported, removed and imported again, then every change undone in turn.

private func call(_ s: MCPServer, _ tool: String, _ arguments: JSONValue = [:], sourceLocation: SourceLocation = #_sourceLocation) throws -> JSONValue {
    let r = try #require(s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": arguments]]),
                         sourceLocation: sourceLocation)
    #expect(r.value(at: "result.isError") == false, "\(tool): \(r.value(at: "result.content.0.text")?.stringValue ?? "")", sourceLocation: sourceLocation)
    return r.value(at: "result.structuredContent") ?? .null
}

@Test func aSkillMadeThroughTheToolsIsReadUsedExportedRemovedImportedAndEveryChangeUndone() throws {
    let root = TemporaryFolder.url.appendingPathComponent("regista-skill-journey-\(UUID().uuidString.prefix(8))", isDirectory: true)
    var services = EngineServices.standard()
    services.rules = RuleBook(directory: root.appendingPathComponent("support/rules", isDirectory: true))
    let book = services.rules
    #expect(book.skillsDirectory.path.hasPrefix(root.path), "the skills folder is not the scratch one")
    let s = MCPServer(host: InProcessEngineHost(engine: Engine(services: services)))

    // The tools are there, the writing ones not marked read-only.
    let tools = try #require(s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])?.value(at: "result.tools")?.arrayValue)
    for name in ["skill_list", "skill_get"] { #expect(tools.first { $0["name"] == .string(name) }?.value(at: "annotations.readOnlyHint") == true, "\(name)") }
    for name in ["skill_create", "skill_set", "skill_duplicate", "skill_remove", "skill_export", "skill_import"] {
        #expect(tools.first { $0["name"] == .string(name) }?.value(at: "annotations.readOnlyHint") == false, "\(name) is marked read-only")
    }

    // A project first (opening one clears the history), then the skill the person asked for.
    _ = try call(s, "project_new", ["name": "journey", "directory": .string(root.appendingPathComponent("projects").path)])
    let made = try call(s, "skill_create", [
        "title": "Long interview", "basedOn": "talking-head-reel",
        "steps": "1. Read the questions.\n2. Cut the pauses, no zoom.\n3. Look at the frames.",
        "rules": ["prose": "No music under the answers."], "choices": ["captions": "elegant-serif", "framing": "still"], "language": "en",
    ])
    let slug = try #require(made["skill"]?.stringValue)
    let file = book.file(slug)
    let created = try #require(FileManager.default.contents(atPath: file.path))
    // Read back: the list, the whole skill, the recipe.
    #expect(try call(s, "skill_list")["skills"]?.arrayValue?.map { $0["skill"] } == [.string(slug)])
    let got = try call(s, "skill_get", ["skill": .string(slug), "language": "en"])
    #expect(got["steps"]?.stringValue?.hasPrefix("1. Read the questions.") == true && got.value(at: "rules.prose") == "No music under the answers.\n")
    #expect(got["choices"]?.arrayValue?.first { $0["id"] == "framing" }?["value"] == "still")
    #expect(try call(s, "recipe_get")["recipes"]?.arrayValue?.contains { $0["name"] == .string(slug) && $0["skill"] == true } == true)
    // Used by the project.
    _ = try call(s, "project_setKind", ["kind": .string(slug)])
    let recipe = try call(s, "recipe_get", ["name": .string(slug), "language": "en"])["text"]?.stringValue ?? ""
    #expect(recipe.contains("## Steps\n\n1. Read the questions.") && recipe.contains("- framing: still") && recipe.contains("# Rules that always hold"))
    #expect(try call(s, "rules_check")["kind"] == .string(slug))
    // Changed, exported, removed.
    _ = try call(s, "skill_set", ["skill": .string(slug), "choices": ["music": "never"]])
    let changed = try #require(FileManager.default.contents(atPath: file.path))
    let out = root.appendingPathComponent("for-a-colleague.md")
    #expect(try call(s, "skill_export", ["skill": .string(slug), "path": .string(out.path)])["path"] == .string(out.path))
    #expect(FileManager.default.contents(atPath: out.path) == changed)
    _ = try call(s, "skill_remove", ["skill": .string(slug)])
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try call(s, "rules_check")["kindSource"] == "format", "the project still follows the removed skill")
    // Imported again: a dry run first (nothing written), then for real.
    let dry = try call(s, "skill_import", ["path": .string(out.path), "dryRun": true])
    #expect(dry["dryRun"] == true && dry.value(at: "skill.title") == "Long interview" && !FileManager.default.fileExists(atPath: file.path))
    #expect(try call(s, "skill_import", ["path": .string(out.path)])["added"] == .string(slug))
    #expect(FileManager.default.contents(atPath: file.path) == changed)
    #expect(try call(s, "rules_check")["kind"] == .string(slug), "the project does not follow the skill imported again")

    // Every change undone in turn: the import, the removal, the change, the project's kind, the creation.
    #expect(try call(s, "history_undo")["undone"] == "skill.import")
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(try call(s, "history_undo")["undone"] == "skill.remove")
    #expect(FileManager.default.contents(atPath: file.path) == changed)
    #expect(try call(s, "history_undo")["undone"] == "skill.set")
    #expect(FileManager.default.contents(atPath: file.path) == created)
    #expect(try call(s, "history_undo")["undone"] == "project.setKind")
    #expect(try call(s, "rules_check")["kindSource"] == "format")
    #expect(try call(s, "history_undo")["undone"] == "skill.create")
    let left = try call(s, "skill_list")["skills"]?.arrayValue
    #expect(!FileManager.default.fileExists(atPath: file.path) && left?.isEmpty == true)
    // Nothing outside the scratch folder: the export where asked, the skill in its folder, no rule sheet written.
    #expect((try? FileManager.default.contentsOfDirectory(atPath: book.directory.path)) ?? [] == [])
}
