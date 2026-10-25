import AppKit
import XCTest
@testable import MacStatus

@MainActor
final class EditorTabControlTests: XCTestCase {
    func testFullBoundsReceiveClicksForSelectedAndUnselectedTabs() {
        for width in [205.0, 310.0] {
            let parent = NSView(frame: NSRect(x: 0, y: 0, width: 680, height: 80))
            let button = EditorTabControl(frame: NSRect(x: 16, y: 12, width: width, height: 34))
            parent.addSubview(button)
            for selected in [false, true] {
                button.isTabSelected = selected
                for x in [17.0, 16 + width / 2, 15 + width] {
                    for y in [13.0, 29.0, 45.0] {
                        XCTAssertTrue(parent.hitTest(NSPoint(x: x, y: y)) === button,
                                      "Full tab must receive clicks at \(x),\(y), selected=\(selected)")
                    }
                }
            }
            XCTAssertFalse(parent.hitTest(NSPoint(x: 8, y: 29)) === button)
        }
    }

    func testButtonUsesLatestActionAndIgnoresClicksWhenDisabled() {
        let button = EditorTabControl(frame: NSRect(x: 0, y: 0, width: 205, height: 34))
        var oldCalls = 0
        var newCalls = 0
        button.onActivate = { oldCalls += 1 }
        button.performClick(nil)
        XCTAssertEqual(oldCalls, 1)
        button.onActivate = { newCalls += 1 }
        button.performClick(nil)
        XCTAssertEqual(oldCalls, 1)
        XCTAssertEqual(newCalls, 1)
        button.isEnabled = false
        button.performClick(nil)
        XCTAssertEqual(newCalls, 1)
    }

    func testFirstClickAndAccessibleSelection() {
        let button = EditorTabControl(frame: .zero)
        button.setAccessibilityLabel("API 연결")
        XCTAssertTrue(button.acceptsFirstMouse(for: nil))
        XCTAssertEqual(button.accessibilityLabel(), "API 연결")
        XCTAssertEqual(button.accessibilityRole(), .radioButton)
        XCTAssertEqual(button.accessibilityValue() as? Int, 0)
        button.isTabSelected = true
        XCTAssertEqual(button.accessibilityValue() as? Int, 1)
    }
}
