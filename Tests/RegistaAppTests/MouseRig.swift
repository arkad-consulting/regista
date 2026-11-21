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
    /// The main display, though the window stays off every display (#50): SwiftUI applies a wheel event on the refresh of
    /// its window's screen, and a window off every display has none, so the events were held. With this one they scroll
    /// where they are given, and the window never moves.
    override var screen: NSScreen? { super.screen ?? NSScreen.main ?? NSScreen.screens.first }
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
        // A press of the rig cannot wait for ever for its release (#102): see `press`. AppKit's private entry for the next
        // event is the one every loop reaches: `nextEventMatchingMask:…` calls it, and an alert's button calls it directly.
        let entry = NSSelectorFromString("_nextEventMatchingEventMask:untilDate:inMode:dequeue:")
        if let m = class_getInstanceMethod(NSApplication.self, entry) {
            typealias Next = @convention(c) (AnyObject, Selector, UInt64, NSDate?, NSString, ObjCBool) -> NSEvent?
            let original = unsafeBitCast(method_getImplementation(m), to: Next.self)
            let block: @convention(block) (AnyObject, UInt64, NSDate?, NSString, ObjCBool) -> NSEvent? = { app, mask, until, mode, dequeue in
                nonisolated(unsafe) var event: NSEvent?
                MainActor.assumeIsolated {
                    event = nextEvent(NSEvent.EventTypeMask(rawValue: mask), until: until as Date?, mode: RunLoop.Mode(mode as String), dequeue: dequeue.boolValue) { m, u, md, d in
                        original(app, entry, m.rawValue, u as NSDate?, md.rawValue as NSString, ObjCBool(d))
                    }
                }
                return event
            }
            method_setImplementation(m, imp_implementationWithBlock(block))
        }
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
        RigTrace.note("MouseRig.init \(Int(size.width))×\(Int(size.height))")
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
        RigTrace.note("MouseRig.close")
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
        for _ in 0..<3 { RigTrace.run("drain", 0.005) }
    }

    /// Turns the main run loop for `seconds` in nested loops of ours: an alert sheet's opening or closing animation stops
    /// the running loop when it ends, which must be one of these, never the test runner's (#40).
    func hold(_ seconds: Double = 0.6) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RigTrace.run("hold", 0.01) }
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
        RigTrace.note("MouseRig.send \(type.rawValue) at \(Int(p.x)),\(Int(p.y))")
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
    /// `name` names the control in a failure (the press that never returned, #102); by default the view under the point.
    func click(_ p: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = [], name: String? = nil) {
        RigTrace.note("MouseRig.click at \(Int(p.x)),\(Int(p.y))")
        let sheet = window.attachedSheet
        defer { if window.attachedSheet !== sheet { hold() } }
        let target = viewAt(p)
        takeKey()
        if let target, target is NSText || target is NSControl, let up = event(.leftMouseUp, p, clicks: clicks, modifiers: modifiers),
           let down = event(.leftMouseDown, p, clicks: clicks, modifiers: modifiers) {
            // The release waits in the event queue, where a control that tracks the mouse in a loop of its own until the
            // button goes up takes it, as from a real mouse; if nothing took it, it is sent after the press. Posting
            // stops the running run loop: a nested one of ours, never the test runner's loop (it would end the process).
            // Named only when it is needed (a fallback, a failure): reading the accessibility tree here queues work on the loop.
            let label = { name ?? Self.describe(target, at: p) }
            var released = false
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) { [self, window] in
                if !Self.loseNextRelease { NSApp.postEvent(up, atStart: false) }
                Self.loseNextRelease = false
                released = Self.press(label, release: up) { deliver(down, to: window) }
            }
            CFRunLoopRunInMode(.defaultMode, 0.3, false)
            Self.finish(up, released: released, label) { deliver($0, to: window) }
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
        var released = false
        let label = { "the alert's «\(button.title)»" }
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            if !Self.loseNextRelease { NSApp.postEvent(up, atStart: false) }
            Self.loseNextRelease = false
            released = Self.press(label, release: up) { sheet.sendEvent(down) }
        }
        CFRunLoopRunInMode(.defaultMode, 0.3, false)
        // An alert's button does not track the mouse: it acts on the release given to it after the press (#103).
        Self.finish(up, released: released, label) { sheet.sendEvent($0) }
        drain()
        hold()
    }

    // MARK: A press that cannot wait for ever (#102)

    /// A press being delivered: the control's name, its release, when it started, whether the release was handed to it.
    private struct Press {
        let name: () -> String
        let release: NSEvent
        let started: TimeInterval
        var handed = false
        /// The loop got a release (its own from the queue, or one handed to it): the time after it is the control's action.
        var released = false
    }
    private static var pressing: Press?
    /// After this long inside a press, its release is handed to the loop that tracks it (`nextEvent`).
    static let fallbackAfter: TimeInterval = 1
    /// A press that has not returned, nor got its release, after this long fails its test, with the control's name.
    static let pressDeadline: TimeInterval = 5
    /// Releases handed to a tracking loop because the one in the event queue never reached it.
    static var fallbackReleases = 0
    /// Releases from outside the rig (the real mouse's, with the screen locked) replaced by the press's own.
    static var foreignReleases = 0
    /// Other events of the real mouse (moves, drags) dropped during a press of the rig's.
    static var foreignEvents = 0
    /// The events a real mouse sends: during a press of the rig's, only the rig's own reach the control.
    private static let realMouse: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .mouseMoved]
    /// The next click over an AppKit control or an alert's button posts no release (the test of the fallback: a release
    /// lost on its way).
    static var loseNextRelease = false

    /// Delivers a press (`deliver`) whose release was posted to the event queue. A control that tracks the mouse in a
    /// loop of its own (a text field's text view, a button's cell) waits there for the release: two commit runs hung for
    /// 40 minutes in a text view's loop that never got it (#102). While the press is delivered, the loop's requests for
    /// events are watched (`nextEvent`): the loop gets the press's own release, written down in RigTrace and on stderr
    /// whenever the queue did not give it. A press still not back after `pressDeadline` fails the test with the control's
    /// name. Returns whether the control's loop got the release (the queued one, if it is still there, is then stale).
    static func press(_ name: @escaping () -> String, release: NSEvent, deliver: () -> Void) -> Bool {
        pressing = Press(name: name, release: release, started: ProcessInfo.processInfo.systemUptime)
        var failed = false
        func fail() {
            guard !failed else { return }
            failed = true
            let line = "the press on «\(name())» has not returned after \(Int(pressDeadline)) s (#102)"
            FileHandle.standardError.write(Data("MouseRig: \(line)\n".utf8))
            RigTrace.note("PRESS STUCK: \(line)")
            Issue.record(Comment(rawValue: line))
        }
        // A press stuck anywhere else than in a request for events still says so, from a timer of every mode.
        let deadline = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + pressDeadline, 0, 0, 0) { _ in
            MainActor.assumeIsolated { if pressing?.released == false { fail() } }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), deadline, .commonModes)
        defer {
            CFRunLoopTimerInvalidate(deadline)
            pressing = nil
        }
        deliver()
        if pressing?.released == false, ProcessInfo.processInfo.systemUptime - (pressing?.started ?? 0) > pressDeadline { fail() }
        return pressing?.released ?? false
    }

    /// After a press whose control did not take its release in a loop of its own (a button that acts on the release given
    /// to it, as an alert's): the control gets the press's own release, never the first one waiting in the event queue. Seen
    /// as «Rimuovi» of Settings › Motori's confirmation reading as a dead control (#103): the release taken from the queue
    /// can be another one (left by another click, or the real mouse's with the screen locked, at the real pointer), or none
    /// (the queue gives back no posted mouse event while the screen is locked, #57). The releases left in the queue go.
    static func finish(_ up: NSEvent, released: Bool, _ name: () -> String, deliver: (NSEvent) -> Void) {
        var others = 0, own = false
        while let e = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) {
            if isOwn(e, up) { own = true } else if !own { others += 1 }
        }
        if !released, others > 0 || !own {
            fallbackReleases += 1
            let line = "the release of the press on «\(name())» was \(own ? "behind \(others) other in the event queue" : "not in the event queue") (screen locked: \(screenLocked)): its own given to it (#103)"
            RigTrace.note("FALLBACK release: " + line)
            FileHandle.standardError.write(Data("MouseRig: \(line)\n".utf8))
        }
        if !released { deliver(up) }
    }

    /// `e` is the press's release `up`, where the rig released (see `nextEvent`).
    static func isOwn(_ e: NSEvent, _ up: NSEvent) -> Bool {
        e === up || (e.timestamp == up.timestamp && e.windowNumber == up.windowNumber
            && abs(e.locationInWindow.x - up.locationInWindow.x) < 1 && abs(e.locationInWindow.y - up.locationInWindow.y) < 1)
    }

    /// AppKit's next event (`-[NSApplication _nextEventMatchingEventMask:untilDate:inMode:dequeue:]`) while a press of the rig
    /// is delivered. A request
    /// for a release waits in short turns and gets the press's own release:
    /// - after `fallbackAfter` when none came (the queue lost it, or gives back no posted mouse event, as with the screen
    ///   locked: #57);
    /// - in place of a release that is not the rig's: with the screen locked, a button's loop got the real mouse's
    ///   button-up, at the real pointer far outside the rig's window, and its click did nothing.
    /// Any other request is the original's.
    fileprivate static func nextEvent(_ mask: NSEvent.EventTypeMask, until: Date?, mode: RunLoop.Mode, dequeue: Bool,
                                      original: (NSEvent.EventTypeMask, Date?, RunLoop.Mode, Bool) -> NSEvent?) -> NSEvent? {
        guard let press = pressing, !press.handed, mask.contains(.leftMouseUp) else { return original(mask, until, mode, dequeue) }
        func hand(_ count: inout Int, _ why: String) -> NSEvent {
            if dequeue {
                pressing?.handed = true
                pressing?.released = true
                count += 1
            }
            let line = "the release of the press on «\(press.name())» \(why) (#102)"
            RigTrace.note("FALLBACK release: \(line)")
            FileHandle.standardError.write(Data("MouseRig: \(line)\n".utf8))
            return press.release
        }
        let end = until ?? .distantPast
        while true {
            let turn = min(end, Date().addingTimeInterval(0.05))
            if let e = original(mask, turn, mode, dequeue) {
                // Its own release, where the rig released: with the screen locked the queue gave back the rig's posted
                // release moved to the real pointer, far outside the window (seen 2026-11-19), which a button ignores.
                let own = isOwn(e, press.release)
                if own, dequeue { pressing?.released = true }
                if own || !Self.realMouse.contains(e.type) { return e }
                if e.type == .leftMouseUp {
                    return hand(&foreignReleases, "was taken by a release from outside the rig (screen locked: \(screenLocked)): replaced by its own")
                }
                // The real mouse moving or dragging (with the screen locked) is not part of a click of the rig's: dropped,
                // or a button's loop would see the pointer leave it and give up the click.
                if !dequeue { _ = original(NSEvent.EventTypeMask(type: e.type), .distantPast, mode, true) }
                foreignEvents += 1
                let line = "an event \(e.type.rawValue) of the real mouse dropped during the press on «\(press.name())» (screen locked: \(screenLocked)) (#102)"
                RigTrace.note("FOREIGN " + line)
                FileHandle.standardError.write(Data("MouseRig: \(line)\n".utf8))
                continue
            }
            if ProcessInfo.processInfo.systemUptime - press.started >= fallbackAfter {
                return hand(&fallbackReleases, "never reached the loop tracking it: handed to it after \(Int(fallbackAfter)) s")
            }
            if Date() >= end { return nil }
        }
    }

    /// A control's name for a failure: its accessibility label, title or placeholder, and its kind.
    static func describe(_ view: NSView, at p: CGPoint) -> String {
        var v: NSView? = view
        while let candidate = v, !(candidate is NSControl) { v = candidate.superview }
        let control = (v as? NSControl) ?? (view as? NSText)?.delegate as? NSControl
        let words = [control?.accessibilityLabel(), (control as? NSTextField)?.placeholderString, (control as? NSButton)?.title]
            .compactMap { $0 }.first { !$0.isEmpty }
        return "\(words ?? "?") (\(Swift.type(of: control ?? view)) at \(Int(p.x)),\(Int(p.y)))"
    }

    /// Two clicks at a point, the second with a click count of 2 (what a double-click sends).
    func doubleClick(_ p: CGPoint) {
        click(p, clicks: 1)
        click(p, clicks: 2)
    }

    /// A right click; the menu that opens is recorded by RigGuard instead of tracked.
    ///
    /// With the screen unlocked it first goes through the event queue, as AppKit delivers a real one: taken from the
    /// queue it becomes `NSApp.currentEvent` (a context menu area reads it), then it is given to the window. With the
    /// screen locked the queue gives back no posted mouse event (#57), so each event is given straight to the window
    /// as the application's current event (`deliver`).
    ///
    /// Neither way is enough over some SwiftUI content (a project tab's name, a Media tile): the hosting view keeps a
    /// press that came through the window and opens nothing, always when it was handed straight to the window and
    /// some of the times when it came from the queue, locked or not (seen 2026-11-17 with the screen unlocked and the
    /// display on), while the same press given to the view under the point opens the menu. So a press that opened no
    /// menu is given once to the view under the point, the one the window itself would pick; each one is counted and
    /// said on stderr with what was tried (`handedRightClicks`). A view with no menu still opens none.
    func rightClick(_ p: CGPoint, modifiers: NSEvent.ModifierFlags = []) {
        RigTrace.note("MouseRig.rightClick at \(Int(p.x)),\(Int(p.y))")
        guard let down = event(.rightMouseDown, p, modifiers: modifiers), let up = event(.rightMouseUp, p, modifiers: modifiers) else { return }
        takeKey()
        let events = RigGuard.events.count
        var opened: Bool { RigGuard.events.dropFirst(events).contains { $0.kind == .menu } }
        var tried = "the screen is locked"
        if !Self.screenLocked {
            // Posting stops the running run loop: a nested one of ours (see `click`).
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
            }
            CFRunLoopRunInMode(.defaultMode, 0.3, false)
            var taken = 0
            while let e = NSApp.nextEvent(matching: [.rightMouseDown, .rightMouseUp], until: .distantPast, inMode: .default, dequeue: true) {
                window.sendEvent(e)
                taken += 1
            }
            drain()
            pump()
            if opened { return }
            tried = "the event queue gave back \(taken) of the 2 events posted and no menu opened"
        }
        deliver(down, to: window)
        pump()
        if !opened, let hit = viewAt(p) {
            Self.handedRightClicks += 1
            FileHandle.standardError.write(Data("MouseRig: \(tried), and a right press through the window opened no menu at \(Int(p.x)),\(Int(p.y)); given to \(Swift.type(of: hit)) (#57)\n".utf8))
            // A press of its own: the hosting view does not answer twice for the one the window already gave it.
            if let again = event(.rightMouseDown, p, modifiers: modifiers) {
                let previous = NSApp.currentEvent
                NSApp.setValue(again, forKey: "currentEvent")
                hit.rightMouseDown(with: again)
                NSApp.setValue(previous, forKey: "currentEvent")
            }
        }
        deliver(up, to: window)
        drain()
        pump()
    }

    /// Right presses given to the view under the point because none sent through the window opened a menu (see
    /// `rightClick`).
    static var handedRightClicks = 0
    /// Whether the session's screen is locked (a Mac left alone while the tests run).
    static var screenLocked: Bool {
        ((CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
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

    /// Scrolls the scroll view under `p` by `dy` points (positive: towards its end) with a wheel event given to the rig's
    /// window (never posted to the session or the HID event tap), and says whether it moved. The window stays off every display: its `screen` answers the main display, which is
    /// what SwiftUI's wheel handling needs (#50). With the main display asleep SwiftUI holds a wheel event until the display
    /// wakes, so the clip view is moved instead, and the same when the wheel moved nothing; both are counted (`wheelMisses`).
    @discardableResult
    func scrollContent(at p: CGPoint, by dy: CGFloat) -> Bool {
        var v = viewAt(p)
        while let x = v, !(x is NSScrollView) { v = x.superview }
        guard let sv = v as? NSScrollView else { return false }
        let from = sv.contentView.bounds.origin.y
        guard CGDisplayIsAsleep(CGMainDisplayID()) == 0 else {
            scrolledWithoutWheel(sv, from: from, by: dy)
            return abs(sv.contentView.bounds.origin.y - from) > 0.5
        }
        scroll(at: p, dy: Int32(dy.rounded()))
        pump(0.25)
        if abs(sv.contentView.bounds.origin.y - from) <= 0.5 { scrolledWithoutWheel(sv, from: from, by: dy) }
        return abs(sv.contentView.bounds.origin.y - from) > 0.5
    }

    /// How many times `scrollContent` moved the clip view instead of scrolling with a wheel event (the main display
    /// asleep, or a wheel event that moved nothing).
    static var wheelMisses = 0

    /// The way `scrollContent` scrolled before #50: the scroll view's clip view moved within its content, as the wheel
    /// would. Only when the wheel event did not move it, and said on the test's output.
    private func scrolledWithoutWheel(_ sv: NSScrollView, from: CGFloat, by dy: CGFloat) {
        guard let doc = sv.documentView else { return }
        let clip = sv.contentView
        let to = min(max(from + (doc.isFlipped ? dy : -dy), 0), max(0, doc.frame.height - clip.bounds.height))
        guard abs(to - from) > 0.5 else { return }
        Self.wheelMisses += 1
        FileHandle.standardError.write(Data("MouseRig: no wheel event scrolled \(Swift.type(of: sv)) (main display asleep: \(CGDisplayIsAsleep(CGMainDisplayID()) != 0)); its clip view was moved instead (#50)\n".utf8))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: to))
        sv.reflectScrolledClipView(clip)
        pump(0.05)
    }

    /// A scroll-wheel event at a point (positive `dy` scrolls the content down, as a trackpad swipe up does), given to
    /// the window. The rig's window answers the main display as its screen (#50), so a SwiftUI scroll view applies it.
    func scroll(at p: CGPoint, dx: Int32 = 0, dy: Int32, modifiers: NSEvent.ModifierFlags = []) {
        guard let e = wheelEvent(at: p, dx: dx, dy: dy, modifiers: modifiers) else { return }
        takeKey()
        window.sendEvent(e)
        pump(0.05)
    }

    /// The scroll-wheel event `scroll` gives the window.
    func wheelEvent(at p: CGPoint, dx: Int32 = 0, dy: Int32, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -dy, wheel2: -dx, wheel3: 0) else { return nil }
        let screen = window.convertPoint(toScreen: CGPoint(x: p.x, y: size.height - p.y))
        // CGEvent locations are top-left based on the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: mainHeight - screen.y)
        cg.flags = CGEventFlags(rawValue: UInt64(modifiers.rawValue))
        // The window under the pointer, as the window server fills it for a real wheel event.
        for field in [91, 92] { if let f = CGEventField(rawValue: UInt32(field)) { cg.setIntegerValueField(f, value: Int64(window.windowNumber)) } }
        return NSEvent(cgEvent: cg)
    }

    // MARK: Keyboard

    /// A key press through the application (local event monitors see it, then the key window's first responder).
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        RigTrace.note("MouseRig.key \(keyCode)")
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
        RigTrace.note("MouseRig.elements")
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
        click(e.centre, modifiers: modifiers, name: name)
        return true
    }


    /// Whether `e` is one of AppKit's own controls (the Settings form's pop-ups, check boxes, bordered buttons, text
    /// fields): their element is the control or its cell, not a node of SwiftUI's.
    /// A SwiftUI button the system form draws with an AppKit button under it («Nuovo kit», «Importa…» in Settings)
    /// counts too: synthetic clicks reached it in one run and not in the next.
    func isNative(_ e: RigElement) -> Bool { e.ref is NSView || e.ref is NSCell || viewAt(e.centre) is NSControl }

    /// Drives a native control the way an assistive client does (#36): a pop-up picks its next item (what choosing it in
    /// its menu does, without AppKit's modal menu tracking), a text field takes the focus and `text` is typed into it,
    /// anything else is pressed. Returns what was done, for the audit's table; nil when `e` is not a native control.
    @discardableResult
    func performAccessibility(_ e: RigElement, text: String = "Regista") -> String? {
        guard isNative(e), e.enabled, let o = e.ref as? NSObject else { return nil }
        defer { drain(); pump() }
        switch e.role {
        case "AXPopUpButton":
            guard let cell = (o as? NSPopUpButtonCell) ?? ((o as? NSPopUpButton)?.cell as? NSPopUpButtonCell), let menu = cell.menu else { return nil }
            // SwiftUI fills a pop-up's menu when it is about to show it (its cell's delegate is asked, as AppKit asks it
            // before the menu opens).
            if let d = menu.delegate as AnyObject?, d.responds(to: NSSelectorFromString("popUpButtonCell:willShowMenu:")) {
                _ = d.perform(NSSelectorFromString("popUpButtonCell:willShowMenu:"), with: cell, with: menu)
            }
            menu.update()
            let choices = menu.items.indices.filter { !menu.items[$0].isSeparatorItem && menu.items[$0].isEnabled && !menu.items[$0].isHidden }
            let current = cell.indexOfSelectedItem
            guard let next = choices.first(where: { $0 > current }) ?? choices.first, next != current else { return "accessibility action: nothing else to pick (\(menu.items.count) items)" }
            menu.performActionForItem(at: next)
            return "accessibility action: pick «\(menu.items[next].title)»"
        case "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox":
            // Focused through accessibility, then typed into: a value set directly would change the field and not
            // what it is bound to (seen on the Scorciatoie search, whose list did not filter).
            takeKey()
            if let v = o as? NSView { v.setAccessibilityFocused(true) } else { (o as? NSCell)?.setAccessibilityFocused(true) }
            pump()
            // A field that ignores the accessibility focus (seen on two of the three in Settings) is made the window's
            // first responder, which is what the focus asks for.
            if !isTyping, let v = (o as? NSView) ?? (o as? NSCell)?.controlView { window.makeFirstResponder(v); pump() }
            guard isTyping else { return "accessibility action: the field did not take the focus" }
            type(text)
            return "accessibility action: focus, type «\(text)»"
        default:
            if let v = o as? NSView { _ = v.accessibilityPerformPress() }
            else if let c = o as? NSCell { _ = c.accessibilityPerformPress() }
            else if o.responds(to: NSSelectorFromString("accessibilityPerformPress")) { _ = o.perform(NSSelectorFromString("accessibilityPerformPress")) }
            else { return nil }
            return "accessibility action: press"
        }
    }

    /// The deepest accessibility element at a point of the view (what an assistive client finds there).
    func elementAt(_ p: CGPoint) -> AnyObject? {
        RigTrace.note("MouseRig.elementAt \(Int(p.x)),\(Int(p.y))")
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
        // at the end of the run, prints where it came from. One such exit was known: the test runner's main loop is a
        // bare CFRunLoopRun followed by exit(0), and a stop that AppKit queues while a test awaits ended it (#40).
        // `holdTheMainLoop` keeps the main thread out of that loop; scripts/test.sh still sees a run without its
        // summary and takes it up again, never counting it as green.
        swap(NSApplication.self, #selector(NSApplication.terminate(_:)), #selector(NSApplication.rig_terminate(_:)))
        // #40: a stop asked through NSApp is written down with its caller (RigTrace).
        swap(NSApplication.self, #selector(NSApplication.stop(_:)), #selector(NSApplication.rig_stop(_:)))
        holdTheMainLoop()
        guardProcesses()
        guardTrash()
        guardRecycle()
        guardPasteboard()
        atexit {
            let stack = Thread.callStackSymbols
            guard !stack.contains(where: { $0.contains("RunnerV4main") }) else { return }
            FileHandle.standardError.write(Data(("MouseRig: the test process is exiting from inside a test:\n" + stack.joined(separator: "\n") + "\n"
                + "MouseRig: the rig's last operations before the exit, oldest first (#40):\n" + RigTrace.last.joined(separator: "\n") + "\n").utf8))
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
    /// #40, at its root. The test runner's main thread sits in a bare CFRunLoopRun followed by exit(0): a stop that
    /// AppKit queues (a posted event, a window shown, a teleprompter's display link) ends that loop when it lands
    /// while a test awaits, and the process with it, with code 0 and the remaining tests not run. The rig's nested
    /// loops absorbed the stops that landed in them, never the ones in between. So the main thread does not go back
    /// to the runner's loop: a timer waits until that loop itself calls it, then turns a loop of ours for ever.
    /// Everything the main thread does from then on (the tests' main-actor code, the main queue, timers, AppKit) runs
    /// inside it, and a stop ends one turn of it, written down by RigTrace. The process still ends as before, by the
    /// runner's own exit.
    ///
    /// "Called by the runner's loop itself" is: no nested run of the default mode has started since this was installed
    /// (an observer counts them: a wait on a subprocess, a loop of the rig's), and the thread runs no Swift task (a
    /// test's code that turns a loop of its own). Started anywhere else, the loop would never give that caller its
    /// thread back. The stack cannot tell: under a Swift task it shows the task's frames, not the thread's.
    private static func holdTheMainLoop() {
        nonisolated(unsafe) var nested = 0
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.entry.rawValue | CFRunLoopActivity.exit.rawValue, true, 0) { _, activity in
            nested += activity == .entry ? 1 : -1
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .defaultMode)
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 0.02, 0, 0) { timer in
            guard nested == 0, withUnsafeCurrentTask(body: { $0 == nil }) else { return }
            CFRunLoopTimerInvalidate(timer)
            CFRunLoopObserverInvalidate(observer)
            RigTrace.note("RigGuard: the main thread turns the rig's loop from here on, not the runner's")
            while true {
                if RigTrace.run("hold", 3600) == .finished { usleep(1000) }
            }
        }
        CFRunLoopAddTimer(CFRunLoopGetMain(), timer, .defaultMode)
    }

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

    /// NSWorkspace's recycle (the Finder's Trash, «Sposta il file nel Cestino», #142) never reaches the Trash of the person
    /// running the tests either: each file goes to RigTrash.folder and the completion gets the new places.
    private static func guardRecycle() {
        typealias Done = @convention(block) (NSDictionary, NSError?) -> Void
        let sel = NSSelectorFromString("recycleURLs:completionHandler:")
        guard let m = class_getInstanceMethod(NSWorkspace.self, sel) else { return }
        let block: @convention(block) (AnyObject, NSArray, AnyObject?) -> Void = { _, urls, handler in
            var moved: [URL: URL] = [:]
            var failure: NSError?
            for case let url as URL in urls {
                do { moved[url] = try RigTrash.take(url) } catch let e as NSError { failure = e }
            }
            if let handler { unsafeBitCast(handler, to: Done.self)(moved as NSDictionary, failure) }
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

    /// Queues a nested loop of ours on the main run loop for the length of a sheet animation (or of a window's showing).
    static func holdForAnimation(_ what: String = "sheet animation") {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            let end = Date().addingTimeInterval(0.6)
            while Date() < end { RigTrace.run(what, 0.01) }
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
        // A window put on screen stops the running run loop about 0.15 s later (not through NSApp.stop, not its ordering
        // animation: switching that off changed nothing; where the stop comes from was not traced further). Showing the Gobbo's panel («Mostra il gobbo») was the operation before
        // every early end traced on 2026-11-16 (#40): the stop landed in a nested loop of the rig's in about half the
        // runs and in the test runner's own loop (which then returns and ends the process) in the others. A nested
        // loop of ours turns for that time, so the stop lands there.
        holdForAnimation("window shown")
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
        RigPlayers.asked(url)
        return rig_play()
    }
}

/// The files the code asked an AVAudioPlayer to play (muted: nothing reaches the speakers), in order.
enum RigPlayers {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _played: [String] = []
    static var played: [String] { lock.withLock { _played } }
    static func asked(_ url: URL?) { lock.withLock { _played.append(url?.lastPathComponent ?? "?") } }
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
