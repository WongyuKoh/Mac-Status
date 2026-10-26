import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class AccountLoginController: NSObject, NSWindowDelegate {
    private var windows: [MetricKind: NSWindow] = [:]
    private var sessions: [MetricKind: WebAccountSession] = [:]

    func present(kind: MetricKind, store: StatusStore) {
        if let existing = windows[kind], existing.isVisible {
            WindowFocus.present(existing)
            return
        }
        let session = store.session(for: kind)
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = kind == .codex ? "Mac Status · ChatGPT 계정 연결" : "Mac Status · Claude 계정 연결"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(Palette.background)
        window.minSize = NSSize(width: 820, height: 640)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentViewController = NSHostingController(rootView: AccountLoginView(kind: kind, session: session, connectionGeneration: { [weak store] in
            store?.connectionGeneration(for: kind) ?? -1
        }, onComplete: { [weak window, weak store] reading, generation in
            guard let window, window.isVisible, let store,
                  store.completeConnection(kind, reading: reading, expectedGeneration: generation) else { return false }
            window.close()
            return true
        }, onCancel: { [weak window] in window?.close() }))
        windows[kind] = window
        sessions[kind] = session
        session.prepare()
        window.center()
        WindowFocus.present(window, firstResponder: session.webView)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let kind = windows.first(where: { $0.value === window })?.key else { return }
        sessions[kind]?.closeAuthenticationPopups()
    }
}

private struct AccountWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

struct AuthenticationPopupContentView: View {
    let webView: WKWebView
    let kind: MetricKind
    @State private var currentURL: URL?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(Palette.mint)
                Text(currentURL?.host ?? "로그인 인증 창")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .lineLimit(1).textSelection(.enabled)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                QuietIconButton(symbol: "arrow.clockwise", label: "인증 페이지 새로고침") { webView.reload() }
            }.padding(.horizontal, 16).padding(.vertical, 8).background(Palette.surface)
            AccountWebView(webView: webView).frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 8) {
                if let notice = WebAccountPolicy.embeddedAuthenticationNotice(at: currentURL) {
                    Label(notice, systemImage: "key.fill")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tint("orange"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(WebAccountPolicy.authenticationStatus(at: currentURL, for: kind)
                     ?? "로그인을 마친 뒤 원래 연결 창에서 사용량을 확인합니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface)
        }
        .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
        .acceptsWindowActivationClicks()
        .onReceive(webView.publisher(for: \.url)) { currentURL = $0 }
        .onReceive(webView.publisher(for: \.isLoading)) { loading = $0 }
    }
}

private struct AccountLoginView: View {
    let kind: MetricKind
    @ObservedObject var session: WebAccountSession
    let connectionGeneration: () -> Int
    let onComplete: (MetricReading, Int) -> Bool
    let onCancel: () -> Void
    @State private var isChecking = false
    @State private var message: String?
    @State private var messageState: MetricState = .needsSetup
    @State private var checkTask: Task<Void, Never>?
    @State private var lastAutomaticURL: URL?

    private var providerName: String { kind == .codex ? "ChatGPT" : "Claude" }
    private var isOnServicePage: Bool { WebAccountPolicy.canReadUsage(at: session.webView.url, for: kind) }
    private var isAuthenticationPage: Bool { session.pendingAuthenticationStatus != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            HStack(spacing: 9) {
                Image(systemName: "globe").foregroundStyle(Palette.mint)
                Text(session.currentHost.isEmpty ? "\(providerName) 로그인 페이지 여는 중…" : session.currentHost)
                    .font(.system(size: 12, weight: .medium, design: .monospaced)).textSelection(.enabled)
                Spacer()
                if session.isLoading { ProgressView().controlSize(.small) }
                QuietIconButton(symbol: "arrow.left", label: "이전 페이지") { session.webView.goBack() }.disabled(!session.webView.canGoBack)
                QuietIconButton(symbol: "arrow.clockwise", label: "페이지 새로고침") { session.reload() }
                QuietIconButton(symbol: "chart.bar", label: "서비스 사용량 페이지") { session.showUsagePage() }
            }.padding(.horizontal, 22).padding(.vertical, 8).background(Palette.surface)
            AccountWebView(webView: session.webView).frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }.background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
            .acceptsWindowActivationClicks()
            .onDisappear { checkTask?.cancel(); session.closeAuthenticationPopups() }
            .onChange(of: session.isAuthenticatingPopup) { _, active in
                lastAutomaticURL = nil
                if active { checkTask?.cancel(); isChecking = false; message = nil }
            }
            .onChange(of: session.isLoading) { _, loading in
                if loading { message = nil; lastAutomaticURL = nil }
                else { automaticallyVerifyIfReady() }
            }
            .onReceive(session.webView.publisher(for: \.url).debounce(for: .milliseconds(650), scheduler: RunLoop.main)) { _ in
                automaticallyVerifyIfReady()
            }
            .onChange(of: session.selectedOrganizationID) { _, organization in
                if organization != nil { verify() }
            }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: kind == .codex ? "terminal.fill" : "sun.max.fill")
                .font(.system(size: 23)).foregroundStyle(Palette.tint(kind == .codex ? "mint" : "orange"))
            VStack(alignment: .leading, spacing: 6) {
                Text("\(providerName) 계정 연결").font(.system(size: 18, weight: .semibold))
                Text("로그인이 끝나면 사용량을 자동으로 확인합니다.").font(.system(size: 12)).foregroundStyle(Palette.muted)
            }
            Spacer()
            Label("추가 설치 없음", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Palette.mint)
        }.padding(22)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.organizations.isEmpty {
                HStack {
                    Text("워크스페이스").font(.system(size: 12))
                    Picker("워크스페이스", selection: $session.selectedOrganizationID) {
                        Text("통계를 볼 워크스페이스 선택").tag(String?.none)
                        ForEach(session.organizations) { org in Text(org.name).tag(Optional(org.id)) }
                    }.labelsHidden().frame(maxWidth: 420)
                    Spacer()
                }
            }
            if let limitation = WebAccountPolicy.embeddedAuthenticationNotice(at: session.webView.url) {
                Label(limitation, systemImage: "key.fill")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.tint("orange"))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.tint("orange").opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            }
            if let pending = session.pendingAuthenticationStatus {
                Label(pending, systemImage: session.isAuthenticatingPopup ? "macwindow.on.rectangle" : "person.crop.circle.badge.checkmark")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .claude && !session.isAuthenticatingPopup && WebAccountPolicy.canReadUsage(at: session.webView.url, for: .claude) {
                    Text("이메일 인증 링크를 다른 기기에서 열어 받은 코드를 이 창에 입력하면 앱의 로그인을 완료할 수 있습니다.")
                        .font(.system(size: 10)).foregroundStyle(Palette.mint).fixedSize(horizontal: false, vertical: true)
                }
            } else if let displayed = message ?? session.statusMessage, !displayed.isEmpty {
                Label(displayed, systemImage: messageState == .failed ? "exclamationmark.circle" : "info.circle").font(.system(size: 11))
                    .foregroundStyle(messageState == .failed ? Palette.tint("orange") : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !isOnServicePage && !session.currentHost.isEmpty && session.pendingAuthenticationStatus == nil {
                Text("로그인을 마치고 \(providerName) 페이지로 돌아오면 연결을 확인할 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.mint)
            }
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("로그인은 이 앱 전용 웹 세션에 저장됩니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Text("브라우저 로그인은 이 앱에 자동으로 연결되지 않습니다.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted.opacity(0.75))
                }
                Spacer()
                Button {
                    NSWorkspace.shared.open(WebAccountPolicy.usageURL(for: kind))
                } label: {
                    Label("브라우저에서 보기", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(StatusSecondaryButtonStyle())
                .help("기본 브라우저에서 서비스 사용량을 봅니다. 앱의 자동 조회 연결과는 별개입니다.")
                Button("취소") { checkTask?.cancel(); onCancel() }.buttonStyle(.borderless).font(.system(size: 12)).keyboardShortcut(.cancelAction)
                AccentButton(title: isChecking ? "확인 중…" : "연결 확인", symbol: "link") { verify() }.disabled(isChecking || session.isLoading || !isOnServicePage || isAuthenticationPage)
            }
        }.padding(20).background(Palette.surface)
    }

    private func automaticallyVerifyIfReady() {
        guard !isChecking, !session.isLoading, let url = session.webView.url,
              url != lastAutomaticURL, WebAccountPolicy.canReadUsage(at: url, for: kind) else { return }
        guard session.pendingAuthenticationStatus == nil else { return }
        lastAutomaticURL = url
        verify(automatic: true)
    }

    private func verify(automatic: Bool = false) {
        guard !isChecking, !isAuthenticationPage else { return }
        let generation = connectionGeneration()
        isChecking = true
        message = nil
        checkTask = Task { @MainActor in
            let reading = await session.read()
            guard !Task.isCancelled else { isChecking = false; return }
            isChecking = false
            messageState = reading.state
            if session.isAuthenticated && (reading.state == .ready || (!automatic && reading.state == .unavailable)) {
                if !onComplete(reading, generation) { message = "연결 상태가 변경되었습니다. 다시 확인해 주세요." }
            }
            else { message = reading.subtitle }
        }
    }
}
