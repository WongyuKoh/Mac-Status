import XCTest
@testable import MacStatus

final class TemplateCalculationTests: XCTestCase {
    func testLegacyTemplatesAndJSONRoundTripKeepIndependentExpressions() throws {
        let legacy = try TemplateEngine.decode(#"{"name":"API","kind":"http","endpoint":"https://example.com/usage","valuePath":"A.B.C"}"#)
        XCTAssertNil(legacy.valueExpression)
        XCTAssertNil(legacy.limitExpression)
        XCTAssertFalse(legacy.hasNumericExpressions)
        XCTAssertEqual(try JSONDecoder().decode(MetricTemplate.self, from: JSONEncoder().encode(legacy)), legacy)

        var template = legacy
        template.limitPath = "limit"
        template.valueExpression = "value * 2"
        template.limitExpression = "value / 10"
        XCTAssertTrue(template.hasNumericExpressions)
        XCTAssertEqual(try TemplateEngine.decode(TemplateEngine.encode(template)), template)
        XCTAssertEqual(try JSONDecoder().decode(MetricTemplate.self, from: JSONEncoder().encode(template)), template)
    }

    func testValueExpressionUsesTheExtractedPathBeforePercentageDisplay() throws {
        var template = apiTemplate()
        template.limit = 100
        template.valueExpression = "value * 2"
        let reading = try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":25}}}"#.utf8), template: template)
        XCTAssertEqual(reading.state, .ready)
        XCTAssertEqual(reading.value, 50)
        XCTAssertEqual(reading.limit, 100)
        XCTAssertEqual(reading.fraction, 0.5)
    }

    func testAggregationThenIndependentExpressionsThenLegacyMultiplier() throws {
        var template = apiTemplate()
        template.valuePath = "data.*.value"
        template.aggregation = "sum"
        template.valueExpression = "(value + 1) * 2"
        template.limitPath = "limit"
        template.limitExpression = "value / 2"
        template.multiplier = 0.5
        let reading = try TemplateEngine.reading(from: Data(#"{"data":[{"value":1},{"value":2}],"limit":20}"#.utf8), template: template)
        XCTAssertEqual(reading.value, 4)
        XCTAssertEqual(reading.limit, 5)
        XCTAssertEqual(try XCTUnwrap(reading.fraction), 0.8, accuracy: 0.000001)
    }

    func testDivisionByZeroInEitherExpressionProducesAnExplicitNull() throws {
        for expressions in [("value / 0", "value"), ("value", "value / (value - value)")] {
            var template = apiTemplate()
            template.limitPath = "limit"
            template.valueExpression = expressions.0
            template.limitExpression = expressions.1
            XCTAssertNoThrow(try TemplateEngine.validate(template), "Runtime zero division is valid expression syntax")
            assertNull(try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":12}},"limit":100}"#.utf8), template: template))
        }
    }

    func testOverflowAndInvalidCalculatedLimitNeverBecomeNumbers() throws {
        var template = apiTemplate()
        template.valueExpression = "value * value"
        assertNull(try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":1e308}}}"#.utf8), template: template))
        template.valueExpression = "value"
        template.multiplier = 2
        assertNull(try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":1e308}}}"#.utf8), template: template))

        template.multiplier = 1
        template.limitPath = "limit"
        for expression in ["value - value", "-value"] {
            template.limitExpression = expression
            assertNull(try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":12}},"limit":100}"#.utf8), template: template))
        }
    }

    func testCalculatedZeroIsValidAndDoesNotDisplayNegativeZero() throws {
        var template = apiTemplate()
        template.valueExpression = "value / -2"
        let reading = try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":0}}}"#.utf8), template: template)
        XCTAssertEqual(reading.state, .ready)
        XCTAssertEqual(reading.value, 0)
        XCTAssertEqual(try XCTUnwrap(reading.value).sign, .plus)
        XCTAssertNil(reading.text)
    }

    func testUnusedExpressionsDoNotAffectStaticLimitsOrRawJSON() throws {
        var template = apiTemplate()
        template.limit = 100
        template.limitExpression = "unsupported()"
        XCTAssertNoThrow(try TemplateEngine.validate(template))
        var reading = try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":25}}}"#.utf8), template: template)
        XCTAssertEqual(reading.value, 25)
        XCTAssertEqual(reading.limit, 100)

        template.valueMode = .json
        template.valueExpression = "unsupported()"
        XCTAssertFalse(template.hasNumericExpressions)
        XCTAssertNoThrow(try TemplateEngine.validate(template))
        reading = try TemplateEngine.reading(from: Data(#"{"A":{"B":{"C":false}}}"#.utf8), template: template)
        XCTAssertEqual(reading.text, "false")
        XCTAssertNil(reading.value)
    }

    func testExpressionSyntaxAndJSONTypesHaveTheirOwnValidationFields() {
        var template = apiTemplate()
        template.limitPath = "limit"
        template.valueExpression = "value +"
        template.limitExpression = "limit * 2"
        XCTAssertEqual(TemplateEngine.validationIssues(for: template).map(\.field), [.valueExpression, .limitExpression])
        for field in ["valueExpression", "limitExpression"] {
            let json = "{\"name\":\"API\",\"kind\":\"http\",\"endpoint\":\"https://example.com/usage\",\"valuePath\":\"A.B.C\",\"\(field)\":12}"
            XCTAssertThrowsError(try TemplateEngine.decode(json)) { error in
                XCTAssertTrue(error.localizedDescription.contains(field))
            }
        }
    }

    private func apiTemplate() -> MetricTemplate {
        .init(name: "API", kind: .http, unit: "%", limit: nil, endpoint: "https://example.com/usage", valuePath: "A.B.C")
    }

    private func assertNull(_ reading: MetricReading, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reading.text, "null", file: file, line: line)
        XCTAssertEqual(reading.state, .unavailable, file: file, line: line)
        XCTAssertNil(reading.value, file: file, line: line)
        XCTAssertNil(reading.limit, file: file, line: line)
        XCTAssertNil(reading.updatedAt, file: file, line: line)
        XCTAssertNil(reading.fraction, file: file, line: line)
    }
}
