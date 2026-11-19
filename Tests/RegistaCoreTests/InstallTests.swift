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
    #expect(missing.first { $0.node == "SomeCustomNode" }?.hint.contains("install the node pack") == true)
    #expect(missing.count == 4)
}

/// The full node list a ComfyUI with every pack and model file of Regista's four workflows would give.
private func completeObjectInfo() -> JSONValue {
    var info: [String: JSONValue] = [:]
    for w in ComfyCheck.workflows {
        for (_, n) in w.graph.objectValue ?? [:] {
            guard let cls = n["class_type"]?.stringValue else { continue }
            var required = info[cls]?.value(at: "input.required")?.objectValue ?? [:]
            for (name, v) in n["inputs"]?.objectValue ?? [:] {
                guard let text = v.stringValue else { continue }
                let had = required[name]?.arrayValue?.first?.arrayValue ?? []
                required[name] = [.array(had + [.string(text)])]
            }
            info[cls] = ["input": ["required": .object(required)]]
        }
    }
    return .object(info)
}

@Test func comfyCheckReadsTheShippedWorkflowsWithTheServerOnOrOff() throws {
    let info = completeObjectInfo().data()
    let found = ComfyServer.Location(server: URL(string: "http://127.0.0.1:9")!, start: .executable(URL(fileURLWithPath: "/usr/bin/true")), configured: true, startProblem: nil)
    // Server on, every node and file there: the four shipped workflows are ready.
    let on = ComfyCheck.run(location: found, objectInfo: info)
    #expect(on.map(\.model) == ComfyCheck.models)
    #expect(on.allSatisfy { $0.state == "ready" }, "\(on.map(\.summary))")
    // Server off: never started, the rest "not checked", and where Regista would start it from.
    let off = try #require(ComfyCheck.run(model: "z-image-turbo", location: found, objectInfo: nil).first)
    #expect(off.state == "notChecked" && off.reason?.contains("ComfyUI is off") == true && off.reason?.contains("/usr/bin/true") == true)
    #expect(ComfyCheck.lastResult("z-image-turbo") == off, "generate.providers shows the last result")
    // Off and nowhere to start from: the guided steps of the manifest.
    var none = found
    none.start = nil
    none.configured = false
    let missing = try #require(ComfyCheck.run(model: "ace-step-1.5-turbo", location: none, objectInfo: nil).first)
    #expect(missing.state == "missing" && missing.summary.contains("does not know where it is") && missing.summary.contains("1. "))
    #expect(ComfyCheck.setupSteps.hasPrefix("1. ") && ComfyCheck.setupSteps.contains("generate.check"))
}

@Test func generateRunFailsFastOnAMissingComfyFileAndNotWhenTheServerIsOff() throws {
    var info = completeObjectInfo().objectValue!
    info["VAELoader"] = ["input": ["required": ["vae_name": [["other.safetensors"]]]]]
    let data = JSONValue.object(info).data()
    let location = ComfyServer.Location(server: URL(string: "http://127.0.0.1:9")!, start: nil, configured: false, startProblem: nil)
    do {
        try ComfyCheck.gate(model: "z-image-turbo", location: location, command: "generate.run", fetch: { data })
        Issue.record("a missing model file did not stop the run")
    } catch {
        #expect("\(error)".contains("ae.safetensors") && "\(error)".contains("models/vae") && "\(error)".contains("Nothing was queued"))
    }
    try ComfyCheck.gate(model: "z-image-turbo", location: location, command: "generate.run", fetch: { nil })   // off: Regista starts it
    try ComfyCheck.gate(model: "z_image", location: location, command: "generate.run", fetch: { data })        // not a ComfyUI model
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

/// #26: the doctor's repoint hint names the app's own button, exactly as each language's table spells it (and the path
/// to it: Settings › Claude), so the two cannot drift again.
@Test func theRepointHintQuotesTheAppsButton() throws {
    func value(_ key: String, _ lang: String) throws -> String {
        let table = try String(contentsOf: repo.appendingPathComponent("Resources/Localization/\(lang).lproj/Localizable.strings"), encoding: .utf8)
        let prefix = "\"\(key)\" = \""
        let line = try #require(table.split(separator: "\n").first { $0.hasPrefix(prefix) }, "\(lang): no \(key)")
        return String(line.dropFirst(prefix.count).dropLast(2))   // the value, without its closing quote and semicolon
    }
    for lang in ["it", "en", "fr", "pt"] {
        let path = "Regista › \(try value("Impostazioni", lang)) › Claude › \(try value("Ricollega a questa app…", lang))"
        let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", ". \"$0/scripts/lib.sh\"; t fix_repoint desktop", repo.path],
                                   environment: ["REGISTA_LANG": lang])
        #expect(r.stdoutText.contains(path), "\(lang): \(r.stdoutText) does not quote \(path)")
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

/// #12: the copy of the installer inside the app (Regista.app/Contents/Resources/Installer, what Impostazioni › Motori runs)
/// checks the sound bank of that app, Contents/Resources/SFX. A fake app layout in a temporary folder, laid out as
/// scripts/build-app.sh lays it out; neither /Applications nor the engines folder is touched.
@Test func theInstallerInsideTheAppFindsTheAppsSoundBank() throws {
    let dir = tempDir()
    let resources = dir.appendingPathComponent("Regista.app/Contents/Resources")
    let scripts = resources.appendingPathComponent("Installer/scripts")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    for f in ["install.sh", "lib.sh", "i18n.sh", "engines.py", "engines.lock", "engines.manifest.json"] {
        try FileManager.default.copyItem(at: repo.appendingPathComponent("scripts/\(f)"), to: scripts.appendingPathComponent(f))
    }
    try FileManager.default.copyItem(at: repo.appendingPathComponent("Resources/SFX"), to: resources.appendingPathComponent("SFX"))
    let support = dir.appendingPathComponent("support")
    let env = ["REGISTA_SUPPORT_DIR": support.path, "REGISTA_CACHE_DIR": dir.appendingPathComponent("cache").path,
               "REGISTA_ENGINES": support.appendingPathComponent("engines.json").path, "REGISTA_APP_DIR": dir.appendingPathComponent("apps").path,
               "REGISTA_LANG": "en"]
    let install = scripts.appendingPathComponent("install.sh").path
    let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), [install, "--only", "sfx-bank"], environment: env)
    let out = r.stdoutText + r.stderrText
    #expect(r.status == 0, "\(out)")
    #expect(out.contains("\(SoundLibrary.bank().count) sounds"), "\(out)")
    // A bank that is not the pinned one still fails there.
    try Data("{}".utf8).write(to: resources.appendingPathComponent("SFX/manifest.json"))
    let bad = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), [install, "--only", "sfx-bank"], environment: env)
    #expect(bad.status != 0 && (bad.stdoutText + bad.stderrText).contains("differs from its pin"))
}

// MARK: the installer's ComfyUI line (#124)

/// The installer's ComfyUI line in the four configurations Regista itself tells apart: a server that answers, only the
/// start setting, a ComfyUI folder in a usual place, and none of them. A scratch home each time (never the person's
/// usual places), «not installed» in the language of the run, and the usual places read from the one list Regista reads.
@Test(arguments: ["it", "en"])
func theInstallersComfyUILineSaysWhatRegistaWouldUse(_ lang: String) throws {
    #expect(ComfyServer.usualPlaces == EngineManifest.shared.comfyPlaces && ComfyServer.usualPlaces.count == 8)
    #expect(ComfyServer.usualPlaces.first == "~/ComfyUI" && ComfyServer.usualPlaces.contains("~/Documents/ComfyUI"))
    func line(home: URL, config: String) throws -> String {
        let file = home.appendingPathComponent("engines.json")
        try config.write(to: file, atomically: true, encoding: .utf8)
        let r = try Subprocess.run(URL(fileURLWithPath: "/bin/bash"), ["-c", ". \"$0/scripts/lib.sh\"; comfy_line; echo \"COMFY=$COMFY\"", repo.path],
                                   environment: ["HOME": home.path, "REGISTA_ENGINES": file.path, "REGISTA_LANG": lang, "REGISTA_HELPER": ""])
        #expect(r.status == 0, "\(r.stderrText)")
        return r.stdoutText
    }
    let notInstalled = lang == "it" ? "ComfyUI: non installato — livello Pro" : "ComfyUI: not installed — Pro tier"
    // A stand-in server answering at the address engines.json sets.
    let fake = try FakeComfy()
    let served = try line(home: tempDir(), config: #"{"comfyServer": "\#(fake.base.absoluteString)"}"#)
    #expect(served.contains("✓ ComfyUI — \(fake.base.absoluteString)") && served.contains("COMFY=\(fake.base.absoluteString)"), "\(served)")
    #expect(!fake.requests("/system_stats").isEmpty)
    // Only the start setting (nothing answers at the address).
    let started = try line(home: tempDir(), config: #"{"comfyServer": "http://127.0.0.1:9", "comfyStart": "/opt/comfy/start.sh"}"#)
    #expect(started.contains("✓ ComfyUI — /opt/comfy/start.sh") && started.contains("COMFY=/opt/comfy/start.sh"), "\(started)")
    // Neither: «not installed» in the run's language, nothing reachable.
    let neither = try line(home: tempDir(), config: #"{"comfyServer": "http://127.0.0.1:9"}"#)
    #expect(neither.contains(notInstalled) && neither.contains("COMFY=\n") && !neither.contains("not installed —") == (lang == "it"), "\(neither)")
    // A ComfyUI folder with its own Python environment in a usual place (the third one): found there, as Regista finds it.
    let home = tempDir()
    let folder = home.appendingPathComponent("Documents/ComfyUI")
    try FileManager.default.createDirectory(at: folder.appendingPathComponent("comfy"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: folder.appendingPathComponent(".venv/bin"), withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent("main.py"))
    try "#!/bin/sh\n".write(to: folder.appendingPathComponent(".venv/bin/python"), atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.appendingPathComponent(".venv/bin/python").path)
    let real = ComfyServer.canonical(folder).path
    let found = try line(home: home, config: #"{"comfyServer": "http://127.0.0.1:9"}"#)
    let words = lang == "it" ? "trovata in un posto consueto" : "found in a usual place"
    #expect(found.contains("✓ ComfyUI — \(real) (\(words)") && found.contains("COMFY=\(real)\n"), "\(found)")
    // Regista finds the same folder from the same list (spelled from the scratch home).
    let places = ComfyServer.usualPlaces.map { $0.hasPrefix("~/") ? home.path + $0.dropFirst() : $0 }
    #expect(ComfyServer.find(in: places)?.path == real)
}
