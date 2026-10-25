import Foundation

/// Fictional, local-only teaching fixtures. Never sent or applied to an editor.
enum APIGuideExamples {
    static let endpoint = "https://example.com/api/usage?period=month"
    static let singleResponse = """
    {
      "usage": {
        "current": 42,
        "limit": 100
      }
    }
    """
    static let sumResponse = """
    { "data": [ { "count": 12 }, { "count": 8 } ] }
    """

    static var singleTemplate: MetricTemplate {
        .init(name: "형식 설명용 예시", kind: .http, unit: "회", limit: nil,
              endpoint: endpoint, valuePath: "usage.current", limitPath: "usage.limit",
              authHeader: "", authPrefix: "")
    }

    static var sumTemplate: MetricTemplate {
        .init(name: "합계 형식 예시", kind: .http, unit: "회", limit: nil,
              endpoint: endpoint, valuePath: "data.*.count", aggregation: "sum",
              authHeader: "", authPrefix: "")
    }
}

enum APIProviderRequirement: Equatable {
    case openAIOrganization, anthropicOrganization

    init?(endpoint: String) {
        guard let url = URLComponents(string: endpoint), url.scheme?.lowercased() == "https" else { return nil }
        switch url.host?.lowercased() {
        case "api.openai.com" where url.path.hasPrefix("/v1/organization/"):
            self = .openAIOrganization
        case "api.anthropic.com" where url.path.hasPrefix("/v1/organizations/"):
            self = .anthropicOrganization
        default: return nil
        }
    }

    var notice: String {
        switch self {
        case .openAIOrganization:
            return "OpenAI 조직 조회에는 Admin API 키가 필요합니다. 일반 프로젝트 키와 구분해 주세요."
        case .anthropicOrganization:
            return "Anthropic 조직 조회에는 Admin API 자격 증명이 필요합니다. 워크스페이스 범위의 API 키는 사용할 수 없습니다."
        }
    }

    var documentationURL: URL {
        switch self {
        case .openAIOrganization:
            return URL(string: "https://developers.openai.com/api/reference/administration/overview")!
        case .anthropicOrganization:
            return URL(string: "https://platform.claude.com/docs/en/manage-claude/usage-cost-api")!
        }
    }
}
