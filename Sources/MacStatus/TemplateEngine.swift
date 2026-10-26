import Foundation
import CoreFoundation

/// A declarative, read-only adapter. Templates contain configuration, never code or secrets.
enum TemplateEngine {
    private static let maximumResponseBytes = 1_048_576
    private static let transportHeaderNames: Set<String> = ["host", "content-length", "transfer-encoding", "connection", "upgrade"]
    private static let secretNames: Set<String> = [
        "authorization", "proxy-authorization", "x-api-key", "api-key", "apikey",
        "api_key", "api-token", "api_token", "apitoken", "access_token", "accesstoken", "refresh_token", "refreshtoken",
        "x-auth-token", "x-access-token", "token", "cookie", "set-cookie", "password", "secret", "credential", "credentials"
    ]

    static func decode(_ text: String) throws -> MetricTemplate {
        guard let data = text.data(using: .utf8), data.count <= 65_536 else {
            throw StatusError.message("내용이 너무 길어요. JSON을 64 KB 이하로 줄여 주세요.")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw StatusError.message("입력란이 비어 있어요. 예시를 넣거나 JSON을 붙여 넣어 주세요.")
        }
        guard !trimmed.hasPrefix("```") else {
            throw StatusError.message("앞뒤의 ``` 표시를 지우고 { } 안의 내용만 붙여 넣어 주세요.")
        }
        let object: [String: Any]
        do {
            guard let dictionary = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? [String: Any] else {
                throw StatusError.message("템플릿 하나만 넣어 주세요. [ ] 대신 { }로 시작해야 합니다.")
            }
            object = dictionary
        } catch let error as StatusError { throw error }
        catch { throw StatusError.message("쉼표와 큰따옴표를 확인해 주세요. 예시와 같은 JSON 형식이 필요합니다.") }

        guard !object.keys.contains(where: { secretNames.contains($0.lowercased()) }) else {
            throw StatusError.message("JSON에서 키와 토큰을 빼 주세요. 다음 편집 화면의 보안 키 칸에 입력할 수 있어요.")
        }
        let document: TemplateDocument
        do { document = try JSONDecoder().decode(TemplateDocument.self, from: data) }
        catch let error as DecodingError { throw decodingMessage(error) }
        catch { throw StatusError.message("항목 형식을 확인해 주세요. 예시와 비교해 보세요.") }
        let template = document.template
        try validate(template)
        return template
    }

    /// Only known schema field names may be shown. Decoder paths and descriptions
    /// can contain arbitrary input, including a credential used as a header name.
    private static func decodingMessage(_ error: DecodingError) -> StatusError {
        let fields: Set<String> = ["id", "name", "subtitle", "symbol", "tint", "kind", "unit", "limit", "manualValue", "endpoint", "valuePath", "limitPath", "aggregation", "multiplier", "headers", "authHeader", "authPrefix", "refreshInterval", "link", "isEnabled", "valueMode", "valueExpression", "limitExpression"]
        let labels = [
            "name": "name(이름)", "kind": "kind(만들기 방식)",
            "limit": "limit(한도)", "manualValue": "manualValue(현재 값)",
            "multiplier": "multiplier(배율)", "refreshInterval": "refreshInterval(갱신 간격)",
            "valueExpression": "valueExpression(값 계산식)", "limitExpression": "limitExpression(한도 계산식)"
        ]
        let context: DecodingError.Context
        switch error {
        case .keyNotFound(let key, _):
            let field = fields.contains(key.stringValue) ? (labels[key.stringValue] ?? key.stringValue) : "필수 항목"
            return .message("\(field) 항목이 빠졌어요. 예시를 보고 추가해 주세요.")
        case .typeMismatch(_, let value), .valueNotFound(_, let value), .dataCorrupted(let value):
            context = value
        @unknown default:
            return .message("항목 형식을 확인해 주세요. 예시와 비교해 보세요.")
        }
        guard let root = context.codingPath.first?.stringValue, fields.contains(root) else {
            return .message("항목 형식을 확인해 주세요. 예시와 비교해 보세요.")
        }
        switch root {
        case "kind":
            return .message("kind(만들기 방식)을 확인해 주세요. 숫자 수동 입력은 \"manual\", API 자동 조회는 \"http\"입니다.")
        case "valueMode":
            return .message("valueMode(값 불러오기 방식)는 \"number\" 또는 \"json\"으로 입력해 주세요.")
        case "limit", "manualValue", "multiplier", "refreshInterval":
            return .message("\(labels[root] ?? root)에 숫자를 넣어 주세요. 숫자에는 큰따옴표를 쓰지 않아요.")
        case "headers":
            return .message("headers는 { }로 감싸고, 안의 이름과 값은 큰따옴표로 감싸 주세요.")
        case "isEnabled":
            return .message("isEnabled에는 true 또는 false를 넣어 주세요.")
        case "id":
            return .message("id를 지우고 다시 시도해 주세요. 새 ID는 앱이 만듭니다.")
        default:
            return .message("\(labels[root] ?? root)의 글자를 큰따옴표로 감싸 주세요. 예: \"나의 통계\".")
        }
    }

    static func encode(_ template: MetricTemplate) throws -> String {
        try validate(template)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let text = String(data: try encoder.encode(template), encoding: .utf8) else {
            throw StatusError.message("템플릿을 내보낼 수 없습니다.")
        }
        return text
    }

    static func validate(_ template: MetricTemplate) throws {
        if let first = validationIssues(for: template).first {
            throw StatusError.message(first.message)
        }
    }

    /// The editor can mark all affected inputs while import, export, and fetch
    /// retain their existing first-error validation behavior and messages.
    static func validationIssues(for template: MetricTemplate) -> [TemplateValidationIssue] {
        var issues: [TemplateValidationIssue] = []
        func append(_ field: TemplateField, _ message: String) {
            guard !issues.contains(where: { $0.field == field }) else { return }
            issues.append(.init(field: field, message: message))
        }

        if template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || template.name.count > 60 {
            append(.name, "name(이름)을 1~60자로 입력해 주세요.")
        }
        if template.subtitle.count > 180 {
            append(.subtitle, "subtitle(설명)을 180자 이하로 줄여 주세요.")
        }
        if template.unit.count > 20 {
            append(.unit, "unit(단위)을 20자 이하로 줄여 주세요.")
        }
        if template.symbol.count > 80 {
            append(.symbol, "symbol(아이콘 이름)을 80자 이하로 줄여 주세요.")
        }
        if !template.refreshInterval.isFinite || !(3...86_400).contains(template.refreshInterval) {
            append(.refreshInterval, "refreshInterval(갱신 간격)에 3~86400 사이의 숫자를 넣어 주세요. 단위는 초예요.")
        }
        if !template.multiplier.isFinite || template.multiplier == 0 {
            append(.multiplier, "multiplier(배율)에 0이 아닌 숫자를 넣어 주세요.")
        }
        if let limit = template.limit, !limit.isFinite || limit <= 0 {
            append(.limit, "limit(한도)에 0보다 큰 숫자를 넣어 주세요. 한도가 없으면 null로 쓰세요.")
        }
        if let value = template.manualValue, !value.isFinite || value < 0 {
            append(.manualValue, "manualValue(현재 값)에 0 이상의 숫자를 넣어 주세요.")
        }
        if !["first", "sum"].contains(template.aggregation) {
            append(.aggregation, "aggregation에는 \"first\" 또는 \"sum\"을 넣어 주세요.")
        }
        let authenticationMessage = "authHeader와 authPrefix를 확인해 주세요. 줄바꿈은 넣을 수 없어요."
        if (!template.authHeader.isEmpty && !validHeaderName(template.authHeader)) ||
            transportHeaderNames.contains(template.authHeader.lowercased()) {
            append(.authHeader, authenticationMessage)
        }
        if template.authPrefix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) || template.authPrefix.count > 100 {
            append(.authPrefix, authenticationMessage)
        }
        if template.headers.count > 20 {
            append(.headers, "headers의 항목을 20개 이하로 줄여 주세요.")
        }
        for (key, value) in template.headers {
            if !validHeaderName(key) || value.count > 1_000 || value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
                append(.headers, "headers의 이름과 값을 확인해 주세요. 줄바꿈은 넣을 수 없어요.")
            }
            if secretNames.contains(key.lowercased()) || key.lowercased() == template.authHeader.lowercased() {
                append(.headers, "headers에서 키와 토큰을 빼 주세요. 편집 화면의 보안 키 칸을 사용하세요.")
            }
            if transportHeaderNames.contains(key.lowercased()) {
                append(.headers, "headers에서 전송 제어 항목을 빼 주세요. 앱이 자동으로 설정해요.")
            }
        }
        if !template.link.isEmpty {
            do { _ = try checkedURL(template.link, allowVariables: false) }
            catch { append(.link, "link(바로가기): \(error.localizedDescription)") }
        }
        if template.kind == .http {
            do { _ = try checkedURL(template.endpoint, allowVariables: true) }
            catch { append(.endpoint, "endpoint(조회 주소): \(error.localizedDescription)") }
            do {
                let components = try pathComponents(template.valuePath)
                if template.effectiveHTTPValueMode == .json, components.contains("*") {
                    throw StatusError.message("JSON 값은 A.B.C 또는 data.0.value처럼 한 위치를 지정해 주세요.")
                }
            } catch {
                append(.valuePath, template.effectiveHTTPValueMode == .json
                    ? "valuePath(값 위치): A.B.C 또는 data.0.value처럼 한 위치를 점(.)으로 구분해 주세요."
                    : "valuePath(숫자 위치): usage.total처럼 점(.)으로 구분해 주세요.")
            }
            if template.effectiveHTTPValueMode == .number, !template.limitPath.isEmpty {
                do { _ = try pathComponents(template.limitPath) }
                catch { append(.limitPath, "limitPath(한도 위치): usage.limit처럼 점(.)으로 구분해 주세요.") }
            }
            if template.effectiveHTTPValueMode == .number {
                do { try MetricCalculation.validate(template.valueExpression ?? "") }
                catch { append(.valueExpression, "valueExpression(값 계산식): value와 숫자, 사칙연산으로 입력해 주세요.") }
                if !template.limitPath.isEmpty {
                    do { try MetricCalculation.validate(template.limitExpression ?? "") }
                    catch { append(.limitExpression, "limitExpression(한도 계산식): value와 숫자, 사칙연산으로 입력해 주세요.") }
                }
            }
        }
        return issues
    }

    static func generationPrompt(request: String) -> String {
        """
        Mac Status macOS 상단바 앱용 통계 항목 템플릿을 만들어 주세요.
        원하는 항목: \(request.isEmpty ? "서비스의 사용량과 한도" : request)

        실제 공식 API 문서를 확인하고, 읽기 전용 GET으로 숫자를 읽을 수 있을 때만 아래 형식의 JSON 객체 하나를 출력하세요. API가 없으면 kind를 manual로 만들고 subtitle에 그 이유를 설명하세요. 엔드포인트, 경로, 수치 또는 구독 한도를 추측하지 마세요. 구독 사용량과 API 청구 금액을 구분하세요.

        형식 예시:
        {
          "name": "서비스 이름",
          "subtitle": "수치의 기간과 의미",
          "kind": "http",
          "symbol": "chart.bar.fill",
          "tint": "mint",
          "unit": "USD",
          "limit": null,
          "endpoint": "https://example.com/api/usage",
          "valuePath": "usage.total",
          "limitPath": "",
          "valueExpression": "",
          "limitExpression": "",
          "aggregation": "first",
          "multiplier": 1,
          "headers": {},
          "authHeader": "Authorization",
          "authPrefix": "Bearer ",
          "refreshInterval": 300,
          "link": "https://example.com/dashboard"
        }

        규칙:
        - kind는 http 또는 manual. manual은 manualValue에 사용자가 입력할 숫자를 넣거나 null로 둡니다.
        - endpoint는 HTTPS만 사용하며, 로컬 도구는 localhost/127.0.0.1/::1의 HTTP도 허용합니다.
        - valuePath와 limitPath는 점으로 구분합니다. 배열 인덱스는 data.0.value, 전체 배열은 data.*.value. 여러 숫자의 합은 aggregation: sum. 단일 숫자는 first.
        - multiplier는 추출한 값에 곱합니다. 한도 limit은 표시 단위 기준이며 null이면 한도 없이 표시합니다.
        - valueExpression과 limitExpression은 선택 계산식입니다. 각 경로에서 읽은 숫자를 value로 두고 +, -, *, /, 괄호만 사용합니다. 예: "value * 2". 단일 값 또는 합계 추출 → 계산식 → multiplier 순서로 계산합니다. limitExpression은 limitPath가 있을 때만 사용합니다. 빈 계산식은 원래 값을 유지하며 0으로 나누거나 계산 결과가 유한하지 않으면 null로 표시합니다.
        - URL의 {{month_start_unix}}, {{now_unix}}, {{month_start_iso}}는 실행 시 UTC 기준으로 대체됩니다.
        - headers에는 anthropic-version 같은 비밀이 아닌 헤더만 넣으세요. 키, 토큰, Cookie는 JSON/URL 어디에도 포함하지 마세요. 사용자가 앱의 보안 키 필드에 입력하며 macOS 키체인에 저장됩니다.
        - 인증 헤더는 authHeader, 접두어는 authPrefix. x-api-key 방식이면 authHeader: x-api-key, authPrefix: 빈 문자열.
        - tint는 mint, blue, purple, orange 중 하나. symbol은 SF Symbols 이름. refreshInterval은 초 단위 3~86400.
        - 페이지가 나뉘는 API에서는 요청 기간/limit을 조정해 전체 결과가 한 응답에 들어오게 하세요. 합계 응답에 has_more: true 또는 next_page가 있으면 앱은 불완전한 합계를 표시하지 않습니다.
        - sum에서 경로가 존재하는 빈 배열의 합계는 0입니다. 누락된 경로나 null을 0으로 바꾸지는 않습니다.
        - API 주소와 JSON 경로의 값을 그대로 표시하려면 valueMode: "json"을 사용할 수 있습니다. 숫자·문자열·참/거짓·객체·배열을 읽으며, 한도·합계·배율은 적용하지 않습니다. 경로는 A.B.C 또는 data.0.value처럼 한 위치를 지정합니다. 값이 없거나 조회에 실패하면 null로 표시합니다. 인증이 필요 없으면 authHeader와 authPrefix를 빈 문자열로 둡니다.
        - JSON 이외의 코드, 셸 명령, JavaScript는 지원하지 않습니다.
        """
    }

    static func fetch(_ template: MetricTemplate, token: String?) async throws -> MetricReading {
        try validate(template)
        if template.kind == .manual {
            guard let value = template.manualValue else { return .setup("현재 값을 입력해 주세요.") }
            return MetricReading(value: value, limit: template.limit, subtitle: template.subtitle)
        }
        guard template.kind == .http else {
            throw StatusError.message("이 항목은 전용 데이터 소스로 조회해야 합니다.")
        }
        do { return try await fetchHTTP(template, token: token) }
        catch is CancellationError { throw CancellationError() }
        catch let error as StatusError {
            guard template.effectiveHTTPValueMode == .json else { throw error }
            return nullJSONReading(error.localizedDescription, state: .failed)
        }
        catch {
            guard template.effectiveHTTPValueMode == .json else { throw error }
            return nullJSONReading("값을 불러오지 못했습니다. API 주소와 연결 상태를 확인하세요.", state: .failed)
        }
    }

    private static func fetchHTTP(_ template: MetricTemplate, token: String?) async throws -> MetricReading {
        let url = try checkedURL(expandVariables(template.endpoint), allowVariables: false)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacStatus/1.0", forHTTPHeaderField: "User-Agent")
        template.headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        if !template.authHeader.isEmpty, let token, !token.isEmpty {
            try validateCredential(token)
            request.setValue(template.authPrefix + token, forHTTPHeaderField: template.authHeader)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = TemplateRedirectPolicy()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw StatusError.message("올바른 HTTP 응답을 받지 못했습니다.")
            }
            guard (200...299).contains(response.statusCode) else {
                switch response.statusCode {
                case 300...399: throw StatusError.message("다른 서버로의 리디렉션은 허용되지 않습니다. 최종 API 주소를 입력하세요.")
                case 401, 403: throw StatusError.authentication("API 인증에 실패했습니다. 키와 조회 권한을 확인하세요. (\(response.statusCode))")
                case 429: throw StatusError.message("API 요청 한도에 도달했습니다. 새로고침 주기를 늘려 주세요. (429)")
                default: throw StatusError.message("API가 HTTP \(response.statusCode) 상태를 반환했습니다.")
                }
            }
            guard response.expectedContentLength <= maximumResponseBytes else {
                throw StatusError.message("API 응답이 1 MB를 초과합니다. 조회 범위를 줄여 주세요.")
            }
            var received = Data()
            for try await byte in bytes {
                guard received.count < maximumResponseBytes else {
                    throw StatusError.message("API 응답이 1 MB를 초과합니다. 조회 범위를 줄여 주세요.")
                }
                received.append(byte)
            }
            data = received
        } catch let error as StatusError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            // URLSession error descriptions can contain URLs, including query secrets.
            let code = (error as NSError).code
            if code == NSURLErrorTimedOut { throw StatusError.message("API 응답 시간이 초과되었습니다.") }
            if code == NSURLErrorCancelled { throw CancellationError() }
            throw StatusError.message("API에 연결할 수 없습니다. 네트워크와 주소를 확인하세요.")
        }
        return try reading(from: data, template: template)
    }

    /// Kept separate from transport to verify adapters using safe, repeatable fixtures.
    static func reading(from data: Data, template: MetricTemplate) throws -> MetricReading {
        if template.effectiveHTTPValueMode == .json {
            return jsonReading(from: data, template: template)
        }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
        catch { throw StatusError.message("API 응답이 JSON 형식이 아닙니다.") }
        if template.aggregation == "sum", let root = json as? [String: Any] {
            if let hasMore = root["has_more"] {
                guard let boolean = hasMore as? NSNumber, CFGetTypeID(boolean) == CFBooleanGetTypeID() else {
                    throw StatusError.message("API의 has_more 필드가 올바르지 않아 전체 합계인지 확인할 수 없습니다.")
                }
                if boolean.boolValue { throw incompletePageError() }
            }
            if let nextPage = root["next_page"], !(nextPage is NSNull) {
                guard let cursor = nextPage as? String else {
                    throw StatusError.message("API의 next_page 필드가 올바르지 않아 전체 합계인지 확인할 수 없습니다.")
                }
                if !cursor.isEmpty { throw incompletePageError() }
            }
        }
        let rawValue = try extractNumber(from: json, path: template.valuePath, aggregation: template.aggregation)
        do {
            let value = try calculatedNumber(rawValue, expression: template.valueExpression, template: template)
            let limit: Double?
            if template.limitPath.isEmpty { limit = template.limit }
            else {
                let rawLimit = try extractNumber(from: json, path: template.limitPath, aggregation: "first")
                let extracted = try calculatedNumber(rawLimit, expression: template.limitExpression, template: template)
                guard extracted > 0 else {
                    if !(template.limitExpression ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return nullCalculationReading("한도 계산 결과는 0보다 커야 합니다.")
                    }
                    throw StatusError.message("API 한도 값이 올바르지 않습니다.")
                }
                limit = extracted
            }
            return MetricReading(value: value, limit: limit, subtitle: template.subtitle.isEmpty ? "HTTP JSON · 실제 조회 값" : template.subtitle)
        } catch let failure as MetricCalculation.Failure {
            switch failure {
            case .divisionByZero: return nullCalculationReading("0으로 나눌 수 없어 계산 결과가 null입니다.")
            case .nonFinite: return nullCalculationReading("계산 결과를 유한한 숫자로 표시할 수 없습니다.")
            case .invalidExpression, .tooComplex: return nullCalculationReading("계산식을 확인해 주세요.")
            }
        }
    }

    private static func calculatedNumber(_ value: Double, expression: String?, template: MetricTemplate) throws -> Double {
        let calculated = try MetricCalculation.evaluate(expression ?? "", value: value)
        let scaled = calculated * template.multiplier
        guard scaled.isFinite else {
            if template.hasNumericExpressions { throw MetricCalculation.Failure.nonFinite }
            throw StatusError.message("계산 결과가 유한한 숫자가 아닙니다.")
        }
        return scaled == 0 ? 0 : scaled
    }

    private static func nullCalculationReading(_ message: String) -> MetricReading {
        .init(text: "null", subtitle: message, state: .unavailable, updatedAt: nil)
    }

    private static func jsonReading(from data: Data, template: MetricTemplate) -> MetricReading {
        guard data.count <= maximumResponseBytes else {
            return nullJSONReading("API 응답이 1 MB를 초과합니다. 조회 범위를 줄여 주세요.", state: .failed)
        }
        let json: Any
        do { json = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) }
        catch { return nullJSONReading("API 응답이 JSON 형식이 아닙니다.", state: .failed) }
        let value: Any?
        do { value = try extractJSONValue(from: json, path: template.valuePath) }
        catch { return nullJSONReading("JSON 경로를 확인하세요. A.B.C처럼 한 위치를 지정해 주세요.") }
        guard let value else { return nullJSONReading("지정한 JSON 경로에 값이 없습니다.") }
        guard !(value is NSNull) else { return nullJSONReading("API가 null을 반환했습니다.") }
        let text: String
        if let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = string
        } else {
            do {
                let encoded = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes])
                guard let decoded = String(data: encoded, encoding: .utf8) else {
                    return nullJSONReading("JSON 값을 표시할 수 없습니다.")
                }
                text = decoded
            } catch { return nullJSONReading("JSON 값을 표시할 수 없습니다.") }
        }
        guard text.count <= 4_096 else {
            return nullJSONReading("선택한 값이 너무 큽니다. 더 안쪽의 JSON 경로를 지정해 주세요.")
        }
        return MetricReading(text: text, subtitle: template.subtitle.isEmpty ? "JSON 경로에서 가져온 값" : template.subtitle)
    }

    private static func nullJSONReading(_ message: String, state: MetricState = .unavailable) -> MetricReading {
        MetricReading(text: "null", subtitle: message, state: state, updatedAt: nil)
    }

    /// Reads a single exact location. Missing containers and out-of-range indexes
    /// remain absent; an explicit JSON null remains NSNull until presentation.
    static func extractJSONValue(from json: Any, path: String) throws -> Any? {
        let components = try pathComponents(path)
        guard !components.contains("*") else {
            throw StatusError.message("JSON 값은 A.B.C 또는 data.0.value처럼 한 위치를 지정해 주세요.")
        }
        var current = json
        for component in components {
            if let object = current as? [String: Any], let next = object[component] { current = next }
            else if let array = current as? [Any], let index = Int(component), array.indices.contains(index) { current = array[index] }
            else { return nil }
        }
        return current
    }

    static func extractNumber(from json: Any, path: String, aggregation: String) throws -> Double {
        let components = try pathComponents(path)
        var nodes = [json]
        for component in components {
            var next: [Any] = []
            for node in nodes {
                if component == "*", let array = node as? [Any] { next.append(contentsOf: array) }
                else if let dictionary = node as? [String: Any], let value = dictionary[component] { next.append(value) }
                else if let array = node as? [Any], let index = Int(component), array.indices.contains(index) { next.append(array[index]) }
                else { throw StatusError.message("지정한 JSON 경로를 찾을 수 없습니다. valuePath/limitPath를 확인하세요.") }
            }
            if next.isEmpty {
                // An explicit empty collection has a valid sum of zero. Missing fields,
                // null and a wrong container type still fail in the traversal above.
                if aggregation == "sum", component == "*" { return 0 }
                throw StatusError.message("API에 표시할 수치가 아직 없습니다.")
            }
            guard next.count <= 100_000 else { throw StatusError.message("JSON 경로의 결과가 너무 많습니다.") }
            nodes = next
        }
        let values = try nodes.map { node -> Double in
            if let number = node as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                let value = number.doubleValue
                guard value.isFinite else { throw StatusError.message("JSON 경로의 값이 유한한 숫자가 아닙니다.") }
                return value
            }
            if let text = node as? String,
               let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite {
                return value
            }
            throw StatusError.message("JSON 경로의 값이 숫자가 아닙니다. 경로와 API 응답을 확인하세요.")
        }
        guard !values.isEmpty else { throw StatusError.message("API에 표시할 수치가 아직 없습니다.") }
        if aggregation == "sum" {
            let sum = values.reduce(0, +)
            guard sum.isFinite else { throw StatusError.message("합계가 유한한 숫자가 아닙니다.") }
            return sum
        }
        guard aggregation == "first", values.count == 1 else {
            throw StatusError.message("경로가 여러 숫자를 반환합니다. 합계는 aggregation을 sum으로 설정하세요.")
        }
        return values[0]
    }

    static func expandVariables(_ endpoint: String, now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return endpoint
            .replacingOccurrences(of: "{{month_start_unix}}", with: String(Int(monthStart.timeIntervalSince1970)))
            .replacingOccurrences(of: "{{now_unix}}", with: String(Int(now.timeIntervalSince1970)))
            .replacingOccurrences(of: "{{month_start_iso}}", with: formatter.string(from: monthStart))
    }

    static func validateCredential(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16_384,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw StatusError.message("보안 키 형식을 확인하세요. 앞뒤 공백과 줄바꿈 없이 키만 입력하세요.")
        }
    }

    private static func incompletePageError() -> StatusError {
        .message("API 결과가 여러 페이지입니다. 기간 또는 limit을 조정해야 정확한 합계를 표시할 수 있습니다.")
    }

    private static func pathComponents(_ path: String) throws -> [String] {
        guard !path.isEmpty, path.count <= 300 else {
            throw StatusError.message("숫자를 읽을 JSON 경로를 입력하세요.")
        }
        let components = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard components.count <= 32,
              components.allSatisfy({ !$0.isEmpty && ($0 == "*" || $0.unicodeScalars.allSatisfy(allowed.contains)) }) else {
            throw StatusError.message("JSON 경로는 usage.total, data.0.value, data.*.value 같은 점 표기법을 사용하세요.")
        }
        return components
    }

    private static func validHeaderName(_ name: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
        return !name.isEmpty && name.count <= 100 && name.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func checkedURL(_ text: String, allowVariables: Bool) throws -> URL {
        let expanded = allowVariables ? expandVariables(text) : text
        guard !expanded.contains("{{"), !expanded.contains("}}"),
              let components = URLComponents(string: expanded),
              let url = components.url, let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil, components.fragment == nil else {
            throw StatusError.message("올바른 API 주소를 입력하세요. 인증 정보는 URL에 넣을 수 없습니다.")
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard components.scheme?.lowercased() == "https" || (components.scheme?.lowercased() == "http" && loopback) else {
            throw StatusError.message("HTTPS 주소가 필요합니다. HTTP는 로컬 루프백 서버만 허용됩니다.")
        }
        if let query = components.queryItems,
           query.contains(where: { secretNames.contains($0.name.lowercased()) || ["key", "signature", "api_token", "bearer"].contains($0.name.lowercased()) }) {
            throw StatusError.message("키와 토큰은 URL에 넣지 말고 연결 설정의 보안 키 필드에 입력하세요.")
        }
        return url
    }
}

private struct TemplateDocument: Decodable {
    var id: UUID?
    var name: String
    var subtitle: String?
    var symbol: String?
    var tint: String?
    var kind: MetricKind
    var unit: String?
    var limit: Double?
    var manualValue: Double?
    var endpoint: String?
    var valuePath: String?
    var limitPath: String?
    var aggregation: String?
    var multiplier: Double?
    var headers: [String: String]?
    var authHeader: String?
    var authPrefix: String?
    var refreshInterval: Double?
    var link: String?
    var isEnabled: Bool?
    var valueMode: HTTPValueMode?
    var valueExpression: String?
    var limitExpression: String?

    var template: MetricTemplate {
        MetricTemplate(
            id: id ?? UUID(), name: name, subtitle: subtitle ?? "", symbol: symbol ?? "chart.bar.fill",
            tint: tint ?? "mint", kind: kind, unit: unit ?? "%", limit: limit, manualValue: manualValue,
            endpoint: endpoint ?? "", valuePath: valuePath ?? "", limitPath: limitPath ?? "",
            aggregation: aggregation ?? "first", multiplier: multiplier ?? 1, headers: headers ?? [:],
            authHeader: authHeader ?? (valueMode == .json ? "" : "Authorization"),
            authPrefix: authPrefix ?? (valueMode == .json ? "" : "Bearer "),
            refreshInterval: refreshInterval ?? 60, link: link ?? "", isEnabled: isEnabled ?? true,
            valueMode: valueMode, valueExpression: valueExpression, limitExpression: limitExpression
        )
    }
}

private final class TemplateRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let originalRequest = task.originalRequest,
              let original = originalRequest.url, let next = request.url,
              original.scheme?.lowercased() == next.scheme?.lowercased(),
              original.host?.lowercased() == next.host?.lowercased(),
              Self.effectivePort(original) == Self.effectivePort(next),
              next.user == nil, next.password == nil else {
            completionHandler(nil)
            return
        }
        // URLSession can remove Authorization even for a same-origin redirect.
        // Restore only the user's original headers after the origin check succeeds.
        var redirected = request
        originalRequest.allHTTPHeaderFields?.forEach { redirected.setValue($1, forHTTPHeaderField: $0) }
        redirected.httpMethod = "GET"
        completionHandler(redirected)
    }

    private static func effectivePort(_ url: URL) -> Int {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }
}
