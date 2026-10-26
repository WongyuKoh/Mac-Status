enum TemplateField: String, Hashable, CaseIterable {
    case name, subtitle, unit, symbol, refreshInterval, multiplier, limit, manualValue
    case aggregation, authHeader, authPrefix, headers, link, endpoint, valuePath, limitPath, token
    case valueExpression, limitExpression
}

struct TemplateValidationIssue: Equatable {
    let field: TemplateField
    let message: String
}
