import Foundation
import Combine
import WebKit
import CoreFoundation
import AppKit

/// A separate, app-owned Claude Console login. It never imports the Claude chat
/// session or another browser's cookies and reads only API-organization billing.
@MainActor
final class ClaudeConsoleSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let webView: WKWebView
    @Published private(set) var status = "Claude Console에 로그인하면 API 크레딧을 확인합니다."
    @Published private(set) var isLoading = false
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isAuthenticatingPopup = false
    @Published private(set) var organizations: [WebOrganization] = []
    @Published var selectedOrganizationID: String? {
        didSet {
            guard oldValue != selectedOrganizationID, !applyingSelection else { return }
            invalidate()
            defaults.set(selectedOrganizationID, forKey: Self.organizationKey)
        }
    }

    private static let organizationKey = "web.claudeConsole.organization"
    private let defaults: UserDefaults
    private var prepared = false
    private var generation = 0
    private var applyingSelection = false
    private var readTask: Task<MetricReading, Never>?
    private var activeReadID: UUID?
    private var evaluation: WebAccountDeadline?
    private var clearTask: Task<Void, Never>?
    private var loadingObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var authenticationPopups: [ObjectIdentifier: AuthenticationPopup] = [:]
    private var suppressPopupReload = false

    private struct AuthenticationPopup {
        let webView: WKWebView
        let window: NSWindow
    }

    var pendingAuthenticationStatus: String? {
        if isAuthenticatingPopup { return "별도 인증 창에서 로그인을 완료해 주세요. 인증 창을 닫으면 Console 연결을 다시 확인합니다." }
        return Self.authenticationStatus(at: webView.url)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let key = "web.claudeConsole.storeIdentifier"
        let identifier = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? UUID()
        defaults.set(identifier.uuidString, forKey: key)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = LoginWebView(frame: .zero, configuration: configuration)
        selectedOrganizationID = defaults.string(forKey: Self.organizationKey)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        loadingObservation = webView.observe(\.isLoading, options: [.initial, .new]) { [weak self] view, _ in
            Task { @MainActor in self?.isLoading = view.isLoading }
        }
        urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.updateAuthenticationStage() }
        }
    }

    func prepare() {
        guard clearTask == nil, !prepared else { return }
        prepared = true
        isLoading = true
        webView.load(URLRequest(url: Self.billingURL))
    }

    func reload() {
        invalidate()
        guard clearTask == nil else { return }
        prepared = false
        prepare()
    }

    /// Return from an unfinished external OAuth page without deleting cookies
    /// or attempting to fill or submit any authentication form.
    func showLoginPage() {
        invalidate()
        guard clearTask == nil else { return }
        closeAuthenticationPopups()
        webView.stopLoading()
        prepared = true
        isLoading = true
        isAuthenticated = false
        status = "Console 로그인 페이지에서 이메일 로그인을 다시 진행할 수 있습니다."
        webView.load(URLRequest(url: Self.loginURL))
    }

    func read() async -> MetricReading {
        if let clearTask { await clearTask.value }
        guard !Task.isCancelled else { return .setup("Console 조회를 취소했습니다.") }
        if let readTask { return await readTask.value }
        let requestGeneration = generation
        let requestID = UUID()
        let selection = selectedOrganizationID ?? ""
        let task = Task { @MainActor [self] in await performRead(generation: requestGeneration, selection: selection) }
        readTask = task
        activeReadID = requestID
        var result = await task.value
        if activeReadID == requestID {
            readTask = nil
            activeReadID = nil
            if let pending = pendingAuthenticationStatus {
                isAuthenticated = false
                result = .setup(pending)
            }
            status = result.state == .ready ? "Claude API 크레딧을 확인했습니다." : result.subtitle
        }
        return result
    }

    func clear() async {
        if let clearTask { await clearTask.value; return }
        invalidate()
        closeAuthenticationPopups()
        isAuthenticated = false
        organizations = []
        applyingSelection = true
        selectedOrganizationID = nil
        applyingSelection = false
        defaults.removeObject(forKey: Self.organizationKey)
        prepared = false
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        status = "이 앱의 Claude Console 연결을 해제했습니다."
        let store = webView.configuration.websiteDataStore
        let task = Task { @MainActor [self] in
            let blankDeadline = Date().addingTimeInterval(3)
            while webView.isLoading, Date() < blankDeadline { try? await Task.sleep(nanoseconds: 50_000_000) }
            webView.stopLoading()
            await withCheckedContinuation { continuation in
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
            }
            clearTask = nil
        }
        clearTask = task
        await task.value
    }

    private func invalidate() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        activeReadID = nil
        evaluation?.cancel()
        evaluation = nil
    }

    private func performRead(generation expectedGeneration: Int, selection: String) async -> MetricReading {
        prepare()
        if let pending = pendingAuthenticationStatus {
            isAuthenticated = false
            return .setup(pending)
        }
        let pageDeadline = Date().addingTimeInterval(12)
        while webView.isLoading, Date() < pageDeadline, generation == expectedGeneration, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard generation == expectedGeneration, !Task.isCancelled else { return .setup("조회 조건이 변경되었습니다. 다시 확인해 주세요.") }
        if let pending = pendingAuthenticationStatus {
            isAuthenticated = false
            return .setup(pending)
        }
        guard !webView.isLoading else {
            isAuthenticated = false
            return .setup("로그인 창에서 Claude Console 계정 로그인을 완료해 주세요.")
        }
        do {
            let gate = WebAccountDeadline()
            evaluation = gate
            defer { if evaluation === gate { evaluation = nil } }
            let raw = try await gate.run(timeoutSeconds: 15) { completion in
                webView.callAsyncJavaScript(Self.script, arguments: ["selectedOrganization": selection], in: nil, in: WKContentWorld.page) {
                    completion($0.map { $0 as Any? })
                }
            }
            guard generation == expectedGeneration, !Task.isCancelled else {
                return .setup("로그인 또는 조회 조건이 변경되었습니다. 다시 확인해 주세요.")
            }
            if let pending = pendingAuthenticationStatus {
                isAuthenticated = false
                return .setup(pending)
            }
            guard let payload = raw as? [String: Any], let code = payload["status"] as? Int else {
                return .error("Claude Console 응답 형식을 확인할 수 없습니다.")
            }
            if payload["organizations"] != nil { organizations = WebAccountPolicy.organizations(from: payload["organizations"]) }
            if payload["authenticated"] as? Bool == true { isAuthenticated = true }
            if code == 401 {
                isAuthenticated = false
                return .setup("Claude Console 로그인 세션이 만료되었습니다. 앱의 Console 창에서 다시 로그인해 주세요.")
            }
            if code == 409 { return .setup("Console 로그인 창에서 API 조직을 선택해 주세요.") }
            if code == 422 { return .init(text: "API 조직 없음", subtitle: "현재 Console 계정에 API 조직이 없습니다.", state: .unavailable) }
            if let failure = WebAccountPolicy.failure(from: payload, status: code) { return failure.reading }
            guard code == 200 else { return .error("Claude Console의 크레딧 정보를 확인할 수 없습니다.") }
            let credits = try WebAccountPolicy.usageData(from: payload["body"])
            let spend = try? WebAccountPolicy.usageData(from: payload["spendBody"])
            let selectedID = payload["selectedOrganization"] as? String
            guard let selectedID, let organization = organizations.first(where: { $0.id == selectedID }) else {
                return .error("조회한 API 조직을 확인할 수 없습니다.")
            }
            let result = try ClaudeConsoleParser.parse(credits: credits, spend: spend, organization: organization.name)
            applyingSelection = true
            selectedOrganizationID = selectedID
            applyingSelection = false
            defaults.set(selectedID, forKey: Self.organizationKey)
            isAuthenticated = true
            return result
        } catch {
            guard generation == expectedGeneration, !Task.isCancelled else { return .setup("조회 조건이 변경되었습니다. 다시 확인해 주세요.") }
            if let pending = pendingAuthenticationStatus {
                isAuthenticated = false
                return .setup(pending)
            }
            // Raw WebKit errors may contain page URLs; never display them.
            return .error("Claude API 크레딧을 읽지 못했습니다. Console 로그인 상태와 네트워크를 확인해 주세요.")
        }
    }

    static let billingURL = URL(string: "https://platform.claude.com/settings/billing")!
    static let loginURL = URL(string: "https://platform.claude.com/login")!

    static func canRead(at url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https" && url.host?.lowercased() == "platform.claude.com" && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    static func isAuthenticationPage(_ url: URL?) -> Bool {
        guard let url else { return false }
        let auth: Set<String> = ["login", "logout", "auth", "oauth", "oauth2", "signin", "signup", "verify", "verification", "callback", "email-code"]
        return url.path.split(separator: "/").contains { auth.contains($0.lowercased()) }
    }

    static func authenticationStatus(at url: URL?) -> String? {
        if let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "accounts.google.com" {
            return "Google 로그인 완료를 기다리고 있습니다. 화면이 진행되지 않으면 이메일 로그인을 다시 시도해 주세요."
        }
        guard canRead(at: url), !isAuthenticationPage(url) else {
            return "Console 로그인 또는 이메일 인증을 완료하면 API 크레딧을 확인합니다. 로그인 중에는 사용량을 조회하지 않습니다."
        }
        return nil
    }

    private func updateAuthenticationStage() {
        guard let pending = pendingAuthenticationStatus else { return }
        isAuthenticated = false
        status = pending
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        invalidate()
        updateAuthenticationStage()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        updateAuthenticationStage()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        updateAuthenticationStage()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        if (error as NSError).code != NSURLErrorCancelled {
            prepared = false
            status = Self.authenticationStatus(at: webView.url) ?? "Console 페이지를 불러오지 못했습니다. 새로고침해 주세요."
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        invalidate()
        prepared = false
        isLoading = false
        status = "Console 로그인 페이지가 중단되었습니다. 새로고침해 주세요."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        decisionHandler(url.scheme?.lowercased() == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              Self.canOpenAuthenticationPopup(at: navigationAction.request.url),
              (webView === self.webView && Self.canRead(at: webView.url)) || authenticationPopups.values.contains(where: { $0.webView === webView }) else { return nil }
        // WebKit supplies a related configuration preserving window.opener and
        // the app-owned store. Loading this request in the parent destroys the
        // OAuth callback's original browsing context.
        let child = LoginWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        child.autoresizingMask = [.width, .height]
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Claude Console · 로그인 인증"
        window.contentView = child
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        authenticationPopups[ObjectIdentifier(window)] = AuthenticationPopup(webView: child, window: window)
        invalidate()
        isAuthenticatingPopup = true
        isAuthenticated = false
        updateAuthenticationStage()
        WindowFocus.present(window, firstResponder: child)
        return child
    }

    static func canOpenAuthenticationPopup(at url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    func webViewDidClose(_ webView: WKWebView) {
        authenticationPopups.values.first(where: { $0.webView === webView })?.window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let popup = authenticationPopups.removeValue(forKey: ObjectIdentifier(window)) else { return }
        popup.webView.stopLoading()
        popup.webView.navigationDelegate = nil
        popup.webView.uiDelegate = nil
        isAuthenticatingPopup = !authenticationPopups.isEmpty
        guard !isAuthenticatingPopup, !suppressPopupReload, clearTask == nil else { return }
        let expectedGeneration = generation
        // Let the opener's callback or postMessage run before restoring the
        // billing document using the newly authenticated app-owned cookies.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, self.generation == expectedGeneration, !self.isAuthenticatingPopup, self.clearTask == nil else { return }
            self.reload()
        }
    }

    private func closeAuthenticationPopups() {
        suppressPopupReload = true
        for popup in Array(authenticationPopups.values) { popup.window.close() }
        authenticationPopups.removeAll()
        isAuthenticatingPopup = false
        suppressPopupReload = false
    }

    static let script = WebAccountSession.scriptPrelude + #"""
    try {
        if (location.origin !== 'https://platform.claude.com') return {status:401};
        const response = await getJSON('/api/organizations');
        if (response.status !== 200 || response.issue) return failure(response);
        const list = Array.isArray(response.json) ? response.json : response.json && response.json.organizations;
        if (!Array.isArray(list)) return {status:498};
        const organizations = list.filter(item => item && Array.isArray(item.capabilities) && item.capabilities.includes('api'))
            .map(item => ({id:item.uuid || item.id, name:typeof item.name === 'string' ? item.name.slice(0,120) : 'API 조직'}))
            .filter(item => typeof item.id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(item.id));
        if (!organizations.length) return {status:422,organizations,authenticated:true};
        let selected = organizations.find(item => item.id === selectedOrganization);
        if (!selected && organizations.length === 1) selected = organizations[0];
        if (!selected) return {status:409,organizations,authenticated:true};
        const credits = await getJSON('/api/organizations/' + encodeURIComponent(selected.id) + '/prepaid/credits');
        if (credits.status !== 200 || credits.issue) return failure(credits,{organizations,authenticated:credits.status !== 401});
        const result = {status:200,body:JSON.stringify(credits.json),organizations,selectedOrganization:selected.id,authenticated:true};
        const optionalController = new AbortController();
        const optionalTimer = setTimeout(() => optionalController.abort(),2500);
        try {
            const spend = await getJSON('/api/organizations/' + encodeURIComponent(selected.id) + '/current_spend',{},optionalController.signal);
            if (spend.status === 200 && !spend.issue) result.spendBody = JSON.stringify(spend.json);
        } catch (_) { /* Billing balance remains available without spend. */ }
        finally { clearTimeout(optionalTimer); }
        return result;
    } catch (error) { return {status:error && error.name === 'AbortError' ? 408 : 0}; }
    finally { clearTimeout(timer); }
    """#
}

enum ClaudeConsoleParser {
    static func parse(credits: Data, spend: Data? = nil, organization: String? = nil, now: Date = Date()) throws -> MetricReading {
        guard credits.count <= 1_048_576,
              let root = try JSONSerialization.jsonObject(with: credits) as? [String: Any],
              let amount = minor(root["amount"]), let currency = root["currency"] as? String,
              currency == "USD" else { throw StatusError.message("Console API 크레딧 잔액 형식이 올바르지 않습니다.") }
        let balanceCredits = (root["balance"] as? [String: Any])?["credits"] as? [String: Any]
        let exponent: Int
        if let raw = balanceCredits?["exponent"] {
            guard let number = minor(raw), number <= 4 else { throw StatusError.message("Console 크레딧 단위를 확인할 수 없습니다.") }
            exponent = Int(number)
        } else { exponent = 2 }
        let scale = pow(10.0, Double(exponent))
        let balance = amount / scale
        var details: [MetricDetail] = [.init(label: "API 크레딧 총 잔액", value: money(balance), role: .credits,
                                           note: "Claude Console API 조직의 잔액입니다. Claude 구독 사용량·웹 추가 사용 크레딧과 별도입니다.")]
        var grants: [[String: Any]] = []
        for key in ["promo_tranches", "tranches"] {
            guard let raw = root[key], !(raw is NSNull) else { continue }
            guard let array = raw as? [[String: Any]] else { throw StatusError.message("Console 크레딧 내역 형식이 올바르지 않습니다.") }
            grants += array
        }
        var seen = Set<String>()
        for (index, grant) in grants.prefix(100).enumerated() {
            if let id = grant["id"] as? String, !seen.insert(id).inserted { continue }
            let expiry = (grant["expires_at"] as? String).flatMap(isoDate)
            if let expiry, expiry <= now { continue }
            guard let remaining = minor(grant["remaining_amount_minor_units"]),
                  let granted = minor(grant["granted_amount_minor_units"]),
                  remaining <= granted,
                  grant["currency"] as? String == currency else { continue }
            let program = grant["program_id"] as? String
            let label = program == "subscription_api_credit" ? "구독 제공 API 크레딧" : program == "api_credits" ? "구매 API 크레딧" : "기타 API 크레딧"
            let expiryText = expiry.map { " · 만료 " + $0.formatted(.iso8601.year().month().day().timeZone(separator: .omitted)) } ?? " · 만료일 미제공"
            details.append(.init(label: label + " \(index + 1)", value: "\(money(remaining / scale)) / \(money(granted / scale)) 남음",
                                 fraction: granted > 0 ? min(max((granted - remaining) / granted, 0), 1) : nil, role: .credits,
                                 note: "이 내역의 그래프는 사용 비율입니다. 총 잔액에 이미 포함되어 있으므로 합산하지 않습니다." + expiryText))
        }
        if let spend, spend.count <= 1_048_576,
           let object = try? JSONSerialization.jsonObject(with: spend) as? [String: Any], let amount = minor(object["amount"]) {
            details.append(.init(label: "이번 달 API 사용액 · UTC", value: money(amount / 100), note: "Console의 current_spend 응답입니다. 크레딧 잔액과 합산하지 않습니다."))
        } else {
            details.append(.init(label: "이번 달 API 사용액 · UTC", value: "정보 미제공", note: "사용액 조회에 실패해도 확인된 크레딧 잔액을 유지합니다."))
        }
        if let organization { details.append(.init(label: "API 조직", value: String(organization.prefix(120)))) }
        return .init(value: balance, subtitle: "Claude Console · API 크레딧 잔액", details: details)
    }

    private static func minor(_ raw: Any?) -> Double? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        return value.isFinite && value >= 0 && value.rounded() == value && value <= 9_007_199_254_740_991 ? value : nil
    }

    private static func money(_ value: Double) -> String { String(format: "USD %.2f", value) }
    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
