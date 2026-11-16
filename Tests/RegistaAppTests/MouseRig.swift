import AppKit
import AVFoundation
import ObjectiveC
import Testing
import SwiftUI
@testable import Regista

// Real mouse events for the app's views (#28, #29). The rendered states (ui.screenshot, ui-shots) show what a view
// draws, never what a click does: a control can look right and be dead, or pass its click to what lies under it. A
// MouseRig hosts a view in a window and sends it the events a mouse and a keyboard send, through the window, the way
// AppKit does. It also reads the view's accessibility tree (role, label, frame of every element), so a test can click
// a control by its name and the click audit (ClickAudit.swift) can find every control of a screen by itself.

/// Every suite that hosts windows and sends them events (the mouse suites and the click audits) is a member of this
/// one serialized suite: they share the key window, the event queue, the guard's record and the app's defaults, so they
/// run one at a time (beside the rest of the tests).
@Suite(.serialized) struct MouseSuites {}

/// A window that can be key, so its content behaves as in the frontmost window of the app.
final class RigWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

extension NSApplication {
    @objc fileprivate var rig_isActive: Bool { true }
}

@MainActor
final class MouseRig {
    let window: NSWindow
    let size: CGSize
    var host: NSView { window.contentView! }

    /// The test process is never the active app, and a window of an inactive app cannot be key: drags are then
    /// swallowed as soon as a focusable control (a slider, a text field) is on screen, which no user ever sees. The
    /// process reports itself active for the tests (nothing is activated on screen: the user's frontmost app keeps
    /// the keyboard), so the rig's window becomes key like the app's own.
    private static var active = false
    private static func reportActive() {
        guard !active else { return }
        active = true
        _ = NSApplication.shared
        guard let real = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.isActive)),
              let fake = class_getInstanceMethod(NSApplication.self, #selector(getter: NSApplication.rig_isActive)) else { return }
        method_exchangeImplementations(real, fake)
        RigGuard.install()
        // SwiftUI builds its accessibility tree only for an assistive client: this is what such a client sets.
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    /// Whether this rig set the words' language (it puts it back on close).
    private var speaks = false

    /// `language` (it, en, fr, pt): the window's views read their words in that language; nil, in the test process's own
    /// (the Italian keys). The language holds while the rig is open, for the code the window runs (SwiftUI's updates, the
    /// main queue's blocks) and the test that hosts it; the other tests running beside it keep the Italian keys
    /// (`Test.current` tells them apart: SwiftUI's work runs outside every test's task).
    init<V: View>(_ view: V, size: CGSize, language: String? = nil) {
        Self.reportActive()
        self.size = size
        if let language {
            let test = Test.current?.id
            Words.override = Self.table(language)
            Words.applies = { Test.current == nil || Test.current?.id == test }
            speaks = true
        }
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        window = RigWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        // No ordering animation: its end stops the running run loop, which may be the test runner's own.
        window.animationBehavior = .none
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Gestures only see the events of a window that is on screen: this one is ordered in far outside every display.
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        pump(0.1)
    }

    /// Whether the window is one the code under test opened (`adopting`): closing the rig leaves it alone.
    private var adopted = false

    /// Drives a window the code under test opened (a popover's, a panel's): its events and its accessibility tree, as
    /// for the rig's own window.
    init(adopting window: NSWindow) {
        self.window = window
        size = window.contentView?.bounds.size ?? window.frame.size
        adopted = true
    }

    /// The app's words in `language`: Resources/Localization/<language>.lproj.
    nonisolated static func table(_ language: String) -> Bundle {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localization/\(language).lproj")
        guard let bundle = Bundle(path: dir.path) else { fatalError("no table for \(language) at \(dir.path)") }
        return bundle
    }

    func close() {
        if adopted { return }
        if let sheet = window.attachedSheet {
            window.endSheet(sheet)
            hold()
        }
        window.orderOut(nil)
        window.contentView = nil
        if speaks {
            Words.override = nil
            Words.applies = nil
            speaks = false
        }
    }

    /// Mouse suites of other files run beside this one and their rigs take the key window at their turn: the window
    /// that gets the next event takes it back first (a window that is not key swallows drags).
    func takeKey() {
        if !window.isKeyWindow { window.makeKey() }
    }

    /// Runs the blocks queued on the main run loop in nested loops of ours. Reading the accessibility tree, posting an
    /// event or asking for one can queue a block that stops the running loop: run while the test awaits, it would stop
    /// the test runner's own loop and end the process.
    func drain() {
        for _ in 0..<3 { CFRunLoopRunInMode(.defaultMode, 0.005, false) }
    }

    /// Turns the main run loop for `seconds` in nested loops of ours: an alert sheet's opening or closing animation stops
    /// the running loop when it ends, which must be one of these, never the test runner's (#40).
    func hold(_ seconds: Double = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
    }

    /// Lets the main run loop turn (SwiftUI updates, main-queue work).
    func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Pumps until `condition` holds (at most `timeout` seconds); returns whether it did.
    @discardableResult
    func wait(_ timeout: Double = 2, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { return false }
            pump(0.02)
        }
        return true
    }

    // MARK: Mouse

    /// A mouse event at a point of the view (top-left origin).
    func event(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        let up = type == .leftMouseUp || type == .rightMouseUp
        return NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: size.height - p.y), modifierFlags: modifiers,
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                  eventNumber: 0, clickCount: clicks, pressure: up ? 0 : 1)
    }

    /// One mouse event at a point of the view (top-left origin).
    func send(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        guard let e = event(type, p, clicks: clicks, modifiers: modifiers) else { return }
        takeKey()
        deliver(e, to: window)
        pump(0.02)
    }

    /// Gives `e` to `w` as AppKit's own loop does: while it is handled it is the application's current event, so code
    /// that reads the click's own modifier keys (NSEvent.clickModifiers) finds the ones this event carries, never the
    /// keyboard of the person running the tests (#36). The current event is put back afterwards.
    func deliver(_ e: NSEvent, to w: NSWindow) {
        let previous = NSApp.currentEvent
        NSApp.setValue(e, forKey: "currentEvent")
        w.sendEvent(e)
        NSApp.setValue(previous, forKey: "currentEvent")
    }

    /// The AppKit view a mouse event at `p` goes to.
    func viewAt(_ p: CGPoint) -> NSView? {
        let inWindow = CGPoint(x: p.x, y: size.height - p.y)
        guard let frame = host.superview else { return host.hitTest(inWindow) }
        return frame.hitTest(frame.convert(inWindow, from: nil))
    }

    /// Press and release at a point. Over an AppKit control or text view (a SwiftUI text field), the release goes
    /// through the event queue as from a real mouse; anywhere else both are sent to the window one after the other
    /// (SwiftUI's gestures see them there). Settings' system form is only partly driven this way (see WindowsClickTests).
    func click(_ p: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = []) {
        let sheet = window.attachedSheet
        defer { if window.attachedSheet !== sheet { hold() } }
        let target = viewAt(p)
        takeKey()
        if target is NSText || target is NSControl, let up = event(.leftMouseUp, p, clicks: clicks, modifiers: modifiers),
           let down = event(.leftMouseDown, p, clicks: clicks, modifiers: modifiers) {
            // The release waits in the event queue, where a control that tracks the mouse in a loop of its own until the
            // button goes up takes it, as from a real mouse; if nothing took it, it is sent after the press. Posting
            // stops the running run loop: a nested one of ours, never the test runner's loop (it would end the process).
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { [self, window] in
                NSApp.postEvent(up, atStart: false)
                deliver(down, to: window)
            }
            CFRunLoopRunInMode(.defaultMode, 0.3, false)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                deliver(pending, to: window)
            }
            drain()
        } else {
            send(.leftMouseDown, p, clicks: clicks, modifiers: modifiers)
            send(.leftMouseUp, p, clicks: clicks, modifiers: modifiers)
        }
        pump()
    }

    /// The buttons of the alert attached to the window as a sheet (a confirmation dialog, an alert), left to right;
    /// empty when none is shown or the sheet is not an alert.
    func sheetButtons() -> [NSButton] {
        // Only an alert (a SwiftUI sheet is a screen of its own).
        guard let sheet = window.attachedSheet, String(describing: Swift.type(of: sheet)).contains("Alert"), let content = sheet.contentView else { return [] }
        func buttons(_ v: NSView) -> [NSButton] { v.subviews.flatMap { s in (s as? NSButton).map { [$0] } ?? buttons(s) } }
        return buttons(content).filter { !$0.isHidden && !$0.title.isEmpty && $0.isEnabled }.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// A click on a button of the attached alert sheet, as `click` sends one to an AppKit control: the press to the sheet,
    /// the release through the event queue.
    func click(_ button: NSButton) {
        guard let sheet = button.window else { return }
        let p = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
        func e(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: sheet.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        guard let down = e(.leftMouseDown), let up = e(.leftMouseUp) else { return }
        // Posting stops the running run loop: a nested one of ours (see `click`).
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            NSApp.postEvent(up, atStart: false)
            sheet.sendEvent(down)
        }
        CFRunLoopRunInMode(.defaultMode, 0.3, false)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            sheet.sendEvent(pending)
        }
        drain()
        hold()
    }

    /// Two clicks at a point, the second with a click count of 2 (what a double-click sends).
    func doubleClick(_ p: CGPoint) {
        click(p, clicks: 1)
        click(p, clicks: 2)
    }

    /// A right click as AppKit delivers it: through the event queue, so the views that read `NSApp.currentEvent` see it
    /// (a context menu area does); the menu that opens is recorded by RigGuard instead of tracked.
    func rightClick(_ p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        guard let down = event(.rightMouseDown, p, modifiers: modifiers), let up = event(.rightMouseUp, p, modifiers: modifiers) else { return }
        takeKey()
        // Posting stops the running run loop: a nested one of ours (see `click`).
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            NSApp.postEvent(down, atStart: false)
            NSApp.postEvent(up, atStart: false)
        }
        CFRunLoopRunInMode(.defaultMode, 0.3, false)
        // Taken from the queue (it becomes NSApp.currentEvent), then given to the window.
        while let e = NSApp.nextEvent(matching: [.rightMouseDown, .rightMouseUp], until: .distantPast, inMode: .default, dequeue: true) {
            window.sendEvent(e)
        }
        drain()
        pump()
    }

    /// Press at `from`, move by `delta` in ten steps, release.
    func drag(from: CGPoint, by delta: CGSize, modifiers: NSEvent.ModifierFlags = [], release: Bool = true) {
        send(.leftMouseDown, from, modifiers: modifiers)
        for i in 1...10 {
            let f = Double(i) / 10
            send(.leftMouseDragged, CGPoint(x: from.x + delta.width * f, y: from.y + delta.height * f), modifiers: modifiers)
        }
        if release { send(.leftMouseUp, CGPoint(x: from.x + delta.width, y: from.y + delta.height), modifiers: modifiers) }
        pump()
    }

    /// A scroll-wheel turn at a point (positive `dy` scrolls the content down, as a trackpad swipe up does).
    /// Scrolls the scroll view under `p` by `dy` points (positive: towards its end), as the wheel would, and says whether
    /// it moved. A synthetic wheel event does not move a SwiftUI scroll view in this window, which lies outside every
    /// display (tried: pixel, line and phased events, sent through the window and to the scroll view itself), so the
    /// scroll view's own clip view is moved, within its content (#50).
    @discardableResult
    func scrollContent(at p: CGPoint, by dy: CGFloat) -> Bool {
        var v = viewAt(p)
        while let x = v, !(x is NSScrollView) { v = x.superview }
        guard let sv = v as? NSScrollView, let doc = sv.documentView else { return false }
        let clip = sv.contentView
        let maxY = max(0, doc.frame.height - clip.bounds.height)
        let from = clip.bounds.origin.y
        let to = min(max(from + (doc.isFlipped ? dy : -dy), 0), maxY)
        guard abs(to - from) > 0.5 else { return false }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: to))
        sv.reflectScrolledClipView(clip)
        pump(0.05)
        return true
    }

    func scroll(at p: CGPoint, dx: Int32 = 0, dy: Int32, modifiers: NSEvent.ModifierFlags = []) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else { return }
        let screen = window.convertPoint(toScreen: CGPoint(x: p.x, y: size.height - p.y))
        // CGEvent locations are top-left based on the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
        cg.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        guard let e = NSEvent(cgEvent: cg) else { return }
        window.sendEvent(e)
        pump(0.05)
    }

    // MARK: Keyboard

    /// A key press through the application (local event monitors see it, then the key window's first responder).
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        takeKey()
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: characters,
                                           charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { continue }
            NSApp.sendEvent(e)
            pump(0.02)
        }
        pump()
    }

    enum Key {
        case returnKey, escape, space, tab, delete, left, right, up, down, home, end
        var code: UInt16 {
            switch self {
            case .returnKey: 36
            case .escape: 53
            case .space: 49
            case .tab: 48
            case .delete: 51
            case .left: 123
            case .right: 124
            case .down: 125
            case .up: 126
            case .home: 115
            case .end: 119
            }
        }
        var characters: String {
            switch self {
            case .returnKey: "\r"
            case .escape: "\u{1b}"
            case .space: " "
            case .tab: "\t"
            case .delete: "\u{7f}"
            case .left: String(UnicodeScalar(NSLeftArrowFunctionKey)!)
            case .right: String(UnicodeScalar(NSRightArrowFunctionKey)!)
            case .up: String(UnicodeScalar(NSUpArrowFunctionKey)!)
            case .down: String(UnicodeScalar(NSDownArrowFunctionKey)!)
            case .home: String(UnicodeScalar(NSHomeFunctionKey)!)
            case .end: String(UnicodeScalar(NSEndFunctionKey)!)
            }
        }
    }

    func key(_ k: Key, modifiers: NSEvent.ModifierFlags = []) { key(k.characters, keyCode: k.code, modifiers: modifiers) }

    /// Types a text into the first responder, one key event per character.
    func type(_ text: String) {
        for c in text { key(String(c), keyCode: 0) }
    }

    /// The window's first responder is a text editor (a field being typed in).
    var isTyping: Bool { window.firstResponder is NSText }

    // MARK: Accessibility

    /// Every element of the hosted view's accessibility tree, depth first, with its frame in view coordinates.
    func elements() -> [RigElement] {
        var out: [RigElement] = []
        let bounds = CGRect(origin: .zero, size: size)
        func walk(_ node: AnyObject, clip: CGRect, depth: Int, parent: String) {
            for child in (node.accessibilityChildren?() ?? nil) ?? [] {
                let o = child as AnyObject
                let role = (o.accessibilityRole?() ?? nil)?.rawValue ?? ""
                let screen = o.accessibilityFrame?() ?? .zero
                let inWindow = window.convertFromScreen(screen)
                let frame = CGRect(x: inWindow.minX, y: size.height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
                let value: String = {
                    let get = NSSelectorFromString("accessibilityValue")
                    guard o.responds(to: get), let v = o.perform(get)?.takeUnretainedValue() else { return "" }
                    if let s = v as? String { return s }
                    if let n = v as? NSNumber { return n.stringValue }
                    if let a = v as? NSAttributedString { return a.string }
                    return "\(v)"
                }()
                // SwiftUI gives the value of an element of its own (a slider, an intensity bar: AXUnknown) as its value
                // description, which is what an assistive client reads there (#36).
                let valueDescription: String = {
                    let get = NSSelectorFromString("accessibilityValueDescription")
                    guard o.responds(to: get), let v = o.perform(get)?.takeUnretainedValue() else { return "" }
                    return (v as? String) ?? (v as? NSAttributedString)?.string ?? ""
                }()
                let actions: [String] = {
                    let get = NSSelectorFromString("accessibilityActionNames")
                    guard o.responds(to: get), let v = o.perform(get)?.takeUnretainedValue() as? [String] else { return [] }
                    return v
                }()
                let shown = frame.intersection(clip)
                let e = RigElement(ref: o, role: role, label: (o.accessibilityLabel?() ?? nil) ?? "", value: value,
                                   title: (o.accessibilityTitle?() ?? nil) ?? "", frame: frame, enabled: o.isAccessibilityEnabled?() ?? true,
                                   selected: o.isAccessibilitySelected?() ?? false, visible: !shown.isNull && shown.width >= 2 && shown.height >= 2 && clip.contains(CGPoint(x: frame.midX, y: frame.midY)),
                                   depth: depth, actions: actions, parentRole: parent, clip: clip, valueDescription: valueDescription)
                out.append(e)
                // A scroll area clips its content: what lies outside it is not on screen.
                walk(o, clip: role == NSAccessibility.Role.scrollArea.rawValue ? clip.intersection(frame) : clip, depth: depth + 1, parent: role)
            }
        }
        walk(host, clip: bounds, depth: 0, parent: "")
        drain()
        return out
    }

    /// The interactive elements on screen (buttons, switches, sliders, fields, links…).
    func controls() -> [RigElement] { elements().filter { $0.isControl && $0.visible } }

    /// The first element (or the `index`-th) whose label, title or value is `name`, optionally of a role.
    func element(_ name: String, role: String? = nil, index: Int = 0) -> RigElement? {
        let matches = elements().filter { ($0.label == name || $0.title == name || $0.value == name) && (role == nil || $0.role == role) && $0.visible }
        return index < matches.count ? matches[index] : nil
    }

    /// Elements whose label (or title, or value) contains `text`.
    func elements(containing text: String) -> [RigElement] {
        elements().filter { $0.visible && ($0.label.contains(text) || $0.title.contains(text) || $0.value.contains(text)) }
    }

    /// Clicks the centre of the element named `name`; false when there is none on screen.
    @discardableResult
    func click(_ name: String, role: String? = nil, index: Int = 0, modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let e = element(name, role: role, index: index) else { return false }
        click(e.centre, modifiers: modifiers)
        return true
    }

    /// The deepest accessibility element at a point of the view (what an assistive client finds there).
    func elementAt(_ p: CGPoint) -> AnyObject? {
        let screen = window.convertPoint(toScreen: CGPoint(x: p.x, y: size.height - p.y))
        let hit = host.accessibilityHitTest(screen) as AnyObject?
        drain()
        return hit
    }
}

/// One element of the accessibility tree, its frame in the hosted view's coordinates (top-left origin).
struct RigElement: CustomStringConvertible {
    let ref: AnyObject
    let role: String
    let label: String
    let value: String
    let title: String
    let frame: CGRect
    let enabled: Bool
    let selected: Bool
    /// Its centre (where a click goes) inside the window and its scroll areas.
    let visible: Bool
    let depth: Int
    /// The accessibility actions it answers (AXPress for anything with a tap action).
    var actions: [String] = []
    /// The role of the element it belongs to.
    var parentRole = ""
    /// What of the window can show it: the window, or the scroll areas around it (they clip what lies past their edges).
    var clip: CGRect = .infinite
    /// The value as an assistive client reads it on an element of SwiftUI's own (a slider's "14 Mbps"), where
    /// `value` is empty. Not part of the name: a control keeps its key while its value moves.
    var valueDescription = ""

    var centre: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    /// What a person reads on it.
    var name: String { [label, title, value].first { !$0.isEmpty } ?? "" }

    static let controlRoles: Set<String> = ["AXButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXIncrementor", "AXTextField",
                                            "AXTextArea", "AXPopUpButton", "AXMenuButton", "AXLink", "AXDisclosureTriangle",
                                            "AXComboBox", "AXSearchField", "AXColorWell", "AXSegment", "AXTab"]
    var isControl: Bool {
        // The parts of AppKit's scrollers (overlay scrollbars, hidden until scrolling) belong to the scroll view.
        if parentRole == "AXScrollBar" || role == "AXScrollBar" { return false }
        if Self.controlRoles.contains(role) { return true }
        // SwiftUI's sliders and splitters come as unknown elements.
        return role == "AXUnknown" && frame.width > 4 && frame.height > 4
    }

    /// A short line for tables: role without the AX prefix and the name.
    var description: String {
        let r = role.hasPrefix("AX") ? String(role.dropFirst(2)) : role
        let n = name.replacingOccurrences(of: "\n", with: " ")
        return n.isEmpty ? "\(r) (no name)" : "\(r) «\(n.count > 70 ? String(n.prefix(70)) + "…" : n)»"
    }

    /// The key that finds the same control again after the view was rebuilt: role and name.
    var key: String { "\(role)|\(name)" }
}

// MARK: - Side effects of a click

/// What a click does outside the window: a modal open/save panel or alert (each would block the test until a person
/// answers), a URL or a Finder window opened, another window put on screen, a context menu, a quit. The guard answers
/// the modal ones itself (Cancel, unless told otherwise), never opens a URL, never quits, moves every other window the
/// code shows far outside the displays (so nothing appears on the screen of the person running the tests), and
/// records each. It also mutes every player: nothing is heard. Under the rig's stand-ins (RigIsolation.swift) it is the
/// net (#35): every process the code starts is checked against RigProcesses' allow-list (a refused one does not start,
/// fails its caller and is a test failure), and an item sent to the Trash goes to a scratch folder instead.
@MainActor
enum RigGuard {
    struct Event: Equatable, CustomStringConvertible {
        enum Kind: String { case panel, alert, url, finder, window, menu, quit }
        let kind: Kind
        let detail: String
        var description: String { "\(kind.rawValue): \(detail)" }
    }

    static var events: [Event] = []
    /// How the next modal alerts are answered (Annulla, the second button, by default).
    static var alertAnswer: NSApplication.ModalResponse = .alertSecondButtonReturn
    /// The last context menu that would have opened (its items can be run with `NSMenu.performActionForItem(at:)`).
    static var lastMenu: NSMenu?
    /// What the next open or save panel answers: these files, as if the person had picked them and clicked Open or Save.
    /// One panel only; then (and by default) a panel is answered Cancel.
    static var panelAnswer: [URL]?

    static func record(_ kind: Event.Kind, _ detail: String) { events.append(Event(kind: kind, detail: detail)) }

    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        swap(NSSavePanel.self, #selector(NSSavePanel.runModal), #selector(NSSavePanel.rig_runModal))
        guardPanelAnswers()
        swap(NSAlert.self, #selector(NSAlert.runModal), #selector(NSAlert.rig_runModal))
        swap(NSWorkspace.self, #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool), #selector(NSWorkspace.rig_open(_:)))
        swap(NSWorkspace.self, #selector(NSWorkspace.activateFileViewerSelecting(_:)), #selector(NSWorkspace.rig_activateFileViewerSelecting(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.rig_orderFrontRegardless))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.rig_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.rig_orderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.order(_:relativeTo:)), #selector(NSWindow.rig_order(_:relativeTo:)))
        swap(NSWindow.self, #selector(NSWindow.constrainFrameRect(_:to:)), #selector(NSWindow.rig_constrainFrameRect(_:to:)))
        // A sheet's opening and closing animations stop the running run loop when they end (#40): whoever opens or
        // closes one (an alert of a failed command, a confirmation), a loop of ours turns until they are over.
        swap(NSWindow.self, #selector(NSWindow.beginSheet(_:completionHandler:)), #selector(NSWindow.rig_beginSheet(_:completionHandler:)))
        swap(NSWindow.self, #selector(NSWindow.beginCriticalSheet(_:completionHandler:)), #selector(NSWindow.rig_beginCriticalSheet(_:completionHandler:)))
        swap(NSWindow.self, #selector(NSWindow.endSheet(_:)), #selector(NSWindow.rig_endSheet(_:)))
        swap(NSWindow.self, #selector(NSWindow.endSheet(_:returnCode:)), #selector(NSWindow.rig_endSheet(_:returnCode:)))
        swap(NSMenu.self, #selector(NSMenu.popUp(positioning:at:in:)), #selector(NSMenu.rig_popUp(positioning:at:in:)))
        // Nothing is heard on the machine running the tests: every player the code starts is muted first (it still
        // plays, so the playhead and the "playing" states move as in the app).
        swap(AVPlayer.self, #selector(AVPlayer.play), #selector(AVPlayer.rig_play))
        swap(AVPlayer.self, #selector(setter: AVPlayer.rate), #selector(AVPlayer.rig_setRate(_:)))
        swap(AVAudioPlayer.self, #selector(AVAudioPlayer.play as (AVAudioPlayer) -> () -> Bool), #selector(AVAudioPlayer.rig_play))
        // A click must never end the test run: a quit is recorded, not obeyed (the process would exit with 0 and the
        // tests not yet run would be missing from a run that looks green). Any other exit than the test runner's own,
        // at the end of the run, prints where it came from. One such exit is known and not prevented here: the test
        // runner's main loop is a bare CFRunLoopRun followed by exit(0), and a stop that AppKit queues while a test
        // awaits ends it (`drain` absorbs most of them). scripts/test.sh sees a run without its summary and runs the
        // suite once more; it is never counted as green.
        swap(NSApplication.self, #selector(NSApplication.terminate(_:)), #selector(NSApplication.rig_terminate(_:)))
        guardProcesses()
        guardTrash()
        guardPasteboard()
        atexit {
            let stack = Thread.callStackSymbols
            guard !stack.contains(where: { $0.contains("RunnerV4main") }) else { return }
            FileHandle.standardError.write(Data(("MouseRig: the test process is exiting from inside a test:\n" + stack.joined(separator: "\n") + "\n").utf8))
        }
        if let real = class_getClassMethod(NSMenu.self, #selector(NSMenu.popUpContextMenu(_:with:for:))),
           let fake = class_getClassMethod(NSMenu.self, #selector(NSMenu.rig_popUpContextMenu(_:with:for:))) {
            method_exchangeImplementations(real, fake)
        }
        // SwiftUI's context menus reach AppKit's private entry (NSView's menu for a right click): recorded, never tracked.
        let privateEntry = NSSelectorFromString("_popUpContextMenu:withEvent:forView:withFont:")
        if let m = class_getInstanceMethod(NSMenu.self, privateEntry) {
            let block: @convention(block) (AnyObject, AnyObject, NSEvent, NSView, NSFont?) -> Void = { this, first, _, _, _ in
                MainActor.assumeIsolated {
                    guard let menu = (first as? NSMenu) ?? (this as? NSMenu) else { return }
                    RigGuard.lastMenu = menu
                    RigGuard.record(.menu, menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: " · "))
                }
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
    }

    /// A panel answered with `panelAnswer` gives those files to whoever reads its `url` or `urls` (an open or save panel
    /// never shown has none of its own).
    private static func guardPanelAnswers() {
        typealias Get = @convention(c) (AnyObject, Selector) -> AnyObject?
        for (cls, name) in [(NSSavePanel.self, "URL"), (NSOpenPanel.self, "URL"), (NSOpenPanel.self, "URLs")] as [(AnyClass, String)] {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            let original = unsafeBitCast(method_getImplementation(m), to: Get.self)
            let block: @convention(block) (AnyObject) -> AnyObject? = { panel in
                if let answer = objc_getAssociatedObject(panel, &panelAnswerKey) as? [URL] {
                    return name == "URLs" ? answer as NSArray : answer.first as NSURL?
                }
                return original(panel, sel)
            }
            let imp = imp_implementationWithBlock(block)
            // A class that only inherits the getter gets its own copy; one that defines it is changed in place.
            if !class_addMethod(cls, sel, imp, method_getTypeEncoding(m)) { method_setImplementation(m, imp) }
        }
    }

    /// Every Process (NSTask) the code runs goes through `-launchAndReturnError:` (Process.run): checked there.
    private static func guardProcesses() {
        typealias Launch = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool
        let sel = NSSelectorFromString("launchAndReturnError:")
        // The concrete class the instances have, and the public one (each keeps its own original).
        let concrete: AnyClass = object_getClass(Process()) ?? Process.self
        for cls in concrete === Process.self ? [concrete] : [concrete, Process.self] {
            guard let m = class_getInstanceMethod(cls, sel) else { continue }
            let original = unsafeBitCast(method_getImplementation(m), to: Launch.self)
            let block: @convention(block) (AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool = { task, error in
                let p = task as? Process
                let exe = p?.executableURL?.path ?? p?.launchPath ?? "?"
                if let why = RigProcesses.check(exe, p?.arguments ?? []) {
                    error?.pointee = NSError(domain: "RigGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: "the test rig refused to start \(exe): \(why)"])
                    return false
                }
                return original(task, sel, error)
            }
            let imp = imp_implementationWithBlock(block)
            // A class that only inherits the method gets its own copy; one that defines it is changed in place.
            if !class_addMethod(cls, sel, imp, method_getTypeEncoding(m)) { method_setImplementation(m, imp) }
        }
    }

    /// The Trash of the person running the tests is never written: an item sent there goes to RigTrash.folder.
    private static func guardTrash() {
        typealias Trash = @convention(c) (AnyObject, Selector, NSURL, AutoreleasingUnsafeMutablePointer<NSURL?>?, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool
        let sel = NSSelectorFromString("trashItemAtURL:resultingItemURL:error:")
        guard let m = class_getInstanceMethod(FileManager.self, sel) else { return }
        let block: @convention(block) (AnyObject, NSURL, AutoreleasingUnsafeMutablePointer<NSURL?>?, AutoreleasingUnsafeMutablePointer<NSError?>?) -> ObjCBool = { _, url, out, error in
            do {
                let moved = try RigTrash.take(url as URL)
                out?.pointee = moved as NSURL
                return true
            } catch let e as NSError {
                error?.pointee = e
                return false
            }
        }
        method_setImplementation(m, imp_implementationWithBlock(block))
    }

    /// The general pasteboard (the clipboard of the person running the tests) is never written: a write is recorded in
    /// RigPasteboard.generalWrites and refused.
    private static func guardPasteboard() {
        func refuse<Block>(_ name: String, _ make: (@escaping (AnyObject) -> Bool, IMP) -> Block) {
            let sel = NSSelectorFromString(name)
            guard let m = class_getInstanceMethod(NSPasteboard.self, sel) else { return }
            let original = method_getImplementation(m)
            let isGeneral: (AnyObject) -> Bool = { board in
                guard (board as? NSPasteboard)?.name == .general else {
                    RigPasteboard.recordWrite()
                    return false
                }
                RigPasteboard.recordGeneralWrite(name)
                return true
            }
            method_setImplementation(m, imp_implementationWithBlock(make(isGeneral, original)))
        }
        typealias Clear = @convention(c) (AnyObject, Selector) -> Int
        refuse("clearContents") { general, imp -> @convention(block) (AnyObject) -> Int in
            { board in general(board) ? 0 : unsafeBitCast(imp, to: Clear.self)(board, NSSelectorFromString("clearContents")) }
        }
        typealias Set = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> ObjCBool
        for name in ["setString:forType:", "setData:forType:", "setPropertyList:forType:"] {
            refuse(name) { general, imp -> @convention(block) (AnyObject, AnyObject, AnyObject) -> ObjCBool in
                { board, value, type in general(board) ? false : unsafeBitCast(imp, to: Set.self)(board, NSSelectorFromString(name), value, type) }
            }
        }
        typealias Write = @convention(c) (AnyObject, Selector, AnyObject) -> ObjCBool
        refuse("writeObjects:") { general, imp -> @convention(block) (AnyObject, AnyObject) -> ObjCBool in
            { board, objects in general(board) ? false : unsafeBitCast(imp, to: Write.self)(board, NSSelectorFromString("writeObjects:"), objects) }
        }
    }

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let real = class_getInstanceMethod(cls, a), let fake = class_getInstanceMethod(cls, b) else { return }
        method_exchangeImplementations(real, fake)
    }

    /// Queues a nested loop of ours on the main run loop for the length of a sheet animation.
    static func holdForAnimation() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            let end = Date().addingTimeInterval(0.6)
            while Date() < end { CFRunLoopRunInMode(.defaultMode, 0.01, false) }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// A window the code under test shows: never seen and never in the way of the person at the Mac. It is moved off
    /// every display, and, because AppKit brings a titled window back onto a screen when it is ordered front (the
    /// teleprompter's panel kept appearing during the click audits), it is also made fully transparent and deaf to
    /// the mouse, and AppKit's frame constraint is switched off for the test process.
    static func offscreen(_ w: NSWindow) {
        guard !(w is RigWindow) else { return }
        w.alphaValue = 0
        w.ignoresMouseEvents = true
        if NSScreen.screens.contains(where: { $0.frame.intersects(w.frame) }) || w.frame.origin == .zero {
            w.setFrameOrigin(CGPoint(x: -30000, y: -30000))
        }
        record(.window, String(describing: type(of: w)) + (w.title.isEmpty ? "" : " «\(w.title)»"))
    }
}

nonisolated(unsafe) private var panelAnswerKey = 0

extension NSSavePanel {
    @objc fileprivate func rig_runModal() -> NSApplication.ModalResponse {
        MainActor.assumeIsolated {
            RigGuard.record(.panel, "\(type(of: self)) \(message.isEmpty ? title : message)")
            guard let answer = RigGuard.panelAnswer else { return .cancel }
            RigGuard.panelAnswer = nil
            objc_setAssociatedObject(self, &panelAnswerKey, answer, .OBJC_ASSOCIATION_RETAIN)
            return .OK
        }
    }
}

extension NSAlert {
    @objc fileprivate func rig_runModal() -> NSApplication.ModalResponse {
        MainActor.assumeIsolated {
            RigGuard.record(.alert, messageText)
            return RigGuard.alertAnswer
        }
    }
}

extension NSApplication {
    @objc fileprivate func rig_terminate(_ sender: Any?) {
        let stack = Thread.callStackSymbols.prefix(12).joined(separator: "\n")
        FileHandle.standardError.write(Data("MouseRig: a quit was asked for inside a test (recorded, not obeyed):\n\(stack)\n".utf8))
        MainActor.assumeIsolated { RigGuard.record(.quit, "NSApplication.terminate") }
    }
}

extension AVPlayer {
    @objc fileprivate func rig_play() {
        isMuted = true
        rig_play()
    }

    @objc fileprivate func rig_setRate(_ rate: Float) {
        isMuted = true
        rig_setRate(rate)
    }
}

extension AVAudioPlayer {
    @objc fileprivate func rig_play() -> Bool {
        volume = 0
        return rig_play()
    }
}

extension NSWorkspace {
    @objc fileprivate func rig_open(_ url: URL) -> Bool {
        MainActor.assumeIsolated { RigGuard.record(.url, url.absoluteString) }
        return true
    }

    @objc fileprivate func rig_activateFileViewerSelecting(_ urls: [URL]) {
        MainActor.assumeIsolated { RigGuard.record(.finder, urls.map(\.lastPathComponent).joined(separator: ", ")) }
    }
}

extension NSWindow {
    @objc fileprivate func rig_orderFrontRegardless() {
        MainActor.assumeIsolated { RigGuard.offscreen(self) }
        rig_orderFrontRegardless()
    }

    @objc fileprivate func rig_makeKeyAndOrderFront(_ sender: Any?) {
        MainActor.assumeIsolated { RigGuard.offscreen(self) }
        rig_makeKeyAndOrderFront(sender)
    }

    @objc fileprivate func rig_beginSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?) {
        rig_beginSheet(sheet, completionHandler: completionHandler)
        MainActor.assumeIsolated { RigGuard.holdForAnimation() }
    }

    @objc fileprivate func rig_beginCriticalSheet(_ sheet: NSWindow, completionHandler: ((NSApplication.ModalResponse) -> Void)?) {
        rig_beginCriticalSheet(sheet, completionHandler: completionHandler)
        MainActor.assumeIsolated { RigGuard.holdForAnimation() }
    }

    @objc fileprivate func rig_endSheet(_ sheet: NSWindow) {
        rig_endSheet(sheet)
        MainActor.assumeIsolated { RigGuard.holdForAnimation() }
    }

    @objc fileprivate func rig_endSheet(_ sheet: NSWindow, returnCode: NSApplication.ModalResponse) {
        rig_endSheet(sheet, returnCode: returnCode)
        MainActor.assumeIsolated { RigGuard.holdForAnimation() }
    }

    @objc fileprivate func rig_orderFront(_ sender: Any?) {
        MainActor.assumeIsolated { RigGuard.offscreen(self) }
        rig_orderFront(sender)
    }

    @objc fileprivate func rig_order(_ place: NSWindow.OrderingMode, relativeTo other: Int) {
        if place != .out { MainActor.assumeIsolated { RigGuard.offscreen(self) } }
        rig_order(place, relativeTo: other)
    }

    /// No window is brought back onto a screen in the test process.
    @objc fileprivate func rig_constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

extension NSMenu {
    @objc fileprivate func rig_popUp(positioning item: NSMenuItem?, at location: NSPoint, in view: NSView?) -> Bool {
        MainActor.assumeIsolated {
            RigGuard.lastMenu = self
            RigGuard.record(.menu, items.map(\.title).filter { !$0.isEmpty }.joined(separator: " · "))
        }
        return false
    }

    @objc fileprivate class func rig_popUpContextMenu(_ menu: NSMenu, with event: NSEvent, for view: NSView) {
        MainActor.assumeIsolated {
            RigGuard.lastMenu = menu
            RigGuard.record(.menu, menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }
}
