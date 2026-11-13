import Foundation

// Keystroke overlay (issue #44): the keys logged in session.json ("cmd+shift+k", "k36") become on-screen badges in
// the macOS notation (⇧⌘K). By default only shortcuts are shown; with allKeys, runs of plain typing collapse into
// one badge of the typed text and special keys (↩ ⎋ ⇥ arrows) get their own. Pure, unit-tested; keys.overlay puts
// the badges on the timeline.

/// One logged keystroke: modifiers (cmd, ctrl, alt, shift) and the key as logged (characters or "k<keyCode>").
public struct KeyStroke: Hashable, Sendable {
    public static let modifierNames = ["ctrl", "alt", "shift", "cmd"]

    public var modifiers: Set<String>
    public var key: String

    public init(modifiers: Set<String> = [], key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// "cmd+shift+k" → [cmd, shift] + "k"; "cmd++" → [cmd] + "+".
    public init(parsing s: String) {
        var parts = s.components(separatedBy: "+")
        var mods: Set<String> = []
        while parts.count > 1, Self.modifierNames.contains(parts[0]) { mods.insert(parts.removeFirst()) }
        modifiers = mods
        key = parts.joined(separator: "+")
        if key.isEmpty, s.hasSuffix("+") { key = "+" }
    }

    /// macOS key codes of the keys whose characters are not printable (logged as "k<code>").
    static let keyCodes: [Int: String] = [36: "↩", 76: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                          115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
                                          98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]

    /// The key's name on screen ("K", "↩", "F5", "Space"), nil for an unknown key code.
    public var name: String? {
        if key.hasPrefix("k"), key.count > 1, let code = Int(key.dropFirst()) { return Self.keyCodes[code] }
        guard let u = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return key.uppercased() }
        switch u.value {
        case 0x0D, 0x03: return "↩"
        case 0x09, 0x19: return "⇥"
        case 0x1B: return "⎋"
        case 0x7F, 0x08: return "⌫"
        case 0x20: return "Space"
        case 0xF728: return "⌦"
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0xF729: return "↖"
        case 0xF72B: return "↘"
        case 0xF72C: return "⇞"
        case 0xF72D: return "⇟"
        case 0xF704...0xF70F: return "F\(u.value - 0xF704 + 1)"
        case 0xF700...0xF8FF: return nil   // other function keys of the private-use area
        case 0x00...0x1F: return nil
        default: return key.uppercased()
        }
    }

    /// F1…F12.
    var isFunctionKey: Bool { (name ?? "").hasPrefix("F") && (name ?? "").count > 1 && Int((name ?? "").dropFirst()) != nil }

    /// Not a character that types text: return, tab, escape, delete, arrows, function keys, page keys.
    public var isSpecial: Bool {
        guard let n = name else { return true }
        return n != "Space" && (n.count > 1 || "↩⇥⎋⌫⌦←→↓↑↖↘⇞⇟".contains(n))
    }

    /// A shortcut: ⌘, ⌃ or ⌥ held, or a function key.
    public var isShortcut: Bool { !modifiers.isDisjoint(with: ["cmd", "ctrl", "alt"]) || isFunctionKey }

    /// The macOS notation: modifiers in the menu order ⌃⌥⇧⌘, then the key ("⇧⌘K", "⌘Space").
    public var glyphs: String {
        let symbols = ["ctrl": "⌃", "alt": "⌥", "shift": "⇧", "cmd": "⌘"]
        return Self.modifierNames.filter(modifiers.contains).compactMap { symbols[$0] }.joined() + (name ?? "?")
    }

    /// The character it types (plain typing), nil for special keys.
    var typed: String? {
        guard !isSpecial, let n = name else { return nil }
        if n == "Space" { return " " }
        return modifiers.contains("shift") ? key.uppercased() : key
    }
}

/// A badge on screen: from the first key to the last key of its group plus the hold, session seconds.
public struct KeyBadge: Hashable, Sendable {
    public enum Kind: String, Sendable { case shortcut, special, typing }
    public var kind: Kind
    public var start: Double
    public var end: Double
    /// Session time of the last key in the group.
    public var last: Double
    /// shortcut / special: the glyphs; typing: the text typed.
    public var keys: String
    /// Presses of the same shortcut in a row.
    public var count: Int

    /// What the badge shows ("⌘Z ×3", "…ello world").
    public func text(maxTyped: Int = 24) -> String {
        switch kind {
        case .typing: return keys.count > maxTyped ? "…" + keys.suffix(maxTyped - 1) : keys
        case .shortcut, .special: return count > 1 ? "\(keys) ×\(count)" : keys
        }
    }
}

public enum KeyOverlay {
    public struct Options: Sendable {
        /// Also show plain typing (collapsed into runs) and special keys.
        public var allKeys = false
        /// Seconds a badge stays after its last key.
        public var hold = 1.0
        /// Shortest badge, seconds.
        public var minDuration = 0.7
        /// The same key again within this many seconds counts as a repeat (⌘Z ×3).
        public var repeatGap = 0.8
        /// Typed characters closer than this belong to the same run.
        public var typingGap = 1.2
        public init() {}
    }

    /// The badges of a session's key events (other events ignored), in time order, never overlapping.
    public static func badges(_ events: [RecordingSession.Event], _ o: Options = Options()) -> [KeyBadge] {
        var out: [KeyBadge] = []
        for e in events.filter({ $0.kind == "key" && $0.key != nil }).sorted(by: { $0.t < $1.t }) {
            let k = KeyStroke(parsing: e.key!)
            guard k.name != nil else { continue }
            if k.isShortcut || (o.allKeys && k.isSpecial) {
                let kind: KeyBadge.Kind = k.isShortcut ? .shortcut : .special
                // ⌫ inside a typing run edits the run instead of getting its own badge.
                if kind == .special, k.name == "⌫", k.modifiers.isEmpty, var run = out.last, run.kind == .typing, e.t - run.last <= o.typingGap {
                    if !run.keys.isEmpty { run.keys.removeLast() }
                    run.last = e.t
                    out[out.count - 1] = run
                    continue
                }
                if var prev = out.last, prev.kind == kind, prev.keys == k.glyphs, e.t - prev.last <= o.repeatGap {
                    prev.count += 1
                    prev.last = e.t
                    out[out.count - 1] = prev
                } else {
                    out.append(KeyBadge(kind: kind, start: e.t, end: e.t, last: e.t, keys: k.glyphs, count: 1))
                }
            } else if o.allKeys, let c = k.typed {
                if var run = out.last, run.kind == .typing, e.t - run.last <= o.typingGap {
                    run.keys += c
                    run.last = e.t
                    out[out.count - 1] = run
                } else {
                    out.append(KeyBadge(kind: .typing, start: e.t, end: e.t, last: e.t, keys: c, count: 1))
                }
            }
        }
        out.removeAll { $0.kind == .typing && $0.keys.trimmingCharacters(in: .whitespaces).isEmpty }
        for i in out.indices {
            out[i].end = max(out[i].last + o.hold, out[i].start + o.minDuration)
            if i > 0, out[i - 1].end > out[i].start { out[i - 1].end = out[i].start }
        }
        return out
    }

    /// The badge's look: a dark rounded chip with light text, coloured by the brand kit (ink chip, paper text) or
    /// neutral. The face stays the system's Helvetica Neue: the ⌘⇧⌥⌃ glyphs come from system fonts and would not match
    /// a brand face. `size` is the font size in title pixels (per 1080 of the output width).
    public static func title(_ text: String, kind: KeyBadge.Kind, size: Double, kit: BrandKit?) -> Title {
        var t = Title(text: text, font: "HelveticaNeue-Medium", size: size, color: kit == nil ? "#F5F5F7" : "paper")
        t.tracking = kind == .typing ? 0 : 0.05 * size
        t.background = TitleBackground(kind: "box", color: kit == nil ? "#15161A" : "ink", opacity: 0.86,
                                       padX: (0.58 * size).rounded(), padY: (0.3 * size).rounded(), radius: (0.3 * size).rounded())
        t.shadow = TitleShadow(blur: (0.5 * size).rounded(), x: 0, y: (0.14 * size).rounded(), opacity: 0.3)
        return kit.map { $0.resolve(t) } ?? t
    }

    /// Font size (title pixels) for a `width`×`height` output: about 3.8% of the shorter side on screen.
    public static func size(width W: Int, height H: Int) -> Double {
        (0.038 * Double(min(W, H)) * SafeZones.referenceWidth / Double(W) * 10).rounded() / 10
    }

    /// Height of a badge on screen, output pixels.
    public static func badgeHeight(size: Double, width W: Int) -> Double {
        (size * 1.15 + 2 * (0.3 * size).rounded()) * Double(W) / SafeZones.referenceWidth
    }

    /// Vertical centre (output pixels) of a badge `badge` px tall: inside the bottom (top) edge of a boxed screen (a
    /// styled frame, the stack's screen half) so it belongs to the screen; otherwise near the frame's bottom (top) edge,
    /// or just above the caption band (in the top band) of a tall reel, clear of the Instagram chrome.
    public static func centreY(position: String, width W: Int, height H: Int, screenBox: [Double]?, badge: Double) -> Double {
        let top = position == "top"
        if let b = screenBox {
            let margin = 0.05 * b[3]
            return top ? b[1] + margin + badge / 2 : b[1] + b[3] - margin - badge / 2
        }
        let h = Double(H)
        if Double(H) / Double(W) >= 1.5 {
            return top ? SafeZones.centre(of: "top")! * h : (SafeZones.caption.0 - 30) / SafeZones.referenceHeight * h - badge / 2
        }
        let margin = 0.07 * Double(min(W, H))
        return top ? margin + badge / 2 : h - margin - badge / 2
    }

    /// Horizontal centre (output pixels) of a badge `width`×`height` centred at `y`: the middle of `span` [left, right]
    /// (the screen box or the frame), moved into the larger free part of the span when it would touch `avoid` (the
    /// camera's box [x, y, w, h]).
    public static func centreX(span: (Double, Double), width bw: Double, y: Double, height bh: Double, avoid: [Double]?) -> Double {
        let mid = (span.0 + span.1) / 2
        guard let a = avoid, y + bh / 2 > a[1], y - bh / 2 < a[1] + a[3] else { return mid }
        let gap = 0.4 * bh
        guard mid + bw / 2 + gap > a[0], mid - bw / 2 - gap < a[0] + a[2] else { return mid }
        let leftFree = (span.0, a[0] - gap), rightFree = (a[0] + a[2] + gap, span.1)
        let side = leftFree.1 - leftFree.0 >= rightFree.1 - rightFree.0 ? leftFree : rightFree
        // Centred in the free part when it fits, else as close to the middle as it can be.
        return side.1 - side.0 >= bw ? (side.0 + side.1) / 2 : (side == leftFree ? side.1 - bw / 2 : side.0 + bw / 2)
    }
}
