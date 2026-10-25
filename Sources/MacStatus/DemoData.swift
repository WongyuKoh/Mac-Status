import Foundation

/// Public screenshots render the real views using synthetic data and an
/// in-memory preferences store. No account, network, or credential source is used.
@MainActor
enum DemoData {
    static var isEnabled: Bool {
        enabled(arguments: CommandLine.arguments, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    static func enabled(arguments: [String], bundleIdentifier: String?) -> Bool {
        arguments.contains("--demo") || bundleIdentifier == "com.kwg.macstatus.preview"
    }

    static func makeStore(now: Date = Date()) -> StatusStore {
        let defaults = DemoMemoryPreferences(values: [
            "builtins.wakatime.v1": true,
            "builtins.apiOptIn.v1": true,
            "showCPUInMenu": true,
            "wakatime.useExistingConfiguration": false
        ])
        let store = StatusStore(defaults: defaults, start: false, services: .init(
            readMetric: { template in reading(for: template.kind, now: now) },
            clearSession: { _ in },
            deleteToken: { _ in true },
            hasSavedToken: { _ in false },
            now: { now }
        ))
        store.templates = MetricTemplate.defaults + [StatusStore.wakaTimeTemplate()]
        store.codexConnected = true
        store.claudeConnected = true
        store.claudeAPIConnected = false
        store.launchAtLogin = false
        store.useWakaTimeConfiguration = false
        for template in store.templates {
            store.readings[template.id] = reading(for: template.kind, now: now)
            if template.kind == .cpu {
                store.histories[template.id] = [9, 12, 11, 17, 14, 20, 16, 18]
            }
        }
        store.lastRefresh = now
        return store
    }

    private static func reading(for kind: MetricKind, now: Date) -> MetricReading {
        let sessionReset = now.addingTimeInterval(2 * 3_600 + 35 * 60)
        let weekReset = now.addingTimeInterval(4 * 86_400 + 8 * 3_600)
        switch kind {
        case .codex:
            return .init(value: 32, limit: 100, subtitle: "데모 · 구독 사용량", updatedAt: now, details: [
                .init(label: "5시간", value: "32% 사용 · 68% 남음", fraction: 0.32, resetAt: sessionReset, role: .session),
                .init(label: "주간 전체", value: "44% 사용 · 56% 남음", fraction: 0.44, resetAt: weekReset, role: .weekly),
                .init(label: "크레딧 잔액", value: "75 크레딧", role: .credits, note: "공개 화면을 위한 예시 수치입니다.")
            ])
        case .claude:
            return .init(value: 21, limit: 100, subtitle: "데모 · 구독 사용량", updatedAt: now, details: [
                .init(label: "5시간", value: "21% 사용 · 79% 남음", fraction: 0.21, resetAt: sessionReset, role: .session),
                .init(label: "주간 전체", value: "38% 사용 · 62% 남음", fraction: 0.38, resetAt: weekReset, role: .weekly),
                .init(label: "API 토큰", value: "USD 120.00", role: .credits, note: "공개 화면을 위한 예시 수치입니다."),
                .init(label: "클라우드 세션 크레딧", value: "USD 6.50 / 50.00 사용", fraction: 0.13, role: .credits, note: "공개 화면을 위한 예시 수치입니다."),
                .init(label: "추가 크레딧 사용", value: "비활성화", role: .credits)
            ])
        case .wakatime:
            return .init(value: 2 + 35.0 / 60, text: "2시간 35분", subtitle: "데모 · 오늘 기록 시간", updatedAt: now, details: [
                .init(label: "오늘 코딩 시간", value: "2시간 35분", note: "실제 계정이 아닌 예시 데이터입니다."),
                .init(label: "최근 7일", value: "18시간 20분"),
                .init(label: "프로젝트 1 · Demo App", value: "1시간 40분", fraction: 100.0 / 155),
                .init(label: "프로젝트 2 · Sample Website", value: "55분", fraction: 55.0 / 155),
                .init(label: "언어 1 · Swift", value: "1시간 40분", fraction: 100.0 / 155),
                .init(label: "언어 2 · TypeScript", value: "55분", fraction: 55.0 / 155)
            ])
        case .cpu:
            return .init(value: 18, limit: 100, subtitle: "데모 · CPU 사용량", updatedAt: now, details: [
                .init(label: "사용자", value: "12%", fraction: 0.12),
                .init(label: "시스템", value: "6%", fraction: 0.06)
            ])
        case .memory:
            return .init(value: 16.2, limit: 32, subtitle: "데모 · 전체 32 GB", updatedAt: now)
        case .storage:
            return .init(value: 256, limit: 512, subtitle: "데모 · 전체 512 GB", updatedAt: now)
        case .temperature:
            return .init(value: 48, subtitle: "데모 · CPU 센서 · 정상", updatedAt: now)
        default:
            return .setup("데모에서는 외부 서비스에 연결하지 않습니다.")
        }
    }
}

/// UserDefaults-compatible storage that never persists preferences or falls
/// through to the standard account's domains.
private final class DemoMemoryPreferences: UserDefaults, @unchecked Sendable {
    private let valueLock = NSLock()
    private var values: [String: Any]

    init(values: [String: Any]) {
        self.values = values
        super.init(suiteName: "com.kwg.macstatus.preview.memory.\(UUID().uuidString)")!
    }

    override func object(forKey defaultName: String) -> Any? {
        valueLock.lock()
        defer { valueLock.unlock() }
        return values[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        valueLock.lock()
        defer { valueLock.unlock() }
        values[defaultName] = value
    }

    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { set(nil as Any?, forKey: defaultName) }
    override func bool(forKey defaultName: String) -> Bool { object(forKey: defaultName) as? Bool ?? false }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }

    override func dictionaryRepresentation() -> [String: Any] {
        valueLock.lock()
        defer { valueLock.unlock() }
        return values
    }
}
