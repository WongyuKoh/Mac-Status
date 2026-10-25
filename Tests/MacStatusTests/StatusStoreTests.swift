import XCTest
@testable import MacStatus

@MainActor
final class StatusStoreTests: XCTestCase {
    func testUnconfiguredOpenAIDefaultsAreHiddenWhileConfiguredOnesRemain() async throws {
        let cost = StatusStore.openAICostTemplate()
        let tokens = StatusStore.openAITokensTemplate()
        let preferences = try StoreTestPreferences(templates: [cost, tokens])
        defer { preferences.remove() }
        preferences.defaults.removeObject(forKey: "builtins.apiOptIn.v1")
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(hasSavedToken: { $0 == tokens.id }))
        XCTAssertFalse(store.templates.first { $0.id == cost.id }!.isEnabled)
        XCTAssertTrue(store.templates.first { $0.id == tokens.id }!.isEnabled)
        store.setEnabled(cost.id, true)
        XCTAssertTrue(StatusStore(defaults: preferences.defaults, start: false).templates.first { $0.id == cost.id }!.isEnabled)
    }

    func testConsoleConnectionMergesAPIBalanceIntoClaudeAndRejectsAnOldCompletion() async throws {
        let claude = MetricTemplate(name: "Claude", kind: .claude)
        let preferences = try StoreTestPreferences(templates: [claude])
        defer { preferences.remove() }
        let store = StatusStore(defaults: preferences.defaults, start: false, services: .init(clearSession: { _ in }))
        store.readings[claude.id] = .init(value: 20, details: [.init(label: "API 토큰", value: "USD 500.00", role: .credits)])
        let generation = store.connectionGeneration(for: .claudeAPI)
        XCTAssertTrue(store.completeConnection(.claudeAPI, reading: .init(value: 0, subtitle: "API credits"), expectedGeneration: generation))
        XCTAssertTrue(store.claudeAPIConnected)
        XCTAssertEqual(store.reading(for: claude).details.last?.value, "$0.00")
        XCTAssertTrue(store.customTemplates.isEmpty)
        store.disconnect(.claudeAPI)
        XCTAssertFalse(store.completeConnection(.claudeAPI, reading: .init(value: 999), expectedGeneration: generation))
        XCTAssertEqual(store.reading(for: claude).details.count, 1)
    }

    func testWakaTimeUpgradeInstallsOnceAndPreservesLaterRemoval() async throws {
        let original = MetricTemplate(name: "CPU", kind: .cpu)
        let preferences = try StoreTestPreferences(templates: [original])
        defer { preferences.remove() }
        preferences.defaults.removeObject(forKey: "builtins.wakatime.v1")
        let store = StatusStore(defaults: preferences.defaults, start: false, services: .init(deleteToken: { _ in true }))
        let wakaTime = try XCTUnwrap(store.templates.first { $0.kind == .wakatime })
        XCTAssertEqual(store.templates.first?.id, original.id)
        XCTAssertEqual(store.activityTemplates.map(\.id), [wakaTime.id])
        XCTAssertFalse(store.customTemplates.contains { $0.id == wakaTime.id })
        XCTAssertEqual(StatusStore(defaults: preferences.defaults, start: false).activityTemplates.count, 1)
        XCTAssertTrue(store.remove(wakaTime.id))
        XCTAssertTrue(StatusStore(defaults: preferences.defaults, start: false).activityTemplates.isEmpty)
    }

    func testWakaTimeConfigurationOptOutPersistsAndInvalidatesAnOlderRead() async throws {
        let metric = StatusStore.wakaTimeTemplate()
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        let gate = StoreReadGate()
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { _ in await gate.read() }))
        let pending = Task { await store.refresh(force: true) }
        await gate.waitUntilStarted()
        store.setWakaTimeConfiguration(false)
        gate.finish(.init(value: 9, text: "9시간"))
        await pending.value
        XCTAssertNil(store.readings[metric.id])
        XCTAssertFalse(store.useWakaTimeConfiguration)
        XCTAssertFalse(StatusStore(defaults: preferences.defaults, start: false).useWakaTimeConfiguration)
    }

    func testPreferencesUseTheInjectedStore() async throws {
        let preferences = try StoreTestPreferences(templates: [])
        defer { preferences.remove() }
        preferences.defaults.set(false, forKey: "showCPUInMenu")
        preferences.defaults.set(true, forKey: "web.codex.connected")
        let store = StatusStore(defaults: preferences.defaults, start: false)
        XCTAssertFalse(store.showCPUInMenu)
        XCTAssertTrue(store.codexConnected)
        store.setMenuCPU(true)
        XCTAssertTrue(preferences.defaults.bool(forKey: "showCPUInMenu"))
        XCTAssertTrue(StatusStore(defaults: preferences.defaults, start: false).showCPUInMenu)
    }

    func testDisconnectRejectsAnEarlierReadAndLoginCompletion() async throws {
        let metric = MetricTemplate(name: "Codex", kind: .codex)
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "web.codex.connected")
        let gate = StoreReadGate()
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { _ in await gate.read() }, clearSession: { _ in }))
        let originalGeneration = store.connectionGeneration(for: .codex)
        let pending = Task { await store.refresh(force: true) }
        await gate.waitUntilStarted()
        store.disconnect(.codex)
        gate.finish(.init(value: 80, limit: 100, subtitle: "obsolete account"))
        await pending.value

        XCTAssertFalse(store.codexConnected)
        XCTAssertEqual(store.reading(for: metric).state, .needsSetup)
        XCTAssertNil(store.reading(for: metric).value)
        XCTAssertNil(store.histories[metric.id])
        XCTAssertFalse(store.isRefreshing)
        XCTAssertFalse(store.completeConnection(.codex, reading: .init(value: 80), expectedGeneration: originalGeneration))
        XCTAssertFalse(store.codexConnected)
    }

    func testSavingDuringAReadKeepsTheNewRequestAndDiscardsOldData() async throws {
        var metric = publicMetric(endpoint: "https://example.com/old")
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        let old = StoreReadGate()
        let replacement = StoreReadGate()
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { template in
                                    await (template.endpoint.hasSuffix("/old") ? old : replacement).read()
                                }))
        let oldRequest = Task { await store.refresh(force: true) }
        await old.waitUntilStarted()
        metric.endpoint = "https://example.com/new"
        try store.save(metric)
        let newRequest = Task { await store.refresh() }
        await replacement.waitUntilStarted()

        old.finish(.init(value: 10, limit: 100))
        await oldRequest.value
        XCTAssertTrue(store.isRefreshing, "Finishing the obsolete request must not clear the newer in-flight marker")
        XCTAssertNil(store.readings[metric.id])

        replacement.finish(.init(value: 90, limit: 100))
        await newRequest.value
        XCTAssertFalse(store.isRefreshing)
        XCTAssertEqual(store.reading(for: metric).value, 90)
        XCTAssertEqual(store.histories[metric.id], [90])
    }

    func testReauthenticationReplacesTheAccountHistoryAndRejectsAnOlderPoll() async throws {
        let metric = MetricTemplate(name: "Codex", kind: .codex)
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "web.codex.connected")
        let oldAccount = StoreReadGate()
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { _ in await oldAccount.read() }))
        store.histories[metric.id] = [90, 95]
        let pending = Task { await store.refresh(force: true) }
        await oldAccount.waitUntilStarted()
        XCTAssertTrue(store.completeConnection(.codex, reading: .init(value: 5, limit: 100),
                                               expectedGeneration: store.connectionGeneration(for: .codex)))
        oldAccount.finish(.init(value: 99, limit: 100))
        await pending.value
        XCTAssertEqual(store.reading(for: metric).value, 5)
        XCTAssertEqual(store.histories[metric.id], [5])
        XCTAssertTrue(store.codexConnected)
    }

    func testRepeatedTransientFailuresPreserveTheLastSuccessTimestamp() async throws {
        let metric = MetricTemplate(name: "CPU", kind: .cpu)
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        let sampledAt = Date(timeIntervalSince1970: 100)
        var queue: [MetricReading] = [
            .init(value: 42, limit: 100, subtitle: "sample", updatedAt: sampledAt),
            .error("network interrupted"), .error("still interrupted")
        ]
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { _ in queue.removeFirst() }))
        await store.refresh(force: true)
        await store.refresh(force: true)
        await store.refresh(force: true)

        let reading = store.reading(for: metric)
        XCTAssertEqual(reading.value, 42)
        XCTAssertEqual(reading.updatedAt, sampledAt)
        XCTAssertEqual(reading.state, .failed)
        XCTAssertEqual(reading.subtitle, "still interrupted")
        XCTAssertEqual(store.histories[metric.id], [42])
        XCTAssertNil(store.cpuReading, "The menu bar must not present a failed cached CPU reading as current")
    }

    func testAuthenticationLossClearsValuesAndHistory() async throws {
        let metric = MetricTemplate(name: "Codex", kind: .codex)
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        preferences.defaults.set(true, forKey: "web.codex.connected")
        var queue: [MetricReading] = [.init(value: 30, limit: 100), .setup("다시 로그인해 주세요")]
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { _ in queue.removeFirst() }))
        await store.refresh(force: true)
        XCTAssertEqual(store.histories[metric.id], [30])
        await store.refresh(force: true)
        XCTAssertNil(store.reading(for: metric).value)
        XCTAssertNil(store.reading(for: metric).updatedAt)
        XCTAssertEqual(store.reading(for: metric).state, .needsSetup)
        XCTAssertNil(store.histories[metric.id])
    }

    func testDisabledMetricsAreNeverPolledOrShownInTheMenu() async throws {
        let cpu = MetricTemplate(name: "CPU", kind: .cpu)
        var storage = MetricTemplate(name: "storage", kind: .storage)
        storage.isEnabled = false
        let preferences = try StoreTestPreferences(templates: [cpu, storage])
        defer { preferences.remove() }
        var calls: [UUID] = []
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { template in
                                    calls.append(template.id)
                                    return .init(value: 12, limit: 100)
                                }))
        await store.refresh(force: true)
        XCTAssertEqual(calls, [cpu.id])
        XCTAssertEqual(store.cpuReading, 12)

        store.setEnabled(cpu.id, false)
        await store.refresh(force: true)
        XCTAssertEqual(calls, [cpu.id])
        XCTAssertNil(store.cpuReading)
        XCTAssertTrue(store.visibleTemplates.isEmpty)

        store.setEnabled(storage.id, true)
        await store.refresh()
        XCTAssertEqual(calls, [cpu.id, storage.id])
        XCTAssertEqual(store.visibleTemplates.map(\.id), [storage.id])
    }

    func testEditingOneMetricDoesNotForceUnrelatedProvidersToPoll() async throws {
        let cpu = MetricTemplate(name: "CPU", kind: .cpu, refreshInterval: 3)
        var api = publicMetric(endpoint: "https://example.com/usage")
        api.refreshInterval = 300
        let preferences = try StoreTestPreferences(templates: [cpu, api])
        defer { preferences.remove() }
        var now = Date(timeIntervalSince1970: 1_000)
        var calls: [UUID] = []
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { template in
                                    calls.append(template.id)
                                    return .init(value: 10, limit: 100)
                                }, now: { now }))
        await store.refresh()
        XCTAssertEqual(Set(calls), Set([cpu.id, api.id]))
        calls.removeAll()
        now = now.addingTimeInterval(3)
        await store.refresh()
        XCTAssertEqual(calls, [cpu.id])
        calls.removeAll()

        api.name = "renamed API"
        try store.save(api)
        await store.refresh()
        XCTAssertEqual(calls, [api.id])
    }

    func testManualValuesKeepTheEntryTimeAcrossRefreshesAndRestarts() async throws {
        var metric = MetricTemplate(name: "manual", kind: .manual, manualValue: 5)
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        var now = Date(timeIntervalSince1970: 100)
        let store = StatusStore(defaults: preferences.defaults, start: false, services: .init(now: { now }))
        await store.refresh(force: true)
        XCTAssertNil(store.reading(for: metric).updatedAt, "An imported historical value has no known sample date")

        metric.manualValue = 7
        try store.save(metric)
        await store.refresh(force: true)
        XCTAssertEqual(store.reading(for: metric).updatedAt, now)
        now = now.addingTimeInterval(500)
        await store.refresh(force: true)
        XCTAssertEqual(store.reading(for: metric).updatedAt, Date(timeIntervalSince1970: 100))
        XCTAssertNil(store.histories[metric.id], "Polling a manually entered value must not create fresh sample history")

        metric.name = "renamed manual"
        try store.save(metric)
        await store.refresh(force: true)
        XCTAssertEqual(store.reading(for: metric).updatedAt, Date(timeIntervalSince1970: 100))
        let restarted = StatusStore(defaults: preferences.defaults, start: false)
        await restarted.refresh(force: true)
        XCTAssertEqual(restarted.reading(for: metric).value, 7)
        XCTAssertEqual(restarted.reading(for: metric).updatedAt, Date(timeIntervalSince1970: 100))
    }

    func testLoginGenerationAndPendingSessionClearPreventReconnectionRaces() async throws {
        let metric = MetricTemplate(name: "Claude", kind: .claude)
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        let clear = StoreReadGate()
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(clearSession: { _ in _ = await clear.read() }))
        var windowsRequested = 0
        store.onRequestLogin = { _ in windowsRequested += 1 }
        store.connect(.claude)
        let earlierLogin = store.connectionGeneration(for: .claude)
        store.connect(.claude)
        let latestLogin = store.connectionGeneration(for: .claude)
        XCTAssertNotEqual(earlierLogin, latestLogin)
        XCTAssertFalse(store.completeConnection(.claude, reading: .init(value: 20), expectedGeneration: earlierLogin))
        XCTAssertTrue(store.completeConnection(.claude, reading: .init(value: 30), expectedGeneration: latestLogin))
        XCTAssertTrue(store.claudeConnected)
        XCTAssertEqual(store.reading(for: metric).value, 30)

        store.disconnect(.claude)
        await clear.waitUntilStarted()
        store.connect(.claude)
        XCTAssertEqual(windowsRequested, 2, "Do not open a new login while its website cookies are being cleared")
        XCTAssertNotNil(store.notice)
        XCTAssertFalse(store.completeConnection(.claude, reading: .init(value: 90), expectedGeneration: store.connectionGeneration(for: .claude)))
        XCTAssertFalse(store.claudeConnected)
        clear.finish(.setup("cleared"))
        await Task.yield()
    }

    func testReorderingPersistsWithoutChangingVisibility() async throws {
        let first = MetricTemplate(name: "first", kind: .manual)
        var second = MetricTemplate(name: "second", kind: .manual)
        second.isEnabled = false
        let preferences = try StoreTestPreferences(templates: [first, second])
        defer { preferences.remove() }
        let store = StatusStore(defaults: preferences.defaults, start: false)
        store.move(second.id, by: -1)
        store.move(second.id, by: Int.max)
        XCTAssertEqual(store.templates.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.visibleTemplates.map(\.id), [first.id])
        let restarted = StatusStore(defaults: preferences.defaults, start: false)
        XCTAssertEqual(restarted.templates.map(\.id), [second.id, first.id])
        XCTAssertEqual(restarted.visibleTemplates.map(\.id), [first.id])
    }

    func testDeniedCredentialDeletionKeepsTheMetricAndItsSettingsAccessible() async throws {
        let metric = publicMetric(endpoint: "https://example.com/usage")
        let preferences = try StoreTestPreferences(templates: [metric])
        defer { preferences.remove() }
        var deletionAllowed = false
        let store = StatusStore(defaults: preferences.defaults, start: false,
                                services: .init(readMetric: { _ in .init(value: 25, limit: 100) }, deleteToken: { _ in deletionAllowed }))
        await store.refresh(force: true)
        XCTAssertFalse(store.removeToken(metric.id))
        XCTAssertEqual(store.reading(for: metric).value, 25)
        XCTAssertFalse(store.remove(metric.id))
        XCTAssertTrue(store.templates.contains { $0.id == metric.id })
        XCTAssertNotNil(store.notice)

        deletionAllowed = true
        XCTAssertTrue(store.remove(metric.id))
        XCTAssertFalse(store.templates.contains { $0.id == metric.id })
        XCTAssertNil(store.readings[metric.id])
        XCTAssertTrue(StatusStore(defaults: preferences.defaults, start: false).templates.isEmpty)
    }

    private func publicMetric(endpoint: String) -> MetricTemplate {
        .init(name: "API", kind: .http, endpoint: endpoint, valuePath: "value", authHeader: "", authPrefix: "")
    }
}

private struct StoreTestPreferences {
    let name = "MacStatus.StoreTests.\(UUID().uuidString)"
    let defaults: UserDefaults

    init(templates: [MetricTemplate]) throws {
        defaults = UserDefaults(suiteName: name)!
        defaults.set(try JSONEncoder().encode(templates), forKey: "metricTemplates")
        defaults.set(true, forKey: "builtins.wakatime.v1")
        defaults.set(true, forKey: "builtins.apiOptIn.v1")
    }

    func remove() { defaults.removePersistentDomain(forName: name) }
}

@MainActor
private final class StoreReadGate {
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<MetricReading, Never>?

    func read() async -> MetricReading {
        started = true
        waiter?.resume()
        waiter = nil
        return await withCheckedContinuation { result = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish(_ reading: MetricReading) {
        result?.resume(returning: reading)
        result = nil
    }
}
