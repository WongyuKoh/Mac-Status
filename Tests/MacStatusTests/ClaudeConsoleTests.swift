import XCTest
import JavaScriptCore
@testable import MacStatus

final class ClaudeConsoleTests: XCTestCase {
    private let apiID = "22222222-2222-4222-8222-222222222222"
    private let chatID = "11111111-1111-4111-8111-111111111111"
    private let now = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!

    func testAPIBalanceAndSpendAreSeparateAmounts() throws {
        let reading = try ClaudeConsoleParser.parse(credits: Data(#"{"amount":50000,"currency":"USD"}"#.utf8),
                                                    spend: Data(#"{"amount":1234}"#.utf8), organization: "API account")
        XCTAssertEqual(reading.value, 500)
        XCTAssertNil(reading.limit)
        XCTAssertEqual(reading.details.first?.value, "USD 500.00")
        XCTAssertEqual(reading.details.first { $0.label.contains("이번 달") }?.value, "USD 12.34")
        XCTAssertEqual(reading.details.last?.value, "API account")
    }

    func testReportedExponentAppliesToBalanceAndGrantsWithoutRescalingSpend() throws {
        let credits = #"{"amount":187250,"currency":"USD","balance":{"credits":{"exponent":3}},"promo_tranches":[{"program_id":"subscription_api_credit","currency":"USD","remaining_amount_minor_units":124750,"granted_amount_minor_units":200000,"expires_at":"2026-10-28T00:00:00Z"}]}"#
        let reading = try ClaudeConsoleParser.parse(credits: Data(credits.utf8), spend: Data(#"{"amount":4321}"#.utf8), now: now)
        XCTAssertEqual(reading.value, 187.25)
        let monthly = try XCTUnwrap(reading.details.first { $0.label.contains("구독 제공 API") })
        XCTAssertEqual(monthly.value, "USD 124.75 / USD 200.00 남음")
        XCTAssertEqual(try XCTUnwrap(monthly.fraction), 0.37625, accuracy: 0.00001)
        XCTAssertNil(monthly.resetAt, "Expiry is not a repeating quota reset")
        XCTAssertTrue(monthly.note?.contains("만료") == true)
        XCTAssertEqual(reading.details.first { $0.label.contains("이번 달") }?.value, "USD 43.21")
    }

    func testZeroIsARealBalanceButMissingMalformedAndFractionalMinorAmountsFail() throws {
        XCTAssertEqual(try ClaudeConsoleParser.parse(credits: Data(#"{"amount":0,"currency":"USD"}"#.utf8)).value, 0)
        for input in [#"{}"#, #"{"amount":null,"currency":"USD"}"#, #"{"amount":true,"currency":"USD"}"#,
                      #"{"amount":-1,"currency":"USD"}"#, #"{"amount":"50000","currency":"USD"}"#,
                      #"{"amount":12.5,"currency":"USD"}"#, #"{"amount":1e99,"currency":"USD"}"#,
                      #"{"amount":50000,"currency":"EUR"}"#,
                      #"{"amount":50000,"currency":"USD","balance":{"credits":{"exponent":5}}}"#,
                      #"{"amount":50000,"currency":"USD","tranches":{}}"#] {
            XCTAssertThrowsError(try ClaudeConsoleParser.parse(credits: Data(input.utf8)), input)
        }
    }

    func testOptionalSpendFailureDoesNotHideVerifiedCreditBalance() throws {
        let credits = Data(#"{"amount":50000,"currency":"USD"}"#.utf8)
        for spend in [nil, Data("not json".utf8), Data(#"{"amount":null}"#.utf8), Data(#"{"amount":-1}"#.utf8)] {
            let reading = try ClaudeConsoleParser.parse(credits: credits, spend: spend)
            XCTAssertEqual(reading.value, 500)
            XCTAssertEqual(reading.state, .ready)
            XCTAssertEqual(reading.details.first { $0.label.contains("이번 달") }?.value, "정보 미제공")
        }
    }

    func testExpiredGrantsAreOmittedAndInvalidGrantsNeverBecomeZero() throws {
        let root: [String: Any] = ["amount": 50000, "currency": "USD", "tranches": [
            ["id": "old", "currency": "USD", "remaining_amount_minor_units": 1000, "granted_amount_minor_units": 2000, "expires_at": "2026-10-24T00:00:00Z"],
            ["id": "broken", "currency": "USD", "remaining_amount_minor_units": 9999, "granted_amount_minor_units": 2000],
            ["id": "active", "program_id": "api_credits", "currency": "USD", "remaining_amount_minor_units": 0, "granted_amount_minor_units": 2000]
        ]]
        let reading = try ClaudeConsoleParser.parse(credits: JSONSerialization.data(withJSONObject: root), now: now)
        let grants = reading.details.filter { $0.label.contains("구매 API") }
        XCTAssertEqual(grants.count, 1)
        XCTAssertEqual(grants.first?.value, "USD 0.00 / USD 20.00 남음")
        XCTAssertEqual(grants.first?.fraction, 1)
    }

    @MainActor
    func testOnlyExactHTTPSConsoleOriginCanReadBilling() {
        XCTAssertTrue(ClaudeConsoleSession.canRead(at: URL(string: "https://platform.claude.com/settings/billing")))
        for address in ["https://claude.ai/settings/usage", "http://platform.claude.com", "https://platform.claude.com.evil.example", "https://user@platform.claude.com", "https://platform.claude.com:8443"] {
            XCTAssertFalse(ClaudeConsoleSession.canRead(at: URL(string: address)), address)
        }
        XCTAssertTrue(ClaudeConsoleSession.isAuthenticationPage(URL(string: "https://platform.claude.com/login?returnTo=/settings/billing")))
        XCTAssertFalse(ClaudeConsoleSession.isAuthenticationPage(URL(string: "https://platform.claude.com/settings/billing?returnTo=/login")))
    }

    @MainActor
    func testExternalOAuthAndAuthenticationPagesRemainPendingRatherThanBillingFailures() {
        for address in [
            "https://accounts.google.com/v3/signin/identifier?continue=https%3A%2F%2Fplatform.claude.com",
            "https://accounts.google.com/o/oauth2/auth",
            "https://platform.claude.com/login?returnTo=/settings/billing",
            "https://platform.claude.com/auth/callback",
            "https://platform.claude.com.evil.example/settings/billing",
            "http://platform.claude.com/settings/billing"
        ] {
            XCTAssertNotNil(ClaudeConsoleSession.authenticationStatus(at: URL(string: address)), address)
        }
        XCTAssertNotNil(ClaudeConsoleSession.authenticationStatus(at: nil))
        XCTAssertNil(ClaudeConsoleSession.authenticationStatus(at: URL(string: "https://platform.claude.com/settings/billing?returnTo=/login")))
    }

    @MainActor
    func testLoginRetryDestinationIsTheExactOfficialConsoleLoginWithoutCredentials() {
        XCTAssertEqual(ClaudeConsoleSession.loginURL.absoluteString, "https://platform.claude.com/login")
        XCTAssertTrue(ClaudeConsoleSession.canRead(at: ClaudeConsoleSession.loginURL))
        XCTAssertTrue(ClaudeConsoleSession.isAuthenticationPage(ClaudeConsoleSession.loginURL))
        XCTAssertNotNil(ClaudeConsoleSession.authenticationStatus(at: ClaudeConsoleSession.loginURL))
        XCTAssertNil(ClaudeConsoleSession.loginURL.query)
        XCTAssertNil(ClaudeConsoleSession.loginURL.user)
        XCTAssertNil(ClaudeConsoleSession.loginURL.password)
    }

    @MainActor
    func testAuthenticationPopupPolicyKeepsHTTPSAndBlankOpenerContextsOnly() {
        for address in ["https://accounts.google.com/o/oauth2/auth", "https://platform.claude.com/auth/callback", "about:blank"] {
            XCTAssertTrue(ClaudeConsoleSession.canOpenAuthenticationPopup(at: URL(string: address)), address)
        }
        for address in ["http://accounts.google.com", "javascript:alert(1)", "data:text/html,test", "file:///tmp/auth.html", "https://user@accounts.google.com", "https://accounts.google.com:8443"] {
            XCTAssertFalse(ClaudeConsoleSession.canOpenAuthenticationPopup(at: URL(string: address)), address)
        }
        XCTAssertFalse(ClaudeConsoleSession.canOpenAuthenticationPopup(at: nil))
    }

    @MainActor
    func testScriptReadsAPIOrganizationAndOptionalSpendFailureKeepsBalance() throws {
        let payload = try runScript(responses: [
            ["body": [["uuid": chatID, "name": "Chat", "capabilities": ["chat"]], ["uuid": apiID, "name": "API", "capabilities": ["api"]]]],
            ["body": ["amount": 50000, "currency": "USD"]],
            ["status": 401]
        ])
        XCTAssertEqual(payload["status"] as? Int, 200)
        XCTAssertEqual(payload["selectedOrganization"] as? String, apiID)
        XCTAssertEqual((payload["organizations"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(payload["spendBody"])
        XCTAssertEqual(payload["authenticated"] as? Bool, true)
    }

    @MainActor
    func testMultipleAPIOrganizationsRequireExplicitSelection() throws {
        let otherID = "33333333-3333-4333-8333-333333333333"
        let response: [String: Any] = ["body": [["uuid": apiID, "capabilities": ["api"]], ["uuid": otherID, "capabilities": ["api"]]]]
        XCTAssertEqual(try runScript(responses: [response])["status"] as? Int, 409)
        let selected = try runScript(responses: [response, ["body": ["amount": 0, "currency": "USD"]], ["status": 403]], selection: otherID)
        XCTAssertEqual(selected["selectedOrganization"] as? String, otherID)
        XCTAssertEqual(selected["status"] as? Int, 200)
    }

    @MainActor
    func testChatOnlyOrInvalidOrganizationNeverReceivesBillingRequest() throws {
        let result = try runScript(responses: [["body": [["uuid": chatID, "capabilities": ["chat"]], ["uuid": "../../bad", "capabilities": ["api"]]]]])
        XCTAssertEqual(result["status"] as? Int, 422)
    }

    @MainActor
    private func runScript(responses: [[String: Any]], selection: String = "") throws -> [String: Any] {
        let context = try XCTUnwrap(JSContext())
        let responsesJSON = String(data: try JSONSerialization.data(withJSONObject: responses), encoding: .utf8)!
        let scriptJSON = String(data: try JSONEncoder().encode(ClaudeConsoleSession.script), encoding: .utf8)!
        let selectionJSON = String(data: try JSONEncoder().encode(selection), encoding: .utf8)!
        context.evaluateScript("""
        const queue = \(responsesJSON);
        const location = {origin:'https://platform.claude.com'};
        class AbortController { constructor() { this.signal = {}; } abort() {} }
        function setTimeout() { return 1; }
        function clearTimeout() {}
        class TextDecoder { decode(bytes) { return String.fromCharCode(...bytes); } }
        async function fetch(path, options) {
            if (!queue.length) throw new Error('Unexpected request');
            const next = queue.shift();
            const status = next.status || 200;
            const text = JSON.stringify(next.body || {});
            const bytes = Uint8Array.from(text, c => c.charCodeAt(0));
            let read = false;
            return {status,ok:status >= 200 && status < 300,headers:{get(name) { return name === 'Content-Type' ? 'application/json' : null; }},
              body:{getReader() { return {async read() { if (read) return {done:true}; read = true; return {done:false,value:bytes}; },async cancel() {}}; }}};
        }
        var output, failure;
        const execute = new (Object.getPrototypeOf(async function() {}).constructor)('selectedOrganization',\(scriptJSON));
        execute(\(selectionJSON)).then(value => output = JSON.stringify(value), error => failure = String(error));
        """)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        XCTAssertTrue(context.objectForKeyedSubscript("failure")?.isUndefined == true)
        let output = try XCTUnwrap(context.objectForKeyedSubscript("output")?.toString())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
