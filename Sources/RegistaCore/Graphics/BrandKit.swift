import Foundation

/// A brand's look as data: colours and fonts by role, logos, caption style, title presets, logo placement.
/// Title presets and caption colours may name colours and fonts by role ("paper", "display"); `resolve` swaps in
/// the values. Built in: `arkad`, `wesites`, `cafe-atelier`. A kit folder in
/// `~/Library/Application Support/Regista/brandkits/<id>/` (`kit.json` + `assets/`) replaces a built-in or adds
/// a kit; asset paths in it are relative to that folder (see `BrandKitStore`).
///
/// Colour roles: primary, accent, ink, paper, surface, success, highlight (the colour that marks the key word:
/// caption keyword box, highlighted title words) and onHighlight (text on it). Font roles: display, text,
/// textBold, mono. A font file that is missing falls back to a system font of the same role (`fontReport`).
public struct BrandKit: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Role → hex (#RRGGBB).
    public var colors: [String: String]
    /// Role → font file (.ttf/.otf/.woff2: relative to the kit folder, absolute, `~/…` or `bundle:Fonts/…`) or font name.
    public var fonts: [String: String]
    /// The default logo (older kits); `logos` has the variants.
    public var logo: String?
    /// Logo variants: onDark (light-coloured, for footage), onLight (dark-coloured, for pale backgrounds), mark (symbol only).
    /// SVG (rasterised at the size drawn) or PNG.
    public var logos: [String: String]?
    /// Caption preset the kit starts from, then style fields to override (as captions.setStyle `overrides`;
    /// colour fields may name roles). keywordBoxColor defaults to `highlight`, keywordTextColor to `onHighlight`.
    public var captionPreset: String?
    public var captionStyle: [String: JSONValue]?
    /// Title presets (title.add `preset`).
    public var titles: [String: Title]
    /// Where and how logo.add puts the logo.
    public var logoPlacement: LogoPlacement?
    /// brandkit.apply also lays the logo over the whole video.
    public var watermark: Bool?
    /// One line on how the brand moves and what to avoid (shown by brandkit.list).
    public var notes: String?
    /// Folder of a stored kit (relative asset paths resolve against it); not encoded.
    public var directory: URL?
    /// A project's copy only (#101): the kit's file each of the copy's own files was copied from (copy path → kit path),
    /// so the copy is compared with the kit by what a person sees, not by where the files are.
    public var originals: [String: String]?

    enum CodingKeys: String, CodingKey {
        case id, name, colors, fonts, logo, logos, captionPreset, captionStyle, titles, logoPlacement, watermark, notes, originals
    }

    public init(id: String, name: String, colors: [String: String], fonts: [String: String], logo: String? = nil,
                logos: [String: String]? = nil, captionPreset: String? = nil, captionStyle: [String: JSONValue]? = nil,
                titles: [String: Title], logoPlacement: LogoPlacement? = nil, watermark: Bool? = nil, notes: String? = nil) {
        self.id = id
        self.name = name
        self.colors = colors
        self.fonts = fonts
        self.logo = logo
        self.logos = logos
        self.captionPreset = captionPreset
        self.captionStyle = captionStyle
        self.titles = titles
        self.logoPlacement = logoPlacement
        self.watermark = watermark
        self.notes = notes
    }

    public static let colorRoles = ["primary", "accent", "ink", "paper", "surface", "success", "highlight", "onHighlight"]
    public static let fontRoles = ["display", "text", "textBold", "mono"]
    public static let logoVariants = ["onDark", "onLight", "mark"]
    /// System fonts used when a role's file is missing.
    public static let fallbackFonts = ["display": "Georgia", "text": "HelveticaNeue", "textBold": "HelveticaNeue-Bold", "mono": "Menlo-Regular"]

    /// A colour role or a literal hex.
    public func color(_ c: String) -> String { colors[c] ?? c }

    /// A font role or a literal font, with files resolved against the kit folder; a missing file falls back to
    /// the role's system font.
    public func font(_ f: String) -> String {
        let spec = fonts[f] ?? f
        guard Self.isFontFile(spec) else { return spec }
        let path = assetPath(spec)
        if FileManager.default.fileExists(atPath: path) { return path }
        return Self.fallbackFonts[fonts[f] != nil ? f : "text"] ?? "HelveticaNeue"
    }

    static func isFontFile(_ spec: String) -> Bool {
        spec.contains("/") || [".ttf", ".otf", ".woff2", ".woff", ".ttc"].contains(where: spec.lowercased().hasSuffix)
    }

    /// Per font role: what the kit asks for, what is drawn, and whether that is a fallback.
    public func fontReport() -> [(role: String, spec: String, resolved: String, fallback: Bool)] {
        fonts.keys.sorted().map { role in
            let spec = fonts[role]!
            let resolved = font(role)
            return (role, spec, resolved, Self.isFontFile(spec) && resolved != assetPath(spec))
        }
    }

    /// A title with roles replaced by values.
    public func resolve(_ t: Title) -> Title {
        var r = t
        r.font = font(t.font)
        r.color = color(t.color)
        r.highlightColor = t.highlightColor.map(color)
        r.background?.color = color(t.background?.color ?? "")
        r.stroke?.color = color(t.stroke?.color ?? "")
        r.shadow?.color = color(t.shadow?.color ?? "")
        return r
    }

    // MARK: Checks

    /// A title, card or label whose text, box or highlight colour is none of the kit's colours (#97).
    public struct OffKitTitle: Hashable, Sendable {
        public let clipID: String
        public let start: MediaTime
        public let text: String
        /// The colours outside the kit (#RRGGBB, uppercase).
        public let colors: [String]
    }

    /// The titles of `project` (titles, cards, labels: every clip with a title) drawn in a colour that is not one of the
    /// kit's (any role), in timeline order.
    public func offKitTitles(in project: Project) -> [OffKitTitle] {
        func code(_ c: String) -> String {
            let v = color(c).uppercased()
            return v.hasPrefix("#") && v.count == 9 ? String(v.prefix(7)) : v   // an alpha byte is not another colour
        }
        let palette = Set(colors.values.map(code))
        var out: [OffKitTitle] = []
        for track in project.tracks {
            for clip in track.clips {
                guard let t = clip.title else { continue }
                var used = [t.color]
                if let b = t.background { used.append(b.color) }
                if let h = t.highlightColor, !(t.highlight ?? []).isEmpty { used.append(h) }
                var off: [String] = []
                for c in used.map(code) where !palette.contains(c) && !off.contains(c) { off.append(c) }
                if !off.isEmpty { out.append(OffKitTitle(clipID: clip.id, start: clip.start, text: t.text, colors: off)) }
            }
        }
        return out.sorted { $0.start != $1.start ? $0.start < $1.start : $0.clipID < $1.clipID }
    }

    // MARK: Assets

    /// An asset path as a file path: absolute, `~/…`, `bundle:<path under Resources>` (the app bundle or the
    /// repository), or relative to the kit folder.
    public func assetPath(_ p: String) -> String {
        if p.hasPrefix("bundle:") { return BrandKit.bundled(String(p.dropFirst(7))) }
        if p.hasPrefix("/") || p.hasPrefix("~") { return EngineConfig.expand(p) }
        if let directory { return directory.appendingPathComponent(p).path }
        return EngineConfig.expand(p)
    }

    /// The logo file of a variant (falling back to the other variants, then `logo`), as a path.
    public func logoPath(_ variant: String? = nil) -> String? {
        let order = [variant ?? logoPlacement?.variant ?? "onDark"] + Self.logoVariants
        for v in order { if let p = logos?[v] { return assetPath(p) } }
        return logo.map(assetPath)
    }

    /// The same kit with every asset path absolute (as stored in a project, which must not depend on the kit folder).
    public func absolutized() -> BrandKit {
        var k = self
        k.fonts = fonts.mapValues { Self.isFontFile($0) ? assetPath($0) : $0 }
        k.logo = logo.map(assetPath)
        k.logos = logos?.mapValues(assetPath)
        k.directory = nil
        return k
    }

    /// A project's copy with each of its own files named by the kit's file it was copied from (`originals`, #101): what
    /// the kit itself would say.
    public func withOriginalPaths() -> BrandKit {
        guard let originals, !originals.isEmpty else { return self }
        var k = self
        func back(_ p: String) -> String { originals[p] ?? p }
        k.fonts = fonts.mapValues(back)
        k.logo = logo.map(back)
        k.logos = logos?.mapValues(back)
        k.originals = nil
        return k
    }

    /// The files the kit refers to (font files, the logo and its variants), as paths.
    public var files: [String] {
        let fontFiles = fonts.keys.sorted().compactMap { fonts[$0].flatMap { Self.isFontFile($0) ? assetPath($0) : nil } }
        let logoFiles = (logo.map { [assetPath($0)] } ?? []) + (logos ?? [:]).keys.sorted().compactMap { logos?[$0].map(assetPath) }
        return fontFiles + logoFiles
    }

    /// The files the kit refers to that are not on disk (a deleted kit's folder took them, #101).
    public var missingFiles: [String] { files.filter { !FileManager.default.fileExists(atPath: $0) } }

    /// Resources shipped with Regista (`Resources/<path>`): in the app bundle (also for the regista-mcp it ships in
    /// Contents/MacOS, whose main bundle is the app), else in the source tree it was built from.
    public static func bundled(_ path: String) -> String {
        var roots: [URL] = []
        if let r = Bundle.main.resourceURL { roots.append(r) }
        // Sources/RegistaCore/Graphics/BrandKit.swift → repository root.
        roots.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"))
        for r in roots {
            let f = r.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: f.path) { return f.path }
        }
        return roots[min(1, roots.count - 1)].appendingPathComponent(path).path
    }

    // MARK: Captions

    /// Caption style overrides with roles resolved: the keyword box takes `highlight` and its text `onHighlight`
    /// (or ink/white by contrast) unless `captionStyle` says otherwise.
    public func captionOverrides() -> [String: JSONValue] {
        var o: [String: JSONValue] = [:]
        if let h = colors["highlight"] {
            o["keywordBoxColor"] = .string(h)
            o["keywordTextColor"] = .string(colors["onHighlight"] ?? Self.readable(on: h, ink: colors["ink"] ?? "#141414"))
        }
        for (k, v) in captionStyle ?? [:] {
            if k.hasSuffix("Color"), let s = v.stringValue { o[k] = .string(color(s)) } else { o[k] = v }
        }
        return o
    }

    /// The caption style `base` restyled by the kit: the kit's preset (if any) with its overrides; chunking fields
    /// keep `base`'s values so existing chunks stay valid.
    public func captionStyle(over base: CaptionStyle) throws -> CaptionStyle {
        var style = captionPreset.flatMap { CaptionStyle.presets[$0] } ?? base
        let o = captionOverrides()
        if !o.isEmpty {
            guard case .object(var current) = try JSONValue.from(style) else { return style }
            for (k, v) in o where current[k] != nil { current[k] = v }
            current["id"] = .string("\(style.id)+\(id)")
            style = try JSONDecoder().decode(CaptionStyle.self, from: JSONValue.object(current).data())
        }
        style.maxWords = base.maxWords; style.maxChars = base.maxChars; style.hold = base.hold
        style.stopWords = base.stopWords; style.uppercase = base.uppercase
        return style
    }

    /// The caption style `base` recoloured by the kit and nothing else (#17): the preset, fonts, sizes and chunking the
    /// user chose stay; only the colour fields the kit sets (keyword box, its text, any `…Color` override) change.
    public func captionColors(over base: CaptionStyle) throws -> CaptionStyle {
        let colors = captionOverrides().filter { $0.key.hasSuffix("Color") }
        guard !colors.isEmpty, case .object(var current) = try JSONValue.from(base) else { return base }
        for (k, v) in colors where current[k] != nil { current[k] = v }
        return try JSONDecoder().decode(CaptionStyle.self, from: JSONValue.object(current).data())
    }

    /// #RRGGBB as 0…255 components.
    public static func rgb(_ hex: String) -> [Double] {
        let v = UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        return [Double((v >> 16) & 255), Double((v >> 8) & 255), Double(v & 255)]
    }

    /// WCAG relative luminance of #RRGGBB.
    public static func luminance(_ hex: String) -> Double {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let v = UInt32(h, radix: 16) ?? 0
        func lin(_ c: UInt32) -> Double { let s = Double(c) / 255; return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin((v >> 16) & 255) + 0.7152 * lin((v >> 8) & 255) + 0.0722 * lin(v & 255)
    }

    public static func contrast(_ a: String, _ b: String) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// White or `ink`, whichever reads better on `background`.
    public static func readable(on background: String, ink: String) -> String {
        contrast(background, "#FFFFFF") >= contrast(background, ink) ? "#FFFFFF" : ink
    }

    // MARK: Loading

    /// `$REGISTA_BRANDKITS`, else `~/Library/Application Support/Regista/brandkits`.
    public static var userDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["REGISTA_BRANDKITS"], !env.isEmpty { return URL(fileURLWithPath: EngineConfig.expand(env)) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Regista/brandkits")
    }

    /// Built-ins overlaid with the user's kits (folders `<id>/kit.json`, and older `<id>.json` files).
    public static func all(userDirectory dir: URL = userDirectory) -> [String: BrandKit] {
        var kits = Dictionary(uniqueKeysWithValues: builtIn.map { ($0.id, $0) })
        for kit in BrandKitStore(directory: dir).userKits() { kits[kit.id] = kit }
        return kits
    }

    /// A kit from a `kit.json`, a kit folder or an older single JSON file.
    public static func load(_ path: String) throws -> BrandKit {
        var url = URL(fileURLWithPath: EngineConfig.expand(path))
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { url.appendPathComponent("kit.json") }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CommandError.notFound("brand kit: no file at \(path)") }
        do {
            var kit = try JSONDecoder().decode(BrandKit.self, from: data)
            if url.lastPathComponent == "kit.json" { kit.directory = url.deletingLastPathComponent() }
            return kit
        } catch { throw CommandError.invalid("brand kit \(path): \(error)") }
    }

    public static let builtIn: [BrandKit] = [arkad, wesites, cafeAtelier]
    public static var builtInIDs: Set<String> { Set(builtIn.map(\.id)) }

    // MARK: Built-in kits

    static func title(_ text: String = "", font: String, size: Double, color: String, background: TitleBackground? = nil,
                      uppercase: Bool? = nil, tracking: Double? = nil, maxWidth: Double? = nil, shadow: TitleShadow? = TitleShadow(),
                      align: String? = nil, highlight: String? = nil) -> Title {
        var t = Title(text: text, font: font, size: size, color: color)
        t.background = background
        t.uppercase = uppercase
        t.tracking = tracking
        t.maxWidth = maxWidth
        t.shadow = shadow
        t.align = align
        t.highlightColor = highlight
        return t
    }

    /// The WeSites fonts and logo are the client's (not in the repository): `$REGISTA_WESITES_ASSETS`, else the
    /// `wesites/assets` folder of the user's brand kits.
    static let wesitesAssets: String = {
        if let env = ProcessInfo.processInfo.environment["REGISTA_WESITES_ASSETS"], !env.isEmpty { return env }
        return BrandKit.userDirectory.appendingPathComponent("wesites/assets").path
    }()

    /// WeSites (reel 2026-10-26, BRIEF-cards): IKB / ink / cream, vermillon and veronese accents, rose; Young Serif
    /// display, Instrument Sans UI, Fragment Mono labels; captions = the approved talking-head-v1 (keyword pink #FF2D6F
    /// = highlight).
    public static let wesites = BrandKit(
        id: "wesites", name: "WeSites",
        colors: ["primary": "#002FA7", "ink": "#141414", "paper": "#F7F4EC", "accent": "#E8442E", "success": "#2E7D5B",
                 "rose": "#F27FA5", "highlight": "#FF2D6F", "onHighlight": "#FFFFFF"],
        fonts: ["display": "\(wesitesAssets)/young-serif-latin-400-normal.woff2",
                "text": "\(wesitesAssets)/instrument-sans-latin-400-normal.woff2",
                "textBold": "\(wesitesAssets)/instrument-sans-latin-700-normal.woff2",
                "mono": "\(wesitesAssets)/fragment-mono-latin-400-normal.woff2"],
        logo: "\(wesitesAssets)/wesites-mark.svg",
        captionPreset: "talking-head-v1",
        titles: [
            "hook": title(font: "display", size: 84, color: "paper", background: TitleBackground(kind: "pill", color: "primary", padX: 44, padY: 22)),
            "hookLight": title(font: "display", size: 84, color: "ink", background: TitleBackground(kind: "pill", color: "paper", padX: 44, padY: 22)),
            "question": title(font: "display", size: 54, color: "paper", background: TitleBackground(kind: "pill", color: "primary", padX: 40, padY: 20),
                              maxWidth: 900),
            "kicker": title(font: "mono", size: 28, color: "ink", background: TitleBackground(kind: "box", color: "paper", padX: 18, padY: 10, radius: 8),
                            uppercase: true, tracking: 2, shadow: nil),
            "card": title(font: "text", size: 44, color: "ink", background: TitleBackground(kind: "box", color: "paper", padX: 44, padY: 34, radius: 32),
                          maxWidth: 860, align: "left"),
            "stat": title(font: "display", size: 150, color: "paper", background: TitleBackground(kind: "box", color: "ink", padX: 56, padY: 30, radius: 32)),
            "chipOK": title(font: "textBold", size: 30, color: "paper", background: TitleBackground(kind: "pill", color: "success", padX: 26, padY: 12),
                            shadow: nil),
            "chipWarn": title(font: "textBold", size: 30, color: "paper", background: TitleBackground(kind: "pill", color: "accent", padX: 26, padY: 12),
                              shadow: nil),
            "word": title(font: "display", size: 140, color: "rose", shadow: TitleShadow(blur: 30, y: 6, opacity: 0.35)),
        ],
        logoPlacement: LogoPlacement(corner: "topRight", width: 96),
        notes: "Abstract fine touches, clean product UI, real motion (in ~0.35 s spring/expo, out ~0.25 s). No literal decoration, no gimmicks, no stock icons. Cards in the top band y 110–640; caption band 1230–1460 always clean.")

    /// Arkad (Regista UI theme): noir / crème / gold; Fraunces display, Geist UI, Geist Mono labels; the gold logo.
    /// Colours = arkad-consulting.com: --or #F4BD56, --or-solid #D89528, --or-deep #7A4D16, --creme #FFF2E9. No orange.
    public static let arkad = BrandKit(
        id: "arkad", name: "Arkad",
        colors: ["primary": "#F4BD56", "ink": "#070501", "paper": "#FFF2E9", "accent": "#D89528", "success": "#B6791B",
                 "highlight": "#F4BD56", "onHighlight": "#070501", "surface": "#14100A"],
        fonts: ["display": "bundle:Fonts/Fraunces.ttf", "text": "bundle:Fonts/Geist.ttf", "textBold": "bundle:Fonts/Geist.ttf",
                "mono": "bundle:Fonts/GeistMono.ttf"],
        logo: "bundle:Brand/arkad-mark.png",
        logos: ["onDark": "bundle:Brand/arkad-logo-on-dark.svg", "onLight": "bundle:Brand/arkad-logo-on-light.svg",
                "mark": "bundle:Brand/arkad-mark-gold.svg"],
        captionPreset: "talking-head-v1",
        titles: [
            "hook": title(font: "display", size: 84, color: "paper", background: TitleBackground(kind: "pill", color: "ink", padX: 44, padY: 22),
                          highlight: "primary"),
            "hookLight": title(font: "display", size: 84, color: "ink", background: TitleBackground(kind: "pill", color: "paper", padX: 44, padY: 22)),
            "question": title(font: "display", size: 54, color: "paper", background: TitleBackground(kind: "pill", color: "ink", padX: 40, padY: 20),
                              maxWidth: 900, highlight: "primary"),
            "kicker": title(font: "mono", size: 28, color: "primary", background: TitleBackground(kind: "box", color: "ink", padX: 18, padY: 10, radius: 8),
                            uppercase: true, tracking: 2, shadow: nil),
            "card": title(font: "text", size: 44, color: "paper", background: TitleBackground(kind: "box", color: "surface", padX: 44, padY: 34, radius: 28),
                          maxWidth: 860, align: "left"),
            "stat": title(font: "display", size: 150, color: "primary", background: TitleBackground(kind: "box", color: "ink", padX: 56, padY: 30, radius: 28)),
            "chipOK": title(font: "textBold", size: 30, color: "ink", background: TitleBackground(kind: "pill", color: "primary", padX: 26, padY: 12), shadow: nil),
            "chipWarn": title(font: "textBold", size: 30, color: "paper", background: TitleBackground(kind: "pill", color: "accent", padX: 26, padY: 12), shadow: nil),
            "word": title(font: "display", size: 140, color: "primary", shadow: TitleShadow(blur: 30, y: 6, opacity: 0.35)),
        ],
        logoPlacement: LogoPlacement(corner: "topLeft", width: 220),
        notes: "Noir and crème with gold accents, serif display. Calm, premium, few elements at a time.")

    /// Café Atelier: a fictional bakery-café starter kit to copy for a small business — espresso, oat and caramel
    /// with a terracotta keyword; Georgia display, Avenir Next text (system fonts). The logo is a PLACEHOLDER
    /// wordmark: replace it with your own (brandkit.setLogo).
    public static let cafeAtelier = BrandKit(
        id: "cafe-atelier", name: "Café Atelier",
        colors: ["primary": "#8A5A3C", "accent": "#C9A57B", "ink": "#2B2018", "paper": "#F5EFE4", "surface": "#E9DFCF",
                 "success": "#6F8A5E", "highlight": "#D2603A", "onHighlight": "#FFFFFF"],
        fonts: ["display": "Georgia", "text": "AvenirNext-Regular", "textBold": "AvenirNext-DemiBold", "mono": "Menlo-Regular"],
        logos: ["onDark": "bundle:Brand/cafe-atelier-placeholder-on-dark.svg", "onLight": "bundle:Brand/cafe-atelier-placeholder-on-light.svg"],
        captionPreset: "talking-head-v1",
        captionStyle: ["font": "AvenirNext-Heavy"],
        titles: [
            "hook": title(font: "display", size: 86, color: "ink", background: TitleBackground(kind: "pill", color: "paper", padX: 48, padY: 22),
                          highlight: "primary"),
            "hookLight": title(font: "display", size: 86, color: "paper", background: TitleBackground(kind: "pill", color: "primary", padX: 48, padY: 22)),
            "question": title(font: "display", size: 56, color: "ink", background: TitleBackground(kind: "pill", color: "paper", padX: 40, padY: 20),
                              maxWidth: 900, highlight: "highlight"),
            "kicker": title(font: "textBold", size: 28, color: "primary", background: TitleBackground(kind: "box", color: "paper", padX: 18, padY: 10, radius: 14),
                            uppercase: true, tracking: 3, shadow: nil),
            "card": title(font: "text", size: 44, color: "ink", background: TitleBackground(kind: "box", color: "surface", padX: 44, padY: 34, radius: 36),
                          maxWidth: 860, align: "left"),
            "stat": title(font: "display", size: 150, color: "primary", background: TitleBackground(kind: "box", color: "paper", padX: 56, padY: 30, radius: 36)),
            "chipOK": title(font: "textBold", size: 30, color: "paper", background: TitleBackground(kind: "pill", color: "success", padX: 26, padY: 12), shadow: nil),
            "chipWarn": title(font: "textBold", size: 30, color: "paper", background: TitleBackground(kind: "pill", color: "highlight", padX: 26, padY: 12), shadow: nil),
            "word": title(font: "display", size: 140, color: "paper", shadow: TitleShadow(blur: 30, y: 6, opacity: 0.35)),
        ],
        logoPlacement: LogoPlacement(corner: "topLeft", width: 300),
        notes: "Warm and handmade: espresso and oat, one terracotta accent. Soft entrances (fade, slow push), never flashy. Placeholder logo: replace it with the business's own.")
}

/// Where logo.add puts a brand's logo, in pixels of a 1080×1920 frame, always inside the Instagram safe area
/// and out of the caption band.
public struct LogoPlacement: Codable, Hashable, Sendable {
    /// topLeft, topRight, topCenter, bottomLeft, bottomRight (bottom = between the captions and the Instagram UI).
    public var corner: String
    /// Drawn width, px at 1080 wide.
    public var width: Double
    /// Distance from the frame edge (inside the safe area), px.
    public var margin: Double?
    public var opacity: Double?
    /// Entrance and exit (AnimationPreset name; default fade) or a logo motion (spin, orbit, pulse, sting).
    public var animation: String?
    /// Logo variant (onDark by default: footage is usually darker than the logo).
    public var variant: String?

    public init(corner: String = "topLeft", width: Double = 200, margin: Double? = nil, opacity: Double? = nil, animation: String? = nil,
                variant: String? = nil) {
        self.corner = corner
        self.width = width
        self.margin = margin
        self.opacity = opacity
        self.animation = animation
        self.variant = variant
    }

    public static let corners = ["topLeft", "topRight", "topCenter", "bottomLeft", "bottomRight"]
    /// Entrance presets and the logo motions of the effects gallery.
    public static var animations: [String] { AnimationPreset.names.filter { $0 != "kenBurns" } + LogoMotion.names.filter { $0 != "none" } }

    /// Centre of a `width`×`height` logo (reference pixels) and the size actually used: a logo too tall for the
    /// strip between the captions and the Instagram UI is shrunk to fit.
    public func frame(aspect: Double) -> (x: Double, y: Double, width: Double, height: Double) {
        let m = margin ?? 48
        let W = SafeZones.referenceWidth
        let bottom = corner.hasPrefix("bottom")
        var w = width, h = width / max(aspect, 0.01)
        // Never wider than the safe width, never taller than its band: the top card band, or the strip between
        // the caption band and the Instagram caption/UI zone.
        let maxW = corner == "topCenter" ? W - 2 * SafeZones.rightMargin : W - SafeZones.rightMargin - m
        let maxH = bottom ? SafeZones.bottomLimit - SafeZones.caption.1 - 16 : SafeZones.top.1 - SafeZones.topLimit - m / 2
        if w > maxW { w = maxW; h = w / max(aspect, 0.01) }
        if h > maxH { h = maxH; w = h * aspect }
        let x: Double
        switch corner {
        case "topRight", "bottomRight": x = W - SafeZones.rightMargin - w / 2
        case "topCenter": x = W / 2
        default: x = m + w / 2
        }
        let y = bottom ? (SafeZones.caption.1 + SafeZones.bottomLimit) / 2 : SafeZones.topLimit + m / 2 + h / 2
        return (x, y, w, h)
    }
}
