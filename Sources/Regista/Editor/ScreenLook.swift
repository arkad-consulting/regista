import Foundation
import RegistaCore

// The Schermo section of the inspector (R2 #51, #42 #43 #44), without SwiftUI: which screen recording the selection
// belongs to, what its look is now, and the command each control runs — layout.apply (face layout and styled frame),
// cursor.style, keys.overlay, edit.autoZoom and project.format. One command per gesture, so each change is logged and
// is one undo step, exactly what an agent would do over MCP.

/// The screen recording the section edits, and over which range.
struct ScreenLookTarget: Equatable {
    var index: Int
    var link: RecordingLink
    /// The selected recording clips' range; nil = the whole recording.
    var from: MediaTime?
    var to: MediaTime?
    /// The layout at the start of the range (the session's default when none was applied).
    var layout: LayoutSpec
    /// How many different layouts the range holds (a choice here replaces them all).
    var layoutCount: Int

    var hasCamera: Bool { link.camera != nil }
    /// The take was recorded without the system cursor: the compositor draws it (cursor.style).
    var cursorDrawn: Bool { link.cursorInVideo == false }
    var cursor: CursorStyle { link.cursor ?? CursorStyle() }
}

/// What the take logged while recording (read from its session.json).
struct ScreenSessionInfo: Equatable {
    var clicks = 0
    var keys = 0
    /// session.json could be read.
    var readable = false
}

/// A frame background as the section offers it.
enum ScreenBackground: Hashable {
    /// The applied brand kit's (the default), else graphite.
    case brand
    case preset(String)
    case color(String)
    case image(String)
    /// A custom gradient made over MCP: kept as it is.
    case custom
}

enum ScreenLook {
    static let formats = ["16:9", "9:16", "4:5", "1:1"]

    // MARK: Target

    /// The recording of the selection (single or multiple clips of one recording), or with nothing selected the
    /// project's last screen recording; nil when the selection is something else or the project has none.
    static func target(_ t: InspectorTarget, in p: Project) -> ScreenLookTarget? {
        let all = p.recordings ?? []
        guard !all.isEmpty else { return nil }
        func assets(_ l: RecordingLink) -> Set<String> { Set([l.screen, l.camera, l.mic, l.system].compactMap { $0 }) }
        var index: Int
        var from: MediaTime?, to: MediaTime?
        switch t.kind {
        case .none:
            guard let i = all.lastIndex(where: { $0.screen != nil }) else { return nil }
            index = i
        case .video, .audio, .multi:
            guard !t.items.isEmpty,
                  let i = all.firstIndex(where: { l in l.screen != nil && t.items.allSatisfy { assets(l).contains($0.clip.assetID) } }) else { return nil }
            index = i
            from = t.items.map(\.clip.start).min()
            to = t.items.map(\.clip.end).max()
            // A clip that spans the whole recording is the whole recording.
            if let ext = Recording.extent(all[i], p), let f = from, let e = to, f <= ext.0, e >= ext.1 { from = nil; to = nil }
        default:
            return nil
        }
        let link = all[index]
        let layouts = (link.layouts ?? []).sorted { $0.from < $1.from }
        let start = from ?? layouts.first?.from ?? .zero
        let end = to ?? layouts.last?.to ?? p.duration
        let inRange = layouts.filter { $0.from < end && start < $0.to }
        let current = layouts.last { $0.from <= start }?.layout ?? inRange.first?.layout
            ?? LayoutSpec(kind: link.camera == nil ? .screen : .bubble)
        return ScreenLookTarget(index: index, link: link, from: from, to: to, layout: current, layoutCount: Set(inRange.map(\.layout)).count)
    }

    /// session.json's clicks and keys, read once per file.
    @MainActor private static var infoCache: [String: ScreenSessionInfo] = [:]

    @MainActor
    static func sessionInfo(_ link: RecordingLink) -> ScreenSessionInfo {
        if let hit = infoCache[link.session] { return hit }
        var info = ScreenSessionInfo()
        if let s = try? RecordingSession.load(URL(fileURLWithPath: link.session)) {
            info = ScreenSessionInfo(clicks: s.clicks.count, keys: s.events.filter { $0.kind == "key" }.count, readable: true)
        }
        infoCache[link.session] = info
        return info
    }

    // MARK: Face layout and frame (layout.apply)

    /// layout.apply for `spec` over the target's range. Options that do not belong to the layout are dropped (the frame
    /// outside screen / bubble, a top corner for the cut-out, a side of the other kind), and the frame always travels
    /// with the layout (layout.apply without frame options removes it).
    static func layout(_ spec: LayoutSpec, _ t: ScreenLookTarget) -> InspectorCommand {
        var s = spec
        if !LayoutSpec.framed.contains(s.kind) { s.frame = nil }
        if s.kind == .cutout, s.corner?.hasPrefix("top") == true { s.corner = "bottomRight" }
        if let side = s.side, !(s.kind == .stack ? ["top", "bottom"] : ["left", "right"]).contains(side) || ![.split, .stack].contains(s.kind) { s.side = nil }
        var o: [String: JSONValue] = ["preset": .string(s.kind.rawValue), "recordingId": .string(t.link.id)]
        switch s.kind {
        case .bubble:
            o["corner"] = .string(s.corner ?? "bottomRight"); o["shape"] = .string(s.shape ?? "circle"); o["size"] = .string(s.size ?? "M")
        case .cutout:
            o["corner"] = .string(s.corner ?? "bottomRight"); o["size"] = .string(s.size ?? "M")
        case .split, .stack:
            if let side = s.side { o["side"] = .string(side) }
        case .face, .screen: break
        }
        if LayoutSpec.framed.contains(s.kind) { o.merge(frameParams(s.frame), uniquingKeysWith: { _, b in b }) }
        if let f = t.from { o["from"] = .number(f.seconds) }
        if let e = t.to { o["to"] = .number(e.seconds) }
        return InspectorCommand(id: "layout.apply", params: .object(o))
    }

    /// layout.apply's frame options for `frame` (nil: frame false).
    static func frameParams(_ frame: ScreenFrame?) -> [String: JSONValue] {
        guard let f = frame else { return ["frame": false] }
        var o: [String: JSONValue] = ["frame": true]
        if let b = f.background {
            switch b.kind {
            case .solid: if let c = b.colors?.first { o["background"] = .string(c) }
            case .image: if let path = b.path { o["background"] = .string(path) }
            case .linear, .radial:
                if let name = b.preset, Backdrop.presetNames.contains(name) {
                    o["background"] = .string(name)
                } else if let colors = b.colors {
                    o["gradient"] = .array(colors.map { .string($0) })
                    o["gradientKind"] = .string(b.kind.rawValue)
                    if let a = b.angle { o["angle"] = .number(a) }
                }
            }
        }
        if let v = f.padding { o["padding"] = .number(v) }
        if let v = f.radius { o["radius"] = .number(v) }
        if let v = f.shadow { o["shadow"] = .number(v) }
        return o
    }

    static func background(_ frame: ScreenFrame?) -> ScreenBackground {
        guard let b = frame?.background else { return .brand }
        switch b.kind {
        case .solid: return .color(b.colors?.first ?? "#000000")
        case .image: return .image(b.path ?? "")
        case .linear, .radial:
            if let name = b.preset, Backdrop.presetNames.contains(name) { return .preset(name) }
            return .custom
        }
    }

    /// The layout with its frame switched on or off.
    static func framed(_ on: Bool, _ t: ScreenLookTarget) -> InspectorCommand {
        var s = t.layout
        s.frame = on ? (s.frame ?? ScreenFrame()) : nil
        return layout(s, t)
    }

    /// The layout with another frame background.
    static func background(_ b: ScreenBackground, _ t: ScreenLookTarget) -> InspectorCommand {
        var s = t.layout
        var f = s.frame ?? ScreenFrame()
        switch b {
        case .brand: f.background = nil
        case .preset(let name): f.background = Backdrop.preset(name)
        case .color(let hex): f.background = Backdrop(kind: .solid, colors: [hex.uppercased()])
        case .image(let path): f.background = Backdrop(kind: .image, path: path)
        case .custom: break
        }
        s.frame = f
        return layout(s, t)
    }

    enum FrameField: String { case padding, radius, shadow }

    static func frameValue(_ f: FrameField, _ t: ScreenLookTarget) -> Double {
        let fr = t.layout.frame
        switch f {
        case .padding: return fr?.padding ?? ScreenFrame.defaultPadding
        case .radius: return fr?.radius ?? ScreenFrame.defaultRadius
        case .shadow: return fr?.shadow ?? ScreenFrame.defaultShadow
        }
    }

    static func frame(_ f: FrameField, _ v: Double, _ t: ScreenLookTarget) -> InspectorCommand {
        var s = t.layout
        var fr = s.frame ?? ScreenFrame()
        let r = (v * 1000).rounded() / 1000
        switch f {
        case .padding: fr.padding = min(max(r, 0), 0.3)
        case .radius: fr.radius = min(max(r, 0), 0.2)
        case .shadow: fr.shadow = min(max(r, 0), 1)
        }
        s.frame = fr
        return layout(s, t)
    }

    // MARK: Cursor (cursor.style)

    static func cursor(_ field: String, _ value: JSONValue, _ t: ScreenLookTarget) -> InspectorCommand {
        InspectorCommand(id: "cursor.style", params: [field: value, "recordingId": .string(t.link.id)])
    }

    // MARK: Key badges (keys.overlay)

    struct KeysState: Equatable {
        var on: Bool
        var allKeys: Bool
        var position: String
    }

    static func keysState(_ t: ScreenLookTarget, in p: Project) -> KeysState {
        KeysState(on: p.tracks.contains { $0.role == Recording.keysTrackRole && $0.kind == .overlay && !$0.clips.isEmpty },
                  allKeys: t.link.keys?["allKeys"]?.boolValue ?? false, position: t.link.keys?["position"]?.stringValue ?? "bottom")
    }

    static func keys(_ s: KeysState, _ t: ScreenLookTarget) -> InspectorCommand {
        guard s.on else { return InspectorCommand(id: "keys.overlay", params: ["clear": true, "recordingId": .string(t.link.id)]) }
        var o = (t.link.keys ?? [:]).filter { ["hold", "size"].contains($0.key) }
        o["allKeys"] = .bool(s.allKeys)
        o["position"] = .string(s.position)
        o["recordingId"] = .string(t.link.id)
        return InspectorCommand(id: "keys.overlay", params: .object(o))
    }

    // MARK: Automatic zoom (edit.autoZoom)

    struct ZoomState: Equatable {
        var on: Bool
        var zoom: Double
        var follow: Bool
    }

    static func zoomState(_ t: ScreenLookTarget, in p: Project) -> ZoomState {
        let o = t.link.autoZoom
        let keyed = Recording.clips(of: t.link.screen, in: p).contains { p.tracks[$0.track].clips[$0.clip].keyframes != nil }
        return ZoomState(on: o != nil || keyed, zoom: o?["zoom"]?.doubleValue ?? ZoomOptions().zoom, follow: o?["follow"]?.boolValue ?? false)
    }

    /// edit.autoZoom with the recording's last options and `s` on top (a re-run replaces its own keyframes), or the
    /// zoom removed.
    static func zoom(_ s: ZoomState, _ t: ScreenLookTarget) -> InspectorCommand {
        guard s.on else { return InspectorCommand(id: "edit.autoZoom", params: ["clear": true, "recordingId": .string(t.link.id)]) }
        var o = t.link.autoZoom ?? [:]
        o["zoom"] = .number((min(max(s.zoom, 1.05), 4) * 100).rounded() / 100)
        o["follow"] = .bool(s.follow)
        o["recordingId"] = .string(t.link.id)
        return InspectorCommand(id: "edit.autoZoom", params: .object(o))
    }

    // MARK: Output format (project.format)

    static func format(_ id: String) -> InspectorCommand { InspectorCommand(id: "project.format", params: ["preset": .string(id)]) }

    /// The preset the project's size matches (by aspect), nil for another size.
    static func formatID(_ p: Project) -> String? {
        let a = Double(p.settings.width) / Double(max(p.settings.height, 1))
        return ExportPreset.all.first { abs(Double($0.width) / Double($0.height) - a) < 0.01 }?.id
    }
}
