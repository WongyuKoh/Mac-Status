import AppKit
import Combine
import Sparkle

@MainActor
protocol AppUpdateDriving: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var checkAvailability: AnyPublisher<Bool, Never> { get }
    var automaticCheckChanges: AnyPublisher<Bool, Never> { get }
    func checkForUpdates()
}

/// Sparkle owns download progress, signature validation, installation and relaunch.
/// Disabled/demo instances never construct Sparkle or read updater preferences.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    let currentVersion: String
    private var driver: (any AppUpdateDriving)?
    private var observations: Set<AnyCancellable> = []

    init(isEnabled: Bool = true,
         currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "개발 버전",
         driverFactory: (() -> any AppUpdateDriving)? = nil) {
        self.currentVersion = currentVersion
        guard isEnabled, !DemoData.isEnabled else { return }
        let driver = driverFactory?() ?? SparkleUpdateDriver()
        self.driver = driver
        canCheckForUpdates = driver.canCheckForUpdates
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
        driver.checkAvailability.sink { [weak self] available in
            MainActor.assumeIsolated { self?.canCheckForUpdates = available }
        }.store(in: &observations)
        driver.automaticCheckChanges.sink { [weak self] enabled in
            MainActor.assumeIsolated { self?.automaticallyChecksForUpdates = enabled }
        }.store(in: &observations)
    }

    func checkForUpdates() {
        guard canCheckForUpdates, let driver else { return }
        driver.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard let driver else { return }
        driver.automaticallyChecksForUpdates = enabled
        automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
    }
}

@MainActor
private final class SparkleUpdateDriver: AppUpdateDriving {
    // Sparkle keeps a weak delegate; retain the selection policy for every check.
    private let selectionPolicy = LatestUpdatePolicy()
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: selectionPolicy, userDriverDelegate: nil)

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var checkAvailability: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.canCheckForUpdates).eraseToAnyPublisher()
    }
    var automaticCheckChanges: AnyPublisher<Bool, Never> {
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).eraseToAnyPublisher()
    }
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

enum LatestUpdateSelection {
    /// Version comparison uses Sparkle's build ordering, never feed position,
    /// publication date, or a display version. Ties keep the first candidate.
    static func newest<Item>(in candidates: [Item], newerThan installedBuild: String,
                             version: (Item) -> String) -> Item? {
        let comparator = SUStandardVersionComparator.default
        var selected: Item?
        for candidate in candidates {
            let candidateBuild = version(candidate)
            guard comparator.compareVersion(candidateBuild, toVersion: installedBuild) == .orderedDescending else { continue }
            if let current = selected,
               comparator.compareVersion(candidateBuild, toVersion: version(current)) != .orderedDescending { continue }
            selected = candidate
        }
        return selected
    }
}

@MainActor
private final class LatestUpdatePolicy: NSObject, SPUUpdaterDelegate {
    func bestValidUpdate(in appcast: SUAppcast, for updater: SPUUpdater) -> SUAppcastItem? {
        guard let installedBuild = updater.hostBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
              !installedBuild.isEmpty else { return nil }
        // Sparkle has already applied OS, architecture, channel, rollout and
        // skipped-version rules. Select only among its eligible top-level items;
        // download/signature verification and installation stay with Sparkle.
        // With no newer candidate, nil preserves Sparkle's no-update diagnostics
        // and its final protection against reinstalling or downgrading.
        return LatestUpdateSelection.newest(in: appcast.items, newerThan: installedBuild, version: \.versionString)
    }
}
