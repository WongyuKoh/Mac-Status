import Foundation
import CoreFoundation

/// Reads WakaTime summaries only. Credentials never enter a URL or diagnostics.
enum WakaTimeProvider {
    static let dashboardURL = URL(string: "https://wakatime.com/dashboard")!

    static let maximumResponseBytes = 1_048_576

    /// Compatibility with existing plugin keys; new integrations should use a
    /// read_summaries OAuth access token, as recommended by WakaTime.
    static func fetch(apiKey: String) async -> MetricReading {
        let today = Date()
        do {
            let credential = try checkedCredential(apiKey)
            let request = credential.hasPrefix("waka_tok_")
                ? try request(accessToken: credential, today: today)
                : try request(apiKey: credential, today: today)
            return try await fetch(request: request, today: today)
        }
        catch StatusError.authentication(let message) { return .setup(message) }
        catch { return .error(error.localizedDescription) }
    }

    static func fetch(accessToken: String) async -> MetricReading {
        let today = Date()
        do { return try await fetch(request: request(accessToken: accessToken, today: today), today: today) }
        catch StatusError.authentication(let message) { return .setup(message) }
        catch { return .error(error.localizedDescription) }
    }

    static func request(apiKey: String, today: Date = Date(), calendar: Calendar = .current) throws -> URLRequest {
        try makeRequest(authorization: "Basic " + Data(try checkedCredential(apiKey).utf8).base64EncodedString(), today: today, calendar: calendar)
    }

    static func request(accessToken: String, today: Date = Date(), calendar: Calendar = .current) throws -> URLRequest {
        try makeRequest(authorization: "Bearer " + checkedCredential(accessToken), today: today, calendar: calendar)
    }

    private static func makeRequest(authorization: String, today: Date, calendar: Calendar) throws -> URLRequest {
        let calendar = gregorian(calendar)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today) else {
            throw StatusError.message("WakaTime 조회 날짜를 계산할 수 없습니다.")
        }
        var components = URLComponents(string: "https://api.wakatime.com/api/v1/users/current/summaries")!
        components.queryItems = [
            URLQueryItem(name: "start", value: dayString(start, calendar: calendar)),
            URLQueryItem(name: "end", value: dayString(today, calendar: calendar)),
            URLQueryItem(name: "timezone", value: calendar.timeZone.identifier)
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("MacStatus/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private static func fetch(request: URLRequest, today: Date) async throws -> MetricReading {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: WakaTimeRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else {
                throw StatusError.message("WakaTime에서 올바른 응답을 받지 못했습니다.")
            }
            try validateResponse(response)
            var received = Data()
            for try await byte in bytes {
                guard received.count < maximumResponseBytes else {
                    throw StatusError.message("WakaTime 응답이 1 MB를 초과합니다.")
                }
                received.append(byte)
            }
            data = received
        } catch let error as StatusError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch {
            let code = (error as NSError).code
            if code == NSURLErrorTimedOut { throw StatusError.message("WakaTime 응답 시간이 초과되었습니다.") }
            if code == NSURLErrorCancelled { throw CancellationError() }
            throw StatusError.message("WakaTime에 연결할 수 없습니다. 네트워크를 확인하세요.")
        }
        return try parse(data: data, today: today)
    }

    static func validateResponse(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200: break
        case 202: throw StatusError.message("WakaTime에서 통계를 집계 중입니다. 잠시 후 다시 확인합니다.")
        case 401, 403:
            throw StatusError.authentication("WakaTime 조회 인증에 실패했습니다. 키의 호환성 또는 read_summaries 권한의 OAuth 토큰을 확인하세요. (\(response.statusCode))")
        case 300...399: throw StatusError.message("WakaTime이 다른 서버로 이동을 요청하여 조회를 중단했습니다.")
        case 404: throw StatusError.message("WakaTime 사용량 조회 경로를 찾을 수 없습니다. (404)")
        case 429: throw StatusError.message("WakaTime 요청 한도에 도달했습니다. 잠시 후 다시 확인합니다. (429)")
        default: throw StatusError.message("WakaTime이 HTTP \(response.statusCode) 상태를 반환했습니다.")
        }
        guard response.expectedContentLength <= maximumResponseBytes else {
            throw StatusError.message("WakaTime 응답이 1 MB를 초과합니다.")
        }
    }

    static func parse(data: Data, today: Date = Date(), calendar: Calendar = .current) throws -> MetricReading {
        guard data.count <= maximumResponseBytes else { throw StatusError.message("WakaTime 응답이 1 MB를 초과합니다.") }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw StatusError.message("WakaTime 응답이 JSON 형식이 아닙니다.") }
        guard let root = object as? [String: Any], let days = root["data"] as? [[String: Any]] else {
            throw StatusError.message("WakaTime 일별 통계가 응답에 없습니다.")
        }
        let calendar = gregorian(calendar)
        let todayKey = dayString(today, calendar: calendar)
        let expectedDays = (0..<7).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: today).map { dayString($0, calendar: calendar) }
        }
        var byDate: [String: [String: Any]] = [:]
        for day in days {
            guard let range = day["range"] as? [String: Any],
                  let key = dateKey(range, calendar: calendar), expectedDays.contains(key) else { continue }
            guard byDate[key] == nil else { throw StatusError.message("WakaTime 응답에 중복 날짜가 있어 합계를 확인할 수 없습니다.") }
            byDate[key] = day
        }
        guard let current = byDate[todayKey] else {
            return .init(subtitle: "오늘 통계가 아직 제공되지 않았습니다. 누락된 날짜를 0으로 계산하지 않습니다.", state: .unavailable, details: [.init(label: "조회 날짜", value: todayKey)])
        }
        guard let total = (current["grand_total"] as? [String: Any]).flatMap({ seconds($0["total_seconds"]) }) else {
            throw StatusError.message("WakaTime의 오늘 총 시간이 올바르지 않습니다.")
        }
        var details: [MetricDetail] = [.init(label: "오늘 코딩 시간", value: duration(total), note: "\(todayKey) · \(calendar.timeZone.identifier)")]
        let week = expectedDays.compactMap { key in
            (byDate[key]?["grand_total"] as? [String: Any]).flatMap { seconds($0["total_seconds"]) }
        }
        if week.count == 7 {
            details.append(.init(label: "최근 7일", value: duration(week.reduce(0, +)), note: "오늘을 포함한 7일의 합계입니다."))
        } else {
            details.append(.init(label: "최근 7일", value: "정보 미제공", note: "7일 전체가 제공되지 않아 부분 합계를 전체 합계로 표시하지 않습니다."))
        }
        appendBreakdown(current["projects"], title: "프로젝트", total: total, to: &details)
        appendBreakdown(current["languages"], title: "언어", total: total, to: &details)
        return .init(value: total / 3_600, text: duration(total), subtitle: "오늘 코딩 시간 · \(calendar.timeZone.identifier)", details: details)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 3_600) else { return "확인 불가" }
        if seconds == 0 { return "0분" }
        if seconds < 60 { return "1분 미만" }
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : "\(minutes)분"
    }

    static func redirectedRequest(_ request: URLRequest, original: URLRequest) -> URLRequest? {
        guard let next = request.url,
              next.scheme?.lowercased() == "https", next.host?.lowercased() == "api.wakatime.com", next.port == nil || next.port == 443,
              next.user == nil, next.password == nil else { return nil }
        var redirected = request
        redirected.httpMethod = "GET"
        redirected.setValue(original.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
        return redirected
    }

    private static func appendBreakdown(_ raw: Any?, title: String, total: Double, to details: inout [MetricDetail]) {
        guard let rows = raw as? [[String: Any]] else { return }
        let valid = rows.compactMap { row -> (String, Double)? in
            guard let name = row["name"] as? String, !name.isEmpty, let value = seconds(row["total_seconds"]) else { return nil }
            return (name, value)
        }.sorted { $0.1 > $1.1 }
        for (index, row) in valid.prefix(3).enumerated() {
            details.append(.init(label: "\(title) \(index + 1) · \(row.0)", value: duration(row.1), fraction: total > 0 ? min(row.1 / total, 1) : nil))
        }
    }

    private static func checkedCredential(_ credential: String) throws -> String {
        let value = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 8_192,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw StatusError.authentication("WakaTime 보안 키 또는 조회 토큰을 입력해 주세요.")
        }
        return value
    }

    private static func seconds(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 && value < Double(Int.max / 3_600) ? value : nil
    }

    private static func dateKey(_ range: [String: Any], calendar: Calendar) -> String? {
        if let date = range["date"] as? String {
            let formatter = dateFormatter(calendar)
            guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { return nil }
            return date
        }
        guard let start = range["start"] as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = formatter.date(from: start) ?? ISO8601DateFormatter().date(from: start)
        return parsed.map { dayString($0, calendar: calendar) }
    }

    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = calendar.timeZone
        return result
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String { dateFormatter(calendar).string(from: date) }
    private static func dateFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

private final class WakaTimeRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest else { completionHandler(nil); return }
        completionHandler(WakaTimeProvider.redirectedRequest(request, original: original))
    }
}
