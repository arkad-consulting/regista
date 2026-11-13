import Foundation
import Testing
@testable import RegistaCore

// M3 (#60): installs without the owner's folders — no developer path in Sources/ or scripts/, the ComfyUI setup check
// (generate.check, #36), the pinned aligners with Italian / French opt-in (#20), Node + HyperFrames from a lockfile, and
// the installer / doctor messages in four languages.

private let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

// MARK: no developer paths

@Test func noDeveloperPathInSourcesOrScripts() throws {
    // A path that exists only on the developer's Mac (a code folder, a home folder) breaks a new user's install. Fixtures use temp dirs.
    let patterns = [#"~/code/"#, #"\$HOME/code"#, #"/Users/[a-z]+/"#, #"\{HOME\}/code"#, #"homeDirectoryForCurrentUser[^\n]*"code"#]
    let regex = try NSRegularExpression(pattern: patterns.joined(separator: "|"))
    var scanned = 0, hits: [String] = []
    for dir in ["Sources", "scripts"] {
        let walker = FileManager.default.enumerator(at: repo.appendingPathComponent(dir), includingPropertiesForKeys: nil)!
        while let f = walker.nextObject() as? URL {
            guard ["swift", "sh", "py", "json", "lock", "md", "command"].contains(f.pathExtension) || f.pathExtension.isEmpty,
                  let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            scanned += 1
            for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where regex.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)) != nil {
                hits.append("\(f.path.dropFirst(repo.path.count + 1)):\(n + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    #expect(scanned > 100, "the scan read only \(scanned) files")
    #expect(hits.isEmpty, "developer paths:\n\(hits.joined(separator: "\n"))")
}

// MARK: ComfyUI setup check

private let objectInfo: JSONValue = [
    "UNETLoader": ["input": ["required": ["unet_name": [["z_image_turbo_bf16.safetensors", "other.safetensors"]], "weight_dtype": [["default", "fp8"]]]]],
    "CLIPLoader": ["input": ["required": ["clip_name": [["qwen_3_4b.safetensors"]], "type": [["lumina2", "wan"]]]]],
    "VAELoader": ["input": ["required": ["vae_name": [["ae.safetensors"]]]]],
    // The newer combo format.
    "KSampler": ["input": ["required": ["sampler_name": ["COMBO", ["options": ["res_multistep", "euler"]]], "seed": ["INT", ["default": 0]]]]],
    "LoadImage": ["input": ["required": ["image": [["some-input.png"]]]]],
    "CLIPTextEncode": ["input": ["required": ["text": ["STRING", ["multiline": true]]]]],
]

private let zimage: JSONValue = [
    "1": ["class_type": "UNETLoader", "inputs": ["unet_name": "z_image_turbo_bf16.safetensors", "weight_dtype": "default"]],
    "2": ["class_type": "CLIPLoader", "inputs": ["clip_name": "qwen_3_4b.safetensors", "type": "lumina2"]],
    "3": ["class_type": "VAELoader", "inputs": ["vae_name": "ae.safetensors"]],
    "5": ["class_type": "CLIPTextEncode", "inputs": ["text": "PROMPT", "clip": ["2", 0]]],
    "8": ["class_type": "KSampler", "inputs": ["seed": 42, "sampler_name": "res_multistep", "model": ["1", 0]]],
    "11": ["class_type": "LoadImage", "inputs": ["image": "START_IMAGE"]],
]

@Test func comfyCheckFindsMissingNodesModelsAndValues() throws {
    #expect(ComfyCheck.check(workflow: zimage, objectInfo: objectInfo).isEmpty, "a complete setup is ready (per-request inputs and links skipped)")

    var renamed = zimage.objectValue!
    renamed["2"] = ["class_type": "CLIPLoader", "inputs": ["clip_name": "qwen_3_4b_renamed.safetensors", "type": "lumina2"]]
    renamed["8"] = ["class_type": "KSampler", "inputs": ["seed": 42, "sampler_name": "res_multistep_v2"]]
    renamed["20"] = ["class_type": "UnetLoaderGGUF", "inputs": ["unet_name": "Wan2.2-I2V-A14B-HighNoise-Q6_K.gguf"]]
    renamed["21"] = ["class_type": "SomeCustomNode", "inputs": [:]]
    let missing = ComfyCheck.check(workflow: .object(renamed), objectInfo: objectInfo)
    let model = try #require(missing.first { $0.kind == "model" })
    #expect(model.value == "qwen_3_4b_renamed.safetensors" && model.folder == "text_encoders" && model.hint.contains("models/text_encoders"))
    let value = try #require(missing.first { $0.kind == "value" })
    #expect(value.node == "KSampler" && value.input == "sampler_name" && value.value == "res_multistep_v2")
    let gguf = try #require(missing.first { $0.node == "UnetLoaderGGUF" })
    #expect(gguf.kind == "node" && gguf.hint.contains("ComfyUI-GGUF") && gguf.hint.contains("https://github.com/city96/ComfyUI-GGUF"))
    #expect(missing.first { $0.node == "SomeCustomNode" }?.hint.contains("ComfyUI Manager") == true)
    #expect(missing.count == 4)
}

/// A comfy-gen setup in a temp dir: an executable runner and its workflows folder with the z-image workflow.
private func fakeComfy(workflow: JSONValue? = zimage) throws -> EngineConfig {
    let dir = tempDir()
    let gen = dir.appendingPathComponent("comfy_gen.py")
    try Data("#!/bin/sh\n".utf8).write(to: gen)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gen.path)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("workflows"), withIntermediateDirectories: true)
    if let workflow { try workflow.data().write(to: dir.appendingPathComponent("workflows/zimage-turbo.json")) }
    var c = EngineConfig()
    c.comfyGen = gen.path
    c.comfyRun = dir.appendingPathComponent("no-runner/comfy_run.py").path
    return c
}

@Test func comfyCheckStatesWithTheServerOffOrOnAndWithoutASetup() throws {
    let config = try fakeComfy()
    let info = try objectInfo.data()
    // Server on: z-image ready; music has no runner here → missing with the setup steps.
    let on = ComfyCheck.run(config: config, objectInfo: info)
    #expect(on.map(\.model) == ComfyCheck.models)
    #expect(on.first { $0.model == "z-image-turbo" }?.state == "ready")
    let wan = try #require(on.first { $0.model == "wan2.2-i2v-14b-lightning" })
    #expect(wan.state == "missing" && wan.missing.first?.kind == "file" && wan.missing.first?.hint.contains("workflow") == true)
    let music = try #require(on.first { $0.model == "ace-step-1.5-turbo" })
    #expect(music.state == "missing" && music.summary.contains("comfy_run.py not found") && music.summary.contains("1. "))
    // Server off: never started, the files checked, the rest "not checked".
    let off = try #require(ComfyCheck.run(model: "z-image-turbo", config: config, objectInfo: nil).first)
    #expect(off.state == "notChecked" && off.reason?.contains("ComfyUI is off") == true)
    #expect(ComfyCheck.lastResult("z-image-turbo") == off, "generate.providers shows the last result")
    // No setup at all: the guided steps of the manifest, no developer path.
    var none = EngineConfig()
    none.comfyGen = tempDir().appendingPathComponent("comfy-gen").path
    let missing = try #require(ComfyCheck.run(model: "z-image-turbo", config: none, objectInfo: info).first)
    #expect(missing.state == "missing" && missing.summary.contains("ComfyUI is not set up on this Mac"))
    #expect(ComfyCheck.setupSteps.hasPrefix("1. ") && ComfyCheck.setupSteps.contains("generate.check"))
}

@Test func generateRunFailsFastOnAMissingComfyFileAndNotWhenTheServerIsOff() throws {
    var broken = zimage.objectValue!
    broken["3"] = ["class_type": "VAELoader", "inputs": ["vae_name": "gone.safetensors"]]
    let config = try fakeComfy(workflow: .object(broken))
    let info = try objectInfo.data()
    #expect(throws: CommandError.self) { try ComfyCheck.gate(model: "z-image-turbo", config: config, command: "generate.run", fetch: { info }) }
    do { try ComfyCheck.gate(model: "z-image-turbo", config: config, command: "generate.run", fetch: { info }) } catch {
        #expect("\(error)".contains("gone.safetensors") && "\(error)".contains("models/vae") && "\(error)".contains("Nothing was queued"))
    }
    try ComfyCheck.gate(model: "z-image-turbo", config: config, command: "generate.run", fetch: { nil })   // off: comfy-gen starts it
    try ComfyCheck.gate(model: "z_image", config: config, command: "generate.run", fetch: { info })        // not a ComfyUI model
    // The command is registered and validates its model.
    #expect(Engine(prober: FakeProber(), services: FakeServices().make()).registry["generate.check"] != nil)
}

// MARK: aligners

@Test func alignersArePinnedAndItalianFrenchAreOptIn() throws {
    let m = EngineManifest.shared
    for lang in ["en", "pt"] {
        let e = try #require(m.entry("aligner-\(lang)"))
        #expect(e.install.method == "installer" && !e.optional && !m.artifacts(of: e).isEmpty, "\(lang) is pinned and installed with WhisperX")
        #expect(m.artifacts(of: e).allSatisfy { $0.sha256.count == 64 && $0.url.hasPrefix("https://") })
        #expect(!e.nonCommercial)
    }
    for lang in ["it", "fr"] {
        let e = try #require(m.entry("aligner-\(lang)"))
        #expect(e.nonCommercial && e.optional && e.licenceUrl?.hasPrefix("https://creativecommons.org/licenses/by-nc/") == true)
        #expect(!m.installerEntries(.pro).contains(e), "never installed without asking")
    }
    // The PT revision is pinned (not the main branch) and every file of the folder wx_align.py loads is in the lock.
    let pt = m.artifacts(of: m.entry("aligner-pt")!)
    #expect(Set(pt.map { String($0.id.dropFirst("ptalign:".count)) }) == ["pytorch_model.bin", "config.json", "preprocessor_config.json", "vocab.json", "special_tokens_map.json"])
    #expect(pt.allSatisfy { $0.version.hasPrefix("hf@") && $0.version.count == 43 && $0.url.contains($0.version.dropFirst(3)) })

    // What WhisperX can align here: the file of the language, or a reason that names the licence when it is opt-in.
    var c = EngineConfig()
    let project = tempDir()
    c.whisperXProject = project.path
    let wx = WhisperXTranscriber(config: c)
    let it = try #require(wx.alignerReason("it"))
    #expect(it.contains("non-commercial") && it.contains("CC-BY-NC-4.0") && it.contains("aligner-it"))
    #expect(wx.alignerReason("en")?.contains("non-commercial") == false)
    #expect(wx.alignerReason("de")?.contains("no pinned aligner") == true)
    for (lang, rel) in WhisperXTranscriber.aligners {
        let f = project.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: f)
        #expect(wx.alignerReason(lang) == nil)
    }
    // The paths agree with the manifest's files (what Motori removes) and with wx_align.py.
    let script = try String(contentsOf: repo.appendingPathComponent("engines/whisperx/wx_align.py"), encoding: .utf8)
    for (lang, rel) in WhisperXTranscriber.aligners {
        let files = m.entry("aligner-\(lang)")!.files
        #expect(files.contains { "whisperx/" + rel == $0 || ("whisperx/" + rel).hasPrefix($0 + "/") }, "\(lang): \(rel) not in \(files)")
        #expect(script.contains((rel as NSString).lastPathComponent) || script.contains(((rel as NSString).deletingLastPathComponent as NSString).lastPathComponent))
    }
    #expect(script.contains("HF_HUB_OFFLINE"), "nothing from the Hub at run time")
}

// MARK: Node + HyperFrames

@Test func nodeAndHyperframesArePinnedWithALockfile() throws {
    let m = EngineManifest.shared
    let node = try #require(m.artifact("node"))
    #expect(node.url == "https://nodejs.org/dist/v\(node.version)/node-v\(node.version)-darwin-arm64.tar.gz" && node.sha256.count == 64)
    let env = try #require(m.artifact("hyperframes-env"))
    #expect(EngineConfig.hyperframesVersion == env.version)
    let lockURL = repo.appendingPathComponent("engines/hyperframes/package-lock.json")
    #expect(try FileDigest.sha256(lockURL) == env.sha256, "package-lock.json is the pinned one")
    let lock = try JSONValue.parse(Data(contentsOf: lockURL))
    let packages = try #require(lock["packages"]?.objectValue)
    #expect(packages["node_modules/hyperframes"]?["version"]?.stringValue == env.version)
    for (path, p) in packages where !path.isEmpty {
        #expect(p["integrity"]?.stringValue?.hasPrefix("sha512-") == true, "\(path) has no sha512 integrity")
        #expect(p["resolved"]?.stringValue?.hasPrefix("https://registry.npmjs.org/") == true, "\(path) not from the npm registry")
    }
    let pkg = try JSONValue.parse(Data(contentsOf: repo.appendingPathComponent("engines/hyperframes/package.json")))
    #expect(pkg.value(at: "dependencies.hyperframes")?.stringValue == env.version, "an exact version, no range")
    let npmrc = try String(contentsOf: repo.appendingPathComponent("engines/hyperframes/.npmrc"), encoding: .utf8)
    #expect(npmrc.contains("ignore-scripts=true"))
    for id in ["node", "hyperframes"] {
        let e = try #require(m.entry(id))
        #expect(e.install.method == "installer" && !e.optional && m.tier(of: e) == .medium, "\(id): installed on Medium")
    }

    // The runner: the installed copy first, npx only as a fallback.
    var c = EngineConfig()
    let dir = tempDir()
    c.node = dir.appendingPathComponent("bin/node").path
    c.hyperframes = dir.appendingPathComponent("hf/hyperframes.mjs").path
    c.npx = dir.appendingPathComponent("nonexistent-npx").path
    #expect(GraphicsEngines.hyperframes(c) == nil)
    for (path, mode) in [(c.node, 0o755), (c.hyperframes, 0o644)] {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
    let r = try #require(GraphicsEngines.hyperframes(c))
    #expect(r.source == "installed" && r.executable.path == c.node && r.prefix == [c.hyperframes])
}

// MARK: disk and messages

@Test func theDiskCheckAsksForEachTiersNeedFromTheManifest() throws {
    let m = EngineManifest.shared
    #expect(m.installerNeedGB(.medium) >= 15, "Medium installs about 13 GB of engines + the margin")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    p.arguments = ["-I", repo.appendingPathComponent("scripts/engines.py").path, "need-gb", "medium", "--detail"]
    let out = Pipe(); p.standardOutput = out
    try p.run(); p.waitUntilExit()
    let cols = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: " ")
    #expect(cols.count == 3 && Int(cols[0]) == m.installerNeedGB(.medium) && Double(cols[2].trimmingCharacters(in: .whitespacesAndNewlines)) == m.diskMarginGB)
}

/// The keys of scripts/i18n.sh per language.
private func messageKeys() throws -> [String: Set<String>] {
    let text = try String(contentsOf: repo.appendingPathComponent("scripts/i18n.sh"), encoding: .utf8)
    let entry = try NSRegularExpression(pattern: #"^\s+(it|en|fr|pt)\.([a-z0-9_]+)\)"#, options: .anchorsMatchLines)
    var keys: [String: Set<String>] = [:]
    for m in entry.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        keys[String(text[Range(m.range(at: 1), in: text)!]), default: []].insert(String(text[Range(m.range(at: 2), in: text)!]))
    }
    return keys
}

@Test func installerAndDoctorMessagesExistInFourLanguages() throws {
    let keys = try messageKeys()
    let en = try #require(keys["en"])
    #expect(en.count > 40)
    for lang in ["it", "fr", "pt"] {
        #expect(keys[lang] == en, "\(lang): missing \(en.subtracting(keys[lang] ?? [])), extra \((keys[lang] ?? []).subtracting(en))")
    }
    // Every `t <key>` the scripts use has an English entry.
    let use = try NSRegularExpression(pattern: #"\$\(t ([a-z0-9_]+)"#)
    for script in ["install.sh", "doctor.sh"] {
        let text = try String(contentsOf: repo.appendingPathComponent("scripts/\(script)"), encoding: .utf8)
        let used = Set(use.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { String(text[Range($0.range(at: 1), in: text)!]) })
        #expect(used.count > 5, "\(script) uses t")
        #expect(used.subtracting(en).isEmpty, "\(script) uses undefined messages \(used.subtracting(en))")
    }
    // The language follows REGISTA_LANG (then macOS), English for anything else.
    for (lang, expected) in [("it", "Regista è installato"), ("fr", "Regista est installé"), ("pt", "O Regista está instalado"), ("de", "Regista is installed")] {
        let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", ". \"$0/scripts/lib.sh\"; t done_title", repo.path],
                                   environment: ["REGISTA_LANG": lang])
        #expect(r.stdoutText == expected, "\(lang): \(r.stdoutText) \(r.stderrText)")
    }
}

// MARK: the opt-in install

@Test func theNonCommercialAlignerShowsItsLicenceWhenInstalled() throws {
    // scripts/install.sh --only aligner-it, as the Motori screen runs it after its licence dialog: the licence is printed,
    // the pinned file is installed and checked. The download is a local file standing in for the real one.
    let dir = tempDir()
    let payload = dir.appendingPathComponent("aligner.pt")
    try Data((0..<50_000).map { UInt8(truncatingIfNeeded: $0 &* 7) }).write(to: payload)
    let sha = try FileDigest.sha256(payload)
    let lock = String(decoding: PackageResources.engines_lock, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map { line in
        line.hasPrefix("wav2vec2-voxpopuli-it | ")
            ? "wav2vec2-voxpopuli-it | VOXPOPULI_ASR_BASE_10K_IT | 2021-10-27 | 2026-11-01 | \(sha) | 50000 | file://\(payload.path)" : String(line)
    }.joined(separator: "\n")
    try lock.write(to: dir.appendingPathComponent("engines.lock"), atomically: true, encoding: .utf8)
    let support = dir.appendingPathComponent("support")
    let env = ["REGISTA_LOCK": dir.appendingPathComponent("engines.lock").path, "REGISTA_SUPPORT_DIR": support.path,
               "REGISTA_CACHE_DIR": dir.appendingPathComponent("cache").path, "REGISTA_ENGINES": support.appendingPathComponent("engines.json").path,
               "REGISTA_LANG": "en"]
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), [repo.appendingPathComponent("scripts/install.sh").path, "--only", "aligner-it", "--tier", "medium"],
                               environment: env)
    let out = r.stdoutText + r.stderrText
    #expect(r.status == 0, "\(out)")
    #expect(out.contains("NON-COMMERCIAL") && out.contains("CC-BY-NC-4.0") && out.contains("creativecommons.org/licenses/by-nc/4.0"))
    let file = support.appendingPathComponent("engines/" + EngineManifest.shared.entry("aligner-it")!.files[0])
    #expect(try FileDigest.sha256(file) == sha)
    // --check says what it would do and that the licence comes first.
    let check = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), [repo.appendingPathComponent("scripts/install.sh").path, "--only", "aligner-fr", "--check", "--tier", "medium"],
                                   environment: env)
    #expect(check.status == 0 && check.stdoutText.contains("non-commercial: licence shown first"))
}
