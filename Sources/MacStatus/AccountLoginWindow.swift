import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class AccountLoginController {
    private var windows: [MetricKind: NSWindow] = [:]

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
        window.contentViewController = NSHostingController(rootView: AccountLoginView(kind: kind, session: session, connectionGeneration: { [weak store] in
            store?.connectionGeneration(for: kind) ?? -1
        }, onComplete: { [weak window, weak store] reading, generation in
            guard let window, window.isVisible, let store,
                  store.completeConnection(kind, reading: reading, expectedGeneration: generation) else { return false }
            window.close()
            return true
        }, onCancel: { [weak window] in window?.close() }))
        windows[kind] = window
        session.prepare()
        window.center()
        WindowFocus.present(window, firstResponder: session.webView)
    }
}

private struct AccountWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
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
    private var isAuthenticationPage: Bool { WebAccountPolicy.isAuthenticationPage(at: session.webView.url, for: kind) }

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
            .onDisappear { checkTask?.cancel() }
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
            if let pending = WebAccountPolicy.authenticationStatus(at: session.webView.url, for: kind) {
                Label(pending, systemImage: "envelope.badge").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if kind == .claude {
                    Text("이메일 인증 링크를 다른 기기에서 열어 받은 코드를 이 창에 입력하면 앱의 로그인을 완료할 수 있습니다.")
                        .font(.system(size: 10)).foregroundStyle(Palette.mint).fixedSize(horizontal: false, vertical: true)
                }
            } else if let displayed = message ?? session.statusMessage, !displayed.isEmpty {
                Label(displayed, systemImage: messageState == .failed ? "exclamationmark.circle" : "info.circle").font(.system(size: 11))
                    .foregroundStyle(messageState == .failed ? Palette.tint("orange") : Palette.muted)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if !isOnServicePage && !session.currentHost.isEmpty {
                Text("로그인을 마치고 \(providerName) 페이지로 돌아오면 연결을 확인할 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.mint)
            }
            HStack(alignment: .center, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("로그인은 이 앱 전용 웹 세션에 저장됩니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    HStack(spacing: 8) {
                        Text("일부 소셜 로그인은 앱 내부에서 제한될 수 있습니다.").foregroundStyle(Palette.muted.opacity(0.75))
                        Button("브라우저에서 사용량 확인") { NSWorkspace.shared.open(WebAccountPolicy.usageURL(for: kind)) }
                            .buttonStyle(.borderless).foregroundStyle(Palette.mint)
                            .help("기본 브라우저에서 서비스 사용량 페이지를 엽니다. 브라우저 로그인은 이 앱과 공유되지 않습니다.")
                    }.font(.system(size: 10))
                }
                Spacer()
                Button("취소") { checkTask?.cancel(); onCancel() }.buttonStyle(.borderless).font(.system(size: 12)).keyboardShortcut(.cancelAction)
                AccentButton(title: isChecking ? "확인 중…" : "연결 확인", symbol: "link") { verify() }.disabled(isChecking || session.isLoading || !isOnServicePage || isAuthenticationPage)
            }
        }.padding(20).background(Palette.surface)
    }

    private func automaticallyVerifyIfReady() {
        guard !isChecking, !session.isLoading, let url = session.webView.url,
              url != lastAutomaticURL, WebAccountPolicy.canReadUsage(at: url, for: kind) else { return }
        guard !WebAccountPolicy.isAuthenticationPage(at: url, for: kind) else { return }
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
