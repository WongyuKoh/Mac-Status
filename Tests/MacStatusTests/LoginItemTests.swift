import XCTest
@testable import MacStatus

@MainActor
final class LoginItemTests: XCTestCase {
    func testDisabledLoginItemServiceDoesNotReadOrWriteSystemState() {
        let preferences = isolatedPreferences()
        defer { preferences.defaults.removePersistentDomain(forName: preferences.name) }
        var statusReads = 0
        let store = StatusStore(defaults: preferences.defaults, start: false, services: .init(
            hasSavedToken: { _ in false },
            loginItemStatus: { statusReads += 1; return true },
            updateLoginItem: nil
        ))
        XCTAssertFalse(store.canManageLoginItem)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(statusReads, 0)
        store.setLoginItem(true)
        store.setLoginItem(false)
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertEqual(statusReads, 0)
        XCTAssertNil(store.notice)
    }

    func testInjectedLoginItemServiceControlsEnabledState() {
        let preferences = isolatedPreferences()
        defer { preferences.defaults.removePersistentDomain(forName: preferences.name) }
        var enabled = true
        var statusReads = 0
        var updates: [Bool] = []
        let store = StatusStore(defaults: preferences.defaults, start: false, services: .init(
            hasSavedToken: { _ in false },
            loginItemStatus: { statusReads += 1; return enabled },
            updateLoginItem: { requested in
                updates.append(requested)
                enabled = requested
                return enabled
            }
        ))
        XCTAssertTrue(store.canManageLoginItem)
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(statusReads, 1)
        store.setLoginItem(false)
        XCTAssertFalse(store.launchAtLogin)
        store.setLoginItem(true)
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertEqual(updates, [false, true])
        XCTAssertEqual(statusReads, 1, "Updates use the backend result without a second system read")
        XCTAssertNil(store.notice)
    }

    func testRejectedEnableExplainsRequiredPermission() {
        let preferences = isolatedPreferences()
        defer { preferences.defaults.removePersistentDomain(forName: preferences.name) }
        var updates: [Bool] = []
        let store = StatusStore(defaults: preferences.defaults, start: false, services: .init(
            hasSavedToken: { _ in false },
            loginItemStatus: { false },
            updateLoginItem: { requested in updates.append(requested); return false }
        ))
        store.setLoginItem(true)
        XCTAssertEqual(updates, [true])
        XCTAssertFalse(store.launchAtLogin)
        XCTAssertTrue(store.notice?.contains("허용") == true)
    }

    func testFailedUpdateKeepsKnownStateAndReportsFailure() {
        let preferences = isolatedPreferences()
        defer { preferences.defaults.removePersistentDomain(forName: preferences.name) }
        var updates: [Bool] = []
        let store = StatusStore(defaults: preferences.defaults, start: false, services: .init(
            hasSavedToken: { _ in false },
            loginItemStatus: { true },
            updateLoginItem: { requested in
                updates.append(requested)
                throw LoginItemTestError.denied
            }
        ))
        store.setLoginItem(false)
        XCTAssertEqual(updates, [false])
        XCTAssertTrue(store.launchAtLogin)
        XCTAssertTrue(store.notice?.contains("설정하지 못했습니다") == true)
    }

    private func isolatedPreferences() -> (defaults: UserDefaults, name: String) {
        let name = "MacStatus.LoginItemTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.set(true, forKey: "builtins.wakatime.v1")
        defaults.set(true, forKey: "builtins.apiOptIn.v1")
        return (defaults, name)
    }
}

private enum LoginItemTestError: Error { case denied }
