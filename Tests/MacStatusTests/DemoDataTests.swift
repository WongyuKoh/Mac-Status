import XCTest
@testable import MacStatus

@MainActor
final class DemoDataTests: XCTestCase {
    func testDemoDataIsIndependentFromStandardPreferencesAndOtherDemoInstances() async throws {
        let standardBefore = UserDefaults.standard.dictionaryRepresentation()
        let first = DemoData.makeStore(now: Date(timeIntervalSince1970: 1_800_000_000))
        let second = DemoData.makeStore(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(Set(first.templates.map(\.kind)), Set([.codex, .claude, .wakatime, .cpu, .memory, .storage, .temperature]))
        XCTAssertTrue(first.codexConnected)
        XCTAssertTrue(first.claudeConnected)
        XCTAssertFalse(first.claudeAPIConnected)
        XCTAssertFalse(first.useWakaTimeConfiguration)
        let cpu = try XCTUnwrap(first.templates.first { $0.kind == .cpu })
        first.setEnabled(cpu.id, false)
        first.setMenuCPU(false)
        XCTAssertTrue(second.systemTemplates.contains { $0.kind == .cpu })
        XCTAssertTrue(second.showCPUInMenu)
        XCTAssertTrue(NSDictionary(dictionary: standardBefore).isEqual(to: UserDefaults.standard.dictionaryRepresentation()))
    }

    func testManualRefreshRemainsSyntheticAndKeepsFixtureTimestamps() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let store = DemoData.makeStore(now: timestamp)
        let originals = store.readings
        await store.refresh(force: true)
        for template in store.templates {
            XCTAssertEqual(store.reading(for: template), originals[template.id])
            XCTAssertEqual(store.reading(for: template).updatedAt, timestamp)
        }
        let memory = try XCTUnwrap(store.templates.first { $0.kind == .memory })
        XCTAssertEqual(store.reading(for: memory).value, 16.2)
        XCTAssertEqual(store.reading(for: memory).limit, 32)
        let claude = try XCTUnwrap(store.templates.first { $0.kind == .claude })
        XCTAssertEqual(store.reading(for: claude).details.first { $0.label == "API 토큰" }?.value, "USD 120.00")
        XCTAssertFalse(store.isRefreshing)
    }

    func testOnlyExplicitDemoFlagOrPreviewBundleEnableDemo() {
        XCTAssertTrue(DemoData.enabled(arguments: ["MacStatus", "--demo"], bundleIdentifier: "com.kwg.macstatus"))
        XCTAssertTrue(DemoData.enabled(arguments: ["MacStatus"], bundleIdentifier: "com.kwg.macstatus.preview"))
        XCTAssertFalse(DemoData.enabled(arguments: ["MacStatus", "--preview"], bundleIdentifier: "com.kwg.macstatus"))
        XCTAssertFalse(DemoData.enabled(arguments: ["MacStatus"], bundleIdentifier: nil))
    }

    func testDemoCannotEnableOrDisableSystemLoginItems() {
        let store = DemoData.makeStore()
        XCTAssertFalse(store.canManageLoginItem)
        XCTAssertFalse(store.launchAtLogin)
        store.setLoginItem(true)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertNil(store.notice)
        store.setLoginItem(false)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertNil(store.notice)
    }
}
