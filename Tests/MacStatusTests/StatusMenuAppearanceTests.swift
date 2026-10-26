import AppKit
import XCTest
@testable import MacStatus

@MainActor
final class StatusMenuAppearanceTests: XCTestCase {
    func testGroupedMenuSelectsAndDispatchesTheLogicalOptionTag() throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls: [Int] = []
        let options = groupedOptions()
        coordinator.update(button, configuration: config(options, selected: 1) { calls.append($0) })

        let menu = try XCTUnwrap(button.menu)
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), ["AI 사용량", "이 Mac"])
        XCTAssertTrue(menu.items.contains(where: \.isSeparatorItem))
        XCTAssertEqual(button.selectedItem?.tag, 1)
        XCTAssertNotEqual(button.indexOfSelectedItem, 1, "Headers must not be mistaken for logical options")
        XCTAssertEqual(menu.items.filter { $0.tag >= 0 }.map(\.title), options.map(\.title))

        coordinator.select(button)
        XCTAssertEqual(calls, [1])
        XCTAssertTrue(button.selectItem(withTag: 2))
        coordinator.select(button)
        XCTAssertEqual(calls, [1, 2])
    }

    func testHeadersAndSeparatorsNeverDispatchAnOption() throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls: [Int] = []
        coordinator.update(button, configuration: config(groupedOptions(), selected: 0) { calls.append($0) })
        let menu = try XCTUnwrap(button.menu)
        let decorations = menu.items.filter { $0.isSectionHeader || $0.isSeparatorItem }
        XCTAssertFalse(decorations.isEmpty)
        for item in decorations {
            XCTAssertEqual(item.tag, -2)
            XCTAssertFalse(item.isEnabled)
            button.select(item)
            coordinator.select(button)
        }
        XCTAssertTrue(calls.isEmpty)
    }

    func testSectionChangesWaitForTrackingToFinishAndKeepOldCallbacks() async throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls: [String] = []
        let old = groupedOptions()
        let changed = old.map { StatusMenuOption(title: $0.title, symbol: $0.symbol, section: "새 섹션") }
        coordinator.update(button, configuration: config(old, selected: 0) { calls.append("old \($0)") })
        let menu = try XCTUnwrap(button.menu)
        coordinator.menuWillOpen(menu)
        coordinator.update(button, configuration: config(changed, selected: 2) { calls.append("new \($0)") })
        XCTAssertTrue(button.menu === menu)
        XCTAssertEqual(menu.items.filter(\.isSectionHeader).map(\.title), ["AI 사용량", "이 Mac"])
        XCTAssertTrue(button.selectItem(withTag: 1))
        coordinator.menuDidClose(menu)
        coordinator.select(button)
        XCTAssertEqual(calls, ["old 1"])

        await settleMenuClose()
        let refreshed = try XCTUnwrap(button.menu)
        XCTAssertFalse(refreshed === menu)
        XCTAssertEqual(refreshed.items.filter(\.isSectionHeader).map(\.title), ["새 섹션"])
        XCTAssertEqual(button.selectedItem?.tag, 2)
        coordinator.select(button)
        XCTAssertEqual(calls, ["old 1", "new 2"])
    }

    func testActionMenuPreservesItsHiddenPlaceholderAndLogicalTags() throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        var calls: [Int] = []
        coordinator.update(button, configuration: config(groupedOptions(), selected: nil, action: true) { calls.append($0) })
        let placeholder = try XCTUnwrap(button.item(at: 0))
        XCTAssertEqual(placeholder.tag, -1)
        XCTAssertFalse(placeholder.isSectionHeader)
        button.select(placeholder)
        coordinator.select(button)
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(button.selectItem(withTag: 2))
        coordinator.select(button)
        XCTAssertEqual(calls, [2])
    }

    func testUngroupedOptionsRetainTheirOriginalIndicesAndNativeItemViews() throws {
        let (button, coordinator) = fixture()
        defer { coordinator.detach() }
        let options = [StatusMenuOption(title: "단일 값", symbol: "number"), StatusMenuOption(title: "합계")]
        coordinator.update(button, configuration: config(options, selected: 1) { _ in })
        let menu = try XCTUnwrap(button.menu)
        XCTAssertEqual(button.itemTitles, ["단일 값", "합계"])
        XCTAssertEqual(button.indexOfSelectedItem, 1)
        XCTAssertEqual(button.selectedItem?.tag, 1)
        for item in menu.items {
            XCTAssertNil(item.view, "Native AppKit rows retain keyboard and menu tracking behavior")
            XCTAssertNotNil(item.image, "Options with no explicit symbol still receive a fallback icon")
            XCTAssertNotNil(item.onStateImage)
        }
    }

    private func groupedOptions() -> [StatusMenuOption] {
        [
            .init(title: "Codex · 5시간 사용량", symbol: "clock", section: "AI 사용량"),
            .init(title: "Claude · 주간 사용량", symbol: "calendar", section: "AI 사용량"),
            .init(title: "CPU", symbol: "cpu", section: "이 Mac")
        ]
    }

    private func fixture() -> (StatusPopupButton, StatusMenuCoordinator) {
        _ = NSApplication.shared
        // Do not show a menu/window or dispatch user input from these tests.
        return (StatusPopupButton(frame: .zero, pullsDown: false), StatusMenuCoordinator())
    }

    private func config(_ options: [StatusMenuOption], selected: Int?, action: Bool = false,
                        onSelect: @escaping (Int) -> Void) -> StatusMenuCoordinator.Configuration {
        .init(title: "표시할 항목", displayValue: "선택 값", options: options, selectedIndex: selected,
              isActionMenu: action, isEnabled: true, onSelect: onSelect, onFocus: { _ in })
    }

    private func settleMenuClose() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
