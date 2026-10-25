import AppKit
import WebKit

@MainActor
final class LoginWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Foreground the actual window at the point of a physical click. A web view's
/// internal WKContentView may receive mouse events without calling WKWebView's
/// mouseDown override, so activation belongs at the NSWindow boundary.
@MainActor
final class KeyboardWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            NSApp.activate()
            if !isKeyWindow { makeKeyAndOrderFront(nil) }
        }
        InputDiagnostics.recordWindowEvent(event)
        super.sendEvent(event)
    }
}

/// Opt-in development diagnostics. Records event COUNTS and responder classes,
/// never key codes, characters, input values, URLs, or account information.
@MainActor
enum InputDiagnostics {
    private static var enabled = false
    private static var appKeys = 0
    private static var appMouse = 0
    private static var windowKeys = 0
    private static var windowMouse = 0
    private static var monitor: Any?
    private static var timer: Timer?
    private static let output = URL(fileURLWithPath: "/private/tmp/mac-status-input-diagnostics/state.json")

    static func start() {
        guard ProcessInfo.processInfo.environment["MAC_STATUS_INPUT_DIAGNOSTICS"] == "1", !enabled else { return }
        enabled = true
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            MainActor.assumeIsolated {
                if event.type == .keyDown { appKeys += 1 }
                if event.type == .leftMouseDown { appMouse += 1 }
            }
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { writeSnapshot() }
        }
        writeSnapshot()
    }

    static func recordWindowEvent(_ event: NSEvent) {
        guard enabled else { return }
        if event.type == .keyDown { windowKeys += 1 }
        if event.type == .leftMouseDown { windowMouse += 1 }
    }

    private static func writeSnapshot() {
        let windows: [[String: Any]] = NSApp.windows.filter(\.isVisible).map {
            ["number": $0.windowNumber, "key": $0.isKeyWindow, "main": $0.isMainWindow,
             "canBecomeKey": $0.canBecomeKey, "class": String(describing: type(of: $0)),
             "responderClass": $0.firstResponder.map { String(describing: type(of: $0)) } ?? "none"]
        }
        let state: [String: Any] = ["active": NSApp.isActive, "activationPolicy": NSApp.activationPolicy().rawValue,
                                    "appKeyEvents": appKeys, "appMouseEvents": appMouse,
                                    "windowKeyEvents": windowKeys, "windowMouseEvents": windowMouse,
                                    "keyWindow": NSApp.keyWindow?.windowNumber ?? -1, "windows": windows]
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: output, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}
