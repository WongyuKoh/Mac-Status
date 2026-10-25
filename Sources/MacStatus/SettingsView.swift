import SwiftUI

struct SettingsView: View {
    @ObservedObject var store: StatusStore
    @State var selectedTab: Int = 0
    @State private var editing: MetricTemplate?
    @State private var removal: MetricTemplate?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(["나의 항목", "새 항목 만들기", "앱 설정"][selectedTab]).font(.system(size: 25, weight: .semibold))
                        Text(["자주 보는 숫자만, 원하는 순서로.", "같은 스타일, 무한한 가능성.", "Mac Status를 나에게 맞추세요."][selectedTab]).font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    if selectedTab == 0 { AccentButton(title: "항목 추가", symbol: "plus") { selectedTab = 1 } }
                }.padding(30)
                ScrollView {
                    Group {
                        switch selectedTab {
                        case 0: metricList
                        case 1: TemplateBuilderView(onEdit: { editing = $0 })
                        default: generalSettings
                        }
                    }.padding(.horizontal, 30).padding(.bottom, 30)
                }.scrollIndicators(.never)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 840, idealWidth: 900, minHeight: 650, idealHeight: 730)
        .background(Palette.background).foregroundStyle(Palette.text).preferredColorScheme(.dark)
        .sheet(item: $editing) { template in MetricEditorView(store: store, original: template) }
        .alert("항목을 삭제할까요?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })) {
            Button("취소", role: .cancel) { removal = nil }
            Button("삭제", role: .destructive) { if let removal { store.remove(removal.id) }; removal = nil }
        } message: { Text("이 항목의 설정과 저장된 API 키가 삭제됩니다.") }
        .alert("설정 안내", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } })) {
            Button("확인") { store.notice = nil }
        } message: { Text(store.notice ?? "") }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").foregroundStyle(Palette.mint)
                Text("Mac Status").font(.system(size: 15, weight: .semibold))
            }.padding(.bottom, 34).padding(.top, 15)
            navItem("나의 항목", icon: "square.grid.2x2", tab: 0)
            navItem("새 항목 만들기", icon: "plus.circle", tab: 1)
            navItem("앱 설정", icon: "slider.horizontal.3", tab: 2)
            Spacer()
            Text("VERSION \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.1")").font(.system(size: 8, design: .monospaced)).tracking(1).foregroundStyle(Palette.muted.opacity(0.5))
        }.padding(20).frame(width: 174).background(Palette.surface.opacity(0.5))
    }

    private func navItem(_ title: String, icon: String, tab: Int) -> some View {
        Button { selectedTab = tab } label: {
            Label(title, systemImage: icon).font(.system(size: 12, weight: selectedTab == tab ? .semibold : .regular))
                .foregroundStyle(selectedTab == tab ? Palette.mint : Palette.muted)
                .frame(maxWidth: .infinity, alignment: .leading).padding(11)
                .background(selectedTab == tab ? Palette.mint.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var metricList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(store.templates.count)개 항목 · \(store.visibleTemplates.count)개 표시 중").font(.system(size: 11)).foregroundStyle(Palette.muted)
            ForEach(store.templates) { template in
                HStack(spacing: 12) {
                    Image(systemName: template.symbol).font(.system(size: 19)).foregroundStyle(Palette.tint(template.tint))
                        .frame(width: 38, height: 38).background(Palette.tint(template.tint).opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(template.name).font(.system(size: 13, weight: .medium))
                        Text(template.kind.title + " · " + store.reading(for: template).subtitle).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 5)
                    QuietIconButton(symbol: "arrow.up", label: "앞으로 이동") { store.move(template.id, by: -1) }
                        .disabled(store.templates.first?.id == template.id)
                    QuietIconButton(symbol: "arrow.down", label: "뒤로 이동") { store.move(template.id, by: 1) }
                        .disabled(store.templates.last?.id == template.id)
                    QuietIconButton(symbol: "pencil", label: "\(template.name) 편집") { editing = template }
                    QuietIconButton(symbol: "trash", label: "\(template.name) 삭제") { removal = template }
                    Toggle("표시", isOn: Binding(get: { store.templates.first(where: { $0.id == template.id })?.isEnabled ?? false }, set: { store.setEnabled(template.id, $0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small).tint(Palette.mint).help("상단바에 표시")
                }.padding(13).cardSurface(radius: 12)
            }
            Label("순서는 각 섹션 안에서 적용됩니다. 숨긴 항목은 자동 갱신도 멈춥니다.", systemImage: "info.circle")
                .font(.system(size: 10)).foregroundStyle(Palette.muted).padding(.top, 5)
        }
    }

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 0) {
                settingsToggleRow("로그인 시 자동 실행", description: "Mac을 켜면 상단바에서 바로 시작합니다.",
                                  isOn: Binding(get: { store.launchAtLogin }, set: { store.setLoginItem($0) }))
                Divider().overlay(Palette.line)
                settingsToggleRow("상단바에 CPU 사용량 표시", description: "아이콘 옆에 현재 사용률을 표시합니다.",
                                  isOn: Binding(get: { store.showCPUInMenu }, set: { store.setMenuCPU($0) }))
            }.cardSurface()
            VStack(alignment: .leading, spacing: 16) {
                Text("계정 연결").font(.system(size: 14, weight: .semibold))
                connectionRow("Codex", connected: store.codexConnected, kind: .codex)
                connectionRow("Claude", connected: store.claudeConnected, kind: .claude)
                connectionRow("Claude API Console", connected: store.claudeAPIConnected, kind: .claudeAPI)
                Text("이 앱의 로그인 창에서 계정을 연결합니다. Codex CLI·Claude Code를 설치할 필요가 없습니다. 웹 조회 경로는 서비스 변경에 영향을 받을 수 있으며, 세션 만료 시 이 앱에서 다시 로그인하면 됩니다.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(20).cardSurface()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("WakaTime", systemImage: "clock").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("연결 설정") {
                        editing = store.templates.first(where: { $0.kind == .wakatime }) ?? StatusStore.wakaTimeTemplate()
                    }.buttonStyle(.borderless).font(.system(size: 11))
                }.padding(20)
                Divider().overlay(Palette.line)
                TrailingSwitchRow(title: "이 Mac의 기존 WakaTime 설정 사용", isOn: Binding(
                    get: { store.useWakaTimeConfiguration },
                    set: { store.setWakaTimeConfiguration($0) }
                ))
                .padding(.horizontal, 20).padding(.vertical, 14)
                Divider().overlay(Palette.line)
                VStack(alignment: .leading, spacing: 14) {
                    Text("~/.wakatime.cfg의 인증 정보로 통계를 조회합니다. 별도로 저장한 개인 OAuth 토큰이 있으면 그 토큰을 우선 사용합니다. 이 옵션을 꺼도 저장한 토큰으로 연결한 항목은 계속 조회됩니다.")
                    Text("Mac Status는 기록을 읽어 표시합니다. WakaTime 추적 앱은 계속 실행한 채 macOS 메뉴 막대 설정에서 아이콘만 숨길 수 있습니다.")
                }
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }.frame(maxWidth: .infinity, alignment: .leading).cardSurface()
            VStack(alignment: .leading, spacing: 10) {
                Label("내 Mac 안에만 저장", systemImage: "lock.shield").font(.system(size: 13, weight: .medium)).foregroundStyle(Palette.mint)
                Text("항목 설정과 앱 전용 웹 로그인 세션은 이 Mac에, 직접 입력한 API 키·토큰은 macOS 키체인에 저장합니다. Codex·Claude는 다른 앱이나 브라우저의 로그인 정보를 읽지 않습니다. WakaTime 기존 설정은 위 옵션을 켠 경우에만 읽습니다. 연결한 서비스에만 조회 요청을 보내며 분석·추적 서버는 없습니다.")
                    .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            }.padding(20).cardSurface()
        }
    }

    private func settingsLabel(_ title: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 13)); Text(description).font(.system(size: 11)).foregroundStyle(Palette.muted) }
            .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
    }

    private func settingsToggleRow(_ title: String, description: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 24) {
            settingsLabel(title, description: description).frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch)
                .controlSize(.regular).tint(Palette.mint).fixedSize()
        }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).padding(20)
    }

    private func connectionRow(_ name: String, connected: Bool, kind: MetricKind) -> some View {
        HStack(spacing: 16) {
            Text(name).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Circle().fill(connected ? Palette.mint : Palette.muted).frame(width: 5, height: 5).accessibilityHidden(true)
                Text(connected ? "자동 조회 켜짐" : "연결 전").font(.system(size: 11))
            }
            .foregroundStyle(connected ? Palette.mint : Palette.muted)
            .frame(width: 98, alignment: .leading)
            HStack(spacing: 8) {
                Button { store.connect(kind) } label: {
                    Label(connected ? "로그인 창" : "연결", systemImage: "macwindow")
                }
                .buttonStyle(ConnectionActionButtonStyle(tint: Palette.mint))
                .accessibilityLabel("\(name) \(connected ? "로그인 창" : "연결")")
                if connected {
                    Button { store.disconnect(kind) } label: {
                        Label("연결 해제", systemImage: "xmark")
                    }
                    .buttonStyle(ConnectionActionButtonStyle(tint: Palette.tint("orange")))
                    .accessibilityLabel("\(name) 연결 해제")
                }
            }.frame(width: 196, alignment: .leading)
        }.frame(minHeight: 36)
    }
}

private struct ConnectionActionButtonStyle: ButtonStyle {
    let tint: Color
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1).fixedSize()
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minWidth: 94, minHeight: 32)
            .background(tint.opacity(configuration.isPressed ? 0.20 : (hovering ? 0.13 : 0.07)),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(hovering || configuration.isPressed ? 0.65 : 0.32), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .onHover { hovering = $0 }
    }
}

struct TemplateBuilderView: View {
    let onEdit: (MetricTemplate) -> Void
    @State private var mode = TemplateCreationMode.presets
    @State private var request = ""
    @State private var json = ""
    @State private var message: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 14) {
                Image(systemName: "square.stack.3d.up").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.mint)
                VStack(alignment: .leading, spacing: 7) {
                    Text("데이터는 달라도, 만드는 방식은 같게.").font(.system(size: 16, weight: .semibold))
                    Text("이름, 단위, 데이터 소스를 템플릿으로 정의하면\n새로운 통계도 같은 카드 스타일로 표시됩니다.")
                        .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).cardSurface()
            TemplateCreationModeSelector(selection: $mode)
            switch mode {
            case .presets: presetContent
            case .ai: generatorContent
            case .json: importContent
            }
            if let message { Text(message).font(.system(size: 11)).foregroundStyle(Palette.tint("orange")).textSelection(.enabled) }
        }
    }

    private var presetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            builderPreset("HTTP API 통계", subtitle: "URL과 JSON 경로로 자동 갱신", icon: "network", tint: "blue") {
                onEdit(.init(name: "새 API 통계", subtitle: "나만의 데이터", symbol: "network", tint: "blue", kind: .http, unit: "", limit: nil, authPrefix: ""))
            }
            builderPreset("직접 입력하는 통계", subtitle: "구독 한도, 예산, 목표를 간편하게", icon: "slider.horizontal.3", tint: "purple") {
                onEdit(.init(name: "나의 통계", subtitle: "직접 입력", tint: "purple", kind: .manual, manualValue: 0))
            }
            builderPreset("WakaTime", subtitle: "오늘·최근 7일 기록 시간, 프로젝트·언어 통계", icon: "clock", tint: "blue") {
                onEdit(StatusStore.wakaTimeTemplate())
            }
            Text("API 프리셋").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).padding(.top, 12)
            builderPreset("OpenAI API 비용", subtitle: "이번 달 실제 조직 API 비용 · Admin 키 필요", icon: "dollarsign.circle", tint: "mint") { onEdit(StatusStore.openAICostTemplate()) }
            builderPreset("OpenAI API 입력 토큰", subtitle: "이번 달 API 입력 토큰 · Admin 키 필요", icon: "number.circle", tint: "blue") { onEdit(StatusStore.openAITokensTemplate()) }
            builderPreset("Anthropic API 비용", subtitle: "이번 달 API 비용 · Priority Tier 제외 · Admin 키 필요", icon: "dollarsign.circle", tint: "orange") { onEdit(StatusStore.anthropicCostTemplate()) }
            builderPreset("Anthropic API 입력 토큰", subtitle: "이번 달 비캐시 입력 토큰 · Admin 키 필요", icon: "number.circle", tint: "orange") { onEdit(StatusStore.anthropicTokensTemplate()) }
        }
    }

    private func builderPreset(_ title: String, subtitle: String, icon: String, tint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.system(size: 21)).foregroundStyle(Palette.tint(tint)).frame(width: 30)
                VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 13, weight: .medium)); Text(subtitle).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer(); Image(systemName: "plus").foregroundStyle(Palette.muted)
            }.padding(17).cardSurface(radius: 11)
        }.buttonStyle(.plain)
    }

    private var generatorContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("01  보고 싶은 통계를 적어 주세요").font(.system(size: 13, weight: .medium))
            TextField("예: 이번 달 Anthropic API 비용을 달러로 보고 싶어", text: $request, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...5)
            Text("02  생성 프롬프트를 ChatGPT·Claude에 붙여넣으세요").font(.system(size: 13, weight: .medium))
            Text("앱의 템플릿 규격과 요청을 함께 복사합니다. 사용 중인 AI가 반환한 JSON을 ‘JSON 가져오기’에 붙여넣으면 설정을 검토한 뒤 추가할 수 있습니다.")
                .font(.system(size: 12)).foregroundStyle(Palette.muted).lineSpacing(4)
            AccentButton(title: copied ? "프롬프트 복사됨" : "생성 프롬프트 복사", symbol: copied ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(TemplateEngine.generationPrompt(request: request), forType: .string)
                copied = true
            }.disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("03  생성된 JSON 가져오기 →") { mode = .json }.buttonStyle(.borderless).font(.system(size: 12)).padding(.top, 12)
        }.padding(22).cardSurface()
    }

    private var importContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("템플릿 JSON").font(.system(size: 13, weight: .medium)); Spacer()
                Button("클립보드에서 붙여넣기") { json = NSPasteboard.general.string(forType: .string) ?? "" }.buttonStyle(.borderless).font(.system(size: 11))
            }
            TextEditor(text: $json).font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden).scrollIndicators(.never)
                .padding(10).frame(height: 220).background(Palette.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
            Text("API 키는 JSON에 넣지 마세요. 검증한 뒤 편집 화면에서 키체인에 별도로 저장합니다.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted)
            AccentButton(title: "검증하고 미리보기", symbol: "checkmark.shield") {
                do {
                    var template = try TemplateEngine.decode(json)
                    template.id = UUID()
                    message = nil
                    onEdit(template)
                } catch { message = error.localizedDescription }
            }.disabled(json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }.padding(22).cardSurface()
    }
}
