import AppKit

/// Activation may restore keyboard input to an already open dashboard, but
/// must not bring an unrelated settings or account window to the foreground.
@MainActor
enum PopoverFocus {
    static func activationTarget(popoverWindow: NSWindow?, isPopoverShown: Bool,
                                 keyWindow: NSWindow?, modalWindow: NSWindow?) -> NSWindow? {
        if let keyWindow, keyWindow.isVisible { return nil }
        if let modalWindow, modalWindow.isVisible { return nil }
        guard isPopoverShown, let popoverWindow, popoverWindow.isVisible else { return nil }
        return WindowFocus.target(for: popoverWindow, modalWindow: nil)
    }
}
