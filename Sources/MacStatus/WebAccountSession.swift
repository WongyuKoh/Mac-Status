import Foundation
import Combine
import WebKit
import AppKit
import SwiftUI

struct WebOrganization: Identifiable, Equatable {
    let id: String
    let name: String
}

/// The app owns these website sessions. It never reads another browser's cookies,
/// CLI login files, passwords, or OAuth credentials from an installed tool.
@MainActor
final class WebAccountSession: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    let kind: MetricKind
    let webView: WKWebView
    @Published private(set) var isLoading = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var currentHost = ""
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isAuthenticatingPopup = false
    @Published private(set) var organizations: [WebOrganization] = []
    @Published var selectedOrganizationID: String? {
        didSet {
            guard oldValue != selectedOrganizationID, !applyingOrganization else { return }
            invalidateRead()
            statusMessage = nil
        }
    }

    private var prepared = false
    private var isClearing = false
    private var prepareAfterClear = false
    private var applyingOrganization = false
    private var generation = 0
    private var mainNavigationSequence = 0
    private var retryAfter: Date?
    private var readTask: Task<MetricReading, Never>?
    private var activeReadID: UUID?
    private var evaluation: WebAccountDeadline?
    private var clearTask: Task<Void, Never>?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var authenticationPopups: [ObjectIdentifier: AuthenticationPopup] = [:]
    private var popupRestoreTask: Task<Void, Never>?
    private var popupFailureStatus: String?
    private var suppressPopupReload = false
    private let defaults: UserDefaults
    private let presentAuthenticationWindow: @MainActor (NSWindow, WKWebView) -> Void

    private struct AuthenticationPopup {
        let webView: WKWebView
        let window: NSWindow
    }

    var pendingAuthenticationStatus: String? {
        if isAuthenticatingPopup {
            return popupFailureStatus ?? "별도 인증 창에서 로그인을 완료해 주세요. 인증 창을 닫으면 연결을 다시 확인합니다."
        }
        return WebAccountPolicy.authenticationStatus(at: webView.url, for: kind)
    }

    init(kind: MetricKind, defaults: UserDefaults = .standard, websiteDataStore: WKWebsiteDataStore? = nil,
         presentAuthenticationWindow: @escaping @MainActor (NSWindow, WKWebView) -> Void = { window, view in
             WindowFocus.present(window, firstResponder: view)
         }) {
        precondition(kind == .codex || kind == .claude)
        self.kind = kind
        self.defaults = defaults
        self.presentAuthenticationWindow = presentAuthenticationWindow
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore ?? WKWebsiteDataStore(forIdentifier: WebAccountPolicy.storeIdentifier(for: kind))
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = LoginWebView(frame: .zero, configuration: configuration)
        selectedOrganizationID = kind == .claude ? defaults.string(forKey: WebAccountPolicy.organizationKey) : nil
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        urlObservation = webView.observe(\.url, options: [.new, .initial]) { [weak self] view, _ in
            Task { @MainActor in
                self?.currentHost = view.url?.host ?? ""
                self?.updateAuthenticationStage()
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new, .initial]) { [weak self] view, _ in
            Task { @MainActor in self?.isLoading = view.isLoading }
        }
    }

    /// Loading a service's own page also restores this app's persisted session.
    /// It never fills fields or submits login forms; the user signs in normally.
    func prepare() {
        if isClearing { prepareAfterClear = true; return }
        guard !isAuthenticatingPopup else { return }
        guard !prepared else { return }
        prepared = true
        isLoading = true
        statusMessage = nil
        webView.load(URLRequest(url: WebAccountPolicy.usageURL(for: kind)))
    }

    func reload() {
        closeAuthenticationPopups()
        invalidateRead()
        statusMessage = nil
        if isClearing { prepareAfterClear = true; return }
        if !prepared { prepare() }
        else if webView.url != nil { webView.reload() }
        else { prepared = false; prepare() }
    }

    func showUsagePage() {
        closeAuthenticationPopups()
        invalidateRead()
        statusMessage = nil
        if isClearing { prepareAfterClear = true; return }
        prepared = true
        isLoading = true
        webView.load(URLRequest(url: WebAccountPolicy.usageURL(for: kind)))
    }

    /// Concurrent refreshes share one request, including the login window's
    /// explicit connection check and a scheduled refresh from the dashboard.
    func read() async -> MetricReading {
        if let clearTask { await clearTask.value }
        guard !Task.isCancelled else { return .setup("사용량 조회를 취소했습니다.") }
        if isAuthenticatingPopup, let pending = pendingAuthenticationStatus {
            isAuthenticated = false
            statusMessage = pending
            return .setup(pending)
        }
        if let readTask { return await readTask.value }
        let requestGeneration = generation
        let selection = selectedOrganizationID
        let requestID = UUID()
        let task = Task { @MainActor [self] in await performRead(generation: requestGeneration, organization: selection) }
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
            statusMessage = result.state == .ready ? "계정 연결을 확인했습니다." : result.subtitle
        }
        return result
    }

    func clear() async {
        if let clearTask { await clearTask.value; return }
        isClearing = true
        prepareAfterClear = false
        closeAuthenticationPopups()
        invalidateRead()
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        prepared = false
        isAuthenticated = false
        currentHost = ""
        organizations = []
        applyingOrganization = true
        selectedOrganizationID = nil
        applyingOrganization = false
        retryAfter = nil
        statusMessage = "이 앱의 계정 연결을 해제했습니다."
        if kind == .claude { defaults.removeObject(forKey: WebAccountPolicy.organizationKey) }
        let store = webView.configuration.websiteDataStore
        let task = Task { @MainActor [self] in
            // Let the local blank document replace the service document before
            // wiping data, so its old fetches/timers cannot restore cookies.
            let blankDeadline = Date().addingTimeInterval(3)
            while webView.isLoading, Date() < blankDeadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            webView.stopLoading()
            await withCheckedContinuation { continuation in
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    continuation.resume()
                }
            }
            isLoading = webView.isLoading
            isClearing = false
            clearTask = nil
            if prepareAfterClear { prepareAfterClear = false; prepare() }
        }
        clearTask = task
        await task.value
    }

    private func invalidateRead() {
        generation += 1
        readTask?.cancel()
        readTask = nil
        activeReadID = nil
        evaluation?.cancel()
        evaluation = nil
    }

    private func performRead(generation requestGeneration: Int, organization: String?) async -> MetricReading {
        guard !isAuthenticatingPopup else { return .setup(pendingAuthenticationStatus ?? "별도 인증 창에서 로그인을 완료해 주세요.") }
        if let retryAfter, retryAfter > Date() {
            return .error("서비스에서 조회를 제한했습니다. 약 \(max(1, Int(ceil(retryAfter.timeIntervalSinceNow / 60))))분 뒤 다시 확인합니다.")
        }
        prepare()
        if let pending = pendingAuthenticationStatus {
            isAuthenticated = false
            return .setup(pending)
        }
        // Restoring an existing session can require a short page navigation.
        // This is cooperative waiting on the main actor, never a blocking sleep.
        let deadline = Date().addingTimeInterval(12)
        while webView.isLoading, Date() < deadline, generation == requestGeneration, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard generation == requestGeneration, !Task.isCancelled else { return .setup("사용량 조회 조건이 변경되었습니다. 다시 확인해 주세요.") }
        if let pending = pendingAuthenticationStatus {
            isAuthenticated = false
            return .setup(pending)
        }
        guard !webView.isLoading else { return .setup("페이지를 불러오는 중입니다. 로그인 창에서 연결을 다시 확인해 주세요.") }
        guard WebAccountPolicy.canReadUsage(at: webView.url, for: kind) else {
            isAuthenticated = false
            return .setup("로그인 창에서 \(kind == .codex ? "ChatGPT" : "Claude") 계정으로 로그인해 주세요.")
        }

        do {
            let deadline = WebAccountDeadline()
            evaluation = deadline
            defer { if evaluation === deadline { evaluation = nil } }
            let raw = try await deadline.run(timeoutSeconds: 15) { completion in
                webView.callAsyncJavaScript(
                    kind == .codex ? Self.codexScript : Self.claudeScript,
                    arguments: ["selectedOrganization": organization ?? ""],
                    in: nil,
                    in: WKContentWorld.page
                ) { result in completion(result.map { $0 as Any? }) }
            }
            guard generation == requestGeneration, !Task.isCancelled else { return .setup("사용량 조회 조건이 변경되었습니다. 다시 확인해 주세요.") }
            if let pending = pendingAuthenticationStatus {
                isAuthenticated = false
                return .setup(pending)
            }
            // A page navigation invalidates the context. Do not accept a result
            // after the view has left the exact official service origin.
            guard WebAccountPolicy.canReadUsage(at: webView.url, for: kind), let payload = raw as? [String: Any],
                  let status = payload["status"] as? Int else {
                return .error("사용량 응답을 확인할 수 없습니다. 로그인 창에서 다시 확인해 주세요.")
            }
            if kind == .claude, payload["organizations"] != nil {
                organizations = WebAccountPolicy.organizations(from: payload["organizations"])
            }
            if payload["authenticated"] as? Bool == true { isAuthenticated = true }
            if let failure = WebAccountPolicy.failure(from: payload, status: status) {
                if failure.authenticationLost { isAuthenticated = false }
                if let delay = failure.retrySeconds { retryAfter = Date().addingTimeInterval(delay) }
                return failure.reading
            }
            switch status {
            case 200:
                let data = try WebAccountPolicy.usageData(from: payload["body"])
                let prepaidData = try? WebAccountPolicy.usageData(from: payload["prepaidBody"])
                let organizationData = try? WebAccountPolicy.usageData(from: payload["organizationBody"])
                let reading = try kind == .codex ? AIUsageParser.codexWeb(data) : AIUsageParser.claude(data, prepaidData: prepaidData, organizationData: organizationData)
                isAuthenticated = true
                if kind == .claude, let organization = payload["selectedOrganization"] as? String,
                   organizations.contains(where: { $0.id == organization }) {
                    applyingOrganization = true
                    selectedOrganizationID = organization
                    applyingOrganization = false
                    defaults.set(organization, forKey: WebAccountPolicy.organizationKey)
                }
                return reading
            case 409:
                isAuthenticated = true
                return .setup("로그인 창에서 사용량을 볼 워크스페이스를 선택해 주세요.")
            case 422:
                isAuthenticated = true
                return .init(text: "사용량 정보 없음", subtitle: "현재 계정에서 조회 가능한 워크스페이스가 없습니다.", state: .unavailable)
            default:
                return .error("사용량 응답 형식을 확인할 수 없습니다.")
            }
        } catch WebAccountDeadlineError.timedOut {
            guard generation == requestGeneration, !Task.isCancelled else { return .setup("사용량 조회 조건이 변경되었습니다. 다시 확인해 주세요.") }
            return .error("사용량 조회 시간이 초과되었습니다. 로그인 창에서 연결을 다시 확인해 주세요.")
        } catch WebAccountDeadlineError.navigationChanged {
            return .setup("로그인 페이지가 이동했습니다. 페이지가 열린 뒤 연결을 다시 확인해 주세요.")
        } catch {
            guard generation == requestGeneration, !Task.isCancelled else { return .setup("사용량 조회 조건이 변경되었습니다. 다시 확인해 주세요.") }
            // WebKit errors may contain page URLs, so never surface raw details.
            return .error("사용량을 읽지 못했습니다. 로그인 창에서 계정 연결을 다시 확인해 주세요.")
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else {
            if ownsAuthenticationPopup(webView) { popupFailureStatus = nil }
            return
        }
        mainNavigationSequence += 1
        evaluation?.cancel(error: WebAccountDeadlineError.navigationChanged)
        isLoading = webView.isLoading
        currentHost = webView.url?.host ?? ""
        updateAuthenticationStage()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isLoading = webView.isLoading
        currentHost = webView.url?.host ?? ""
        updateAuthenticationStage()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        isLoading = webView.isLoading
        currentHost = webView.url?.host ?? ""
        updateAuthenticationStage()
    }

    private func updateAuthenticationStage() {
        guard let pending = pendingAuthenticationStatus else { return }
        isAuthenticated = false
        statusMessage = pending
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error, in: webView)
    }

    private func navigationFailed(_ error: Error, in view: WKWebView) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        guard view === webView else {
            if ownsAuthenticationPopup(view) {
                popupFailureStatus = "인증 페이지를 불러오지 못했습니다. 인증 창을 닫은 뒤 다시 시도해 주세요."
                updateAuthenticationStage()
            }
            return
        }
        isLoading = webView.isLoading
        guard !webView.isLoading else { return }
        prepared = false
        statusMessage = "로그인 페이지를 불러오지 못했습니다. 네트워크를 확인한 뒤 새로고침해 주세요."
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else {
            if ownsAuthenticationPopup(webView) {
                popupFailureStatus = "인증 페이지가 중단되었습니다. 인증 창을 닫은 뒤 다시 시도해 주세요."
                updateAuthenticationStage()
            }
            return
        }
        closeAuthenticationPopups()
        invalidateRead()
        prepared = false
        isLoading = false
        statusMessage = "로그인 페이지가 중단되었습니다. 새로고침하면 이 앱에 저장된 세션으로 다시 연결합니다."
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // Authentication pages can navigate to HTTPS SSO providers normally.
        // Never launch custom schemes/apps or bypass a TLS challenge.
        let allowed = url.scheme?.lowercased() == "https" || url.absoluteString == "about:blank"
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        return makeAuthenticationPopup(configuration: configuration, opener: webView, requestURL: navigationAction.request.url)
    }

    /// Use WebKit's related configuration unchanged. It preserves the app-owned
    /// website store and window.opener relationship; the parent stays in place.
    func makeAuthenticationPopup(configuration: WKWebViewConfiguration, opener: WKWebView, requestURL: URL?) -> WKWebView? {
        guard !isClearing, clearTask == nil, WebAccountPolicy.canOpenAuthenticationPopup(at: requestURL),
              opener === webView || ownsAuthenticationPopup(opener) else { return nil }
        guard authenticationPopups.count < 3 else {
            popupFailureStatus = "인증 창이 여러 개 열려 있습니다. 열린 인증 창에서 로그인을 진행해 주세요."
            updateAuthenticationStage()
            return nil
        }
        popupRestoreTask?.cancel()
        popupRestoreTask = nil
        let child = LoginWebView(frame: .zero, configuration: configuration)
        child.navigationDelegate = self
        child.uiDelegate = self
        child.autoresizingMask = [.width, .height]
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 720),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(kind == .codex ? "ChatGPT" : "Claude") · 로그인 인증"
        window.contentViewController = NSHostingController(rootView: AuthenticationPopupContentView(webView: child, kind: kind))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        authenticationPopups[ObjectIdentifier(window)] = .init(webView: child, window: window)
        invalidateRead()
        popupFailureStatus = nil
        isAuthenticatingPopup = true
        isAuthenticated = false
        updateAuthenticationStage()
        presentAuthenticationWindow(window, child)
        return child
    }

    private func ownsAuthenticationPopup(_ view: WKWebView) -> Bool {
        authenticationPopups.values.contains { $0.webView === view }
    }

    func webViewDidClose(_ webView: WKWebView) {
        authenticationPopups.values.first { $0.webView === webView }?.window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let popup = authenticationPopups.removeValue(forKey: ObjectIdentifier(window)) else { return }
        popup.webView.stopLoading()
        popup.webView.navigationDelegate = nil
        popup.webView.uiDelegate = nil
        window.delegate = nil
        isAuthenticatingPopup = !authenticationPopups.isEmpty
        guard !isAuthenticatingPopup, !suppressPopupReload, !isClearing, clearTask == nil else { return }
        popupFailureStatus = nil
        let expectedGeneration = generation
        let parentURL = webView.url
        let parentNavigationSequence = mainNavigationSequence
        popupRestoreTask?.cancel()
        popupRestoreTask = Task { @MainActor [weak self] in
            // Allow the opener's OAuth callback/postMessage to finish first.
            do { try await Task.sleep(nanoseconds: 300_000_000) }
            catch { return }
            guard let self, !Task.isCancelled, self.generation == expectedGeneration,
                  !self.isAuthenticatingPopup, !self.isClearing, self.clearTask == nil else { return }
            self.popupRestoreTask = nil
            guard WebAccountPolicy.shouldRestoreUsageAfterAuthentication(initialURL: parentURL, currentURL: self.webView.url,
                      isLoading: self.webView.isLoading, navigationUnchanged: self.mainNavigationSequence == parentNavigationSequence,
                      kind: self.kind) else { return }
            self.reload()
        }
    }

    /// Cancel/completion/clear must not trigger a delayed hidden page reload.
    func closeAuthenticationPopups() {
        popupRestoreTask?.cancel()
        popupRestoreTask = nil
        suppressPopupReload = true
        for popup in Array(authenticationPopups.values) {
            popup.webView.stopLoading()
            popup.webView.navigationDelegate = nil
            popup.webView.uiDelegate = nil
            popup.window.close()
            popup.window.delegate = nil
        }
        authenticationPopups.removeAll()
        isAuthenticatingPopup = false
        popupFailureStatus = nil
        suppressPopupReload = false
    }

    /// All scripts are fixed application code. They inspect no input fields or
    /// DOM contents, and return only usage data and workspace display names.
    static let scriptPrelude = #"""
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 12000);
    const maximumBytes = 1048576;
    function failure(response, extra = {}) {
        const result = {status: response.status, ...extra};
        if (response.issue) result.issue = response.issue;
        if (Number.isFinite(response.retrySeconds)) result.retrySeconds = response.retrySeconds;
        return result;
    }
    async function getJSON(path, headers = {}, signal = controller.signal) {
        const response = await fetch(path, {method: 'GET', credentials: 'include', redirect: 'error', cache: 'no-store', signal, headers});
        const retryHeader = response.headers.get('Retry-After');
        const retrySeconds = retryHeader && /^\d+$/.test(retryHeader) ? Number(retryHeader) : undefined;
        const contentType = (response.headers.get('Content-Type') || '').toLowerCase();
        const isHTML = contentType.includes('text/html') || contentType.includes('application/xhtml');
        if (!response.ok && !isHTML) return {status: response.status, retrySeconds};
        if (Number(response.headers.get('Content-Length') || 0) > maximumBytes) return {status: 413};
        if (!response.body) return {status: response.ok ? 498 : response.status, issue: 'empty_response'};
        const reader = response.body.getReader();
        const chunks = [];
        let total = 0;
        while (true) {
            const item = await reader.read();
            if (item.done) break;
            total += item.value.byteLength;
            if (total > maximumBytes) { await reader.cancel(); return {status: 413}; }
            chunks.push(item.value);
        }
        const bytes = new Uint8Array(total);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
        const text = new TextDecoder().decode(bytes);
        if (isHTML || /^\s*<(?:!doctype\s+html|html)/i.test(text)) {
            const challenge = /cf-chl|challenge-platform|just a moment|attention required|verify you are human/i.test(text);
            return {status: response.status, issue: challenge ? 'browser_challenge' : 'html_response', retrySeconds};
        }
        if (!response.ok) return {status: response.status, retrySeconds};
        try { return {status: 200, json: JSON.parse(text)}; }
        catch (_) { return {status: 498, issue: 'invalid_json'}; }
    }
    """#

    static let codexScript = scriptPrelude + #"""
    try {
        if (location.origin !== 'https://chatgpt.com') return {status: 401};
        const session = await getJSON('/api/auth/session');
        if (session.status !== 200 || session.issue) return failure(session);
        const token = session.json && session.json.accessToken;
        if (typeof token !== 'string' || !token) return {status: 401};
        const usage = await getJSON('/backend-api/wham/usage', {Authorization: 'Bearer ' + token});
        // The session's access token stays in this local JavaScript scope.
        return usage.status === 200 && !usage.issue
            ? {status: 200, body: JSON.stringify(usage.json), authenticated: true}
            : failure(usage, {authenticated: usage.status !== 401});
    } catch (error) { return {status: error && error.name === 'AbortError' ? 408 : 0}; }
    finally { clearTimeout(timer); }
    """#

    static let claudeScript = scriptPrelude + #"""
    try {
        if (location.origin !== 'https://claude.ai') return {status: 401};
        const response = await getJSON('/api/organizations');
        if (response.status !== 200 || response.issue) return failure(response);
        const list = Array.isArray(response.json) ? response.json : response.json && response.json.organizations;
        if (!Array.isArray(list)) return {status: 498};
        const organizations = list.filter(item => item && typeof item === 'object')
            .filter(item => !Array.isArray(item.capabilities) || item.capabilities.includes('chat'))
            .map(item => ({id: item.uuid || item.id, name: item.name || '워크스페이스'}))
            .filter(item => typeof item.id === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(item.id) && typeof item.name === 'string');
        if (!organizations.length) return {status: 422, organizations, authenticated: true};
        let selected = organizations.find(item => item.id === selectedOrganization);
        if (!selected && organizations.length === 1) selected = organizations[0];
        if (!selected) return {status: 409, organizations, authenticated: true};
        const usage = await getJSON('/api/organizations/' + encodeURIComponent(selected.id) + '/usage');
        if (usage.status !== 200 || usage.issue) return failure(usage, {organizations, authenticated: usage.status !== 401});
        const result = {status: 200, body: JSON.stringify(usage.json), organizations, selectedOrganization: selected.id, authenticated: true};
        const selectedSource = list.find(item => item && (item.uuid || item.id) === selected.id) || {};
        const planCapabilities = new Set(['claude_free', 'claude_pro', 'claude_max', 'claude_max_5x', 'claude_max_20x', 'claude_team', 'claude_enterprise', 'claude_ultra']);
        function planFields(source) {
            const fields = {};
            for (const key of ['rate_limit_tier', 'subscription_type', 'billing_type']) {
                const value = source && source[key];
                if (typeof value === 'string' && /^[a-z0-9_ -]{1,80}$/i.test(value)) fields[key] = value;
            }
            if (source && Array.isArray(source.capabilities)) {
                fields.capabilities = source.capabilities.filter(value => typeof value === 'string' && planCapabilities.has(value.toLowerCase()))
                    .map(value => value.toLowerCase()).slice(0, 16);
            }
            return fields;
        }
        const plan = {organization: planFields(selectedSource)};
        result.organizationBody = JSON.stringify(plan);
        // Balance is optional; a restricted billing endpoint must never hide
        // successfully fetched session/weekly usage or invalidate this login.
        const optionalController = new AbortController();
        const optionalTimer = setTimeout(() => optionalController.abort(), 2500);
        const prepaidTask = (async () => {
            try {
                const prepaid = await getJSON('/api/organizations/' + encodeURIComponent(selected.id) + '/prepaid/credits', {}, optionalController.signal);
                if (prepaid.status === 200 && !prepaid.issue) result.prepaidBody = JSON.stringify(prepaid.json);
            } catch (_) { /* Normal usage remains available without prepaid data. */ }
        })();
        const accountTask = (async () => {
            try {
                const account = await getJSON('/api/account', {}, optionalController.signal);
                const memberships = account.status === 200 && !account.issue && account.json && account.json.memberships;
                if (!Array.isArray(memberships)) return;
                const membership = memberships.find(item => item && item.organization && item.organization.uuid === selected.id);
                if (!membership) return;
                plan.account = planFields(membership.organization);
                if (['team_standard', 'team_tier_1'].includes(membership.seat_tier)) plan.account.seat_tier = membership.seat_tier;
                // Account email, profile fields, IDs and tokens stay in this
                // JavaScript scope; only allowlisted subscription metadata leaves.
                result.organizationBody = JSON.stringify(plan);
            } catch (_) { /* Plan enrichment cannot fail successful quota. */ }
        })();
        try { await Promise.all([prepaidTask, accountTask]); }
        finally { clearTimeout(optionalTimer); }
        return result;
    } catch (error) { return {status: error && error.name === 'AbortError' ? 408 : 0}; }
    finally { clearTimeout(timer); }
    """#
}

enum WebAccountDeadlineError: Error { case timedOut, navigationChanged }

/// WebKit promises can stop completing when a document navigates or a web
/// process is suspended. This gate always resumes the native caller exactly
/// once, even when the JavaScript callback never arrives or arrives late.
@MainActor
final class WebAccountDeadline {
    typealias Completion = (Result<Any?, Error>) -> Void
    private var continuation: CheckedContinuation<Any?, Error>?
    private var completed = false
    private var started = false
    private var earlyResult: Result<Any?, Error>?
    private var timeoutTask: Task<Void, Never>?

    func run(timeoutSeconds: Double, start: (@escaping Completion) -> Void) async throws -> Any? {
        guard !started else { throw CancellationError() }
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let earlyResult { continuation.resume(with: earlyResult); return }
                self.continuation = continuation
                if Task.isCancelled { cancel(); return }
                let delay = timeoutSeconds.isFinite ? max(0.001, min(timeoutSeconds, 60)) : 15
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                    self?.finish(.failure(WebAccountDeadlineError.timedOut))
                }
                start { [weak self] result in
                    Task { @MainActor in self?.finish(result) }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel(error: Error = CancellationError()) { finish(.failure(error)) }

    private func finish(_ result: Result<Any?, Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        timeoutTask = nil
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        } else { earlyResult = result }
    }
}

struct WebAccountFailure {
    var reading: MetricReading
    var authenticationLost = false
    var retrySeconds: Double? = nil
}

/// Pure policy helpers keep origin and payload checks testable without opening
/// a browser, sending a network request, or requiring a real account.
enum WebAccountPolicy {
    static let organizationKey = "webAccount.claude.organization"

    static func storeIdentifier(for kind: MetricKind) -> UUID {
        UUID(uuidString: kind == .codex ? "47B0CB1D-A97E-431E-8E0F-90906A2B19A1" : "75CA9657-7EB8-48CC-A3C3-7B78824815DC")!
    }

    static func usageURL(for kind: MetricKind) -> URL {
        URL(string: kind == .codex ? "https://chatgpt.com/codex/settings/usage" : "https://claude.ai/settings/usage")!
    }

    static func canReadUsage(at url: URL?, for kind: MetricKind) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return url.host?.lowercased() == (kind == .codex ? "chatgpt.com" : "claude.ai")
    }

    static func canOpenAuthenticationPopup(at url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" { return true }
        return url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
    }

    static func embeddedAuthenticationNotice(at url: URL?) -> String? {
        guard let url, url.scheme?.lowercased() == "https", url.host?.lowercased() == "accounts.google.com",
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        return "Google 로그인·패스키는 이 앱 안에서 제한될 수 있습니다."
    }

    static func shouldRestoreUsageAfterAuthentication(initialURL: URL?, currentURL: URL?, isLoading: Bool,
                                                     navigationUnchanged: Bool, kind: MetricKind) -> Bool {
        guard !isLoading, navigationUnchanged, let currentURL, initialURL == currentURL,
              canReadUsage(at: currentURL, for: kind), !isAuthenticationPage(at: currentURL, for: kind) else { return false }
        return true
    }

    /// Authentication stage detection is deliberately independent of the query
    /// string. A login page's returnTo=/settings/usage does not mean signed in;
    /// a usage page's returnTo=/login does not mean signed out. Exact-origin
    /// validation is a separate guard before any usage script can run.
    static func isAuthenticationPage(at url: URL?, for kind: MetricKind) -> Bool {
        guard let url, kind == .codex || kind == .claude else { return false }
        if embeddedAuthenticationNotice(at: url) != nil { return true }
        let common: Set<String> = [
            "login", "logout", "auth", "oauth", "oauth2", "signup", "signin", "sign-in", "sign-up", "log-in", "log-out",
            "verify", "verification", "callback", "magic-link", "magic_link", "verify-email", "email-verification", "email-code"
        ]
        let provider: Set<String> = kind == .codex
            ? ["log-in-or-create-account", "create-account", "login-password", "phone-verification"]
            : ["confirm-email", "verify-code"]
        let components = url.path.split(separator: "/").map { $0.lowercased() }
        return components.contains { common.contains($0) || provider.contains($0) }
    }

    static func authenticationStatus(at url: URL?, for kind: MetricKind) -> String? {
        guard isAuthenticationPage(at: url, for: kind) else { return nil }
        if embeddedAuthenticationNotice(at: url) != nil {
            return "패스키 인증 창이 뜨지 않으면 ‘다른 방법 시도’에서 다른 인증 수단을 선택하세요."
        }
        return "로그인 또는 이메일 인증을 완료하면 사용량을 자동으로 확인합니다. 인증을 진행하는 동안에는 사용량을 조회하지 않습니다."
    }

    static func organizations(from value: Any?) -> [WebOrganization] {
        guard let objects = value as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return objects.prefix(100).compactMap { item in
            guard let id = item["id"] as? String, UUID(uuidString: id) != nil,
                  let name = item["name"] as? String, seen.insert(id).inserted else { return nil }
            return WebOrganization(id: id, name: String(name.prefix(120)))
        }
    }

    static func usageData(from value: Any?) throws -> Data {
        guard let body = value as? String, let data = body.data(using: .utf8), data.count <= 1_048_576 else {
            throw StatusError.message("사용량 응답 형식을 확인할 수 없습니다.")
        }
        return data
    }

    static func failure(from payload: [String: Any], status: Int) -> WebAccountFailure? {
        if status == 429 {
            let supplied = (payload["retrySeconds"] as? NSNumber)?.doubleValue ?? 300
            let seconds = supplied.isFinite ? min(3600, max(300, supplied)) : 300
            return .init(reading: .error("서비스에서 조회를 제한했습니다. \(Int(ceil(seconds / 60)))분 뒤 자동으로 다시 확인합니다."), retrySeconds: seconds)
        }
        if status == 401 {
            return .init(reading: .setup("로그인 세션이 없습니다. 로그인 창에서 계정으로 로그인해 주세요."), authenticationLost: true)
        }
        let issue = payload["issue"] as? String
        if issue == "browser_challenge" {
            return .init(reading: .error("서비스의 브라우저 확인이 필요합니다. 로그인 창에서 확인을 완료해 주세요. 계속 차단되면 앱 내부 로그인이 제한된 경우입니다."))
        }
        if issue == "html_response" {
            return .init(reading: .error("사용량 API 대신 웹 페이지가 반환되었습니다. 로그인 창의 ‘사용량 페이지’에서 계정 상태를 확인해 주세요."))
        }
        if status == 403 {
            let message = payload["authenticated"] as? Bool == true
                ? "계정은 로그인되었지만 이 워크스페이스의 사용량 조회가 허용되지 않았습니다. 계정과 조회 권한을 확인해 주세요."
                : "서비스가 이 앱의 사용량 조회를 허용하지 않았습니다. 로그인 창에서 계정과 접근 권한을 확인해 주세요."
            return .init(reading: .error(message))
        }
        switch status {
        case 200 where issue == nil, 409, 422: return nil
        case 200: return .init(reading: .error("사용량 응답이 비어 있거나 JSON 형식이 아닙니다. 서비스의 사용량 페이지에서 직접 확인해 주세요."))
        case 408: return .init(reading: .error("사용량 조회 시간이 초과되었습니다. 네트워크와 로그인 상태를 확인해 주세요."))
        case 413: return .init(reading: .error("사용량 응답이 예상보다 큽니다. 서비스 페이지에서 직접 확인해 주세요."))
        case 498: return .init(reading: .error("사용량 응답 형식이 변경되었습니다. 서비스 페이지에서 직접 확인해 주세요."))
        case 404: return .init(reading: .error("사용량 조회 경로가 변경되었거나 제공되지 않습니다. ‘사용량 페이지’에서 직접 확인해 주세요."))
        case 0: return .init(reading: .error("사용량 서버에 연결할 수 없습니다. 네트워크와 로그인 창을 확인해 주세요."))
        default: return .init(reading: .error("사용량 조회에 실패했습니다. (HTTP \(status))"))
        }
    }
}
