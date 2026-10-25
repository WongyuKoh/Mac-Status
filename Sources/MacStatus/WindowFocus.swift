import AppKit

/// Editable windows need a foreground application and a key window, even though
/// the normal dashboard lives in a transient menu-bar popover.
@MainActor
enum WindowFocus {
    static func present(_ window: NSWindow, firstResponder: NSView? = nil) {
        NSApp.setActivationPolicy(.regular)
        if let firstResponder { window.initialFirstResponder = firstResponder }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        // Hosting attaches an NSViewRepresentable's WKWebView during layout.
        // Do this once, after attachment, without resetting focused web inputs
        // on subsequent SwiftUI updates.
        DispatchQueue.main.async { [weak window, weak firstResponder] in
            guard let window, window.isVisible else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            if let firstResponder { window.makeFirstResponder(firstResponder) }
        }
    }

    static func restoreMenuBarMode(afterClosing window: NSWindow) {
        DispatchQueue.main.async { [weak window] in
            let hasEditableWindow = NSApp.windows.contains {
                $0 !== window && $0.isVisible && $0.styleMask.contains(.titled)
            }
            if !hasEditableWindow { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
