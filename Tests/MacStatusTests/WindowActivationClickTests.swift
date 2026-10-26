import AppKit
import SwiftUI
import XCTest
@testable import MacStatus

@MainActor
final class WindowActivationClickTests: XCTestCase {
    func testPlainButtonReceivesTheWindowActivationClick() throws {
        guard #available(macOS 15.0, *) else {
            throw XCTSkip("SwiftUI window activation events require macOS 15.")
        }

        _ = NSApplication.shared
        let controller = NSHostingController(rootView: PlainButtonProbe(label: "Before")
            .acceptsWindowActivationClicks())
        let window = makeHiddenWindow(controller: controller)
        defer { window.close() }

        let event = try makeMouseEvent(in: window)
        let hitView = try XCTUnwrap(controller.view.hitTest(NSPoint(x: 80, y: 50)))
        XCTAssertTrue(hitView.acceptsFirstMouse(for: event))
        XCTAssertFalse(window.isVisible)
    }

    func testOrdinaryHostingControllerKeepsItsRootViewLifecycle() throws {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: PlainButtonProbe(label: "Before")
            .acceptsWindowActivationClicks())
        let window = makeHiddenWindow(controller: controller)
        defer { window.close() }

        let originalHostingView = controller.view
        assertOrdinaryHostingView(controller)
        controller.rootView = PlainButtonProbe(label: "After").acceptsWindowActivationClicks()
        controller.view.layoutSubtreeIfNeeded()

        XCTAssertTrue(window.contentViewController === controller)
        XCTAssertTrue(controller.view === originalHostingView)
        assertOrdinaryHostingView(controller)
        if #available(macOS 15.0, *) {
            XCTAssertTrue(controller.view.acceptsFirstMouse(for: try makeMouseEvent(in: window)))
        }
        XCTAssertFalse(window.isVisible)
    }

    private func makeHiddenWindow<Content: View>(controller: NSHostingController<Content>) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = NSRect(x: 0, y: 0, width: 240, height: 120)
        controller.view.layoutSubtreeIfNeeded()
        return window
    }

    private func makeMouseEvent(in window: NSWindow) throws -> NSEvent {
        // Only query acceptance; never dispatch this event or show the window.
        try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                                       location: NSPoint(x: 80, y: 50), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func assertOrdinaryHostingView<Content: View>(_ controller: NSHostingController<Content>,
                                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(controller.view is NSHostingView<Content>, file: file, line: line)
    }
}

private struct PlainButtonProbe: View {
    let label: String

    var body: some View {
        Button(label) {}
            .buttonStyle(.plain)
            .frame(width: 200, height: 80)
            .contentShape(Rectangle())
    }
}
