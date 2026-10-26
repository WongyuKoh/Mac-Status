import AppKit

/// Dismiss the menu-bar dashboard when another app window is clicked, while
/// leaving that physical event available for its original control to handle.
@MainActor
enum PopoverOutsideClick {
    static func shouldDismiss(for clickedWindow: NSWindow?, popoverWindow: NSWindow?, statusItemWindow: NSWindow?) -> Bool {
        guard let clickedWindow, let popoverWindow,
              clickedWindow !== statusItemWindow else { return false }

        // A native menu or help popover can have a different window. Preserve
        // descendants of the dashboard, including attached detail sheets.
        var ancestors = [clickedWindow]
        var visited: Set<ObjectIdentifier> = []
        while let window = ancestors.popLast() {
            guard visited.insert(ObjectIdentifier(window)).inserted else { continue }
            if window === popoverWindow { return false }
            if let parent = window.parent { ancestors.append(parent) }
            if let sheetParent = window.sheetParent { ancestors.append(sheetParent) }
        }

        // Unrelated borderless menu/tracking windows need to finish their own
        // interaction. Ordinary settings, login, and updater windows do dismiss.
        return clickedWindow.styleMask.contains(.titled) || clickedWindow.canBecomeMain
    }

    static func handle(_ event: NSEvent, clickedWindow: NSWindow?, popoverWindow: NSWindow?, statusItemWindow: NSWindow?,
                       dismiss: () -> Void, focus: (NSWindow) -> Void) -> NSEvent {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type),
              shouldDismiss(for: clickedWindow, popoverWindow: popoverWindow, statusItemWindow: statusItemWindow),
              let clickedWindow else { return event }
        dismiss()
        focus(clickedWindow)
        // Never consume or replay a click: the same event must select the tab.
        return event
    }
}
