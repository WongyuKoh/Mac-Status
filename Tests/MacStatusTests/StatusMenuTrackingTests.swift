import AppKit
import XCTest
@testable import MacStatus

@MainActor
final class StatusMenuTrackingTests: XCTestCase {
    func testRefreshKeepsTheOpenMenuAndDispatchesItsOriginalOptions() async throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var selected: [String] = []
        let oldIDs = ["cpu", "memory", "claude"]
        let newIDs = ["claude", "cpu"]
        coordinator.update(button, configuration: config(oldIDs, selected: 0) { selected.append(oldIDs[$0]) })
        let openMenu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(openMenu)
        coordinator.update(button, configuration: config(newIDs, selected: 1, enabled: false) { selected.append(newIDs[$0]) })
        XCTAssertTrue(button.menu === openMenu)
        XCTAssertEqual(button.numberOfItems, 3)
        XCTAssertEqual(button.indexOfSelectedItem, 0)
        XCTAssertTrue(button.isEnabled)

        button.selectItem(at: 1)
        coordinator.select(button)
        XCTAssertEqual(selected, ["memory"])
        coordinator.menuDidClose(openMenu)
        XCTAssertTrue(button.menu === openMenu, "The close callback must not modify menu structure")
        await settleMenuClose()
        XCTAssertFalse(button.menu === openMenu)
        XCTAssertEqual(button.itemTitles, newIDs)
        XCTAssertEqual(button.indexOfSelectedItem, 1)
        XCTAssertFalse(button.isEnabled)
    }

    func testCloseBeforeActionRetainsTheOldCallbackEvenWhenTitlesAreUnchanged() async throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls: [String] = []
        let titles = ["same A", "same B"]
        coordinator.update(button, configuration: config(titles, selected: 0) { index in
            calls.append("old \(index)")
            coordinator.update(button, configuration: self.config(titles, selected: 0) { calls.append("latest \($0)") })
        })
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.update(button, configuration: config(titles, selected: 1) { calls.append("intermediate \($0)") })
        button.selectItem(at: 1)
        coordinator.menuDidClose(menu)
        coordinator.select(button)
        XCTAssertEqual(calls, ["old 1"])
        await settleMenuClose()
        XCTAssertTrue(button.menu === menu, "Unchanged labels need no menu reconstruction")
        XCTAssertEqual(button.indexOfSelectedItem, 0)
        coordinator.select(button)
        XCTAssertEqual(calls, ["old 1", "latest 0"])
    }

    func testCancelAppliesOnlyTheNewestPendingRefreshWithoutAnAction() async throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls = 0
        coordinator.update(button, configuration: config(["old"], selected: 0) { _ in calls += 1 })
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.update(button, configuration: config(["intermediate"], selected: 0) { _ in calls += 1 })
        coordinator.update(button, configuration: config(["new A", "new B"], selected: 1) { _ in calls += 1 })
        coordinator.menuDidClose(menu)
        await settleMenuClose()
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(button.itemTitles, ["new A", "new B"])
        XCTAssertEqual(button.indexOfSelectedItem, 1)
    }

    func testRapidReopenDoesNotApplyThePreviousCloseUpdateWhileTrackingAgain() async throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls: [Int] = []
        coordinator.update(button, configuration: config(["old A", "old B"], selected: 0) { calls.append($0) })
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.update(button, configuration: config(["new"], selected: 0) { _ in XCTFail("Old menu must retain its action") })
        coordinator.menuDidClose(menu)
        coordinator.menuWillOpen(menu)
        await settleMenuClose()
        XCTAssertTrue(button.menu === menu)
        XCTAssertEqual(button.numberOfItems, 2)
        button.selectItem(at: 1)
        coordinator.select(button)
        XCTAssertEqual(calls, [1])
        coordinator.menuDidClose(menu)
        await settleMenuClose()
        XCTAssertEqual(button.itemTitles, ["new"])
    }

    func testDismantlingDiscardsDeferredUpdatesAndLateActions() async throws {
        let (button, coordinator) = fixture()
        var calls = 0
        coordinator.update(button, configuration: config(["old"], selected: 0) { _ in calls += 1 })
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.update(button, configuration: config(["new"], selected: 0) { _ in calls += 1 })
        coordinator.menuDidClose(menu)
        coordinator.detach()
        coordinator.select(button)
        await settleMenuClose()
        coordinator.update(button, configuration: config(["ignored"], selected: 0) { _ in calls += 1 })
        XCTAssertEqual(calls, 0)
        XCTAssertNil(button.target)
        XCTAssertNil(button.action)
        XCTAssertNil(menu.delegate)
        XCTAssertEqual(button.itemTitles, ["old"])
    }

    func testInvalidIndicesAndTheActionMenuPlaceholderNeverDispatch() {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls: [Int] = []
        coordinator.update(button, configuration: config(["one"], selected: 4) { calls.append($0) })
        XCTAssertNil(button.selectedItem)
        coordinator.select(button)
        XCTAssertTrue(calls.isEmpty)
        coordinator.update(button, configuration: config(["action"], selected: nil, action: true) { calls.append($0) })
        button.selectItem(at: 0)
        coordinator.select(button)
        XCTAssertTrue(calls.isEmpty)
        button.selectItem(at: 1)
        coordinator.select(button)
        XCTAssertEqual(calls, [0])
    }

    private func fixture() -> (StatusPopupButton, StatusMenuCoordinator) {
        _ = NSApplication.shared
        return (StatusPopupButton(frame: .zero, pullsDown: false), StatusMenuCoordinator())
    }

    private func config(_ titles: [String], selected: Int?, action: Bool = false, enabled: Bool = true,
                        onSelect: @escaping (Int) -> Void) -> StatusMenuCoordinator.Configuration {
        .init(title: "Fixture", displayValue: "Displayed value", options: titles.map { StatusMenuOption(title: $0) },
              selectedIndex: selected, isActionMenu: action, isEnabled: enabled, onSelect: onSelect, onFocus: { _ in })
    }

    private func settleMenuClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
