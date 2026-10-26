import XCTest
@testable import MacStatus

@MainActor
final class MenuBarMetricTests: XCTestCase {
    func testDefaultCPUSelectionPreservesTheExistingVisibilityPreference() throws {
        let cpu = MetricTemplate(name: "CPU", kind: .cpu)
        let preferences = try MenuBarPreferences(templates: [cpu])
        defer { preferences.remove() }
        preferences.defaults.set(false, forKey: "showCPUInMenu")
        let store = makeStore(preferences)
        store.readings[cpu.id] = .init(value: 33.4, limit: 100)
        XCTAssertEqual(store.menuBarMetricID, MenuBarMetricID.primary(cpu.id))
        XCTAssertEqual(store.menuBarValueMode, .value)
        XCTAssertFalse(store.showCPUInMenu)
        XCTAssertEqual(store.menuBarPresentation.text, "")
        store.setMenuCPU(true)
        XCTAssertEqual(store.menuBarPresentation.text, "33%")
        XCTAssertEqual(makeStore(preferences).menuBarMetricID, store.menuBarMetricID)
    }

    func testSelectionAndPercentagePersistAndDoNotChangeOnTemporaryFailure() throws {
        let cpu = MetricTemplate(name: "CPU", kind: .cpu)
        let memory = MetricTemplate(name: "메모리", kind: .memory, unit: "GB", limit: nil)
        let preferences = try MenuBarPreferences(templates: [cpu, memory])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        store.setMenuBarMetric(MenuBarMetricID.primary(memory.id))
        store.setMenuBarValueMode(.percentage)
        store.readings[cpu.id] = .init(value: 33, limit: 100)
        store.readings[memory.id] = .init(value: 36, limit: 48)
        XCTAssertEqual(store.menuBarPresentation.text, "75%")
        let restored = makeStore(preferences)
        XCTAssertEqual(restored.menuBarMetricID, store.menuBarMetricID)
        XCTAssertEqual(restored.menuBarValueMode, .percentage)
        store.readings[memory.id] = .init(value: 36, limit: 48, subtitle: "temporary failure", state: .failed)
        XCTAssertEqual(store.menuBarPresentation.text, "—")
        XCTAssertTrue(store.menuBarPresentation.description.contains("temporary failure"))
        XCTAssertTrue(store.menuBarSupportsPercentage)
        XCTAssertEqual(store.menuBarValueMode, .percentage)
        store.readings[memory.id] = .init(value: 24, limit: 48)
        XCTAssertEqual(store.menuBarPresentation.text, "50%")
    }

    func testHiddenOrRemovedSelectionNeverFallsBackToAnotherMetric() throws {
        let cpu = MetricTemplate(name: "CPU", kind: .cpu)
        let memory = MetricTemplate(name: "메모리", kind: .memory, unit: "GB", limit: nil)
        let preferences = try MenuBarPreferences(templates: [cpu, memory])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        let selected = MenuBarMetricID.primary(memory.id)
        store.setMenuBarMetric(selected)
        store.setMenuBarValueMode(.percentage)
        store.readings[cpu.id] = .init(value: 80, limit: 100)
        store.setEnabled(memory.id, false)
        XCTAssertEqual(store.menuBarMetricID, selected)
        XCTAssertEqual(store.menuBarPresentation.text, "—")
        XCTAssertTrue(store.menuBarMetricOptions.contains { $0.id == selected && $0.title.contains("사용 불가") })
        XCTAssertTrue(store.remove(memory.id))
        XCTAssertEqual(store.menuBarMetricID, selected)
        XCTAssertEqual(store.menuBarValueMode, .percentage)
        XCTAssertEqual(store.menuBarPresentation.text, "—")
    }

    func testAIWindowSelectionUsesRoleAndFractionInsteadOfParsingDisplayText() throws {
        let codex = MetricTemplate(name: "Codex", kind: .codex)
        let preferences = try MenuBarPreferences(templates: [codex])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        let selected = MenuBarMetricID.role(.weekly, in: codex.id)
        XCTAssertTrue(store.menuBarMetricOptions.contains { $0.id == selected && $0.supportsPercentage })
        XCTAssertFalse(store.menuBarMetricOptions.contains { $0.id == MenuBarMetricID.primary(codex.id) })
        store.setMenuBarMetric(selected)
        XCTAssertEqual(store.menuBarValueMode, .percentage)
        store.readings[codex.id] = .init(value: 12, limit: 100, details: [
            .init(label: "5시간", value: "12%", fraction: 0.12, role: .session),
            .init(label: "주간", value: "99%라고 잘못 파싱하면 안 됨", fraction: 0.54, role: .weekly)
        ])
        XCTAssertEqual(store.menuBarPresentation.text, "54%")
        store.readings[codex.id] = .init(value: 12, limit: 100, details: [
            .init(label: "이름이 변경된 주간", value: "localized display", fraction: 0, role: .weekly)
        ])
        XCTAssertEqual(store.menuBarPresentation.text, "0%")
        store.readings[codex.id] = .init(value: 12, limit: 100, details: [.init(label: "주간", value: "54%", role: .weekly)])
        XCTAssertEqual(store.menuBarPresentation.text, "—")
        store.setMenuBarValueMode(.value)
        store.setMenuBarMetric(selected)
        XCTAssertEqual(store.menuBarValueMode, .value)
    }

    func testPrimaryPercentageKeepsOverLimitValuesAndZero() throws {
        let metric = MetricTemplate(name: "예산", kind: .manual, unit: "USD", limit: 100, manualValue: 120)
        let preferences = try MenuBarPreferences(templates: [metric])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        store.setMenuBarMetric(MenuBarMetricID.primary(metric.id))
        store.readings[metric.id] = .init(value: 120, limit: 100)
        XCTAssertEqual(store.menuBarPresentation.text, "$120.00")
        store.setMenuBarValueMode(.percentage)
        XCTAssertEqual(store.menuBarPresentation.text, "120%")
        store.readings[metric.id] = .init(value: 0, limit: 100)
        XCTAssertEqual(store.menuBarPresentation.text, "0%")
        store.readings[metric.id] = .init(value: .infinity, limit: 100)
        XCTAssertEqual(store.menuBarPresentation.text, "—")
    }

    func testJSONNullAndLongTextAreSafeForTheMenuWhileTooltipKeepsTheFullValue() throws {
        var metric = MetricTemplate(name: "상태", kind: .http, unit: "", limit: nil, authHeader: "", authPrefix: "")
        metric.valueMode = .json
        let preferences = try MenuBarPreferences(templates: [metric])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        store.setMenuBarMetric(MenuBarMetricID.primary(metric.id))
        XCTAssertFalse(store.menuBarSupportsPercentage)
        XCTAssertEqual(store.menuBarPresentation.text, "null")
        let full = "hello\nworld " + String(repeating: "x", count: 40)
        store.readings[metric.id] = .init(text: full)
        XCTAssertLessThanOrEqual(store.menuBarPresentation.text.count, 18)
        XCTAssertFalse(store.menuBarPresentation.text.contains("\n"))
        XCTAssertTrue(store.menuBarPresentation.text.hasSuffix("…"))
        XCTAssertTrue(store.menuBarPresentation.description.contains(full))
        store.readings[metric.id] = .init(text: "false")
        XCTAssertEqual(store.menuBarPresentation.text, "false")
        store.readings[metric.id] = .error("offline")
        XCTAssertEqual(store.menuBarPresentation.text, "null")
    }

    func testChangingTheSelectedTemplateToJSONResetsAnInapplicablePercentageFormat() throws {
        var metric = MetricTemplate(name: "API", kind: .http, unit: "", limit: 100,
                                    endpoint: "https://example.com/api", valuePath: "A.B.C", authHeader: "", authPrefix: "")
        let preferences = try MenuBarPreferences(templates: [metric])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        store.setMenuBarMetric(MenuBarMetricID.primary(metric.id))
        store.setMenuBarValueMode(.percentage)
        metric.valueMode = .json
        try store.save(metric)
        XCTAssertEqual(store.menuBarMetricID, MenuBarMetricID.primary(metric.id))
        XCTAssertEqual(store.menuBarValueMode, .value)
        XCTAssertFalse(store.menuBarSupportsPercentage)
        XCTAssertEqual(store.menuBarPresentation.text, "null")
        XCTAssertEqual(makeStore(preferences).menuBarValueMode, .value)
    }

    func testCalculationNullDisplaysLiterallyInValueAndPercentageModesAndThenRecovers() throws {
        var metric = MetricTemplate(name: "계산 통계", kind: .http, unit: "%", limit: 100,
                                    endpoint: "https://example.com/usage", valuePath: "value", authHeader: "", authPrefix: "")
        metric.valueExpression = "value / (value - 2) + 0"
        let preferences = try MenuBarPreferences(templates: [metric])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        store.setMenuBarMetric(MenuBarMetricID.primary(metric.id))
        let null = try TemplateEngine.reading(from: Data(#"{"value":2}"#.utf8), template: metric)
        store.readings[metric.id] = null
        for mode in [MenuBarValueMode.value, .percentage] {
            store.setMenuBarValueMode(mode)
            XCTAssertEqual(store.menuBarPresentation.text, "null")
            XCTAssertTrue(store.menuBarPresentation.description.contains(null.subtitle))
            XCTAssertEqual(store.menuBarValueMode, mode)
        }

        store.readings[metric.id] = try TemplateEngine.reading(from: Data(#"{"value":0}"#.utf8), template: metric)
        XCTAssertEqual(store.menuBarPresentation.text, "0%")
        store.setMenuBarValueMode(.value)
        XCTAssertEqual(store.menuBarPresentation.text, "0%")
    }

    func testLimitCalculationNullAlsoDisplaysNullWithoutChangingOtherUnavailableMetrics() throws {
        var metric = MetricTemplate(name: "한도 계산", kind: .http, unit: "USD", limit: nil,
                                    endpoint: "https://example.com/usage", valuePath: "value", limitPath: "limit")
        metric.limitExpression = "value / (value - 100)"
        let null = try TemplateEngine.reading(from: Data(#"{"value":5,"limit":100}"#.utf8), template: metric)
        for mode in [MenuBarValueMode.value, .percentage] {
            XCTAssertEqual(MenuBarMetricFormat.primary(metric, reading: null, mode: mode).text, "null")
            XCTAssertEqual(MenuBarMetricFormat.primary(metric, reading: .error("offline"), mode: mode).text, "—")
        }

        let cpu = MetricTemplate(name: "CPU", kind: .cpu)
        let unrelated = MetricReading(text: "null", state: .unavailable, updatedAt: nil)
        XCTAssertEqual(MenuBarMetricFormat.primary(cpu, reading: unrelated, mode: .value).text, "—")
    }

    func testCreditsCanDisplayWithoutQuotaAndSelectingThemLeavesPercentageMode() throws {
        let claude = MetricTemplate(name: "Claude", kind: .claude)
        let preferences = try MenuBarPreferences(templates: [claude])
        defer { preferences.remove() }
        let store = makeStore(preferences)
        let credits = MetricDetail(label: "API 토큰", value: "USD 500.00", role: .credits)
        store.readings[claude.id] = .init(state: .unavailable, details: [credits])
        store.setMenuBarMetric(MenuBarMetricID.role(.weekly, in: claude.id))
        store.setMenuBarValueMode(.percentage)
        store.setMenuBarMetric(MenuBarMetricID.detail(credits, in: claude.id))
        XCTAssertEqual(store.menuBarValueMode, .value)
        XCTAssertEqual(store.menuBarPresentation.text, "USD 500.00")
        store.readings[claude.id] = .init(state: .failed, details: [credits])
        XCTAssertEqual(store.menuBarPresentation.text, "—")
    }

    private func makeStore(_ preferences: MenuBarPreferences) -> StatusStore {
        StatusStore(defaults: preferences.defaults, start: false, services: .init(
            deleteToken: { _ in true }, hasSavedToken: { _ in false }, updateLoginItem: nil
        ))
    }
}

private struct MenuBarPreferences {
    let defaults: UserDefaults
    let suite: String

    init(templates: [MetricTemplate]) throws {
        suite = "MacStatus.MenuBarMetricTests." + UUID().uuidString
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode(templates), forKey: "metricTemplates")
        defaults.set(true, forKey: "builtins.wakatime.v1")
        defaults.set(true, forKey: "builtins.apiOptIn.v1")
    }

    func remove() { defaults.removePersistentDomain(forName: suite) }
}
