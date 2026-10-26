import XCTest
@testable import MacStatus

final class MenuBarMetricOptionStyleTests: XCTestCase {
    func testPresentationMetadataPreservesMetricOrderIdentityAndPercentageSupport() {
        let codex = MetricTemplate(name: "Codex", kind: .codex)
        let cpu = MetricTemplate(name: "CPU", kind: .cpu)
        let manual = MetricTemplate(name: "예산", kind: .manual, unit: "USD", limit: 200)
        let credits = MetricDetail(label: "크레딧 잔액", value: "10", role: .credits)
        let options = MenuBarMetricCatalog.options(for: [manual, codex, cpu]) { template in
            template.id == codex.id ? .init(details: [credits]) : .init()
        }

        XCTAssertEqual(options.map(\.id), [
            MenuBarMetricID.primary(manual.id),
            MenuBarMetricID.role(.session, in: codex.id),
            MenuBarMetricID.role(.weekly, in: codex.id),
            MenuBarMetricID.detail(credits, in: codex.id),
            MenuBarMetricID.primary(cpu.id)
        ])
        XCTAssertEqual(options.map(\.title), ["예산", "Codex · 5시간 사용량", "Codex · 주간 사용량", "Codex · 크레딧 잔액", "CPU"])
        XCTAssertEqual(options.map(\.supportsPercentage), [true, true, true, false, true])
        XCTAssertEqual(options.map(\.section), ["직접 입력", "AI 사용량", "AI 사용량", "AI 사용량", "이 Mac"])
        XCTAssertEqual(options.map(\.symbol), [manual.symbol, "clock", "calendar", "creditcard", "cpu"])
    }

    func testSystemActivityAndAPIOptionsHaveDistinctContextIcons() {
        let memory = MetricTemplate(name: "메모리", kind: .memory)
        let storage = MetricTemplate(name: "저장공간", kind: .storage)
        let temperature = MetricTemplate(name: "발열", kind: .temperature)
        let activity = MetricTemplate(name: "WakaTime", kind: .wakatime)
        let api = MetricTemplate(name: "Claude API 크레딧", kind: .claudeAPI)
        let week = MetricDetail(label: "최근 7일", value: "10시간")
        let options = MenuBarMetricCatalog.options(for: [memory, storage, temperature, activity, api]) { template in
            template.id == activity.id ? .init(details: [week]) : .init()
        }

        XCTAssertEqual(options.map(\.symbol), ["memorychip", "internaldrive", "thermometer.medium", "clock", "calendar", "creditcard"])
        XCTAssertEqual(options.map(\.section), ["이 Mac", "이 Mac", "이 Mac", "활동 기록", "활동 기록", "API 통계"])
        XCTAssertEqual(options[3].id, MenuBarMetricID.primary(activity.id))
        XCTAssertEqual(options[4].id, MenuBarMetricID.detail(week, in: activity.id))
        XCTAssertEqual(options[3].title, "WakaTime · 오늘 기록 시간")
    }

    func testUnavailablePlaceholderCanKeepItsExistingInitializer() {
        let option = MenuBarMetricOption(id: "missing", title: "선택한 항목 · 사용 불가", supportsPercentage: true, source: .unavailable)
        XCTAssertNil(option.symbol)
        XCTAssertNil(option.section)
        XCTAssertEqual(option.id, "missing")
        XCTAssertTrue(option.supportsPercentage)
    }
}
