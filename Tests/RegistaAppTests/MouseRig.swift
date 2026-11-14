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

    init<V: View>(_ view: V, size: CGSize) {
        Self.reportActive()
        self.size = size
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

    func close() {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.orderOut(nil)
        window.contentView = nil
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
        window.sendEvent(e)
        pump(0.02)
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
        let target = viewAt(p)
        takeKey()
        if target is NSText || target is NSControl, let up = event(.leftMouseUp, p, clicks: clicks, modifiers: modifiers),
           let down = event(.leftMouseDown, p, clicks: clicks, modifiers: modifiers) {
            // The release waits in the event queue, where a control that tracks the mouse in a loop of its own until the
            // button goes up takes it, as from a real mouse; if nothing took it, it is sent after the press. Posting
            // stops the running run loop: a nested one of ours, never the test runner's loop (it would end the process).
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { [window] in
                NSApp.postEvent(up, atStart: false)
                window.sendEvent(down)
            }
            CFRunLoopRunInMode(.defaultMode, 0.3, false)
            if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(pending)
            }
            drain()
        } else {
            send(.leftMouseDown, p, clicks: clicks, modifiers: modifiers)
            send(.leftMouseUp, p, clicks: clicks, modifiers: modifiers)
        }
        pump()
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
                let actions: [String] = {
                    let get = NSSelectorFromString("accessibilityActionNames")
                    guard o.responds(to: get), let v = o.perform(get)?.takeUnretainedValue() as? [String] else { return [] }
                    return v
                }()
                let shown = frame.intersection(clip)
                let e = RigElement(ref: o, role: role, label: (o.accessibilityLabel?() ?? nil) ?? "", value: value,
                                   title: (o.accessibilityTitle?() ?? nil) ?? "", frame: frame, enabled: o.isAccessibilityEnabled?() ?? true,
                                   selected: o.isAccessibilitySelected?() ?? false, visible: !shown.isNull && shown.width >= 2 && shown.height >= 2 && clip.contains(CGPoint(x: frame.midX, y: frame.midY)),
                                   depth: depth, actions: actions, parentRole: parent)
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
/// records each. It also mutes every player: nothing is heard.
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

    static func record(_ kind: Event.Kind, _ detail: String) { events.append(Event(kind: kind, detail: detail)) }

    private static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        swap(NSSavePanel.self, #selector(NSSavePanel.runModal), #selector(NSSavePanel.rig_runModal))
        swap(NSAlert.self, #selector(NSAlert.runModal), #selector(NSAlert.rig_runModal))
        swap(NSWorkspace.self, #selector(NSWorkspace.open(_:) as (NSWorkspace) -> (URL) -> Bool), #selector(NSWorkspace.rig_open(_:)))
        swap(NSWorkspace.self, #selector(NSWorkspace.activateFileViewerSelecting(_:)), #selector(NSWorkspace.rig_activateFileViewerSelecting(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFrontRegardless), #selector(NSWindow.rig_orderFrontRegardless))
        swap(NSWindow.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.rig_makeKeyAndOrderFront(_:)))
        swap(NSWindow.self, #selector(NSWindow.orderFront(_:)), #selector(NSWindow.rig_orderFront(_:)))
        swap(NSMenu.self, #selector(NSMenu.popUp(positioning:at:in:)), #selector(NSMenu.rig_popUp(positioning:at:in:)))
        // Nothing is heard on the machine running the tests: every player the code starts is muted first (it still
        // plays, so the playhead and the "playing" states move as in the app).
        swap(AVPlayer.self, #selector(AVPlayer.play), #selector(AVPlayer.rig_play))
        swap(AVPlayer.self, #selector(setter: AVPlayer.rate), #selector(AVPlayer.rig_setRate(_:)))
        swap(AVAudioPlayer.self, #selector(AVAudioPlayer.play as (AVAudioPlayer) -> () -> Bool), #selector(AVAudioPlayer.rig_play))
        // The test runner's main loop is a bare CFRunLoopRun followed by exit(0): one stop reaching it ends the process
        // with a green exit code and the tests not yet run missing. AppKit stops the running loop for ordinary reasons
        // (an event posted, the accessibility tree read), which an app's own loop simply survives. So the runner's loop
        // is never the one running: from here on the main thread stays in this loop of ours, which starts again when
        // stopped. It is a run loop block, not a main-queue block, so the main queue (the tests) is served inside it.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            while true {
                if CFRunLoopRunInMode(.defaultMode, 1e10, false) == .finished { usleep(1000) }
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
        // A click must never end the test run: a quit is recorded, not obeyed (the process would exit with 0 and the
        // tests not yet run would be missing from a run that looks green). Any other exit than the test runner's own,
        // at the end of the run, prints where it came from.
        swap(NSApplication.self, #selector(NSApplication.terminate(_:)), #selector(NSApplication.rig_terminate(_:)))
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

    private static func swap(_ cls: AnyClass, _ a: Selector, _ b: Selector) {
        guard let real = class_getInstanceMethod(cls, a), let fake = class_getInstanceMethod(cls, b) else { return }
        method_exchangeImplementations(real, fake)
    }

    /// A window the code under test shows: kept off every display.
    static func offscreen(_ w: NSWindow) {
        guard !(w is RigWindow) else { return }
        if NSScreen.screens.contains(where: { $0.frame.intersects(w.frame) }) || w.frame.origin == .zero {
            w.setFrameOrigin(CGPoint(x: -30000, y: -30000))
        }
        record(.window, String(describing: type(of: w)) + (w.title.isEmpty ? "" : " «\(w.title)»"))
    }
}

extension NSSavePanel {
    @objc fileprivate func rig_runModal() -> NSApplication.ModalResponse {
        MainActor.assumeIsolated { RigGuard.record(.panel, "\(type(of: self)) \(message.isEmpty ? title : message)") }
        return .cancel
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

    @objc fileprivate func rig_orderFront(_ sender: Any?) {
        MainActor.assumeIsolated { RigGuard.offscreen(self) }
        rig_orderFront(sender)
    }
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
