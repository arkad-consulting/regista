import AppKit
import CoreText
import RegistaCore
import SwiftUI

// Regista's design tokens (D0 #46): the only file with colour values and font literals. Every view takes its colours,
// fonts, spacing and radii from `Ed`; the controls built on them live in Controls.swift. The values follow the approved
// window shell A (docs/design/shell-a-*.html): macOS dark greys, SF Pro for text, SF Mono for timecodes and numbers,
// the editorial display face only for large headings, and one accent (Arkad gold, or the brand kit's: `Accent`).
// Tests/RegistaAppTests/DesignSystemTests.swift fails when a colour or font literal appears in another file.
//
// Allowed elsewhere (documented in that test): `Color(hexString:)` for colours that are data (a brand kit's palette, a
// backdrop chosen by the user), and the neutral `.white` / `.black` / `.clear` for shadows, scrims and drawn media.

enum Ed {
    // MARK: Surfaces — the shell (title row, bars, panels) and the content inside the panels

    static let bar = Color(hex: 0x232325)         // title row, activity bar, status bar, project tab strip
    static let side = Color(hex: 0x202022)        // side panel, right panel
    static let toolbar = Color(hex: 0x1C1C1E)     // the active project tab, the editor toolbar
    static let main = Color(hex: 0x161618)        // the main area behind the monitors
    static let control = Color(hex: 0x2C2C2E)     // a control's track (segmented bar, chrome buttons)
    static let controlOn = Color(hex: 0x48484A)   // the chosen segment
    static let rule = Color(hex: 0x2F2F31)        // separators between the shell's regions
    static let rule2 = Color(hex: 0x2A2A2C)       // separators inside a panel's header

    static let bg = Color(hex: 0x09090A)          // gutters between panels
    static let panel = Color(hex: 0x131315)
    static let header = Color(hex: 0x18181B)
    static let raised = Color(hex: 0x222226)
    static let hover = Color(hex: 0x2B2B30)
    static let well = Color(hex: 0x0E0E10)        // timeline lanes, monitor surround, recessed fields
    static let lane = Color(hex: 0x111113)        // a timeline lane that holds a track
    static let stage = Color(hex: 0x111114)       // the record preview's empty stage
    static let stageTop = Color(hex: 0x1D1D22), stageBottom = Color(hex: 0x16161A)     // the record preview's backdrop
    static let cardTop = Color(hex: 0x24242A), cardBottom = Color(hex: 0x1B1B20)       // a placeholder card on the stage
    static let stageDeep = Color(hex: 0x0F1013)   // behind the live sources in the record preview
    static let tooltip = Color(hex: 0x1D1D20)
    static let line = Color.white.opacity(0.06)
    static let line2 = Color.white.opacity(0.11)

    // MARK: Text — four greys, brightest first

    static let text = Color(hex: 0xF2F2F4)
    static let text2 = Color(hex: 0xC7C7CC)
    static let text3 = Color(hex: 0x8E8E93)
    static let text4 = Color(hex: 0x6E6E73)

    // MARK: Accent and states

    /// The accent: Arkad gold, or the active brand kit's when "accent follows the kit" is on (`Accent`).
    static var gold: Color { Accent.color }
    static var goldSoft: Color { Accent.color.opacity(0.16) }
    static let danger = Color(hex: 0xFF453A)
    static let ok = Color(hex: 0x7FC8A9)
    static let online = Color(hex: 0x30D158)      // the "connected" dot
    static let warn = Color(hex: 0xD89528)

    // Waveforms and caption blocks on the timeline (clip fills by type: ClipPalette)
    static let audioWave = Color(hex: 0x74C2A8)
    static let musicWave = Color(hex: 0xC9A86A)
    static let captionClip = Color(hex: 0x2E2719)
    static let keyword = Color(hex: 0xFF2D6F)

    /// The kinds of item applied to a clip (Applied list): graphics, transitions, speed (effects use the accent).
    static let appliedGraphic = Color(hex: 0x8C78F2), appliedTransition = Color(hex: 0x59C7DB), appliedSpeed = Color(hex: 0x73CC7A)

    /// Brand-kit previews: a logo tile on dark and on light footage, a caption sample's backdrop.
    static let logoOnDark = Color(hex: 0x2A2724), logoOnLight = Color(hex: 0xEDE7DF), captionBackdrop = Color(hex: 0x4A4541)

    // MARK: Spacing, radii, type scale

    /// Spacing scale, points: between the parts of a control (xs), controls (s, m), groups (l, xl), sections (xxl).
    enum Space {
        static let xxs: CGFloat = 2, xs: CGFloat = 4, s: CGFloat = 8, m: CGFloat = 12, l: CGFloat = 16, xl: CGFloat = 24, xxl: CGFloat = 32
    }

    /// Corner radii: small controls (s), buttons and fields (m), rows and tiles (l), panels and previews (xl).
    enum Radius {
        static let s: CGFloat = 4, m: CGFloat = 6, l: CGFloat = 8, xl: CGFloat = 10
    }

    /// Type scale, points. SF Pro for text, SF Mono for timecodes and numbers, the display face for large headings.
    enum TypeSize {
        static let micro: CGFloat = 9.5, caption: CGFloat = 10.5, small: CGFloat = 11, body: CGFloat = 12, label: CGFloat = 12.5,
                   control: CGFloat = 13, title: CGFloat = 14, heading: CGFloat = 18, display: CGFloat = 28
    }

    // MARK: Fonts

    /// Text (SF Pro, the system font).
    static func ui(_ size: CGFloat = TypeSize.control, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// Timecodes, numbers, file sizes (SF Mono).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
    /// Large headings only (Inizio's title, an empty screen's headline): the editorial face that ships in the bundle.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom("Fraunces", size: size).weight(weight) }
    /// SF Symbols beside text.
    static func icon(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight) }
    /// A caption-style preview word (the brand kit's caption box sample).
    static func captionSample(_ size: CGFloat) -> Font { .custom("Impact", size: size) }

    /// A brand kit's font: a font file (registered for the process first) or a family name; data, not chrome.
    static func kitFont(_ spec: String, size: CGFloat) -> Font {
        if spec.hasPrefix("/") {
            let url = URL(fileURLWithPath: spec) as CFURL
            CTFontManagerRegisterFontsForURL(url, .process, nil)
            if let d = (CTFontManagerCreateFontDescriptorsFromURL(url) as? [CTFontDescriptor])?.first {
                return Font(CTFontCreateWithFontDescriptor(d, size, nil))
            }
            return .system(size: size)
        }
        return .custom(spec, size: size)
    }
    /// Text drawn by AppKit over the screen (the area picker's hint and size).
    static func overlayFont(_ size: CGFloat, _ weight: NSFont.Weight, digits: Bool = false) -> NSFont {
        digits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    }

    /// The speaker's teleprompter glass: warm black, cream text, gold for where the reader is (a reading surface, not chrome).
    enum Prompter {
        static let noir = NSColor(hex: 0x070501)
        static let cream = NSColor(hex: 0xFFF2E9)
        static let gold = NSColor(hex: 0xF4BD56)
        static let amber = Color(hex: 0xD89528)
        static let goldDeep = Color(hex: 0xB6791B)
        static let surface = Color(hex: 0x1D170F)   // the glass's control pills
        static let slow = Color(hex: 0x7DA3D1)      // reading pace: too slow
        static var noirColor: Color { Color(nsColor: noir) }
        static var creamColor: Color { Color(nsColor: cream) }
        static var goldColor: Color { Color(nsColor: gold) }

        /// The prompter's text face (Geist ships in the bundle; the system font when it is missing).
        static func font(family: String = "Geist", size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {   // l10n-ignore
            let descriptor = NSFontDescriptor(fontAttributes: [.family: family, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
            return NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
    }

    /// The window's background behind the SwiftUI content (the title band's colour, `bar`).
    static let windowBackground = NSColor(hex: 0x232325)

    /// Fonts ship inside the app bundle (Contents/Resources/Fonts).
    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in files where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

// MARK: - Timeline clip colours

/// Clip colours by type: muted fills (thumbnails and waveforms read first) with a brighter edge that says what the
/// clip is at a glance.
enum ClipPalette {
    enum Kind: CaseIterable { case footage, voice, music, sfx, caption, title, logo, insert, overlay }

    static func fill(_ k: Kind) -> Color {
        switch k {
        case .footage: Color(hex: 0x2A3644)
        case .voice: Color(hex: 0x1C302B)
        case .music: Color(hex: 0x332D1F)
        case .sfx: Color(hex: 0x2B2337)
        case .caption: Color(hex: 0x2E2719)
        case .title: Color(hex: 0x3A2630)
        case .logo: Color(hex: 0x2F2A1C)
        case .insert: Color(hex: 0x1F3236)
        case .overlay: Color(hex: 0x3A2B22)
        }
    }

    static func edge(_ k: Kind) -> Color {
        switch k {
        case .footage: Color(hex: 0x6E8CAD)
        case .voice: Color(hex: 0x74C2A8)
        case .music: Color(hex: 0xC9A86A)
        case .sfx: Color(hex: 0xA48BD6)
        case .caption: Color(hex: 0xE0B86A)
        case .title: Color(hex: 0xE58BA8)
        case .logo: Ed.gold
        case .insert: Color(hex: 0x6CC4CF)
        case .overlay: Color(hex: 0xD8956A)
        }
    }

    /// The kind's name, a lookup key (draw it with loc).
    static func label(_ k: Kind) -> String {
        switch k {
        case .footage: "track.footage"
        case .voice: "Voce"
        case .music: "Musica"
        case .sfx: "track.sfx"
        case .caption: "Sottotitoli"
        case .title: "Titoli"
        case .logo: "Logo"
        case .insert: "Piani IA"
        case .overlay: "Grafica"
        }
    }

    /// The kind of a clip on a track.
    static func kind(_ clip: Clip, track: Track?) -> Kind {
        guard let track else { return .footage }
        switch track.kind {
        case .caption: return .caption
        case .audio: return track.role == "music" ? .music : track.role == "sfx" ? .sfx : .voice
        case .video: return .footage
        case .overlay:
            if clip.title != nil { return .title }
            switch track.role {
            case "logo": return .logo
            case "inserts": return .insert
            default: return .overlay
            }
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}
