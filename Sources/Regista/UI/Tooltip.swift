import AppKit
import SwiftUI

/// What a tip shows: the function's name and, apart, its keyboard shortcut.
struct TipContent: Equatable {
    let text: String
    let shortcut: String?

    init(_ text: String, shortcut: String? = nil) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = shortcut?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.shortcut = s.isEmpty ? nil : s
    }

    var isEmpty: Bool { text.isEmpty && shortcut == nil }

    /// Through the app's Localizable.strings (Italian keys, like every UI literal; unknown texts stay as they are).
    func localized(_ bundle: Bundle = .main) -> TipContent {
        TipContent(bundle.localizedString(forKey: text, value: text, table: nil),
                   shortcut: shortcut.map { bundle.localizedString(forKey: $0, value: $0, table: nil) })
    }

    /// One line for VoiceOver and the system: "Annulla (⌘Z)".
    var spoken: String {
        guard let shortcut else { return text }
        return text.isEmpty ? shortcut : "\(text) (\(shortcut))"
    }
}

/// Where a tip goes, in screen coordinates (y up): centred under the control, above it when there is no room
/// below, always inside the screen's visible frame.
enum TipPlacement {
    static func frame(size: CGSize, anchor: CGRect, screen: CGRect, gap: CGFloat = 6, margin: CGFloat = 4) -> CGRect {
        var y = anchor.minY - gap - size.height
        if y < screen.minY + margin { y = anchor.maxY + gap }
        y = min(y, screen.maxY - margin - size.height)
        let x = min(max(anchor.midX - size.width / 2, screen.minX + margin), screen.maxX - margin - size.width)
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

extension View {
    /// A fast, styled tooltip (≈350 ms after the pointer rests, instant when moving between controls), drawn in
    /// its own window so panels never clip it. Hides on exit, click, scroll and key press. The text is also the
    /// accessibility label; the system `.help` tooltip is not used, it would appear a second time on top.
    func tip(_ text: String, shortcut: String? = nil) -> some View {
        modifier(TipModifier(content: TipContent(text, shortcut: shortcut).localized()))
    }
}

private struct TipModifier: ViewModifier {
    let content: TipContent

    func body(content view: Content) -> some View {
        if content.isEmpty {
            view
        } else {
            view
                .background(TipAnchor(content: content))
                .accessibilityLabel(content.spoken)
        }
    }
}

/// An invisible view behind the control: its tracking area sees the pointer (whatever is drawn on top), and
/// its frame says where the control is on screen.
private struct TipAnchor: NSViewRepresentable {
    let content: TipContent

    func makeNSView(context: Context) -> TipAnchorView {
        let v = TipAnchorView()
        v.content = content
        return v
    }

    func updateNSView(_ v: TipAnchorView, context: Context) {
        guard v.content != content else { return }
        v.content = content
        TipController.shared.contentChanged(v)
    }

    static func dismantleNSView(_ v: TipAnchorView, coordinator: ()) { TipController.shared.leave(v) }
}

final class TipAnchorView: NSView {
    var content = TipContent("")

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { TipController.shared.enter(self) }
    override func mouseExited(with event: NSEvent) { TipController.shared.leave(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { TipController.shared.leave(self) }
    }

    /// The control's frame on screen.
    var screenFrame: CGRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }
}

/// The one tip window of the app.
@MainActor
final class TipController {
    static let shared = TipController()

    static let delay: TimeInterval = 0.35
    /// After a tip was visible, the next one shows at once for this long (like the system's tooltips).
    static let warm: TimeInterval = 0.6

    private var panel: NSPanel?
    private var host: NSHostingController<TipLabel>?
    private var pending: DispatchWorkItem?
    private weak var hovered: TipAnchorView?
    private weak var shown: TipAnchorView?
    /// A click on the hovered control hides its tip until the pointer leaves it.
    private weak var suppressed: TipAnchorView?
    private var lastVisible: Date = .distantPast
    private var monitor: Any?

    func enter(_ anchor: TipAnchorView) {
        installMonitor()
        hovered = anchor
        guard suppressed !== anchor, anchor.window?.isVisible == true, NSApp.isActive || anchor.window is NSPanel else { return }
        pending?.cancel()
        let warmNow = shown != nil || Date().timeIntervalSince(lastVisible) < Self.warm
        let work = DispatchWorkItem { [weak self, weak anchor] in
            guard let self, let anchor, self.hovered === anchor else { return }
            self.show(anchor)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (warmNow ? 0.02 : Self.delay), execute: work)
    }

    func leave(_ anchor: TipAnchorView) {
        if suppressed === anchor { suppressed = nil }
        guard hovered === anchor || shown === anchor else { return }
        hovered = nil
        hide()
    }

    func contentChanged(_ anchor: TipAnchorView) {
        if shown === anchor { show(anchor) }
    }

    /// Hides the tip (and cancels a pending one).
    func hide() {
        pending?.cancel()
        pending = nil
        guard let panel, panel.isVisible else { shown = nil; return }
        lastVisible = Date()
        shown = nil
        panel.orderOut(nil)
    }

    private func show(_ anchor: TipAnchorView) {
        guard let frame = anchor.screenFrame, let screen = anchor.window?.screen ?? NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        if let host { host.rootView = TipLabel(content: anchor.content) }
        let size = host?.sizeThatFits(in: CGSize(width: TipLabel.maxWidth, height: 2000)) ?? .zero
        let wasVisible = panel.isVisible
        panel.setFrame(TipPlacement.frame(size: size, anchor: frame, screen: screen.visibleFrame), display: true)
        panel.invalidateShadow()
        shown = anchor
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.level = .popUpMenu
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        // A recording app: tips never end up in the user's screen recordings.
        p.sharingType = .none
        p.appearance = NSAppearance(named: .darkAqua)
        let h = NSHostingController(rootView: TipLabel(content: TipContent("")))
        h.sizingOptions = []
        p.contentView = h.view
        panel = p
        host = h
        return p
    }

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .scrollWheel, event.type != .keyDown { self.suppressed = self.hovered }
            self.hide()
            return event
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }
}

/// The tip itself: a small dark rounded label, the shortcut in a keycap.
struct TipLabel: View {
    let content: TipContent
    /// Longer texts wrap.
    static let maxWidth: CGFloat = 320

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Ed.Space.s) {
            if !content.text.isEmpty {
                Text(verbatim: content.text)   // already looked up: TipContent.localized()
                    .font(Ed.ui(Ed.TypeSize.body, .medium))
                    .foregroundStyle(Ed.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let s = content.shortcut {
                Text(verbatim: s)
                    .font(Ed.ui(Ed.TypeSize.caption, .medium))
                    .foregroundStyle(Ed.text2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: Ed.Radius.s).fill(Color.white.opacity(0.09)))
                    .overlay(RoundedRectangle(cornerRadius: Ed.Radius.s).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).fill(Ed.tooltip.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: Ed.Radius.l, style: .continuous).strokeBorder(Color.white.opacity(0.11), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }
}
