import AppKit
import ObjectiveC
import SwiftUI
@testable import Regista

// Real mouse events for the app's views (#28). The rendered states (ui.screenshot, ui-shots) show what a view draws,
// never what a click does: a control can look right and be dead, or pass its click to what lies under it. A MouseRig
// hosts a view in a window and sends it the events a mouse sends, through the window, the way AppKit does.

/// A window that can be key, so its content behaves as in the frontmost window of the app.
private final class RigWindow: NSWindow {
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
    }

    init<V: View>(_ view: V, size: CGSize) {
        Self.reportActive()
        self.size = size
        let host = NSHostingView(rootView: view)
        host.frame = CGRect(origin: .zero, size: size)
        window = RigWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // Gestures only see the events of a window that is on screen: this one is ordered in far outside every display.
        window.setFrameOrigin(CGPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        window.makeKey()
        pump(0.1)
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }

    /// Lets the main run loop turn (SwiftUI updates, main-queue work).
    func pump(_ seconds: Double = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// One mouse event at a point of the view (top-left origin).
    func send(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1) {
        guard let e = NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: size.height - p.y), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                         eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseUp ? 0 : 1) else { return }
        window.sendEvent(e)
        pump(0.02)
    }

    /// Press and release at a point.
    func click(_ p: CGPoint, clicks: Int = 1) {
        send(.leftMouseDown, p, clicks: clicks)
        send(.leftMouseUp, p, clicks: clicks)
        pump()
    }

    /// Press at `from`, move by `delta` in ten steps, release.
    func drag(from: CGPoint, by delta: CGSize) {
        send(.leftMouseDown, from)
        for i in 1...10 {
            let f = Double(i) / 10
            send(.leftMouseDragged, CGPoint(x: from.x + delta.width * f, y: from.y + delta.height * f))
        }
        send(.leftMouseUp, CGPoint(x: from.x + delta.width, y: from.y + delta.height))
        pump()
    }
}
