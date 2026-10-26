import Foundation

enum MenuBarValueMode: String, CaseIterable, Hashable {
    case value, percentage
}

enum MenuBarMetricID {
    static func primary(_ id: UUID) -> String { "metric:\(id.uuidString)" }
    static func role(_ role: MetricDetailRole, in id: UUID) -> String { "detail:\(id.uuidString):\(role.rawValue)" }
    static func detail(_ detail: MetricDetail, in id: UUID) -> String {
        "detail:\(id.uuidString):\(detail.role.rawValue):\(detail.label)"
    }
}

enum MenuBarMetricSource: Hashable {
    case primary(UUID)
    case detail(UUID, role: String, label: String?)
    case unavailable
}

struct MenuBarMetricOption: Identifiable, Hashable {
    let id: String
    let title: String
    let supportsPercentage: Bool
    let source: MenuBarMetricSource
    var symbol: String? = nil
    var section: String? = nil
}

struct MenuBarMetricPresentation: Equatable {
    let text: String
    let description: String
}

enum MenuBarMetricCatalog {
    static func supportsPercentage(_ template: MetricTemplate) -> Bool {
        guard !(template.kind == .http && template.effectiveHTTPValueMode == .json), template.kind != .wakatime else { return false }
        if [.cpu, .memory, .storage, .codex, .claude].contains(template.kind) { return true }
        return template.unit == "%" || template.limit.map { $0.isFinite && $0 > 0 } == true || !template.limitPath.isEmpty
    }

    static func options(for templates: [MetricTemplate], reading: (MetricTemplate) -> MetricReading) -> [MenuBarMetricOption] {
        var options: [MenuBarMetricOption] = []
        for template in templates {
            let isAI = [.codex, .claude].contains(template.kind)
            if !isAI {
                let title = template.kind == .wakatime ? template.name + " · 오늘 기록 시간" : template.name
                options.append(.init(id: MenuBarMetricID.primary(template.id), title: title,
                                     supportsPercentage: supportsPercentage(template), source: .primary(template.id),
                                     symbol: symbol(for: template), section: section(for: template.kind)))
            }
            let current = reading(template)
            if isAI {
                for (role, title) in [(MetricDetailRole.session, "5시간 사용량"), (.weekly, "주간 사용량")] {
                    options.append(.init(id: MenuBarMetricID.role(role, in: template.id), title: template.name + " · " + title,
                                         supportsPercentage: true, source: .detail(template.id, role: role.rawValue, label: nil),
                                         symbol: role == .session ? "clock" : "calendar", section: section(for: template.kind)))
                }
            }
            for detail in current.details where
                (detail.role == .credits && detail.label != "추가 크레딧 사용") || (template.kind == .wakatime && detail.label == "최근 7일") {
                let supportsRatio = detail.fraction != nil || ["클라우드 세션 크레딧", "워크스페이스 한도"].contains(detail.label)
                let option = MenuBarMetricOption(id: MenuBarMetricID.detail(detail, in: template.id), title: template.name + " · " + detail.label,
                                                 supportsPercentage: supportsRatio,
                                                 source: .detail(template.id, role: detail.role.rawValue, label: detail.label),
                                                 symbol: detail.role == .credits ? "creditcard" : "calendar", section: section(for: template.kind))
                if !options.contains(where: { $0.id == option.id }) { options.append(option) }
            }
        }
        return options
    }

    private static func section(for kind: MetricKind) -> String {
        switch kind {
        case .codex, .claude: return "AI 사용량"
        case .cpu, .memory, .storage, .temperature: return "이 Mac"
        case .wakatime: return "활동 기록"
        case .claudeAPI, .http: return "API 통계"
        case .manual: return "직접 입력"
        }
    }

    private static func symbol(for template: MetricTemplate) -> String {
        switch template.kind {
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .storage: return "internaldrive"
        case .temperature: return "thermometer.medium"
        case .wakatime: return "clock"
        case .claudeAPI: return "creditcard"
        default: return template.symbol.isEmpty ? "chart.bar.fill" : template.symbol
        }
    }
}

enum MenuBarMetricFormat {
    static func primary(_ template: MetricTemplate, reading: MetricReading, mode: MenuBarValueMode) -> MenuBarMetricPresentation {
        let isJSON = template.kind == .http && template.effectiveHTTPValueMode == .json
        // A failed calculation has an explicit null result, including when
        // percentage display was selected. Do not replace it with a dash or 0%.
        if template.kind == .http, reading.text == "null", reading.value == nil, reading.limit == nil {
            return presentation("null", title: template.name, reason: reading.subtitle)
        }
        guard reading.state == .ready else {
            return unavailable(title: template.name, reason: reading.subtitle, isJSON: isJSON)
        }
        if mode == .percentage && !isJSON {
            let ratio: Double?
            if let value = reading.value, value.isFinite,
               let limit = reading.limit, limit.isFinite, limit > 0 {
                ratio = value / limit * 100
            } else if template.unit == "%", let value = reading.value, value.isFinite {
                ratio = value
            } else { ratio = nil }
            guard let ratio, ratio.isFinite else {
                return unavailable(title: template.name, reason: "현재 항목의 사용률을 확인할 수 없습니다.")
            }
            return presentation(String(format: "%.0f%%", ratio), title: template.name + " · 사용률")
        }
        if let text = reading.text, !text.isEmpty {
            return presentation(text, title: template.name)
        }
        guard let value = reading.value, value.isFinite else {
            return unavailable(title: template.name, reason: "현재 값을 확인할 수 없습니다.", isJSON: isJSON)
        }
        var fullValue = MetricFormat.number(value, unit: template.unit)
        if !template.unit.isEmpty && template.unit != "USD" {
            fullValue += ["%", "°C"].contains(template.unit) ? template.unit : " " + template.unit
        }
        return presentation(fullValue, title: template.name)
    }

    static func detail(_ detail: MetricDetail?, reading: MetricReading, title: String, mode: MenuBarValueMode) -> MenuBarMetricPresentation {
        guard reading.state == .ready || reading.state == .unavailable,
              let detail, !detail.value.isEmpty, !["정보 미제공", "미제공", "—"].contains(detail.value) else {
            return unavailable(title: title, reason: reading.subtitle.isEmpty ? "현재 값을 확인할 수 없습니다." : reading.subtitle)
        }
        if mode == .percentage {
            guard let fraction = detail.fraction, fraction.isFinite, fraction >= 0 else {
                return unavailable(title: title, reason: "현재 항목의 사용률을 확인할 수 없습니다.")
            }
            return presentation(String(format: "%.0f%%", fraction * 100), title: title + " · 사용률")
        }
        return presentation(detail.value, title: title)
    }

    static func unavailable(title: String, reason: String, isJSON: Bool = false) -> MenuBarMetricPresentation {
        presentation(isJSON ? "null" : "—", title: title, reason: reason)
    }

    private static func presentation(_ fullValue: String, title: String, reason: String = "") -> MenuBarMetricPresentation {
        let compact = fullValue.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let text = compact.count > 18 ? String(compact.prefix(17)) + "…" : compact
        let description = "Mac Status · \(title): \(fullValue)" + (reason.isEmpty ? "" : "\n" + reason)
        return .init(text: text, description: description)
    }
}
