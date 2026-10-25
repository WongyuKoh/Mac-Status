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
    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

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
