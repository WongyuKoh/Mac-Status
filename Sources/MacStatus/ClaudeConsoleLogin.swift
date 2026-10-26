import AppKit
import Combine
import SwiftUI
import WebKit

@MainActor
final class ClaudeConsoleLoginController {
    private var window: NSWindow?

    func present(store: StatusStore) {
        if let window, window.isVisible { WindowFocus.present(window); return }
        let session = store.claudeConsoleSession
        let window = KeyboardWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 780),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Mac Status · Claude API Console 연결"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 640)
        window.backgroundColor = NSColor(Palette.background)
        window.contentViewController = NSHostingController(rootView: ClaudeConsoleLoginView(session: session,
            generation: { [weak store] in store?.connectionGeneration(for: .claudeAPI) ?? -1 },
            complete: { [weak store, weak window] reading, generation in
                guard window?.isVisible == true,
                      store?.completeConnection(.claudeAPI, reading: reading, expectedGeneration: generation) == true else { return false }
                window?.close()
                return true
            }, cancel: { [weak window] in window?.close() }))
        self.window = window
        session.prepare()
        window.center()
        WindowFocus.present(window, firstResponder: session.webView)
    }
}

private struct ConsoleWebView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

private struct ClaudeConsoleLoginView: View {
    @ObservedObject var session: ClaudeConsoleSession
    let generation: () -> Int
    let complete: (MetricReading, Int) -> Bool
    let cancel: () -> Void
    @State private var checking = false
    @State private var message: String?
    @State private var task: Task<Void, Never>?
    @State private var lastURL: URL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Claude API Console 연결").font(.system(size: 18, weight: .semibold))
                    Text("Console 계정의 API 크레딧 잔액을 확인합니다.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Text(session.webView.url?.host ?? "platform.claude.com").font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                Button("이메일 로그인으로 다시 시도") {
                    task?.cancel()
                    checking = false
                    message = nil
                    lastURL = nil
                    session.showLoginPage()
                }.buttonStyle(.borderless).font(.system(size: 11))
                QuietIconButton(symbol: "arrow.clockwise", label: "페이지 새로고침") { session.reload() }
            }.padding(20)
            ConsoleWebView(webView: session.webView)
            VStack(alignment: .leading, spacing: 10) {
                if !session.organizations.isEmpty {
                    Picker("API 조직", selection: $session.selectedOrganizationID) {
                        Text("조직 선택").tag(String?.none)
                        ForEach(session.organizations) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                Text(session.pendingAuthenticationStatus ?? message ?? session.status)
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("구독 웹 세션과 분리해 이 앱에 저장합니다.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                    Spacer()
                    Button("닫기") { task?.cancel(); cancel() }.buttonStyle(.borderless)
                    AccentButton(title: checking ? "확인 중…" : "연결 확인", symbol: "link") { verify() }
                        .disabled(checking || session.isLoading || session.isAuthenticatingPopup || !ClaudeConsoleSession.canRead(at: session.webView.url) || ClaudeConsoleSession.isAuthenticationPage(session.webView.url))
                }
            }.padding(18).background(Palette.surface)
        }.background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
            .acceptsWindowActivationClicks()
            .onDisappear { task?.cancel() }
            .onChange(of: session.isLoading) { _, loading in
                if loading { message = nil; lastURL = nil }
                else { verifyAutomatically() }
            }
            .onReceive(session.webView.publisher(for: \.url).debounce(for: .milliseconds(700), scheduler: RunLoop.main)) { url in
                if ClaudeConsoleSession.authenticationStatus(at: url) != nil { message = nil; lastURL = nil }
                verifyAutomatically()
            }
            .onChange(of: session.selectedOrganizationID) { _, selected in if selected != nil { verify() } }
            .onChange(of: session.isAuthenticatingPopup) { _, _ in message = nil; lastURL = nil }
    }

    private func verifyAutomatically() {
        guard !checking, !session.isLoading, !session.isAuthenticatingPopup, let url = session.webView.url,
              url.host == "platform.claude.com", url != lastURL,
              !["login", "signin", "auth", "verify"].contains(where: { url.path.lowercased().contains($0) }) else { return }
        lastURL = url
        verify()
    }

    private func verify() {
        guard !checking, !session.isAuthenticatingPopup, ClaudeConsoleSession.canRead(at: session.webView.url),
              !ClaudeConsoleSession.isAuthenticationPage(session.webView.url) else { return }
        let expected = generation()
        checking = true
        message = nil
        task = Task { @MainActor in
            let reading = await session.read()
            checking = false
            guard !Task.isCancelled else { return }
            if session.isAuthenticated, reading.state == .ready, reading.value != nil {
                if !complete(reading, expected) { message = "연결 상태가 바뀌었습니다. 다시 확인해 주세요." }
            } else { message = reading.subtitle }
        }
    }
}
