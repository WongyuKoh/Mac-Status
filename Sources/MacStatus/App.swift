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
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuItemValidation {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var previewWindow: NSWindow?
    private var monitor: Any?
    private var localMouseMonitor: Any?
    private var windowCloseObserver: NSObjectProtocol?
    private var pendingWindowPresentation: (@MainActor @Sendable () -> Void)?
    private var subscription: AnyCancellable?
    private let accountLogin = AccountLoginController()
    private let consoleLogin = ClaudeConsoleLoginController()
    private lazy var store = DemoData.isEnabled ? DemoData.makeStore() : StatusStore()
    private lazy var updater = AppUpdater(isEnabled: !DemoData.isEnabled)

    func applicationDidFinishLaunching(_ notification: Notification) {
        InputDiagnostics.start()
        _ = updater
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
        updateMenuTitle()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // AppKit delivers monitor callbacks on the main thread. Handle the
            // click now so a queued dismissal cannot close a newly opened panel.
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.dismissPopoverForOutsideClick()
            }
        }
        // Global monitors exclude this app. A click on the settings window
        // must also close the dashboard, then continue to the clicked control.
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return event }
                return PopoverOutsideClick.handle(event, clickedWindow: event.window,
                                                  popoverWindow: self.popover.contentViewController?.view.window,
                                                  statusItemWindow: self.statusItem.button?.window,
                                                  dismiss: { self.dismissPopoverForOutsideClick() },
                                                  focus: { WindowFocus.focusForClick($0) })
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
            // Activating the application also raises its main settings window.
            // Opening the dashboard should order and focus only the popover.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            Task { await store.refresh() }
        }
    }

    private func updateMenuTitle() {
        guard let button = statusItem.button else { return }
        let presentation = store.menuBarPresentation
        button.title = store.showCPUInMenu ? " " + presentation.text : ""
        button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        button.toolTip = store.showCPUInMenu ? presentation.description : "Mac Status · 사용량과 시스템 통계"
        button.setAccessibilityLabel(store.showCPUInMenu ? presentation.description : "Mac Status")
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
        settingsWindow?.contentViewController = NSHostingController(rootView: SettingsView(store: store, updater: updater, selectedTab: builder ? 1 : 0))
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

    private func dismissPopoverForOutsideClick() {
        // A newer click on another window takes precedence over an unfinished
        // dashboard-to-settings/login transition.
        pendingWindowPresentation = nil
        popover.performClose(nil)
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
        // Settings/login windows are presented by their explicit actions and
        // physical clicks. A status-item activation must never raise them.
        let target = PopoverFocus.activationTarget(
            popoverWindow: popover.contentViewController?.view.window,
            isPopoverShown: popover.isShown, keyWindow: NSApp.keyWindow, modalWindow: NSApp.modalWindow
        )
        target?.makeKey()
    }

    @objc private func openSettingsFromMenu() { showSettings(builder: false) }

    @objc private func checkForUpdatesFromMenu() {
        guard updater.canCheckForUpdates else { return }
        presentAfterPopoverCloses { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.updater.checkForUpdates()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdatesFromMenu) { return updater.canCheckForUpdates }
        return true
    }

    private func configureMenu() {
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Mac Status")
        let settings = NSMenuItem(title: "Mac Status 설정…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(settings)
        let updates = NSMenuItem(title: "업데이트 확인…", action: #selector(checkForUpdatesFromMenu), keyEquivalent: "")
        updates.target = self
        applicationMenu.addItem(updates)
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
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
    }
}
