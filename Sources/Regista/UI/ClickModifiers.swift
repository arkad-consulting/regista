import AppKit

extension NSEvent {
    /// The modifier keys of the click being handled: the ones its own event carries (what the person held when they
    /// pressed), the keyboard's state only when no mouse event is being handled. `NSEvent.modifierFlags` alone reads
    /// the keyboard at the moment the code runs, which is not always the moment of the click (#36).
    @MainActor static var clickModifiers: NSEvent.ModifierFlags {
        if let e = NSApp.currentEvent, mouseTypes.contains(e.type) { return e.modifierFlags }
        return NSEvent.modifierFlags
    }

    private static let mouseTypes: Set<NSEvent.EventType> = [.leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown,
                                                              .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp,
                                                              .otherMouseDragged]
}
