import AppKit
import RegistaCore
import SwiftUI

// The context menu of a timeline clip (E1 #53), built when the right click happens so it knows the clip under the
// pointer. Every item is a ClipAction: commands through the tab's store.

@MainActor
enum ClipMenu {
    /// One entry: a title, its shortcut as shown, and what it does (nil = a separator).
    struct Item {
        var title: String
        var shortcut: String = ""
        var action: ClipAction?
        var enabled = true
        var submenu: [Item] = []
    }

    static let speeds: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]

    /// The entries for `clip` (tests read them; `make` turns them into an NSMenu).
    static func items(clip: Clip, track: Track, project p: Project, selection: Set<String>, at t: Double) -> [Item] {
        let group = selection.contains(clip.id) ? selection : [clip.id]
        let linked = clip.link != nil && p.tracks.flatMap(\.clips).contains { $0.link == clip.link && $0.id != clip.id }
        let hasFile = p.asset(clip.assetID) != nil
        var out: [Item] = [
            Item(title: loc("Taglia al cursore"), shortcut: "⌘K", action: .cutAtPlayhead),
            Item(title: loc("Dividi qui"), action: .splitHere(t), enabled: clip.start.seconds < t && t < clip.end.seconds),
            Item(title: "", action: nil),
            Item(title: loc("Elimina"), shortcut: "⌫", action: .delete),
            Item(title: loc("Elimina e chiudi il vuoto"), shortcut: "⇧⌫", action: .rippleDelete),
            Item(title: loc("Duplica"), shortcut: "⌘D", action: .duplicate),
        ]
        if linked { out.append(Item(title: loc("Scollega l'audio"), action: .unlink)) }
        else if group.count >= 2 { out.append(Item(title: loc("Collega le clip"), action: .link)) }
        if hasFile, track.kind != .caption {
            out.append(Item(title: loc("Velocità"), submenu: speeds.map { r in
                Item(title: r == 1 ? loc("Normale (1×)") : String(format: "%g×", r), action: .speed(r))
            }))
        }
        out += [
            Item(title: "", action: nil),
            Item(title: loc("Mostra nell'Ispettore"), action: .showInInspector),
            Item(title: loc("Mostra in Media"), action: .revealInMedia, enabled: hasFile),
            Item(title: loc("Mostra nel Finder"), action: .showInFinder, enabled: hasFile),
        ]
        return out
    }

    static func make(clip: Clip, track: Track, project: Project, store: EditorStore, at t: Double) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items(clip: clip, track: track, project: project, selection: store.selection, at: t) {
            menu.addItem(nsItem(item, clip: clip, store: store))
        }
        return menu
    }

    private static func nsItem(_ item: Item, clip: Clip, store: EditorStore) -> NSMenuItem {
        if item.title.isEmpty && item.submenu.isEmpty { return .separator() }
        let ns = ActionMenuItem(title: item.title) { [weak store] in
            if let a = item.action { store?.perform(a, on: clip) }
        }
        ns.isEnabled = item.enabled
        // The shortcut shown on the right (outside the menu the editor's key monitor handles the keys).
        switch item.shortcut {
        case "⌘K": ns.keyEquivalent = "k"; ns.keyEquivalentModifierMask = .command
        case "⌘D": ns.keyEquivalent = "d"; ns.keyEquivalentModifierMask = .command
        case "⌫": ns.keyEquivalent = "\u{8}"; ns.keyEquivalentModifierMask = []
        case "⇧⌫": ns.keyEquivalent = "\u{8}"; ns.keyEquivalentModifierMask = .shift
        default: break
        }
        if !item.submenu.isEmpty {
            let sub = NSMenu()
            for s in item.submenu { sub.addItem(nsItem(s, clip: clip, store: store)) }
            ns.submenu = sub
        }
        return ns
    }
}

/// An NSMenuItem that runs a closure.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { handler() }
}

/// A transparent view over the timeline lanes that only takes right clicks (and ⌃-clicks) and pops the menu built for
/// that point; every other event goes through to the SwiftUI gestures below.
struct ContextMenuArea: NSViewRepresentable {
    let menu: (CGPoint) -> NSMenu?

    final class Area: NSView {
        var menuAt: ((CGPoint) -> NSMenu?)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let e = NSApp.currentEvent else { return nil }
            let right = e.type == .rightMouseDown || e.type == .rightMouseUp
                || (e.type == .leftMouseDown && e.modifierFlags.contains(.control))
            return right ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { pop(event) }
        override func mouseDown(with event: NSEvent) { pop(event) }   // ⌃-click
        private func pop(_ event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            guard let m = menuAt?(p) else { return }
            NSMenu.popUpContextMenu(m, with: event, for: self)
        }
    }

    func makeNSView(context: Context) -> Area {
        let v = Area()
        v.menuAt = menu
        return v
    }

    func updateNSView(_ v: Area, context: Context) { v.menuAt = menu }
}
