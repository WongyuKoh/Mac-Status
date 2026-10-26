import XCTest
@testable import MacStatus

final class MetricCalculationTests: XCTestCase {
    func testIncomingValuesAndIndependentExpressionsAreCalculated() throws {
        XCTAssertEqual(try MetricCalculation.evaluate("value * 2", value: 21), 42)
        XCTAssertEqual(try MetricCalculation.evaluate("value / 100", value: 2_500), 25)
        XCTAssertEqual(try MetricCalculation.evaluate("value + 10", value: 90), 100)
        XCTAssertEqual(try MetricCalculation.evaluate("42", value: 999), 42)
        XCTAssertEqual(try MetricCalculation.evaluate("value * 0", value: 50), 0)
        XCTAssertEqual(try MetricCalculation.evaluate("", value: 12), 12)
        XCTAssertEqual(try MetricCalculation.evaluate(" \t\r\n ", value: 12), 12)
    }

    func testPrecedenceParenthesesAndLeftAssociativityMatchArithmetic() throws {
        XCTAssertEqual(try MetricCalculation.evaluate("value + 2 * 3", value: 4), 10)
        XCTAssertEqual(try MetricCalculation.evaluate("(value + 2) * 3", value: 4), 18)
        XCTAssertEqual(try MetricCalculation.evaluate("20 - 5 - 2", value: 0), 13)
        XCTAssertEqual(try MetricCalculation.evaluate("24 / 3 / 2", value: 0), 4)
        XCTAssertEqual(try MetricCalculation.evaluate("24 / (3 / 2)", value: 0), 16)
    }

    func testUnarySignsAndFiniteDecimalScientificLiterals() throws {
        XCTAssertEqual(try MetricCalculation.evaluate("-value + +2", value: 5), -3)
        XCTAssertEqual(try MetricCalculation.evaluate("value * -2", value: 5), -10)
        XCTAssertEqual(try MetricCalculation.evaluate("--value", value: 5), 5)
        XCTAssertEqual(try MetricCalculation.evaluate("-(value - .5) / 2.", value: 2.5), -1)
        XCTAssertEqual(try MetricCalculation.evaluate("value * 1e-2 + 2E+1", value: 250), 22.5)
    }

    func testDivisionByPositiveNegativeAndComputedZeroIsARuntimeFailure() throws {
        for expression in ["value / 0", "value / -0", "0 / 0", "value / (value - value)", "value / (0 * value)"] {
            XCTAssertNoThrow(try MetricCalculation.validate(expression))
            XCTAssertThrowsError(try MetricCalculation.evaluate(expression, value: 12)) { error in
                XCTAssertEqual(error as? MetricCalculation.Failure, .divisionByZero)
            }
        }
        XCTAssertNoThrow(try MetricCalculation.validate("10 / value"))
        XCTAssertEqual(try MetricCalculation.evaluate("10 / value", value: 2), 5)
        XCTAssertThrowsError(try MetricCalculation.evaluate("10 / value", value: 0)) { error in
            XCTAssertEqual(error as? MetricCalculation.Failure, .divisionByZero)
        }
    }

    func testEveryIntermediateResultMustBeFinite() {
        for expression in ["value * 2", "(value * 2) / 2", "value + value", "value / 1e-300"] {
            XCTAssertThrowsError(try MetricCalculation.evaluate(expression, value: Double.greatestFiniteMagnitude)) { error in
                XCTAssertEqual(error as? MetricCalculation.Failure, .nonFinite)
            }
        }
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try MetricCalculation.evaluate("value", value: value)) { error in
                XCTAssertEqual(error as? MetricCalculation.Failure, .nonFinite)
            }
            XCTAssertThrowsError(try MetricCalculation.evaluate("", value: value))
        }
        XCTAssertThrowsError(try MetricCalculation.validate("1e999")) { error in
            XCTAssertEqual(error as? MetricCalculation.Failure, .nonFinite)
        }
    }

    func testMalformedExpressionsAndExecutableSyntaxAreRejectedWithoutEchoingInput() {
        for expression in ["value +", "* value", "value value", "2value", "(value", "value)", "()", ".", "1e", "1e+", "1..2", "value ** 2", "value % 2", "value ^ 2", "Value", "limit", "A.B.C", "sqrt(value)", "value; print(1)", "$(echo private-marker)", "value[0]", "{value: 1}", "nan", "inf", "value\0"] {
            XCTAssertThrowsError(try MetricCalculation.validate(expression), "Rejected expression: \(expression)") { error in
                XCTAssertEqual(error as? MetricCalculation.Failure, .invalidExpression)
                XCTAssertFalse(error.localizedDescription.contains("private-marker"))
            }
            XCTAssertThrowsError(try MetricCalculation.evaluate(expression, value: 1))
        }
    }

    func testExpressionSizeTokenCountAndDepthAreBounded() throws {
        XCTAssertThrowsError(try MetricCalculation.validate(String(repeating: " ", count: MetricCalculation.maximumExpressionBytes + 1))) { error in
            XCTAssertEqual(error as? MetricCalculation.Failure, .tooComplex)
        }
        XCTAssertThrowsError(try MetricCalculation.validate(String(repeating: "+", count: MetricCalculation.maximumTokens + 1))) { error in
            XCTAssertEqual(error as? MetricCalculation.Failure, .tooComplex)
        }
        let validNested = String(repeating: "(", count: MetricCalculation.maximumDepth - 1) + "value" + String(repeating: ")", count: MetricCalculation.maximumDepth - 1)
        XCTAssertEqual(try MetricCalculation.evaluate(validNested, value: 7), 7)
        for expression in [
            "(" + validNested + ")",
            String(repeating: "-", count: MetricCalculation.maximumDepth) + "value",
            Array(repeating: "1", count: MetricCalculation.maximumDepth + 1).joined(separator: "+")
        ] {
            XCTAssertThrowsError(try MetricCalculation.validate(expression)) { error in
                XCTAssertEqual(error as? MetricCalculation.Failure, .tooComplex)
            }
        }
    }
}
