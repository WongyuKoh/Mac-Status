import AppKit
import XCTest
@testable import MacStatus

@MainActor
final class WindowFocusTests: XCTestCase {
    func testTargetIsTheDeepestVisibleAttachedSheet() {
        let parent = makeWindow()
        let sheet = makeWindow()
        let nested = makeWindow()
        parent.simulatedSheet = sheet
        sheet.simulatedSheet = nested
        XCTAssertTrue(WindowFocus.target(for: parent, modalWindow: nil) === nested)
        sheet.simulatedSheet = nil
        XCTAssertTrue(WindowFocus.target(for: parent, modalWindow: nil) === sheet)
    }

    func testHiddenSheetDoesNotReceiveFocus() {
        let parent = makeWindow()
        parent.simulatedSheet = makeWindow(visible: false)
        XCTAssertTrue(WindowFocus.target(for: parent, modalWindow: nil) === parent)
    }

    func testVisibleApplicationModalTakesPriorityOverRequestedWindow() {
        let parent = makeWindow()
        let parentSheet = makeWindow()
        parent.simulatedSheet = parentSheet
        let modal = makeWindow()
        let modalSheet = makeWindow()
        modal.simulatedSheet = modalSheet
        XCTAssertTrue(WindowFocus.target(for: parent, modalWindow: modal) === modalSheet)
        modal.simulatedVisible = false
        XCTAssertTrue(WindowFocus.target(for: parent, modalWindow: modal) === parentSheet)
    }

    func testDeferredFocusFollowsASheetAttachedAfterPresentation() {
        let parent = makeWindow()
        let sheet = makeWindow()
        parent.simulatedSheet = sheet
        XCTAssertTrue(WindowFocus.deferredTarget(for: parent, modalWindow: nil, keyWindow: parent,
                                                isApplicationActive: true) === sheet)
        XCTAssertTrue(WindowFocus.deferredTarget(for: parent, modalWindow: nil, keyWindow: sheet,
                                                isApplicationActive: true) === sheet)
    }

    func testDeferredFocusDoesNotStealAnotherWindowsFocusOrReactivateApp() {
        let parent = makeWindow()
        let other = makeWindow()
        XCTAssertNil(WindowFocus.deferredTarget(for: parent, modalWindow: nil, keyWindow: other,
                                               isApplicationActive: true))
        XCTAssertNil(WindowFocus.deferredTarget(for: parent, modalWindow: nil, keyWindow: parent,
                                               isApplicationActive: false))
        parent.simulatedVisible = false
        XCTAssertNil(WindowFocus.deferredTarget(for: parent, modalWindow: nil, keyWindow: nil,
                                               isApplicationActive: true))
    }

    func testDeferredFocusPreservesVisibleNativeModal() {
        let parent = makeWindow()
        let modal = makeWindow()
        XCTAssertTrue(WindowFocus.deferredTarget(for: parent, modalWindow: modal, keyWindow: modal,
                                                isApplicationActive: true) === modal)
    }

    func testDropdownAcceptsTheFirstClickInAnInactiveWindow() {
        _ = NSApplication.shared
        let button = StatusPopupButton(frame: .zero, pullsDown: false)
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
    }

    private func makeWindow(visible: Bool = true) -> FocusTestWindow {
        _ = NSApplication.shared
        return FocusTestWindow(visible: visible)
    }
}

@MainActor
private final class FocusTestWindow: NSWindow {
    var simulatedVisible: Bool
    var simulatedSheet: NSWindow?

    init(visible: Bool) {
        simulatedVisible = visible
        super.init(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }

    override var isVisible: Bool { simulatedVisible }
    override var attachedSheet: NSWindow? { simulatedSheet }
}
