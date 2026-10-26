import Foundation

/// Validate the text currently being edited without saving, reading a secret,
/// or turning an invalid number into a value that could be submitted.
enum MetricEditorValidation {
    struct Evaluation {
        let template: MetricTemplate
        let issues: [TemplateValidationIssue]
    }

    static func evaluate(_ template: MetricTemplate, limitText: String, valueText: String, multiplierText: String) -> Evaluation {
        var candidate = template
        candidate.name = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var issues: [TemplateValidationIssue] = []
        let isBuiltIn = template.kind.isSystem || [.codex, .claude, .claudeAPI, .wakatime].contains(template.kind)
        if template.kind == .http && template.effectiveHTTPValueMode == .json {
            candidate.unit = ""; candidate.limit = nil; candidate.limitPath = ""
            candidate.aggregation = "first"; candidate.multiplier = 1
            candidate.valueExpression = nil; candidate.limitExpression = nil
        } else if !isBuiltIn {
            if limitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { candidate.limit = nil }
            else if let limit = Double(limitText), limit.isFinite, limit > 0 { candidate.limit = limit }
            else {
                issues.append(.init(field: .limit, message: "0보다 큰 숫자를 입력해 주세요."))
                candidate.limit = nil
            }
            if template.kind == .manual {
                if let value = Double(valueText), value.isFinite, value >= 0 { candidate.manualValue = value }
                else {
                    issues.append(.init(field: .manualValue, message: valueText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? "현재 값을 입력해 주세요." : "0 이상의 숫자를 입력해 주세요."))
                    candidate.manualValue = nil
                }
            }
            if template.kind == .http {
                candidate.valueExpression = normalizedExpression(template.valueExpression)
                candidate.limitExpression = template.limitPath.isEmpty ? nil : normalizedExpression(template.limitExpression)
                if let multiplier = Double(multiplierText), multiplier.isFinite, multiplier != 0 { candidate.multiplier = multiplier }
                else {
                    issues.append(.init(field: .multiplier, message: "0이 아닌 숫자를 입력해 주세요."))
                    candidate.multiplier = 1
                }
            }
        }
        for issue in TemplateEngine.validationIssues(for: candidate) where !issues.contains(where: { $0.field == issue.field }) {
            issues.append(issue)
        }
        return Evaluation(template: candidate, issues: issues)
    }

    private static func normalizedExpression(_ expression: String?) -> String? {
        guard let expression = expression?.trimmingCharacters(in: .whitespacesAndNewlines), !expression.isEmpty else { return nil }
        return expression
    }

    static func message(for issue: TemplateValidationIssue, in template: MetricTemplate) -> String {
        switch issue.field {
        case .name: return template.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "이름을 입력해 주세요." : "이름을 60자 이하로 줄여 주세요."
        case .subtitle: return "설명을 180자 이하로 줄여 주세요."
        case .symbol: return "아이콘 이름을 80자 이하로 줄여 주세요."
        case .unit: return "단위를 20자 이하로 줄여 주세요."
        case .limit: return "0보다 큰 숫자를 입력해 주세요."
        case .manualValue: return issue.message.hasPrefix("현재 값") ? issue.message : "0 이상의 숫자를 입력해 주세요."
        case .multiplier: return "0이 아닌 숫자를 입력해 주세요."
        case .endpoint: return template.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "API 주소를 입력해 주세요." : "API 주소를 확인해 주세요. 키·토큰은 인증 칸에 입력하세요."
        case .valuePath: return template.valuePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "값의 JSON 경로를 입력해 주세요." : "경로를 A.B.C처럼 점(.)으로 구분해 주세요."
        case .limitPath: return "한도 경로를 점(.)으로 구분해 주세요."
        case .valueExpression, .limitExpression: return "value와 숫자, + - * / 괄호로 계산식을 입력해 주세요."
        case .aggregation: return "단일 값 또는 합계를 선택해 주세요."
        case .authHeader: return "올바른 인증 헤더 이름을 입력해 주세요."
        case .authPrefix: return "접두어는 100자 이하로 입력하고 줄바꿈은 빼 주세요."
        case .headers: return "추가 헤더 설정을 확인해 주세요."
        case .link: return "올바른 바로가기 주소를 입력해 주세요."
        case .refreshInterval: return "갱신 간격을 3초~24시간 사이로 설정해 주세요."
        case .token: return "보안 키를 확인해 주세요."
        }
    }
}
