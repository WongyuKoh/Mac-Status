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
    @State private var validationAttempts = 0
    @State private var tokenIssue: String?
    @Environment(\.dismiss) private var dismiss

    init(store: StatusStore, original: MetricTemplate) {
        self.store = store
        self.original = original
        _template = State(initialValue: original)
        _limitText = State(initialValue: original.limit.map { String($0) } ?? "")
        _valueText = State(initialValue: original.manualValue.map { String($0) } ?? "")
        _multiplierText = State(initialValue: String(original.multiplier))
        if original.kind == .http && original.effectiveHTTPValueMode == .json {
            _selectedPage = State(initialValue: .connection)
        }
    }

    private var isAI: Bool { [.codex, .claude, .claudeAPI].contains(template.kind) }
    private var isWakaTime: Bool { template.kind == .wakatime }
    private var isJSONValue: Bool { template.kind == .http && template.effectiveHTTPValueMode == .json }
    private var isBuiltIn: Bool { template.kind.isSystem || isAI || isWakaTime }
    private var isExisting: Bool { store.templates.contains(where: { $0.id == original.id }) }
    private var editorTitle: String {
        if template.kind == .http || template.kind == .manual {
            return template.sourceTitle + (isExisting ? " 편집" : "")
        }
        return isExisting ? "항목 편집" : "새 항목 미리보기"
    }
    private var editorDescription: String {
        switch template.kind {
        case .manual: return "표시할 숫자와 단위·한도를 직접 입력합니다."
        case .http: return isJSONValue ? "API 주소와 JSON 경로로 값을 가져옵니다. 읽지 못하면 null로 표시합니다." : "API에서 값을 자동으로 가져올 연결을 설정합니다."
        default: return "표시 스타일과 데이터 연결을 설정합니다."
        }
    }

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
                    Text(editorTitle).font(.system(size: 20, weight: .semibold))
                    Text(editorDescription).font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                QuietIconButton(symbol: "xmark", label: "닫기") { dismiss() }
            }.padding(.horizontal, 24).padding(.vertical, compact ? 14 : 18)

            ScrollViewReader { scroll in
            ScrollView {
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                preview
                if pages.count > 1 { pageSelector }
                switch selectedPage {
                case .general: generalFields
                case .connection:
                    if isWakaTime { editorGroup("WakaTime 연결") { wakaTimeFields } }
                    else { editorGroup("API 연결", help: isJSONValue ? .jsonConnection : .connection) { httpConnectionFields } }
                case .authentication: editorGroup("인증 정보", help: .authentication) { authenticationFields }
                case .additional: additionalFields
                }
            }
            .padding(.horizontal, 24).padding(.bottom, compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            .onChange(of: validationAttempts) { _, _ in
                if let field = firstInvalidField {
                    DispatchQueue.main.async { scroll.scrollTo(field, anchor: .center) }
                }
            }
            }

            footer
        }
        .frame(width: 680, height: editorHeight)
        .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
        .acceptsWindowActivationClicks()
        .onChange(of: pages) { _, available in
            if !available.contains(selectedPage) { selectedPage = .general }
        }
        .onChange(of: token) { _, _ in revalidateTokenIssue() }
        .onChange(of: template.authHeader) { _, header in
            if header.isEmpty && !isWakaTime { tokenIssue = nil }
        }
    }

    private var pageSelector: some View {
        HStack(spacing: 4) {
            ForEach(pages, id: \.self) { page in
                EditorTabButton(title: page == .connection && isWakaTime ? "WakaTime 연결" : page.title,
                                symbol: page.symbol, isSelected: selectedPage == page) {
                    selectedPage = page
                }
                .overlay(alignment: .topTrailing) {
                    if fieldErrors.keys.contains(where: { pageForField($0) == page }) {
                        Text("*").font(.system(size: 14, weight: .bold))
                            .foregroundStyle(StatusInputFeedback.errorColor)
                            .padding(.trailing, 8).padding(.top, 3)
                            .accessibilityHidden(true).allowsHitTesting(false)
                    }
                }
                .accessibilityHint(fieldErrors.keys.contains(where: { pageForField($0) == page }) ? "확인할 입력 항목이 있습니다." : "")
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
                    field("이름", text: $template.name, id: .name)
                    field("설명", text: $template.subtitle, id: .subtitle)
                }
                HStack(alignment: .top, spacing: 14) {
                    field("아이콘 · SF Symbols", text: $template.symbol, id: .symbol)
                    StatusMenuPicker("포인트 색상", selection: $template.tint, options: [
                        ("mint", "민트"), ("blue", "블루"), ("purple", "라벤더"), ("orange", "오렌지"), ("yellow", "옐로")
                    ], symbol: "circle.fill", tint: Palette.tint(template.tint)).frame(width: 160)
                }
            }
            if !isBuiltIn && !isJSONValue {
                editorGroup(template.kind == .manual ? "숫자 입력" : "표시 단위와 한도") {
                    HStack(alignment: .top, spacing: 14) {
                        StatusTextField("단위", text: $template.unit, prompt: "%, GB, USD 등", error: fieldErrors[.unit]).id(TemplateField.unit)
                        StatusTextField("한도 · 선택", text: $limitText, prompt: "없으면 비워 두기", error: fieldErrors[.limit]).id(TemplateField.limit)
                        if template.kind == .manual { field("현재 값", text: $valueText, id: .manualValue) }
                    }
                }
            } else if isBuiltIn && !isWakaTime {
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
                StatusTextField("서비스 바로가기 · 선택", text: $template.link, prompt: "https://", error: fieldErrors[.link]).id(TemplateField.link)
                if !isAI && template.kind != .manual {
                    StatusMenuPicker("새로고침 간격", selection: $template.refreshInterval, options: [
                        (30.0, "30초"), (60.0, "1분"), (300.0, "5분"), (900.0, "15분"), (3600.0, "1시간")
                    ], fallbackTitle: template.refreshInterval.formatted(.number.precision(.fractionLength(0...1))) + "초", symbol: "clock", error: fieldErrors[.refreshInterval])
                    .frame(width: 160).id(TemplateField.refreshInterval)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
        if let message = error ?? testMessage {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: error == nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                Text(message).lineLimit(3).help(message).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { error = nil; testMessage = nil } label: {
                    Image(systemName: "xmark").padding(3).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("결과 안내 닫기")
            }
            .font(.system(size: 11))
            .foregroundStyle(error == nil ? Palette.mint : StatusInputFeedback.errorColor)
            .fixedSize(horizontal: false, vertical: true)
        }
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
            StatusMenuPicker("불러올 값", selection: Binding(
                get: { template.effectiveHTTPValueMode },
                set: { template.valueMode = $0 }
            ), options: [(.number, "숫자 통계"), (.json, "JSON 값 그대로")], symbol: "curlybraces")
            StatusTextField("API 주소 · GET", text: $template.endpoint, prompt: "예: https://example.com/api/usage?period=month", error: fieldErrors[.endpoint]).id(TemplateField.endpoint)
            if isJSONValue {
                StatusTextField("값 JSON 경로", text: $template.valuePath, prompt: "예: A.B.C 또는 data.0.value", error: fieldErrors[.valuePath]).id(TemplateField.valuePath)
                Text("A.B.C는 A 안의 B, 그 안의 C 값을 읽습니다. 연결 실패·경로 없음·빈 값(null)은 null로 표시합니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Text("API 키가 필요한 경우에만 ‘인증’ 탭에서 설정하세요.")
                    .font(.system(size: 11)).foregroundStyle(Palette.mint)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusTextField("값 JSON 경로", text: $template.valuePath, prompt: "예: A.B.C 또는 usage.current", error: fieldErrors[.valuePath]).id(TemplateField.valuePath)
                        StatusTextField("값 계산식", text: Binding(
                            get: { template.valueExpression ?? "" }, set: { template.valueExpression = $0 }
                        ), prompt: "예: value * 2", error: fieldErrors[.valueExpression]).id(TemplateField.valueExpression)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        StatusTextField("한도 JSON 경로", text: $template.limitPath, prompt: "예: usage.limit", error: fieldErrors[.limitPath]).id(TemplateField.limitPath)
                        StatusTextField("한도 계산식", text: Binding(
                            get: { template.limitExpression ?? "" }, set: { template.limitExpression = $0 }
                        ), prompt: "예: value / 1000",
                                        error: fieldErrors[.limitExpression])
                            .disabled(template.limitPath.isEmpty).id(TemplateField.limitExpression)
                    }
                }
                Text("value는 각 경로에서 읽은 숫자입니다. 계산식은 비워도 되며, + - * /와 괄호를 사용할 수 있습니다. 0으로 나누는 등 계산할 수 없으면 null로 표시합니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 14) {
                    StatusMenuPicker("여러 값 처리", selection: $template.aggregation, options: [("first", "단일 값"), ("sum", "합계")], symbol: "sum", error: fieldErrors[.aggregation]).id(TemplateField.aggregation)
                    StatusTextField("값 배율", text: $multiplierText, prompt: "센트 → 달러는 0.01", error: fieldErrors[.multiplier]).id(TemplateField.multiplier)
                }
                Text("A.B.C처럼 JSON의 숫자 위치를 점으로 구분합니다. 응답·경로 예시는 위의 ‘입력 예시 · 설정 방법’에서 확인하세요.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                Text("숫자 추출 → 계산식 → 값 배율 순서로 적용합니다. 한도 계산식은 한도 JSON 경로를 입력했을 때 사용합니다.")
                    .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var authenticationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isJSONValue {
                TrailingSwitchRow(title: "API 키 인증 사용", isOn: Binding(
                    get: { !template.authHeader.isEmpty },
                    set: { enabled in
                        template.authHeader = enabled ? "Authorization" : ""
                        template.authPrefix = enabled ? "Bearer " : ""
                    }
                ))
            }
            if !isJSONValue || !template.authHeader.isEmpty { keyAuthenticationFields }
            else {
                Text("인증 없이 조회합니다. API 주소와 JSON 경로만 입력하면 됩니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var keyAuthenticationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            StatusSecureField("API 키 · macOS 키체인에 저장", text: $token,
                              prompt: isExisting ? "변경할 때만 입력 · 기존 키 유지" : "서비스에서 발급받은 API 키만 입력", error: fieldErrors[.token]).id(TemplateField.token)
            if let requirement = APIProviderRequirement(endpoint: template.endpoint) {
                Text(requirement.notice)
                    .font(.system(size: 11)).foregroundStyle(Palette.tint("orange")).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .top, spacing: 14) {
                StatusTextField("인증 헤더", text: $template.authHeader, prompt: "예: Authorization 또는 x-api-key", error: fieldErrors[.authHeader]).id(TemplateField.authHeader)
                StatusTextField("키 앞에 붙일 값", text: $template.authPrefix, prompt: "예: Bearer 뒤에 공백 한 칸", error: fieldErrors[.authPrefix]).id(TemplateField.authPrefix)
            }
            Text("키는 항목을 저장할 때 이 Mac의 키체인에 저장합니다. 공개 API는 키·인증 헤더·접두어를 모두 비우세요.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            if !template.headers.isEmpty {
                Button("추가 헤더 \(template.headers.count)개 보기" + (fieldErrors[.headers] == nil ? "" : " *")) { showingHeaders = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .foregroundStyle(fieldErrors[.headers] == nil ? Palette.text : StatusInputFeedback.errorColor)
                    .id(TemplateField.headers)
                    .popover(isPresented: $showingHeaders) {
                        ScrollView {
                            Text(template.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n"))
                                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(18)
                        }.scrollIndicators(.never).frame(width: 420, height: 250).background(Palette.background)
                    }
                if let message = fieldErrors[.headers] {
                    Text(message).font(.system(size: 10)).foregroundStyle(StatusInputFeedback.errorColor)
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
            TrailingSwitchRow(title: "기존 설정의 개인 OAuth 토큰 사용", isOn: Binding(
                get: { store.useWakaTimeConfiguration }, set: { store.setWakaTimeConfiguration($0) }
            ))
            Text("~/.wakatime.cfg에 개인 OAuth 토큰이 있을 때만 사용합니다. 아래에 저장한 토큰을 우선하며, 추적용 API 키와 원본 설정은 변경하지 않습니다.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            StatusSecureField("개인 OAuth 토큰 · macOS 키체인에 저장", text: $token,
                              prompt: isExisting ? "변경할 때만 입력 · 기존 토큰 유지" : "waka_tok_…", error: fieldErrors[.token]).id(TemplateField.token)
            Text("조회에는 read_summaries 권한의 개인 OAuth 토큰이 필요합니다. 발급 페이지에서 토큰을 복사해 이 칸에 붙여넣고, ‘연결 테스트’ 후 저장하세요.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Button {
                NSWorkspace.shared.open(URL(string: "https://wakatime.com/oauth")!)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.right.square").accessibilityHidden(true)
                    Text("개인 OAuth 토큰 발급 페이지 열기")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Palette.background)
                .padding(.horizontal, 14)
                .frame(minHeight: 38)
                .background(Palette.mint, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain).fixedSize()
            .padding(.top, 4)
            .accessibilityLabel("WakaTime 개인 OAuth 토큰 발급 페이지 열기")
            .help("WakaTime 개인 OAuth 토큰 발급 페이지를 기본 브라우저에서 엽니다.")
        }
    }

    private func editorGroup<Content: View>(_ title: String, help: APIInputGuideTopic? = nil,
                                           @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                if let help { APIInputGuideButton(topic: help) }
            }
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func field(_ title: String, text: Binding<String>, id: TemplateField) -> some View {
        StatusTextField(title, text: text, error: fieldErrors[id]).id(id)
    }

    private var fieldErrors: [TemplateField: String] {
        var messages: [TemplateField: String] = [:]
        if validationAttempts > 0 {
            let draft = MetricEditorValidation.evaluate(template, limitText: limitText, valueText: valueText, multiplierText: multiplierText)
            for issue in draft.issues {
                messages[issue.field] = MetricEditorValidation.message(for: issue, in: draft.template)
            }
        }
        if let tokenIssue { messages[.token] = tokenIssue }
        return messages
    }

    private func pageForField(_ field: TemplateField) -> EditorPage {
        switch field {
        case .endpoint, .valuePath, .limitPath, .valueExpression, .limitExpression, .aggregation, .multiplier: return .connection
        case .authHeader, .authPrefix, .headers: return template.kind == .http ? .authentication : .general
        case .token: return isWakaTime ? .connection : .authentication
        case .link, .refreshInterval: return separatesAdditionalSettings ? .additional : .general
        default: return .general
        }
    }

    private var firstInvalidField: TemplateField? {
        let errors = fieldErrors
        let fieldOrder: [TemplateField] = [.name, .subtitle, .symbol, .unit, .limit, .manualValue, .link, .refreshInterval,
                                           .endpoint, .valuePath, .valueExpression, .limitPath, .limitExpression, .aggregation, .multiplier, .token, .authHeader, .authPrefix, .headers]
        for page in pages {
            if let field = fieldOrder.first(where: { pageForField($0) == page && errors[$0] != nil }) { return field }
        }
        return nil
    }

    private func revealValidation() {
        if let field = firstInvalidField { selectedPage = pageForField(field) }
    }

    private func validatedCandidate() -> MetricTemplate? {
        validationAttempts += 1
        error = nil; testMessage = nil; tokenIssue = nil
        let draft = MetricEditorValidation.evaluate(template, limitText: limitText, valueText: valueText, multiplierText: multiplierText)
        guard draft.issues.isEmpty else { revealValidation(); return nil }
        return draft.template
    }

    private func showTokenIssue(_ message: String) {
        tokenIssue = message
        revealValidation()
    }

    private func revalidateTokenIssue() {
        guard tokenIssue != nil else { return }
        if token.isEmpty {
            // An empty edit keeps the saved key. A connection test can report
            // a missing credential again if there is no saved/configured one.
            tokenIssue = nil
            return
        }
        _ = checkedEnteredToken(token)
    }

    private func checkedEnteredToken(_ value: String) -> String? {
        do {
            let secret = isWakaTime ? try WakaTimeCredential.checkedAccessToken(value) : value
            try TemplateEngine.validateCredential(secret)
            tokenIssue = nil
            return secret
        } catch {
            showTokenIssue(isWakaTime ? "waka_tok_로 시작하는 개인 OAuth 토큰을 입력해 주세요." : "키만 입력해 주세요. 앞뒤 공백과 줄바꿈은 빼 주세요.")
            return nil
        }
    }

    private func save() {
        guard let candidate = validatedCandidate() else { return }
        var secret = isWakaTime ? token.trimmingCharacters(in: .whitespacesAndNewlines) : token
        let usesKey = candidate.kind != .http || !candidate.authHeader.isEmpty
        if usesKey && !secret.isEmpty {
            guard let checked = checkedEnteredToken(secret) else { return }
            secret = checked
        }
        do {
            try store.save(candidate, token: usesKey && !secret.isEmpty ? secret : nil)
            dismiss()
        }
        catch { self.error = error.localizedDescription }
    }

    private func export() {
        guard let candidate = validatedCandidate() else { return }
        do {
            let json = try TemplateEngine.encode(candidate)
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(json, forType: .string)
            exported = true; error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func test() {
        guard let candidate = validatedCandidate() else { return }
        do {
            var credential: String? = candidate.kind == .http && candidate.authHeader.isEmpty
                ? nil : (token.isEmpty ? KeychainStore.read(id: candidate.id) : token)
            if candidate.kind == .http, !candidate.authHeader.isEmpty && (credential?.isEmpty ?? true) {
                showTokenIssue(isJSONValue ? "API 키를 입력하거나 인증 사용을 꺼 주세요." : "API 키를 입력해 주세요. 공개 API는 인증 헤더를 비우세요.")
                return
            }
            if isWakaTime {
                credential = credential?.trimmingCharacters(in: .whitespacesAndNewlines)
                if credential?.isEmpty != false, store.useWakaTimeConfiguration {
                    credential = try WakaTimeCredential.readConfigured()
                }
                guard let secret = credential, !secret.isEmpty else {
                    showTokenIssue("개인 OAuth 토큰을 발급받아 입력해 주세요.")
                    return
                }
                guard let checked = checkedEnteredToken(secret) else { return }
                credential = checked
            } else if let secret = credential {
                guard let checked = checkedEnteredToken(secret) else { return }
                credential = checked
            }
            testing = true; error = nil; testMessage = nil
            Task {
                do {
                    if candidate.kind == .wakatime {
                        let reading = await WakaTimeProvider.fetch(accessToken: credential!)
                        if reading.state == .ready {
                            testMessage = "연결 성공 · 오늘 \(MetricFormat.value(reading, template: candidate))"
                        } else { error = reading.subtitle }
                    } else {
                        let reading = try await TemplateEngine.fetch(candidate, token: credential)
                        if candidate.effectiveHTTPValueMode == .json {
                            let result = "현재 값: \(MetricFormat.value(reading, template: candidate))"
                            if reading.state == .failed { error = result + "\n" + reading.subtitle }
                            else { testMessage = result + (reading.state == .ready ? "" : "\n" + reading.subtitle) }
                        } else if reading.state == .ready {
                            testMessage = "연결 성공 · \(MetricFormat.value(reading, template: candidate)) \(candidate.unit)"
                        } else {
                            error = "현재 값: \(MetricFormat.value(reading, template: candidate))\n" + reading.subtitle
                        }
                    }
                } catch { self.error = error.localizedDescription }
                testing = false
            }
        } catch StatusError.authentication {
            showTokenIssue("waka_tok_로 시작하는 개인 OAuth 토큰을 입력해 주세요.")
        } catch { self.error = error.localizedDescription }
    }
}
