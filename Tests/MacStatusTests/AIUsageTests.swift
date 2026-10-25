import XCTest
@testable import MacStatus

final class AIUsageTests: XCTestCase {
    func testCodexWebUsageUsesRealDurationsAndResetTimes() throws {
        let fixture = Data(#"{"plan_type":"new_plan","rate_limit":{"primary_window":{"used_percent":42.5,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":68,"limit_window_seconds":604800,"reset_at":1800500000}}}"#.utf8)
        let reading = try AIUsageParser.codexWeb(fixture)
        XCTAssertEqual(reading.value, 42.5)
        XCTAssertEqual(usageWindows(reading).map(\.label), ["5시간", "주간"])
        XCTAssertEqual(reading.details[0].fraction, 0.425)
        XCTAssertEqual(reading.details[0].resetAt?.timeIntervalSince1970, 1_800_000_000)
        XCTAssertTrue(reading.subtitle.contains("ChatGPT 계정"))
    }

    func testCodexWebPrimaryCanBeWeeklyWithoutInventingSessionWindow() throws {
        let fixture = Data(#"{"rate_limit":{"primary_window":{"used_percent":33,"limit_window_seconds":604800},"secondary_window":null}}"#.utf8)
        let reading = try AIUsageParser.codexWeb(fixture)
        XCTAssertEqual(reading.value, 33)
        XCTAssertEqual(usageWindows(reading).map(\.label), ["주간"])
    }

    func testCodexWebMissingAndInvalidUsageNeverBecomesZero() throws {
        for fixture in [#"{}"#, #"{"rate_limit":{"primary_window":{"used_percent":null}}}"#, #"{"rate_limit":{"primary_window":{"used_percent":true},"secondary_window":{"used_percent":"12"}}}"#] {
            let reading = try AIUsageParser.codexWeb(Data(fixture.utf8))
            XCTAssertNil(reading.value)
            XCTAssertEqual(reading.state, .unavailable)
        }
    }

    func testCodexWebIncludesAdditionalModelsCodeReviewAndCredits() throws {
        let fixture = Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"additional_rate_limits":[{"limit_name":"Extra model","metered_feature":"other","rate_limit":{"primary_window":{"used_percent":75,"limit_window_seconds":3600}}}],"code_review_rate_limit":{"primary_window":{"used_percent":22,"limit_window_seconds":604800}},"credits":{"unlimited":false,"balance":"9.99"}}"#.utf8)
        let reading = try AIUsageParser.codexWeb(fixture)
        XCTAssertEqual(reading.value, 10)
        XCTAssertEqual(usageWindows(reading).map(\.label), ["5시간", "Extra model · 1시간", "코드 리뷰 · 주간"])
        XCTAssertEqual(reading.details[1].fraction, 0.75)
        XCTAssertEqual(reading.details.last?.value, "9.99 크레딧")
    }

    func testCodexWebWorkspaceLimitStaysSeparateFromAPIExpenses() throws {
        let fixture = Data(#"{"spend_control":{"individual_limit":{"limit":"1000","used":"36.79","used_percent":4,"reset_at":1800000000}}}"#.utf8)
        let reading = try AIUsageParser.codexWeb(fixture)
        XCTAssertEqual(reading.value, 4)
        XCTAssertEqual(reading.state, .ready)
        let workspace = try XCTUnwrap(reading.details.first(where: { $0.label == "워크스페이스 한도" }))
        XCTAssertEqual(workspace.role, .credits)
        XCTAssertEqual(workspace.fraction, 0.04)
        XCTAssertEqual(workspace.resetAt?.timeIntervalSince1970, 1_800_000_000)
        XCTAssertFalse(reading.subtitle.contains("API"))
    }

    func testCodexPrefersMultipleBucketResponseAndPreservesReset() throws {
        let fixture = #"{"result":{"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{"codex":{"planType":"plus","primary":{"usedPercent":25,"windowDurationMins":300,"resetsAt":1800000000},"secondary":{"usedPercent":68,"windowDurationMins":10080,"resetsAt":1800500000}}}}}"#.data(using: .utf8)!
        let reading = try AIUsageParser.codex(fixture)
        XCTAssertEqual(reading.value, 25)
        XCTAssertEqual(usageWindows(reading).map(\.label), ["5시간", "주간"])
        XCTAssertEqual(reading.details[0].fraction, 0.25)
        XCTAssertEqual(reading.details[0].resetAt?.timeIntervalSince1970, 1_800_000_000)
    }

    func testMissingCodexUsageNeverBecomesZero() throws {
        let reading = try AIUsageParser.codex(Data(#"{"rateLimits":{"primary":null,"secondary":null}}"#.utf8))
        XCTAssertNil(reading.value)
        XCTAssertEqual(reading.state, .unavailable)
    }

    func testCodexKeepsAdditionalMeteredBuckets() throws {
        let fixture = Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":10,"windowDurationMins":300}},"other":{"limitName":"Other model","primary":{"usedPercent":75,"windowDurationMins":60}}}}"#.utf8)
        let reading = try AIUsageParser.codex(fixture)
        XCTAssertEqual(reading.value, 10)
        XCTAssertEqual(usageWindows(reading).map(\.label), ["5시간", "Other model · 1시간"])
        XCTAssertEqual(usageWindows(reading).last?.fraction, 0.75)
    }

    func testClaudeLegacyPercentIsAlreadyPercentage() throws {
        let fixture = Data(#"{"five_hour":{"utilization":42.5,"resets_at":"2026-10-25T12:00:00.123Z"},"seven_day":{"utilization":7,"resets_at":"2026-10-30T12:00:00Z"},"seven_day_sonnet":null}"#.utf8)
        let reading = try AIUsageParser.claude(fixture)
        XCTAssertEqual(reading.value, 42.5)
        XCTAssertEqual(usageWindows(reading).count, 2)
        XCTAssertEqual(reading.details[0].fraction, 0.425)
        XCTAssertNotNil(reading.details[0].resetAt)
        XCTAssertNotNil(reading.details[1].resetAt)
    }

    func testClaudeModernScopedLimitsAreOrderedAndNamed() throws {
        let fixture = Data(#"{"limits":[{"kind":"weekly_scoped","percent":16,"scope":{"model":{"display_name":"Fable"}}},{"kind":"weekly_all","percent":14},{"kind":"session","percent":5}]}"#.utf8)
        let reading = try AIUsageParser.claude(fixture)
        XCTAssertEqual(reading.value, 5)
        XCTAssertEqual(usageWindows(reading).map(\.label), ["5시간", "주간 전체", "주간 Fable"])
    }

    func testMalformedAndUnavailableClaudeNumbersAreNotZero() throws {
        let reading = try AIUsageParser.claude(Data(#"{"five_hour":{"utilization":null},"seven_day":{"utilization":true}}"#.utf8))
        XCTAssertNil(reading.value)
        XCTAssertEqual(reading.state, .unavailable)
    }

    func testClaudeAggregateRolesKeepFiveHourAndWeeklyVisibleTogether() throws {
        let reading = try AIUsageParser.claude(Data(#"{"five_hour":{"utilization":21},"seven_day":{"utilization":62},"seven_day_sonnet":{"utilization":88}}"#.utf8))
        XCTAssertEqual(reading.details.first(where: { $0.role == .session })?.fraction, 0.21)
        XCTAssertEqual(reading.details.first(where: { $0.role == .weekly })?.fraction, 0.62)
        XCTAssertEqual(reading.details.filter { $0.role == .weekly }.count, 1)
        XCTAssertEqual(reading.details.first(where: { $0.label == "주간 Sonnet" })?.role, .other)
    }

    func testPartialModernClaudeLimitsDoNotHideLegacyAggregateWindows() throws {
        let reading = try AIUsageParser.claude(Data(#"{"limits":[{"kind":"weekly_scoped","percent":88,"scope":{"model":{"display_name":"Fable"}}}],"five_hour":{"utilization":21},"seven_day":{"utilization":62}}"#.utf8))
        XCTAssertEqual(reading.value, 21)
        XCTAssertEqual(reading.details.first(where: { $0.role == .weekly })?.fraction, 0.62)
        XCTAssertEqual(reading.details.first(where: { $0.role == .session })?.fraction, 0.21)
    }

    func testCodexCloudIsSharedAndDoesNotDuplicateWeeklyPercentage() throws {
        let reading = try AIUsageParser.codexWeb(Data(#"{"rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":18000},"secondary_window":{"used_percent":62,"limit_window_seconds":604800}},"additional_rate_limits":[{"limit_name":"Cloud named model","rate_limit":{"primary_window":{"used_percent":88,"limit_window_seconds":18000}}}]}"#.utf8))
        let cloud = try XCTUnwrap(reading.details.first(where: { $0.role == .cloud }))
        XCTAssertEqual(cloud.value, "플랜 한도 공유")
        XCTAssertNil(cloud.fraction)
        XCTAssertTrue(cloud.note?.contains("원격 작업만") == true)
        XCTAssertEqual(reading.details.filter { $0.role == .cloud }.count, 1)
        XCTAssertEqual(reading.details.filter { $0.role == .weekly }.count, 1)
        XCTAssertEqual(reading.details.first(where: { $0.label.contains("Cloud named model") })?.role, .other)
    }

    func testClaudeExplicitCoworkQuotaKeepsItsOwnScope() throws {
        let reading = try AIUsageParser.claude(Data(#"{"five_hour":{"utilization":21},"seven_day":{"utilization":62},"seven_day_cowork":{"utilization":37,"resets_at":"2030-01-01T00:00:00Z"}}"#.utf8))
        let cloud = try XCTUnwrap(reading.details.first(where: { $0.role == .cloud }))
        XCTAssertEqual(cloud.label, "Cowork 작업 · 주간")
        XCTAssertEqual(cloud.fraction, 0.37)
        XCTAssertTrue(cloud.note?.contains("전체 원격 작업의 합계") == true)
        XCTAssertEqual(reading.details.filter { $0.role == .weekly }.count, 1)
        XCTAssertEqual(reading.details.filter { $0.label.lowercased().contains("cowork") }.count, 1)
    }

    func testClaudeCreditSpendConvertsCentsWithoutInventingBalance() throws {
        let reading = try AIUsageParser.claude(Data(#"{"five_hour":{"utilization":21},"extra_usage":{"is_enabled":true,"used_credits":4132,"monthly_limit":50000,"utilization":8.264}}"#.utf8))
        let credit = try XCTUnwrap(reading.details.first(where: { $0.role == .credits }))
        XCTAssertEqual(credit.value, "USD 41.32 / USD 500.00 사용")
        XCTAssertEqual(credit.fraction ?? -1, 0.08264, accuracy: 0.00001)
        XCTAssertTrue(credit.note?.contains("충전 잔액과 다릅니다") == true)
        XCTAssertFalse(reading.details.contains(where: { $0.label == "API 토큰" }))
        let won = try AIUsageParser.claude(Data(#"{"extra_usage":{"is_enabled":true,"currency":"KRW","decimal_places":0,"used_credits":4132,"monthly_limit":100000}}"#.utf8))
        XCTAssertEqual(won.details.first(where: { $0.role == .credits })?.value, "KRW 4,132 / KRW 100,000 사용")
        XCTAssertNil(won.value, "A monetary-only account must not invent a five-hour percentage")
    }

    func testClaudeDisabledMissingAndZeroCreditLimitsAreDistinct() throws {
        let disabled = try AIUsageParser.claude(Data(#"{"extra_usage":{"is_enabled":false,"used_credits":null,"monthly_limit":null}}"#.utf8))
        XCTAssertEqual(disabled.details.first(where: { $0.role == .credits })?.value, "비활성화")
        XCTAssertNil(disabled.details.first(where: { $0.role == .credits })?.fraction)
        let missing = try AIUsageParser.claude(Data(#"{"extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":null}}"#.utf8))
        XCTAssertEqual(missing.details.first(where: { $0.role == .credits })?.value, "USD 5.00 사용")
        XCTAssertTrue(missing.details.first(where: { $0.role == .credits })?.note?.contains("월한도 미제공") == true)
        XCTAssertNil(missing.details.first(where: { $0.role == .credits })?.fraction)
        let zero = try AIUsageParser.claude(Data(#"{"extra_usage":{"is_enabled":true,"used_credits":0,"monthly_limit":0}}"#.utf8))
        XCTAssertEqual(zero.details.first(where: { $0.role == .credits })?.value, "USD 0.00 / USD 0.00 사용")
        XCTAssertNil(zero.details.first(where: { $0.role == .credits })?.fraction)
        XCTAssertFalse(zero.details.contains(where: { $0.value.contains("무제한") }))
    }

    func testCodexCreditBalanceIsCreditsAndNotUsdOrDerivedUsage() throws {
        let reading = try AIUsageParser.codexWeb(Data(#"{"credits":{"has_credits":true,"balance":"150.125"}}"#.utf8))
        let credit = try XCTUnwrap(reading.details.first(where: { $0.role == .credits }))
        XCTAssertEqual(credit.label, "크레딧 잔액")
        XCTAssertEqual(credit.value, "150.125 크레딧")
        XCTAssertNil(credit.fraction)
        XCTAssertFalse(credit.value.contains("USD"))
        XCTAssertFalse(credit.value.contains("사용"))
        XCTAssertNil(reading.value)
    }

    func testCodexUnlimitedUnfundedAndMissingCreditsAreDistinct() throws {
        let unlimited = try AIUsageParser.codexWeb(Data(#"{"credits":{"unlimited":true,"balance":null}}"#.utf8))
        XCTAssertEqual(unlimited.details.first(where: { $0.role == .credits })?.value, "무제한")
        let unfunded = try AIUsageParser.codexWeb(Data(#"{"credits":{"has_credits":false,"unlimited":false,"balance":null}}"#.utf8))
        XCTAssertEqual(unfunded.details.first(where: { $0.role == .credits })?.value, "보유 없음")
        let missing = try AIUsageParser.codexWeb(Data(#"{}"#.utf8))
        XCTAssertEqual(missing.details.first(where: { $0.role == .credits })?.value, "정보 미제공")
        let zero = try AIUsageParser.codexWeb(Data(#"{"credits":{"has_credits":false,"balance":0}}"#.utf8))
        XCTAssertEqual(zero.details.first(where: { $0.role == .credits })?.value, "0 크레딧")
    }

    func testClaudePrepaidBalanceIsSeparateFromMonthlySpend() throws {
        let usage = Data(#"{"five_hour":{"utilization":21},"extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":2000}}"#.utf8)
        let reading = try AIUsageParser.claude(usage, prepaidData: Data(#"{"amount":3150,"currency":"usd"}"#.utf8))
        let creditRows = reading.details.filter { $0.role == .credits }
        XCTAssertEqual(creditRows.map(\.label), ["추가 크레딧 사용", "API 토큰"])
        XCTAssertEqual(creditRows.last?.value, "USD 31.50")
        XCTAssertNil(creditRows.last?.fraction)
        for bad in [#"{}"#, #"{"amount":true,"currency":"USD"}"#, #"{"amount":100,"currency":""}"#, "not-json"] {
            let validQuota = try AIUsageParser.claude(usage, prepaidData: Data(bad.utf8))
            XCTAssertEqual(validQuota.value, 21)
            XCTAssertFalse(validQuota.details.contains(where: { $0.label == "API 토큰" }))
        }
        let exhausted = try AIUsageParser.claude(usage, prepaidData: Data(#"{"amount":0,"currency":"USD"}"#.utf8))
        XCTAssertEqual(exhausted.details.first(where: { $0.label == "API 토큰" })?.value, "USD 0.00")
    }

    func testClaudeCloudPromotionUsesDollarsAndExpiryIsNotReset() throws {
        let reading = try AIUsageParser.claude(Data(#"{"five_hour":{"utilization":21},"extra_usage":{"is_enabled":true,"used_credits":500,"monthly_limit":2000},"iguana_necktie":{"limit_dollars":100,"used_dollars":10,"remaining_dollars":75,"resets_at":"2030-11-05T07:59:00Z","locked_reason":null}}"#.utf8))
        let promotion = try XCTUnwrap(reading.details.first(where: { $0.label == "클라우드 세션 크레딧" }))
        XCTAssertEqual(promotion.role, .credits)
        XCTAssertEqual(promotion.value, "USD 10.00 / 100.00 사용", "Reported used amount must not be replaced by a derived value")
        XCTAssertEqual(promotion.fraction, 0.1)
        XCTAssertNil(promotion.resetAt)
        XCTAssertTrue(promotion.note?.contains("남음 USD 75.00") == true)
        XCTAssertTrue(promotion.note?.contains("합계가 한도와 다릅니다") == true)
        XCTAssertTrue(promotion.note?.contains("반복 초기화가 아닙니다") == true)
        XCTAssertEqual(reading.details.first(where: { $0.label == "추가 크레딧 사용" })?.value, "USD 5.00 / USD 20.00 사용")
        let untouched = try AIUsageParser.claude(Data(#"{"iguana_necktie":{"limit_dollars":100,"used_dollars":0,"remaining_dollars":100}}"#.utf8))
        XCTAssertEqual(untouched.details.first(where: { $0.label == "클라우드 세션 크레딧" })?.value, "USD 0.00 / 100.00 사용")
        XCTAssertEqual(untouched.details.first(where: { $0.label == "클라우드 세션 크레딧" })?.fraction, 0)
    }

    func testClaudeExpiredLockedAndMalformedCloudPromotionDoNotInventBalance() throws {
        let expired = try AIUsageParser.claude(Data(#"{"iguana_necktie":{"limit_dollars":100,"remaining_dollars":75,"resets_at":"2000-01-01T00:00:00Z"}}"#.utf8))
        XCTAssertEqual(expired.details.first(where: { $0.label == "클라우드 세션 크레딧" })?.value, "만료됨")
        let locked = try AIUsageParser.claude(Data(#"{"iguana_necktie":{"limit_dollars":100,"remaining_dollars":75,"locked_reason":"private_server_reason"}}"#.utf8))
        let detail = try XCTUnwrap(locked.details.first(where: { $0.label == "클라우드 세션 크레딧" }))
        XCTAssertEqual(detail.value, "사용 불가")
        XCTAssertNil(detail.fraction)
        XCTAssertFalse(detail.note?.contains("private_server_reason") == true)
        let malformed = try AIUsageParser.claude(Data(#"{"five_hour":{"utilization":21},"iguana_necktie":{"limit_dollars":100,"remaining_dollars":101}}"#.utf8))
        XCTAssertEqual(malformed.value, 21)
        XCTAssertFalse(malformed.details.contains(where: { $0.label == "클라우드 세션 크레딧" }))
    }

    func testCodexWorkspaceCreditUsageKeepsActualUsedAndCap() throws {
        let reading = try AIUsageParser.codexWeb(Data(#"{"individual_limit":{"limit":"1000","used":"36.79","remaining_percent":96,"reset_at":1800000000}}"#.utf8))
        let workspace = try XCTUnwrap(reading.details.first(where: { $0.label == "워크스페이스 한도" }))
        XCTAssertEqual(workspace.role, .credits)
        XCTAssertEqual(workspace.value, "36.79 / 1,000 사용")
        XCTAssertEqual(workspace.fraction, 0.04)
        XCTAssertFalse(workspace.value.contains("USD"))
    }

    private func usageWindows(_ reading: MetricReading) -> [MetricDetail] {
        reading.details.filter { [.session, .weekly, .other].contains($0.role) && $0.fraction != nil }
    }

}
