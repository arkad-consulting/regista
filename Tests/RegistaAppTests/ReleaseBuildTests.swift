import Foundation
import RegistaCore
import Testing
@testable import Regista

// #108: a downloaded app installs the Claude Code skill it ships (Contents/Resources/Skill), as the installer does from a
// source folder; a build without it ships none and copies nothing.

@Test func theClaudeCodeSkillComesFromTheApp() throws {
    _ = rigOutside   // the Claude clients' home is the test process's scratch folder (REGISTA_CLAUDE_HOME), never the real one
    #expect(ClaudeClients.homeOverride != nil)
    let root = TemporaryFolder.url.appendingPathComponent("regista-skill-\(UUID().uuidString)", isDirectory: true)
    let app = root.appendingPathComponent("Regista.app", isDirectory: true)
    let skill = app.appendingPathComponent("Contents/Resources/Skill/regista/SKILL.md")
    try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>test.regista.skill</string></dict></plist>".utf8)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let text = try String(contentsOf: RigOutside.repository.appendingPathComponent("handoff/skill/regista/SKILL.md"), encoding: .utf8)
    try text.write(to: skill, atomically: true, encoding: .utf8)
    let bundle = try #require(Bundle(url: app))
    #expect(ClaudeClients.bundledSkill(bundle: bundle)?.path == skill.path)
    let dest = ClaudeClients.skillDestination
    #expect(dest.path.hasPrefix(ClaudeClients.home.path + "/"), "the skill goes under the clients' home: \(dest.path)")
    try? FileManager.default.removeItem(at: dest)
    #expect(try ClaudeClients.installSkill(bundle: bundle))
    #expect(try String(contentsOf: dest, encoding: .utf8) == text)
    // The test process ships none: nothing to copy.
    #expect(ClaudeClients.bundledSkill() == nil)
    #expect(try !ClaudeClients.installSkill())
    try? FileManager.default.removeItem(at: dest)
}
