import Foundation

/// Pure parsers intentionally accept fixtures without accessing any account credentials.
enum AIUsageParser {
    /// The web account's own usage response. No session token or account identity
    /// is retained by this parser; only quota values reach the dashboard.
    static func codexWeb(_ data: Data) throws -> MetricReading {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StatusError.message("Codex 응답 형식을 확인할 수 없습니다.")
        }

        func mappedWindow(_ object: Any?) -> [String: Any]? {
            guard let object = object as? [String: Any],
                  let percent = validPercent(object["used_percent"]) else { return nil }
            var window: [String: Any] = ["usedPercent": percent]
            if let seconds = number(object["limit_window_seconds"]), seconds > 0 {
                window["windowDurationMins"] = seconds / 60
            }
            if let reset = number(object["reset_at"]), reset >= 0 { window["resetsAt"] = reset }
            return window
        }

        func mappedBucket(_ object: Any?, name: String? = nil) -> [String: Any] {
            let object = object as? [String: Any] ?? [:]
            var bucket: [String: Any] = [:]
            if let primary = mappedWindow(object["primary_window"]) { bucket["primary"] = primary }
            if let secondary = mappedWindow(object["secondary_window"]) { bucket["secondary"] = secondary }
            if let name, !name.isEmpty { bucket["limitName"] = name }
            return bucket
        }

        var base = mappedBucket(payload["rate_limit"])
        if let plan = payload["plan_type"] as? String { base["planType"] = plan }
        if let credits = payload["credits"] as? [String: Any] { base["credits"] = credits }
        var buckets = ["codex": base]
        if let additional = payload["additional_rate_limits"] as? [[String: Any]] {
            for (index, item) in additional.enumerated() {
                let name = item["limit_name"] as? String ?? item["metered_feature"] as? String ?? "추가 한도 \(index + 1)"
                let identifier = "additional_\(index)"
                buckets[identifier] = mappedBucket(item["rate_limit"], name: name)
            }
        }
        if let review = payload["code_review_rate_limit"] as? [String: Any] {
            buckets["code_review"] = mappedBucket(review, name: "코드 리뷰")
        }
        var reading = try codex(JSONSerialization.data(withJSONObject: ["rateLimitsByLimitId": buckets]))

        // Workspace spend controls can be monthly even when the normal usage
        // response has only a weekly window. They are percentages, not API USD.
        let spend = payload["spend_control"] as? [String: Any]
        let rateLimit = payload["rate_limit"] as? [String: Any]
        let monthly = payload["individual_limit"] as? [String: Any]
            ?? rateLimit?["individual_limit"] as? [String: Any]
            ?? spend?["individual_limit"] as? [String: Any]
        if let monthly, let detail = codexWorkspaceLimit(monthly) {
            reading.details.append(detail)
            let percent = detail.fraction.map { $0 * 100 }
            if reading.value == nil, let percent {
                reading.value = percent
                reading.limit = 100
                reading.text = nil
                reading.state = .ready
                reading.subtitle = "ChatGPT 계정 · 워크스페이스 한도"
            }
        }
        return reading
    }

    static func codex(_ data: Data) throws -> MetricReading {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StatusError.message("Codex 응답 형식을 확인할 수 없습니다.")
        }
        let result = payload["result"] as? [String: Any] ?? payload
        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let orderedBuckets: [(String, [String: Any])]
        if let buckets, !buckets.isEmpty {
            orderedBuckets = buckets.keys.sorted {
                ($0 == "codex" ? 0 : 1, $0) < ($1 == "codex" ? 0 : 1, $1)
            }.compactMap { key in buckets[key].map { (key, $0) } }
        } else if let legacy = result["rateLimits"] as? [String: Any] {
            orderedBuckets = [("codex", legacy)]
        } else {
            return .setup("앱에서 ChatGPT 계정으로 로그인해 주세요.")
        }
        guard let selected = orderedBuckets.first?.1 else { return .setup("앱에서 ChatGPT 계정으로 로그인해 주세요.") }
        var details: [MetricDetail] = []
        var mainValue: Double?
        for (index, item) in orderedBuckets.enumerated() {
            let (bucketID, bucket) = item
            for key in ["primary", "secondary"] {
                guard let window = bucket[key] as? [String: Any], let percent = validPercent(window["usedPercent"]) else { continue }
                if mainValue == nil { mainValue = percent }
                let duration = number(window["windowDurationMins"])
                let windowTitle = duration.map(windowLabel) ?? (key == "primary" ? "현재 세션" : "추가 한도")
                let label = index == 0 ? windowTitle : "\(bucket["limitName"] as? String ?? bucketID) · \(windowTitle)"
                let role: MetricDetailRole = index == 0 && bucketID == "codex" ? aggregateRole(minutes: duration) : .other
                details.append(.init(label: uniqueLabel(label, in: details), value: percentText(percent), fraction: min(percent / 100, 1), resetAt: number(window["resetsAt"]).map(Date.init(timeIntervalSince1970:)), role: role))
            }
        }
        details.append(.init(label: "원격 작업", value: "플랜 한도 공유", role: .cloud,
                             note: "Codex 로컬·클라우드 작업은 플랜 한도를 함께 사용합니다. 원격 작업만의 사용률·작업 수는 이 응답에서 제공되지 않습니다."))
        details.append(codexCreditDetail(selected["credits"]))
        let plan = codexPlanName(selected["planType"] ?? selected["plan_type"] ?? result["planType"] ?? result["plan_type"])
        guard let mainValue else {
            var reading = MetricReading(text: "한도 정보 없음", subtitle: "현재 계정에서 사용량 수치를 제공하지 않습니다.", state: .unavailable, details: details)
            reading.planName = plan
            return reading
        }
        var reading = MetricReading(value: mainValue, limit: 100, subtitle: plan.map { "\($0) · ChatGPT 계정" } ?? "ChatGPT 계정 · 구독 사용량", details: details)
        reading.planName = plan
        return reading
    }

    static func claude(_ data: Data, prepaidData: Data? = nil, organizationData: Data? = nil) throws -> MetricReading {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StatusError.message("Claude 응답 형식을 확인할 수 없습니다.")
        }
        var details: [MetricDetail] = []
        var aggregateValues: [MetricDetailRole: Double] = [:]
        var fallbackValue: Double?
        // Model-specific weekly limits remain separate from the account-wide weekly budget.
        if let limits = payload["limits"] as? [[String: Any]] {
            let rank = ["session": 0, "weekly_all": 1, "weekly_scoped": 2]
            let ordered = limits.enumerated().sorted {
                (rank[$0.element["kind"] as? String ?? ""] ?? 3, $0.offset)
                    < (rank[$1.element["kind"] as? String ?? ""] ?? 3, $1.offset)
            }.map(\.element)
            for window in ordered {
                guard let percent = validPercent(window["percent"] ?? window["utilization"]) else { continue }
                let kind = window["kind"] as? String ?? ""
                let scope = window["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let label: String
                let role: MetricDetailRole
                switch kind {
                case "session": label = "5시간"; role = .session
                case "weekly_all": label = "주간 전체"; role = .weekly
                case "weekly_scoped": label = "주간 \(model?["display_name"] as? String ?? "모델")"; role = .other
                default: continue
                }
                if role != .other { aggregateValues[role] = percent }
                if fallbackValue == nil { fallbackValue = percent }
                details.append(.init(label: uniqueLabel(label, in: details), value: percentText(percent), fraction: min(percent / 100, 1), resetAt: isoDate(window["resets_at"]), role: role))
            }
        }
        // A partial modern array must not hide valid aggregate windows from the legacy fields.
        for (key, label, role) in [("five_hour", "5시간", MetricDetailRole.session), ("seven_day", "주간 전체", .weekly)] {
            guard aggregateValues[role] == nil, let window = payload[key] as? [String: Any],
                  let percent = validPercent(window["utilization"]) else { continue }
            aggregateValues[role] = percent
            details.append(.init(label: label, value: percentText(percent), fraction: min(percent / 100, 1), resetAt: isoDate(window["resets_at"]), role: role))
        }
        let cloudKeys: Set<String> = ["seven_day_routines", "seven_day_claude_routines", "claude_routines", "routines", "routine", "seven_day_cowork", "cowork"]
        let scoped = payload.keys.filter { $0.hasPrefix("seven_day_") && $0 != "seven_day_oauth_apps" && !cloudKeys.contains($0) }.sorted()
        for key in scoped {
            guard let window = payload[key] as? [String: Any], let percent = validPercent(window["utilization"]) else { continue }
            let label = "주간 " + key.replacingOccurrences(of: "seven_day_", with: "").capitalized
            guard !details.contains(where: { $0.label.caseInsensitiveCompare(label) == .orderedSame }) else { continue }
            if fallbackValue == nil { fallbackValue = percent }
            details.append(.init(label: label, value: percentText(percent), fraction: min(percent / 100, 1), resetAt: isoDate(window["resets_at"])))
        }
        var cloudWindowFound = false
        let surfaces = [
            (["seven_day_cowork", "cowork"], "Cowork 작업"),
            (["seven_day_routines", "seven_day_claude_routines", "claude_routines", "routines", "routine"], "예약 작업")
        ]
        for (keys, title) in surfaces {
            for key in keys {
                guard let window = payload[key] as? [String: Any], let percent = validPercent(window["utilization"]) else { continue }
                let label = key.hasPrefix("seven_day_") ? title + " · 주간" : title
                details.append(.init(label: label, value: percentText(percent), fraction: min(percent / 100, 1), resetAt: isoDate(window["resets_at"]), role: .cloud,
                                     note: "서비스가 별도로 반환한 \(title) 한도입니다. 전체 원격 작업의 합계를 뜻하지 않습니다."))
                cloudWindowFound = true
                break
            }
        }
        if !cloudWindowFound {
            details.append(.init(label: "원격 작업", value: "플랜 한도 공유", role: .cloud,
                                 note: "Claude 클라우드 작업도 플랜 사용량에 포함됩니다. 이 응답에는 원격 작업만의 사용률·작업 수가 없습니다."))
        }
        details.append(claudeExtraUsageDetail(payload["extra_usage"]))
        if let prepaidData, let balance = claudePrepaidCreditDetail(prepaidData) { details.append(balance) }
        if let cloudCredits = claudeCloudCreditDetail(payload["iguana_necktie"]) { details.append(cloudCredits) }
        let plan = claudePlanName(organizationData)
        let mainValue = aggregateValues[.session] ?? aggregateValues[.weekly] ?? fallbackValue
        guard let mainValue else {
            var reading = MetricReading(text: "한도 정보 없음", subtitle: "Claude에서 현재 계정의 한도 수치를 제공하지 않습니다.", state: .unavailable, details: details)
            reading.planName = plan
            return reading
        }
        var reading = MetricReading(value: mainValue, limit: 100, subtitle: "Claude 계정 · 구독 사용량", details: details)
        reading.planName = plan
        return reading
    }

    /// Only documented plan identifiers become badges. Unrecognized values,
    /// account IDs, monetary balances, and model names never imply a plan.
    private static func codexPlanName(_ raw: Any?) -> String? {
        guard let identifier = planIdentifier(raw) else { return nil }
        switch identifier {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        // Match the explicit Pro 100 / Pro 200 / Pro 500 plan identifiers
        // used by the official Codex client, independent of credit balances.
        case "pro": return "Pro · $200"
        case "pro_lite", "prolite": return "Pro · $100"
        case "pro_max", "promax": return "Pro Max · $500"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu", "education": return "Edu"
        default: return nil
        }
    }

    private static func claudePlanName(_ data: Data?) -> String? {
        guard let data, data.count <= 65_536,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        // Account membership is scoped to the exact selected organization by
        // the fixed script. Existing organization metadata remains a fallback.
        let scopedRecords = [object["account"], object["organization"]].compactMap { $0 as? [String: Any] }
        let records = scopedRecords.isEmpty ? [object] : scopedRecords
        let subscriptions = records.compactMap { claudePlanIdentifier(planIdentifier($0["subscription_type"])) }
        let billings = records.compactMap { claudePlanIdentifier(planIdentifier($0["billing_type"])) }
        let tiers = records.compactMap { claudePlanIdentifier(planIdentifier($0["rate_limit_tier"])) }
        let capabilities = records.flatMap { record in
            (record["capabilities"] as? [String] ?? []).prefix(32).compactMap { claudeCapabilityPlan(planIdentifier($0)) }
        }
        let hasTeamSeat = records.contains { ["team_standard", "team_tier_1"].contains(planIdentifier($0["seat_tier"]) ?? "") }
        // Team seats may carry a Max rate-limit tier. Preserve the selected
        // organization's explicit business plan instead of relabeling the seat.
        let organizationPlans = subscriptions + billings + capabilities + tiers.filter { ["Team", "Enterprise"].contains($0) }
        if organizationPlans.contains("Enterprise") { return "Enterprise" }
        if hasTeamSeat || organizationPlans.contains("Team") { return "Team" }
        if let tier = tiers.first { return tier }
        if let explicit = (subscriptions + billings).first(where: { $0 != "Pro" && $0 != "Free" }) { return explicit }
        for plan in ["Max 20×", "Max 5×", "Max", "Ultra"] {
            if capabilities.contains(plan) { return plan }
        }
        if let subscription = subscriptions.first { return subscription }
        if let billing = billings.first { return billing }
        for plan in ["Pro", "Free"] {
            if capabilities.contains(plan) { return plan }
        }
        return nil
    }

    private static func claudeCapabilityPlan(_ identifier: String?) -> String? {
        guard let identifier, identifier.hasPrefix("claude_") else { return nil }
        return claudePlanIdentifier(identifier)
    }

    private static func claudePlanIdentifier(_ identifier: String?) -> String? {
        guard let identifier else { return nil }
        switch identifier {
        case "max_20x", "claude_max_20x", "default_claude_max_20x": return "Max 20×"
        case "max_5x", "claude_max_5x", "default_claude_max_5x": return "Max 5×"
        case "max", "claude_max", "default_claude_max", "stripe_claude_max_subscription": return "Max"
        case "pro", "claude_pro", "default_claude_pro", "stripe_claude_pro_subscription": return "Pro"
        case "team", "claude_team", "default_claude_team", "stripe_claude_team_subscription": return "Team"
        case "enterprise", "claude_enterprise", "default_claude_enterprise", "stripe_claude_enterprise_subscription": return "Enterprise"
        case "ultra", "claude_ultra", "default_claude_ultra": return "Ultra"
        case "free", "claude_free", "default_claude_free": return "Free"
        default: return nil
        }
    }

    private static func planIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String, value.count <= 80,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: "_").replacingOccurrences(of: " ", with: "_")
        guard !identifier.isEmpty, identifier.unicodeScalars.allSatisfy({
            (97...122).contains(Int($0.value)) || (48...57).contains(Int($0.value)) || $0 == "_"
        }) else { return nil }
        return identifier
    }

    private static func aggregateRole(minutes: Double?) -> MetricDetailRole {
        guard let minutes else { return .other }
        if minutes == 10080 { return .weekly }
        if minutes > 0 && minutes <= 300 { return .session }
        return .other
    }

    private static func codexCreditDetail(_ value: Any?) -> MetricDetail {
        guard let credits = value as? [String: Any] else {
            return .init(label: "추가 크레딧", value: "정보 미제공", role: .credits, note: "사용량·잔액을 제공하지 않는 응답입니다.")
        }
        if credits["unlimited"] as? Bool == true {
            return .init(label: "추가 크레딧", value: "무제한", role: .credits, note: "서비스가 무제한으로 표시합니다. 누적 사용량은 제공되지 않습니다.")
        }
        if let balance = nonnegativeDecimal(credits["balance"]) {
            return .init(label: "크레딧 잔액", value: decimalText(balance) + " 크레딧", role: .credits,
                         note: "남은 크레딧 단위입니다. 총 충전량이 없어 사용량은 계산하지 않습니다. API 비용(USD)과 별도입니다.")
        }
        if credits["has_credits"] as? Bool == false {
            return .init(label: "추가 크레딧", value: "보유 없음", role: .credits, note: "서비스가 추가 크레딧 미보유 상태로 표시합니다.")
        }
        return .init(label: "크레딧 잔액", value: "정보 미제공", role: .credits, note: "크레딧 잔액 수치가 응답에 없습니다.")
    }

    private static func codexWorkspaceLimit(_ value: [String: Any]) -> MetricDetail? {
        let used = nonnegativeDecimal(value["used"])
        let limit = nonnegativeDecimal(value["limit"])
        let remainingPercent = validPercent(value["remaining_percent"] ?? value["remainingPercent"]).flatMap { $0 <= 100 ? $0 : nil }
        let percent = validPercent(value["used_percent"]) ?? remainingPercent.map { max(0, 100 - $0) }
            ?? ratio(used, limit).map { $0 * 100 }
        guard percent != nil || used != nil || limit != nil else { return nil }
        let display: String
        if let used, let limit { display = "\(decimalText(used)) / \(decimalText(limit)) 사용" }
        else if let used { display = decimalText(used) + " 사용" }
        else if let percent, let limit { display = percentText(percent) + " · 한도 " + decimalText(limit) }
        else if let percent { display = percentText(percent) }
        else if let limit { display = "사용량 미제공 · 한도 " + decimalText(limit) }
        else { display = "사용량 미제공" }
        let reset = number(value["reset_at"] ?? value["resets_at"] ?? value["resetsAt"]).flatMap { $0 >= 0 ? Date(timeIntervalSince1970: $0) : nil }
        return .init(label: "워크스페이스 한도", value: display, fraction: percent.map { min($0 / 100, 1) }, resetAt: reset, role: .credits,
                     note: "계정이 제공한 사용량·한도 단위입니다. 크레딧 잔액이나 API 비용과 합산하지 않습니다.")
    }

    private static func claudeExtraUsageDetail(_ value: Any?) -> MetricDetail {
        guard let extra = value as? [String: Any] else {
            return .init(label: "추가 크레딧 사용", value: "정보 미제공", role: .credits, note: "구독의 추가 사용량 정보가 응답에 없습니다.")
        }
        let used = nonnegativeDecimal(extra["used_credits"])
        let limit = nonnegativeDecimal(extra["monthly_limit"] ?? extra["monthly_credit_limit"])
        let enabled = extra["is_enabled"] as? Bool
        if enabled == false && (used == nil || used == 0) {
            return .init(label: "추가 크레딧 사용", value: "비활성화", role: .credits, note: "계정에서 추가 사용이 꺼져 있습니다. 사용량 0으로 추정하지 않습니다.")
        }
        let rawCurrency = (extra["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let currency = rawCurrency?.isEmpty == false ? rawCurrency! : "USD"
        let rawPlaces = number(extra["decimal_places"])
        if let raw = extra["decimal_places"], !(raw is NSNull), rawPlaces == nil {
            return .init(label: "추가 크레딧 사용", value: "단위 정보 확인 필요", role: .credits, note: "소수 단위 정보가 올바르지 않아 금액을 표시하지 않습니다.")
        }
        guard rawPlaces == nil || (rawPlaces! >= 0 && rawPlaces! <= 6 && rawPlaces!.rounded() == rawPlaces!) else {
            return .init(label: "추가 크레딧 사용", value: "단위 정보 확인 필요", role: .credits, note: "소수 단위 정보가 올바르지 않아 금액을 표시하지 않습니다.")
        }
        let places = rawPlaces.map(Int.init) ?? 2
        let scale = Decimal(sign: .plus, exponent: -places, significand: 1)
        func amount(_ raw: Decimal) -> String { currency + " " + decimalText(raw * scale, places: places) }
        let display: String
        if let used, let limit { display = "\(amount(used)) / \(amount(limit)) 사용" }
        else if let used { display = amount(used) + " 사용" }
        else if let limit { display = "사용량 미제공 · 월한도 " + amount(limit) }
        else { display = "사용량 미제공" }
        let percent = validPercent(extra["utilization"]).map { $0 / 100 } ?? ratio(used, limit)
        var notes = ["이번 달 구독 추가 사용 · 월한도 여유는 충전 잔액과 다릅니다."]
        if limit == nil { notes.append("월한도 미제공이며 무제한으로 해석하지 않습니다.") }
        if enabled == false { notes.append("현재 추가 사용은 비활성화되어 있습니다.") }
        if rawPlaces == nil { notes.append("레거시 응답의 센트 단위(100분의 1)를 적용했습니다.") }
        if rawCurrency == nil { notes.append("레거시 통화 USD 기준입니다.") }
        return .init(label: "추가 크레딧 사용", value: display, fraction: percent.map { min(max($0, 0), 1) }, role: .credits, note: notes.joined(separator: " "))
    }

    private static func claudeCloudCreditDetail(_ value: Any?) -> MetricDetail? {
        guard let cloud = value as? [String: Any], let limit = nonnegativeDecimal(cloud["limit_dollars"]), limit > 0 else { return nil }
        let reportedUsed = nonnegativeDecimal(cloud["used_dollars"])
        let reportedRemaining = nonnegativeDecimal(cloud["remaining_dollars"])
        if let raw = cloud["used_dollars"], !(raw is NSNull), reportedUsed == nil { return nil }
        if let raw = cloud["remaining_dollars"], !(raw is NSNull), reportedRemaining == nil { return nil }
        if let raw = cloud["locked_reason"], !(raw is NSNull), !(raw is String) { return nil }
        guard reportedUsed.map({ $0 <= limit }) ?? true, reportedRemaining.map({ $0 <= limit }) ?? true,
              let remaining = reportedRemaining ?? reportedUsed.map({ limit - $0 }) else { return nil }
        let used = reportedUsed ?? (limit - remaining)
        let amountDifference = limit - used - remaining
        let inconsistent = abs(NSDecimalNumber(decimal: amountDifference).doubleValue) > 0.0100001
        let expiry = isoDate(cloud["resets_at"])
        if cloud["resets_at"] != nil && !(cloud["resets_at"] is NSNull) && expiry == nil { return nil }
        let expiryNote = expiry.map { "만료 \($0.ISO8601Format()) · 반복 초기화가 아닙니다." }
        if let expiry, expiry <= Date() {
            return .init(label: "클라우드 세션 크레딧", value: "만료됨", role: .credits, note: expiryNote)
        }
        if let reason = cloud["locked_reason"] as? String, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .init(label: "클라우드 세션 크레딧", value: "사용 불가", role: .credits, note: "서비스에서 사용을 제한했습니다. " + (expiryNote ?? ""))
        }
        let display = "USD \(decimalText(used, places: 2)) / \(decimalText(limit, places: 2)) 사용"
        let discrepancyNote = inconsistent ? "서비스가 보고한 사용량·잔액의 합계가 한도와 다릅니다. 제공된 각 금액을 그대로 표시합니다. " : ""
        let note = "남음 USD \(decimalText(remaining, places: 2)) · 구독 추가 사용·API 비용과 별도입니다. " + discrepancyNote + (expiryNote ?? "")
        return .init(label: "클라우드 세션 크레딧", value: display, fraction: ratio(used, limit), role: .credits, note: note)
    }

    private static func claudePrepaidCreditDetail(_ data: Data) -> MetricDetail? {
        guard let prepaid = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let amount = nonnegativeDecimal(prepaid["amount"]),
              let currency = (prepaid["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              !currency.isEmpty else { return nil }
        // This separate endpoint uses minor units. Cloud promotion dollars do not.
        return .init(label: "API 토큰", value: currency + " " + decimalText(amount / 100, places: 2), role: .credits,
                     note: "현재 Claude 웹 워크스페이스가 제공하는 USD 금액입니다. 토큰 개수로 환산하지 않으며, Console API 조직 잔액은 별도로 표시합니다.")
    }

    private static func validPercent(_ value: Any?) -> Double? {
        guard let percent = number(value), percent >= 0, percent <= 100_000 else { return nil }
        return percent
    }

    private static func nonnegativeDecimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
            return number.decimalValue
        }
        if let text = value as? String, let double = Double(text), double.isFinite, double >= 0 {
            return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        }
        return nil
    }

    private static func ratio(_ used: Decimal?, _ limit: Decimal?) -> Double? {
        guard let used, let limit, limit > 0 else { return nil }
        let value = NSDecimalNumber(decimal: used / limit).doubleValue
        return value.isFinite ? value : nil
    }

    private static func decimalText(_ value: Decimal, places: Int? = nil) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSize = 3
        formatter.minimumFractionDigits = places ?? 0
        formatter.maximumFractionDigits = places ?? 8
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? NSDecimalNumber(decimal: value).stringValue
    }

    private static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func percentText(_ percent: Double) -> String {
        String(format: "%.0f%% 사용 · %.0f%% 남음", percent, max(0, 100 - percent))
    }

    private static func windowLabel(_ minutes: Double) -> String {
        if minutes == 10080 { return "주간" }
        if minutes >= 1440 { return String(format: "%.0f일", minutes / 1440) }
        if minutes >= 60 { return String(format: "%.0f시간", minutes / 60) }
        return String(format: "%.0f분", minutes)
    }

    private static func uniqueLabel(_ label: String, in details: [MetricDetail]) -> String {
        let count = details.filter { $0.label == label || $0.label.hasPrefix(label + " · ") }.count
        return count == 0 ? label : "\(label) · \(count + 1)"
    }

    private static func isoDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
