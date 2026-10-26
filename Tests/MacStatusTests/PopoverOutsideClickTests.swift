import AppKit
import XCTest
@testable import MacStatus

@MainActor
final class PopoverOutsideClickTests: XCTestCase {
    func testSettingsClickClosesThenFocusesWithoutConsumingTheClick() throws {
        let popover = makeWindow()
        let settings = makeWindow(titled: true)
        let event = try mouseDown(.leftMouseDown)
        var actions: [String] = []

        let forwarded = PopoverOutsideClick.handle(event, clickedWindow: settings,
                                                  popoverWindow: popover, statusItemWindow: nil,
                                                  dismiss: { actions.append("close") },
                                                  focus: { window in
            XCTAssertTrue(window === settings)
            actions.append("focus")
        })

        XCTAssertEqual(actions, ["close", "focus"])
        XCTAssertTrue(forwarded === event, "The original click must still reach the selected settings tab")
        XCTAssertEqual(forwarded.type, .leftMouseDown)
        XCTAssertFalse(settings.isVisible)
        XCTAssertFalse(popover.isVisible)
    }

    func testEveryMouseDownButtonDismissesForAnOutsideSettingsWindow() throws {
        let popover = makeWindow()
        let settings = makeWindow(titled: true)
        for type in [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            let event = try mouseDown(type)
            var dismissals = 0
            var focuses = 0
            let forwarded = PopoverOutsideClick.handle(event, clickedWindow: settings,
                                                      popoverWindow: popover, statusItemWindow: nil,
                                                      dismiss: { dismissals += 1 }, focus: { _ in focuses += 1 })
            XCTAssertEqual(dismissals, 1)
            XCTAssertEqual(focuses, 1)
            XCTAssertTrue(forwarded === event)
        }
    }

    func testPopoverChildrenAndSheetsKeepThePopoverOpen() throws {
        let popover = makeWindow()
        let child = makeWindow(titled: true)
        child.simulatedParent = popover
        let sheet = makeWindow(titled: true)
        sheet.simulatedSheetParent = child
        let nestedChild = makeWindow(titled: true)
        nestedChild.simulatedParent = sheet
        let event = try mouseDown(.leftMouseDown)

        for window in [popover, child, sheet, nestedChild] {
            XCTAssertFalse(PopoverOutsideClick.shouldDismiss(for: window, popoverWindow: popover, statusItemWindow: nil))
            let forwarded = PopoverOutsideClick.handle(event, clickedWindow: window,
                                                      popoverWindow: popover, statusItemWindow: nil,
                                                      dismiss: { XCTFail("Popover content must remain open") },
                                                      focus: { _ in XCTFail("Popover child focus must remain untouched") })
            XCTAssertTrue(forwarded === event)
        }
    }

    func testStatusItemAndUnrelatedBorderlessMenusAreNotOutsideSettingsClicks() {
        let popover = makeWindow()
        // Even if a status-item host can become main, its own toggle action must run.
        let statusItem = makeWindow(main: true)
        let menu = makeWindow()
        XCTAssertFalse(PopoverOutsideClick.shouldDismiss(for: statusItem, popoverWindow: popover, statusItemWindow: statusItem))
        XCTAssertFalse(PopoverOutsideClick.shouldDismiss(for: menu, popoverWindow: popover, statusItemWindow: statusItem))
        XCTAssertFalse(PopoverOutsideClick.shouldDismiss(for: nil, popoverWindow: popover, statusItemWindow: statusItem))
        XCTAssertFalse(PopoverOutsideClick.shouldDismiss(for: makeWindow(titled: true), popoverWindow: nil, statusItemWindow: statusItem))
    }

    func testIndependentMainWindowIsDismissedEvenWithoutATitleBar() {
        let popover = makeWindow()
        let borderlessEditor = makeWindow(main: true)
        XCTAssertTrue(PopoverOutsideClick.shouldDismiss(for: borderlessEditor, popoverWindow: popover, statusItemWindow: nil))
    }

    func testKeyboardInputPassesThroughWithoutClosingOrChangingFocus() throws {
        let popover = makeWindow()
        let settings = makeWindow(titled: true)
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "", charactersIgnoringModifiers: "",
                                                 isARepeat: false, keyCode: 53))
        let forwarded = PopoverOutsideClick.handle(event, clickedWindow: settings,
                                                  popoverWindow: popover, statusItemWindow: nil,
                                                  dismiss: { XCTFail("This monitor only handles mouse-down events") },
                                                  focus: { _ in XCTFail("Keyboard focus must remain unchanged") })
        XCTAssertTrue(forwarded === event)
    }

    func testWindowRelationshipCyclesTerminateAndStillFindASheetAncestor() {
        let popover = makeWindow()
        let first = makeWindow(titled: true)
        let second = makeWindow(titled: true)
        first.simulatedParent = second
        second.simulatedParent = first
        XCTAssertTrue(PopoverOutsideClick.shouldDismiss(for: first, popoverWindow: popover, statusItemWindow: nil))

        second.simulatedSheetParent = popover
        XCTAssertFalse(PopoverOutsideClick.shouldDismiss(for: first, popoverWindow: popover, statusItemWindow: nil))
    }

    private func mouseDown(_ type: NSEvent.EventType) throws -> NSEvent {
        // Construct an event for the handler only; never post it to a user window.
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 40),
                                       modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func makeWindow(titled: Bool = false, main: Bool = false) -> PopoverClickTestWindow {
        _ = NSApplication.shared
        return PopoverClickTestWindow(titled: titled, main: main)
    }
}

@MainActor
private final class PopoverClickTestWindow: NSWindow {
    weak var simulatedParent: NSWindow?
    weak var simulatedSheetParent: NSWindow?
    private let simulatedMain: Bool

    init(titled: Bool, main: Bool) {
        simulatedMain = main
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: titled ? [.titled] : .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }

    override var parent: NSWindow? {
        get { simulatedParent }
        set { simulatedParent = newValue }
    }
    override var sheetParent: NSWindow? { simulatedSheetParent }
    override var canBecomeMain: Bool { simulatedMain }
}
