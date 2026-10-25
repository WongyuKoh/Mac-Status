import XCTest
@testable import MacStatus

final class APIGuideExamplesTests: XCTestCase {
    func testDisplayedSingleValueAndLimitMatchTheTeachingResponse() throws {
        let template = APIGuideExamples.singleTemplate
        try TemplateEngine.validate(template)
        let reading = try TemplateEngine.reading(from: Data(APIGuideExamples.singleResponse.utf8), template: template)
        XCTAssertEqual(reading.value, 42)
        XCTAssertEqual(reading.limit, 100)
        XCTAssertEqual(URL(string: template.endpoint)?.host, "example.com")
        XCTAssertTrue(template.authHeader.isEmpty)
        XCTAssertTrue(template.authPrefix.isEmpty)
    }

    func testDisplayedArrayPathProducesTheExplainedSum() throws {
        let template = APIGuideExamples.sumTemplate
        try TemplateEngine.validate(template)
        let reading = try TemplateEngine.reading(from: Data(APIGuideExamples.sumResponse.utf8), template: template)
        XCTAssertEqual(reading.value, 20)
    }

    func testAdminRequirementsOnlyApplyToActualOrganizationEndpoints() {
        XCTAssertEqual(APIProviderRequirement(endpoint: "https://api.openai.com/v1/organization/costs?start_time=1"), .openAIOrganization)
        XCTAssertEqual(APIProviderRequirement(endpoint: "https://api.anthropic.com/v1/organizations/cost_report"), .anthropicOrganization)
        for endpoint in [
            "https://api.openai.com/v1/models",
            "https://example.com/?url=api.openai.com/v1/organization/costs",
            "https://api.openai.com.example.com/v1/organization/costs",
            "https://api.anthropic.com/v1/messages"
        ] {
            XCTAssertNil(APIProviderRequirement(endpoint: endpoint), endpoint)
        }
    }
}
