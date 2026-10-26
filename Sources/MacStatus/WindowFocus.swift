import AppKit

/// Editable windows need a foreground application and a key window, even though
/// the normal dashboard lives in a transient menu-bar popover.
@MainActor
enum WindowFocus {
    static func target(for window: NSWindow) -> NSWindow {
        target(for: window, modalWindow: NSApplication.shared.modalWindow)
    }

    /// Preserve an active modal or attached sheet instead of making its parent key.
    static func target(for window: NSWindow, modalWindow: NSWindow?) -> NSWindow {
        let base = modalWindow.flatMap { $0.isVisible ? $0 : nil } ?? window
        return visibleSheetChain(from: base).last ?? base
    }

    /// A deferred layout pass must not take focus back from a newer user action.
    static func deferredTarget(for window: NSWindow, modalWindow: NSWindow?, keyWindow: NSWindow?,
                               isApplicationActive: Bool) -> NSWindow? {
        guard isApplicationActive, window.isVisible else { return nil }
        let destination = target(for: window, modalWindow: modalWindow)
        guard destination.isVisible else { return nil }
        if let keyWindow, keyWindow.isVisible {
            let allowed = visibleSheetChain(from: window)
                + (modalWindow.map { visibleSheetChain(from: $0) } ?? [])
            guard allowed.contains(where: { $0 === keyWindow }) else { return nil }
        }
        return destination
    }

    private static func visibleSheetChain(from window: NSWindow) -> [NSWindow] {
        var chain = [window]
        var seen: Set<ObjectIdentifier> = [ObjectIdentifier(window)]
        var current = window
        while let sheet = current.attachedSheet, sheet.isVisible,
              seen.insert(ObjectIdentifier(sheet)).inserted {
            chain.append(sheet)
            current = sheet
        }
        return chain
    }

    /// Receive an outside-dashboard click without scheduling a later focus pass
    /// that could interfere with the menu or sheet opened by that same click.
    static func focusForClick(_ window: NSWindow) {
        let destination = target(for: window)
        if !NSApp.isActive { NSApp.activate() }
        if !destination.isKeyWindow { destination.makeKeyAndOrderFront(nil) }
    }

    static func present(_ window: NSWindow, firstResponder: NSView? = nil) {
        let application = NSApplication.shared
        let destination = target(for: window, modalWindow: application.modalWindow)
        if application.activationPolicy() != .regular { application.setActivationPolicy(.regular) }
        if destination === window, let firstResponder { window.initialFirstResponder = firstResponder }
        if !application.isActive { application.activate() }
        destination.makeKeyAndOrderFront(nil)
        if destination.canBecomeMain { destination.makeMain() }
        // Hosting attaches an NSViewRepresentable's WKWebView during layout.
        // Do this once, after attachment, without resetting focused web inputs
        // on subsequent SwiftUI updates.
        DispatchQueue.main.async { [weak window, weak firstResponder] in
            guard let window,
                  let destination = deferredTarget(for: window, modalWindow: application.modalWindow,
                                                   keyWindow: application.keyWindow,
                                                   isApplicationActive: application.isActive) else { return }
            destination.makeKeyAndOrderFront(nil)
            if destination.canBecomeMain { destination.makeMain() }
            if destination === window, let firstResponder, firstResponder.window === window,
               window.firstResponder == nil || window.firstResponder === window || window.firstResponder === window.contentView {
                window.makeFirstResponder(firstResponder)
            }
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
