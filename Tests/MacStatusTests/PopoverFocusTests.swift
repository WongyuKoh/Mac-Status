import AppKit
import XCTest
@testable import MacStatus

@MainActor
final class PopoverFocusTests: XCTestCase {
    func testVisiblePopoverIsTheOnlyActivationTargetWhenNoWindowHasFocus() {
        let popover = makeWindow()
        XCTAssertTrue(PopoverFocus.activationTarget(popoverWindow: popover, isPopoverShown: true,
                                                     keyWindow: nil, modalWindow: nil) === popover)
    }

    func testExistingSettingsAndChildKeyWindowsAreNeverReplacedOnActivation() {
        let popover = makeWindow()
        let settings = makeWindow()
        let sheet = makeWindow()
        popover.simulatedSheet = sheet
        for keyWindow in [settings, popover, sheet] {
            XCTAssertNil(PopoverFocus.activationTarget(popoverWindow: popover, isPopoverShown: true,
                                                      keyWindow: keyWindow, modalWindow: nil))
        }
    }

    func testActivationDoesNotRestoreAClosedPopoverOrSelectTheSettingsWindow() {
        let retainedPopover = makeWindow()
        let settings = makeWindow()
        // A retained window is not a request to reopen either UI. In particular,
        // activating the app must not fall back to an existing settings window.
        XCTAssertNil(PopoverFocus.activationTarget(popoverWindow: retainedPopover, isPopoverShown: false,
                                                  keyWindow: nil, modalWindow: nil))
        XCTAssertNil(PopoverFocus.activationTarget(popoverWindow: nil, isPopoverShown: false,
                                                  keyWindow: settings, modalWindow: nil))
    }

    func testMissingAndHiddenPopoverWindowsAreNotMadeKey() {
        let hiddenPopover = makeWindow(visible: false)
        hiddenPopover.simulatedSheet = makeWindow()
        XCTAssertNil(PopoverFocus.activationTarget(popoverWindow: nil, isPopoverShown: true,
                                                  keyWindow: nil, modalWindow: nil))
        XCTAssertNil(PopoverFocus.activationTarget(popoverWindow: hiddenPopover, isPopoverShown: true,
                                                  keyWindow: nil, modalWindow: nil))
    }

    func testPopoverAttachedSheetsKeepTheirOwnFocusTarget() {
        let popover = makeWindow()
        let sheet = makeWindow()
        let nestedSheet = makeWindow()
        popover.simulatedSheet = sheet
        sheet.simulatedSheet = nestedSheet
        XCTAssertTrue(PopoverFocus.activationTarget(popoverWindow: popover, isPopoverShown: true,
                                                     keyWindow: nil, modalWindow: nil) === nestedSheet)
        nestedSheet.simulatedVisible = false
        XCTAssertTrue(PopoverFocus.activationTarget(popoverWindow: popover, isPopoverShown: true,
                                                     keyWindow: nil, modalWindow: nil) === sheet)
    }

    func testVisibleModalBlocksPopoverFocusWithoutPromotingAnyOtherWindow() {
        let popover = makeWindow()
        let modal = makeWindow()
        XCTAssertNil(PopoverFocus.activationTarget(popoverWindow: popover, isPopoverShown: true,
                                                  keyWindow: nil, modalWindow: modal))
        modal.simulatedVisible = false
        XCTAssertTrue(PopoverFocus.activationTarget(popoverWindow: popover, isPopoverShown: true,
                                                     keyWindow: nil, modalWindow: modal) === popover)
    }

    func testHiddenPreviousKeyWindowDoesNotPreventPopoverKeyboardFocus() {
        let popover = makeWindow()
        let previousKeyWindow = makeWindow(visible: false)
        XCTAssertTrue(PopoverFocus.activationTarget(popoverWindow: popover, isPopoverShown: true,
                                                     keyWindow: previousKeyWindow, modalWindow: nil) === popover)
    }

    private func makeWindow(visible: Bool = true) -> PopoverFocusTestWindow {
        _ = NSApplication.shared
        return PopoverFocusTestWindow(visible: visible)
    }
}

@MainActor
private final class PopoverFocusTestWindow: NSWindow {
    var simulatedVisible: Bool
    var simulatedSheet: NSWindow?

    init(visible: Bool) {
        simulatedVisible = visible
        // No window is ordered or event dispatched by these policy tests.
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }

    override var isVisible: Bool { simulatedVisible }
    override var attachedSheet: NSWindow? { simulatedSheet }
}
