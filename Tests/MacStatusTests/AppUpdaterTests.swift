import Combine
import XCTest
@testable import MacStatus

@MainActor
final class AppUpdaterTests: XCTestCase {
    func testDisabledUpdaterNeverCreatesDriverOrChangesPreferences() {
        var creations = 0
        let updater = AppUpdater(isEnabled: false, currentVersion: "0.7.0", driverFactory: {
            creations += 1
            return FakeUpdateDriver()
        })
        updater.checkForUpdates()
        updater.setAutomaticallyChecksForUpdates(true)
        XCTAssertEqual(creations, 0)
        XCTAssertEqual(updater.currentVersion, "0.7.0")
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
    }

    func testCheckAvailabilityAndPreferenceChangesFollowDriver() {
        let driver = FakeUpdateDriver()
        let updater = AppUpdater(isEnabled: true, driverFactory: { driver })
        XCTAssertTrue(updater.canCheckForUpdates)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        updater.setAutomaticallyChecksForUpdates(false)
        XCTAssertFalse(driver.automaticallyChecksForUpdates)
        XCTAssertFalse(updater.automaticallyChecksForUpdates)
        driver.automatic.send(true)
        XCTAssertTrue(updater.automaticallyChecksForUpdates)
        driver.availability.send(false)
        updater.checkForUpdates()
        XCTAssertEqual(driver.checks, 1)
        driver.availability.send(true)
        XCTAssertTrue(updater.canCheckForUpdates)
    }
}

@MainActor
private final class FakeUpdateDriver: AppUpdateDriving {
    let availability = CurrentValueSubject<Bool, Never>(true)
    let automatic = CurrentValueSubject<Bool, Never>(true)
    var checks = 0
    var canCheckForUpdates: Bool { availability.value }
    var automaticallyChecksForUpdates: Bool {
        get { automatic.value }
        set { automatic.send(newValue) }
    }
    var checkAvailability: AnyPublisher<Bool, Never> { availability.eraseToAnyPublisher() }
    var automaticCheckChanges: AnyPublisher<Bool, Never> { automatic.eraseToAnyPublisher() }
    func checkForUpdates() { checks += 1 }
}
