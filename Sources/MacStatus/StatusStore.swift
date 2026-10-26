import AppKit
import Combine
import ServiceManagement

/// Tests can replace external reads and session clearing without creating a
/// WKWebView, opening an account, or accessing Keychain.
struct StatusStoreServices {
    var readMetric: (@MainActor (MetricTemplate) async -> MetricReading)? = nil
    var clearSession: (@MainActor (MetricKind) async -> Void)? = nil
    var deleteToken: (UUID) -> Bool = { KeychainStore.delete(id: $0) }
    var hasSavedToken: (UUID) -> Bool = { KeychainStore.read(id: $0) != nil }
    var now: () -> Date = Date.init
    var loginItemStatus: () -> Bool = { SMAppService.mainApp.status == .enabled }
    var updateLoginItem: ((Bool) throws -> Bool)? = { enabled in
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
        return SMAppService.mainApp.status == .enabled
    }
}

@MainActor
final class StatusStore: ObservableObject {
    @Published var templates: [MetricTemplate] = []
    @Published var readings: [UUID: MetricReading] = [:]
    @Published var histories: [UUID: [Double]] = [:]
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    @Published var notice: String?
    @Published var codexConnected = false
    @Published var claudeConnected = false
    @Published var claudeAPIConnected = false
    @Published var launchAtLogin = false
    @Published var showCPUInMenu = true
    @Published var useWakaTimeConfiguration = true

    private lazy var system = SystemMetrics()
    private lazy var codexSession = WebAccountSession(kind: .codex, defaults: defaults)
    private lazy var claudeSession = WebAccountSession(kind: .claude, defaults: defaults)
    private(set) lazy var claudeConsoleSession = ClaudeConsoleSession(defaults: defaults)
    var onRequestLogin: ((MetricKind) -> Void)?
    private var timer: Timer?
    private var inFlight: [UUID: UUID] = [:]
    private var lastAttempts: [UUID: Date] = [:]
    private var configurationGeneration: [UUID: Int] = [:]
    private var accountGeneration: [MetricKind: Int] = [:]
    private var clearingAccounts: Set<MetricKind> = []
    private let defaults: UserDefaults
    private let services: StatusStoreServices
    private let automaticallyRefresh: Bool

    init(defaults: UserDefaults = .standard, start: Bool = true, services: StatusStoreServices = .init()) {
        self.defaults = defaults
        self.services = services
        automaticallyRefresh = start
        if services.updateLoginItem != nil { launchAtLogin = services.loginItemStatus() }
        codexConnected = defaults.bool(forKey: "web.codex.connected")
        claudeConnected = defaults.bool(forKey: "web.claude.connected")
        claudeAPIConnected = defaults.bool(forKey: "web.claudeAPI.connected")
        showCPUInMenu = defaults.object(forKey: "showCPUInMenu") as? Bool ?? true
        useWakaTimeConfiguration = defaults.object(forKey: "wakatime.useExistingConfiguration") as? Bool ?? true
        if let data = defaults.data(forKey: "metricTemplates"),
           let saved = try? JSONDecoder().decode([MetricTemplate].self, from: data) {
            templates = saved
        } else {
            templates = MetricTemplate.defaults
        }
        // Install the new built-in once. Later removal or hiding stays intentional.
        if !defaults.bool(forKey: "builtins.wakatime.v1") {
            if !templates.contains(where: { $0.kind == .wakatime }) {
                templates.append(Self.wakaTimeTemplate())
            }
            defaults.set(true, forKey: "builtins.wakatime.v1")
            persist()
        }
        if !defaults.bool(forKey: "builtins.apiOptIn.v1") {
            for index in templates.indices {
                let template = templates[index]
                if template.kind == .http,
                   ["OpenAI API 비용", "OpenAI API 토큰"].contains(template.name),
                   template.endpoint.hasPrefix("https://api.openai.com/v1/organization/"),
                   !services.hasSavedToken(template.id) {
                    templates[index].isEnabled = false
                }
            }
            defaults.set(true, forKey: "builtins.apiOptIn.v1")
            persist()
        }
        if start {
            if services.readMetric == nil {
                if codexConnected { codexSession.prepare() }
                if claudeConnected { claudeSession.prepare() }
                if claudeAPIConnected { claudeConsoleSession.prepare() }
            }
            Task { await refresh(force: true) }
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
    }

    var canManageLoginItem: Bool { services.updateLoginItem != nil }
    var visibleTemplates: [MetricTemplate] { templates.filter(\.isEnabled) }
    var systemTemplates: [MetricTemplate] { visibleTemplates.filter { $0.kind.isSystem } }
    var aiTemplates: [MetricTemplate] { visibleTemplates.filter { [.codex, .claude].contains($0.kind) } }
    var activityTemplates: [MetricTemplate] { visibleTemplates.filter { $0.kind == .wakatime } }
    var customTemplates: [MetricTemplate] { visibleTemplates.filter { !$0.kind.isSystem && ![.codex, .claude, .claudeAPI, .wakatime].contains($0.kind) } }
    var cpuReading: Double? {
        guard let template = templates.first(where: { $0.kind == .cpu && $0.isEnabled }),
              let reading = readings[template.id], reading.state == .ready else { return nil }
        return reading.value
    }

    func reading(for template: MetricTemplate) -> MetricReading {
        var reading = readings[template.id] ?? .setup(template.kind.isSystem ? "측정 중…" : "연결하면 통계가 표시됩니다")
        if template.kind == .claude, let api = visibleTemplates.first(where: { $0.kind == .claudeAPI }),
           let apiReading = readings[api.id], let value = apiReading.value {
            reading.details.append(.init(label: "Console API 잔액", value: MetricFormat.number(value, unit: "USD"), role: .credits,
                                         note: "Claude Console API 조직에서 확인한 잔액입니다."))
            reading.details.append(contentsOf: apiReading.details.map { item in
                var detail = item
                detail.label = "API · " + detail.label
                detail.role = .other
                return detail
            })
        }
        return reading
    }

    func refresh(force: Bool = false) async {
        let now = services.now()
        let due = visibleTemplates.filter { template in
            if template.kind == .manual, readings[template.id] != nil, !force { return false }
            return inFlight[template.id] == nil && (force || now.timeIntervalSince(lastAttempts[template.id] ?? .distantPast) >= max(template.kind.isSystem ? 3 : 30, template.refreshInterval))
        }
        guard !due.isEmpty else { return }
        var requestIDs: [UUID: UUID] = [:]
        for template in due {
            let requestID = UUID()
            requestIDs[template.id] = requestID
            inFlight[template.id] = requestID
            lastAttempts[template.id] = now
        }
        isRefreshing = true
        await withTaskGroup(of: (UUID, Int, UUID, MetricReading).self) { group in
            for template in due {
                let generation = configurationGeneration[template.id, default: 0]
                let requestID = requestIDs[template.id]!
                group.addTask { @MainActor [self] in
                    let result = await self.fetch(template)
                    return (template.id, generation, requestID, result)
                }
            }
            for await (id, generation, requestID, result) in group {
                // An edited/reconnected metric may already have a newer request.
                // Completing an obsolete request must not clear the newer marker.
                guard inFlight[id] == requestID else { continue }
                inFlight[id] = nil
                guard let template = templates.first(where: { $0.id == id && $0.isEnabled }),
                      generation == configurationGeneration[id, default: 0] else { continue }
                // Keep the last successful value visible when a source temporarily fails.
                if result.state == .failed, var previous = readings[id], previous.updatedAt != nil,
                   previous.value != nil || previous.text != nil {
                    previous.state = .failed
                    previous.subtitle = result.subtitle
                    readings[id] = previous
                } else {
                    readings[id] = result
                }
                if result.state == .needsSetup || result.state == .unavailable {
                    histories[id] = nil
                }
                if template.kind != .manual, result.state == .ready, let value = result.value, value.isFinite {
                    var history = histories[id, default: []]
                    history.append(value)
                    histories[id] = Array(history.suffix(30))
                }
            }
        }
        isRefreshing = !inFlight.isEmpty
        lastRefresh = services.now()
    }

    private func fetch(_ template: MetricTemplate) async -> MetricReading {
        if template.kind == .codex, !codexConnected { return .setup("앱에서 ChatGPT 계정으로 로그인") }
        if template.kind == .claude, !claudeConnected { return .setup("앱에서 Claude 계정으로 로그인") }
        if template.kind == .claudeAPI, !claudeAPIConnected { return .setup("Claude Console을 연결해 주세요") }
        if template.kind == .manual {
            guard let value = template.manualValue else { return .setup("현재 값을 입력해 주세요") }
            let key = "manualUpdatedAt.\(template.id.uuidString)"
            let updatedAt = (defaults.object(forKey: key) as? Double).map(Date.init(timeIntervalSince1970:))
            return .init(value: value, limit: template.limit, subtitle: "수동 입력한 값", updatedAt: updatedAt)
        }
        if let readMetric = services.readMetric { return await readMetric(template) }
        if template.kind.isSystem { return system.read(template.kind) }
        switch template.kind {
        case .codex:
            return await codexSession.read()
        case .claude:
            return await claudeSession.read()
        case .claudeAPI:
            return await claudeConsoleSession.read()
        case .wakatime:
            do {
                let saved = KeychainStore.read(id: template.id)
                let credential = try saved ?? (useWakaTimeConfiguration ? WakaTimeCredential.readConfigured() : nil)
                guard let credential, !credential.isEmpty else {
                    return .setup("WakaTime 개인 OAuth 토큰을 연결하거나 기존 설정을 사용해 주세요")
                }
                return await WakaTimeProvider.fetch(apiKey: credential)
            } catch { return .error(error.localizedDescription) }
        case .http:
            guard !template.endpoint.isEmpty else { return .setup("API 연결을 설정해 주세요") }
            let token = KeychainStore.read(id: template.id)
            if !template.authHeader.isEmpty && (token?.isEmpty ?? true) { return .setup("API 키를 연결해 주세요") }
            do { return try await TemplateEngine.fetch(template, token: token) }
            catch StatusError.authentication(let message) { return .setup(message) }
            catch { return .error(error.localizedDescription) }
        default: return .error("지원하지 않는 데이터 소스입니다")
        }
    }

    func connect(_ kind: MetricKind) {
        guard [.codex, .claude, .claudeAPI].contains(kind) else { return }
        guard !clearingAccounts.contains(kind) else {
            notice = "연결 해제를 마무리하는 중입니다. 잠시 후 다시 연결해 주세요."
            return
        }
        accountGeneration[kind, default: 0] += 1
        onRequestLogin?(kind)
    }

    func connectionGeneration(for kind: MetricKind) -> Int {
        accountGeneration[kind, default: 0]
    }

    func session(for kind: MetricKind) -> WebAccountSession {
        kind == .codex ? codexSession : claudeSession
    }

    @discardableResult
    func completeConnection(_ kind: MetricKind, reading: MetricReading, expectedGeneration: Int? = nil) -> Bool {
        guard [.codex, .claude, .claudeAPI].contains(kind), !clearingAccounts.contains(kind),
              expectedGeneration == nil || expectedGeneration == connectionGeneration(for: kind),
              reading.state == .ready || reading.state == .unavailable else { return false }
        accountGeneration[kind, default: 0] += 1
        if kind == .codex { codexConnected = true; defaults.set(true, forKey: "web.codex.connected") }
        if kind == .claude { claudeConnected = true; defaults.set(true, forKey: "web.claude.connected") }
        if kind == .claudeAPI {
            claudeAPIConnected = true
            defaults.set(true, forKey: "web.claudeAPI.connected")
            if !templates.contains(where: { $0.kind == .claudeAPI }) {
                templates.append(.init(name: "Claude API 크레딧", subtitle: "Console API 조직 잔액", symbol: "creditcard", tint: "orange",
                                       kind: .claudeAPI, unit: "USD", limit: nil, refreshInterval: 300, link: "https://platform.claude.com/settings/billing"))
                persist()
            } else if let index = templates.firstIndex(where: { $0.kind == .claudeAPI }) {
                templates[index].isEnabled = true
                persist()
            }
        }
        for template in templates where template.kind == kind {
            invalidate(template.id)
            readings[template.id] = reading
            histories[template.id] = reading.value.map { [$0] }
            lastAttempts[template.id] = services.now()
        }
        return true
    }

    func disconnect(_ kind: MetricKind) {
        guard [.codex, .claude, .claudeAPI].contains(kind) else { return }
        accountGeneration[kind, default: 0] += 1
        if kind == .codex { codexConnected = false; defaults.set(false, forKey: "web.codex.connected") }
        if kind == .claude { claudeConnected = false; defaults.set(false, forKey: "web.claude.connected") }
        if kind == .claudeAPI { claudeAPIConnected = false; defaults.set(false, forKey: "web.claudeAPI.connected") }
        for template in templates where template.kind == kind {
            invalidate(template.id)
            readings[template.id] = .setup("연결이 해제되었습니다")
            histories[template.id] = nil
        }
        guard clearingAccounts.insert(kind).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            if let clearSession = services.clearSession { await clearSession(kind) }
            else if kind == .claudeAPI { await claudeConsoleSession.clear() }
            else { await session(for: kind).clear() }
            clearingAccounts.remove(kind)
        }
    }

    func save(_ template: MetricTemplate, token: String? = nil) throws {
        try TemplateEngine.validate(template)
        if let token, !token.isEmpty { try KeychainStore.save(token, id: template.id) }
        let previous = templates.first(where: { $0.id == template.id })
        if template.kind == .manual, template.manualValue != nil,
           previous?.kind != .manual || previous?.manualValue != template.manualValue {
            defaults.set(services.now().timeIntervalSince1970, forKey: "manualUpdatedAt.\(template.id.uuidString)")
        } else if template.kind != .manual || template.manualValue == nil {
            defaults.removeObject(forKey: "manualUpdatedAt.\(template.id.uuidString)")
        }
        if let index = templates.firstIndex(where: { $0.id == template.id }) { templates[index] = template }
        else { templates.append(template) }
        invalidate(template.id)
        readings[template.id] = nil
        histories[template.id] = nil
        persist()
        refreshAfterChange()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        templates[index].isEnabled = enabled
        invalidate(id)
        readings[id] = nil
        histories[id] = nil
        persist()
        refreshAfterChange()
    }

    func move(_ id: UUID, by offset: Int) {
        guard let index = templates.firstIndex(where: { $0.id == id }) else { return }
        let (destination, overflow) = index.addingReportingOverflow(offset)
        guard !overflow, templates.indices.contains(destination) else { return }
        templates.swapAt(index, destination)
        persist()
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard services.deleteToken(id) else {
            notice = "저장된 API 키를 삭제하지 못했습니다. 항목을 유지했습니다. 키체인 접근을 확인해 주세요."
            return false
        }
        invalidate(id)
        templates.removeAll { $0.id == id }
        readings[id] = nil
        histories[id] = nil
        defaults.removeObject(forKey: "manualUpdatedAt.\(id.uuidString)")
        persist()
        return true
    }

    @discardableResult
    func removeToken(_ id: UUID) -> Bool {
        guard services.deleteToken(id) else { return false }
        invalidate(id)
        readings[id] = .setup("API 키를 연결해 주세요")
        histories[id] = nil
        return true
    }

    func setMenuCPU(_ value: Bool) {
        showCPUInMenu = value
        defaults.set(value, forKey: "showCPUInMenu")
    }

    func setWakaTimeConfiguration(_ value: Bool) {
        useWakaTimeConfiguration = value
        defaults.set(value, forKey: "wakatime.useExistingConfiguration")
        for template in templates where template.kind == .wakatime {
            invalidate(template.id)
            readings[template.id] = nil
            histories[template.id] = nil
        }
        refreshAfterChange()
    }

    func setLoginItem(_ enabled: Bool) {
        guard let updateLoginItem = services.updateLoginItem else {
            launchAtLogin = false
            return
        }
        do {
            launchAtLogin = try updateLoginItem(enabled)
            if enabled && !launchAtLogin { notice = "시스템 설정 → 일반 → 로그인 항목에서 Mac Status를 허용해 주세요." }
        } catch { notice = "로그인 시 실행을 설정하지 못했습니다. 앱을 Applications 폴더에 옮긴 후 다시 시도해 주세요." }
    }

    private func persist() {
        do { defaults.set(try JSONEncoder().encode(templates), forKey: "metricTemplates") }
        catch { notice = "설정을 저장하지 못했습니다: \(error.localizedDescription)" }
    }

    private func invalidate(_ id: UUID) {
        configurationGeneration[id, default: 0] += 1
        inFlight[id] = nil
        lastAttempts[id] = nil
        isRefreshing = !inFlight.isEmpty
    }

    private func refreshAfterChange() {
        guard automaticallyRefresh else { return }
        Task { [weak self] in await self?.refresh() }
    }

    static func openAICostTemplate() -> MetricTemplate {
        .init(name: "OpenAI API 비용", subtitle: "이번 달 UTC · API 전용", symbol: "dollarsign.circle", tint: "mint", kind: .http, unit: "USD", limit: nil,
              endpoint: "https://api.openai.com/v1/organization/costs?start_time={{month_start_unix}}&end_time={{now_unix}}&limit=31",
              valuePath: "data.*.results.*.amount.value", aggregation: "sum", refreshInterval: 300, link: "https://platform.openai.com/usage")
    }

    static func wakaTimeTemplate() -> MetricTemplate {
        .init(name: "WakaTime", subtitle: "오늘 · 최근 7일 기록 시간", symbol: "clock", tint: "blue", kind: .wakatime,
              unit: "시간", limit: nil, refreshInterval: 300, link: WakaTimeProvider.dashboardURL.absoluteString)
    }

    static func openAITokensTemplate() -> MetricTemplate {
        .init(name: "OpenAI API 토큰", subtitle: "이번 달 UTC · 입력 토큰", symbol: "number.circle", tint: "blue", kind: .http, unit: "tokens", limit: nil,
              endpoint: "https://api.openai.com/v1/organization/usage/completions?start_time={{month_start_unix}}&end_time={{now_unix}}&bucket_width=1d&limit=31",
              valuePath: "data.*.results.*.input_tokens", aggregation: "sum", refreshInterval: 300, link: "https://platform.openai.com/usage")
    }

    static func anthropicCostTemplate() -> MetricTemplate {
        .init(name: "Anthropic API 비용", subtitle: "이번 달 UTC · Priority Tier 제외", symbol: "dollarsign.circle", tint: "orange", kind: .http, unit: "USD", limit: nil,
              endpoint: "https://api.anthropic.com/v1/organizations/cost_report?starting_at={{month_start_iso}}&bucket_width=1d&limit=31",
              valuePath: "data.*.results.*.amount", aggregation: "sum", multiplier: 0.01,
              headers: ["anthropic-version": "2023-06-01"], authHeader: "x-api-key", authPrefix: "", refreshInterval: 300, link: "https://platform.claude.com/usage")
    }

    static func anthropicTokensTemplate() -> MetricTemplate {
        .init(name: "Anthropic API 토큰", subtitle: "이번 달 UTC · 비캐시 입력만", symbol: "number.circle", tint: "orange", kind: .http, unit: "tokens", limit: nil,
              endpoint: "https://api.anthropic.com/v1/organizations/usage_report/messages?starting_at={{month_start_iso}}&bucket_width=1d&limit=31",
              valuePath: "data.*.results.*.uncached_input_tokens", aggregation: "sum", headers: ["anthropic-version": "2023-06-01"], authHeader: "x-api-key", authPrefix: "", refreshInterval: 300, link: "https://platform.claude.com/usage")
    }
}
