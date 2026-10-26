import XCTest
@testable import MacStatus

final class WakaTimeTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return value
    }
    private var today: Date { ISO8601DateFormatter().date(from: "2026-10-25T14:00:00Z")! }

    func testOAuthAuthenticationIsOnlyInHeaderAndDatesUseLocalTimezone() throws {
        let request = try WakaTimeProvider.request(accessToken: "waka_tok_sample", today: today, calendar: calendar)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer waka_tok_sample")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, "api.wakatime.com")
        let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        XCTAssertEqual(query, ["start": "2026-10-19", "end": "2026-10-25", "timezone": "Asia/Seoul"])
        XCTAssertFalse(request.url!.absoluteString.contains("waka_tok_sample"))
        XCTAssertNil(query["api_key"])
        XCTAssertNil(query["access_token"])
        XCTAssertEqual(request.timeoutInterval, 15)
    }

    func testOAuthUsesBearerAndRejectsControlCharacters() throws {
        let request = try WakaTimeProvider.request(accessToken: "waka_tok_sample", today: today)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer waka_tok_sample")
        for value in ["", " ", "waka_tok_sample\r\nInjected: yes", "waka_tok_" + String(repeating: "a", count: 8_193)] {
            XCTAssertThrowsError(try WakaTimeProvider.request(accessToken: value))
        }
    }

    func testLegacyKeysNeverProduceASummariesRequest() async {
        for value in ["sample-key", "00000000-0000-0000-0000-000000000000", "waka_tok_"] {
            XCTAssertThrowsError(try WakaTimeProvider.request(accessToken: value))
            let reading = await WakaTimeProvider.fetch(accessToken: value)
            XCTAssertEqual(reading.state, .needsSetup)
            XCTAssertNil(reading.value)
            XCTAssertTrue(reading.subtitle.contains("개인 OAuth 토큰"))
        }
    }

    func testRedirectNeverSendsAuthorizationOutsideTheOfficialHTTPSOrigin() throws {
        let original = try WakaTimeProvider.request(accessToken: "waka_tok_sample")
        for url in ["https://example.com/path", "https://api.wakatime.com.evil.test/path", "http://api.wakatime.com/path", "https://api.wakatime.com:444/path", "https://user@api.wakatime.com/path"] {
            XCTAssertNil(WakaTimeProvider.redirectedRequest(URLRequest(url: URL(string: url)!), original: original))
        }
        let redirected = WakaTimeProvider.redirectedRequest(URLRequest(url: URL(string: "https://api.wakatime.com/api/v1/other")!), original: original)
        XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Authorization"), original.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(redirected?.httpMethod, "GET")
    }

    func testTodayAndSevenDayTotalsStaySeparateAndBreakdownsUseSeconds() throws {
        var days = (19...25).map { day($0, seconds: 3_600) }
        days[6]["grand_total"] = ["total_seconds": 7_500]
        days[6]["projects"] = [["name": "Small", "total_seconds": 600], ["name": "Large", "total_seconds": 6_900]]
        days[6]["languages"] = [["name": "Swift", "total_seconds": 7_500]]
        let reading = try parse(days)
        XCTAssertEqual(reading.state, .ready)
        XCTAssertEqual(reading.value, 7_500 / 3_600)
        XCTAssertEqual(reading.text, "2시간 5분")
        XCTAssertNil(reading.limit)
        XCTAssertEqual(reading.details.first(where: { $0.label == "최근 7일" })?.value, "8시간 5분")
        XCTAssertEqual(reading.details.first(where: { $0.label == "프로젝트 1 · Large" })?.value, "1시간 55분")
        XCTAssertEqual(reading.details.first(where: { $0.label == "언어 1 · Swift" })?.fraction, 1)
    }

    func testActualZeroIsValidButMissingTodayIsUnavailable() throws {
        let zero = try parse((19...25).map { day($0, seconds: 0) })
        XCTAssertEqual(zero.state, .ready)
        XCTAssertEqual(zero.value, 0)
        XCTAssertEqual(zero.text, "0분")
        XCTAssertEqual(zero.details.first(where: { $0.label == "최근 7일" })?.value, "0분")
        for days in [[], [day(24, seconds: 100)], [["grand_total": ["total_seconds": 0], "range": ["text": "Today", "timezone": "UTC"]]]] {
            let missing = try parse(days)
            XCTAssertEqual(missing.state, .unavailable)
            XCTAssertNil(missing.value)
        }
    }

    func testPartialWeekDoesNotPresentPartialSumAsSevenDays() throws {
        let reading = try parse([day(24, seconds: 3_600), day(25, seconds: 900)])
        XCTAssertEqual(reading.value, 0.25)
        XCTAssertEqual(reading.details.first(where: { $0.label == "최근 7일" })?.value, "정보 미제공")
    }

    func testDuplicateDatesDoNotDoubleCount() throws {
        XCTAssertThrowsError(try parse([day(25, seconds: 100), day(25, seconds: 100)]))
    }

    func testMissingMalformedOrBooleanTotalNeverBecomesZero() throws {
        for value: Any in [NSNull(), true, "3600", -1] {
            XCTAssertThrowsError(try parse([day(25, seconds: value)]))
        }
        var missing = day(25, seconds: 0)
        missing["grand_total"] = [:] as [String: Any]
        XCTAssertThrowsError(try parse([missing]))
        for fixture in [#"{}"#, #"{"data":null}"#, #"{"data":{}}"#, "not JSON"] {
            XCTAssertThrowsError(try WakaTimeProvider.parse(data: Data(fixture.utf8), today: today, calendar: calendar))
        }
    }

    func testISOStartFallbackRespectsLocalDayRatherThanUTCDate() throws {
        let fixture: [String: Any] = ["range": ["start": "2026-10-24T15:00:00.000Z", "timezone": "Asia/Seoul"], "grand_total": ["total_seconds": 60]]
        XCTAssertEqual(try parse([fixture]).value, 1.0 / 60)
    }

    func testInvalidDayAndFutureDaysCannotMasqueradeAsToday() throws {
        let bad: [String: Any] = ["range": ["date": "2026-02-30"], "grand_total": ["total_seconds": 1]]
        let future: [String: Any] = ["range": ["date": "2026-10-26"], "grand_total": ["total_seconds": 1]]
        XCTAssertEqual(try parse([bad, future]).state, .unavailable)
    }

    func testOversizedResponseAndIncompleteHTTPStatesAreRejected() throws {
        XCTAssertThrowsError(try WakaTimeProvider.parse(data: Data(repeating: 32, count: WakaTimeProvider.maximumResponseBytes + 1)))
        for status in [202, 301, 404, 429, 500] {
            let response = HTTPURLResponse(url: URL(string: "https://api.wakatime.com/api/v1/users/current/summaries")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try WakaTimeProvider.validateResponse(response)) { error in
                if case StatusError.authentication = error { XCTFail("Transient HTTP state must not clear authentication") }
            }
        }
        for status in [401, 403] {
            let response = HTTPURLResponse(url: URL(string: "https://api.wakatime.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            XCTAssertThrowsError(try WakaTimeProvider.validateResponse(response)) { error in
                guard case StatusError.authentication = error else { return XCTFail("Expected an authentication failure") }
                XCTAssertTrue(error.localizedDescription.contains("read_summaries"))
            }
        }
        let oversized = HTTPURLResponse(url: URL(string: "https://api.wakatime.com")!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "1048577"])!
        XCTAssertThrowsError(try WakaTimeProvider.validateResponse(oversized))
    }

    private func day(_ day: Int, seconds: Any) -> [String: Any] {
        ["range": ["date": "2026-10-\(day)", "timezone": "Asia/Seoul"], "grand_total": ["total_seconds": seconds]]
    }
    private func parse(_ days: [[String: Any]]) throws -> MetricReading {
        try WakaTimeProvider.parse(data: JSONSerialization.data(withJSONObject: ["data": days]), today: today, calendar: calendar)
    }
}
