import XCTest
@testable import MacStatus

final class TemplateImportErrorTests: XCTestCase {
    func testMissingRequiredFieldsIdentifyWhatToAdd() {
        for (json, field) in [
            (#"{"kind":"manual"}"#, "name(이름)"),
            (#"{"name":"내 통계"}"#, "kind(만들기 방식)")
        ] {
            let message = failureMessage(json)
            XCTAssertTrue(message.contains(field))
            XCTAssertTrue(message.contains("빠졌"))
        }
    }

    func testNumericTypesStayStrictAndIdentifyTheField() {
        for (field, label) in [
            ("limit", "limit(한도)"), ("manualValue", "manualValue(현재 값)"),
            ("multiplier", "multiplier(배율)"), ("refreshInterval", "refreshInterval(갱신 간격)")
        ] {
            for invalidValue in [#""25""#, "true", "[25]"] {
                let json = "{\"name\":\"내 통계\",\"kind\":\"manual\",\"\(field)\":\(invalidValue)}"
                let message = failureMessage(json)
                XCTAssertTrue(message.contains(label), message)
                XCTAssertTrue(message.contains("숫자"), message)
            }
        }
    }

    func testTextAndObjectTypesIdentifyKnownFields() {
        XCTAssertTrue(failureMessage(#"{"name":25,"kind":"manual"}"#).contains("name"))
        XCTAssertTrue(failureMessage(#"{"name":"내 통계","kind":"manual","headers":false}"#).contains("headers"))
        XCTAssertTrue(failureMessage(#"{"name":"내 통계","kind":"manual","isEnabled":"yes"}"#).contains("true 또는 false"))
    }

    func testFormatErrorsExplainHowToRepairTheInput() {
        XCTAssertTrue(failureMessage("  ").contains("비어"))
        XCTAssertTrue(failureMessage("```json\n{\"name\":\"내 통계\",\"kind\":\"manual\"}\n```").contains("```"))
        XCTAssertTrue(failureMessage(#"[{"name":"내 통계","kind":"manual"}]"#).contains("{ }"))
        XCTAssertTrue(failureMessage(#"{"name":"내 통계" "kind":"manual"}"#).contains("쉼표"))
    }

    func testErrorsNeverEchoSecretValuesOrUntrustedCodingPathNames() {
        let secret = "test-only-sensitive-content"
        let cases = [
            "{\"name\":\"내 통계\",\"kind\":\"\(secret)\"}",
            "{\"name\":\"내 통계\",\"kind\":\"manual\",\"headers\":{\"\(secret)\":25}}",
            "{\"name\":\"내 통계\",\"kind\":\"manual\",\"token\":\"\(secret)\"}",
            "{\"name\":\"내 통계\",\"kind\":\"http\",\"endpoint\":\"https://example.com?api_key=\(secret)\",\"valuePath\":\"value\"}",
            "{\"name\":\"\(secret)\" \"kind\":\"manual\"}"
        ]
        for json in cases {
            let message = failureMessage(json)
            XCTAssertFalse(message.contains(secret))
            XCTAssertFalse(message.contains("codingPath"))
            XCTAssertFalse(message.contains("debugDescription"))
        }
        XCTAssertTrue(failureMessage(cases[0]).contains("kind"))
        XCTAssertTrue(failureMessage(cases[1]).contains("headers"))
    }

    func testValidationErrorsPointToTheSettingWithoutChangingRules() {
        XCTAssertTrue(failureMessage(#"{"name":"내 통계","kind":"manual","limit":0}"#).contains("limit"))
        XCTAssertTrue(failureMessage(#"{"name":"내 통계","kind":"manual","manualValue":-1}"#).contains("manualValue"))
        XCTAssertTrue(failureMessage(#"{"name":"내 통계","kind":"http","endpoint":"https://example.com","valuePath":"usage..total"}"#).contains("valuePath"))
        XCTAssertTrue(failureMessage(#"{"name":"내 통계","kind":"http","endpoint":"http://example.com","valuePath":"usage.total"}"#).contains("endpoint"))
        for kind in MetricKind.allCases where kind != .http {
            XCTAssertNoThrow(try TemplateEngine.decode("{\"name\":\"기존 항목\",\"kind\":\"\(kind.rawValue)\"}"))
        }
    }

    func testBothImportExamplesAreValidWithoutCredentials() throws {
        let manual = try TemplateEngine.decode(TemplateImportExample.manual.json)
        XCTAssertEqual(manual.kind, .manual)
        XCTAssertEqual(manual.manualValue, 25)
        XCTAssertEqual(manual.limit, 100)
        let http = try TemplateEngine.decode(TemplateImportExample.http.json)
        XCTAssertEqual(http.kind, .http)
        XCTAssertEqual(URLComponents(string: http.endpoint)?.host, "example.com")
        XCTAssertTrue(http.headers.isEmpty)
        XCTAssertFalse(http.endpoint.contains("api_key="))
    }

    private func failureMessage(_ json: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        do {
            _ = try TemplateEngine.decode(json)
            XCTFail("Expected invalid import to fail", file: file, line: line)
            return ""
        } catch {
            return error.localizedDescription
        }
    }
}
