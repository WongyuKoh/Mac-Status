import Foundation

enum TemplateImportExample: String, CaseIterable, Identifiable {
    case manual, http
    var id: Self { self }
    var title: String { self == .manual ? "직접 입력 예시" : "API 연결 예시" }

    var json: String {
        switch self {
        case .manual:
            return """
            {
              "name": "나의 통계",
              "subtitle": "직접 입력한 값",
              "kind": "manual",
              "manualValue": 25,
              "unit": "%",
              "limit": 100,
              "symbol": "chart.bar.fill",
              "tint": "mint"
            }
            """
        case .http:
            return """
            {
              "name": "내 서비스 사용량",
              "subtitle": "API에서 읽은 값",
              "kind": "http",
              "endpoint": "https://example.com/api/usage",
              "valuePath": "usage.total",
              "unit": "회",
              "limit": null,
              "aggregation": "first",
              "refreshInterval": 300,
              "symbol": "chart.bar.fill",
              "tint": "blue"
            }
            """
        }
    }
}
