import SwiftUI

struct MetricEditorView: View {
    @ObservedObject var store: StatusStore
    let original: MetricTemplate
    @State private var template: MetricTemplate
    @State private var token = ""
    @State private var limitText: String
    @State private var valueText: String
    @State private var multiplierText: String
    @State private var error: String?
    @State private var testMessage: String?
    @State private var testing = false
    @State private var exported = false
    @Environment(\.dismiss) private var dismiss

    init(store: StatusStore, original: MetricTemplate) {
        self.store = store
        self.original = original
        _template = State(initialValue: original)
        _limitText = State(initialValue: original.limit.map { String($0) } ?? "")
        _valueText = State(initialValue: original.manualValue.map { String($0) } ?? "")
        _multiplierText = State(initialValue: String(original.multiplier))
    }

    private var isAI: Bool { [.codex, .claude, .claudeAPI].contains(template.kind) }
    private var isWakaTime: Bool { template.kind == .wakatime }
    private var isBuiltIn: Bool { template.kind.isSystem || isAI || isWakaTime }
    private var isExisting: Bool { store.templates.contains(where: { $0.id == original.id }) }

    @State private var selectedPage = EditorPage.general
    @State private var showingHeaders = false

    private enum EditorPage: Hashable {
        case general, connection, authentication, additional
        var title: String {
            switch self {
            case .general: return "기본 정보"
            case .connection: return "API 연결"
            case .authentication: return "인증"
            case .additional: return "추가 설정"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .connection: return "network"
            case .authentication: return "lock.shield"
            case .additional: return "ellipsis.circle"
            }
        }
    }

    private var pages: [EditorPage] {
        let primary: [EditorPage]
        if template.kind == .http { primary = [.general, .connection, .authentication] }
        else if isWakaTime { primary = [.general, .connection] }
        else { primary = [.general] }
        return separatesAdditionalSettings ? primary + [.additional] : primary
    }

    private var editorHeight: CGFloat {
        max(1, min(800, (NSScreen.main?.visibleFrame.height ?? 960) - 56))
    }

    private var compact: Bool { editorHeight < 740 }
    private var separatesAdditionalSettings: Bool { editorHeight < 680 && !template.kind.isSystem && !isAI }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isExisting ? "항목 편집" : "새 항목 미리보기").font(.system(size: 20, weight: .semibold))
                    Text("표시 스타일과 데이터 연결을 설정합니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                QuietIconButton(symbol: "xmark", label: "닫기") { dismiss() }
            }.padding(.horizontal, 24).padding(.vertical, compact ? 14 : 18)

            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                preview
                if pages.count > 1 { pageSelector }
                switch selectedPage {
                case .general: generalFields
                case .connection:
                    if isWakaTime { editorGroup("WakaTime 연결") { wakaTimeFields } }
                    else { editorGroup("API 연결") { httpConnectionFields } }
                case .authentication: editorGroup("인증 정보") { authenticationFields }
                case .additional: additionalFields
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24).padding(.bottom, compact ? 16 : 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .frame(width: 680, height: editorHeight)
        .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
        .onChange(of: template.kind) { _, _ in
            selectedPage = .general
            error = nil
            testMessage = nil
        }
        .onChange(of: pages) { _, available in
            if !available.contains(selectedPage) { selectedPage = .general }
        }
        .alert(error == nil ? "설정 안내" : "설정을 확인해 주세요", isPresented: Binding(
            get: { error != nil || testMessage != nil },
            set: { if !$0 { error = nil; testMessage = nil } }
        )) {
            Button("확인") { error = nil; testMessage = nil }
        } message: { Text(error ?? testMessage ?? "") }
    }

    private var pageSelector: some View {
        HStack(spacing: 4) {
            ForEach(pages, id: \.self) { page in
                EditorTabButton(title: page == .connection && isWakaTime ? "WakaTime 연결" : page.title,
                                symbol: page.symbol, isSelected: selectedPage == page) {
                    selectedPage = page
                }
            }
        }
        .padding(3).background(Palette.surface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false))
        .accessibilityElement(children: .contain).accessibilityLabel("편집 화면")
    }

    private var generalFields: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            editorGroup("기본 정보") {
                HStack(alignment: .top, spacing: 14) {
                    field("이름", text: $template.name)
                    field("설명", text: $template.subtitle)
                }
                HStack(alignment: .top, spacing: 14) {
                    field("아이콘 · SF Symbols", text: $template.symbol)
                    StatusMenuPicker("포인트 색상", selection: $template.tint, options: [
                        ("mint", "민트"), ("blue", "블루"), ("purple", "라벤더"), ("orange", "오렌지"), ("yellow", "옐로")
                    ], symbol: "circle.fill", tint: Palette.tint(template.tint)).frame(width: 160)
                }
            }
            if !isBuiltIn {
                editorGroup("데이터 소스") {
                    StatusSourceSelector(selection: $template.kind)
                    HStack(alignment: .top, spacing: 14) {
                        StatusTextField("단위", text: $template.unit, prompt: "%, GB, USD 등")
                        StatusTextField("한도 · 선택", text: $limitText, prompt: "없으면 비워 두기")
                        if template.kind == .manual { field("현재 값", text: $valueText) }
                    }
                }
            } else if !isWakaTime {
                Text("\(template.kind.title) 데이터는 자동으로 측정합니다. 표시 이름과 색상을 바꿀 수 있습니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !template.kind.isSystem && !separatesAdditionalSettings { additionalFields }
        }
    }

    private var additionalFields: some View {
        editorGroup("추가 설정") {
            HStack(alignment: .top, spacing: 14) {
                StatusTextField("서비스 바로가기", text: $template.link, prompt: "https://")
                if !isAI {
                    StatusMenuPicker("새로고침 간격", selection: $template.refreshInterval, options: [
                        (30.0, "30초"), (60.0, "1분"), (300.0, "5분"), (900.0, "15분"), (3600.0, "1시간")
                    ], fallbackTitle: template.refreshInterval.formatted(.number.precision(.fractionLength(0...1))) + "초", symbol: "clock")
                    .frame(width: 160)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if !isBuiltIn {
                Button(exported ? "JSON 복사됨" : "JSON 복사") { export() }
                    .buttonStyle(StatusSecondaryButtonStyle())
            }
            if template.kind == .http || isWakaTime {
                Button(testing ? "연결 확인 중…" : "연결 테스트") { test() }
                    .buttonStyle(StatusSecondaryButtonStyle()).disabled(testing)
            }
            Spacer()
            Button("취소") { dismiss() }.buttonStyle(StatusSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            AccentButton(title: isExisting ? "변경 저장" : "항목 추가", symbol: "checkmark") { save() }.disabled(testing)
        }
        .padding(.horizontal, 24).padding(.vertical, compact ? 12 : 16)
        .background(Palette.surface)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }

    private var preview: some View {
        HStack(spacing: 12) {
            Image(systemName: template.symbol).font(.system(size: 22)).foregroundStyle(Palette.tint(template.tint)).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(template.name.isEmpty ? "새 항목" : template.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(template.subtitle.isEmpty ? "나만의 통계" : template.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            }
            Spacer(minLength: 10)
            if template.kind == .manual, let value = Double(valueText), value.isFinite {
                Text(MetricFormat.number(value, unit: template.unit)).font(.system(size: 23, weight: .medium, design: .rounded)).lineLimit(1)
                Text(template.unit).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
            } else {
                Text("미리보기").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Palette.muted)
            }
        }.padding(compact ? 12 : 14).cardSurface()
    }

    private var httpConnectionFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            StatusTextField("API 주소 · GET", text: $template.endpoint, prompt: "https://")
            Text("시간 변수: {{month_start_unix}}, {{now_unix}}, {{month_start_iso}}")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            field("값 JSON 경로", text: $template.valuePath)
            StatusTextField("한도 JSON 경로 · 선택", text: $template.limitPath, prompt: "예: usage.limit")
            HStack(alignment: .top, spacing: 14) {
                StatusMenuPicker("여러 값 처리", selection: $template.aggregation, options: [("first", "단일 값"), ("sum", "합계")], symbol: "sum")
                StatusTextField("값 배율", text: $multiplierText, prompt: "센트 → 달러는 0.01")
            }
            Text("숫자 위치는 usage.total처럼 점으로 구분합니다. 여러 숫자를 더하려면 ‘합계’를 선택하세요.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var authenticationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusSecureField("API 키 · macOS 키체인에 저장", text: $token,
                              prompt: isExisting ? "변경할 때만 입력 · 기존 키 유지" : "인증이 필요하면 입력하세요")
            if template.endpoint.contains("api.openai.com") || template.endpoint.contains("api.anthropic.com") {
                Text(template.endpoint.contains("api.openai.com")
                     ? "OpenAI 조직 Admin API 키가 필요합니다. ChatGPT·Codex 구독 사용량과 별도인 API 통계입니다."
                     : "Anthropic 조직 Admin API 키가 필요합니다. Claude 구독 한도와 별도인 API 통계입니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.tint("orange")).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 14) {
                StatusTextField("인증 헤더", text: $template.authHeader, prompt: "없으면 비워 두기")
                StatusTextField("키 앞에 붙일 값", text: $template.authPrefix, prompt: "예: Bearer 뒤에 공백")
            }
            Text("키는 이 Mac의 키체인에 저장합니다. 인증이 필요 없는 API는 키를 입력하지 않아도 됩니다.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if !template.headers.isEmpty {
                Button("추가 헤더 \(template.headers.count)개 보기") { showingHeaders = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .popover(isPresented: $showingHeaders) {
                        ScrollView {
                            Text(template.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        }.scrollIndicators(.never).frame(width: 420, height: 250).background(Palette.background)
                    }
            }
            if isExisting {
                Button("저장된 API 키 삭제") {
                    if store.removeToken(template.id) { token = ""; testMessage = "저장된 키를 삭제했습니다."; error = nil }
                    else { testMessage = nil; error = "키체인에서 API 키를 삭제하지 못했습니다. 키체인 접근 권한을 확인해 주세요." }
                }.buttonStyle(.bordered).controlSize(.small).font(.system(size: 11))
            }
        }
    }

    private var wakaTimeFields: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            Text("오늘과 최근 7일의 기록 시간, 프로젝트·언어별 통계를 읽습니다.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            TrailingSwitchRow(title: "이 Mac의 기존 WakaTime 설정 사용", isOn: Binding(
                get: { store.useWakaTimeConfiguration }, set: { store.setWakaTimeConfiguration($0) }
            ))
            Text("켜면 ~/.wakatime.cfg의 인증 정보를 읽어 조회합니다. 아래에 저장한 토큰이 있으면 토큰을 우선 사용합니다. 원본 설정은 변경하지 않습니다.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            StatusSecureField("개인 OAuth 토큰 · macOS 키체인에 저장", text: $token,
                              prompt: isExisting ? "변경할 때만 입력 · 기존 토큰 유지" : "waka_tok_…")
            Text("새 연결에는 read_summaries 권한의 개인 OAuth 토큰을 권장합니다. 기존 API 키의 조회 권한이 제한되면 토큰으로 연결하세요.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Link("WakaTime 연결 안내 열기", destination: URL(string: "https://wakatime.com/developers#authentication")!)
                .font(.system(size: 11))
            if isExisting {
                Button("저장한 토큰 삭제") {
                    if store.removeToken(template.id) {
                        token = ""; error = nil
                        testMessage = store.useWakaTimeConfiguration
                            ? "저장한 토큰을 삭제했습니다. 기존 WakaTime 설정을 통한 조회는 유지됩니다."
                            : "저장한 토큰을 삭제했습니다. 새 토큰을 연결할 때까지 조회를 멈춥니다."
                    } else { testMessage = nil; error = "키체인에서 토큰을 삭제하지 못했습니다. 키체인 접근 권한을 확인해 주세요." }
                }.buttonStyle(.bordered).controlSize(.small).font(.system(size: 11))
            }
        }
    }

    private func editorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        StatusTextField(title, text: text)
    }

    private func prepared() throws -> MetricTemplate {
        var value = template
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isBuiltIn {
            if limitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value.limit = nil }
            else {
                guard let limit = Double(limitText), limit.isFinite, limit > 0 else { throw StatusError.message("한도는 0보다 큰 숫자로 입력해 주세요.") }
                value.limit = limit
            }
            if value.kind == .manual {
                guard let number = Double(valueText), number.isFinite, number >= 0 else { throw StatusError.message("현재 값에 0 이상의 숫자를 입력해 주세요.") }
                value.manualValue = number
            }
            guard let multiplier = Double(multiplierText), multiplier.isFinite else { throw StatusError.message("값 배율에 유효한 숫자를 입력해 주세요.") }
            value.multiplier = multiplier
        }
        try TemplateEngine.validate(value)
        return value
    }

    private func save() {
        let secret = isWakaTime ? token.trimmingCharacters(in: .whitespacesAndNewlines) : token
        do { try store.save(prepared(), token: secret.isEmpty ? nil : secret); dismiss() }
        catch { self.error = error.localizedDescription }
    }

    private func export() {
        do {
            let json = try TemplateEngine.encode(prepared())
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(json, forType: .string)
            exported = true; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func test() {
        do {
            let candidate = try prepared()
            var credential = token.isEmpty ? KeychainStore.read(id: candidate.id) : token
            if isWakaTime {
                credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
                if credential?.isEmpty != false, store.useWakaTimeConfiguration {
                    credential = try WakaTimeCredential.readConfigured()
                }
                guard let secret = credential, !secret.isEmpty else {
                    throw StatusError.message("개인 OAuth 토큰을 입력하거나 기존 WakaTime 설정 사용을 켜 주세요.")
                }
                try TemplateEngine.validateCredential(secret)
            }
            testing = true; error = nil; testMessage = nil
            Task {
                do {
                    if candidate.kind == .wakatime {
                        let reading = await WakaTimeProvider.fetch(apiKey: credential!)
                        if reading.state == .ready {
                            testMessage = "연결 성공 · 오늘 \(MetricFormat.value(reading, template: candidate))"
                        } else { error = reading.subtitle }
                    } else {
                        let reading = try await TemplateEngine.fetch(candidate, token: credential)
                        testMessage = "연결 성공 · \(MetricFormat.value(reading, template: candidate)) \(candidate.unit)"
                    }
                } catch { self.error = error.localizedDescription }
                testing = false
            }
        } catch { self.error = error.localizedDescription }
    }
}
