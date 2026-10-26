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

    func testLatestBuildWinsRegardlessOfFeedOrderDisplayVersionOrDate() {
        let candidates = [
            UpdateCandidate(build: "9", display: "99.0.0", published: 3_000),
            UpdateCandidate(build: "100", display: "1.0.0", published: 1_000),
            UpdateCandidate(build: "10", display: "2.0.0", published: 2_000)
        ]
        for feed in [candidates, Array(candidates.reversed()), [candidates[2], candidates[0], candidates[1]]] {
            let selected = LatestUpdateSelection.newest(in: feed, newerThan: "8", version: \.build)
            XCTAssertEqual(selected?.build, "100")
            XCTAssertEqual(selected?.display, "1.0.0")
        }
    }

    func testInstalledAndOlderBuildsNeverProduceAnUpdate() {
        XCTAssertNil(LatestUpdateSelection.newest(in: ["9", "99", "100"], newerThan: "100", version: { $0 }))
        XCTAssertNil(LatestUpdateSelection.newest(in: [String](), newerThan: "100", version: { $0 }))
        XCTAssertEqual(LatestUpdateSelection.newest(in: ["100", "101", "9"], newerThan: "100", version: { $0 }), "101")
    }

    func testMultiDigitVersionComponentsUseSparkleOrdering() {
        XCTAssertEqual(LatestUpdateSelection.newest(in: ["0.7.9", "0.7.10", "0.7.2"], newerThan: "0.7.1", version: { $0 }), "0.7.10")
    }

    func testEqualBuildsKeepTheFirstEligibleItem() {
        let first = UpdateCandidate(build: "100", display: "first", published: 1_000)
        let second = UpdateCandidate(build: "100", display: "second", published: 2_000)
        XCTAssertEqual(LatestUpdateSelection.newest(in: [first, second], newerThan: "99", version: \.build)?.display, "first")
    }
}

private struct UpdateCandidate {
    let build: String
    let display: String
    let published: Int
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
