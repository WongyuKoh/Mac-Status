import AppKit
import Combine
import SwiftUI

@main
enum MacStatusMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var monitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private var pendingWindowPresentation: (@MainActor @Sendable () -> Void)?
    private var subscription: AnyCancellable?
    private let accountLogin = AccountLoginController()
    private let consoleLogin = ClaudeConsoleLoginController()
    private lazy var store = DemoData.isEnabled ? DemoData.makeStore() : StatusStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDiagnostics.start()
        configureMenu()
        store.onRequestLogin = { [weak self] kind in
            guard let self, !DemoData.isEnabled else { return }
            self.presentAfterPopoverCloses { [weak self] in
                guard let self else { return }
                if kind == .claudeAPI { self.consoleLogin.present(store: self.store) }
                else { self.accountLogin.present(kind: kind, store: self.store) }
            }
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "chart.bar.xaxis", accessibilityDescription: "Mac Status")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(togglePopover)
            button.toolTip = "Mac Status · 사용량과 시스템 통계"
            button.setAccessibilityLabel("Mac Status")
        }
        // Close explicitly on outside clicks. AppKit's transient focus handling
        // can dismiss an accessory app's popover before its button gets the click.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        popover.contentSize = NSSize(width: 600, height: 746)
        popover.contentViewController = NSHostingController(rootView: dashboard)
        subscription = store.objectWillChange.debounce(for: .milliseconds(150), scheduler: RunLoop.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMenuTitle() }
        }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // AppKit delivers monitor callbacks on the main thread. Handle the
            // click now so a queued dismissal cannot close a newly opened panel.
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.popover.performClose(nil)
            }
        }
        windowCloseObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                if let window = notification.object as? NSWindow, window.styleMask.contains(.titled) {
                    WindowFocus.restoreMenuBarMode(afterClosing: window)
                }
            }
        }
        if CommandLine.arguments.contains("--preview") || DemoData.isEnabled {
            showPreview()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if !self.popover.isShown && !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                    self.togglePopover()
                }
            }
        }
    }

    private var dashboard: DashboardView {
        DashboardView(store: store, openSettings: { [weak self] builder in self?.showSettings(builder: builder) }, isDemo: DemoData.isEnabled)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown { popover.performClose(nil) }
        else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await store.refresh() }
        }
    }

    private func updateMenuTitle() {
        if store.showCPUInMenu, let cpu = store.cpuReading {
            statusItem.button?.title = " \(Int(cpu.rounded()))%"
            statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        } else { statusItem.button?.title = "" }
    }

    private func showSettings(builder: Bool) {
        presentAfterPopoverCloses { [weak self] in self?.displaySettings(builder: builder) }
    }

    private func displaySettings(builder: Bool) {
        if settingsWindow == nil {
            let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Mac Status · 설정"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(Palette.background)
            window.minSize = NSSize(width: 900, height: 700)
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsView(store: store, selectedTab: builder ? 1 : 0))
        if let settingsWindow { WindowFocus.present(settingsWindow) }
    }

    private func showPreview() {
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 746), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = DemoData.isEnabled ? "Mac Status · 미리보기" : "Mac Status"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Palette.background)
        window.contentViewController = NSHostingController(rootView: dashboard)
        window.isReleasedWhenClosed = false
        window.center()
        previewWindow = window
        WindowFocus.present(window)
    }

    private func presentAfterPopoverCloses(_ action: @escaping @MainActor @Sendable () -> Void) {
        guard popover.isShown else { DispatchQueue.main.async(execute: action); return }
        pendingWindowPresentation = action
        popover.performClose(nil)
        if !popover.isShown { finishWindowPresentation() }
    }

    func popoverDidClose(_ notification: Notification) {
        finishWindowPresentation()
    }

    private func finishWindowPresentation() {
        guard let action = pendingWindowPresentation else { return }
        pendingWindowPresentation = nil
        DispatchQueue.main.async(execute: action)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Status-bar windows count as visible windows but cannot become key.
        // Use actual editable windows rather than AppKit's aggregate flag.
        if let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
            WindowFocus.present(window)
        } else if !popover.isShown {
            togglePopover()
        }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // activate() is asynchronous. Reassert the editable key window after
        // WindowServer has actually foregrounded this application.
        if let window = NSApp.orderedWindows.first(where: { $0 is KeyboardWindow && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
        } else if statusItem != nil, !popover.isShown {
            togglePopover()
        }
    }

    @objc private func openSettingsFromMenu() { showSettings(builder: false) }

    private func configureMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Mac Status")
        let settings = NSMenuItem(title: "Mac Status 설정…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: "Mac Status 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "편집")
        editMenu.addItem(withTitle: "실행 취소", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "잘라내기", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "복사", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "붙여넣기", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "전체 선택", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }
}
