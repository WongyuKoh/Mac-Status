import XCTest
@testable import MacStatus

final class MetricEditorValidationTests: XCTestCase {
    func testMissingRequiredFieldsAreCollectedAndOnlyCorrectedFieldsDisappear() {
        var template = apiTemplate()
        template.name = "  \n"
        template.endpoint = ""
        template.valuePath = ""

        XCTAssertEqual(fields(evaluate(template)), [.name, .endpoint, .valuePath])
        template.endpoint = "https://example.com/usage"
        XCTAssertEqual(fields(evaluate(template)), [.name, .valuePath])
        template.name = "  내 통계 \n"
        let named = evaluate(template)
        XCTAssertEqual(named.template.name, "내 통계")
        XCTAssertEqual(fields(named), [.valuePath])
        template.valuePath = "A.B.C"
        XCTAssertTrue(evaluate(template).issues.isEmpty)
    }

    func testManualZeroIsValidAndMissingOrInvalidCurrentValuesStayInvalid() {
        let template = MetricTemplate(name: "수동", kind: .manual, limit: nil)
        let zero = evaluate(template, valueText: "0")
        XCTAssertTrue(zero.issues.isEmpty)
        XCTAssertEqual(zero.template.manualValue, 0)

        for text in ["", " \n", "-1", "nan", "inf", "abc"] {
            let result = evaluate(template, valueText: text)
            XCTAssertEqual(fields(result), [.manualValue], "Invalid draft: \(text)")
            XCTAssertNil(result.template.manualValue)
        }
    }

    func testOptionalBlankLimitAndLimitPathDoNotBecomeRequiredFields() {
        var template = apiTemplate()
        template.limit = 100
        template.limitPath = ""
        let result = evaluate(template, limitText: " \n")
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertNil(result.template.limit)
        XCTAssertEqual(result.template.limitPath, "")

        for text in ["0", "-1", "nan", "inf", "bad"] {
            let invalid = evaluate(template, limitText: text)
            XCTAssertEqual(fields(invalid), [.limit])
            XCTAssertEqual(invalid.issues.filter { $0.field == .limit }.count, 1)
        }
    }

    func testInvalidMultiplierDraftsAreNeverSubmittedOrReportedTwice() {
        var template = apiTemplate()
        template.multiplier = .nan
        for text in ["0", "nan", "inf", "-inf", "", "1e9999", "bad"] {
            let result = evaluate(template, multiplierText: text)
            XCTAssertEqual(fields(result), [.multiplier])
            XCTAssertEqual(result.issues.filter { $0.field == .multiplier }.count, 1)
        }

        let negative = evaluate(template, multiplierText: "-0.5")
        XCTAssertTrue(negative.issues.isEmpty)
        XCTAssertEqual(negative.template.multiplier, -0.5)
    }

    func testJSONModeNormalizesHiddenNumericSettingsBeforeValidation() {
        var template = apiTemplate()
        template.valueMode = .json
        template.unit = String(repeating: "x", count: 50)
        template.limit = -1
        template.limitPath = "invalid..path"
        template.aggregation = "invalid"
        template.multiplier = .nan
        template.valueExpression = "unsupported(value)"
        template.limitExpression = "value +"

        let result = evaluate(template, limitText: "bad limit", valueText: "bad value", multiplierText: "bad multiplier")
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.template.unit, "")
        XCTAssertNil(result.template.limit)
        XCTAssertEqual(result.template.limitPath, "")
        XCTAssertEqual(result.template.aggregation, "first")
        XCTAssertEqual(result.template.multiplier, 1)
        XCTAssertNil(result.template.valueExpression)
        XCTAssertNil(result.template.limitExpression)
    }

    func testOptionalCalculationFieldsPreserveExistingTemplatesAndNormalizeBlankInput() {
        var template = apiTemplate()
        let original = evaluate(template)
        XCTAssertTrue(original.issues.isEmpty)
        XCTAssertEqual(original.template.id, template.id)
        XCTAssertNil(original.template.valueExpression)
        XCTAssertNil(original.template.limitExpression)

        template.valueExpression = " \n"
        template.limitExpression = "unused invalid expression"
        let blank = evaluate(template)
        XCTAssertTrue(blank.issues.isEmpty)
        XCTAssertNil(blank.template.valueExpression)
        XCTAssertNil(blank.template.limitExpression, "A calculation without a limit path must not remain active")
    }

    func testValueAndLimitCalculationsKeepTheirIndependentExpressions() {
        var template = apiTemplate()
        template.limitPath = "A.B.limit"
        template.valueExpression = "  value * 2 \n"
        template.limitExpression = " value / 1000 "
        let result = evaluate(template)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.template.valueExpression, "value * 2")
        XCTAssertEqual(result.template.limitExpression, "value / 1000")

        template.limitPath = ""
        let removedLimit = evaluate(template)
        XCTAssertTrue(removedLimit.issues.isEmpty)
        XCTAssertEqual(removedLimit.template.valueExpression, "value * 2")
        XCTAssertNil(removedLimit.template.limitExpression)
    }

    func testCalculationSyntaxErrorsAreAttachedToTheirOwnInputsAndClearIndependently() {
        var template = apiTemplate()
        template.limitPath = "A.B.limit"
        template.valueExpression = "unsupported(value)"
        template.limitExpression = "value +"
        let invalid = evaluate(template)
        XCTAssertEqual(fields(invalid), [.valueExpression, .limitExpression])
        for issue in invalid.issues {
            let message = MetricEditorValidation.message(for: issue, in: template)
            XCTAssertTrue(message.contains("계산식"))
            XCTAssertFalse(message.contains("unsupported"))
        }

        template.valueExpression = "value * 2"
        XCTAssertEqual(fields(evaluate(template)), [.limitExpression])
        template.limitExpression = "value / 2"
        XCTAssertTrue(evaluate(template).issues.isEmpty)
    }

    func testDivisionByZeroIsAValidExpressionForRuntimeNullHandling() {
        var template = apiTemplate()
        template.limitPath = "A.B.limit"
        template.valueExpression = "value / 0"
        template.limitExpression = "value / (value - value)"
        let result = evaluate(template)
        XCTAssertTrue(result.issues.isEmpty, "Runtime calculation failure is not an invalid form expression")
        XCTAssertEqual(result.template.valueExpression, "value / 0")
        XCTAssertEqual(result.template.limitExpression, "value / (value - value)")
    }

    func testBuiltInMetricsIgnoreInapplicableNumericDraftInputs() {
        for kind in [MetricKind.codex, .claude, .claudeAPI, .wakatime, .cpu, .memory, .storage, .temperature] {
            let template = MetricTemplate(name: "기본 항목", kind: kind, limit: 50)
            let result = evaluate(template, limitText: "bad limit", valueText: "bad value", multiplierText: "bad multiplier")
            XCTAssertTrue(result.issues.isEmpty, "Built-in kind: \(kind)")
            XCTAssertEqual(result.template.limit, 50)
            XCTAssertEqual(result.template.multiplier, 1)
        }
    }

    func testPublicAndAuthenticatedTemplatesKeepTheirCredentialConfiguration() {
        var template = apiTemplate()
        template.authPrefix = "Bearer "
        let authenticated = evaluate(template)
        XCTAssertTrue(authenticated.issues.isEmpty)
        XCTAssertEqual(authenticated.template.authPrefix, "Bearer ")
        XCTAssertFalse(fields(authenticated).contains(.token), "Draft validation cannot assume an empty field means no saved key")

        template.authHeader = ""
        template.authPrefix = ""
        let publicAPI = evaluate(template)
        XCTAssertTrue(publicAPI.issues.isEmpty)
        XCTAssertEqual(publicAPI.template.authHeader, "")
        XCTAssertFalse(fields(publicAPI).contains(.token))
    }

    func testUserFacingMessagesDoNotEchoCredentialsFromInvalidSettings() {
        let marker = "test-only-private-marker"
        var template = apiTemplate()
        template.endpoint = "https://example.com/usage?api_key=" + marker
        template.link = "https://example.com/#" + marker
        template.authHeader = "Header\r\n" + marker
        template.authPrefix = "Bearer \r\n" + marker
        template.headers = ["Authorization": marker]

        let result = evaluate(template)
        XCTAssertTrue(fields(result).isSuperset(of: [.endpoint, .link, .authHeader, .authPrefix, .headers]))
        for issue in result.issues {
            let message = MetricEditorValidation.message(for: issue, in: template)
            XCTAssertFalse(message.contains(marker))
            XCTAssertFalse(message.isEmpty)
        }
    }

    private func apiTemplate() -> MetricTemplate {
        MetricTemplate(name: "API", kind: .http, limit: nil,
                       endpoint: "https://example.com/usage", valuePath: "A.B.C")
    }

    private func evaluate(_ template: MetricTemplate, limitText: String = "", valueText: String = "", multiplierText: String = "1") -> MetricEditorValidation.Evaluation {
        MetricEditorValidation.evaluate(template, limitText: limitText, valueText: valueText, multiplierText: multiplierText)
    }

    private func fields(_ result: MetricEditorValidation.Evaluation) -> Set<TemplateField> {
        Set(result.issues.map(\.field))
    }
}
