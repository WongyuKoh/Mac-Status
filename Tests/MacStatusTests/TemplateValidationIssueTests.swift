import XCTest
@testable import MacStatus

final class TemplateValidationIssueTests: XCTestCase {
    func testMissingInputsAreReportedTogetherAndValidateKeepsTheFirstMessage() {
        let template = MetricTemplate(name: "  ", kind: .http)
        let issues = TemplateEngine.validationIssues(for: template)
        XCTAssertEqual(issues.map(\.field), [.name, .endpoint, .valuePath])
        XCTAssertEqual(issues.first?.message, "name(이름)을 1~60자로 입력해 주세요.")
        XCTAssertThrowsError(try TemplateEngine.validate(template)) { error in
            XCTAssertEqual(error.localizedDescription, issues.first?.message)
        }
    }

    func testOptionalInputsAreNotMistakenForMissingRequiredFields() throws {
        var template = validAPI()
        template.limit = nil
        template.limitPath = ""
        template.link = ""
        template.authHeader = ""
        template.authPrefix = ""
        XCTAssertTrue(TemplateEngine.validationIssues(for: template).isEmpty)
        XCTAssertNoThrow(try TemplateEngine.validate(template))

        let manual = MetricTemplate(name: "수동", kind: .manual, limit: nil, manualValue: nil)
        XCTAssertTrue(TemplateEngine.validationIssues(for: manual).isEmpty,
                      "The engine must retain its existing support for an unconfigured manual value")
    }

    func testAuthenticationFieldsAreIdentifiedIndependently() {
        var template = validAPI()
        template.authHeader = "Host"
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [.authHeader])
        template.authHeader = "Authorization"
        template.authPrefix = "Bearer\t"
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [.authPrefix])
        template.authHeader = "Invalid Header"
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [.authHeader, .authPrefix])
        XCTAssertThrowsError(try TemplateEngine.validate(template)) { error in
            XCTAssertEqual(error.localizedDescription, "authHeader와 authPrefix를 확인해 주세요. 줄바꿈은 넣을 수 없어요.")
        }
    }

    func testEachInvalidNumberAndMetadataFieldIsRetained() {
        var template = validAPI()
        template.subtitle = String(repeating: "a", count: 181)
        template.unit = String(repeating: "a", count: 21)
        template.symbol = String(repeating: "a", count: 81)
        template.refreshInterval = .infinity
        template.multiplier = 0
        template.limit = -1
        template.manualValue = .nan
        template.aggregation = "other"
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [
            .subtitle, .unit, .symbol, .refreshInterval, .multiplier, .limit, .manualValue, .aggregation
        ])
    }

    func testURLAndHeaderSecurityFailuresStillRejectTheTemplateWithoutLeakingInput() {
        var template = validAPI()
        template.endpoint = "https://user:private-secret@example.com/usage"
        template.link = "https://example.com/dashboard?api_key=private-secret"
        template.headers = ["Authorization": "Bearer private-secret"]
        let issues = TemplateEngine.validationIssues(for: template)
        XCTAssertEqual(issues.map(\.field), [.headers, .link, .endpoint])
        XCTAssertFalse(issues.map(\.message).joined().contains("private-secret"))
        XCTAssertThrowsError(try TemplateEngine.validate(template))
    }

    func testPathValidationKeepsNumericAndRawJSONRulesSeparate() {
        var template = validAPI()
        template.valuePath = "A..B"
        template.limitPath = "usage limit"
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [.valuePath, .limitPath])

        template.valueMode = .json
        template.valuePath = "data.*.value"
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [.valuePath])
        template.valuePath = "data.0.value"
        XCTAssertTrue(TemplateEngine.validationIssues(for: template).isEmpty,
                      "Raw JSON mode must keep ignoring an unused numeric limit path")
    }

    func testSupportedURLsPathsAndNumericBoundariesAreStillValid() throws {
        var template = validAPI()
        template.endpoint = "https://example.com/usage?from={{month_start_unix}}&to={{now_unix}}"
        template.valuePath = "data.*.value"
        template.limitPath = "limits.0.value"
        template.refreshInterval = 3
        template.multiplier = -0.01
        template.manualValue = 0
        template.aggregation = "sum"
        XCTAssertTrue(TemplateEngine.validationIssues(for: template).isEmpty)
        XCTAssertNoThrow(try TemplateEngine.validate(template))
        for endpoint in ["http://localhost:4000/usage", "http://127.0.0.1:4000/usage", "http://[::1]:4000/usage"] {
            template.endpoint = endpoint
            template.refreshInterval = 86_400
            XCTAssertTrue(TemplateEngine.validationIssues(for: template).isEmpty)
        }
    }

    func testAdditionalHeadersProduceOneFieldIssueAndRetainTheirOriginalFirstError() {
        var template = validAPI()
        template.headers = ["Invalid Header": "bad\nvalue"]
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [.headers])
        XCTAssertThrowsError(try TemplateEngine.validate(template)) { error in
            XCTAssertEqual(error.localizedDescription, "headers의 이름과 값을 확인해 주세요. 줄바꿈은 넣을 수 없어요.")
        }
        template.headers = Dictionary(uniqueKeysWithValues: (0..<21).map { ("X-Header-\($0)", "ok") })
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).count, 1)
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).first?.message, "headers의 항목을 20개 이하로 줄여 주세요.")
        template.headers = ["Content-Length": "1"]
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).first?.message, "headers에서 전송 제어 항목을 빼 주세요. 앱이 자동으로 설정해요.")
    }

    private func validAPI() -> MetricTemplate {
        .init(name: "API", kind: .http, endpoint: "https://example.com/usage", valuePath: "A.B.C")
    }
}
