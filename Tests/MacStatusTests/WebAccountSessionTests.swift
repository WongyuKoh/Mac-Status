import XCTest
import JavaScriptCore
@testable import MacStatus

final class WebAccountSessionTests: XCTestCase {
    func testAuthenticationRoutesRemainPendingDespiteUsageReturnTo() {
        for address in [
            "https://claude.ai/login?from=logout&reauth=1&returnTo=%2Fsettings%2Fusage",
            "https://claude.ai/login/verify?returnTo=/settings/usage",
            "https://claude.ai/auth/callback?returnTo=/settings/usage",
            "https://claude.ai/email-code?returnTo=/settings/usage",
            "https://claude.ai/magic-link?returnTo=/settings/usage",
            "https://claude.ai/VERIFY-CODE?returnTo=/settings/usage"
        ] {
            let url = URL(string: address)
            XCTAssertTrue(WebAccountPolicy.isAuthenticationPage(at: url, for: .claude), address)
            XCTAssertTrue(WebAccountPolicy.authenticationStatus(at: url, for: .claude)?.contains("인증을 완료하면") == true)
        }
    }

    func testUsageAndChatPagesDoNotBecomeAuthenticationStagesFromQueryOrSubstring() {
        for address in [
            "https://claude.ai/settings/usage",
            "https://claude.ai/settings/usage?returnTo=/login&from=logout",
            "https://claude.ai/new?ref=verify",
            "https://claude.ai/chat/thread-with-auth-in-title",
            "https://chatgpt.com/codex/settings/usage?returnTo=/auth/callback",
            "https://claude.ai/settings/login-history"
        ] {
            let url = URL(string: address)
            let kind: MetricKind = url?.host == "chatgpt.com" ? .codex : .claude
            XCTAssertFalse(WebAccountPolicy.isAuthenticationPage(at: url, for: kind), address)
            XCTAssertNil(WebAccountPolicy.authenticationStatus(at: url, for: kind))
        }
    }

    func testExternalAuthenticationCannotBecomeAnAllowedUsageOrigin() {
        for address in [
            "https://auth.openai.com/log-in-or-create-account",
            "https://accounts.google.com/v3/signin/identifier",
            "https://appleid.apple.com/auth/authorize"
        ] {
            let url = URL(string: address)
            XCTAssertTrue(WebAccountPolicy.isAuthenticationPage(at: url, for: .codex), address)
            XCTAssertFalse(WebAccountPolicy.canReadUsage(at: url, for: .codex), address)
            XCTAssertFalse(WebAccountPolicy.canReadUsage(at: url, for: .claude), address)
        }
        XCTAssertFalse(WebAccountPolicy.isAuthenticationPage(at: nil, for: .claude))
        XCTAssertFalse(WebAccountPolicy.isAuthenticationPage(at: URL(string: "https://claude.ai/login"), for: .cpu))
    }

    func testUsageScriptsAreRestrictedToExactOfficialHTTPSOrigins() {
        XCTAssertTrue(WebAccountPolicy.canReadUsage(at: URL(string: "https://chatgpt.com/codex/settings/usage"), for: .codex))
        XCTAssertTrue(WebAccountPolicy.canReadUsage(at: URL(string: "https://claude.ai:443/settings/usage"), for: .claude))
        for address in ["http://chatgpt.com", "https://chatgpt.com.evil.example", "https://auth.openai.com", "https://chatgpt.com:8443", "https://user@chatgpt.com", "file:///tmp/chatgpt.com"] {
            XCTAssertFalse(WebAccountPolicy.canReadUsage(at: URL(string: address), for: .codex), address)
        }
        XCTAssertFalse(WebAccountPolicy.canReadUsage(at: URL(string: "https://claude.ai"), for: .codex))
        XCTAssertFalse(WebAccountPolicy.canReadUsage(at: nil, for: .claude))
    }

    func testProvidersHaveSeparateStableWebsiteStores() {
        XCTAssertNotEqual(WebAccountPolicy.storeIdentifier(for: .codex), WebAccountPolicy.storeIdentifier(for: .claude))
        XCTAssertEqual(WebAccountPolicy.storeIdentifier(for: .codex), WebAccountPolicy.storeIdentifier(for: .codex))
    }

    func testOrganizationSelectionKeepsOnlyValidUniqueIDs() {
        let id = "877e7bb6-a4e6-4b97-8c39-e8f155189bb6"
        let organizations = WebAccountPolicy.organizations(from: [
            ["id": id, "name": "개인 워크스페이스"],
            ["id": id, "name": "중복"],
            ["id": "../../other", "name": "잘못된 ID"],
            ["name": "ID 없음"]
        ])
        XCTAssertEqual(organizations, [.init(id: id, name: "개인 워크스페이스")])
    }

    func testOversizedOrNonstringsAreRejectedBeforeParsing() throws {
        XCTAssertEqual(try WebAccountPolicy.usageData(from: "{\"used_percent\":0}"), Data("{\"used_percent\":0}".utf8))
        XCTAssertThrowsError(try WebAccountPolicy.usageData(from: ["accessToken": "should never be returned"]))
        XCTAssertThrowsError(try WebAccountPolicy.usageData(from: String(repeating: "a", count: 1_048_577)))
    }

    func testBrowserChallengeAndPermissionFailureDoNotPretendTheUserSignedOut() {
        let challenge = WebAccountPolicy.failure(from: ["issue": "browser_challenge"], status: 403)
        XCTAssertEqual(challenge?.reading.state, .failed)
        XCTAssertEqual(challenge?.authenticationLost, false)
        XCTAssertTrue(challenge?.reading.subtitle.contains("브라우저 확인") == true)
        let forbidden = WebAccountPolicy.failure(from: ["authenticated": true], status: 403)
        XCTAssertEqual(forbidden?.reading.state, .failed)
        XCTAssertEqual(forbidden?.authenticationLost, false)
        XCTAssertTrue(forbidden?.reading.subtitle.contains("조회가 허용되지") == true)
        let missingSession = WebAccountPolicy.failure(from: [:], status: 401)
        XCTAssertEqual(missingSession?.reading.state, .needsSetup)
        XCTAssertEqual(missingSession?.authenticationLost, true)
    }

    func testHTMLFallbackAndEmptyResponseAreFailuresRatherThanUsage() {
        let html = WebAccountPolicy.failure(from: ["issue": "html_response"], status: 200)
        XCTAssertEqual(html?.reading.state, .failed)
        XCTAssertNil(html?.reading.value)
        XCTAssertTrue(html?.reading.subtitle.contains("웹 페이지") == true)
        XCTAssertEqual(WebAccountPolicy.failure(from: ["issue": "empty_response"], status: 200)?.reading.state, .failed)
        XCTAssertNil(WebAccountPolicy.failure(from: [:], status: 200))
    }

    func testRetryAfterRemainsBoundedAndNeverClearsAuthentication() {
        for (provided, expected) in [(1.0, 300.0), (900.0, 900.0), (999_999.0, 3600.0), (Double.nan, 300.0)] {
            let failure = WebAccountPolicy.failure(from: ["retrySeconds": provided], status: 429)
            XCTAssertEqual(failure?.retrySeconds, expected)
            XCTAssertEqual(failure?.authenticationLost, false)
        }
    }

    @MainActor
    func testNativeDeadlineReleasesANeverCompletingWebKitCall() async throws {
        let gate = WebAccountDeadline()
        let began = Date()
        do {
            _ = try await gate.run(timeoutSeconds: 0.02) { _ in }
            XCTFail("A hung callback must time out")
        } catch WebAccountDeadlineError.timedOut {}
        XCTAssertLessThan(Date().timeIntervalSince(began), 1)
    }

    @MainActor
    func testNativeCancellationAndLateDuplicateCallbacksCompleteOnlyOnce() async throws {
        let gate = WebAccountDeadline()
        var callback: WebAccountDeadline.Completion?
        let task = Task { try await gate.run(timeoutSeconds: 2) { callback = $0 } }
        while callback == nil { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation should release the caller") }
        catch is CancellationError {}
        callback?(.success("late result"))
        callback?(.success("duplicate result"))
        await Task.yield()
    }

    @MainActor
    func testNavigationCancellationKeepsItsDistinctReason() async throws {
        let gate = WebAccountDeadline()
        var callback: WebAccountDeadline.Completion?
        let task = Task { try await gate.run(timeoutSeconds: 2) { callback = $0 } }
        while callback == nil { await Task.yield() }
        gate.cancel(error: WebAccountDeadlineError.navigationChanged)
        do { _ = try await task.value; XCTFail("Document navigation should cancel its pending extraction") }
        catch WebAccountDeadlineError.navigationChanged {}
        callback?(.success("old document result"))
        await Task.yield()
    }

    @MainActor
    func testCancelledBeforeStartDoesNotRunJavaScript() async throws {
        let gate = WebAccountDeadline()
        gate.cancel()
        var started = false
        do { _ = try await gate.run(timeoutSeconds: 1) { _ in started = true }; XCTFail("An invalidated request must not start") }
        catch is CancellationError {}
        XCTAssertFalse(started)
    }

    @MainActor
    func testCodexScriptReturnsUsageWithoutReturningItsSessionToken() throws {
        let result = try runScript(.codex, responses: [
            ["body": ["accessToken": "fixture-secret"]],
            ["body": ["rate_limit": ["primary_window": ["used_percent": 12]]]]
        ])
        XCTAssertEqual(result["status"] as? Int, 200)
        XCTAssertTrue(result["authenticated"] as? Bool == true)
        XCTAssertFalse(String(describing: result).contains("fixture-secret"))
    }

    @MainActor
    func testScriptDistinguishesACloudflareHTMLChallenge() throws {
        let result = try runScript(.codex, responses: [
            ["status": 403, "contentType": "text/html", "text": "<!doctype html><html>Just a moment cf-chl</html>"]
        ])
        XCTAssertEqual(result["status"] as? Int, 403)
        XCTAssertEqual(result["issue"] as? String, "browser_challenge")
        XCTAssertNil(result["body"])
    }

    @MainActor
    func testClaudeScriptRequiresSelectionAndDoesNotQueryAnArbitraryOrganization() throws {
        let first = "877e7bb6-a4e6-4b97-8c39-e8f155189bb6"
        let second = "f5d9ecbd-cb2c-4477-9dc0-2c07a353427b"
        let result = try runScript(.claude, responses: [["body": [
            ["uuid": first, "name": "One", "capabilities": ["chat"]],
            ["uuid": second, "name": "Two", "capabilities": ["chat"]]
        ]]])
        XCTAssertEqual(result["status"] as? Int, 409)
        XCTAssertEqual((result["organizations"] as? [[String: Any]])?.count, 2)
        XCTAssertNil(result["body"])
    }

    @MainActor
    func testClaudeScriptHonorsTheSelectedWorkspaceAndExcludesAPIOnlyOrganizations() throws {
        let first = "877e7bb6-a4e6-4b97-8c39-e8f155189bb6"
        let second = "f5d9ecbd-cb2c-4477-9dc0-2c07a353427b"
        let result = try runScript(.claude, responses: [
            ["body": [
                ["uuid": first, "name": "One", "capabilities": ["chat"]],
                ["uuid": second, "name": "API", "capabilities": ["api"]],
                ["uuid": "../../invalid", "name": "Invalid"]
            ]],
            ["body": ["five_hour": ["utilization": 7]]]
        ], selectedOrganization: first)
        XCTAssertEqual(result["status"] as? Int, 200)
        XCTAssertEqual(result["selectedOrganization"] as? String, first)
        XCTAssertEqual((result["organizations"] as? [[String: Any]])?.count, 1)
    }

    @MainActor
    func testClaudeScriptAddsPrepaidBalanceWithoutReplacingPlanUsage() throws {
        let org = "877e7bb6-a4e6-4b97-8c39-e8f155189bb6"
        let result = try runScript(.claude, responses: [
            ["body": [["uuid": org, "name": "Workspace", "capabilities": ["chat"]]]],
            ["body": ["five_hour": ["utilization": 7], "seven_day": ["utilization": 12]]],
            ["body": ["amount": 1234, "currency": "USD"]]
        ])
        XCTAssertEqual(result["status"] as? Int, 200)
        let usage = try WebAccountPolicy.usageData(from: result["body"])
        let balance = try WebAccountPolicy.usageData(from: result["prepaidBody"])
        let reading = try AIUsageParser.claude(usage, prepaidData: balance)
        XCTAssertEqual(reading.value, 7)
        XCTAssertEqual(reading.details.first { $0.role == .weekly }?.fraction, 0.12)
        XCTAssertTrue(reading.details.contains { $0.role == .credits && $0.value.contains("12.34") })
    }

    @MainActor
    func testClaudeScriptOptionalBillingFailuresKeepQuotaAndAuthentication() throws {
        let org = "877e7bb6-a4e6-4b97-8c39-e8f155189bb6"
        let failures: [[String: Any]] = [["status": 403], ["status": 404], ["status": 429], ["text": "invalid JSON"], ["throws": true]]
        for failure in failures {
            let result = try runScript(.claude, responses: [
                ["body": [["uuid": org, "name": "Workspace", "capabilities": ["chat"]]]],
                ["body": ["five_hour": ["utilization": 7]]], failure
            ])
            XCTAssertEqual(result["status"] as? Int, 200)
            XCTAssertEqual(result["authenticated"] as? Bool, true)
            XCTAssertNil(result["prepaidBody"])
            XCTAssertEqual(try AIUsageParser.claude(WebAccountPolicy.usageData(from: result["body"])).value, 7)
        }
    }

    /// Runs the production script with a deterministic in-memory fetch transport.
    /// JavaScriptCore is a macOS framework; this needs no browser or Node install.
    @MainActor
    private func runScript(_ kind: MetricKind, responses: [[String: Any]], selectedOrganization: String = "") throws -> [String: Any] {
        let context = try XCTUnwrap(JSContext())
        let encodedResponses = String(data: try JSONSerialization.data(withJSONObject: responses), encoding: .utf8)!
        let script = kind == .codex ? WebAccountSession.codexScript : WebAccountSession.claudeScript
        let encodedScript = String(data: try JSONEncoder().encode(script), encoding: .utf8)!
        let encodedSelection = String(data: try JSONEncoder().encode(selectedOrganization), encoding: .utf8)!
        let origin = kind == .codex ? "https://chatgpt.com" : "https://claude.ai"
        context.evaluateScript("""
        const fixtureQueue = \(encodedResponses);
        const location = {origin: '\(origin)'};
        class AbortController { constructor() { this.signal = {}; } abort() {} }
        function setTimeout() { return 1; }
        function clearTimeout() {}
        class TextDecoder { decode(bytes) { return String.fromCharCode(...bytes); } }
        async function fetch(path, options) {
            if (!fixtureQueue.length) throw new Error('Unexpected fixture request');
            const next = fixtureQueue.shift();
            if (next.throws) throw new Error('Fixture network failure');
            const status = next.status || 200;
            const text = next.text || JSON.stringify(next.body);
            const bytes = Uint8Array.from(text, character => character.charCodeAt(0));
            let read = false;
            return {
                status, ok: status >= 200 && status < 300,
                headers: {get(name) { return name === 'Content-Type' ? (next.contentType || 'application/json') : null; }},
                body: {getReader() { return {async read() { if (read) return {done:true}; read = true; return {done:false, value:bytes}; }, async cancel() {}}; }}
            };
        }
        var fixtureOutput;
        var fixtureFailure;
        const execute = new (Object.getPrototypeOf(async function() {}).constructor)('selectedOrganization', \(encodedScript));
        execute(\(encodedSelection)).then(value => { fixtureOutput = JSON.stringify(value); }, error => { fixtureFailure = String(error); });
        """)
        XCTAssertNil(context.exception, context.exception?.toString() ?? "")
        XCTAssertTrue(context.objectForKeyedSubscript("fixtureFailure")?.isUndefined == true)
        let output = try XCTUnwrap(context.objectForKeyedSubscript("fixtureOutput")?.toString())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
}
