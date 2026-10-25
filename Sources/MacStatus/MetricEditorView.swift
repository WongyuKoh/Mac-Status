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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(isExisting ? "항목 편집" : "새 항목 미리보기").font(.system(size: 20, weight: .semibold))
                    Text("표시 스타일과 데이터 연결을 설정합니다.").font(.system(size: 11)).foregroundStyle(Palette.muted)
                }
                Spacer()
                QuietIconButton(symbol: "xmark", label: "닫기") { dismiss() }
            }.padding(24)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    preview
                    editorGroup("기본 정보") {
                        field("이름", text: $template.name)
                        field("설명", text: $template.subtitle)
                        HStack(spacing: 14) {
                            field("아이콘 · SF Symbols", text: $template.symbol)
                            VStack(alignment: .leading, spacing: 7) {
                                Text("포인트 색상").font(.system(size: 11)).foregroundStyle(Palette.muted)
                                Picker("포인트 색상", selection: $template.tint) {
                                    Text("민트").tag("mint"); Text("블루").tag("blue"); Text("라벤더").tag("purple"); Text("오렌지").tag("orange"); Text("옐로").tag("yellow")
                                }.labelsHidden()
                            }.frame(width: 130)
                        }
                    }
                    if !isBuiltIn {
                        editorGroup("데이터 소스") {
                            Picker("소스", selection: $template.kind) {
                                Text("HTTP JSON API").tag(MetricKind.http)
                                Text("직접 입력").tag(MetricKind.manual)
                            }.pickerStyle(.segmented)
                            HStack(spacing: 14) { field("단위 · %, GB, USD, tokens 등", text: $template.unit); field("한도 · 없으면 비워 두기", text: $limitText) }
                            if template.kind == .manual { field("현재 값", text: $valueText) }
                            else { httpFields }
                        }
                    } else if isWakaTime {
                        editorGroup("WakaTime 연결") { wakaTimeFields }
                    } else {
                        Text("\(template.kind.title) 데이터는 자동으로 측정합니다. 표시 이름과 색상을 바꿀 수 있습니다.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted)
                    }
                    if !template.kind.isSystem {
                        editorGroup("추가 설정") {
                            field("서비스 바로가기 · https://", text: $template.link)
                            if !isAI {
                                HStack {
                                    Text("새로고침 간격").font(.system(size: 12))
                                    Spacer()
                                    Picker("새로고침 간격", selection: $template.refreshInterval) {
                                        Text("30초").tag(30.0); Text("1분").tag(60.0); Text("5분").tag(300.0); Text("15분").tag(900.0); Text("1시간").tag(3600.0)
                                    }.labelsHidden().frame(width: 130)
                                }
                            }
                        }
                    }
                    if let error { Text(error).font(.system(size: 11)).foregroundStyle(Palette.tint("orange")).textSelection(.enabled) }
                    if let testMessage { Label(testMessage, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(Palette.mint).textSelection(.enabled) }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }.scrollIndicators(.never)
            HStack(spacing: 12) {
                if !isBuiltIn {
                    Button(exported ? "JSON 복사됨" : "JSON 복사") { export() }.buttonStyle(.borderless).font(.system(size: 11))
                }
                if template.kind == .http || isWakaTime {
                    Button(testing ? "연결 확인 중…" : "연결 테스트") { test() }.buttonStyle(.borderless).font(.system(size: 11)).disabled(testing)
                }
                Spacer()
                Button("취소") { dismiss() }.buttonStyle(.borderless).font(.system(size: 12)).keyboardShortcut(.cancelAction)
                AccentButton(title: isExisting ? "변경 저장" : "항목 추가", symbol: "checkmark") { save() }.disabled(testing)
            }.padding(20).background(Palette.surface)
        }.frame(width: 580, height: 730).background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
    }

    private var preview: some View {
        HStack(spacing: 13) {
            Image(systemName: template.symbol).font(.system(size: 23)).foregroundStyle(Palette.tint(template.tint)).frame(width: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text(template.name.isEmpty ? "새 항목" : template.name).font(.system(size: 14, weight: .semibold))
                Text(template.subtitle.isEmpty ? "나만의 통계" : template.subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            Spacer()
            if template.kind == .manual, let value = Double(valueText), value.isFinite {
                Text(MetricFormat.number(value, unit: template.unit)).font(.system(size: 23, weight: .medium, design: .rounded))
                Text(template.unit).font(.system(size: 11)).foregroundStyle(Palette.muted)
            } else {
                Text("미리보기").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(Palette.muted)
            }
        }.padding(20).cardSurface()
    }

    private var httpFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("API URL · GET", text: $template.endpoint)
            Text("시간 변수: {{month_start_unix}}, {{now_unix}}, {{month_start_iso}}")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            field("값 JSON 경로 · 예: data.*.results.*.amount.value", text: $template.valuePath)
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("여러 값 처리").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    Picker("여러 값 처리", selection: $template.aggregation) { Text("단일 값").tag("first"); Text("합계").tag("sum") }.labelsHidden()
                }
                field("값 배율 · 센트 → 달러는 0.01", text: $multiplierText)
            }
            field("한도 JSON 경로 · 선택 사항", text: $template.limitPath)
            Divider().overlay(Palette.line)
            VStack(alignment: .leading, spacing: 7) {
                Text("API 키 · macOS 키체인에 저장").font(.system(size: 11)).foregroundStyle(Palette.muted)
                SecureField(isExisting ? "변경할 때만 입력 · 기존 키는 유지됩니다" : "인증이 필요하면 입력하세요", text: $token).textFieldStyle(.roundedBorder)
                if template.endpoint.contains("api.openai.com") {
                    Text("OpenAI 조직 Admin API 키가 필요합니다. ChatGPT·Codex 구독 사용량과 별도인 API 통계입니다.")
                        .font(.system(size: 10)).foregroundStyle(Palette.tint("orange")).fixedSize(horizontal: false, vertical: true)
                }
                if template.endpoint.contains("api.anthropic.com") {
                    Text("Anthropic 조직 Admin API 키가 필요합니다. Claude 구독 한도와 별도인 API 통계입니다.")
                        .font(.system(size: 10)).foregroundStyle(Palette.tint("orange")).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: 14) { field("인증 헤더 · 없으면 비워 두기", text: $template.authHeader); field("키 앞에 붙일 값 · 공백 포함", text: $template.authPrefix) }
            if !template.headers.isEmpty {
                Text("추가 헤더: " + template.headers.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
            if isExisting {
                Button("저장된 API 키 삭제") {
                    if store.removeToken(template.id) {
                        token = ""; testMessage = "저장된 키를 삭제했습니다."; error = nil
                    } else {
                        testMessage = nil; error = "키체인에서 API 키를 삭제하지 못했습니다. 키체인 접근 권한을 확인해 주세요."
                    }
                }
                    .buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
    }

    private var wakaTimeFields: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("오늘과 최근 7일의 기록 시간, 프로젝트·언어별 통계를 읽습니다.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            TrailingSwitchRow(title: "이 Mac의 기존 WakaTime 설정 사용", isOn: Binding(
                get: { store.useWakaTimeConfiguration },
                set: { store.setWakaTimeConfiguration($0) }
            ))
            Text("켜면 ~/.wakatime.cfg의 인증 정보를 읽어 조회합니다. 아래에 저장한 토큰이 있으면 토큰을 우선 사용합니다. 원본 설정은 변경하지 않습니다.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Text("개인 OAuth 토큰 · macOS 키체인에 저장").font(.system(size: 11)).foregroundStyle(Palette.muted)
            SecureField(isExisting ? "변경할 때만 입력 · 기존 토큰은 유지됩니다" : "waka_tok_…", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("새 연결에는 read_summaries 권한의 개인 OAuth 토큰을 권장합니다. 기존 API 키의 조회 권한이 제한되면 토큰으로 연결하세요.")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Link("WakaTime 연결 안내 열기", destination: URL(string: "https://wakatime.com/developers#authentication")!)
                .font(.system(size: 11))
            if isExisting {
                Button("저장한 토큰 삭제") {
                    if store.removeToken(template.id) {
                        token = ""; error = nil
                        testMessage = store.useWakaTimeConfiguration
                            ? "저장한 토큰을 삭제했습니다. 기존 WakaTime 설정을 통한 조회는 유지됩니다."
                            : "저장한 토큰을 삭제했습니다. 새 토큰을 연결할 때까지 조회를 멈춥니다."
                    } else {
                        testMessage = nil; error = "키체인에서 토큰을 삭제하지 못했습니다. 키체인 접근 권한을 확인해 주세요."
                    }
                }.buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func editorGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15) { Text(title).font(.system(size: 13, weight: .semibold)); content() }
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11)).foregroundStyle(Palette.muted)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }.frame(maxWidth: .infinity)
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
