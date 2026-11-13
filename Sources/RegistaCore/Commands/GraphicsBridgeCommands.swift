import CryptoKit
import Foundation

// External graphics engines (issue #5, X2): separate processes like the analysis engines. Each renders an RGBA
// PNG sequence into a cache keyed by its parameters, then the sequence goes on an overlay track (overlay.add).

enum GraphicsEngines {
    /// The manifest tier of an engine id ("blender", "hyperframes").
    static func minimumTier(_ id: String) -> MachineTier { EngineManifest.shared.minimumTier(id) }

    static func blender(_ config: EngineConfig) -> URL { config.url(config.blender) }

    /// npx: the config, then PATH, fnm's default alias and newest installed node, Homebrew.
    static func npx(_ config: EngineConfig) -> URL? {
        let fm = FileManager.default
        if let c = config.npx { return fm.isExecutableFile(atPath: EngineConfig.expand(c)) ? config.url(c) : nil }
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/npx" }
        let fnm = fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/fnm")
        candidates.append(fnm.appendingPathComponent("aliases/default/bin/npx").path)
        let versions = ((try? fm.contentsOfDirectory(atPath: fnm.appendingPathComponent("node-versions").path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        candidates += versions.map { fnm.appendingPathComponent("node-versions/\($0)/installation/bin/npx").path }
        candidates += ["/opt/homebrew/bin/npx", "/usr/local/bin/npx"]
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// How graphics.hyperframes runs the pinned CLI: the installer's own Node + `npm ci` copy (engines folder), else
    /// `npx --yes hyperframes@<pinned>` with a Node found on this Mac (setups from before the installer had Node).
    struct HyperframesRunner: Equatable {
        let executable: URL
        let prefix: [String]
        /// "installed" (engines folder, from the lockfile) or "npx".
        let source: String
    }

    static func hyperframes(_ config: EngineConfig) -> HyperframesRunner? {
        let fm = FileManager.default
        let node = config.url(config.node), cli = config.url(config.hyperframes)
        if fm.isExecutableFile(atPath: node.path), fm.fileExists(atPath: cli.path) {
            return HyperframesRunner(executable: node, prefix: [cli.path], source: "installed")
        }
        return npx(config).map { HyperframesRunner(executable: $0, prefix: ["--yes", "hyperframes@\(EngineConfig.hyperframesVersion)"], source: "npx") }
    }

    static func unavailable(_ ctx: CommandContext, engine: String, id: String, path: URL?) -> String? {
        let minimumTier = minimumTier(id)
        if ctx.services.tier < minimumTier { return "\(engine) needs the \(minimumTier.rawValue) tier (this Mac: \(ctx.services.tier.rawValue))" }
        guard let path, FileManager.default.isExecutableFile(atPath: path.path) else { return "\(engine) not found\(path.map { " at \($0.path)" } ?? "")" }
        return nil
    }

    static func cacheDir(_ ctx: CommandContext, _ kind: String, key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return ctx.services.config.url(ctx.services.config.cacheDirectory).appendingPathComponent("graphics/\(kind)-\(digest)")
    }

    /// Puts a rendered sequence on the timeline through overlay.add (same params for position/animation).
    static func place(_ frames: URL, _ p: CommandParams, extra: [String: JSONValue], _ ctx: inout CommandContext) throws -> JSONValue {
        var params: [String: JSONValue] = ["path": .string(frames.path), "start": .number(p.requiredTime("start").seconds)]
        for key in ["band", "position", "top", "scale", "opacity", "rotation", "animIn", "animOut", "inDuration", "outDuration", "fullFrame"] {
            if let v = p.values[key] { params[key] = v }
        }
        for (k, v) in extra where params[k] == nil { params[k] = v }
        let validated = try CommandParams(validating: .object(params), for: OverlayAdd.descriptor)
        return try OverlayAdd.run(validated, &ctx)
    }
}

enum GraphicsBlenderTitle: Command {
    static let id = "graphics.blenderTitle"
    static let summary = "Render a real 3D title with Blender (headless EEVEE, separate process, Medium tier+): one or two lines of extruded serif text on bevelled pills that spring in and drift in the light, as a transparent 1080×540 PNG sequence placed in the top band (top y 110 by default). Colours and font from the brand kit (line 1 paper on primary, line 2 ink on paper). ~1 s per frame the first time, cached afterwards. Use for the hook only (one per reel). Returns the overlay clip, render time and whether it came from the cache."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("line1", .string, "First line (e.g. AGGIORNATO)."),
        .optional("line2", .string, "Second line (e.g. = SICURO?); '=' is drawn in the accent colour."),
        .required("start", .time, "Timeline start."),
        .optional("duration", .time, "Seconds (default 4)."),
        .optional("samples", .integer, "EEVEE samples (default 64; 16 for drafts)."),
        .optional("engine", .oneOf(["EEVEE", "CYCLES"]), "Render engine (default EEVEE: as good here, 2.5× faster)."),
        .optional("font", .string, "Font file (default: the kit's display font)."),
        .optional("colors", .object, "{pill1, text1, pill2, text2, accent} hex overrides."),
    ] + Graphics.positionParams + Graphics.animationParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        let project = try ctx.requireProject()
        let blender = GraphicsEngines.blender(ctx.services.config)
        if let why = GraphicsEngines.unavailable(ctx, engine: "Blender", id: "blender", path: blender) { throw CommandError(.io, "\(id): \(why)") }
        let kit = project.brand ?? BrandKit.wesites
        guard let fontSpec = p.string("font") ?? kit.fonts["display"] else { throw CommandError.invalid("\(id): pass font") }
        let font = EngineConfig.expand(fontSpec)
        guard FileManager.default.fileExists(atPath: font) else { throw CommandError.notFound("\(id): font file \(font) not found") }
        let o = p.json("colors")?.objectValue ?? [:]
        func color(_ key: String, _ role: String) -> String { o[key]?.stringValue ?? kit.color(role) }
        let colors = [("pill1", color("pill1", "primary")), ("text1", color("text1", "paper")), ("pill2", color("pill2", "paper")),
                      ("text2", color("text2", "ink")), ("accent", color("accent", "primary"))]
        let fps = Int(project.settings.frameRate.doubleValue.rounded())
        let seconds = (p.time("duration") ?? MediaTime(seconds: 4)).seconds
        let engine = p.string("engine") ?? "EEVEE"
        let samples = p.int("samples") ?? 64
        var args = ["--line1", p.requiredString("line1"), "--line2", p.string("line2") ?? "", "--font", font, "--engine", engine,
                    "--seconds", String(format: "%.4f", seconds), "--samples", String(samples), "--fps", String(fps)]
        for (k, v) in colors { args += ["--\(k)", v] }
        let dir = GraphicsEngines.cacheDir(ctx, "blender", key: "v\(BlenderTitleScript.version)|" + args.joined(separator: "|"))
        let frames = dir.appendingPathComponent("frames")
        let marker = dir.appendingPathComponent("done.json")
        var renderSeconds = 0.0
        let cached = FileManager.default.fileExists(atPath: marker.path)
        if !cached {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
            let script = dir.appendingPathComponent("title3d.py")
            try BlenderTitleScript.source.write(to: script, atomically: true, encoding: .utf8)
            let started = Date()
            let r = try Subprocess.run(blender, ["-b", "--factory-startup", "-P", script.path, "--", frames.path] + args)
            renderSeconds = Date().timeIntervalSince(started)
            guard r.status == 0, r.stdoutText.contains("RESULT ") else {
                let tail = (r.stdoutText + r.stderrText).split(separator: "\n").suffix(12).joined(separator: "\n")
                throw CommandError(.io, "\(id): Blender failed (exit \(r.status)):\n\(tail)")
            }
            try JSONValue.object(["seconds": .number(renderSeconds), "args": .array(args.map { .string($0) })]).data().write(to: marker)
        }
        var extra: [String: JSONValue] = ["duration": .number(seconds)]
        if !p.has("band") && !p.has("position") && !p.has("top") { extra["top"] = .number(SafeZones.top.0) }
        if !p.has("animOut") && !p.has("animIn") { extra["animOut"] = "fade" }
        let placed = try GraphicsEngines.place(frames, p, extra: extra, &ctx)
        guard case .object(var result) = placed else { return placed }
        result["cached"] = .bool(cached)
        result["renderSeconds"] = .number((renderSeconds * 10).rounded() / 10)
        result["frames"] = .string(frames.path)
        return .object(result)
    }
}

enum GraphicsHyperframes: Command {
    static let id = "graphics.hyperframes"
    static let summary = "Render a HyperFrames composition (HTML/GSAP cards, kinetic type, UI mock-ups) to a transparent PNG sequence with the pinned CLI (hyperframes \(EngineConfig.hyperframesVersion) installed from a lockfile in the engines folder, npm scripts disabled; separate process, Medium tier+) and place it as an overlay: native size in a band, or fullFrame. The composition must have a transparent background. Cached by project content. Returns the overlay clip and render time."
    static let kind = CommandKind.edit
    static let params: [ParamSpec] = [
        .required("project", .string, "HyperFrames project folder (with index.html)."),
        .optional("composition", .string, "Composition file inside it (default index.html)."),
        .required("start", .time, "Timeline start."),
        .optional("duration", .time, "Seconds to use (default: the whole render)."),
        .optional("variables", .object, "Composition variables (--variables)."),
        .optional("fullFrame", .boolean, "Fill the frame (a 1080×1920 composition) instead of native size."),
    ] + Graphics.positionParams + Graphics.animationParams

    static func run(_ p: CommandParams, _ ctx: inout CommandContext) throws -> JSONValue {
        _ = try ctx.requireProject()
        let runner = GraphicsEngines.hyperframes(ctx.services.config)
        if let why = GraphicsEngines.unavailable(ctx, engine: "HyperFrames (Node.js)", id: "hyperframes", path: runner?.executable) {
            throw CommandError(.io, "\(id): \(why) — install it in Settings › Motori (HyperFrames) or with scripts/install.sh --only hyperframes")
        }
        let projectDir = URL(fileURLWithPath: EngineConfig.expand(p.requiredString("project"))).standardizedFileURL
        let composition = p.string("composition")
        let entry = projectDir.appendingPathComponent(composition ?? "index.html")
        guard FileManager.default.fileExists(atPath: entry.path) else { throw CommandError.notFound("\(id): no \(entry.path)") }
        // Cache key: the CLI version, the params and the content of the project's text files.
        var key = "hf\(EngineConfig.hyperframesVersion)|\(projectDir.path)|\(composition ?? "")|\(p.json("variables").map { String(decoding: $0.data(), as: UTF8.self) } ?? "")"
        let walker = FileManager.default.enumerator(at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
        while let f = walker?.nextObject() as? URL {
            if f.path.contains("/node_modules/") || f.path.contains("/renders/") || f.lastPathComponent.hasPrefix(".") { continue }
            let v = try? f.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            key += "|\(f.path.dropFirst(projectDir.path.count)):\(v?.fileSize ?? 0):\(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }
        let dir = GraphicsEngines.cacheDir(ctx, "hyperframes", key: key)
        let frames = dir.appendingPathComponent("frames")
        let marker = dir.appendingPathComponent("done.json")
        var renderSeconds = 0.0
        let cached = FileManager.default.fileExists(atPath: marker.path)
        if !cached {
            try? FileManager.default.removeItem(at: dir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var args = runner!.prefix + ["render", projectDir.path, "--format", "png-sequence",
                        "--output", frames.path, "--fps", String(Int(ctx.project!.settings.frameRate.doubleValue.rounded())), "--quiet"]
            if let c = composition { args += ["--composition", c] }
            if let v = p.json("variables") { args += ["--variables", String(decoding: v.data(), as: UTF8.self)] }
            let path = runner!.executable.deletingLastPathComponent().path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            let started = Date()
            let r = try Subprocess.run(runner!.executable, args, environment: ["npm_config_ignore_scripts": "true", "PATH": path], currentDirectory: dir)
            renderSeconds = Date().timeIntervalSince(started)
            let pngs = ((try? FileManager.default.contentsOfDirectory(atPath: frames.path)) ?? []).filter { $0.hasSuffix(".png") }
            guard r.status == 0, !pngs.isEmpty else {
                let tail = (r.stdoutText + r.stderrText).split(separator: "\n").suffix(12).joined(separator: "\n")
                throw CommandError(.io, "\(id): hyperframes render failed (exit \(r.status)):\n\(tail)")
            }
            try JSONValue.object(["seconds": .number(renderSeconds), "frames": .number(Double(pngs.count))]).data().write(to: marker)
        }
        var extra: [String: JSONValue] = [:]
        if let d = p.time("duration") { extra["duration"] = .number(d.seconds) }
        if !p.has("band") && !p.has("position") && !p.has("top") && p.bool("fullFrame") != true { extra["band"] = "top" }
        let placed = try GraphicsEngines.place(frames, p, extra: extra, &ctx)
        guard case .object(var result) = placed else { return placed }
        result["cached"] = .bool(cached)
        result["renderSeconds"] = .number((renderSeconds * 10).rounded() / 10)
        result["frames"] = .string(frames.path)
        return .object(result)
    }
}
