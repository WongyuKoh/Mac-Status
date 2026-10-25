import XCTest
import Darwin
@testable import MacStatus

final class TemplateEngineTests: XCTestCase {
    func testMinimalManualTemplateGetsSafeDefaultsAndUniqueIdentity() throws {
        let text = #"{"name":"월 예산","kind":"manual","manualValue":12.5,"unit":"USD"}"#
        let first = try TemplateEngine.decode(text)
        let second = try TemplateEngine.decode(text)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.manualValue, 12.5)
        XCTAssertEqual(first.authPrefix, "Bearer ")
        XCTAssertEqual(first.refreshInterval, 60)
        XCTAssertNil(first.limit)
    }

    func testExportImportPreservesConfigurationWithoutCredentialField() throws {
        var template = MetricTemplate(name: "API 비용", kind: .http, unit: "USD", limit: nil)
        template.endpoint = "https://api.openai.com/v1/organization/costs?start_time={{month_start_unix}}&limit=31"
        template.valuePath = "data.*.results.*.amount.value"
        template.aggregation = "sum"
        let encoded = try TemplateEngine.encode(template)
        XCTAssertEqual(try TemplateEngine.decode(encoded), template)
        XCTAssertFalse(encoded.contains("accessToken"))
    }

    func testCredentialHeadersAndURLCredentialsAreRejected() {
        let cases = [
            #"{"name":"test","kind":"http","endpoint":"https://example.com","valuePath":"value","headers":{"Authorization":"Bearer secret"}}"#,
            #"{"name":"test","kind":"http","endpoint":"https://example.com","valuePath":"value","headers":{"X-API-Key":"secret"}}"#,
            #"{"name":"test","kind":"http","endpoint":"https://example.com?api_key=secret","valuePath":"value"}"#,
            #"{"name":"test","kind":"http","endpoint":"https://user:secret@example.com","valuePath":"value"}"#,
            #"{"name":"test","kind":"manual","token":"secret"}"#,
            #"{"name":"test","kind":"manual","headers":{"X-Custom-Key":"secret"},"authHeader":"X-Custom-Key"}"#
        ]
        for text in cases { XCTAssertThrowsError(try TemplateEngine.decode(text)) }
    }

    func testOnlyLoopbackMayUsePlainHTTP() {
        for host in ["localhost", "127.0.0.1", "[::1]"] {
            let text = "{\"name\":\"local\",\"kind\":\"http\",\"endpoint\":\"http://\(host):4000/usage\",\"valuePath\":\"value\"}"
            XCTAssertNoThrow(try TemplateEngine.decode(text))
        }
        for endpoint in ["http://example.com/usage", "file:///etc/passwd", "https://localhost@evil.example/usage"] {
            let text = "{\"name\":\"test\",\"kind\":\"http\",\"endpoint\":\"\(endpoint)\",\"valuePath\":\"value\"}"
            XCTAssertThrowsError(try TemplateEngine.decode(text))
        }
    }

    func testPublicEndpointMayDisableAuthenticationWithBlankHeader() throws {
        var template = MetricTemplate(name: "public usage", kind: .http)
        template.endpoint = "https://example.com/usage"
        template.valuePath = "value"
        template.authHeader = ""
        XCTAssertNoThrow(try TemplateEngine.validate(template))
        XCTAssertEqual(try TemplateEngine.decode(TemplateEngine.encode(template)), template)
    }

    func testHeaderInjectionAndBadPathsAreRejected() {
        var template = MetricTemplate(name: "test", kind: .http)
        template.endpoint = "https://example.com/usage"
        template.valuePath = "usage.total"
        template.authPrefix = "Bearer \r\nInjected: yes"
        XCTAssertThrowsError(try TemplateEngine.validate(template))
        template.authPrefix = "Bearer "
        template.headers = ["x-test\n": "yes"]
        XCTAssertThrowsError(try TemplateEngine.validate(template))
        template.headers = [:]
        template.authHeader = "Host"
        XCTAssertThrowsError(try TemplateEngine.validate(template))
        template.authHeader = "Authorization"
        template.authPrefix = "Bearer\t"
        XCTAssertThrowsError(try TemplateEngine.validate(template))
        template.authPrefix = "Bearer "
        for path in ["", "usage..value", "data[-1].value", "data. value", "data.$eval"] {
            template.valuePath = path
            XCTAssertThrowsError(try TemplateEngine.validate(template))
        }
    }

    func testNestedArraysAndNumericStringsSumExactly() throws {
        let fixture: [String: Any] = ["data": [
            ["results": [["amount": ["value": "1.25"]], ["amount": ["value": 0.75]]]],
            ["results": [["amount": ["value": 2]]]]
        ]]
        let total = try TemplateEngine.extractNumber(from: fixture, path: "data.*.results.*.amount.value", aggregation: "sum")
        XCTAssertEqual(total, 4, accuracy: 0.0001)
        XCTAssertEqual(try TemplateEngine.extractNumber(from: fixture, path: "data.0.results.1.amount.value", aggregation: "first"), 0.75)
    }

    func testMissingOrNonnumericValuesNeverBecomeZeroOrPartialSum() {
        let cases: [(Any, String)] = [
            (["data": [["value": 5], ["other": 7]]], "data.*.value"),
            (["value": NSNull()], "value"),
            (["value": true], "value"),
            (["value": "unknown"], "value"),
            (["value": "nan"], "value"),
            (["value": "infinity"], "value"),
            (["other": 4], "value")
        ]
        for (fixture, path) in cases {
            XCTAssertThrowsError(try TemplateEngine.extractNumber(from: fixture, path: path, aggregation: "sum"))
        }
        XCTAssertEqual(try TemplateEngine.extractNumber(from: ["value": 0], path: "value", aggregation: "first"), 0)
    }

    func testExplicitEmptyCollectionsHaveZeroSumButMissingCollectionsFail() throws {
        XCTAssertEqual(try TemplateEngine.extractNumber(from: ["data": []], path: "data.*.results.*.amount.value", aggregation: "sum"), 0)
        XCTAssertEqual(try TemplateEngine.extractNumber(from: ["data": [["results": []]]], path: "data.*.results.*.amount.value", aggregation: "sum"), 0)
        XCTAssertThrowsError(try TemplateEngine.extractNumber(from: ["wrong_data": []], path: "data.*.value", aggregation: "sum"))
        XCTAssertThrowsError(try TemplateEngine.extractNumber(from: ["data": NSNull()], path: "data.*.value", aggregation: "sum"))
        XCTAssertThrowsError(try TemplateEngine.extractNumber(from: ["data": []], path: "data.*.value", aggregation: "first"))
    }

    func testFirstDoesNotSilentlyDropAdditionalResults() {
        XCTAssertThrowsError(try TemplateEngine.extractNumber(from: ["data": [2, 3]], path: "data.*", aggregation: "first"))
    }

    func testPaginatedCostDoesNotShowAnIncompleteSum() throws {
        var template = MetricTemplate(name: "cost", kind: .http, unit: "USD", limit: nil)
        template.valuePath = "data.*.value"
        template.aggregation = "sum"
        let fixture = Data(#"{"has_more":true,"data":[{"value":1.2}]}"#.utf8)
        XCTAssertThrowsError(try TemplateEngine.reading(from: fixture, template: template))
        for json in [
            #"{"has_more":true,"data":[]}"#,
            #"{"has_more":"false","data":[]}"#,
            #"{"has_more":false,"next_page":"more","data":[]}"#,
            #"{"next_page":4,"data":[]}"#
        ] {
            XCTAssertThrowsError(try TemplateEngine.reading(from: Data(json.utf8), template: template))
        }
    }

    func testUnitConversionAlsoAppliesToAPILimit() throws {
        var template = MetricTemplate(name: "storage", kind: .http, unit: "GB", limit: nil)
        template.valuePath = "used"
        template.limitPath = "total"
        template.multiplier = 0.001
        let reading = try TemplateEngine.reading(from: Data(#"{"used":2500,"total":10000}"#.utf8), template: template)
        XCTAssertEqual(reading.value, 2.5)
        XCTAssertEqual(reading.limit, 10)
        XCTAssertEqual(reading.fraction, 0.25)
    }

    func testAnthropicDecimalCentAmountsBecomeDollars() throws {
        var template = MetricTemplate(name: "Anthropic API 비용", kind: .http, unit: "USD", limit: nil)
        template.valuePath = "data.*.results.*.amount"
        template.aggregation = "sum"
        template.multiplier = 0.01
        let fixture = Data(#"{"data":[{"results":[{"amount":"123.78912","currency":"USD"},{"amount":"76.21088","currency":"USD"}]}],"has_more":false,"next_page":null}"#.utf8)
        let reading = try TemplateEngine.reading(from: fixture, template: template)
        XCTAssertEqual(try XCTUnwrap(reading.value), 2, accuracy: 0.0000001)
    }

    func testInvalidLimitsAndNonfiniteMultiplierAreRejected() {
        var template = MetricTemplate(name: "test", kind: .manual)
        template.multiplier = .infinity
        XCTAssertThrowsError(try TemplateEngine.validate(template))
        template.multiplier = 1
        template.limit = 0
        XCTAssertThrowsError(try TemplateEngine.validate(template))
        template.limit = nil
        template.manualValue = -.infinity
        XCTAssertThrowsError(try TemplateEngine.validate(template))
    }

    func testDateVariablesUseUTCMonthBoundaries() throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-25T12:30:00Z"))
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        let expanded = TemplateEngine.expandVariables("{{month_start_unix}}|{{now_unix}}|{{month_start_iso}}", now: now)
        XCTAssertEqual(expanded, "\(Int(start.timeIntervalSince1970))|\(Int(now.timeIntervalSince1970))|2026-10-01T00:00:00Z")
    }

    func testManualReadingDistinguishesUnsetFromActualZero() async throws {
        var template = MetricTemplate(name: "manual", kind: .manual)
        let unset = try await TemplateEngine.fetch(template, token: nil)
        XCTAssertEqual(unset.state, .needsSetup)
        XCTAssertNil(unset.value)
        template.manualValue = 0
        let zero = try await TemplateEngine.fetch(template, token: nil)
        XCTAssertEqual(zero.state, .ready)
        XCTAssertEqual(zero.value, 0)
    }

    func testInvalidCredentialsAreRejectedBeforeStorageOrTransport() {
        for value in ["", " token", "token ", "token\n", "token\tpart", "token\0part", String(repeating: "a", count: 16_385)] {
            XCTAssertThrowsError(try TemplateEngine.validateCredential(value))
        }
        XCTAssertNoThrow(try TemplateEngine.validateCredential("test-only-fake-key"))
    }

    func testHTTPTransportSendsGETExpandsDateAndSupportsPublicRequests() async throws {
        let server = try LoopbackHTTPServer { _ in .json(#"{"usage":{"used":42,"limit":100}}"#) }
        defer { server.stop() }
        var template = httpTemplate(server, path: "/usage?start={{month_start_unix}}")
        template.valuePath = "usage.used"
        template.limitPath = "usage.limit"
        template.headers = ["anthropic-version": "2023-06-01"]
        let reading = try await TemplateEngine.fetch(template, token: "test-only-fake-bearer")
        XCTAssertEqual(reading.value, 42)
        XCTAssertEqual(reading.limit, 100)
        let authenticated = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(authenticated.method, "GET")
        XCTAssertEqual(authenticated.headers["authorization"], "Bearer test-only-fake-bearer")
        XCTAssertEqual(authenticated.headers["anthropic-version"], "2023-06-01")
        XCTAssertFalse(authenticated.target.contains("{{"))
        XCTAssertTrue(authenticated.target.contains("start="))

        template.authHeader = ""
        _ = try await TemplateEngine.fetch(template, token: "do-not-send-this-test-token")
        XCTAssertNil(server.requests.last?.headers["authorization"])
        XCTAssertNil(server.requests.last?.headers["x-api-key"])
    }

    func testHTTPTransportSupportsAnthropicKeyAndDecimalCentCost() async throws {
        let server = try LoopbackHTTPServer { _ in
            .json(#"{"data":[{"results":[{"amount":"250.5","currency":"USD"}]}],"has_more":false,"next_page":null}"#)
        }
        defer { server.stop() }
        var template = httpTemplate(server)
        template.unit = "USD"
        template.limit = nil
        template.valuePath = "data.*.results.*.amount"
        template.aggregation = "sum"
        template.multiplier = 0.01
        template.authHeader = "x-api-key"
        template.authPrefix = ""
        let reading = try await TemplateEngine.fetch(template, token: "test-only-fake-admin-key")
        XCTAssertEqual(try XCTUnwrap(reading.value), 2.505, accuracy: 0.000001)
        XCTAssertEqual(server.requests.first?.headers["x-api-key"], "test-only-fake-admin-key")
        XCTAssertNil(server.requests.first?.headers["authorization"])
    }

    func testHTTPAuthenticationFailuresStayTypedWithoutEchoingResponse() async throws {
        let server = try LoopbackHTTPServer { request in
            .init(status: request.target == "/401" ? 401 : 403, body: Data("test-only-fake-key-in-response".utf8))
        }
        defer { server.stop() }
        for status in [401, 403] {
            do {
                _ = try await TemplateEngine.fetch(httpTemplate(server, path: "/\(status)"), token: "test-only-fake-key")
                XCTFail("Expected authentication failure")
            } catch let error as StatusError {
                guard case .authentication = error else { return XCTFail("Authentication status must remain typed") }
                XCTAssertTrue(error.localizedDescription.contains(String(status)))
                XCTAssertFalse(error.localizedDescription.contains("test-only-fake"))
            }
        }
    }

    func testHTTPRedirectPolicyPreservesSameOriginAuthAndBlocksOtherOrigins() async throws {
        let destination = try LoopbackHTTPServer { _ in .json(#"{"value":99}"#) }
        defer { destination.stop() }
        let source = try LoopbackHTTPServer { request in
            if request.target == "/same" { return .init(status: 302, headers: ["Location": "/usage"]) }
            if request.target == "/cross" { return .init(status: 302, headers: ["Location": destination.url + "/usage"]) }
            return .json(#"{"value":7}"#)
        }
        defer { source.stop() }
        let same = try await TemplateEngine.fetch(httpTemplate(source, path: "/same"), token: "test-only-fake-key")
        XCTAssertEqual(same.value, 7)
        XCTAssertEqual(source.requests.first(where: { $0.target == "/usage" })?.headers["authorization"], "Bearer test-only-fake-key")
        var custom = httpTemplate(source, path: "/same")
        custom.authHeader = "x-api-key"
        custom.authPrefix = ""
        _ = try await TemplateEngine.fetch(custom, token: "test-only-custom-key")
        XCTAssertEqual(source.requests.last?.headers["x-api-key"], "test-only-custom-key")
        do {
            _ = try await TemplateEngine.fetch(httpTemplate(source, path: "/cross"), token: "test-only-fake-key")
            XCTFail("Cross-origin redirect must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("리디렉션"))
            XCTAssertFalse(error.localizedDescription.contains("test-only-fake"))
        }
        XCTAssertTrue(destination.requests.isEmpty, "No credential-bearing request may reach the other origin")
    }

    func testHTTPTransportRejectsOversizeStreamingAndInvalidJSON() async throws {
        let server = try LoopbackHTTPServer { request in
            if request.target == "/large" {
                return .init(body: Data(repeating: 97, count: 1_048_577), includeContentLength: false)
            }
            return .init(body: Data("<html>not json</html>".utf8))
        }
        defer { server.stop() }
        do {
            _ = try await TemplateEngine.fetch(httpTemplate(server, path: "/large"), token: nil)
            XCTFail("Oversized streaming body must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("1 MB")) }
        do {
            _ = try await TemplateEngine.fetch(httpTemplate(server, path: "/invalid"), token: nil)
            XCTFail("Non-JSON body must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("JSON")) }
    }

    func testHTTPTransportTimesOutWithoutLeakingURLOrToken() async throws {
        let server = try LoopbackHTTPServer { _ in
            .init(body: Data(#"{"value":1}"#.utf8), delay: 30)
        }
        defer { server.stop() }
        let started = Date()
        do {
            _ = try await TemplateEngine.fetch(httpTemplate(server, path: "/private-test-path"), token: "test-only-fake-key")
            XCTFail("Unresponsive endpoint must time out")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("시간이 초과"))
            XCTAssertFalse(error.localizedDescription.contains("private-test-path"))
            XCTAssertFalse(error.localizedDescription.contains("test-only-fake"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 24)
    }

    private func httpTemplate(_ server: LoopbackHTTPServer, path: String = "/usage") -> MetricTemplate {
        MetricTemplate(name: "Transport fixture", kind: .http, endpoint: server.url + path, valuePath: "value")
    }
}

/// A real HTTP peer bound only to an ephemeral IPv4 loopback port. No accounts or external network.
private final class LoopbackHTTPServer {
    struct Request {
        var method: String
        var target: String
        var headers: [String: String]
    }
    struct Response {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        var includeContentLength = true
        var delay: TimeInterval = 0
        static func json(_ text: String) -> Response { .init(body: Data(text.utf8)) }
    }

    private let listener: Int32
    private let handler: (Request) -> Response
    private let lock = NSLock()
    private var active = true
    private var clients: Set<Int32> = []
    private var recorded: [Request] = []
    let port: UInt16
    var url: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return recorded }

    init(handler: @escaping (Request) -> Response) throws {
        self.handler = handler
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw StatusError.message("Test socket creation failed") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            throw StatusError.message("Test loopback listener failed")
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(descriptor); throw StatusError.message("Test listener port unavailable") }
        listener = descriptor
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.acceptConnections() }
    }

    func stop() {
        lock.lock()
        guard active else { lock.unlock(); return }
        active = false
        let openClients = clients
        lock.unlock()
        shutdown(listener, SHUT_RDWR)
        close(listener)
        openClients.forEach { _ = shutdown($0, SHUT_RDWR) }
    }

    private func acceptConnections() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            lock.lock()
            guard active else { lock.unlock(); close(client); return }
            clients.insert(client)
            lock.unlock()
            DispatchQueue.global(qos: .utility).async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer {
            lock.lock(); clients.remove(client); lock.unlock()
            close(client)
        }
        var noSignal: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < 65_536 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            data.append(contentsOf: buffer.prefix(count))
            if data.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.components(separatedBy: "\r\n")
        let start = lines.first?.split(separator: " ") ?? []
        guard start.count >= 2 else { return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<separator]).lowercased()] = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        }
        let request = Request(method: String(start[0]), target: String(start[1]), headers: headers)
        lock.lock(); recorded.append(request); lock.unlock()
        let response = handler(request)
        if response.delay > 0 { Thread.sleep(forTimeInterval: response.delay) }
        var head = "HTTP/1.1 \(response.status) Fixture\r\nConnection: close\r\nContent-Type: application/json\r\n"
        if response.includeContentLength { head += "Content-Length: \(response.body.count)\r\n" }
        response.headers.forEach { head += "\($0): \($1)\r\n" }
        var output = Data((head + "\r\n").utf8)
        output.append(response.body)
        output.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = Darwin.send(client, base.advanced(by: sent), raw.count - sent, 0)
                guard count > 0 else { return }
                sent += count
            }
        }
    }
}
