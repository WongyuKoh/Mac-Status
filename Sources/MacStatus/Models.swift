import Foundation

enum MetricKind: String, Codable, CaseIterable {
    case codex, claude, claudeAPI, wakatime, cpu, memory, storage, temperature, http, manual
    var title: String {
        switch self {
        case .codex: return "ChatGPT 계정 로그인"
        case .claude: return "Claude 계정 로그인"
        case .claudeAPI: return "Claude Console API 크레딧"
        case .wakatime: return "WakaTime 기록 시간"
        case .cpu: return "CPU"
        case .memory: return "메모리"
        case .storage: return "저장공간"
        case .temperature: return "발열 온도"
        case .http: return "HTTP JSON API"
        case .manual: return "직접 입력"
        }
    }
    var isSystem: Bool { [.cpu, .memory, .storage, .temperature].contains(self) }
}

struct MetricTemplate: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var subtitle: String = ""
    var symbol: String = "chart.bar.fill"
    var tint: String = "mint"
    var kind: MetricKind
    var unit: String = "%"
    var limit: Double? = 100
    var manualValue: Double? = nil
    var endpoint: String = ""
    var valuePath: String = ""
    var limitPath: String = ""
    var aggregation: String = "first"
    var multiplier: Double = 1
    var headers: [String: String] = [:]
    var authHeader: String = "Authorization"
    var authPrefix: String = "Bearer "
    var refreshInterval: Double = 60
    var link: String = ""
    var isEnabled: Bool = true

    static var defaults: [MetricTemplate] {
        [
            .init(name: "Codex", subtitle: "사용량 · 한도", symbol: "terminal.fill", tint: "mint", kind: .codex, link: "https://chatgpt.com/codex/settings/usage"),
            .init(name: "Claude", subtitle: "사용량 · 한도", symbol: "sun.max.fill", tint: "orange", kind: .claude, link: "https://claude.ai/settings/usage"),
            .init(name: "CPU", subtitle: "프로세서 사용량", symbol: "cpu", tint: "blue", kind: .cpu, refreshInterval: 3),
            .init(name: "메모리", subtitle: "물리 메모리", symbol: "memorychip", tint: "purple", kind: .memory, unit: "GB", limit: nil, refreshInterval: 3),
            .init(name: "저장공간", subtitle: "Macintosh HD", symbol: "internaldrive", tint: "mint", kind: .storage, unit: "GB", limit: nil, refreshInterval: 30),
            .init(name: "발열", subtitle: "CPU 센서 · 시스템 상태", symbol: "thermometer.medium", tint: "orange", kind: .temperature, unit: "°C", limit: nil, refreshInterval: 5)
        ]
    }
}

enum MetricDetailRole: String { case session, weekly, cloud, credits, other }

struct MetricDetail: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: String
    var fraction: Double? = nil
    var resetAt: Date? = nil
    var role: MetricDetailRole = .other
    var note: String? = nil
}

enum MetricState: String { case ready, needsSetup, unavailable, failed }

struct MetricReading: Equatable {
    var value: Double? = nil
    var limit: Double? = nil
    var text: String? = nil
    var subtitle: String = ""
    var state: MetricState = .ready
    var updatedAt: Date? = Date()
    var details: [MetricDetail] = []
    var fraction: Double? {
        guard let value, let limit, limit > 0 else { return nil }
        return min(max(value / limit, 0), 1)
    }
    static func setup(_ message: String) -> MetricReading {
        .init(subtitle: message, state: .needsSetup, updatedAt: nil)
    }
    static func error(_ message: String) -> MetricReading {
        .init(subtitle: message, state: .failed, updatedAt: nil)
    }
}

enum StatusError: LocalizedError {
    case message(String)
    case authentication(String)
    var errorDescription: String? {
        switch self {
        case .message(let message), .authentication(let message): return message
        }
    }
}
